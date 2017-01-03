%%%-------------------------------------------------------------------
%%% File    : mod_mon_active.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Monitor active users
%%% Created : 11 Jul 2016 by Christophe Romain <christophe.romain@process-one.net>
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
%%%-------------------------------------------------------------------

-module(mod_mon_active).

-behaviour(ejabberd_config).
-author('christophe.romain@process-one.net').
-behaviour(gen_mod).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("ejabberd_commands.hrl").
-include("mod_mon.hrl").

-define(PROCNAME, ?MODULE).
-define(CALL_TIMEOUT, 5000).

%% module API
-export([start_link/2, start/2, stop/1]).
-export([values/1, reset/2, insert/2]).
-export([get_log/1, add_log/2, del_log/2, sync_log/1]).
%% server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% administration commands
-export([active_command/1, flush_active_command/2]).

-export([sm_register_connection_hook/3]).
-export([depends/2, mod_opt_type/1, opt_type/1]).

-record(state, {host, log, pool=[], file, timers=[]}).

%%====================================================================
%% API
%%====================================================================

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE, [Host, Opts],
                           [{max_queue, 10000}]).

start(Host, Opts) ->
        Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
        ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
                     transient, 5000, worker, [?MODULE]},
        supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    catch ?GEN_SERVER:call(Proc, stop),
    supervisor:delete_child(ejabberd_sup, Proc).

values(Host) when is_binary(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, values, ?CALL_TIMEOUT).

reset(Host, PName) when is_binary(Host), is_atom(PName)  ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, {reset, PName}, ?CALL_TIMEOUT).

