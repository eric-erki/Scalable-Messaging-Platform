%%%-------------------------------------------------------------------
%%% File    : mod_bosh.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : This module acts as a bridge to ejabberd_bosh which implements
%%%           the real stuff, this is to handle the new pluggable architecture
%%%           for extending ejabberd's http service.
%%% Created : 20 Jul 2011 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%-------------------------------------------------------------------
-module(mod_bosh).

-author('steve@zeank.in-berlin.de').

%%-define(ejabberd_debug, true).

-behaviour(gen_mod).

-export([start/2, stop/1, process/2, open_session/2,
	 close_session/1, find_session/1]).

%% DHT callbacks
-export([merge_write/2, merge_delete/2, clean/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("jlib.hrl").

-include("ejabberd_http.hrl").

-include("bosh.hrl").

-record(bosh, {sid = <<"">>      :: binary(),
               timestamp = now() :: erlang:timestamp(),
               pid = self()      :: pid()}).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

process([], #request{method = 'POST', data = <<>>}) ->
    ?DEBUG("Bad Request: no data", []),
    {400, ?HEADER(?CT_XML),
     #xmlel{name = <<"h1">>, attrs = [],
	    children = [{xmlcdata, <<"400 Bad Request">>}]}};
process([],
	#request{method = 'POST', data = Data, ip = IP, headers = Hdrs}) ->
    ?DEBUG("Incoming data: ~p", [Data]),
    Type = get_type(Hdrs),
    ejabberd_bosh:process_request(Data, IP, Type);
process([], #request{method = 'GET', data = <<>>}) ->
    {200, ?HEADER(?CT_XML), get_human_html_xmlel()};
process([], #request{method = 'OPTIONS', data = <<>>}) ->
    {200, ?OPTIONS_HEADER, []};
process(_Path, _Request) ->
    ?DEBUG("Bad Request: ~p", [_Request]),
    {400, ?HEADER(?CT_XML),
     #xmlel{name = <<"h1">>, attrs = [],
	    children = [{xmlcdata, <<"400 Bad Request">>}]}}.

get_human_html_xmlel() ->
    Heading = <<"ejabberd ", (jlib:atom_to_binary(?MODULE))/binary>>,
    #xmlel{name = <<"html">>,
	   attrs =
	       [{<<"xmlns">>, <<"http://www.w3.org/1999/xhtml">>}],
	   children =
	       [#xmlel{name = <<"head">>, attrs = [],
		       children =
			   [#xmlel{name = <<"title">>, attrs = [],
				   children = [{xmlcdata, Heading}]}]},
		#xmlel{name = <<"body">>, attrs = [],
		       children =
			   [#xmlel{name = <<"h1">>, attrs = [],
				   children = [{xmlcdata, Heading}]},
			    #xmlel{name = <<"p">>, attrs = [],
				   children =
				       [{xmlcdata, <<"An implementation of ">>},
					#xmlel{name = <<"a">>,
					       attrs =
						   [{<<"href">>,
						     <<"http://xmpp.org/extensions/xep-0206.html">>}],
					       children =
						   [{xmlcdata,
						     <<"XMPP over BOSH (XEP-0206)">>}]}]},
			    #xmlel{name = <<"p">>, attrs = [],
				   children =
				       [{xmlcdata,
					 <<"This web page is only informative. To "
					   "use HTTP-Bind you need a Jabber/XMPP "
					   "client that supports it.">>}]}]}]}.

open_session(SID, Pid) ->
    dht:write(#bosh{sid = SID,
                    timestamp = now(),
                    pid = Pid}).

close_session(SID) ->
    case mnesia:dirty_read(bosh, SID) of
        [R] ->
            dht:delete(R);
        [] ->
            ok
    end.

merge_delete(#bosh{pid = Pid1}, #bosh{pid = Pid2}) ->
    if Pid1 == Pid2 ->
            delete;
       true ->
            keep
    end.

merge_write(#bosh{pid = Pid1, timestamp = T1} = S1,
            #bosh{pid = Pid2, timestamp = T2} = S2) ->
    if Pid1 == Pid2 ->
            S1;
       T1 < T2 ->
            ejabberd_cluster:send(Pid2, replaced),
            S1;
       true ->
            ejabberd_cluster:send(Pid1, replaced),
            S2
    end.

clean(Node) ->
    ets:select_delete(
      bosh,
      ets:fun2ms(
        fun(#bosh{pid = Pid})
              when node(Pid) == Node ->
                true
        end)).

find_session(SID) ->
    case mnesia:dirty_read(bosh, SID) of
        [#bosh{pid = Pid}] ->
            {ok, Pid};
        [] ->
            find_session(SID, ejabberd_cluster:get_nodes(SID))
    end.

find_session(SID, [Node|Nodes]) ->
    case ejabberd_cluster:call(Node, mnesia, dirty_read,
                               [bosh, SID]) of
        [#bosh{pid = Pid}] ->
            {ok, Pid};
        _ ->
            find_session(SID, Nodes)
    end;
find_session(_SID, []) ->
    error.

start(Host, Opts) ->
    setup_database(),
    start_jiffy(Opts),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc,
		 {ejabberd_tmp_sup, start_link, [Proc, ejabberd_bosh]},
		 permanent, infinity, supervisor, [ejabberd_tmp_sup]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

setup_database() ->
    case catch mnesia:table_info(bosh, attributes) of
        [sid, pid] ->
            mnesia:delete_table(bosh);
        _ ->
            ok
    end,
    mnesia:create_table(bosh,
			[{ram_copies, [node()]}, {local_content, true},
			 {attributes, record_info(fields, bosh)}]),
    mnesia:add_table_copy(bosh, node(), ram_copies),
    dht:new(bosh, ?MODULE).

start_jiffy(Opts) ->
    case gen_mod:get_opt(json, Opts,
                         fun(false) -> false;
                            (true) -> true
                         end, false) of
        false ->
            ok;
        true ->
            case catch ejabberd:start_app(jiffy) of
                ok ->
                    ok;
                Err ->
                    ?WARNING_MSG("Failed to start JSON codec (jiffy): ~p. "
                                 "JSON support will be disabled", [Err])
            end
    end.

get_type(Hdrs) ->
    try
        {_, S} = lists:keyfind('Content-Type', 1, Hdrs),
        [T|_] = str:tokens(S, <<";">>),
        [_, <<"json">>] = str:tokens(T, <<"/">>),
        json
    catch _:_ ->
            xml
    end.
