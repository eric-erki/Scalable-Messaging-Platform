%%%----------------------------------------------------------------------
%%% File    : mod_muc_log_saas.erl
%%% Purpose : Simple wrapper around mod_muc_log to make it work on saas env.
%%%           Only one instance of mod_muc_log should be running on saas cluster.
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
%%%----------------------------------------------------------------------

-module(mod_muc_log_saas).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).
-behaviour(gen_mod).
-behaviour(ejabberd_config).

%% API
-export([start_link/2, start/2, stop/1]).
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1, opt_type/1, depends/2]).

-include("ejabberd.hrl").
-include("logger.hrl").

-define(PROCNAME, ?MODULE).
-define(CHECK_INTERVAL, 60 * 1000).  %% 1 minute

-record(state, {host, opts, timer}).

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 transient, 5000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    catch ?GEN_SERVER:call(Proc, stop),
    supervisor:delete_child(ejabberd_sup, Proc).

init([Host, Opts]) ->
    self() ! check,
    Ref = timer:send_interval(?CHECK_INTERVAL, self(), check),
    {ok, #state{host = Host, opts = Opts, timer = Ref}}.

terminate(_Reason, State) ->
    timer:cancel(State#state.timer),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

handle_call(stop, _From, State) ->
    Host = State#state.host,
    case mod_muc_log:whereis_proc(Host) of
        Pid when is_pid(Pid) ->
            Node = node(),
            case node(Pid) of
                Node -> stop_muc_log(Host);
                _ -> ok
            end;
        undefined ->
            ok
    end,
    {stop, normal, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(check, State) ->
    Host = State#state.host,
    case mod_muc_log:whereis_proc(Host) of
        Pid when is_pid(Pid) -> ok;
        undefined -> start_muc_log(Host, State#state.opts)
    end,
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

start_muc_log(Host, Opts) ->
    gen_mod:start_module(Host, mod_muc_log, Opts).

stop_muc_log(Host) ->
    gen_mod:stop_module(Host, mod_muc_log).

depends(_Host, _Opts) ->
    [{mod_muc, hard}].

mod_opt_type(Opt) ->
    mod_muc_log:mod_opt_type(Opt).

opt_type(Opt) ->
    mod_muc_log:opt_type(Opt).