insert(Host, Item) when is_binary(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:cast(Proc, {insert, Item}).

get_log(Host) when is_binary(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, get_log, ?CALL_TIMEOUT).

add_log(Host, PName) when is_binary(Host), is_atom(PName) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:cast(Proc, {add_log, PName}).

del_log(Host, PName) when is_binary(Host), is_atom(PName) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:cast(Proc, {del_log, PName}).

sync_log(Host) when is_binary(Host) ->
    Cluster = ejabberd_cluster:get_nodes()--[node()],
    SLog = case ejabberd_cluster:multicall(Cluster, ?MODULE, get_log, [Host]) of
               {[], _BadNodes} ->
                   undefined;
               {Logs, _BadNodes} ->
                   lists:foldl(
                     fun(RLog, Acc) -> log_merge(RLog, Acc) end,
                     log_new(), Logs)
           end,
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:cast(Proc, {sync_log, SLog}).


%%====================================================================
%% server callbacks
%%====================================================================

init([Host, Opts]) ->
    % List of desired counters
    Pool = gen_mod:get_opt(pool, Opts,
                           fun(L) when is_list(L) -> L end,
                           [active_users]),

    % HyperLogLog backup path
    FileName = binary:replace(Host, <<".">>, <<"_">>, [global]),
    DefaultFile = filename:join([mnesia:system_info(directory),
                                 "hyperloglog",
                                 <<FileName/binary, ".bin">>]),
    File = gen_mod:get_opt(file, Opts,
                           fun(B) when is_binary(B) -> B end,
                           DefaultFile),

    try
        NLog = log_new(),
        ok = filelib:ensure_dir(File),
        L1 = [{PName, PLog} || {PName, PLog} <- read_logs(File),
                               lists:member(PName, Pool)],
        L2 = [{PName, NLog} || PName <- Pool,
                               not lists:keymember(PName, 1, L1)],
        Logs = L1++L2,
        [mod_mon:declare(Host, PName, gauge) || {PName, _PLog} <- Logs],
        [mod_mon:set(Host, PName, log_card(PLog)) || {PName, PLog} <- Logs],
        ok = write_logs(File, Logs),
        {ok, T} = timer:apply_interval(?HOUR, ?MODULE, sync_log, [Host]),
        ejabberd_hooks:add(sm_register_connection_hook, Host,
                           ?MODULE, sm_register_connection_hook, 20),
        ejabberd_commands:register_commands(get_commands_spec()),
        {ok, #state{host = Host, log = NLog, pool = Pool, file = File, timers = [T]}}
    catch
        error:Reason ->
            ?ERROR_MSG("Can not start active users count service: ~p", [Reason]),
            {stop, Reason}
    end.

handle_call(values, _From, State) ->
    File = State#state.file,
    Values = [{PName, log_card(PLog)} || {PName, PLog} <- read_logs(File)],
    {reply, Values, State};
handle_call({reset, PName}, _From, State) ->
    Host = State#state.host,
    File = State#state.file,
    Log = State#state.log,
    Value = flush_log(Host, File, Log, PName),
    {reply, Value, State#state{log = log_new()}};
handle_call(get_log, _From, State) ->
    {reply, State#state.log, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({insert, Item}, State) ->
    {noreply, State#state{log = log_insert(State#state.log, Item)}};
handle_cast({add_log, PName}, State) ->
    File = State#state.file,
    Logs = lists:keystore(PName, 1, read_logs(File), {PName, log_new()}),
    write_logs(File, Logs),
    {noreply, State#state{pool = proplists:get_keys(Logs)}};
handle_cast({del_log, PName}, State) ->
    File = State#state.file,
    Logs = lists:keydelete(PName, 1, read_logs(File)),
    write_logs(File, Logs),
    {noreply, State#state{pool = proplists:get_keys(Logs)}};
handle_cast({sync_log, ClusterLog}, State) ->
    Host = State#state.host,
    File = State#state.file,
    Log = case ClusterLog of
              undefined -> State#state.log;
              _ -> log_merge(State#state.log, ClusterLog)
          end,
    merge_logs(Host, File, Log),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#state.host,
    [timer:cancel(T) || T <- State#state.timers],
    ejabberd_hooks:delete(sm_register_connection_hook, Host,
                          ?MODULE, sm_register_connection_hook, 20),
    ejabberd_commands:unregister_commands(get_commands_spec()),
    merge_logs(Host, State#state.file, State#state.log),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% ejabberd commands
%%====================================================================

get_commands_spec() ->
    [#ejabberd_commands{name = active_counters,
                        tags = [stats],
                        desc = "Returns active users counter in time period (daily_active_users, weekly_active_users, monthly_active_users, period_active_users)",
                        module = ?MODULE, function = active_command,
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
     #ejabberd_commands{name = flush_active_counter,
                        tags = [stats],
                        desc = "Returns last value from probe and resets its historical data if any.",
                        module = ?MODULE, function = flush_active_command,
                        args = [{server, binary}, {counter, binary}],
                        result = {value, integer}}].

active_command(Host) ->
    case values(Host) of
        List when is_list(List) ->
            [{jlib:atom_to_binary(PName), Count}
             || {PName, Count} <- List];
        _ ->
            []
    end.

flush_active_command(Host, PName) ->
    case reset(Host, jlib:binary_to_atom(PName)) of
        N when is_integer(N) -> N;
        _ -> 0
    end.

%%====================================================================
%% Hooks handlers
%%====================================================================

sm_register_connection_hook(_SID, #jid{luser=LUser,lserver=LServer}, _Info) ->
    insert(LServer, LUser).

%%====================================================================
%% hyperloglog feature
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

% ehyperloglog api
log_new() -> ehyperloglog:new(16).
log_card(Log) -> round(ehyperloglog:cardinality(Log)).
log_insert(Log, Item) -> ehyperloglog:update(Item, Log).
log_merge(LogA, LogB) -> ehyperloglog:merge(LogA, LogB).
% hyper api
%log_new() -> hyper:new(16).
%log_card(Log) -> round(hyper:card(Log)).
%log_insert(Log, Item) -> hyper:insert(Item, Log).
%log_merge(LogA, LogB) -> hyper:union(LogA, LogB).

flush_log(Host, File, Log, Flush)  ->
    {Card, Logs} = lists:foldr(
             fun({PName, PLog}, {_, Acc}) when PName == Flush ->
                     Value = log_card(log_merge(PLog, Log)),
                     mod_mon:set(Host, Flush, Value),
                     {Value, [{PName, log_new()}|Acc]};
                ({PName, PLog}, {Value, Acc}) ->
                     {Value, [{PName, log_merge(PLog, Log)}|Acc]}
             end,
             {0, []}, read_logs(File)),
    write_logs(File, Logs),
    Card.

merge_logs(Host, File, Log) ->
    Logs = lists:foldr(
             fun({PName, PLog}, Acc) ->
                     MLog = log_merge(PLog, Log),
                     mod_mon:set(Host, PName, log_card(MLog)),
                     [{PName, MLog}|Acc]
             end,
             [], read_logs(File)),
    write_logs(File, Logs).

%%====================================================================
%% I/O operations
%%====================================================================

write_logs(File, Logs) when is_list(Logs) ->
    file:write_file(File, term_to_binary(Logs)).

read_logs(File) when is_binary(File) ->
    read_logs(file:read_file(File));
read_logs({ok, Bin}) when is_binary(Bin) ->
    read_logs(catch binary_to_term(Bin));
read_logs(List) when is_list(List) ->
    List;
read_logs(_) ->
    [].

%%====================================================================
%% Module configuration
%%====================================================================

depends(_Host, _Opts) ->
    [{mod_mon, hard}].

mod_opt_type(pool) ->
    fun (List) when is_list(List) -> List end;
mod_opt_type(file) ->
    fun (Bin) when is_binary(Bin) -> Bin end;
mod_opt_type(_) -> [pool,file].

opt_type(_) -> [].
