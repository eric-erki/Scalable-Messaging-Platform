%%%-------------------------------------------------------------------
%%% File    : ejabberd_cluster.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Description :
%%%
%%% Created :  2 Apr 2010 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(ejabberd_cluster).

-behaviour(gen_fsm).

%% API
-export([start_link/0, get_node/1, node_id/0, get_node_by_id/1,
	 get_nodes/0, get_nodes/1, join/1, leave/1,
         subscribe/0, send/2, call/4, multicall/3, multicall/4,
         get_nodes_from_epmd/0, connect/1, get_next_node/0]).

%% gen_fsm callbacks
-export([init/1, booting/2, booting/3, connected/2, connected/3,
         handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

-include("ejabberd.hrl").
-include("logger.hrl").

-define(NODES_TBL, cluster_nodes).
-define(CLUSTER_INFO, cluster_info).
-define(HASHTBL, nodes_hash).

-define(MIGRATE_TIMEOUT, timer:minutes(2)).

-record(state, {vclock = vclock:fresh() :: vclock:vclock(),
                subscribers = []        :: [pid()]}).

-record(?HASHTBL, {hash, node}).
-record(cluster_info, {node, last}).

start_link() -> gen_fsm:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_node(any()) -> node().

get_node(Key) ->
    Hash = hash(Key),
    get_node_by_hash(Hash).

-spec get_next_node() -> node().

get_next_node() ->
    Hash = hash(node()),
    get_node_by_hash(Hash).

-spec get_nodes() -> [node()].

get_nodes() ->
    ets:select(?NODES_TBL, [{{'$1'}, [], ['$1']}]).

-spec get_nodes(any()) -> [node()].

get_nodes(Key) ->
    Hash = hash(Key),
    NodesNum = ets:info(?NODES_TBL, size),
    ReplicasNum = case configured_replicas_number() of
                      auto -> log2(NodesNum);
                      N -> lists:min([N, NodesNum])
                  end,
    get_nodes_by_hash(Hash, ReplicasNum).

node_id() ->
    erlang:integer_to_binary(hash(node())).

-spec get_node_by_id(binary() | atom()) -> node().

get_node_by_id(NodeID) when is_binary(NodeID) ->
    case catch list_to_existing_atom(binary_to_list(NodeID)) of
      {'EXIT', _} -> node();
      Res -> get_node_by_id(Res)
    end;
get_node_by_id(NodeID) ->
    case global:whereis_name(NodeID) of
      Pid when is_pid(Pid) -> node(Pid);
      _ -> node()
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

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================
init([]) ->
    gen_fsm:send_event(self(), boot),
    net_kernel:monitor_nodes(true, [{node_type, visible},
                                    nodedown_reason]),
    ets:new(?NODES_TBL, [named_table, public, ordered_set]),
    mnesia:create_table(?HASHTBL,
                        [{ram_copies, [node()]},
                         {type, ordered_set},
			 {local_content, true},
			 {attributes, record_info(fields, ?HASHTBL)}]),
    mnesia:create_table(cluster_info,
                        [{disc_copies, [node()]},
                         {local_content, true},
                         {attributes, record_info(fields, cluster_info)}]),
    mnesia:add_table_copy(?HASHTBL, node(), ram_copies),
    mnesia:add_table_copy(cluster_info, node(), disc_copies),
    mnesia:clear_table(?HASHTBL),
    add_node(node(), false, []),
    register_node(),
    {ok, booting, #state{}}.

booting(boot, State) ->
    VClock = join_nodes(connect(), State#state.vclock),
    self() ! {ping, dict:new()},
    {next_state, connected, State#state{vclock = VClock}};
booting(_Event, State) ->
    {next_state, booting, State}.

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

booting(_Event, _From, State) ->
    {reply, {error, not_ready}, booting, State}.

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
    del_node(Node, Reason, State#state.subscribers),
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
    case add_node(Node, SeenEachOther, State#state.subscribers) of
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
              mnesia:dirty_delete(cluster_info, N),
              erlang:disconnect_node(N);
         (_) ->
              ok
      end, mnesia:dirty_all_keys(cluster_info)),
    {next_state, connected, State};
handle_info({leave, Node}, connected, State) ->
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
    NewState = case ets:lookup(?NODES_TBL, Node) of
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
                    dict:store(Node, now(), State)
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
                    Diff2 = timer:now_diff(now(), LastPing),
                    Diff2 >= Diff1;
                [] ->
                    false
            end;
        error ->
            true
    end.

-spec add_node(node(), boolean(), [pid()]) -> boolean().

add_node(Node, SeenEachOther, Subscribers) ->
    case ets:insert_new(?NODES_TBL, {Node}) of
        true ->
            Hash = hash(Node),
            mnesia:dirty_write(#cluster_info{node = Node, last = now()}),
            mnesia:dirty_write({?HASHTBL, Hash, Node}),
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
    case ets:lookup(?NODES_TBL, Node) of
        [] ->
            false;
        _ ->
            ets:delete(?NODES_TBL, Node),
            Hash = hash(Node),
            mnesia:dirty_delete(?HASHTBL, Hash),
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

hash(Term) when is_binary(Term) ->
    <<Hash:160>> = crypto:sha(Term),
    Hash;
hash(Term) ->
    hash(term_to_binary(Term)).

register_node() ->
    global:register_name(erlang:binary_to_atom(node_id(), utf8), self()).

get_node_by_hash(Tab, Hash) ->
    NodeHash = case ets:next(Tab, Hash) of
		 '$end_of_table' -> ets:first(Tab);
		 NH -> NH
	       end,
    if NodeHash == '$end_of_table' ->
            node();
       true ->
	    case ets:lookup(Tab, NodeHash) of
		[] ->
		    get_node_by_hash(Tab, Hash);
		[{_, _, Node}] ->
		    Node
	    end
    end.

get_node_by_hash(Hash) ->
    {_, _, Node} = get_next_node_by_hash(Hash),
    Node.

get_next_node_by_hash(Hash) ->
    NodeHash = case ets:next(?HASHTBL, Hash) of
		   '$end_of_table' ->
		       ets:first(?HASHTBL);
		   NH ->
		       NH
	       end,
    if NodeHash == '$end_of_table' ->
	    erlang:error(no_running_nodes);
       true ->
	    case ets:lookup(?HASHTBL, NodeHash) of
		[] ->
		    get_node_by_hash(?HASHTBL, Hash);
		[{_, _Hash, _Node} = Res] ->
		    Res
	    end
    end.

get_nodes_by_hash(_Hash, 0) ->
    [];
get_nodes_by_hash(Hash, K) ->
    {_, NHash, Node} = get_next_node_by_hash(Hash),
    [Node | get_nodes_by_hash(NHash+1, K - 1)].

log2(N) ->
    case round(math:log(N) / math:log(2)) of
        0 -> 1;
        Log -> Log
    end.

rpc_timeout() ->
    timer:seconds(
      ejabberd_config:get_option(
        rpc_timeout,
        fun(T) when is_integer(T), T>0 -> T end,
        5)).

configured_replicas_number() ->
    ejabberd_config:get_option(
      replicas_number,
      fun(I) when is_integer(I), I>0 ->
              I;
         (auto) ->
              auto
      end, auto).

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
