%%%----------------------------------------------------------------------
%%% File    : mod_muc_log_saas.erl
%%% Purpose : Simple wrapper around mod_muc_log to make it work on saas env.
%%%
%%% ejabberd, Copyright (C) 2002-2014   ProcessOne
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
%%%----------------------------------------------------------------------

-module(mod_muc_log_saas).

-behaviour(gen_mod).

%% API
-export([start_link/2, start/2, stop/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-define(MAX_START_RETRIES, 5).

start_link(Host, Opts) ->
    start_with_retry(Host, Opts, 0).


start_with_retry(Host, _Opts, Retries) when Retries == ?MAX_START_RETRIES ->
    ?ERROR_MSG("Max retries reached (~p), mod_muc_log_saas (~p) can't be started", [Retries, Host]),
    error;
start_with_retry(Host, Opts, Retries) ->
    try
        case mod_muc_log:whereis_proc(Host) of
            Pid when is_pid(Pid) ->
                rpc:call(node(Pid), ?MODULE, stop, [Host]);
            undefined ->
                ok
        end,
        mod_muc_log:start_link(Host, Opts)
    catch
        _:Error ->
            % I think there could be delays between the process is stoped in possibly remote node,
            % and the name be ready to global register again from here. This retry is for that
            NewRetries = Retries +1,
            Sleep = 200 * NewRetries,
            ?ERROR_MSG("Error(~p) starting mod_muc (~p), retry in ~p milliseconds: ~p", [NewRetries, Host, Sleep, Error]),
            timer:sleep(Sleep),
            start_with_retry(Host, Opts, Retries +1)
    end.




start(Host, Opts) ->
    mod_muc_log:start(Host, Opts).

stop(Host) ->
    mod_muc_log:stop(Host).
