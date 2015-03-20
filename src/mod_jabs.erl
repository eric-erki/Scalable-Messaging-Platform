%%% ====================================================================
%%% File    : mod_jabs.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Computation of JABS unit
%%% Created : 19 Dec 2014 by Christophe Romain <christophe.romain@process-one.net>
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
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%% ====================================================================

-module(mod_jabs).
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

-record(jabs, {host, counter, stamp, timer}).

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
    gen_server:call(process(Host), value, ?CALL_TIMEOUT).

reset(Host) ->
    gen_server:cast(process(Host), reset).

%%====================================================================
%% callbacks
%%====================================================================

init([Host, _Opts]) ->
    mnesia:create_table(jabs, [{disc_copies, [node()]},
                               {local_content, true},
                               {attributes, record_info(fields, jabs)}]),
    ejabberd_commands:register_commands(commands(Host)),
    {ok, TRef} = timer:send_interval(60000*15, backup),  % backup every 15 minutes
    Jabs = case mnesia:dirty_read({jabs, Host}) of
        [#jabs{}=Record] -> Record;
        _ -> #jabs{host = Host, counter = 0, stamp = os:timestamp(), timer = TRef}
    end,
    [ejabberd_hooks:add(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    {ok, Jabs}.

handle_call(value, _From, State) ->
    {reply, {State#jabs.counter, State#jabs.stamp}, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({inc, Step}, State) ->
    Old = State#jabs.counter,
    {noreply, State#jabs{counter = Old+Step}};
handle_cast(reset, State) ->
    {noreply, State#jabs{counter = 0, stamp = os:timestamp()}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(backup, State) ->
    mnesia:dirty_write(State),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#jabs.host,
    timer:cancel(State#jabs.timer),
    [ejabberd_hooks:delete(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    mnesia:dirty_write(State#jabs{timer = undefined}),
    ejabberd_commands:unregister_commands(commands(Host)).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Helper functions
%%====================================================================

process(Host) ->
    gen_mod:get_module_proc(Host, ?PROCNAME).

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

sm_register_connection_hook(_SID, #jid{lserver=Host}, _Info) ->
    gen_server:cast(process(Host), {inc, 5}).

user_send_packet(Packet, _C2SState, From, To) ->
    user_send_packet(From, To, Packet).
user_send_packet(#jid{lserver=Host}, _To, Packet) ->
    gen_server:cast(process(Host), {inc, 1}),
    Packet.
