%%%-------------------------------------------------------------------
%%% File    : mod_mon.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Event monitor for runtime statistics
%%% Created : 10 Apr 2014 by Christophe Romain <christophe.romain@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
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
%%%-------------------------------------------------------------------

-module(mod_mon).

-behaviour(ejabberd_config).
-author('christophe.romain@process-one.net').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("ejabberd_commands.hrl").
-include("mod_mon.hrl").

-define(PROCNAME, ?MODULE).
-define(CALL_TIMEOUT, 4000).

%% module API
-export([start_link/2, start/2, stop/1]).
-export([value/2, dump/1, declare/3, drop/2, info/1]).
-export([reset/2, set/3, inc/3, dec/3, sum/3]).
%% sync commands
-export([flush_log/3, sync_log/1, push_metrics/2]).
%% administration commands
-export([active_counters_command/1, flush_probe_command/2]).
%% monitors
-export([process_queues/2, internal_queues/2, health_check/1, jabs_count/1]).
-export([cpu_usage/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([offline_message_hook/3,
	 resend_offline_messages_hook/3,
	 sm_register_connection_hook/3,
	 sm_remove_connection_hook/3, roster_in_subscription/6,
	 roster_out_subscription/4, user_available_hook/1,
	 unset_presence_hook/4, set_presence_hook/4,
	 user_send_packet/4, user_receive_packet/5,
	 c2s_replaced/1, s2s_send_packet/3, s2s_receive_packet/3,
	 privacy_iq_set/4, privacy_iq_get/5, remove_user/2,
	 register_user/2, api_call/3, backend_api_call/3,
	 backend_api_response_time/4, backend_api_timeout/3,
	 backend_api_error/3, backend_api_badauth/3,
	 pubsub_create_node/5, pubsub_delete_node/4,
	 pubsub_publish_item/6, mod_opt_type/1, opt_type/1]).
         %pubsub_broadcast_stanza/4, get_commands_spec/0 ]).

% dictionary command overrided for better control
-compile({no_auto_import, [get/1]}).

-record(mon, {probe, value}).
-record(state, {host, active_count, backends, monitors, log, timers=[]}).

%%====================================================================
%% API
%%====================================================================

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
                 temporary, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

value(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {get, Probe}, ?CALL_TIMEOUT).

set(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, {set, Probe, Value}).

inc(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, {inc, Probe, Value}).

dec(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, {dec, Probe, Value}).

sum(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, {sum, Probe, Value}).

reset(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {reset, Probe}).

dump(Host) when is_binary(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, dump, ?CALL_TIMEOUT).

declare(Host, Probe, Type) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {declare, Probe, Type}, ?CALL_TIMEOUT).

drop(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {drop, Probe}, ?CALL_TIMEOUT).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Opts]) ->
    % List enabled monitors, defaults all
    MonitorsBase = gen_mod:get_opt(monitors_base, Opts,
                               fun(L) when is_list(L) -> L end,
                               ?DEFAULT_MONITORS),
    Monitors = gen_mod:get_opt(monitors, Opts,
                               fun(L) when is_list(L) -> L end,
                               []) ++ MonitorsBase,

    % List enabled hooks, defaults all supported hooks
    Hooks = gen_mod:get_opt(hooks, Opts,
                               fun(L) when is_list(L) -> L end,
                               ?SUPPORTED_HOOKS),
    % Active users counting uses hyperloglog structures
    ActiveCount = gen_mod:get_opt(active_count, Opts,
                                  fun(B) when is_boolean(B) -> B end,
                                  true)
                  and not ejabberd_auth_anonymous:allow_anonymous(Host),
    Log = init_log(Host, ActiveCount),

    % Statistics backends
    BackendsSpec = gen_mod:get_opt(backends, Opts,
                                   fun(List) when is_list(List) -> List
                                   end, []),
    Backends = lists:usort([init_backend(Host, Spec)
                            || Spec <- lists:flatten(BackendsSpec)]),

    %% Note: we use priority of 20 cause some modules can block execution of hooks
    %% example; mod_offline stops the hook if it stores packets
    %Components = [Dom || Dom <- mnesia:dirty_all_keys(route),
    %                     lists:suffix(
    %                        str:tokens(Dom, <<".">>),
    %                        str:tokens(Host, <<".">>))],
    [ejabberd_hooks:add(Hook, Component, ?MODULE, Hook, 20)
     || Component <- [Host], % Todo, Components for muc and pubsub
        Hook <- Hooks],
    ejabberd_commands:register_commands(get_commands_spec()),

    % Store probes specs
    ets:new(mon_probes, [named_table, public]),
    [ets:insert(mon_probes, {Probe, gauge}) || Probe<-?GAUGES],

    % Start timers for cache and backends sync
    {ok, TSync} = timer:apply_interval(?HOUR, ?MODULE, sync_log, [Host]),
    {ok, TPush} = timer:apply_interval(?MINUTE, ?MODULE, push_metrics, [Host, Backends]),

    {ok, #state{host = Host,
                active_count = ActiveCount,
                backends = Backends,
                monitors = Monitors,
                log = Log,
                timers = [TSync, TPush]}}.

