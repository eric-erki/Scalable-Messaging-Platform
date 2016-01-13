%%%-------------------------------------------------------------------
%%% File    : mod_jabs.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Computation of JABS unit
%%% Created : 19 Dec 2014 by Christophe Romain <christophe.romain@process-one.net>
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


-module(mod_jabs).

-behaviour(ejabberd_config).
-author('christophe.romain@process-one.net').
-behaviour(gen_mod).
-behaviour(gen_server).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("ejabberd_commands.hrl").

%% module API
-export([start_link/2, start/2, stop/1]).
-export([value/1, reset/1]).
%% administration commands
-export([jabs_count_command/1, jabs_since_command/1, jabs_reset_command/1]).
%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% handled ejabberd hooks
-export([sm_register_connection_hook/3, user_send_packet/3, user_send_packet/4]).

-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2,
	 mod_opt_type/1, opt_type/1]).

-record(jabs, {host, counter, stamp, timer, ignore=[]}).

-define(PROCNAME, ?MODULE).
-define(CALL_TIMEOUT, 4000).
-define(SUPPORTED_HOOKS, [sm_register_connection_hook, user_send_packet]).

%%====================================================================
%% API
%%====================================================================

start_link(Host, Opts) ->
    gen_server:start_link({local, process(Host)}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    ChildSpec = {process(Host), {?MODULE, start_link, [Host, Opts]},
                 temporary, 1000, worker, [?MODULE]},
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
    gen_server:cast(process(Host), reset).

%%====================================================================
%% callbacks
%%====================================================================

init([Host, Opts]) ->
    init_db(gen_mod:db_type(Host, Opts), Host),
    ejabberd_commands:register_commands(commands(Host)),
    Ignore = gen_mod:get_opt(ignore, Opts,
                             fun(L) when is_list(L) -> L end, []),
    {ok, TRef} = timer:send_interval(60000*5, backup),  % backup every 5 minutes
    R1 = read_db(Host),
    IgnoreLast = lists:usort(Ignore++R1#jabs.ignore),
    R2 = R1#jabs{ignore = IgnoreLast, timer = TRef},
    % temporary hack for SaaS: if stamp is more than 31 days old
    % then force reset (in case of node saas upgrade)
    Age = timer:now_diff(os:timestamp(), R2#jabs.stamp) div 1000000,
    Jabs = if Age > 2678400 ->  % 31 days in seconds
            R2#jabs{counter = 0, stamp = os:timestamp()};
        true ->
            R2
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
handle_cast(reset, State) ->
    clean_db(State#jabs.host),
    {noreply, State#jabs{counter = 0, stamp = os:timestamp()}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(backup, State) ->
    write_db(State),
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

%%====================================================================
%% database functions
%%====================================================================

init_db(mnesia, _Host) ->
    mnesia:create_table(jabs, [{disc_copies, [node()]},
                               {local_content, true},
                               {attributes, record_info(fields, jabs)}]);
init_db(p1db, Host) ->
    Group = gen_mod:get_module_opt(Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end, 
                        ejabberd_config:get_option(
                            {p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    [Key|Values] = record_info(fields, jabs),
    p1db:open_table(pubsub_state,
                        [{group, Group}, {nosync, true},
                         {schema, [{keys, [Key]},
                                   {vals, Values},
                                   {enc_key, fun ?MODULE:enc_key/1},
                                   {dec_key, fun ?MODULE:dec_key/1},
                                   {enc_val, fun ?MODULE:enc_val/2},
                                   {dec_val, fun ?MODULE:dec_val/2}]}]);
init_db(_, _) ->
    ok.

read_db(Host) when is_binary(Host) ->
    read_db(Host, gen_mod:db_type(Host, ?MODULE)).

read_db(Host, mnesia) ->
    case catch mnesia:dirty_read(jabs, {Host, node()}) of
        [#jabs{}=Jabs] -> Jabs#jabs{host = Host};
        _ -> #jabs{host = Host, counter = 0, stamp = os:timestamp()}
    end;
read_db(Host, p1db) ->
    Key = enc_key({Host, node()}),
    case p1db:get(jabs, Key) of
        {ok, Val, _VClock} -> (p1db_to_jabs(Key, Val))#jabs{host = Host};
        _ -> #jabs{host = Host, counter = 0, stamp = os:timestamp()}
    end;
read_db(Host, _) ->
    #jabs{host = Host, counter = 0, stamp = os:timestamp()}.

write_db(Jabs) when is_record(Jabs, jabs) ->
    write_db(Jabs, gen_mod:db_type(Jabs#jabs.host, ?MODULE)).

write_db(Jabs, mnesia) ->
    Key = {Jabs#jabs.host, node()},
    ejabberd_cluster:multicall(mnesia, dirty_write, [Jabs#jabs{host=Key}]);
write_db(Jabs, p1db) ->
    Key = enc_key({Jabs#jabs.host, node()}),
    p1db:insert(jabs, Key, jabs_to_p1db(Jabs));
write_db(_, _) ->
    ok.

match_db(Host) when is_binary(Host) ->
    match_db(Host, gen_mod:db_type(Host, ?MODULE)).

match_db(Host, mnesia) ->
    Record = #jabs{host = {Host, '_'}, _ = '_'},
    lists:map(fun(Jabs) ->
                {Host, Node} = Jabs#jabs.host,
                {Node, Jabs#jabs{host = Host}}
        end, mnesia:dirty_match_object(Record));
match_db(Host, p1db) ->
    case p1db:get_by_prefix(jabs, enc_key(Host)) of
        {ok, L} ->
            lists:map(fun(Jabs) ->
                        {Host, Node} = Jabs#jabs.host,
                        {Node, Jabs#jabs{host = Host}}
                end, [p1db_to_jabs(Key, Val) || {Key, Val, _} <- L]);
        _ ->
            []
    end;
match_db(_, _) ->
    [].

clean_db(Host) when is_binary(Host) ->
    clean_db(Host, gen_mod:db_type(Host, ?MODULE)).

clean_db(Host, mnesia) ->
    Record = #jabs{host = {Host, '_'}, _ = '_'},
    ejabberd_cluster:multicall(mnesia, dirty_delete_object, [Record]),
    ok;
clean_db(Host, p1db) ->
    case p1db:get_by_prefix(jabs, enc_key(Host)) of
        {ok, L} -> [p1db:delete(jabs, Key) || {Key, _, _} <- L], ok;
        _ -> ok
    end;
clean_db(_, _) ->
    ok.

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

sm_register_connection_hook(_SID, #jid{luser=User,lserver=Host}, _Info) ->
    gen_server:cast(process(Host), {inc, 5, User}).

user_send_packet(Packet, _C2SState, From, To) ->
    user_send_packet(From, To, Packet).
user_send_packet(#jid{luser=User,lserver=Host}, _To, Packet) ->
    gen_server:cast(process(Host), {inc, 1, User}),
    Packet.

%%====================================================================
%% p1db helpers
%%====================================================================

jabs_to_p1db(Jabs) when is_record(Jabs, jabs) ->
    term_to_binary([
            {counter, Jabs#jabs.counter},
            {stamp, Jabs#jabs.stamp},
            {timer, Jabs#jabs.timer},
            {ignore, Jabs#jabs.ignore}]).
p1db_to_jabs(Key, Val) when is_binary(Key) ->
    p1db_to_jabs(dec_key(Key), Val);
p1db_to_jabs({Host, Node}, Val) ->
    lists:foldl(
        fun ({counter, C}, J) -> J#jabs{counter=C};
            ({stamp, S}, J) -> J#jabs{stamp=S};
            ({timer, T}, J) -> J#jabs{timer=T};
            ({ignore, I}, J) -> J#jabs{ignore=I};
            (_, J) -> J
        end, #jabs{host={Host, Node}}, binary_to_term(Val)).

enc_key({Host, Node}) ->
    N = jlib:atom_to_binary(Node),
    <<Host/binary, 0, N/binary>>;
enc_key(Host) ->
    <<Host/binary, 0>>.
dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Host:SLen/binary, 0, N/binary>> = Key,
    {Host, jlib:binary_to_atom(N)}.

enc_val(_, [Counter, Stamp, Timer, Ignore]) ->
    jabs_to_p1db(#jabs{
            counter=Counter,
            stamp=Stamp,
            timer=Timer,
            ignore=Ignore}).
dec_val(Key, Bin) ->
    J = p1db_to_jabs(Key, Bin),
    [J#jabs.counter,
     J#jabs.stamp,
     J#jabs.timer,
     J#jabs.ignore].


mod_opt_type(db_type) -> fun gen_mod:v_db/1;
mod_opt_type(ignore) ->
    fun (L) when is_list(L) -> L end;
mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(_) -> [db_type, ignore, p1db_group].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
