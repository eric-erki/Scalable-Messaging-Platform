%%% ====================================================================
%%% This software is copyright 2006-2015, ProcessOne.
%%%
%%% Computation of JABS unit
%%%
%%% @copyright 2006-2015 ProcessOne
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
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

-record(state, {host, jabs, timestamp}).

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
    [ejabberd_hooks:add(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    ejabberd_commands:register_commands(commands(Host)),
    {ok, #state{host = Host, jabs = 0, timestamp = now()}}.

handle_call(value, _From, State) ->
    Jabs = State#state.jabs,
    Timestamp = State#state.timestamp,
    {reply, {Jabs, Timestamp}, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast({inc, Step}, State) ->
    Old = State#state.jabs,
    {noreply, State#state{jabs = Old+Step}};
handle_cast(reset, State) ->
    {noreply, State#state{jabs = 0, timestamp = now()}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#state.host,
    [ejabberd_hooks:delete(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
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
                        result = {count, integer}},
     #ejabberd_commands{name = jabs_since,
                        tags = [stats],
                        desc = "Returns start date of jabs counter",
                        module = ?MODULE, function = jabs_since_command,
                        args = [{server, ArgType}],
                        result = {since, string}},
     #ejabberd_commands{name = jabs_reset,
                        tags = [stats],
                        desc = "Reset jabs counter",
                        module = ?MODULE, function = jabs_reset_command,
                        args = [{server, ArgType}],
                        result = {result, string}}].

jabs_count_command(Host) ->
    {Count, _} = value(Host),
    Count.

jabs_since_command(Host) ->
    {_, Timestamp} = value(Host),
    {{Y,M,D},{HH,MM,SS}} = calendar:now_to_datetime(Timestamp),
    io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B",
                           [Y, M, D, HH, MM, SS]).

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
