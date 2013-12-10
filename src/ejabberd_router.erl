%%%----------------------------------------------------------------------
%%% File    : ejabberd_router.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Main router
%%% Created : 27 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
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
%%%----------------------------------------------------------------------

-module(ejabberd_router).

-author('alexey@process-one.net').

-behaviour(gen_server).

%% API
-export([route/3, route_error/4, register_route/1,
	 register_route/2, register_routes/1, unregister_route/1,
	 unregister_routes/1, dirty_get_all_routes/0,
	 dirty_get_all_domains/0, make_id/0, get_domain_balancing/1,
         check_consistency/0, merge_pids/3]).

-export([start_link/0]).

%% DHT callbacks
-export([merge_write/2, clean/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-type local_hint() :: undefined | {apply, atom(), atom()}.

-record(route, {domain = <<"">>        :: binary(),
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
      _ -> ok
    end.

%% Route the error packet only if the originating packet is not an error itself.
%% RFC3920 9.3.1
-spec route_error(jid(), jid(), xmlel(), xmlel()) -> ok.

route_error(From, To, ErrPacket, OrigPacket) ->
    #xmlel{attrs = Attrs} = OrigPacket,
    case <<"error">> == xml:get_attr_s(<<"type">>, Attrs) of
      false -> route(From, To, ErrPacket);
      true -> ok
    end.

-spec register_route(binary()) -> term().

register_route(Domain) ->
    register_route(Domain, undefined).

-spec register_route(binary(), local_hint()) -> ok.

register_route(Domain, LocalHint) ->
    case jlib:nameprep(Domain) of
        error ->
            erlang:error({invalid_domain, Domain});
        LDomain when LocalHint /= undefined ->
            mnesia:dirty_write(#route{domain = LDomain,
                                      local_hint = LocalHint});
        LDomain ->
            case mnesia:dirty_read(route, LDomain) of
                [#route{pid = Pids, clock = V1} = R] ->
                    V2 = vclock:increment(node(), V1),
                    NewPids = add_pid(self(), Pids, LDomain),
                    dht:write_everywhere(
                      R#route{clock = V2, pid = NewPids});
                [] ->
                    dht:write_everywhere(
                      #route{clock = vclock:increment(
                                       node(), vclock:fresh()),
                             pid = add_pid(self(), [], LDomain),
                             domain = LDomain});
                _ ->
                    ok
            end
    end.

-spec register_routes([binary()]) -> ok.

register_routes(Domains) ->
    lists:foreach(fun (Domain) -> register_route(Domain)
		  end,
		  Domains).

-spec unregister_route(binary()) -> term().

unregister_route(Domain) ->
    case jlib:nameprep(Domain) of
        error ->
            erlang:error({invalid_domain, Domain});
        LDomain ->
            case mnesia:dirty_read(route, LDomain) of
                [#route{local_hint = LHint}] when LHint /= undefined ->
                    mnesia:dirty_delete(route, LDomain);
                [#route{pid = Pids, clock = V} = R] ->
                    NewPids = del_pid(self(), Pids, LDomain),
                    dht:write_everywhere(
                      R#route{clock = vclock:increment(node(), V),
                              pid = NewPids});
                [] ->
                    ok
            end
    end.

merge_write(#route{pid = Pids1, clock = V1, domain = Domain} = R1,
            #route{pid = Pids2, clock = V2} = R2) ->
    case vclock:descends(V1, V2) of
        true ->
            R1#route{pid = Pids1, clock = V1};
        false ->
            case vclock:descends(V2, V1) of
                true ->
                    R2#route{pid = Pids2, clock = V2};
                false ->
                    V = vclock:merge([V1, V2]),
                    Pids = merge_pids(Pids1, Pids2, Domain),
                    R1#route{pid = Pids, clock = V}
            end
    end.

clean(Node) ->
    lists:foreach(
      fun(#route{pid = []}) ->
              ok;
         (#route{pid = Pids, clock = V, domain = Domain} = R) ->
              NewV = vclock:increment(node(), V),
              NewPids = del_pid_by_node(Node, Pids, Domain),
              mnesia:dirty_write(
                R#route{pid = NewPids, clock = NewV})
      end, ets:tab2list(route)).

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
    dht:new(route, ?MODULE),
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
handle_info(_Info, State) ->
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
    case xml:get_attr_s(<<"id">>, Attrs) of
      << ?ROUTE_PREFIX, Rest/binary>> ->
	  Type = xml:get_attr_s(<<"type">>, Attrs),
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

do_route(OrigFrom, OrigTo, OrigPacket) ->
    ?DEBUG("route~n\tfrom ~p~n\tto ~p~n\tpacket ~p~n",
	   [OrigFrom, OrigTo, OrigPacket]),
    case ejabberd_hooks:run_fold(filter_packet,
				 {OrigFrom, OrigTo, OrigPacket}, []) of
        {From, To, Packet} ->
            LDstDomain = To#jid.lserver,
            case mnesia:dirty_read(route, LDstDomain) of
                [] ->
                    ejabberd_s2s:route(From, To, Packet);
                [#route{pid = [], local_hint = LocalHint}] ->
                    case LocalHint of
                        {apply, Module, Function} ->
                            Module:Function(From, To, Packet);
                        undefined ->
                            ejabberd_s2s:route(From, To, Packet)
                    end;
                [#route{pid = [Pid]}] ->
                    ejabberd_cluster:send(Pid, {route, From, To, Packet});
                [#route{pid = Pids}] ->
                    balancing_route(Pids, From, To, Packet)
            end;
        drop ->
            ?DEBUG("packet dropped~n", []),
            ok
    end.

balancing_route(Pids, From, To, Packet) ->
    LDstDomain = To#jid.lserver,
    Value = case get_domain_balancing(LDstDomain) of
                random -> now();
                source -> jlib:jid_tolower(From);
                destination -> jlib:jid_tolower(To);
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

merge_pids(Pids1, Pids2, Domain) ->
    case get_component_number(Domain) of
        undefined ->
            lists:usort(Pids1 ++ Pids2);
        _N ->
            %% TODO: This is totally wrong and should be rewritten
            D1 = to_orddict(Pids1),
            D2 = to_orddict(Pids2),
            D = orddict:merge(
                  fun(_, Pid, undefined) -> Pid;
                     (_, undefined, Pid) -> Pid;
                     (_, Pid, Pid) -> Pid;
                     (_Node, _Pid1, _Pid2) -> undefined
                  end, D1, D2),
            from_orddict(D)
    end.

to_orddict(Pids) ->
    lists:map(
      fun(Pid) when is_pid(Pid) ->
              {node(Pid), Pid};
         (Node) ->
              {Node, undefined}
      end, Pids).

from_orddict(NodePids) ->
    lists:map(
      fun({Node, undefined}) -> Node;
         ({_, Pid}) -> Pid
      end, NodePids).

add_pid(Pid, Pids, Domain) ->
    merge_pids([Pid], Pids, Domain).

del_pid(Pid, Pids, Domain) ->
    case get_component_number(Domain) of
        undefined ->
            lists:delete(Pid, Pids);
        _ ->
            lists:map(
              fun(P) when P == Pid ->
                      node(P);
                 (P) ->
                      P
              end, Pids)
    end.

del_pid_by_node(Node, Pids, Domain) ->
    case get_component_number(Domain) of
        undefined ->
            lists:filter(fun(P) -> node(P) /= Node end, Pids);
        _ ->
            lists:map(
              fun(P) when node(P) == Node ->
                      Node;
                 (P) ->
                      P
              end, Pids)
    end.

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
    io:format("~s~n", [p1_yaml:encode(Res)]).

update_tables() ->
    case catch mnesia:table_info(route, local_content) of
        false ->
            mnesia:delete_table(route);
        _ ->
            ok
    end,
    case catch mnesia:table_info(route, attributes) of
      [domain, node, pid] -> mnesia:delete_table(route);
      [domain, pid] -> mnesia:delete_table(route);
      [domain, pid, local_hint] -> mnesia:delete_table(route);
      [domain, pid, local_hint, clock] -> ok;
      {'EXIT', _} -> ok
    end,
    case lists:member(local_route,
		      mnesia:system_info(tables))
	of
      true -> mnesia:delete_table(local_route);
      false -> ok
    end.
