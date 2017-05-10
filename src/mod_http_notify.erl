%%%----------------------------------------------------------------------
%%% File    : mod_http_notify.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Send HTTP notifications about some events
%%% Created :  9 Oct 2013 by Alexey Shchepin <alexey@process-one.net>
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

-module(mod_http_notify).
-author('alexey@process-one.net').
-author('cromain@process-one.net').

-define(GEN_SERVER, p1_server).
-behaviour(gen_server).
-behaviour(gen_mod).

-export([start/2, stop/1, start_link/2, enable/0, disable/0]).

-export([offline/3, available/1, presence/4, unavailable/4,
	 connect/3, disconnect/3,
	 create_room/3, remove_room/3, join_room/4, leave_room/4]).

-export([init/1, handle_info/2, handle_call/3,
	 handle_cast/2, terminate/2, code_change/3,
	 depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-define(PROCNAME, ejabberd_notify).

-define(HOOKS, [{offline_message_hook, offline, 35},
		{user_available_hook, available, 50},
		{set_presence_hook, presence, 50},
		{unset_presence_hook, unavailable, 50},
		{sm_register_connection_hook, connect, 80},
		{sm_remove_connection_hook, disconnect, 80},
		{create_room, create_room, 50},
		{remove_room, remove_room, 50},
		{join_room, join_room, 50},
		{leave_room, leave_room, 50}]).

-define(DICT, dict).

-record(state, {host = <<"">>             :: binary(),
                endpoints = (?DICT):new() :: ?DICT}).
%%%
%%% API
%%%

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 transient, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

init([Host, Opts]) ->
    rest:start(Host),
    [maybe_hook(Host, Opts, Hook, Fun, Priority)
     || {Hook, Fun, Priority} <- ?HOOKS],
    Cfg = [{Fun, v_fun(Args)} || {Fun, Args} <- Opts],
    {ok, #state{host = Host, endpoints = (?DICT):from_list(Cfg)}}.

terminate(_Reason, State) ->
    Host = State#state.host,
    [unhook(Host, Hook, Fun, Priority)
     || {Hook, Fun, Priority} <- ?HOOKS],
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Req, _From, State) ->
    {reply, {error, badarg}, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({notify, Type, Params}, State) ->
    Event = [{<<"notification_type">>, atom_to_binary(Type, latin1)} | Params],
    case (?DICT):find(Type, State#state.endpoints) of
	{ok, {URL, <<>>}} ->
	    rest:post(undefined, URL, [],
		      jiffy:encode({Event}));
	{ok, {URL, AuthToken}} ->
	    rest:post(undefined, URL, [],
		      jiffy:encode({[{<<"access_token">>, AuthToken} | Event]}));
	_ ->
	    ?ERROR_MSG("Received unconfigured event ~s: ~p", [Type, Event])
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

%%%
%%% Simple debug start/stop helpers
%%%

enable() ->
    Conf = [{Host, proplists:get_value(?MODULE,
			ejabberd_config:get_option({modules, Host},
						   fun(X) -> X end, []))}
	    || Host <- ejabberd_config:get_myhosts()],
    [{Host, gen_mod:start_module(Host, ?MODULE, Opts)}
     || {Host, Opts} <- Conf, Opts=/=undefined].

disable() ->
    [{Host, gen_mod:stop_module(Host, ?MODULE)}
     || Host <- ejabberd_config:get_myhosts()].

%%%
%%% Hook handlers
%%%

offline(From, To, Packet) ->
    Host = To#jid.lserver,
    Type = fxml:get_tag_attr_s(<<"type">>, Packet),
    Body = fxml:get_subtag(Packet, <<"body">>),
    if (Body /= <<"">>) andalso
       ((Type == <<"normal">>) or (Type == <<"">>) or (Type == <<"chat">>)) ->
	  SFrom = jid:to_string(From),
	  STo = jid:to_string(To),
	  notify(Host, offline,
		 [{<<"from">>, SFrom},
		  {<<"to">>, STo},
		  {<<"body">>, Body}]);
       true ->
	  ok
    end.

available(JID) ->
    Host = JID#jid.lserver,
    notify(Host, available,
	   [{<<"jid">>, jid:to_string(JID)}]).

presence(User, Server, Resource, _Presence) ->
    Host = jid:nameprep(Server),
    JID = jid:make(User, Server, Resource),
    notify(Host, presence,
	   [{<<"jid">>, jid:to_string(JID)}]).

unavailable(User, Server, Resource, _Status) ->
    Host = jid:nameprep(Server),
    JID = jid:make(User, Server, Resource),
    notify(Host, unavailable,
	   [{<<"jid">>, jid:to_string(JID)}]).

connect(_SID, JID, _Info) ->
    Host = JID#jid.lserver,
    notify(Host, connect,
	   [{<<"jid">>, jid:to_string(JID)}]).

disconnect(_SID, JID, _Info) ->
    Host = JID#jid.lserver,
    notify(Host, disconnect,
	   [{<<"jid">>, jid:to_string(JID)}]).

create_room(ServerHost, Room, Host) ->
    notify(ServerHost, create_room,
	   [{<<"room">>, <<Room/binary, "@", Host/binary>>}]).

remove_room(ServerHost, Room, Host) ->
    notify(ServerHost, remove_room,
	   [{<<"room">>, <<Room/binary, "@", Host/binary>>}]).

join_room(ServerHost, Room, Host, JID) ->
    notify(ServerHost, join_room,
	   [{<<"room">>, <<Room/binary, "@", Host/binary>>},
	    {<<"jid">>, jid:to_string(JID)}]).

leave_room(ServerHost, Room, Host, JID) ->
    notify(ServerHost, leave_room,
	   [{<<"room">>, <<Room/binary, "@", Host/binary>>},
	    {<<"jid">>, jid:to_string(JID)}]).

%%%
%%% internal helpers
%%%

notify(Host, Type, Params) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    Proc ! {notify, Type, Params}.

maybe_hook(Host, Opts, Hook, Fun, Priority) ->
    case lists:keymember(Fun, 1, Opts) of
	true -> ejabberd_hooks:add(Hook, Host, ?MODULE, Fun, Priority);
	false -> ok
    end.

unhook(Host, Hook, Fun, Priority) ->
    ejabberd_hooks:delete(Hook, Host, ?MODULE, Fun, Priority).

v_fun(L) when is_list(L) ->
    URL = proplists:get_value(url, L),
    AuthToken = proplists:get_value(auth_token, L, <<>>),
    {URL, AuthToken}.

depends(_Host, _Opts) ->
    [].

mod_opt_type(Handler) ->
    Handlers = [Fun || {_Hook, Fun, _Priority} <- ?HOOKS],
    case lists:member(Handler, Handlers) of
	true -> fun v_fun/1;
	false -> Handlers
    end.
