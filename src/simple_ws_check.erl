%%%----------------------------------------------------------------------
%%% File    : simple_ws_check.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : websocket check code
%%% Created : 19 Jan 2011 by Eric Cestari <ecestari@process-one.net>
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
%%%----------------------------------------------------------------------

-module(simple_ws_check).

-export([is_acceptable/6]).

-include("ejabberd.hrl").
-include("logger.hrl").

is_acceptable([<<"true">>] = Path, Q, Origin, Protocol,
	      IP, Headers) ->
    ?INFO_MSG("Authorized Websocket ~p with: ~n Q = "
	      "~p~n Origin = ~p~n Protocol = ~p~n IP "
	      "= ~p~n Headers = ~p~n",
	      [Path, Q, Origin, Protocol, IP, Headers]),
    true;
is_acceptable([<<"false">>] = Path, Q, Origin, Protocol,
	      IP, Headers) ->
    ?INFO_MSG("Failed Websocket ~p with: ~n Q = ~p~n "
	      "Origin = ~p~n Protocol = ~p~n IP = ~p~n "
	      "Headers = ~p~n",
	      [Path, Q, Origin, Protocol, IP, Headers]),
    false.
