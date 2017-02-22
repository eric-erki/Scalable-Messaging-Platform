%%%----------------------------------------------------------------------
%%% File    : ejabberd_cluster.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : Ejabberd clustering management
%%% Created : 2 Apr 2010 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
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

-module(ejabberd_cluster).

-behaviour(ejabberd_config).

-behaviour(gen_fsm).

%% API
-export([start_link/0, node_id/0, get_node_by_id/1,
	 get_nodes/0, join/1, leave/1, boot/0, hash/1,
	 subscribe/0, send/2, call/4, multicall/3, multicall/4,
	 get_known_nodes/0, get_nodes_from_epmd/0, connect/1]).

%% Backward compatibility
-export([get_node/1]).

-export([init/1, connected/2, connected/3,
	 handle_event/3, handle_sync_event/4, handle_info/3,
	 terminate/3, code_change/4, opt_type/1]).

-include("licence.hrl").
-include("ejabberd.hrl").
-include("logger.hrl").

-define(CLUSTER_NODES, cluster_nodes).
-define(CLUSTER_INFO, cluster_info).
-define(NODES_RING, nodes_ring).

-define(MIGRATE_TIMEOUT, timer:minutes(2)).

-record(state, {vclock = vclock:fresh() :: vclock:vclock(),
                subscribers = []        :: [pid()]}).

-record(?NODES_RING, {hash, node}).
-record(cluster_info, {node, last}).

start_link() -> gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_node(term()) -> node().

get_node(_) ->
    node().

-spec get_nodes() -> [node()].

get_nodes() ->
    ets:select(?CLUSTER_NODES, [{{'$1'}, [], ['$1']}]).

-spec get_known_nodes() -> [node()].

get_known_nodes() ->
    mnesia:dirty_all_keys(cluster_info).

node_id() ->
    jlib:integer_to_binary(hash(node())).

-spec get_node_by_id(binary() | integer()) -> node().

get_node_by_id(NodeID) when is_binary(NodeID) ->
    case catch jlib:binary_to_integer(NodeID) of
        {'EXIT', _} -> node();
        I -> get_node_by_id(I)
    end;
get_node_by_id(NodeID) when is_integer(NodeID) ->
    case ets:lookup(?NODES_RING, NodeID) of
        [{_, _, Node}] -> Node;
        [] -> node()
    end.

-spec join(node()) -> ok | {error, not_ready}.

join(Node) ->
    gen_fsm:sync_send_event(?MODULE, {join, Node}).

-spec leave(node()) -> ok.

leave(Node) ->
    lists:foreach(
      fun(N) ->
              send({?MODULE, N}, {leave, Node})
      end, get_nodes()).

-spec subscribe() -> ok | {error, not_ready}.

subscribe() ->
    gen_fsm:send_event(?MODULE, {subscribe, self()}).

-spec send(pid() | atom() | {atom(), node()}, term()) -> boolean().

send(Dst, Msg) ->
    case erlang:send(Dst, Msg, [noconnect, nosuspend]) of
        nosuspend ->
            Node = case Dst of
                       {_, N} -> N;
                       Pid -> node(Pid)
                   end,
            erlang:disconnect_node(Node),
            false;
        noconnect ->
            false;
        _ ->
            true
    end.

-spec call(node(), module(), atom(), [any()]) -> any().

call(Node, Module, Function, Args) ->
    rpc:call(Node, Module, Function, Args, rpc_timeout()).

-spec multicall(module(), atom(), [any()]) -> {list(), [node()]}.

multicall(Module, Function, Args) ->
    multicall(get_nodes(), Module, Function, Args).

-spec multicall([node()], module(), atom(), list()) -> {list(), [node()]}.

multicall(Nodes, Module, Function, Args) ->
    rpc:multicall(Nodes, Module, Function, Args, rpc_timeout()).

-spec boot() -> ok.

