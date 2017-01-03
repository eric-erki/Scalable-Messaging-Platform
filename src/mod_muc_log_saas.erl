%%%----------------------------------------------------------------------
%%% File    : mod_muc_log_saas.erl
%%% Purpose : Simple wrapper around mod_muc_log to make it work on saas env.
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

-behaviour(gen_mod).

%% API
-export([start_link/2, start/2, stop/1]).

-export([check_proc_running/2, depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-define(CHECK_INTERVAL, 60 * 1000).  %% 1 minute

start_link(Host, Opts) ->
    mod_muc_log:start_link(Host, Opts).

%% Workaround for unique muc log process in saas: we just keep asking periodically if there is a log process registered in the cluster,
%% and if not, start it in the local node.
check_proc_running(Host, Opts) ->
    case mod_muc_log:whereis_proc(Host) of
        Pid when is_pid(Pid) ->
            ok;
        undefined ->
             Proc = mod_muc_log:get_proc_name(Host),
             ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
	    	 transient, 1000, worker, [mod_muc_log]},
             supervisor:start_child(ejabberd_sup, ChildSpec)
    end.

start(Host, Opts) ->
    timer:apply_interval(?CHECK_INTERVAL, ?MODULE, check_proc_running, [Host, Opts]),
    check_proc_running(Host, Opts). %%do an check right now, to run it at startup when it is the first node

stop(Host) ->
    mod_muc_log:stop(Host).

depends(_Host, _Opts) ->
    [{mod_muc, hard}].

mod_opt_type(Opt) ->
    mod_muc_log:mod_opt_type(Opt).
