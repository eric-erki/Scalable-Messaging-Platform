%%%-------------------------------------------------------------------
%%% File    : mod_jabs.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Computation of JABS unit
%%% Created : 19 Dec 2014 by Christophe Romain <christophe.romain@process-one.net>
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


-module(mod_jabs).

-behaviour(ejabberd_config).
-author('christophe.romain@process-one.net').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("ejabberd_commands.hrl").
-include("mod_jabs.hrl").

%% module API
-export([start_link/2, start/2, stop/1]).
-export([value/1, reset/1, add/2]).
%% administration commands
-export([jabs_count_command/1, jabs_since_command/1, jabs_reset_command/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% handled ejabberd hooks
-export([badauth/3, sm_register_connection_hook/3, user_send_packet/3, user_send_packet/4]).

-export([depends/2, mod_opt_type/1, opt_type/1]).

-callback init(binary(), gen_mod:opts()) -> any().
-callback read(binary()) -> {ok, #jabs{}} | {error, any()}.
-callback write(#jabs{}) -> ok | {error, any()}.
-callback match(binary()) -> [{node(), #jabs{}}].
-callback clean(binary()) -> ok.

-define(PROCNAME, ?MODULE).
-define(CALL_TIMEOUT, 5000).
-define(SUPPORTED_HOOKS, [badauth, sm_register_connection_hook, user_send_packet]).

%%====================================================================
%% API
%%====================================================================

start_link(Host, Opts) ->
    gen_server:start_link({local, process(Host)}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    ChildSpec = {process(Host), {?MODULE, start_link, [Host, Opts]},
                 transient, 5000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = process(Host),
    gen_server:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

value(Host) ->
    Proc = process(Host),
    case whereis(Proc) of
        undefined ->
            undefined;
        _ ->
            case gen_server:call(Proc, values, ?CALL_TIMEOUT) of
                [] ->
                    gen_server:call(Proc, value, ?CALL_TIMEOUT);
                Values ->
                    lists:foldl(
                        fun ({_N, C, S}, {CAcc, SAcc}) when S<SAcc -> {CAcc+C, S};
                            ({_N, C, _S}, {CAcc, SAcc}) -> {CAcc+C, SAcc}
                        end,
                        {0, os:timestamp()}, Values)
            end
    end.

reset(Host) ->
    Proc = process(Host),
    ejabberd_cluster:multicall(gen_server, cast, [Proc, reset]),
    gen_server:cast(Proc, clean_db).  %% db backend takes care of cluster replication

add(Host, Count) ->
    gen_server:cast(process(Host), {inc, Count}).

%%====================================================================
%% callbacks
%%====================================================================

init([Host, Opts]) ->
    Mod = gen_mod:db_mod(Host, Opts, ?MODULE),
    Mod:init(Host, Opts),
    ejabberd_commands:register_commands(commands(Host)),
    Ignore = gen_mod:get_opt(ignore, Opts,
                             fun(L) when is_list(L) -> L end, []),
    {ok, TRef} = timer:send_interval(60000, backup),  % backup every 60s
    R1 = read_db(Host),
    IgnoreLast = lists:usort(Ignore++R1#jabs.ignore),
    R2 = R1#jabs{ignore = IgnoreLast, timer = TRef},
    % temporary hack for SaaS: if stamp is more than 31 days old
    % then force reset (in case of node saas upgrade)
    Age = timer:now_diff(os:timestamp(), R2#jabs.stamp) div 1000000,
    Jabs = if Age > 2678400 -> reset_jabs(R2);
              true -> R2
    end,
    write_db(Jabs),
    [ejabberd_hooks:add(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    {ok, Jabs}.

handle_call(value, _From, State) ->
    {reply, {State#jabs.counter, State#jabs.stamp}, State};
handle_call(values, _From, State) ->
    Host = State#jabs.host,
    Values = [{Node, Jabs#jabs.counter, Jabs#jabs.stamp}
              || {Node, Jabs} <- match_db(Host)],
    {reply, Values, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({inc, Step, User}, State) ->
    case lists:member(User, State#jabs.ignore) of
        true ->
            {noreply, State};
        false ->
            Old = State#jabs.counter,
            {noreply, State#jabs{counter = Old+Step}}
    end;
handle_cast({inc, Step}, State) ->
    Old = State#jabs.counter,
    {noreply, State#jabs{counter = Old+Step}};
handle_cast({dec, Step}, State) ->
    Old = State#jabs.counter,
    {noreply, State#jabs{counter = Old-Step}};
handle_cast({ignore, User}, State) ->
    Ignore = lists:usort([User|State#jabs.ignore]),
    {noreply, State#jabs{ignore = Ignore}};
handle_cast({attend, User}, State) ->
    Ignore = lists:delete(User, State#jabs.ignore),
    {noreply, State#jabs{ignore = Ignore}};
handle_cast(clean_db, State) ->
    clean_db(State#jabs.host),
    {noreply, State};
handle_cast(reset, State) ->
    {noreply, reset_jabs(State)};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(backup, State) ->
    spawn(fun() -> write_db(State) end),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#jabs.host,
    timer:cancel(State#jabs.timer),
    [ejabberd_hooks:delete(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    write_db(State#jabs{timer = undefined}),
    ejabberd_commands:unregister_commands(commands(Host)).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Helper functions
%%====================================================================

process(Host) ->
    gen_mod:get_module_proc(Host, ?PROCNAME).

reset_jabs(#jabs{} = R) ->
    R#jabs{counter = 0, stamp = os:timestamp()}.

%%====================================================================
%% database functions
%%====================================================================
read_db(Host) when is_binary(Host) ->
    Mod = gen_mod:db_mod(Host, ?MODULE),
    case Mod:read(Host) of
	{ok, Jabs} -> Jabs;
	_ -> reset_jabs(#jabs{host = Host})
    end.

write_db(Jabs) when is_record(Jabs, jabs) ->
    Mod = gen_mod:db_mod(Jabs#jabs.host, ?MODULE),
    Mod:write(Jabs).

match_db(Host) when is_binary(Host) ->
    Mod = gen_mod:db_mod(Host, ?MODULE),
    Mod:match(Host).

clean_db(Host) when is_binary(Host) ->
    Mod = gen_mod:db_mod(Host, ?MODULE),
    Mod:clean(Host).

%%====================================================================
%% ejabberd commands
%%====================================================================

commands(Host) when is_binary(Host) ->
    commands2(binary);
commands(Host) when is_list(Host) ->
    commands2(string).

commands2(ArgType) -> [
     #ejabberd_commands{name = jabs_count,
                        tags = [stats],
                        desc = "Returns the current value of jabs counter",
                        module = ?MODULE, function = jabs_count_command,
                        args = [{server, ArgType}],
                        result = {res, integer}},
     #ejabberd_commands{name = jabs_since,
                        tags = [stats],
                        desc = "Returns start date of jabs counter",
                        module = ?MODULE, function = jabs_since_command,
                        args = [{server, ArgType}],
                        result = {res, string}},
     #ejabberd_commands{name = jabs_reset,
                        tags = [stats],
                        desc = "Reset jabs counter",
                        module = ?MODULE, function = jabs_reset_command,
                        args = [{server, ArgType}],
                        result = {res, string}}].

jabs_count_command(Host) ->
    {Count, _} = value(Host),
    Count.

jabs_since_command(Host) ->
    {_, Stamp} = value(Host),
    {{Y,M,D},{HH,MM,SS}} = calendar:now_to_datetime(Stamp),
    lists:flatten(io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
                                [Y, M, D, HH, MM, SS])).

jabs_reset_command(Host) ->
    atom_to_list(reset(Host)).

%%====================================================================
%% Hooks handlers
%%====================================================================

badauth(LUser, LServer, _Password) ->
    gen_server:cast(process(LServer), {inc, 3, LUser}).

sm_register_connection_hook(_SID, #jid{luser=User,lserver=Host}, _Info) ->
    gen_server:cast(process(Host), {inc, 5, User}).

user_send_packet(Packet, _C2SState, From, To) ->
    user_send_packet(From, To, Packet).
user_send_packet(#jid{luser=User,lserver=Host}, _To, Packet) ->
    Size = erlang:external_size(Packet),
    gen_server:cast(process(Host), {inc, 1+(Size div 5120), User}),
    Packet.

depends(_Host, _Opts) ->
    [].

mod_opt_type(db_type) -> fun(T) -> ejabberd_config:v_db(?MODULE, T) end;
mod_opt_type(ignore) ->
    fun (L) when is_list(L) -> L end;
mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(_) -> [db_type, ignore, p1db_group].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
