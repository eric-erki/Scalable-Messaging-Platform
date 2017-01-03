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
-module(ejabberd_pool).

-behaviour(supervisor).

%% API
-export([start_link/5, get_proc_by_hash/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================
start_link(PoolName, WorkerName, WorkerModule, WorkerArgs, Size) ->
    supervisor:start_link({local, PoolName}, ?MODULE, [WorkerName, WorkerModule, WorkerArgs, Size]).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================
init([WorkerName, WorkerModule, WorkerArgs, Size]) ->
    Specs = lists:map(fun(I)-> worker_spec(WorkerName, WorkerModule,WorkerArgs, I) end, lists:seq(1,Size)),
    {ok, {{one_for_one, Size*10, 1}, Specs}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
%%%
worker_spec(WorkerName, WorkerModule, WorkerArgs, I) ->
    {I,
     {WorkerModule, start_link, [get_proc_name(WorkerName, I), WorkerArgs]},
     permanent,
     brutal_kill,
     worker,
     [WorkerModule]}.


get_proc_name(WorkerName, I) ->
    jlib:binary_to_atom(<<(iolist_to_binary(atom_to_list(WorkerName)))/binary,
			    "_",
			    (iolist_to_binary(integer_to_list(I)))/binary>>).

get_proc_by_hash(WorkerName, PoolSize, Term) ->
    N = erlang:phash2(Term, PoolSize) +1,
    get_proc_name(WorkerName, N).
