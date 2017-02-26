%%%----------------------------------------------------------------------
%%% File    : ejabberd_router.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Main router
%%% Created : 27 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_router).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-behaviour(gen_server).

%% API
-export([route/3,
	 route_error/4,
	 register_route/1,
	 register_route/2,
	 register_route/3,
	 register_routes/1,
	 host_of_route/1,
	 unregister_route/1,
	 unregister_routes/1,
	 dirty_get_all_routes/0,
	 dirty_get_all_domains/0,
         is_my_route/1,
	 make_id/0,
	 get_domain_balancing/1,
	 check_consistency/0]).

-export([start_link/0]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-type local_hint() :: undefined | {apply, atom(), atom()}.

-record(route, {domain = <<"">>        :: binary(),
		server_host = <<"">>   :: binary(),
                pid = []               :: [pid()],
                local_hint             :: local_hint(),
                clock = vclock:fresh() :: vclock:vclock()}).

-record(state, {}).

-define(ROUTE_PREFIX, "rr-").

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec route(jid(), jid(), xmlel()) -> ok.

route(From, To, Packet) ->
    case catch route_check_id(From, To, Packet) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p~nwhen processing: ~p",
		       [Reason, {From, To, Packet}]);
	_ ->
	    ok
    end.

%% Route the error packet only if the originating packet is not an error itself.
%% RFC3920 9.3.1
-spec route_error(jid(), jid(), xmlel(), xmlel()) -> ok.

route_error(From, To, ErrPacket, OrigPacket) ->
    #xmlel{attrs = Attrs} = OrigPacket,
    case <<"error">> == fxml:get_attr_s(<<"type">>, Attrs) of
      false -> route(From, To, ErrPacket);
      true -> ok
    end.

-spec register_route(binary()) -> term().

register_route(Domain) ->
    ?WARNING_MSG("~s:register_route/1 is deprected, "
		 "use ~s:register_route/2 instead",
		 [?MODULE, ?MODULE]),
    register_route(Domain, ?MYNAME).

-spec register_route(binary(), binary()) -> term().

register_route(Domain, ServerHost) ->
    register_route(Domain, ServerHost, undefined).

-spec register_route(binary(), binary(), local_hint()) -> ok.

register_route(Domain, ServerHost, LocalHint) ->
    case {jid:nameprep(Domain), jid:nameprep(ServerHost)} of
	{error, _} ->
	    erlang:error({invalid_domain, Domain});
	{_, error} ->
	    erlang:error({invalid_domain, ServerHost});
        {LDomain, LServerHost} when LocalHint /= undefined ->
            mnesia:dirty_write(#route{domain = LDomain,
				      server_host = LServerHost,
                                      local_hint = LocalHint});
        {LDomain, LServerHost} ->
	    Msg = {register_route, self(), LDomain, LServerHost},
	    lists:foreach(
	      fun(Node) when Node == node() ->
		      gen_server:call(?MODULE, Msg);
		 (Node) ->
		      ejabberd_cluster:send({?MODULE, Node}, Msg)
	      end, ejabberd_cluster:get_nodes())
    end.

-spec register_routes([{binary(), binary()}]) -> ok.

register_routes(Domains) ->
    lists:foreach(fun ({Domain, ServerHost}) -> register_route(Domain, ServerHost)
		  end,
		  Domains).

-spec unregister_route(binary()) -> term().

