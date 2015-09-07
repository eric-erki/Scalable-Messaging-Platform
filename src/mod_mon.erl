%%%-------------------------------------------------------------------
%%% File    : mod_mon.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Event monitor for runtime statistics
%%% Created : 10 Apr 2014 by Christophe Romain <christophe.romain@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2015   ProcessOne
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
-export([value/2, reset/2, set/3, dump/1, info/1]).
%% sync commands
-export([flush_log/3, sync_log/1]).
%% administration commands
-export([active_counters_command/1, flush_probe_command/2]).
%% monitors
-export([process_queues/2, internal_queues/2, health_check/2, jabs_count/1]).
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
	 register_user/2, backend_api_call/3,
	 backend_api_response_time/4, backend_api_timeout/3,
	 backend_api_error/3, backend_api_badauth/3,
	 pubsub_create_node/5, pubsub_delete_node/4,
	 pubsub_publish_item/6, mod_opt_type/1, opt_type/1]).
         %pubsub_broadcast_stanza/4 ]).

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

reset(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, {reset, Probe}).

dump(Host) when is_binary(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:call(Proc, dump, ?CALL_TIMEOUT).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Opts]) ->
    % List enabled monitors, defaults all
    Monitors = gen_mod:get_opt(monitors, Opts,
                               fun(L) when is_list(L) -> L end, [])
               ++ ?DEFAULT_MONITORS,
    % Active users counting uses hyperloglog structures
    ActiveCount = gen_mod:get_opt(active_count, Opts,
                                  fun(A) when is_atom(A) -> A end, true)
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
        Hook <- ?SUPPORTED_HOOKS],
    ejabberd_commands:register_commands(commands()),

    % Start timers for cache and backends sync
    {ok, T1} = timer:apply_interval(?HOUR, ?MODULE, sync_log, [Host]),
    {ok, T2} = timer:send_interval(?MINUTE, push),

    {ok, #state{host = Host,
                active_count = ActiveCount,
                backends = Backends,
                monitors = Monitors,
                log = Log,
                timers = [T1,T2]}}.

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
    put(Probe, Value),
    {noreply, State};
handle_cast({avg, Probe, Value}, State) ->
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

