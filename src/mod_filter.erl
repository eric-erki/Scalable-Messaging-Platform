%%%----------------------------------------------------------------------
%%% File    : mod_filter.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Apply regexp filter on message body, or let external backend reformat body
%%% Created : 22 Jan 2018 by Christophe Romain <christophe.romain@process-one.net>
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

-module(mod_filter).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).
-behaviour(gen_mod).
-behaviour(ejabberd_config).

%% API
-export([start_link/2, start/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1, opt_type/1, depends/2]).

-export([set_rule/4, del_rule/2, rules/1]).
-export([filter_packet/1, process_local_iq/3]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("mod_filter.hrl").

-define(PROCNAME, ?MODULE).
-define(CALL_TIMEOUT, 5000).

-record(state, {host, mod, opts = []}).

-callback set_rule(binary(), binary(), binary(), atom()) -> ok | {error, atom()}.
-callback del_rule(binary(), binary()) -> ok | {error, atom()}.
-callback rules(binary()) -> ok | [#filter_rule{}].
-callback filter(binary(), #jid{}, #jid{}, #xmlel{}) -> pass |
							drop |
							{bounce, binary()} |
							{filter, binary()} |
							{error, any()}.


start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 transient, 5000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    supervisor:delete_child(ejabberd_sup, Proc).

set_rule(Host, Id, Exp, Type) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, {set, Id, Exp, Type}, ?CALL_TIMEOUT).

del_rule(Host, Id) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, {del, Id}, ?CALL_TIMEOUT).

rules(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, get, ?CALL_TIMEOUT).

init([Host, Opts]) ->
    Mod = gen_mod:db_mod(Host, ?MODULE),
    ejabberd_hooks:add(filter_packet, ?MODULE, filter_packet, 10),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_FILTER,
				  ?MODULE, process_local_iq, one_queue),
    Mod:init(Host, Opts),
    {ok, #state{host = Host, mod = Mod, opts = Opts}}.

terminate(_Reason, State) ->
    Host = State#state.host,
    ejabberd_hooks:delete(filter_packet, ?MODULE, filter_packet, 10),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_FILTER),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call({set, Id, Exp, Type}, _From, State) ->
    Host = State#state.host,
    Mod = State#state.mod,
    Result = Mod:set_rule(Host, Id, Exp, Type),
    {reply, Result, State};
handle_call({del, Id}, _From, State) ->
    Host = State#state.host,
    Mod = State#state.mod,
    Result = Mod:del_rule(Host, Id),
    {reply, Result, State};
handle_call(get, _From, State) ->
    Host = State#state.host,
    Mod = State#state.mod,
    Result = Mod:rules(Host),
    {reply, Result, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%%% =======================================================
%%% router packet filter
%%% =======================================================

filter_packet({From, To, Packet}) ->
    Host = From#jid.lserver,
    Mod = gen_mod:db_mod(Host, ?MODULE),
    case Mod:filter(Host, From, To, Packet) of
	drop -> drop;
	pass -> {From, To, Packet};
	{filter, NewPacket} -> {From, To, NewPacket};
	{bounce, Msg} -> bounce_packet(From, To, Packet, Msg);
	{error, Error} ->
	    ?ERROR_MSG("failed to filter packet from ~s to ~s~n"
		       "== Packet: ~p~n== Error: ~p",
		       [jid:to_string(From), jid:to_string(To),
			Packet, Error]),
	    {From, To, Packet}
    end.

bounce_packet(From, To, #xmlel{attrs = Attrs} = Packet, Msg) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    if Type == <<"error">>; Type == <<"result">> ->
	    drop;
       true ->
	    {To, From, jlib:make_error_reply(Packet, <<"406">>, Msg)}
    end.

%%% =======================================================
%%% Iq handler
%%% =======================================================

process_local_iq(From, #jid{lserver = VH} = _To,
		 #iq{type = Type, sub_el = SubEl} = IQ) ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}.
%    case Type of
%      get ->
%	  IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
%      set ->
%	  #jid{luser = User, lserver = Server,
%	       lresource = Resource} =
%	      From,
%	  case acl:match_rule(global, configure,
%			      {User, Server, Resource})
%	      of
%	    allow ->
%		case fxml:get_subtag(SubEl, <<"add">>) of
%		  #xmlel{name = <<"add">>, attrs = AddAttrs} ->
%		      AID = fxml:get_attr_s(<<"id">>, AddAttrs),
%		      ARE = fxml:get_attr_s(<<"re">>, AddAttrs),
%		      case fxml:get_attr_s(<<"type">>, AddAttrs) of
%			<<"">> -> add_regexp(VH, AID, ARE);
%			ATP -> add_regexp(VH, AID, ARE, ATP)
%		      end;
%		  _ -> ok
%		end,
%		case fxml:get_subtag(SubEl, <<"del">>) of
%		  #xmlel{name = <<"del">>, attrs = DelAttrs} ->
%		      DID = fxml:get_attr_s(<<"id">>, DelAttrs),
%		      case fxml:get_attr_s(<<"re">>, DelAttrs) of
%			<<"">> -> del_regexp(VH, DID);
%			DRE -> del_regexp(VH, DID, DRE)
%		      end;
%		  _ -> ok
%		end,
%		case fxml:get_subtag(SubEl, <<"delrules">>) of
%		  #xmlel{name = <<"delrules">>} -> purge_regexps(VH);
%		  _ -> ok
%		end,
%		IQ#iq{type = result, sub_el = []};
%	    _ ->
%		IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
%	  end
%    end.

depends(_Host, _Opts) ->
    [].

mod_opt_type(db_type) -> fun(T) -> ejabberd_config:v_db(?MODULE, T) end;
mod_opt_type(_) -> [db_type].

opt_type(_) -> [].