boot() ->
    {Ms,Ss,_} = os:timestamp(),
    if ?CHECK_EXPIRATION(Ms, Ss) ->
        gen_fsm:send_event(?MODULE, boot);
       true ->
        ?ERROR_MSG("~s~n", [ejabberd_license:info()]),
        application:stop(ejabberd),
        erlang:halt()
    end.

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================
init([]) ->
    net_kernel:monitor_nodes(true, [{node_type, visible},
                                    nodedown_reason]),
    ets:new(?CLUSTER_NODES, [named_table, public, ordered_set]),
    mnesia:create_table(?NODES_RING,
                        [{ram_copies, [node()]},
                         {type, ordered_set},
			 {local_content, true},
			 {attributes, record_info(fields, ?NODES_RING)}]),
    mnesia:create_table(cluster_info,
                        [{disc_copies, [node()]},
                         {local_content, true},
                         {attributes, record_info(fields, cluster_info)}]),
    mnesia:add_table_copy(?NODES_RING, node(), ram_copies),
    mnesia:add_table_copy(cluster_info, node(), disc_copies),
    add_node(node(), false, []),
    {ok, connected, #state{}}.

connected(boot, State) ->
    VClock = join_nodes(connect(), State#state.vclock),
    self() ! {ping, dict:new()},
    {next_state, connected, State#state{vclock = VClock}};
connected({subscribe, Pid}, State) ->
    Subscribers = [Pid|State#state.subscribers],
    lists:foreach(
      fun(Node) when Node /= node() ->
              Pid ! {node_up, Node};
         (_) ->
              ok
      end, get_nodes()),
    {next_state, connected, State#state{subscribers = Subscribers}};
connected(_Event, State) ->
    {next_state, connected, State}.

connected(get_nodes, _From, State) ->
    Nodes = lists:flatmap(
              fun(Node) ->
                      case mnesia:dirty_read(cluster_info, Node) of
                          [#cluster_info{node = Node, last = Last}] ->
                              [{Node, Last}];
                          [] ->
                              []
                      end
              end, mnesia:dirty_all_keys(cluster_info)),
    {reply, {ok, Nodes}, connected, State};
connected({join, Node}, _From, State) ->
    KnownNodes = mnesia:dirty_all_keys(cluster_info) -- [node()],
    case KnownNodes of
        [] ->
            VClock = join_nodes(connect(Node), State#state.vclock),
            {reply, ok, connected, State#state{vclock = VClock}};
        [_|_] ->
            {reply, {error, already_joined}, connected, State}
    end;
connected(_Event, _From, State) ->
    {reply, {error, badarg}, connected, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(_Event, _From, StateName, State) ->
    Reply = ok,
    {reply, Reply, StateName, State}.

handle_info({nodedown, Node, InfoList}, connected, State) ->
    case mnesia:dirty_read(cluster_info, Node) of
        [] ->
	    ok;
	_ ->
	    Reason = proplists:get_value(nodedown_reason, InfoList),
	    if Reason == disconnect ->
		    ?WARNING_MSG(
		       "Connection with node ~p is overloaded, "
		       "forcing disconnect. If this message occurs "
		       "too frequently, change '+zdbbl' Erlang emulator flag. "
		       "See erl(1) for details. The current value is ~p.",
		       [Node, erlang:system_info(dist_buf_busy_limit) div 1024]);
	       true ->
		    ok
	    end,
	    del_node(Node, Reason, State#state.subscribers)
    end,
    {next_state, connected, State};
handle_info({nodeup, Node, _InfoList}, connected, State) ->
    ?DEBUG("got nodeup from net_kernel for node ~p", [Node]),
    case mnesia:dirty_read(cluster_info, Node) of
        [] ->
            {next_state, connected, State};
        _ ->
            VClock = send_join(Node, State#state.vclock),
            {next_state, connected, State#state{vclock = VClock}}
    end;
handle_info({ping, Nodes}, connected, State) ->
    Self = self(),
    spawn(fun() -> ping(Nodes, Self) end),
    {next_state, connected, State};
handle_info({join, Node, VClock}, connected, State) ->
    SeenEachOther = vclock:get_counter(node(), VClock) > 0
        andalso vclock:get_counter(Node, State#state.vclock) > 0,
    case ?CHECK_NODES(ets:info(?CLUSTER_NODES, size)) andalso
        add_node(Node, SeenEachOther, State#state.subscribers) of
        true ->
            VClock1 = vclock:increment(Node, State#state.vclock),
            VClock2 = send_join(Node, VClock1),
            {next_state, connected, State#state{vclock = VClock2}};
        false ->
            {next_state, connected, State}
    end;
handle_info({leave, Node}, connected, State) when Node == node() ->
    %% Remove ourselves from the cluster
    lists:foreach(
      fun(N) when N /= node() ->
	      del_node(N, left_cluster, State#state.subscribers),
	      mnesia:dirty_delete(cluster_info, N),
              erlang:disconnect_node(N);
         (_) ->
              ok
      end, mnesia:dirty_all_keys(cluster_info)),
    {next_state, connected, State};
handle_info({leave, Node}, connected, State) ->
    del_node(Node, left_cluster, State#state.subscribers),
    mnesia:dirty_delete(cluster_info, Node),
    erlang:disconnect_node(Node),
    {next_state, connected, State};
handle_info(Info, StateName, State) ->
    ?WARNING_MSG("unexpected info ~p in ~p", [Info, StateName]),
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
connect() ->
    Nodes = case mnesia:dirty_all_keys(cluster_info) -- [node()] of
                [] -> get_nodes_from_epmd();
                Ns -> Ns
            end,
    lists:usort(lists:flatten(rpc:pmap({?MODULE, connect}, [], Nodes))).

connect(Node) when Node == node() ->
    [];
connect(Node) ->
    try
        true = net_kernel:connect(Node),
        {ok, Nodes} = gen_fsm:sync_send_event({?MODULE, Node}, get_nodes),
        Nodes
    catch _:_ ->
            []
    end.

join_nodes(Nodes, VClock) ->
    lists:foldl(
      fun({Node, Last}, V) ->
              case mnesia:dirty_read(cluster_info, Node) of
                  [] ->
                      mnesia:dirty_write(#cluster_info{node = Node,
                                                       last = Last});
                  _ ->
                      ok
              end,
              send_join(Node, V)
      end, VClock, Nodes).

send_join(Node, VClock) ->
    NewVClock = vclock:increment(node(), VClock),
    send({?MODULE, Node}, {join, node(), NewVClock}),
    NewVClock.

ping(State, Parent) ->
    NewState = ping_nodes(mnesia:dirty_first(cluster_info), State),
    erlang:send_after(timer:seconds(30), Parent, {ping, NewState}).

ping_nodes('$end_of_table', State) ->
    State;
ping_nodes(Node, State) ->
    NewState = case ets:lookup(?CLUSTER_NODES, Node) of
                   [_|_] ->
                       dict:erase(Node, State);
                   [] ->
                       ping_node(Node, State)
               end,
    ping_nodes(mnesia:dirty_next(cluster_info, Node), NewState).

ping_node(Node, State) ->
    case need_to_ping(Node, State) of
        true ->
            ?INFO_MSG("Connecting to ~p...", [Node]),
            case net_kernel:connect(Node) of
                true ->
                    send(?MODULE, {nodeup, Node, []}),
                    dict:erase(Node, State);
                false ->
                    dict:store(Node, p1_time_compat:timestamp(), State)
            end;
        false ->
            State
    end.

need_to_ping(Node, State) ->
    case dict:find(Node, State) of
        {ok, LastPing} ->
            case mnesia:dirty_read(cluster_info, Node) of
                [#cluster_info{last = LastSeen}] ->
                    Diff1 = timer:now_diff(LastPing, LastSeen),
                    Diff2 = timer:now_diff(p1_time_compat:timestamp(), LastPing),
                    Diff2 >= Diff1;
                [] ->
                    false
            end;
        error ->
            true
    end.

-spec add_node(node(), boolean(), [pid()]) -> boolean().

add_node(Node, SeenEachOther, Subscribers) ->
    case ets:insert_new(?CLUSTER_NODES, {Node}) of
        true ->
            mnesia:dirty_write(#cluster_info{node = Node, last = p1_time_compat:timestamp()}),
            add_node_to_ring(Node),
            if Node /= node(), SeenEachOther == false ->
                    ?INFO_MSG("Node ~p has joined", [Node]),
                    lists:foreach(
                      fun(Subscriber) ->
                              send(Subscriber, {node_up, Node})
                      end, Subscribers),
                    true;
               Node /= node(), SeenEachOther == true ->
                    ?INFO_MSG("Node ~p has re-joined after network partition",
                              [Node]),
                    lists:foreach(
                      fun(Subscriber) ->
                              send(Subscriber, {node_up, Node})
                      end, Subscribers),
                    true;
               true ->
                    false
            end;
        false ->
            false
    end.

-spec del_node(node(), atom(), [pid()]) -> boolean().

del_node(Node, Reason, Subscribers) ->
    case ets:lookup(?CLUSTER_NODES, Node) of
        [] ->
            false;
        _ ->
	    mnesia:dirty_write(#cluster_info{node = Node, last = p1_time_compat:timestamp()}),
            ets:delete(?CLUSTER_NODES, Node),
            del_node_from_ring(Node),
            if Node /= node() ->
                    ?INFO_MSG("Node ~p has left: ~p", [Node, Reason]),
                    lists:foreach(
                      fun(Subscriber) ->
                              send(Subscriber, {node_down, Node})
                      end, Subscribers),
                    true;
               true ->
                    false
            end
    end.

add_node_to_ring(Node) ->
    mnesia:transaction(
      fun() ->
              mnesia:write({?NODES_RING, hash(Node), Node})
      end).

del_node_from_ring(Node) ->
    mnesia:transaction(
      fun() ->
              mnesia:delete({?NODES_RING, hash(Node)})
      end).

hash(Term) when is_binary(Term) ->
    <<Hash:160>> = crypto:hash(sha, Term),
    Hash;
hash(Term) ->
    hash(term_to_binary(Term)).

rpc_timeout() ->
    try
        timer:seconds(
          ejabberd_config:get_option(
            rpc_timeout,
            fun(T) when is_integer(T), T>0 -> T end,
            5))
    catch error:badarg ->
            timer:seconds(5)
    end.

get_nodes_from_epmd() ->
    get_nodes_from_epmd(
      ejabberd_config:get_option(
        boot_from_epmd,
        fun(true) -> true;
           (false) -> false
        end, false)).

get_nodes_from_epmd(true) ->
    HostSuffix = case string:tokens(atom_to_list(node()), "@") of
                     [_, H] -> "@" ++ H;
                     _ -> ""
                 end,
    Ss = [string:tokens(S, " ")
          || S <- string:tokens(os:cmd("epmd -names"), "\n")],
    lists:flatmap(
      fun(["name", NodeS|_]) ->
              case string:tokens(NodeS, "@") of
                  [_, _] -> [list_to_atom(NodeS)];
                  [Name] -> [list_to_atom(Name ++ HostSuffix)]
              end;
         (_) ->
              []
      end, Ss);
get_nodes_from_epmd(false) ->
    [].

opt_type(boot_from_epmd) ->
    fun (true) -> true;
	(false) -> false
    end;
opt_type(rpc_timeout) ->
    fun (T) when is_integer(T), T > 0 -> T end;
opt_type(_) -> [boot_from_epmd, rpc_timeout].
