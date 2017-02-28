%%%----------------------------------------------------------------------
%%% File    : mod_cleanup.erl
%%% Author  : Christophe Romain <cromain@process-one.net>
%%% Purpose : garbage collect consumming processes and restart applications
%%% Created : 21 Nov 2014 by Christophe Romain <cromain@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2014-2017   ProcessOne
%%%
%%% Usage:
%%%   Declare this mod_cleanup in your ejabberd modules config section.
%%%     mod_cleanup:
%%%       memory_limit: 150000
%%%       warn: false
%%%       applications: lhttpc
%%%
%%% ----------------------------------------------------------------------

-module(mod_cleanup).
-behaviour(gen_mod).
-author('cromain@process-one.net').

-export([start/2, stop/1, loop/1,
	 mod_opt_type/1, depends/2]).

%% hook callbacks
-export([c2s/1, s2s/1, iq/6, http/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-define(PROCNAME, cleaner).

-record(state, {memory_limit, warn, applications}).

start(_Host, Opts) ->
    Limit = gen_mod:get_opt(memory_limit, Opts,
                            fun(I) when is_integer(I), I>0 -> I end,
                            16384), % 128kb on 64bit system
    Warn = gen_mod:get_opt(warn, Opts,
                           fun(B) when is_boolean(B) -> B end,
                           false),
    Apps = gen_mod:get_opt(applications, Opts,
                           fun(L) when is_list(L) -> L end,
                           []),
    State = #state{memory_limit = Limit, warn = Warn, applications = Apps},
    ejabberd_hooks:add(c2s_loop_debug, ?MODULE, c2s, 50),
    ejabberd_hooks:add(s2s_loop_debug, ?MODULE, s2s, 50),
    ejabberd_hooks:add(process_iq_debug, ?MODULE, iq, 50),
    ejabberd_hooks:add(http_request_debug, ?MODULE, http, 50),
    case whereis(?PROCNAME) of
        undefined -> register(?PROCNAME, spawn(?MODULE, loop, [State]));
        Pid -> Pid
    end.

stop(_Host) ->
    ?PROCNAME ! stop,
    ejabberd_hooks:delete(c2s_loop_debug, ?MODULE, c2s, 50),
    ejabberd_hooks:delete(s2s_loop_debug, ?MODULE, s2s, 50),
    ejabberd_hooks:delete(process_iq_debug, ?MODULE, iq, 50),
    ejabberd_hooks:delete(http_request_debug, ?MODULE, http, 50).

c2s(LastReceivedPacket) ->
    ?PROCNAME ! {check, c2s, self(), LastReceivedPacket}.

s2s(LastReceivedPacket) ->
    ?PROCNAME ! {check, s2s, self(), LastReceivedPacket}.

iq(Module, Function, From, To, IQ, Result) ->
    Packet = {Module, Function, From, To, IQ, Result},
    ?PROCNAME ! {check, process_iq, self(), Packet}.

http(Packet) ->
    ?PROCNAME ! {check, http, self(), Packet}.

%% loop handler
%% TODO: switch to p1_server

loop(State) ->
    receive
        {check, Context, Pid, Packet} ->
            case process_info(Pid, total_heap_size) of
                {total_heap_size, Words}
                        when Words > State#state.memory_limit ->
                    [?WARNING_MSG("Large memory consumption [~p] (~p) = ~p",
                                  [Context, Pid, Packet])
                     || State#state.warn == true],
                    erlang:garbage_collect(Pid);
                _ ->
                    ok
            end,
            loop(State);
        garbage_collect ->
            [erlang:garbage_collect(Pid)
             || Pid <- erlang:processes(),
                element(2, process_info(Pid, total_heap_size)) > State#state.memory_limit],
            loop(State);
        restart ->
            lists:foreach(fun(App) ->
                        application:stop(App),
                        application:start(App)
                end, State#state.applications),
            loop(State);
        stop ->
            ok
    end.

depends(_Host, _Opts) ->
    [].

mod_opt_type(memory_limit) ->
    fun (A) when is_integer(A) andalso A > 0 -> A end;
mod_opt_type(warn) ->
    fun (A) when is_boolean(A) -> A end;
mod_opt_type(applications) ->
    fun(L) when is_list(L) -> L end;
mod_opt_type(_) -> [memory_limit, warn, applications].