handle_info(push, State) ->
    run_monitors(State#state.host, State#state.monitors),
    [compute_average(Probe) || Probe <- [backend_api_response_time]],
    Probes = [{Key, Val} || {Key, Val} <- get(), is_integer(Val)],
    [push(State#state.host, Probes, Backend) || Backend <- State#state.backends],
    [put(Key, 0) || {Key, Val} <- Probes,
                    Val =/= 0,
                    not proplists:is_defined(Key, ?NO_COUNTER_PROBES)],
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#state.host,
    [timer:cancel(T) || T <- State#state.timers],
    [ejabberd_hooks:delete(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    sync_log(Host),
    ejabberd_commands:unregister_commands(commands()).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% ejabberd commands
%%====================================================================

commands() ->
    [#ejabberd_commands{name = active_counters,
                        tags = [stats],
                        desc = "Returns active users counter in time period (daily_active_users, weekly_active_users, monthly_active_users)",
                        module = ?MODULE, function = active_counters_command,
                        args = [{host, binary}],
                        args_desc = ["Name of host which should return counters"],
                        result = {counters, {list, {counter, {tuple, [{name, string}, {value, integer}]}}}},
                        result_desc = "List of counter names with value",
                        args_example = [<<"xmpp.example.org">>],
                        result_example = [{<<"daily_active_users">>, 100},
                                          {<<"weekly_active_users">>, 1000},
                                          {<<"monthly_active_users">>, 10000}]
                       },
     #ejabberd_commands{name = flush_probe,
                        tags = [stats],
                        desc = "Returns last value from probe and resets its historical data. Supported probes so far: daily_active_users, weekly_active_users, monthly_active_users",
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
%     %% can use odbc_queries:count_records_where(Host, db_mnesia_to_sql(Table), <<>>)
%     Query = [<<"select count(*) from ">>, db_mnesia_to_sql(Table)],
%     case catch ejabberd_odbc:sql_query(Host, Query) of
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
    cast(jlib:nameprep(Server), {inc, resend_offline_messages}),
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
    cast(jlib:nameprep(Server), {inc, roster_in_subscription}),
    Ls.
roster_out_subscription(_User, Server, _To, _Type) ->
    cast(jlib:nameprep(Server), {inc, roster_out_subscription}).

user_available_hook(#jid{lserver=LServer}) ->
    cast(LServer, {inc, user_available_hook}).
unset_presence_hook(_User, Server, _Resource, _Status) ->
    cast(jlib:nameprep(Server), {inc, unset_presence_hook}).
set_presence_hook(_User, Server, _Resource, _Presence) ->
    cast(jlib:nameprep(Server), {inc, set_presence_hook}).

user_send_packet(#xmlel{name=Name, attrs=Attrs} = Packet,
                 _C2SState, #jid{lserver=LServer}, _To) ->
    Type = xml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(packet(<<"receive">>, Name, Type)), % user send = server receive
    cast(LServer, {inc, Hook}),
    %possible jabs computation. see mod_jabs
    %Size = erlang:external_size(Packet),
    %gen_server:cast(mod_jabs:process(Host), {inc, 'XPS', 1+(Size div 6000)}),
    Packet.
user_receive_packet(#xmlel{name=Name, attrs=Attrs} = Packet,
                    _C2SState, _JID, _From, #jid{lserver=LServer}) ->
    Type = xml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(packet(<<"send">>, Name, Type)), % user receive = server send
    cast(LServer, {inc, Hook}),
    Packet.

c2s_replaced(#jid{lserver=LServer}) ->
    cast(LServer, {inc, c2s_replaced}).

s2s_send_packet(#jid{lserver=LServer}, _To,
                #xmlel{name=Name, attrs=Attrs}) ->
    Type = xml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(concat(<<"s2s">>, packet(<<"send">>, Name, Type))),
    cast(LServer, {inc, Hook}).
s2s_receive_packet(_From, #jid{lserver=LServer},
                   #xmlel{name=Name, attrs=Attrs}) ->
    Type = xml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(concat(<<"s2s">>, packet(<<"receive">>, Name, Type))),
    cast(LServer, {inc, Hook}).

privacy_iq_set(Acc, #jid{lserver=LServer}, _To, _Iq) ->
    cast(LServer, {inc, privacy_iq_set}),
    Acc.

privacy_iq_get(Acc, #jid{lserver=LServer}, _To, _Iq, _) ->
    cast(LServer, {inc, privacy_iq_get}),
    Acc.

backend_api_call(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_call}).
backend_api_response_time(LServer, _Method, _Path, Ms) ->
    cast(LServer, {avg, backend_api_response_time, Ms}).
backend_api_timeout(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_timeout}).
backend_api_error(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_error}).
backend_api_badauth(LServer, _Method, _Path) ->
    cast(LServer, {inc, backend_api_badauth}).

remove_user(_User, Server) ->
    cast(jlib:nameprep(Server), {inc, remove_user}).
register_user(_User, Server) ->
    cast(jlib:nameprep(Server), {inc, register_user}).

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
    case read_logs(Host) of
        [] ->
            L = ehyperloglog:new(16),
            write_logs(Host, [{Key, L} || Key <- ?HYPERLOGLOGS]),
            [put(Key, 0) || Key <- ?HYPERLOGLOGS],
            L;
        Logs ->
            [put(Key, round(ehyperloglog:cardinality(Val))) || {Key, Val} <- Logs],
            proplists:get_value(hd(?HYPERLOGLOGS), Logs)
    end.

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

run_monitors(Host, Monitors) ->
    Probes = [{Key, Val} || {Key, Val} <- get(), is_integer(Val)],
    lists:foreach(
        fun({I, M, F, A}) -> put(I, apply(M, F, A));
           ({I, M, F, A, Fun}) -> put(I, Fun(apply(M, F, A)));
           ({I, F, A}) -> put(I, apply(?MODULE, F, [Host, A]));
           ({I, F}) when is_atom(F) -> put(I, apply(?MODULE, F, [Host]));
           ({I, Spec}) when is_list(Spec) -> put(I, eval_monitors(Probes, Spec, 0));
           (_) -> ok
        end, Monitors).

eval_monitors(_, [], Acc) ->
    Acc;
eval_monitors(Probes, [Action|Tail], Acc) ->
    eval_monitors(Probes, Tail, compute_monitor(Probes, Action, Acc)).

compute_monitor(Probes, Probe, Acc) when is_atom(Probe) ->
    compute_monitor(Probes, {'+', Probe}, Acc);
compute_monitor(Probes, {'+', Probe}, Acc) ->
    case proplists:get_value(Probe, Probes) of
        undefined -> Acc;
        Val -> Acc+Val
    end;
compute_monitor(Probes, {'-', Probe}, Acc) ->
    case proplists:get_value(Probe, Probes) of
        undefined -> Acc;
        Val -> Acc-Val
    end.

compute_average(Probe) ->
    case get(Probe) of
        {Value, Count} -> put(Probe, Value div Count);
        _ -> ok
    end.

%%====================================================================
%% Cache sync
%%====================================================================

init_backend(Host, {statsd, Server}) ->
    application:load(statsderl),
    application:set_env(statsderl, base_key, binary_to_list(Host)),
    case catch inet:getaddr(binary_to_list(Server), inet) of
        {ok, Ip} -> application:set_env(statsderl, hostname, Ip);
        _ -> ?WARNING_MSG("statsd have undefined endpoint: can not resolve ~p", [Server])
    end,
    application:start(statsderl),
    statsd;
init_backend(Host, statsd) ->
    application:load(statsderl),
    application:set_env(statsderl, base_key, binary_to_list(Host)),
    application:start(statsderl),
    statsd;
init_backend(Host, mnesia) ->
    Table = gen_mod:get_module_proc(Host, mon),
    mnesia:create_table(Table,
                        [{disc_copies, [node()]},
                         {local_content, true},
                         {record_name, mon},
                         {attributes, record_info(fields, mon)}]),
    mnesia;
init_backend(Host, grapherl) ->
    init_backend(Host, {grapherl, {127,0,0,1}, 11111});
init_backend(Host, {grapherl, Server, Port}) ->
    % TODO init client
    grapherl;
init_backend(_, _) ->
    none.

push(Host, Probes, mnesia) ->
    Table = gen_mod:get_module_proc(Host, mon),
    Cache = [{Key, Val} || {mon, Key, Val} <- ets:tab2list(Table)],
    lists:foreach(
        fun({Key, Val}) ->
                case proplists:get_value(Key, ?NO_COUNTER_PROBES) of
                    undefined ->
                        case proplists:get_value(Key, Cache) of
                            undefined -> mnesia:dirty_write(Table, #mon{probe = Key, value = Val});
                            Old -> [mnesia:dirty_write(Table, #mon{probe = Key, value = Old+Val}) || Val > 0]
                        end;
                    gauge ->
                        case proplists:get_value(Key, Cache) of
                            Val -> ok;
                            _ -> mnesia:dirty_write(Table, #mon{probe = Key, value = Val})
                        end;
                    _ ->
                        ok
                end
        end, Probes);
push(_Host, Probes, statsd) ->
    % Librato metrics are name first with service name (to group the metrics from a service),
    % then type of service (xmpp, etc) and then nodename and name of the data itself
    % example => process-one.net.xmpp.xmpp-1.chat_receive_packet
    [_, NodeId] = str:tokens(jlib:atom_to_binary(node()), <<"@">>),
    [Node | _] = str:tokens(NodeId, <<".">>),
    BaseId = <<"xmpp.", Node/binary, ".">>,
    lists:foreach(
        fun({Key, Val}) ->
                Id = <<BaseId/binary, (jlib:atom_to_binary(Key))/binary>>,
                case proplists:get_value(Key, ?NO_COUNTER_PROBES) of
                    undefined -> statsderl:increment(Id, Val, 1);
                    gauge -> statsderl:gauge(Id, Val, 1);
                    _ -> ok
                end
        end, Probes);
push(Host, Probes, grapherl) ->
    % grapherl metrics are name first with service name, then nodename
    % and name of the data itself, followed by type timestamp and value
    % example => process-one.net/xmpp-1.chat_receive_packet:g/timestamp:value
    [_, NodeId] = str:tokens(jlib:atom_to_binary(node()), <<"@">>),
    [Node | _] = str:tokens(NodeId, <<".">>),
    BaseId = <<Host/binary, "/", Node/binary, ".">>,
    DateTime = erlang:universaltime(),
    UnixTime = calendar:datetime_to_gregorian_seconds(DateTime) - 62167219200,
    TS = integer_to_binary(UnixTime),
    case gen_udp:open(0) of
        {ok, Socket} ->
            lists:foreach(
                fun({Key, Val}) ->
                        Type = case proplists:get_value(Key, ?NO_COUNTER_PROBES) of
                            gauge -> <<"g">>;
                            _ -> <<"c">>
                        end,
                        BVal = integer_to_binary(Val),
                        Data = <<BaseId/binary, (jlib:atom_to_binary(Key))/binary,
                                 ":", Type/binary, "/", TS/binary, ":", BVal/binary>>,
                        gen_udp:send(Socket, {127,0,0,1}, 11111, Data)
                end, Probes),
            gen_udp:close(Socket);
        Error ->
            ?WARNING_MSG("can not open udp socket to grapherl: ~p", [Error])
    end;
push(_Host, _Probes, none) ->
    ok.

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

workers(Host, ejabberd_odbc_sup) ->
    Sup = gen_mod:get_module_proc(Host, ejabberd_odbc_sup),
    workers(Host, Sup);
workers(Host, mod_offline_pool) ->
    Sup = gen_mod:get_module_proc(Host, mod_offline_pool),
    workers(Host, Sup);
workers(_Host, Sup) ->
    supervisor:which_children(Sup).

% Note: health_check must be called last from monitors list
%       as it uses values as they are pushed and also some other
%       monitors values
health_check(Host, all) ->
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
          [{odbc_queues, <<"odbc driver overloaded">>, <<"service down">>},
           {offline_queues, <<"offline spool overloaded">>, <<"service down">>}]},
         {<<"Client">>,
          [{client_conn_time, <<"connection is slow">>, <<"service unavailable">>},
           {client_auth_time, <<"authentification is slow">>, <<"auth broken">>},
           {client_roster_time, <<"roster response is slow">>, <<"roster broken">>}]}]).

jabs_count(Host) ->
    {Count, _} = mod_jabs:value(Host),
    Count.

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
check_level(odbc_queues, Spec) ->
    Value = get(odbc_message_queues)+get(odbc_internal_queues),
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


mod_opt_type(active_count) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(backends) ->
    fun (List) when is_list(List) -> List end;
mod_opt_type(monitors) ->
    fun (L) when is_list(L) -> L end;
mod_opt_type(_) -> [active_count, backends, monitors].

opt_type(health) -> fun (V) when is_list(V) -> V end;
opt_type(_) -> [health].