unregister_route(Domain) ->
    case jid:nameprep(Domain) of
        error ->
            erlang:error({invalid_domain, Domain});
        LDomain ->
            case mnesia:dirty_read(route, LDomain) of
                [#route{local_hint = LHint}] when LHint /= undefined ->
                    mnesia:dirty_delete(route, LDomain);
                [_] ->
		    Msg = {unregister_route, node(), LDomain},
		    lists:foreach(
		      fun(Node) when Node == node() ->
			      gen_server:call(?MODULE, Msg);
			 (Node) ->
			      ejabberd_cluster:send({?MODULE, Node}, Msg)
		      end, ejabberd_cluster:get_nodes());
		[] ->
                    ok
            end
    end.

add_route(Pid, LDomain, LServerHost) ->
    case mnesia:dirty_read(route, LDomain) of
	[R] ->
	    Pids = lists:usort([Pid|R#route.pid]),
	    mnesia:dirty_write(R#route{pid = Pids});
	[] ->
	    mnesia:dirty_write(#route{pid = [Pid], domain = LDomain,
				      server_host = LServerHost})
    end.

del_route(Node, LDomain) ->
    case mnesia:dirty_read(route, LDomain) of
	[R] ->
	    case lists:filter(fun(P) -> node(P) /= Node end, R#route.pid) of
		[] ->
		    mnesia:dirty_delete(route, LDomain);
		Pids ->
		    mnesia:dirty_write(R#route{pid = Pids})
	    end;
	[] ->
	    ok
    end.

-spec unregister_routes([binary()]) -> ok.

unregister_routes(Domains) ->
    lists:foreach(fun (Domain) -> unregister_route(Domain)
		  end,
		  Domains).

-spec dirty_get_all_routes() -> [binary()].

dirty_get_all_routes() ->
    lists:usort(mnesia:dirty_all_keys(route)) -- (?MYHOSTS).

-spec dirty_get_all_domains() -> [binary()].

dirty_get_all_domains() ->
    lists:usort(mnesia:dirty_all_keys(route)).

-spec make_id() -> binary().

make_id() ->
    <<?ROUTE_PREFIX, (randoms:get_string())/binary,
      "-", (ejabberd_cluster:node_id())/binary>>.

-spec host_of_route(binary()) -> binary().

host_of_route(Domain) ->
    case jid:nameprep(Domain) of
	error ->
	    erlang:error({invalid_domain, Domain});
	LDomain ->
	    case mnesia:dirty_read(route, LDomain) of
		[#route{server_host = ServerHost}|_] ->
		    ServerHost;
		[] ->
		    erlang:error({unregistered_route, Domain})
	    end
    end.

-spec is_my_route(binary()) -> boolean().
is_my_route(Domain) ->
    case jid:nameprep(Domain) of
	error ->
	    erlang:error({invalid_domain, Domain});
	LDomain ->
	    mnesia:dirty_read(route, LDomain) /= []
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([]) ->
    update_tables(),
    mnesia:create_table(route,
			[{ram_copies, [node()]},
			 {local_content, true},
			 {attributes, record_info(fields, route)}]),
    mnesia:add_table_copy(route, node(), ram_copies),
    ejabberd_cluster:subscribe(),
    {ok, #state{}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({register_route, Pid, LDomain, LServerHost}, _From, State) ->
    Res = add_route(Pid, LDomain, LServerHost),
    {reply, Res, State};
handle_call({unregister_route, Node, LDomain}, _From, State) ->
    Res = del_route(Node, LDomain),
    {reply, Res, State};
handle_call(_Request, _From, State) ->
    Reply = ok, {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) -> {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route, From, To, Packet}, State) ->
    case catch do_route(From, To, Packet) of
      {'EXIT', Reason} ->
	  ?ERROR_MSG("~p~nwhen processing: ~p",
		     [Reason, {From, To, Packet}]);
      _ -> ok
    end,
    {noreply, State};
handle_info({register_route, Pid, LDomain, LServerHost}, State) ->
    add_route(Pid, LDomain, LServerHost),
    {noreply, State};
handle_info({unregister_route, Node, LDomain}, State) ->
    del_route(Node, LDomain),
    {noreply, State};
handle_info({node_up, Node}, State) ->
    lists:foreach(
      fun(#route{local_hint = undefined} = R) ->
	      Pids = lists:filter(fun(P) -> node(P) == node() end, R#route.pid),
	      lists:foreach(
		fun(P) ->
			Msg = {register_route, P, R#route.domain, R#route.server_host},
			ejabberd_cluster:send({?MODULE, Node}, Msg)
		end, Pids);
	 (_) ->
	      ok
      end, ets:tab2list(route)),
    {noreply, State};
handle_info({node_down, Node}, State) ->
    lists:foreach(
      fun(#route{local_hint = undefined} = R) ->
	      del_route(Node, R#route.domain);
	 (_) ->
	      ok
      end, ets:tab2list(route)),
    {noreply, State};
handle_info(_Info, State) ->
    ?ERROR_MSG("got unexpected info: ~p", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

route_check_id(From, To,
	       #xmlel{name = <<"iq">>, attrs = Attrs} = Packet) ->
    case fxml:get_attr_s(<<"id">>, Attrs) of
      << ?ROUTE_PREFIX, Rest/binary>> ->
	  Type = fxml:get_attr_s(<<"type">>, Attrs),
	  if Type == <<"error">>; Type == <<"result">> ->
		 case str:tokens(Rest, <<"-">>) of
		   [_, NodeID] ->
		       case ejabberd_cluster:get_node_by_id(NodeID) of
			 Node when Node == node() -> do_route(From, To, Packet);
			 Node ->
			     ejabberd_cluster:send(
                               {ejabberd_router, Node},
                               {route, From, To, Packet})
		       end;
		   _ -> do_route(From, To, Packet)
		 end;
	     true -> do_route(From, To, Packet)
	  end;
      _ -> do_route(From, To, Packet)
    end;
route_check_id(From, To, Packet) ->
    do_route(From, To, Packet).

do_route(From, To, Packet) ->
    do_route(From, To, Packet, _IsBounce = false).

do_route(OrigFrom, OrigTo, OrigPacket, IsBounce) ->
    ?DEBUG("route~n\tfrom ~s~n\tto ~s~n\tpacket ~p~n",
	   [jid:to_string(OrigFrom),
	    jid:to_string(OrigTo),
	    OrigPacket]),
    case ejabberd_hooks:run_fold(filter_packet,
				 {OrigFrom, OrigTo, OrigPacket}, []) of
        {From, To, Packet} ->
            LDstDomain = To#jid.lserver,
	    LSrcDomain = From#jid.lserver,
            case mnesia:dirty_read(route, LDstDomain) of
                [] ->
                    ejabberd_s2s:route(From, To, Packet);
                [#route{pid = [], local_hint = LocalHint}] ->
                    case LocalHint of
                        {apply, Module, Function} ->
			    case allow_host(LSrcDomain, LDstDomain, IsBounce) of
				true ->
				    Module:Function(From, To, Packet);
				false ->
				    bounce_packet(From, To, Packet)
			    end;
                        undefined ->
                            ejabberd_s2s:route(From, To, Packet)
                    end;
                [#route{pid = Pids}] ->
		    case allow_host(LSrcDomain, LDstDomain, IsBounce) of
			false ->
			    bounce_packet(From, To, Packet);
			true ->
			    case ejabberd_local:process_iq_reply(From, To, Packet) of
				nothing ->
				    balancing_route(Pids, From, To, Packet);
				ok ->
				    ok
			    end
		    end
            end;
        drop ->
            ?DEBUG("packet dropped~n", []),
            ok
    end.

allow_host(_FromHost, _ToHost, _IsBounce = true) ->
    true;
allow_host(FromHost, ToHost, _IsBounce = false) ->
    case {mnesia:dirty_read(route, FromHost),
	  mnesia:dirty_read(route, ToHost)} of
	{[#route{pid = [], local_hint = {apply, _Mod1, _Fun1}}],
	 [#route{pid = [], local_hint = {apply, _Mod2, _Fun2}}]} ->
	    allow_host1(FromHost, ToHost) andalso allow_host1(ToHost, FromHost);
	{[#route{pid = [], local_hint = {apply, _Mod, _Fun}}], [_|_]} ->
	    allow_host1(FromHost, ToHost);
	{[_|_], [#route{pid = [], local_hint = {apply, _Mod, _Fun}}]} ->
	    allow_host1(ToHost, FromHost);
	_ ->
	    true
    end.

allow_host1(MyHost, VHost) ->
    Rule = ejabberd_config:get_option(
	     {host_access, MyHost},
	     fun(A) -> A end,
	     all),
    JID = jid:make(<<"">>, VHost, <<"">>),
    acl:match_rule(MyHost, Rule, JID) == allow.

bounce_packet(From, To, #xmlel{attrs = Attrs} = Packet) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    if Type == <<"error">>; Type == <<"result">> ->
	    ?DEBUG("packet dropped~n", []),
	    ok;
       true ->
	    Err = jlib:make_error_reply(Packet, ?ERR_SERVICE_UNAVAILABLE),
	    do_route(To, From, Err, true)
    end.

balancing_route([Pid], From, To, Packet) ->
    ejabberd_cluster:send(Pid, {route, From, To, Packet});
balancing_route(Pids, From, To, Packet) ->
    LDstDomain = To#jid.lserver,
    Value = case get_domain_balancing(LDstDomain) of
                random -> p1_time_compat:monotonic_time();
                source -> jid:tolower(From);
                destination -> jid:tolower(To);
                bare_source -> {From#jid.luser, From#jid.lserver};
                bare_destination -> {To#jid.luser, To#jid.lserver};
                broadcast -> broadcast
            end,
    if Value == broadcast ->
            lists:foreach(
              fun(Pid) ->
                      ejabberd_cluster:send(Pid, {route, From, To, Packet})
              end, Pids);
       true ->
            case get_component_number(LDstDomain) of
                undefined ->
                    Node = ejabberd_cluster:get_node(Value),
                    case lists:any(
                           fun(Pid) when node(Pid) == Node ->
                                   ejabberd_cluster:send(
                                     Pid, {route, From, To, Packet});
                              (_) ->
                                   false
                           end, Pids) of
                        true ->
                            ok;
                        false ->
                            N = erlang:phash(Value, length(Pids)),
                            Pid = lists:nth(N, Pids),
                            ejabberd_cluster:send(
                              Pid, {route, From, To, Packet})
                    end;
                _ ->
                    Pid = lists:nth(erlang:phash(Value, length(Pids)), Pids),
                    if is_pid(Pid) ->
                            ejabberd_cluster:send(
                              Pid, {route, From, To, Packet});
                       true ->
                            Err = jlib:make_error_reply(
                                    Packet, ?ERR_SERVICE_UNAVAILABLE),
                            route_error(To, From, Err, Packet)
                    end
            end
    end.

get_component_number(LDomain) ->
    ejabberd_config:get_option(
      {domain_balancing_component_number, LDomain},
      fun(N) when is_integer(N), N > 1 -> N end,
      undefined).

get_domain_balancing(LDomain) ->
    ejabberd_config:get_option(
      {domain_balancing, LDomain},
      fun(random) -> random;
         (source) -> source;
         (destination) -> destination;
         (bare_source) -> bare_source;
         (bare_destination) -> bare_destination;
         (broadcast) -> broadcast
      end, bare_destination).

check_consistency() ->
    Rs = lists:flatmap(
           fun(Node) ->
                   Rs = rpc:call(Node, ets, tab2list, [route]),
                   lists:flatmap(
                     fun(#route{domain = Domain, pid = [_|_] = Pids}) ->
                             [{{Domain, Pids}, Node}];
                        (_) ->
                             []
                     end, Rs)
           end, ejabberd_cluster:get_nodes()),
    D = lists:foldl(
          fun({DomainPids, Nodes}, Acc) ->
                  dict:append(DomainPids, Nodes, Acc)
          end, dict:new(), Rs),
    Res = [{Domain, Nodes} || {{Domain, _}, Nodes} <- dict:to_list(D)],
    io:format("~s~n", [fast_yaml:encode(Res)]).

update_tables() ->
    case catch mnesia:table_info(route, local_content) of
        false ->
            mnesia:delete_table(route);
        _ ->
            ok
    end,
    try
	mnesia:transform_table(route, ignore, record_info(fields, route))
    catch exit:{aborted, {no_exists, _}} ->
	    ok
    end,
    case lists:member(local_route,
		      mnesia:system_info(tables))
	of
      true -> mnesia:delete_table(local_route);
      false -> ok
    end.

opt_type(domain_balancing) ->
    fun (random) -> random;
	(source) -> source;
	(destination) -> destination;
	(bare_source) -> bare_source;
	(bare_destination) -> bare_destination;
	(broadcast) -> broadcast
    end;
opt_type(domain_balancing_component_number) ->
    fun (N) when is_integer(N), N > 1 -> N end;
opt_type(host_access) -> fun acl:access_rules_validator/1;
opt_type(_) ->
    [domain_balancing, domain_balancing_component_number,
     host_access].
