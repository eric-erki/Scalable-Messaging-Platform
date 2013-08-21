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
         write/1, write/2, write_everywhere/1, write_everywhere/2,
         delete/1, delete/2]).

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

-spec new(atom(), module()) -> ok.

new(Tab, Mod) ->
    gen_server:cast(?MODULE, {new, Tab, Mod}).

-spec write(record()) -> ok.

write(Obj) ->
    write(Obj, element(2, Obj)).

-spec write(record(), any()) -> ok.

write(Obj, HashKey) ->
    gen_server:call(?MODULE, {write, Obj, HashKey}).

-spec write_everywhere(any()) -> ok.

write_everywhere(Obj) ->
    write_everywhere(Obj, element(2, Obj)).

-spec write_everywhere(record(), any()) -> ok.

write_everywhere(Obj, HashKey) ->
    gen_server:call(?MODULE, {write_everywhere, Obj, HashKey}).

-spec delete(record()) -> ok.

delete(Obj) ->
    delete(Obj, element(2, Obj)).

-spec delete(record(), any()) -> ok.

delete(Obj, HashKey) ->
    gen_server:call(?MODULE, {delete, Obj, HashKey}).

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

handle_call({Tag, Obj, HashKey}, _From, State)
  when Tag == write; Tag == write_everywhere ->
    Key = element(2, Obj),
    Tab = element(1, Obj),
    Nodes = case Tag of
                write ->
                    ejabberd_cluster:get_nodes(HashKey);
                write_everywhere ->
                    everywhere
            end,
    NewObj = try_write(Obj, State#state.tabs),
    send_write(Nodes, NewObj),
    ets:insert(?MODULE, {HashKey, Tab, Key, Nodes}),
    {reply, ok, State};
handle_call({delete, Obj, HashKey}, _From, State) ->
    Key = element(2, Obj),
    Tab = element(1, Obj),
    case ets:lookup(?MODULE, HashKey) of
        [{_, Tab, Key, Nodes}] ->
            ets:delete(?MODULE, HashKey),
            case try_delete(Obj, State#state.tabs) of
                true ->
                    send_delete(Nodes, Obj);
                false ->
                    ok;
                NewObj ->
                    send_write(Nodes, NewObj)
            end;
        _ ->
            ?WARNING_MSG("Attempt to delete object which wasn't "
                         "created via DHT interface: ~p", [Obj]),
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
              fun({Tab, Mod}) ->
                      case catch Mod:clean(Node) of
                          {'EXIT', _} = Err ->
                              ?ERROR_MSG("failed to clean ~p from "
                                         "node ~p: ~p", [Tab, Node, Err]);
                          _ ->
                              ok
                      end
              end, dict:to_list(State#state.tabs));
       true ->
            ok
    end,
    lists:foreach(
      fun({_HashKey, Tab, Key, everywhere}) ->
              case mnesia_read(Tab, Key) of
                  [Obj] when Event == node_up ->
                      send_write([Node], Obj);
                  _ ->
                      ok
              end;
         ({HashKey, Tab, Key, Nodes}) ->
              NewNodes = ejabberd_cluster:get_nodes(HashKey),
              AddNodes = NewNodes -- Nodes,
              case AddNodes of
                  [] ->
                      ok;
                  _ ->
                      case mnesia_read(Tab, Key) of
                          [Obj] ->
                              send_write(AddNodes, Obj);
                          [] ->
                              ok
                      end
              end,
              DelNodes = if Event == node_down -> [Node];
                            true -> []
                         end,
              ets:insert(?MODULE, {HashKey, Tab, Key,
                                   AddNodes ++ Nodes -- DelNodes})
      end, ets:match_object(?MODULE, '_')),
    {noreply, State};
handle_info({replica, delete, Obj}, State) ->
    try_delete(Obj, State#state.tabs),
    {noreply, State};
handle_info({replica, write, Obj}, State) ->
    try_write(Obj, State#state.tabs),
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
send_delete(Nodes, Obj) ->
    send(Nodes, {replica, delete, Obj}).

send_write(Nodes, Obj) ->
    send(Nodes, {replica, write, Obj}).

send(everywhere, Msg) ->
    send(ejabberd_cluster:get_nodes(), Msg);
send(Nodes, Msg) ->
    lists:foreach(
      fun(Node) when Node /= node() ->
              ejabberd_cluster:send({?MODULE, Node},  Msg);
         (_) ->
              ok
      end, Nodes).

try_delete(Obj, Tabs) ->
    Key = element(2, Obj),
    Tab = element(1, Obj),
    case mnesia_read(Tab, Key) of
        [Obj] ->
            mnesia_delete(Tab, Key),
            true;
        [PrevObj] ->
            case dict:find(Tab, Tabs) of
                {ok, Mod} ->
                    case catch Mod:merge_delete(Obj, PrevObj) of
                        {'EXIT', _} = Err ->
                            ?ERROR_MSG("failed to resolve conflict: ~p", [Err]),
                            mnesia_delete(Tab, Key),
                            true;
                        delete ->
                            mnesia_delete(Tab, Key),
                            true;
                        {write, NewObj} ->
                            mnesia_write(NewObj),
                            NewObj;
                        keep ->
                            false
                    end;
                error ->
                    ?ERROR_MSG("failed to resolve conflict: couldn't find "
                               "the callback module for table ~p", [Tab]),
                    mnesia_delete(Tab, Key),
                    true
            end;
        [] ->
            false
    end.

try_write(Obj, Tabs) ->
    Key = element(2, Obj),
    Tab = element(1, Obj),
    case mnesia_read(Tab, Key) of
        [Obj] ->
            mnesia_write(Obj),
            Obj;
        [PrevObj] ->
            case dict:find(Tab, Tabs) of
                {ok, Mod} ->
                    case catch Mod:merge_write(Obj, PrevObj) of
                        {'EXIT', _} = Err ->
                            ?ERROR_MSG("failed to resolve conflict: ~p", [Err]),
                            mnesia_write(Obj),
                            Obj;
                        NewObj ->
                            mnesia_write(NewObj),
                            NewObj
                    end;
                error ->
                    ?ERROR_MSG("failed to resolve conflict: couldn't find "
                               "the callback module for table ~p", [Tab]),
                    mnesia_write(Obj),
                    Obj
            end;
        [] ->
            mnesia_write(Obj),
            Obj
    end.

mnesia_read(Tab, Key) ->
    case catch mnesia:dirty_read(Tab, Key) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("failed to read ~p by ~p: ~p", [Tab, Key, Err]),
            [];
        Res ->
            Res
    end.

mnesia_write(Obj) ->
    case catch mnesia:dirty_write(Obj) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("failed to write ~p: ~p", [Obj, Err]),
            false;
        _ ->
            true
    end.

mnesia_delete(Tab, Key) ->
    case catch mnesia:dirty_delete(Tab, Key) of
        {'EXIT', _} = Err ->
            ?ERROR_MSG("failed to delete ~p by ~p: ~p", [Tab, Key, Err]),
            false;
        _ ->
            true
    end.
