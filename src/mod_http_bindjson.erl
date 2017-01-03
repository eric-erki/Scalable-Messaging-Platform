%%%----------------------------------------------------------------------
%%% File    : mod_http_bindjson.erl
%%% Original Author : Stefan Strigler <steve@zeank.in-berlin.de>
%%% Purpose : Implementation of XMPP over BOSH (XEP-0206)
%%% Created : Tue Feb 20 13:15:52 CET 2007
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2017   ProcessOne
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
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%----------------------------------------------------------------------

%%%----------------------------------------------------------------------
%%% This module acts as a bridge to ejabberd_http_bind which implements
%%% the real stuff, this is to handle the new pluggable architecture for
%%% extending ejabberd's http service.
%%%----------------------------------------------------------------------
%%% I will probable kill and merge code with the original mod_http_bind
%%% if this feature gains traction.
%%%           Eric Cestari

-module(mod_http_bindjson).

-author('steve@zeank.in-berlin.de').

%%-define(ejabberd_debug, true).

-behaviour(gen_mod).

-export([start/2, stop/1, process/2, depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_http.hrl").

-include("http_bind.hrl").

-record(http_bind,
	{id, pid, to, hold, wait, process_delay, version}).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

process([], #request{method = 'POST', data = <<>>}) ->
    ?DEBUG("Bad Request: no data", []),
    {400, ?HEADER,
     #xmlel{name = <<"h1">>, attrs = [],
	    children = [{xmlcdata, <<"400 Bad Request">>}]}};
process([],
	#request{method = 'POST', data = Data, ip = IP}) ->
    ?DEBUG("Incoming data: ~s", [Data]),
    ejabberd_http_bindjson:process_request(Data, IP);
process([], #request{method = 'GET', data = <<>>}) ->
    {200, ?HEADER, get_human_html_xmlel()};
process([], #request{method = 'OPTIONS', data = <<>>}) ->
    {200, ?OPTIONS_HEADER, []};
process(_Path, _Request) ->
    ?DEBUG("Bad Request: ~p", [_Request]),
    {400, ?HEADER,
     #xmlel{name = <<"h1">>, attrs = [],
	    children = [{xmlcdata, <<"400 Bad Request">>}]}}.

get_human_html_xmlel() ->
    Heading = <<"ejabberd ",
		(iolist_to_binary(atom_to_list(?MODULE)))/binary>>,
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

start(_Host, _Opts) ->
    setup_database().

stop(_Host) ->
    ok.

setup_database() ->
    migrate_database(),
    mnesia:create_table(http_bind,
			[{ram_copies, [node()]}, {local_content, true},
			 {attributes, record_info(fields, http_bind)}]),
    mnesia:add_table_copy(http_bind, node(), ram_copies).

migrate_database() ->
    case catch mnesia:table_info(http_bind, attributes) of
      [id, pid, to, hold, wait, process_delay, version] -> ok;
      _ -> mnesia:delete_table(http_bind)
    end,
    case catch mnesia:table_info(http_bind, local_content)
	of
      false -> mnesia:delete_table(http_bind);
      _ -> ok
    end.

depends(_Host, _Opts) ->
    [].

mod_opt_type(_) -> [].
