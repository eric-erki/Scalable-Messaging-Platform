%%%----------------------------------------------------------------------
%%% File    : websocket_test.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : websocket check code
%%% Created : 19 Jan 2011 by Eric Cestari <ecestari@process-one.net>
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

-module(websocket_test).

-export([start_link/1, loop/1]).

start_link(Ws) ->
    Pid = spawn_link(?MODULE, loop, [Ws]), {ok, Pid}.

loop(Ws) ->
    receive
      {browser, Data} ->
	  Ws:send([<<"received '">>, Data, <<"'">>]), loop(Ws);
      _Ignore -> loop(Ws)
      after 5000 -> Ws:send(<<"pushing!">>), loop(Ws)
    end.