handle_call({get, log}, _From, State) ->
    {reply, State#state.log, State};
handle_call({get, Probe}, _From, State) ->
    Ret = case get(Probe) of
        {Sum, Count} -> Sum div Count;
        Value -> Value
    end,
    {reply, Ret, State};
handle_call({reset, Probe}, _From, State) ->
    OldVal = get(Probe),
    IsLog = State#state.active_count andalso lists:member(Probe, ?HYPERLOGLOGS),
    [put(Probe, 0) || OldVal =/= 0],
    [flush_log(State#state.host, Probe) || IsLog],
    {reply, OldVal, State};
handle_call(dump, _From, State) ->
    {reply, get(), State};
handle_call(snapshot, _From, State) ->
    Host = State#state.host,
    Probes = compute_probes(Host, State#state.monitors),
    ExtProbes = ejabberd_hooks:run_fold(mon_monitors, Host, [], [Host]),
    [put(Key, 0) || {Key, Type, Val} <- Probes ++ ExtProbes,
                    Val =/= 0, Type == counter],
    {reply, Probes++ExtProbes, State};
handle_call({declare, Probe, Type}, _From, State) ->
    Result = case Type of
        gauge ->
            declare_gauge(Probe),
            put(Probe, 0),
            ok;
        counter ->
            put(Probe, 0),
            ok;
        _ ->
            error
    end,
    {reply, Result, State};
handle_call({drop, Probe}, _From, State) ->
    {reply, erase(Probe), State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({inc, Probe}, State) ->
    Old = get(Probe),
    put(Probe, Old+1),
    {noreply, State};
handle_cast({inc, Probe, Value}, State) ->
    Old = get(Probe),
    put(Probe, Old+Value),
    {noreply, State};
handle_cast({dec, Probe}, State) ->
    Old = get(Probe),
    put(Probe, Old-1),
    {noreply, State};
handle_cast({dec, Probe, Value}, State) ->
    Old = get(Probe),
    put(Probe, Old-Value),
    {noreply, State};
handle_cast({set, log, Value}, State) ->
    {noreply, State#state{log = Value}};
handle_cast({set, Probe, Value}, State) ->
    declare_gauge(Probe),
    put(Probe, Value),
    {noreply, State};
handle_cast({sum, Probe, Value}, State) ->
    declare_gauge(Probe),
    case get(Probe) of
        {Old, Count} -> put(Probe, {Old+Value, Count+1});
        _ -> put(Probe, {Value, 1})
    end,
    {noreply, State};
handle_cast({active, Item}, State) ->
    Log = case State#state.active_count of
        true -> ehyperloglog:update(Item, State#state.log);
        false -> State#state.log
    end,
    {noreply, State#state{log = Log}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#state.host,
    [timer:cancel(T) || T <- State#state.timers],
    [ejabberd_hooks:delete(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    sync_log(Host),
    ejabberd_commands:unregister_commands(get_commands_spec()).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% ejabberd commands
%%====================================================================

get_commands_spec() ->
    [#ejabberd_commands{name = active_counters,
                        tags = [stats],
                        desc = "Returns active users counter in time period (daily_active_users, weekly_active_users, monthly_active_users, period_active_users)",
                        module = ?MODULE, function = active_counters_command,
                        args = [{host, binary}],
                        args_desc = ["Name of host which should return counters"],
                        result = {counters, {list, {counter, {tuple, [{name, string}, {value, integer}]}}}},
                        result_desc = "List of counter names with value",
                        args_example = [<<"xmpp.example.org">>],
                        result_example = [{<<"daily_active_users">>, 100},
                                          {<<"weekly_active_users">>, 1000},
                                          {<<"monthly_active_users">>, 10000},
                                          {<<"period_active_users">>, 300}]
                       },
     #ejabberd_commands{name = flush_probe,
                        tags = [stats],
                        desc = "Returns last value from probe and resets its historical data if any.",
                        module = ?MODULE, function = flush_probe_command,
                        args = [{server, binary}, {probe_name, binary}],
                        result = {probe_value, integer}}].

active_counters_command(Host) ->
    [{jlib:atom_to_binary(Key), Val}
     || {Key, Val} <- dump(Host),
        lists:member(Key, ?HYPERLOGLOGS)].

flush_probe_command(Host, Probe) ->
    case reset(Host, jlib:binary_to_atom(Probe)) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

%%====================================================================
%% Helper functions
%%====================================================================

hookid(Name) when is_binary(Name) -> jlib:binary_to_atom(Name).

packet(Main, Name, <<>>) -> <<Name/binary, "_", Main/binary, "_packet">>;
packet(Main, _Name, Type) -> <<Type/binary, "_", Main/binary, "_packet">>.

concat(Pre, <<>>) -> Pre;
concat(Pre, Post) -> <<Pre/binary, "_", Post/binary>>.

declare_gauge(Probe) ->
    case lists:member(Probe, ?GAUGES) of
        false -> ets:insert(mon_probes, {Probe, gauge});
        true -> ok
    end.

%serverhost(Host) ->
%    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
%    case whereis(Proc) of
%        undefined ->
%            case str:chr(Host, $.) of
%                0 -> {undefined, <<>>};
%                P -> serverhost(str:substr(Host, P+1))
%            end;
%        _ ->
%            {Proc, Host}
%    end.

cast(Host, Msg) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:cast(Proc, Msg).
%    case serverhost(Host) of
%        {undefined, _} -> error;
%        {Proc, _Host} -> gen_server:cast(Proc, Msg)
%    end.

%put(Key, Val) already uses erlang:put(Key, Val)
%get() already uses erlang:get()
get(Key) ->
    case erlang:get(Key) of
        undefined -> 0;
        Val -> Val
    end.

%%====================================================================
%% database api
%%====================================================================

%% this is a temporary solution, waiting for a better one, to get table size

% db_mnesia_to_sql(roster) -> <<"rosterusers">>;
% db_mnesia_to_sql(offline_msg) -> <<"spool">>;
% db_mnesia_to_sql(passwd) -> <<"users">>;
% db_mnesia_to_sql(Table) -> jlib:atom_to_binary(Table).
% 
% db_table_size(passwd) ->
%     lists:foldl(fun(Host, Acc) ->
%                         Acc + ejabberd_auth:get_vh_registered_users_number(Host)
%                 end, 0, ejabberd_config:get_global_option(hosts, fun(V) when is_list(V) -> V end));
% db_table_size(Table) ->
%     [ModName|_] = str:tokens(jlib:atom_to_binary(Table), <<"_">>),
%     Module = jlib:binary_to_atom(<<"mod_",ModName/binary>>),
%     SqlTableSize = lists:foldl(fun(Host, Acc) ->
%                                        case gen_mod:is_loaded(Host, Module) of
%                                            true -> Acc + db_table_size(Table, Host);
%                                            false -> Acc
%                                        end
%                                end, 0, ejabberd_config:get_global_option(hosts, fun(V) when is_list(V) -> V end)),
%     Info = mnesia:table_info(Table, all),
%     case proplists:get_value(local_content, Info) of
%         true -> proplists:get_value(size, Info) + other_nodes_db_size(Table) + SqlTableSize;
%         false -> proplists:get_value(size, Info) + SqlTableSize
%     end.
% 
% db_table_size(session, _Host) ->
%     0;
% db_table_size(s2s, _Host) ->
%     0;
% db_table_size(Table, Host) ->
%     %% TODO (for MySQL):
%     %% Query = [<<"select table_rows from information_schema.tables where table_name='">>,
%     %%          db_mnesia_to_sql(Table), <<"'">>];
%     %% can use sql_queries:count_records_where(Host, db_mnesia_to_sql(Table), <<>>)
%     Query = [<<"select count(*) from ">>, db_mnesia_to_sql(Table)],
%     case catch ejabberd_sql:sql_query(Host, Query) of
%         {selected, [_], [[V]]} ->
%             case catch jlib:binary_to_integer(V) of
%                 {'EXIT', _} -> 0;
%                 Int -> Int
%             end;
%         _ ->
%             0
%     end.
% 
% %% calculates table size on cluster excluding current node
% other_nodes_db_size(Table) ->
%     lists:foldl(fun(Node, Acc) ->
%                     Acc + rpc:call(Node, mnesia, table_info, [Table, size])
%                 end, 0, lists:delete(node(), ejabberd_cluster:get_nodes())).

%%====================================================================
%% Hooks handlers
%%====================================================================

offline_message_hook(_From, #jid{lserver=LServer}, _Packet) ->
    cast(LServer, {inc, offline_message}).
resend_offline_messages_hook(Ls, _User, Server) ->
    cast(jid:nameprep(Server), {inc, resend_offline_messages}),
    Ls.

sm_register_connection_hook(_SID, #jid{luser=LUser,lserver=LServer}, Info) ->
    Post = case proplists:get_value(conn, Info) of
        undefined -> <<>>;
        Atom -> jlib:atom_to_binary(Atom)
    end,
    Hook = hookid(concat(<<"sm_register_connection">>, Post)),
    cast(LServer, {inc, Hook}),
    cast(LServer, {active, LUser}).
sm_remove_connection_hook(_SID, #jid{lserver=LServer}, Info) ->
    Post = case proplists:get_value(conn, Info) of
        undefined -> <<>>;
        Atom -> jlib:atom_to_binary(Atom)
    end,
    Hook = hookid(concat(<<"sm_remove_connection">>, Post)),
    cast(LServer, {inc, Hook}).

roster_in_subscription(Ls, _User, Server, _To, _Type, _Reason) ->
    cast(jid:nameprep(Server), {inc, roster_in_subscription}),
    Ls.
roster_out_subscription(_User, Server, _To, _Type) ->
    cast(jid:nameprep(Server), {inc, roster_out_subscription}).

user_available_hook(#jid{lserver=LServer}) ->
    cast(LServer, {inc, user_available_hook}).
unset_presence_hook(_User, Server, _Resource, _Status) ->
    cast(jid:nameprep(Server), {inc, unset_presence_hook}).
set_presence_hook(_User, Server, _Resource, _Presence) ->
    cast(jid:nameprep(Server), {inc, set_presence_hook}).

user_send_packet(#xmlel{name=Name, attrs=Attrs} = Packet,
                 _C2SState, #jid{lserver=LServer}, _To) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(packet(<<"receive">>, Name, Type)), % user send = server receive
    cast(LServer, {inc, Hook}),
    Packet.
user_receive_packet(#xmlel{name=Name, attrs=Attrs} = Packet,
                    _C2SState, _JID, _From, #jid{lserver=LServer}) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(packet(<<"send">>, Name, Type)), % user receive = server send
    cast(LServer, {inc, Hook}),
    Packet.

c2s_replaced(#jid{lserver=LServer}) ->
    cast(LServer, {inc, c2s_replaced}).

s2s_send_packet(#jid{lserver=LServer}, _To,
                #xmlel{name=Name, attrs=Attrs}) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(concat(<<"s2s">>, packet(<<"send">>, Name, Type))),
    cast(LServer, {inc, Hook}).
s2s_receive_packet(_From, #jid{lserver=LServer},
                   #xmlel{name=Name, attrs=Attrs}) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(concat(<<"s2s">>, packet(<<"receive">>, Name, Type))),
    cast(LServer, {inc, Hook}).

privacy_iq_set(Acc, #jid{lserver=LServer}, _To, _Iq) ->
    cast(LServer, {inc, privacy_iq_set}),
    Acc.

privacy_iq_get(Acc, #jid{lserver=LServer}, _To, _Iq, _) ->
    cast(LServer, {inc, privacy_iq_get}),
    Acc.

api_call(_Module, _Function, _Arguments) ->
    [LServer|_] = ejabberd_config:get_myhosts(),
    cast(LServer, {inc, api_call}).
backend_api_call(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_call}).
backend_api_response_time(LServer, _Method, _Path, Ms) ->
    cast(LServer, {sum, backend_api_response_time, Ms}).
backend_api_timeout(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_timeout}).
backend_api_error(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_error}).
backend_api_badauth(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_badauth}).

remove_user(_User, Server) ->
    cast(jid:nameprep(Server), {inc, remove_user}).
register_user(_User, Server) ->
    cast(jid:nameprep(Server), {inc, register_user}).

%muc_create(_Host, ServerHost, _Room, _JID) ->
%    cast(ServerHost, {inc, muc_rooms}),
%    cast(ServerHost, {inc, muc_create}).
%muc_destroy(_Host, ServerHost, _Room) ->
%    cast(ServerHost, {dec, muc_rooms}),
%    cast(ServerHost, {inc, muc_destroy}).
%muc_user_join(_Host, ServerHost, _Room, _JID) ->
%    cast(ServerHost, {inc, muc_users}),
%    cast(ServerHost, {inc, muc_user_join}).
%muc_user_leave(_Host, ServerHost, _Room, _JID) ->
%    cast(ServerHost, {dec, muc_users}),
%    cast(ServerHost, {inc, muc_user_leave}).
%muc_message(_Host, ServerHost, Room, _JID) ->
%    cast(ServerHost, {inc, {muc_message, Room}}).
%
pubsub_create_node(ServerHost, _Host, _Node, _Nidx, _NodeOptions) ->
    cast(ServerHost, {inc, pubsub_create_node}).
pubsub_delete_node(ServerHost, _Host, _Node, _Nidx) ->
    cast(ServerHost, {inc, pubsub_delete_node}).
pubsub_publish_item(ServerHost, _Node, _Publisher, _From, _ItemId, _Packet) ->
    %Size = erlang:external_size(Packet),
    cast(ServerHost, {inc, pubsub_publish_item}).
%pubsub_broadcast_stanza(Host, Node, Count, _Stanza) ->
%    cast(Host, {inc, {pubsub_broadcast_stanza, Node, Count}}).

%%====================================================================
%% active user feature
%%====================================================================

% HyperLogLog notes:
% Let σ ≈ 1.04/√m represent the standard error; the estimates provided by HYPERLOGLOG
% are expected to be within σ, 2σ, 3σ of the exact count in respectively 65%, 95%, 99%
% of all the cases.
%
% bits / memory / registers / σ 2σ 3σ
% 10   1309  1024 ±3.25% ±6.50% ±9.75%
% 11   2845  2048 ±2.30% ±4.60% ±6.90%
% 12   6173  4096 ±1.62% ±3.26% ±4.89%
% 13  13341  8192 ±1.15% ±2.30% ±3.45%
% 14  28701 16384 ±0.81% ±1.62% ±2.43%
% 15  62469 32768 ±0.57% ±1.14% ±1.71%
% 16 131101 65536 ±0.40% ±0.81% ±1.23%   <=== we take this one

init_log(_Host, false) ->
    undefined;
init_log(Host, true) ->
    EmptyLog = ehyperloglog:new(16),
    [put(Key, 0) || Key <- ?HYPERLOGLOGS],
    Logs = lists:foldl(
            fun({Key, Val}, Acc) ->
                    put(Key, round(ehyperloglog:cardinality(Val))),
                    lists:keyreplace(Key, 1, Acc, {Key, Val})
            end,
            [{Key, EmptyLog} || Key <- ?HYPERLOGLOGS],
            read_logs(Host)),
    write_logs(Host, Logs),
    proplists:get_value(hd(?HYPERLOGLOGS), Logs).

cluster_log(Host) ->
    {Logs, _} = ejabberd_cluster:multicall(?MODULE, value, [Host, log]),
    lists:foldl(fun
            ({hll,_,_}=L1, L2) -> ehyperloglog:merge(L2, L1);
            (_, Acc) -> Acc
        end, ehyperloglog:new(16), Logs).

sync_log(Host) when is_binary(Host) ->
    % this process can safely run on its own, thanks to put/get hyperloglogs not using dictionary
    % it should be called at regular interval to keep logs consistency
    spawn(fun() ->
                ClusterLog = cluster_log(Host),
                set(Host, log, ClusterLog),
                write_logs(Host, [{Key, merge_log(Host, Key, Val, ClusterLog)}
                                  || {Key, Val} <- read_logs(Host)])
        end).

flush_log(Host, Probe) ->
    % this process can safely run on its own, thanks to put/get hyperloglogs not using dictionary
    % it may be called at regular interval with timers or external cron
    spawn(fun() ->
                ClusterLog = cluster_log(Host),
                ejabberd_cluster:multicall(?MODULE, flush_log, [Host, Probe, ClusterLog])
        end).
flush_log(Host, Probe, _ClusterLog) when is_binary(Host), is_atom(Probe) ->
    set(Host, log, ehyperloglog:new(16)),
    UpdatedLogs = lists:foldr(
            fun({Key, Val}, Acc) ->
                    NewLog = case Key of
                        Probe -> reset_log(Host, Key);
                        _ -> Val
                    end,
                    [{Key, NewLog}|Acc]
            end,
            [], read_logs(Host)),
    write_logs(Host, UpdatedLogs).

merge_log(Host, Probe, Log, ClusterLog) ->
    Merge = ehyperloglog:merge(ClusterLog, Log),
    set(Host, Probe, round(ehyperloglog:cardinality(Merge))),
    Merge.

reset_log(Host, Probe) ->
    set(Host, Probe, 0),
    ehyperloglog:new(16).

write_logs(Host, Logs) when is_list(Logs) ->
    File = logfilename(Host),
    filelib:ensure_dir(File),
    file:write_file(File, term_to_binary(Logs)).

read_logs(Host) ->
    File = logfilename(Host),
    case file:read_file(File) of
        {ok, Bin} ->
            case catch binary_to_term(Bin) of
                List when is_list(List) ->
                    % prevent any garbage loading
                    lists:foldr(
                        fun ({Key, Val}, Acc) ->
                                case lists:member(Key, ?HYPERLOGLOGS) of
                                    true -> [{Key, Val}|Acc];
                                    false -> Acc
                                end;
                            (_, Acc) ->
                                Acc
                        end, [], List);
                _ ->
                    []
            end;
        _ ->
            []
    end.

logfilename(Host) when is_binary(Host) ->
    Name = binary:replace(Host, <<".">>, <<"_">>, [global]),
    filename:join([mnesia:system_info(directory), "hyperloglog", <<Name/binary, ".bin">>]).

%%====================================================================
%% high level monitors
%%====================================================================

compute_probes(Host, Monitors) ->
    Probes = lists:foldl(
            fun({Key, {Val, Count}}, Acc) when is_integer(Val), is_integer(Count) ->
                    Avg = Val div Count,
                    put(Key, Avg), %% to force reset of average count
                    [{Key, probe_type(Key), Avg}|Acc];
                ({Key, Val}, Acc) when is_integer(Val) ->
                    [{Key, probe_type(Key), Val}|Acc];
                (_, Acc) ->
                    Acc
            end, [], get()),
    Computed = lists:foldl(
            fun({I, M, F, A}, Acc) -> acc_monitor(I, apply(M, F, A), Acc);
                ({I, M, F, A, Fun}, Acc) -> acc_monitor(I, Fun(apply(M, F, A)), Acc);
                ({I, F, A}, Acc) -> acc_monitor(I, apply(?MODULE, F, [Host, A]), Acc);
                ({I, F}, Acc) when is_atom(F) -> acc_monitor(I, apply(?MODULE, F, [Host]), Acc);
                ({I, Spec}, Acc) when is_list(Spec) -> acc_monitor(I, eval_monitors(Probes, Spec, 0), Acc);
                (_, Acc) -> Acc
            end, [], Monitors),
    Probes ++ Computed.

probe_type(Probe) ->
    case catch ets:lookup(mon_probes, Probe) of
        [{Probe, Type}] -> Type;
        _ -> counter
    end.

eval_monitors(_, [], Acc) ->
    Acc;
eval_monitors(Probes, [Action|Tail], Acc) ->
    eval_monitors(Probes, Tail, compute_monitor(Probes, Action, Acc)).

compute_monitor(Probes, Probe, Acc) when is_atom(Probe) ->
    compute_monitor(Probes, {'+', Probe}, Acc);
compute_monitor(Probes, {'+', Probe}, Acc) ->
    case lists:keyfind(Probe, 1, Probes) of
        {Probe, _Type, Val} -> Acc+Val;
        _ -> Acc
    end;
compute_monitor(Probes, {'-', Probe}, Acc) ->
    case lists:keyfind(Probe, 1, Probes) of
        {Probe, _Type, Val} -> Acc-Val;
        _ -> Acc
    end.

acc_monitor(dynamic, Values, Acc) when is_list(Values) ->
    lists:foldl(
        fun({Probe, Value}, Res) ->
                acc_monitor(Probe, Value, Res);
            (_, Res) ->
                Res
        end, Acc, Values);
acc_monitor(Probe, Value, Acc) ->
    [{Probe, gauge, Value}|Acc].

%%====================================================================
%% Cache sync
%%====================================================================

init_backend(_Host, {statsd, EndPoint}) ->
    {Ip, Port} = backend_ip_port(EndPoint, {127,0,0,1}, 2003),
    {statsd, Ip, Port};
init_backend(_Host, statsd) ->
    {statsd, {127,0,0,1}, 2003};
init_backend(_Host, {influxdb, EndPoint}) ->
    {Ip, Port} = backend_ip_port(EndPoint, {127,0,0,1}, 4444),
    {influxdb, Ip, Port};
init_backend(_Host, influxdb) ->
    {influxdb, {127,0,0,1}, 4444};
init_backend(_Host, {grapherl, EndPoint}) ->
    {Ip, Port} = backend_ip_port(EndPoint, {127,0,0,1}, 11111),
    {grapherl, Ip, Port};
init_backend(_Host, grapherl) ->
    {grapherl, {127,0,0,1}, 11111};
init_backend(Host, mnesia) ->
    Table = gen_mod:get_module_proc(Host, mon),
    mnesia:create_table(Table,
                        [{disc_copies, [node()]},
                         {local_content, true},
                         {record_name, mon},
                         {attributes, record_info(fields, mon)}]),
    mnesia;
init_backend(_, _) ->
    none.

backend_ip_port(EndPoint, DefaultServer, DefaultPort) when is_binary(EndPoint) ->
    case string:tokens(binary_to_list(EndPoint), ":") of
        [Ip] -> {backend_ip(Ip, DefaultServer), DefaultPort};
        [Ip, Port|_] -> {backend_ip(Ip, DefaultServer), backend_port(Port, DefaultPort)};
        _ ->
            ?WARNING_MSG("backend endoint is invalid: ~p", [EndPoint]),
            {DefaultServer, DefaultPort}
    end.
backend_ip(Server, Default) when is_list(Server) ->
    case catch inet:getaddr(Server, inet) of
        {ok, IpAddr} ->
            IpAddr;
        _ ->
            ?WARNING_MSG("backend address is invalid: ~p, fallback to ~p", [Server, Default]),
            Default
    end.
backend_port(Port, Default) when is_list(Port) ->
    case catch list_to_integer(Port) of
        I when is_integer(I) ->
            I;
        _ ->
            ?WARNING_MSG("backend port is invalid: ~p, fallback to ~p", [Port, Default]),
            Default
    end.

push_metrics(Host, Backends) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    case catch gen_server:call(Proc, snapshot, ?CALL_TIMEOUT) of
        {'EXIT', Reason} ->
            ?WARNING_MSG("Can not push mon metrics~n~p", [Reason]),
            {error, Reason};
        Probes ->
            [_, NodeId] = str:tokens(jlib:atom_to_binary(node()), <<"@">>),
            [Node | _] = str:tokens(NodeId, <<".">>),
            DateTime = erlang:universaltime(),
            UnixTime = calendar:datetime_to_gregorian_seconds(DateTime) - 62167219200,
            [push(Host, Node, Probes, UnixTime, Backend) || Backend <- Backends],
            ok
    end.

push(Host, _Node, Probes, _Time, mnesia) ->
    Table = gen_mod:get_module_proc(Host, mon),
    Cache = [{Key, Val} || {mon, Key, Val} <- ets:tab2list(Table)],
    lists:foreach(
        fun({Key, counter, Val}) ->
                case proplists:get_value(Key, Cache) of
                    undefined -> mnesia:dirty_write(Table, #mon{probe = Key, value = Val});
                    Old -> [mnesia:dirty_write(Table, #mon{probe = Key, value = Old+Val}) || Val > 0]
                end;
           ({Key, gauge, Val}) ->
                case proplists:get_value(Key, Cache) of
                    Val -> ok;
                    _ -> mnesia:dirty_write(Table, #mon{probe = Key, value = Val})
                end
        end, Probes);
push(Host, Node, Probes, _Time, {statsd, Ip, Port}) ->
    % probe example => process-one.net.xmpp.xmpp-1.chat_receive_packet:value|g
    BaseId = <<Host/binary, ".xmpp.", Node/binary, ".">>,
    push_udp(Ip, Port, Probes, fun(Key, Val, Type) ->
            <<BaseId/binary, Key/binary, ":", Val/binary, "|", Type>>
        end);
push(Host, Node, Probes, Time, {influxdb, Ip, Port}) ->
    % probe example => chat_receive_packet,host=process-one.net,node=xmpp-1 value timestamp
    Tags = <<"host=", Host/binary, ",node=", Node/binary>>,
    TS = <<(integer_to_binary(Time))/binary, "000000000">>,
    push_udp(Ip, Port, Probes, fun(Key, Val, _Type) ->
            <<Key/binary, ",", Tags/binary, " value=", Val/binary, " ", TS/binary>>
        end);
push(Host, Node, Probes, Time, {grapherl, Ip, Port}) ->
    % probe example => process-one.net/xmpp-1.chat_receive_packet:g/timestamp:value
    BaseId = <<Host/binary, "/", Node/binary, ".">>,
    TS = integer_to_binary(Time),
    push_udp(Ip, Port, Probes, fun(Key, Val, Type) ->
            <<BaseId/binary, Key/binary, ":", Type, "/", TS/binary, ":", Val/binary>>
        end);
push(_Host, _Node, _Probes, _Time, _Backend) ->
    ok.

push_udp(Ip, Port, Probes, Format) ->
    case gen_udp:open(0) of
        {ok, Socket} ->
            lists:foreach(
                fun({Key, Type, Val}) when is_integer(Val) ->
                        BKey = jlib:atom_to_binary(Key),
                        BVal = integer_to_binary(Val),
                        Data = Format(BKey, BVal, type_to_char(Type)),
                        gen_udp:send(Socket, Ip, Port, Data);
                   ({health, _Type, _Val}) ->
                        ok;
                   ({Key, _Type, Val}) ->
                        ?WARNING_MSG("can not push metrics ~p with value ~p", [Key, Val])
                end, Probes),
            gen_udp:close(Socket);
        Error ->
            ?WARNING_MSG("can not open udp socket to ~p port ~p: ~p", [Ip, Port, Error])
    end.

type_to_char(counter) -> $c;
type_to_char(gauge) -> $g;
type_to_char(Type) ->
    ?WARNING_MSG("invalid probe type ~p, assuming counter", [Type]),
    $c.

%%====================================================================
%% Monitors helpers
%%====================================================================

process_queues(_Host, all) ->
    weight([queue(Pid, message_queue_len) || Pid <- processes()]);
process_queues(Host, Sup) ->
    case catch workers(Host, Sup) of
        {'EXIT', _} -> 0;
        Workers -> weight([queue(Pid, message_queue_len) || {_,Pid,_,_} <- Workers])
    end.

internal_queues(Host, Sup) ->
    case catch workers(Host, Sup) of
        {'EXIT', _} -> 0;
        Workers -> weight([queue(Pid, dictionary) || {_,Pid,_,_} <- Workers])
    end.

weight([]) -> 0;
weight(List) when is_list(List) ->
    {Sum, Max} = lists:foldl(
            fun(X, {S, M}) when is_integer(X) ->
                    if X>M -> {S+X, X};
                        true -> {S+X, M}
                    end;
                (_, Acc) ->
                    Acc
            end, {0, 0}, List),
    Avg = Sum div length(List),
    (Avg + Max) div 2.

queue(Pid, Attr) -> queue(erlang:process_info(Pid, Attr)).
queue({message_queue_len, I}) -> I;
queue({dictionary, D}) -> proplists:get_value('$internal_queue_len', D, 0);
queue(_) -> 0.

workers(Host, ejabberd_sql_sup) ->
    Sup = gen_mod:get_module_proc(Host, ejabberd_sql_sup),
    workers(Host, Sup);
workers(Host, mod_offline_pool) ->
    Sup = gen_mod:get_module_proc(Host, mod_offline_pool),
    workers(Host, Sup);
workers(_Host, Sup) ->
    supervisor:which_children(Sup).

% Note: health_check must be called last from monitors list
%       as it uses values as they are pushed and also some other
%       monitors values
health_check(Host) ->
    spawn(mod_mon_client, start, [Host]),
    HealthCfg = ejabberd_config:get_option({health, Host},
                               fun(V) when is_list(V) -> V end,
                               []),
    lists:foldr(fun({Component, Check}, Acc) ->
                lists:foldr(fun({Probe, Message, Critical}, Acc2) ->
                            Spec = case proplists:get_value(Probe, HealthCfg, []) of
                                L when is_list(L) -> L;
                                Other -> [Other]
                            end,
                            case check_level(Probe, Spec) of
                                ok -> Acc2;
                                critical -> [{critical, Component, Critical}|Acc2];
                                Level -> [{Level, Component, Message}|Acc2]
                            end
                    end, Acc, Check)
            end, [],
        [{<<"REST API">>,
          [{backend_api_response_time, <<"slow responses">>, <<"no response">>},
           {backend_api_error, <<"error responses">>, <<"total failure">>},
           {backend_api_badauth, <<"logins with bad credentials">>, <<"auth flooding">>}]},
         {<<"Router">>,
          [{c2s_queues, <<"c2s processes overloaded">>, <<"c2s dead">>},
           {s2s_queues, <<"s2s processes overloaded">>, <<"s2s dead">>},
           {iq_queues, <<"iq handlers overloaded">>, <<"iq handlers dead">>},
           {sm_queues, <<"session managers overloaded">>, <<"sessions dead">>}]},
         {<<"Database">>,
          [{sql_queues, <<"sql driver overloaded">>, <<"service down">>},
           {offline_queues, <<"offline spool overloaded">>, <<"service down">>}]},
         {<<"Client">>,
          [{client_conn_time, <<"connection is slow">>, <<"service unavailable">>},
           {client_auth_time, <<"authentification is slow">>, <<"auth broken">>},
           {client_roster_time, <<"roster response is slow">>, <<"roster broken">>}]}]).

jabs_count(Host) ->
    case catch mod_jabs:value(Host) of
        {'EXIT', _} -> 0;
        undefined -> 0;
        {Count, _} -> Count
    end.

cpu_usage(_Host) ->
    Threads = erlang:system_info(schedulers),
    {_, Runtime} = erlang:statistics(runtime),
    Runtime div (?MINUTE * Threads).

%%====================================================================
%% Health check helpers
%%====================================================================

check_level(_, []) ->
    ok;
check_level(iq_queues, Spec) ->
    Value = get(iq_message_queues)+get(iq_internal_queues),
    check_level(ok, Value, Spec);
check_level(sm_queues, Spec) ->
    Value = get(sm_message_queues)+get(sm_internal_queues),
    check_level(ok, Value, Spec);
check_level(c2s_queues, Spec) ->
    Value = get(c2s_message_queues)+get(c2s_internal_queues),
    check_level(ok, Value, Spec);
check_level(s2s_queues, Spec) ->
    Value = get(s2s_message_queues)+get(s2s_internal_queues),
    check_level(ok, Value, Spec);
check_level(sql_queues, Spec) ->
    Value = get(sql_message_queues)+get(sql_internal_queues),
    check_level(ok, Value, Spec);
check_level(offline_queues, Spec) ->
    Value = get(offline_message_queues)+get(offline_internal_queues),
    check_level(ok, Value, Spec);
check_level(Probe, Spec) ->
    Val = case get(Probe) of
        {Sum, Count} -> Sum div Count;
        Value -> Value
    end,
    check_level(ok, Val, Spec).

check_level(Acc, _, []) -> Acc;
check_level(Acc, Value, [{Level, gt, Limit}|Tail]) ->
    if Value > Limit -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, lt, Limit}|Tail]) ->
    if Value < Limit -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, in, Low, Up}|Tail]) ->
    if (Value >= Low) and (Value =< Up) -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, out, Low, Up}|Tail]) ->
    if (Value < Low) or (Value > Up) -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, eq, Limit}|Tail]) ->
    if Value == Limit -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, neq, Limit}|Tail]) ->
    if Value =/= Limit -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [Invalid|Tail]) ->
    ?WARNING_MSG("invalid health limit spec: ~p", [Invalid]),
    check_level(Acc, Value, Tail).

%%====================================================================
%% Temporary helper to get clear cluster view of most important probes
%%====================================================================

merge_sets([L]) -> L;
merge_sets([L1,L2]) -> merge_set(L1,L2);
merge_sets([L1,L2|Tail]) -> merge_sets([merge_set(L1,L2)|Tail]).
merge_set(L1, L2) ->
    lists:foldl(fun({K,V}, Acc) ->
                case proplists:get_value(K, Acc) of
                    undefined -> [{K,V}|Acc];
                    Old -> lists:keyreplace(K, 1, Acc, {K,Old+V})
                end
        end, L1, L2).

tab2set(Mons) when is_list(Mons) ->
    [{K,V} || {mon,K,V} <- Mons];
tab2set(_) ->
    [].

info(Host) when is_binary(Host) ->
    Table = gen_mod:get_module_proc(Host, mon),
    Probes = merge_sets([tab2set(rpc:call(Node, ets, tab2list, [Table])) || Node <- ejabberd_cluster:get_nodes()]),
    [{Key, Val} || {Key, Val} <- Probes,
                   lists:member(Key, [c2s_receive, c2s_send, s2s_receive, s2s_send])].


mod_opt_type(hooks) ->
    fun (List) when is_list(List) -> List end;
mod_opt_type(monitors_base) ->
    fun (List) when is_list(List) -> List end;
mod_opt_type(active_count) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(backends) ->
    fun (List) when is_list(List) -> List end;
mod_opt_type(monitors) ->
    fun (L) when is_list(L) -> L end;
mod_opt_type(_) -> [hooks, monitors_base, active_count, backends, monitors].

opt_type(health) -> fun (V) when is_list(V) -> V end;
opt_type(_) -> [health].
