%%%-------------------------------------------------------------------
%%% @author Pablo Polvorin <pablo.polvorin@process-one.net>
%%% @doc
%%%
%%% @end
%%%
%%%
%%% ejabberd, Copyright (C) 2012-2017   ProcessOne
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
-module(mod_offline_sup).

-behaviour(supervisor).

%% API
-export([start/2, stop/1, get_worker_for/2, status/1]).

-export([start_link/2, init/1, mod_opt_type/1]).

-define(SERVER, ?MODULE).

-define(PROCNAME, ejabberd_offline_sup).

-define(DEFAULT_POOL_SIZE, 16).



get_pool_size(Host) ->
    gen_mod:get_module_opt(Host, mod_offline,  pool_size,
                           fun(N) when is_integer(N) -> N end,
                           ?DEFAULT_POOL_SIZE).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 permanent, 1000, supervisor, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc),
    ok.

status(Host) ->
    PoolName = gen_mod:get_module_proc(Host, mod_offline_pool),
    Workers = supervisor:which_children(PoolName),
    lists:map(fun({Id, Pid, worker, _}) ->
                      {Id,
                       Pid,
                       element(2,erlang:process_info(Pid, message_queue_len)),
                       proplists:get_value('$internal_queue_len',element(2,erlang:process_info(Pid, dictionary)),0)}
              end , Workers).


%%%===================================================================
%%% API functions
%%%===================================================================
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    supervisor:start_link({local, Proc}, ?MODULE, [Host, Opts]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================
init([Host, Opts]) ->
    PoolSize = gen_mod:get_opt(pool_size, Opts,
                           fun(N) when is_integer(N) -> N end,
                           ?DEFAULT_POOL_SIZE),
    PoolName = gen_mod:get_module_proc(Host, mod_offline_pool),
    WorkerName = gen_mod:get_module_proc(Host, mod_offline_worker),
    WorkerSupSpec = {worker_sup,
                     {ejabberd_pool, start_link, [PoolName, WorkerName, mod_offline_worker, [Host,Opts], PoolSize]},
                     permanent, brutal_kill, supervisor, [ejabberd_pool]},
    ModOfflineProcSpec =
                    {mod_offline,
                    {mod_offline, start_link, [Host, Opts]},
                    transient, brutal_kill, worker, [mod_offline]},

    {ok, {{rest_for_one, 10, 1}, [WorkerSupSpec, ModOfflineProcSpec]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%%

get_worker_for(Host, Term) ->
    PoolSize = get_pool_size(Host),
    WorkerName = gen_mod:get_module_proc(Host, mod_offline_worker),
    ejabberd_pool:get_proc_by_hash(WorkerName, PoolSize, Term).

mod_opt_type(pool_size) ->
    fun (N) when is_integer(N) -> N end;
mod_opt_type(_) -> [pool_size].
