%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <>
%%% @copyright (C) 2013, Evgeniy Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 16 Aug 2013 by Evgeniy Khramtsov <>
%%%-------------------------------------------------------------------
-module(dht).

-behaviour(gen_server).

%% API
-export([start_link/0, new/2, node_up/1, node_down/1,
         write/2, write/3, write_everywhere/2, write_everywhere/3,
         delete/2, delete/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("logger.hrl").

-record(state, {tabs = dict:new() :: dict()}).

%%%===================================================================
%%% API
%%%===================================================================
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec new(atom(), fun((node()) -> any())) -> ok.

new(Tab, EraseFun) ->
    gen_server:cast(?MODULE, {new, Tab, EraseFun}).

-spec write(any(), mfa()) -> ok.

write(Obj, MFA) ->
    write(Obj, MFA, element(2, Obj)).

-spec write(record(), mfa(), any()) -> ok.

write(Obj, MFA, HashKey) ->
    gen_server:call(?MODULE, {write, Obj, HashKey, MFA, self()}).

-spec write_everywhere(any(), mfa()) -> ok.

write_everywhere(Obj, MFA) ->
    write_everywhere(Obj, MFA, element(2, Obj)).

-spec write_everywhere(record(), mfa(), any()) -> ok.

write_everywhere(Obj, MFA, HashKey) ->
    gen_server:call(?MODULE, {write_everywhere, Obj, HashKey, MFA, self()}).

-spec delete(atom(), any()) -> ok.

delete(Tab, Key) ->
    delete(Tab, Key, Key).

-spec delete(atom(), any(), any()) -> ok.

delete(Tab, Key, HashKey) ->
    gen_server:call(?MODULE, {delete, Tab, Key, HashKey, self()}).

-spec node_up(node()) -> ok.

node_up(Node) ->
    gen_server:cast(?MODULE, {node_up, Node}).

-spec node_down(node()) -> ok.

node_down(Node) ->
    gen_server:cast(?MODULE, {node_down, Node}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init([]) ->
    ets:new(?MODULE, [named_table, public]),
    ejabberd_cluster:subscribe(),
    {ok, #state{}}.

handle_call({Tag, Obj, HashKey, MFA, Owner}, _From, State)
  when Tag == write; Tag == write_everywhere ->
    Key = element(2, Obj),
    Tab = element(1, Obj),
    Nodes = case Tag of
                write ->
                    ejabberd_cluster:get_nodes(HashKey);
                write_everywhere ->
                    everywhere
            end,
    NewObj = try_write(Tab, Key, Obj, MFA, Owner),
    send(Nodes, {replica, write, NewObj, MFA, Owner}),
    ets:insert(?MODULE, {{HashKey, Owner}, Tab, Key, MFA, Nodes}),
    {reply, ok, State};
handle_call({delete, Tab, Key, HashKey, Owner}, _From, State) ->
    case ets:lookup(?MODULE, {HashKey, Owner}) of
        [{_, Tab, Key, MFA, Nodes}] ->
            ets:delete(?MODULE, {HashKey, Owner}),
            case try_delete(Tab, Key, MFA, Owner) of
                true ->
                    send(Nodes, {replica, delete, Tab, Key, MFA, Owner});
                false ->
                    ok;
                NewObj ->
                    send(Nodes, {replica, write, NewObj, MFA, Owner})
            end;
        _ ->
            ok
    end,
    {reply, ok, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({new, Tab, F}, State) ->
    Tabs = dict:store(Tab, F, State#state.tabs),
    {noreply, State#state{tabs = Tabs}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Event, Node}, State)
  when Event == node_up; Event == node_down ->
    if Event == node_down ->
            lists:foreach(
              fun({_Tab, EraseFun}) ->
                      EraseFun(Node)
              end, dict:to_list(State#state.tabs));
       true ->
            ok
    end,
    lists:foreach(
      fun({{_HashKey, Owner}, Tab, Key, MFA, everywhere}) ->
              case mnesia:dirty_read(Tab, Key) of
                  [Obj] when Event == node_up ->
                      send([Node], {replica, write, Obj, MFA, Owner});
                  _ ->
                      ok
              end;
         ({{HashKey, Owner}, Tab, Key, MFA, Nodes}) ->
              NewNodes = ejabberd_cluster:get_nodes(HashKey),
              AddNodes = NewNodes -- Nodes,
              case AddNodes of
                  [] ->
                      ok;
                  _ ->
                      case mnesia:dirty_read(Tab, Key) of
                          [Obj] ->
                              send(AddNodes, {replica, write, Obj, MFA, Owner});
                          [] ->
                              ok
                      end
              end,
              DelNodes = if Event == node_down -> [Node];
                            true -> []
                         end,
              ets:insert(?MODULE, {{HashKey, Owner}, Tab, Key, MFA,
                                   AddNodes ++ Nodes -- DelNodes})
      end, ets:match_object(?MODULE, '_')),
    {noreply, State};
handle_info({replica, delete, Tab, Key, MFA, Owner}, State) ->
    try_delete(Tab, Key, MFA, Owner),
    {noreply, State};
handle_info({replica, write, Obj, MFA, Owner}, State) ->
    Tab = element(1, Obj),
    Key = element(2, Obj),
    try_write(Tab, Key, Obj, MFA, Owner),
    {noreply, State};
handle_info(_Info, State) ->
    ?WARNING_MSG("unexpected info ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
send(everywhere, Msg) ->
    send(ejabberd_cluster:get_nodes(), Msg);
send(Nodes, Msg) ->
    lists:foreach(
      fun(Node) when Node /= node() ->
              ejabberd_cluster:send({?MODULE, Node},  Msg);
         (_) ->
              ok
      end, Nodes).

try_delete(Tab, Key, {M, F, A}, Owner) ->
    case mnesia:dirty_read(Tab, Key) of
        [Obj] ->
            case catch apply(M, F, [Obj, Owner|A]) of
                {'EXIT', _} = Err ->
                    ?ERROR_MSG("failed to resolve conflict: ~p", [Err]),
                    mnesia:dirty_delete(Tab, Key),
                    true;
                delete ->
                    mnesia:dirty_delete(Tab, Key),
                    true;
                {write, NewObj} ->
                    mnesia:dirty_write(NewObj),
                    NewObj;
                keep ->
                    false
            end;
        [] ->
            false
    end.

try_write(Tab, Key, NewObj, {M, F, A}, Owner) ->
    case mnesia:dirty_read(Tab, Key) of
        [PrevObj] ->
            case catch apply(M, F, [NewObj, PrevObj, Owner|A]) of
                {'EXIT', _} = Err ->
                    ?ERROR_MSG("failed to resolve conflict: ~p", [Err]),
                    mnesia:dirty_write(NewObj),
                    NewObj;
                Obj ->
                    mnesia:dirty_write(Obj),
                    Obj
            end;
        [] ->
            mnesia:dirty_write(NewObj),
            NewObj
    end.
