%%%----------------------------------------------------------------------
%%% File    : ejabberd_sm.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Session manager
%%% Created : 24 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_sm).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').
-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

-compile(export_all).

%% API
-export([start/0,
	 start_link/0,
	 route/3, do_route1/4,
	 set_session/6,
	 process_iq/3,
	 open_session/5,
	 open_session/6,
	 close_session/4,
	 close_migrated_session/4,
	 drop_session/2,
	 check_in_subscription/6,
	 bounce_offline_message/3,
	 disconnect_removed_user/2,
	 get_user_sessions/2,
	 get_user_resources/2,
	 get_user_present_resources/2,
	 set_presence/7,
	 unset_presence/6,
	 close_session_unset_presence/5,
	 set_offline_info/5,
	 get_offline_info/4,
	 dirty_get_sessions_list/0,
	 dirty_get_my_sessions_list/0,
	 get_vh_session_list/1,
	 get_vh_my_session_list/1,
	 get_vh_session_number/1,
	 get_vh_by_backend/1,
	 register_iq_handler/4,
	 register_iq_handler/5,
	 unregister_iq_handler/2,
	 force_update_presence/1,
	 connected_users/0,
	 connected_users_number/0,
	 get_sessions_number/0,
	 user_resources/2,
	 kick_user/2,
	 get_session_pid/3,
	 get_user_info/3,
	 get_user_ip/3,
	 get_max_user_sessions/2,
	 get_all_pids/0,
	 get_proc_num/0,
	 get_commands_spec/0,
         make_sid/0,
         cache_tab_error/0
	]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("jlib.hrl").

-include("ejabberd_commands.hrl").
-include("mod_privacy.hrl").
-include("ejabberd_sm.hrl").

-callback init() -> ok | {error, any()}.
-callback get_session(binary(), binary(), binary()) -> {ok, #session{}} | {error, notfound}.
-callback set_session(#session{}) -> ok.
-callback delete_session({binary(), binary(), binary()}) -> ok.
-callback get_sessions() -> [#session{}].
-callback get_sessions(binary()) -> [#session{}].
-callback get_sessions(binary(), binary()) -> [#session{}].
-callback get_node_sessions(atom()) -> [#session{}].
-callback delete_node(atom()) -> ok.
-callback get_sessions_number() -> integer().

-record(state, {}).

%% default value for the maximum number of user connections
-define(MAX_USER_SESSIONS, infinity).
-define(CALL_TIMEOUT, timer:seconds(60)).

-type session() :: #session{}.

%%====================================================================
%% API
%%====================================================================
-export_type([sid/0]).

start() ->
    ChildSpec = {?MODULE, {?MODULE, start_link, []},
		 transient, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

start_link() ->
    ?GEN_SERVER:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec route(jid(), jid(), xmlel() | broadcast()) -> ok.

route(From, To, Packet) ->
    case catch do_route(From, To, Packet, []) of
      {'EXIT', Reason} ->
	  ?ERROR_MSG("~p~nwhen processing: ~p",
		     [Reason, {From, To, Packet}]);
      _ -> ok
    end.

-spec open_session(sid(), binary(), binary(), binary(), info()) -> ok.

open_session(SID, User, Server, Resource, Info) ->
    open_session(SID, User, Server, Resource, undefined,
		 Info).

-spec open_session(sid(), binary(), binary(), binary(), prio(), info()) -> ok.

open_session(SID, User, Server, Resource, Priority, Info) ->
    set_session(SID, User, Server, Resource, Priority, Info),
    check_for_sessions_to_replace(User, Server, element(2,SID)),
    JID = jid:make(User, Server, Resource),
    ejabberd_hooks:run(sm_register_connection_hook,
		       JID#jid.lserver, [SID, JID, Info]).

-spec close_session(sid(), binary(), binary(), binary()) -> ok.

close_session(SID, User, Server, Resource) ->
    Info = do_close_session(SID, User, Server, Resource),
    JID = jid:make(User, Server, Resource),
    ejabberd_hooks:run(sm_remove_connection_hook,
		       JID#jid.lserver, [SID, JID, Info]).

-spec close_migrated_session(sid(), binary(), binary(), binary()) -> ok.

close_migrated_session(SID, User, Server, Resource) ->
    Info = do_close_session(SID, User, Server, Resource),
    JID = jid:make(User, Server, Resource),
    ejabberd_hooks:run(sm_remove_migrated_connection_hook,
		       JID#jid.lserver, [SID, JID, Info]).

-spec do_close_session(sid(), binary(), binary(), binary()) -> info().

do_close_session(SID, User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    USR = {LUser, LServer, LResource},
    Mod = get_sm_backend(LServer),
    Info = case Mod:get_session(LUser, LServer, LResource) of
	       {ok, #session{info = I}} -> I;
	       {error, notfound} -> []
	   end,
    drop_session(SID, USR),
    Info.

-spec drop_session(sid(), ljid()) -> any().

drop_session(SID, USR) ->
    lists:foreach(
      fun(Node) when Node == node() ->
	      ?GEN_SERVER:call(?MODULE, {delete, SID, USR}, ?CALL_TIMEOUT);
	 (Node) ->
	      ejabberd_cluster:send({?MODULE, Node}, {delete, SID, USR})
      end, ejabberd_cluster:get_nodes()).

-spec check_in_subscription(any(), binary(), binary(),
                            any(), any(), any()) -> any().

check_in_subscription(Acc, User, Server, _JID, _Type, _Reason) ->
    case ejabberd_auth:is_user_exists(User, Server) of
      true -> Acc;
      false -> {stop, false}
    end.

-spec bounce_offline_message(jid(), jid(), xmlel()) -> stop.

bounce_offline_message(From, To, Packet) ->
    Lang = fxml:get_tag_attr_s(<<"xml:lang">>, Packet),
    Txt = <<"User session not found">>,
    Err = jlib:make_error_reply(
	    Packet, ?ERRT_SERVICE_UNAVAILABLE(Lang, Txt)),
    ejabberd_router:route(To, From, Err),
    stop.

-spec disconnect_removed_user(binary(), binary()) -> ok.

disconnect_removed_user(User, Server) ->
    ejabberd_sm:route(jid:make(<<"">>, <<"">>, <<"">>),
		      jid:make(User, Server, <<"">>),
                      {broadcast, {exit, <<"User removed">>}}).

-spec get_user_sessions(binary(), binary()) -> [session()].

get_user_sessions(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Mod = get_sm_backend(LServer),
    Mod:get_sessions(LUser, LServer).

-spec get_user_resources(binary(), binary()) -> [binary()].

get_user_resources(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Mod = get_sm_backend(LServer),
    Ss = Mod:get_sessions(LUser, LServer),
    [element(3, S#session.usr) || S <- clean_session_list(Ss)].

-spec get_user_present_resources(binary(), binary()) -> [tuple()].

get_user_present_resources(LUser, LServer) ->
    Mod = get_sm_backend(LServer),
    Ss = Mod:get_sessions(LUser, LServer),
    [{S#session.priority, element(3, S#session.usr)}
     || S <- clean_session_list(Ss), is_integer(S#session.priority)].

-spec get_user_ip(binary(), binary(), binary()) -> ip().

get_user_ip(User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    Mod = get_sm_backend(LServer),
    case Mod:get_session(LUser, LServer, LResource) of
        {ok, Session} -> proplists:get_value(ip, Session#session.info);
        {error, notfound} -> undefined
    end.

-spec get_user_info(binary(), binary(), binary()) -> info() | offline.

get_user_info(User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    Mod = get_sm_backend(LServer),
    case Mod:get_session(LUser, LServer, LResource) of
        {ok, Session} ->
            N = node(element(2, Session#session.sid)),
            Conn = proplists:get_value(conn, Session#session.info),
            IP = proplists:get_value(ip, Session#session.info),
            [{node, N}, {conn, Conn}, {ip, IP}];
        {error, notfound} -> offline
    end.

-spec set_presence(sid(), binary(), binary(), binary(),
                   prio(), xmlel(), info()) -> ok.

set_presence(SID, User, Server, Resource, Priority,
	     Presence, Info) ->
    set_session(SID, User, Server, Resource, Priority,
		Info),
    ejabberd_hooks:run(set_presence_hook,
		       jid:nameprep(Server),
		       [User, Server, Resource, Presence]).

-spec unset_presence(sid(), binary(), binary(),
                     binary(), binary(), info()) -> ok.

unset_presence(SID, User, Server, Resource, Status,
	       Info) ->
    set_session(SID, User, Server, Resource, undefined,
		Info),
    ejabberd_hooks:run(unset_presence_hook,
		       jid:nameprep(Server),
		       [User, Server, Resource, Status]).

-spec close_session_unset_presence(sid(), binary(), binary(),
                                   binary(), binary()) -> ok.

close_session_unset_presence(SID, User, Server,
			     Resource, Status) ->
    close_session(SID, User, Server, Resource),
    ejabberd_hooks:run(unset_presence_hook,
		       jid:nameprep(Server),
		       [User, Server, Resource, Status]).

-spec get_session_pid(binary(), binary(), binary()) -> none | pid().

get_session_pid(User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    Mod = get_sm_backend(LServer),
    case Mod:get_session(LUser, LServer, LResource) of
        {ok, #session{sid = {_, Pid}}} -> Pid;
        {error, notfound} -> none
    end.

-spec set_offline_info(sid(), binary(), binary(), binary(), info()) -> ok.

set_offline_info({Time, _} = _SID, User, Server, Resource, Info) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    Key = {Time, LUser, LServer, LResource},
    cache_tab:dirty_dist_insert(
      mgmt_offline, Key, Info, fun ?MODULE:cache_tab_error/0).

-spec get_offline_info(erlang:timestamp(), binary(), binary(),
                       binary()) -> none | info().

get_offline_info(Time, User, Server, Resource) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    Key = {Time, LUser, LServer, LResource},
    case cache_tab:lookup(mgmt_offline, Key, fun ?MODULE:cache_tab_error/0) of
	{ok, Info} ->
            cache_tab:dirty_dist_delete(
              mgmt_offline, Key, fun ?MODULE:cache_tab_error/0),
            Info;
	_ ->
	    none
    end.

cache_tab_error() -> error.

-spec dirty_get_sessions_list() -> [ljid()].

dirty_get_sessions_list() ->
    lists:flatmap(
      fun(Mod) ->
	      [S#session.usr || S <- Mod:get_sessions()]
      end, get_sm_backends()).

-spec dirty_get_my_sessions_list() -> [#session{}].

dirty_get_my_sessions_list() ->
    lists:flatmap(
      fun(Mod) ->
	      [S || S <- Mod:get_sessions(),
		    node(element(2, S#session.sid)) == node()]
      end, get_sm_backends()).

-spec get_vh_my_session_list(binary()) -> [ljid()].

get_vh_my_session_list(Server) ->
    LServer = jid:nameprep(Server),
    Mod = get_sm_backend(LServer),
    [S#session.usr || S <- Mod:get_sessions(LServer),
                      node(element(2, S#session.sid)) == node()].

-spec get_vh_session_list(binary()) -> [ljid()].

get_vh_session_list(Server) ->
    LServer = jid:nameprep(Server),
    Mod = get_sm_backend(LServer),
    [S#session.usr || S <- Mod:get_sessions(LServer)].

-spec get_all_pids() -> [pid()].

get_all_pids() ->
    lists:flatmap(
      fun(Mod) ->
	      [element(2, S#session.sid) || S <- Mod:get_sessions()]
      end, get_sm_backends()).

-spec get_vh_session_number(binary()) -> non_neg_integer().

get_vh_session_number(Server) ->
    LServer = jid:nameprep(Server),
    Mod = get_sm_backend(LServer),
    length(Mod:get_sessions(LServer)).

-spec register_iq_handler(binary(), binary(), atom(), atom()) -> any().

register_iq_handler(Host, XMLNS, Module, Fun) ->
    ?MODULE ! {register_iq_handler, Host, XMLNS, Module, Fun}.

-spec register_iq_handler(binary(), binary(), atom(), atom(), list()) -> any().

register_iq_handler(Host, XMLNS, Module, Fun, Opts) ->
    ?MODULE ! {register_iq_handler, Host, XMLNS, Module, Fun, Opts}.

-spec unregister_iq_handler(binary(), binary()) -> any().

unregister_iq_handler(Host, XMLNS) ->
    ?MODULE ! {unregister_iq_handler, Host, XMLNS}.

register_hooks(Host) ->
    ejabberd_hooks:add(roster_in_subscription, Host,
		       ejabberd_sm, check_in_subscription,
		       20),
    ejabberd_hooks:add(offline_message_hook, Host,
		       ejabberd_sm,
		       bounce_offline_message, 100),
    ejabberd_hooks:add(remove_user, Host, ejabberd_sm,
		       disconnect_removed_user, 100).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    lists:foreach(fun(Mod) -> Mod:init() end, get_sm_backends()),
    ets:new(sm_iqtable, [named_table, bag]),
    lists:foreach(fun register_hooks/1, ?MYHOSTS),
    ejabberd_commands:register_commands(get_commands_spec()),
    ejabberd_cluster:subscribe(),
    start_handlers(),
    cache_tab:new(crls, [{max_size, 10000},
			 {life_time, timer:minutes(1) div 1000}]),
    cache_tab:new(mgmt_offline,
                  [{max_size, 10000},
                   {life_time, timer:hours(24) div 1000}]),
    {ok, #state{}}.

handle_call({write, Session}, _From, State) ->
    Res = write_session(Session),
    {reply, Res, State};
handle_call({delete, SID, USR}, _From, State) ->
    Res = delete_session(SID, USR),
    {reply, Res, State};
handle_call(_Request, _From, State) ->
    Reply = ok, {reply, Reply, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({route, From, To, Packet}, State) ->
    handle_info({route, From, To, Packet, []}, State);
handle_info({route, From, To, Packet, Hops}, State) ->
    case catch do_route(From, To, Packet, Hops) of
        {'EXIT', Reason} ->
            ?ERROR_MSG("~p~nwhen processing: ~p",
                       [Reason, {From, To, Packet, Hops}]);
        _ ->
            ok
    end,
    {noreply, State};
handle_info({route_multiple, From, Destinations, Packet}, State) ->
    lists:foreach(
      fun(To) ->
              handle_info({route, From, To, Packet, []}, State)
      end, Destinations),
    {noreply, State};
handle_info({register_iq_handler, Host, XMLNS, Module,
	     Function},
	    State) ->
    ets:insert(sm_iqtable,
	       {{XMLNS, Host}, Module, Function}),
    {noreply, State};
handle_info({register_iq_handler, Host, XMLNS, Module, Function, Opts}, State) ->
    ets:insert(sm_iqtable, {{XMLNS, Host}, Module, Function, Opts}),
    if is_pid(Opts) ->
            erlang:monitor(process, Opts);
       true ->
            ok
    end,
    {noreply, State};
handle_info({unregister_iq_handler, Host, XMLNS},
	    State) ->
    case ets:lookup(sm_iqtable, {XMLNS, Host}) of
      [{_, Module, Function, Opts1}|Tail] when is_pid(Opts1) ->
	  Opts = [Opts1 | [Pid || {_, _, _, Pid} <- Tail]],
	  gen_iq_handler:stop_iq_handler(Module, Function, Opts);
      _ -> ok
    end,
    ets:delete(sm_iqtable, {XMLNS, Host}),
    {noreply, State};
handle_info({'DOWN', _MRef, _Type, Pid, _Info}, State) ->
    Rs = ets:select(sm_iqtable,
                    [{{'_','_','_','$1'},
                      [{'==', '$1', Pid}],
                      ['$_']}]),
    lists:foreach(fun(R) -> ets:delete_object(sm_iqtable, R) end, Rs),
    {noreply, State};
handle_info({write, Session}, State) ->
    write_session(Session),
    {noreply, State};
handle_info({delete, SID, USR}, State) ->
    delete_session(SID, USR),
    {noreply, State};
handle_info({node_up, Node}, State) ->
    lists:foreach(
      fun(Mod) ->
	      Ss = Mod:get_node_sessions(node()),
	      lists:foreach(
		fun(S) ->
			ejabberd_cluster:send({?MODULE, Node}, {write, S})
		end, Ss)
      end, get_sm_backends()),
    {noreply, State};
handle_info({node_down, Node}, State) ->
    lists:foreach(
      fun(Mod) ->
	      Mod:delete_node(Node)
      end, get_sm_backends()),
    {noreply, State};
handle_info(_Info, State) ->
    ?ERROR_MSG("got unexpected info: ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ejabberd_commands:unregister_commands(get_commands_spec()),
    stop_handlers(),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

-spec set_session(sid(), binary(), binary(), binary(),
                  prio(), info()) -> ok.

set_session(SID, User, Server, Resource, Priority, Info) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LResource = jid:resourceprep(Resource),
    US = {LUser, LServer},
    USR = {LUser, LServer, LResource},
    Session = #session{sid = SID, usr = USR, us = US,
                       priority = Priority, info = Info},
    Mod = get_sm_backend(LServer),
    case Mod:get_session(LUser, LServer, LResource) of
	{ok, Session} ->
	    ok;
	_ ->
	    lists:foreach(
	      fun(Node) when Node == node() ->
		      ?GEN_SERVER:call(?MODULE, {write, Session}, ?CALL_TIMEOUT);
		 (Node) ->
		      ejabberd_cluster:send({?MODULE, Node}, {write, Session})
	      end, ejabberd_cluster:get_nodes())
    end.

write_session(#session{usr = USR, sid = {T1, P1}} = S1) ->
    {LUser, LServer, LResource} = USR,
    Mod = get_sm_backend(LServer),
    case Mod:get_session(LUser, LServer, LResource) of
	{ok, #session{sid = {T2, P2}, us = {_, Server}} = S2} when P1 /= P2 ->
	    {Old, New} = if T1 < T2 -> {S1, S2};
			    true -> {S2, S1}
			 end,
	    case ejabberd_config:get_option(
		   {resource_conflict, Server},
		   fun(closeold) -> acceptnew;
		      (closenew) -> closenew;
		      (acceptnew) -> acceptnew
		   end, acceptnew) of
		acceptnew ->
		    ejabberd_cluster:send(
		      element(2, Old#session.sid), {replaced, element(2, New#session.sid)}),
		    Mod:set_session(New);
		closenew ->
		    ejabberd_cluster:send(
		      element(2, New#session.sid), {replaced, element(2, Old#session.sid)}),
		    Mod:set_session(Old)
	    end;
	_ ->
	    Mod:set_session(S1)
    end.

delete_session({_, Pid1} = _SID, USR) ->
    {LUser, LServer, LResource} = USR,
    Mod = get_sm_backend(LServer),
    case Mod:get_session(LUser, LServer, LResource) of
	{ok, #session{sid = {_, Pid2}}} when Pid1 == Pid2 ->
	    Mod:delete_session(USR);
	_ ->
	    ok
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

do_route(From, To, Packet, Hops) ->
    ?DEBUG("session manager~n\tfrom ~s~n\tto ~s~n\tpacket "
	   "~P~n",
	   [jid:to_string(From),
	    jid:to_string(To),
	    Packet, 8]),
    {U, S, R} = jid:tolower(To),
    Mod = get_sm_backend(S),
    case Mod:get_session(U, S, R) of
	{ok, #session{sid = {_, Pid}}} ->
	    Node = node(Pid),
	    if Node == node() ->
		    dispatch(From, To, Packet, Hops);
	       true ->
		    case lists:member(Node, Hops) of
			true ->
			    %% Loop detected. End up here.
			    dispatch(From, To, Packet, Hops);
			false ->
			    ejabberd_cluster:send(
			      {get_proc_by_hash({U, S}), Node},
			      {route, From, To, Packet, [node()|Hops]})
		    end
	    end;
	{error, notfound} ->
	    dispatch(From, To, Packet, Hops)
    end.

do_route1(From, To, {broadcast, _} = Packet, Hops) ->
    case To#jid.lresource of
        <<"">> ->
            lists:foreach(fun (R) ->
                                  do_route(From,
                                           jid:replace_resource(To, R),
                                           Packet, Hops)
                          end,
                          get_user_resources(To#jid.user, To#jid.server));
        _ ->
            USR = jid:tolower(To),
            {LUser, LServer, LResource} = USR,
            Mod = get_sm_backend(LServer),
            case Mod:get_session(LUser, LServer, LResource) of
                {error, notfound} ->
                    ?DEBUG("packet dropped~n", []);
                {ok, Session} ->
                    Pid = element(2, Session#session.sid),
                    ?DEBUG("sending to process ~p~n", [Pid]),
                    ejabberd_cluster:send(Pid, {route, From, To, Packet})
            end
    end;
do_route1(From, To, Packet, Hops) ->
    #jid{user = User, server = Server, luser = LUser,
	 lserver = LServer, lresource = LResource} =
	To,
    #xmlel{name = Name, attrs = Attrs} = Packet,
    ejabberd_hooks:run(message_to_user, LServer, [From, To, Packet]),
    Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
    case LResource of
      <<"">> ->
	  case Name of
	    <<"presence">> ->
		{Pass, _Subsc} = case fxml:get_attr_s(<<"type">>, Attrs)
				     of
				   <<"subscribe">> ->
				       Reason = fxml:get_path_s(Packet,
							       [{elem,
								 <<"status">>},
								cdata]),
				       {is_privacy_allow(From, To, Packet)
					  andalso
					  ejabberd_hooks:run_fold(roster_in_subscription,
								  LServer,
								  false,
								  [User, Server,
								   From,
								   subscribe,
								   Reason]),
					true};
				   <<"subscribed">> ->
				       {is_privacy_allow(From, To, Packet)
					  andalso
					  ejabberd_hooks:run_fold(roster_in_subscription,
								  LServer,
								  false,
								  [User, Server,
								   From,
								   subscribed,
								   <<"">>]),
					true};
				   <<"unsubscribe">> ->
				       {is_privacy_allow(From, To, Packet)
					  andalso
					  ejabberd_hooks:run_fold(roster_in_subscription,
								  LServer,
								  false,
								  [User, Server,
								   From,
								   unsubscribe,
								   <<"">>]),
					true};
				   <<"unsubscribed">> ->
				       {is_privacy_allow(From, To, Packet)
					  andalso
					  ejabberd_hooks:run_fold(roster_in_subscription,
								  LServer,
								  false,
								  [User, Server,
								   From,
								   unsubscribed,
								   <<"">>]),
					true};
				   _ -> {true, false}
				 end,
		if Pass ->
		       PResources = get_user_present_resources(LUser, LServer),
		       lists:foreach(fun ({_, R}) ->
					     do_route(From,
						      jid:replace_resource(To,
										R),
						      Packet, Hops)
				     end,
				     PResources);
		   true -> ok
		end;
	    <<"message">> ->
		case fxml:get_attr_s(<<"type">>, Attrs) of
		  <<"chat">> -> route_message(From, To, Packet, chat);
		  <<"headline">> -> route_message(From, To, Packet, headline);
		  <<"error">> -> ok;
		  <<"groupchat">> ->
		      ErrTxt = <<"User session not found">>,
		      Err = jlib:make_error_reply(
			      Packet, ?ERRT_SERVICE_UNAVAILABLE(Lang, ErrTxt)),
		      ejabberd_router:route(To, From, Err);
		  _ ->
		      route_message(From, To, Packet, normal)
		end;
	    <<"iq">> -> process_iq(From, To, Packet);
	    _ -> ok
	  end;
      _ ->
	  Mod = get_sm_backend(LServer),
	  case Mod:get_session(LUser, LServer, LResource) of
	    {error, notfound} ->
		case Name of
		  <<"message">> ->
		      case fxml:get_attr_s(<<"type">>, Attrs) of
			<<"chat">> -> route_message(From, To, Packet, chat);
			<<"headline">> -> ok;
			<<"error">> -> ok;
			<<"groupchat">> ->
			    ErrTxt = <<"User session not found">>,
			    Err = jlib:make_error_reply(
				    Packet,
				    ?ERRT_SERVICE_UNAVAILABLE(Lang, ErrTxt)),
			    ejabberd_router:route(To, From, Err);
			_ ->
			    route_message(From, To, Packet, normal)
		      end;
		  <<"iq">> ->
		      case fxml:get_attr_s(<<"type">>, Attrs) of
			<<"error">> -> ok;
			<<"result">> -> ok;
			_ ->
			    ErrTxt = <<"User session not found">>,
			    Err = jlib:make_error_reply(
				    Packet,
				    ?ERRT_SERVICE_UNAVAILABLE(Lang, ErrTxt)),
			    ejabberd_router:route(To, From, Err)
		      end;
		  _ -> ?DEBUG("packet dropped~n", [])
		end;
	    {ok, Session} ->
		Pid = element(2, Session#session.sid),
		?DEBUG("sending to process ~p~n", [Pid]),
		ejabberd_cluster:send(Pid, {route, From, To, Packet})
	  end
    end.

%% The default list applies to the user as a whole,
%% and is processed if there is no active list set
%% for the target session/resource to which a stanza is addressed,
%% or if there are no current sessions for the user.
is_privacy_allow(From, To, Packet) ->
    User = To#jid.user,
    Server = To#jid.server,
    PrivacyList =
	ejabberd_hooks:run_fold(privacy_get_user_list, Server,
				#userlist{}, [User, Server]),
    is_privacy_allow(From, To, Packet, PrivacyList).

%% Check if privacy rules allow this delivery
%% Function copied from ejabberd_c2s.erl
is_privacy_allow(From, To, Packet, PrivacyList) ->
    User = To#jid.user,
    Server = To#jid.server,
    allow ==
      ejabberd_hooks:run_fold(privacy_check_packet, Server,
			      allow,
			      [User, Server, PrivacyList, {From, To, Packet},
			       in]).

route_message(From, To, Packet, Type) ->
    LUser = To#jid.luser,
    LServer = To#jid.lserver,
    PrioRes = get_user_present_resources(LUser, LServer),
    case catch lists:max(PrioRes) of
      {Priority, _R}
	  when is_integer(Priority), Priority >= 0 ->
	  lists:foreach(fun ({P, R}) when P == Priority;
					  (P >= 0) and (Type == headline) ->
				LResource = jid:resourceprep(R),
                                Mod = get_sm_backend(LServer),
                                case Mod:get_session(LUser, LServer, LResource) of
                                  {error, notfound} ->
				      ok; % Race condition
				  {ok, Session} ->
				      Pid = element(2, Session#session.sid),
				      ?DEBUG("sending to process ~p~n", [Pid]),
				      ejabberd_cluster:send(
                                        Pid, {route, From, To, Packet})
				end;
			    %% Ignore other priority:
			    ({_Prio, _Res}) -> ok
			end,
			PrioRes);
      _ ->
	  case Type of
	    headline -> ok;
	    _ ->
		case ejabberd_auth:is_user_exists(LUser, LServer) andalso
		    is_privacy_allow(From, To, Packet) of
			true ->
			    ejabberd_hooks:run(offline_message_hook, LServer,
					       [From, To, Packet]);
		  false ->
		      Err = jlib:make_error_reply(Packet,
						  ?ERR_SERVICE_UNAVAILABLE),
		      ejabberd_router:route(To, From, Err)
		end
	  end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

clean_session_list(Ss) ->
    clean_session_list(lists:keysort(#session.usr, Ss), []).

clean_session_list([], Res) -> Res;
clean_session_list([S], Res) -> [S | Res];
clean_session_list([S1, S2 | Rest], Res) ->
    if S1#session.usr == S2#session.usr ->
	   if S1#session.sid > S2#session.sid ->
		  clean_session_list([S1 | Rest], Res);
	      true -> clean_session_list([S2 | Rest], Res)
	   end;
       true -> clean_session_list([S2 | Rest], [S1 | Res])
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% On new session, check if some existing connections need to be replace
check_for_sessions_to_replace(User, Server, NewPid) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    check_max_sessions(LUser, LServer, NewPid).

check_max_sessions(LUser, LServer, NewPid) ->
    Mod = get_sm_backend(LServer),
    SIDs = [S#session.sid || S <- Mod:get_sessions(LUser, LServer)],
    MaxSessions = get_max_user_sessions(LUser, LServer),
    if length(SIDs) =< MaxSessions -> ok;
       true ->
            {_, Pid} = lists:min(SIDs),
            ejabberd_cluster:send(Pid, {replaced, NewPid})
    end.

%% Get the user_max_session setting
%% This option defines the max number of time a given users are allowed to
%% log in
%% Defaults to infinity
get_max_user_sessions(LUser, Host) ->
    case acl:match_rule(Host, max_user_sessions,
			jid:make(LUser, Host, <<"">>))
	of
      Max when is_integer(Max) -> Max;
      infinity -> infinity;
      _ -> ?MAX_USER_SESSIONS
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

process_iq(From, To, Packet) ->
    IQ = jlib:iq_query_info(Packet),
    case IQ of
      #iq{xmlns = XMLNS, lang = Lang} ->
	  Host = To#jid.lserver,
	  case ets:lookup(sm_iqtable, {XMLNS, Host}) of
	    [{_, Module, Function}] ->
		ResIQ = Module:Function(From, To, IQ),
		if ResIQ /= ignore ->
		       ejabberd_router:route(To, From, jlib:iq_to_xml(ResIQ));
		   true -> ok
		end;
	    [{_, Module, Function, Opts1}|Tail] ->
		Opts = if is_pid(Opts1) ->
			[Opts1 | [Pid || {_, _, _, Pid} <- Tail]];
		    true ->
			Opts1
		end,
		gen_iq_handler:handle(Host, Module, Function, Opts,
				      From, To, IQ);
	    [] ->
		Txt = <<"No module is handling this query">>,
		Err = jlib:make_error_reply(
			Packet,
			?ERRT_SERVICE_UNAVAILABLE(Lang, Txt)),
		ejabberd_router:route(To, From, Err)
	  end;
      reply -> ok;
      _ ->
	  Err = jlib:make_error_reply(Packet, ?ERR_BAD_REQUEST),
	  ejabberd_router:route(To, From, Err),
	  ok
    end.

-spec force_update_presence({binary(), binary()}) -> any().

force_update_presence({LUser, LServer}) ->
    Mod = get_sm_backend(LServer),
    Ss = Mod:get_sessions(LUser, LServer),
    lists:foreach(fun (#session{sid = {_, Pid}}) ->
                          ejabberd_cluster:send(
                            Pid, {force_update_presence, LUser, LServer})
                  end,
                  Ss).

-spec get_sm_backend(binary()) -> module().

get_sm_backend(Host) ->
    DBType = ejabberd_config:get_option(
	       {sm_db_type, Host},
	       fun(T) -> ejabberd_config:v_db(?MODULE, T) end,
	       mnesia),
    list_to_atom("ejabberd_sm_" ++ atom_to_list(DBType)).

-spec get_sm_backends() -> [module()].

get_sm_backends() ->
    lists:usort([get_sm_backend(Host) || Host <- ?MYHOSTS]).

-spec get_vh_by_backend(module()) -> [binary()].

get_vh_by_backend(Mod) ->
    lists:filter(
      fun(Host) ->
	      get_sm_backend(Host) == Mod
      end, ?MYHOSTS).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% ejabberd commands

get_commands_spec() ->
    [#ejabberd_commands{name = connected_users, tags = [session],
			desc = "List all established sessions",
                        policy = admin,
			module = ?MODULE, function = connected_users, args = [],
			result_desc = "List of users sessions",
			result_example = [<<"user1@example.com">>, <<"user2@example.com">>],
			result = {connected_users, {list, {sessions, string}}}},
     #ejabberd_commands{name = connected_users_number, tags = [session, stats],
			desc = "Get the number of established sessions",
                        policy = admin,
			module = ?MODULE, function = connected_users_number,
			result_example = 2,
			args = [], result = {num_sessions, integer}},
     #ejabberd_commands{name = user_resources, tags = [session],
			desc = "List user's connected resources",
                        policy = user,
			module = ?MODULE, function = user_resources,
			args = [],
			args_desc = ["User name", "Server name"],
			args_example = [<<"user1">>, <<"example.com">>],
			result_example = [<<"tka1">>, <<"Gajim">>, <<"mobile-app">>],
			result = {resources, {list, {resource, string}}}},
     #ejabberd_commands{name = kick_user, tags = [session],
			desc = "Disconnect user's active sessions",
			module = ?MODULE, function = kick_user,
			args = [{user, binary}, {host, binary}],
			args_desc = ["User name", "Server name"],
			args_example = [<<"user1">>, <<"example.com">>],
			result_desc = "Number of resources that were kicked",
			result_example = 3,
			result = {num_resources, integer}}].

-spec connected_users() -> [binary()].

connected_users() ->
    USRs = dirty_get_sessions_list(),
    SUSRs = lists:sort(USRs),
    lists:map(fun ({U, S, R}) -> <<U/binary, $@, S/binary, $/, R/binary>> end,
	      SUSRs).

connected_users_number() ->
    length(dirty_get_sessions_list()).

get_sessions_number() ->
    lists:sum([Mod:get_sessions_number() || Mod <- get_sm_backends()]).

user_resources(User, Server) ->
    Resources = get_user_resources(User, Server),
    lists:sort(Resources).

get_proc_num() ->
    1000.

get_proc_by_hash(Term) ->
    N = erlang:phash2(Term, get_proc_num()) + 1,
    get_proc(N).

get_proc(N) ->
    jlib:binary_to_atom(<<(iolist_to_binary(atom_to_list(?MODULE)))/binary,
			    "_",
			    (iolist_to_binary(integer_to_list(N)))/binary>>).

start_handlers() ->
    N = get_proc_num(),
    lists:foreach(
      fun(I) ->
              ejabberd_sm_handler:start(get_proc(I))
      end, lists:seq(1, N)).

stop_handlers() ->
    N = get_proc_num(),
    lists:foreach(
      fun(I) ->
              ejabberd_sm_handler:stop(get_proc(I))
      end, lists:seq(1, N)).

dispatch(From, To, Packet, Hops) ->
    #jid{luser = U, lserver = S} = To,
    ejabberd_sm_handler:route(get_proc_by_hash({U, S}), From, To, Packet, Hops).

kick_user(User, Server) ->
    Resources = get_user_resources(User, Server),
    lists:foreach(
	fun(Resource) ->
		PID = get_session_pid(User, Server, Resource),
		PID ! kick
	end, Resources),
    length(Resources).

make_sid() ->
    {p1_time_compat:unique_timestamp(), self()}.

opt_type(resource_conflict) ->
    fun (closeold) -> acceptnew;
	(closenew) -> closenew;
	(acceptnew) -> acceptnew
    end;
opt_type(sm_db_type) -> fun(T) -> ejabberd_config:v_db(?MODULE, T) end;
opt_type(_) -> [resource_conflict, sm_db_type].
