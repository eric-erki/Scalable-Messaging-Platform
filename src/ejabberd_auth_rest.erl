%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_rest.erl
%%% Author  : Pablo Polvorin <pablo.polvorin@process-one.net>
%%% Based on ejabberd_auth_internal
%%%
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

-module(ejabberd_auth_rest).

-behaviour(ejabberd_auth).

%% External exports
-export([start/1, set_password/3, check_password/3,
         check_password/5, try_register/3,
         dirty_get_registered_users/0, get_vh_registered_users/1,
         get_vh_registered_users/2,
         get_vh_registered_users_number/1,
         get_vh_registered_users_number/2, get_password/2,
         get_password_s/2, is_user_exists/2, remove_user/2,
         remove_user/3, store_type/0,
         plain_password_required/0]).

-include("ejabberd.hrl").
-include("logger.hrl").

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(_Host) ->
    rest:start(),
    ok.

plain_password_required() -> true.

store_type() -> external.

check_password(_User, _Server, <<>>) ->
    false;
check_password(User, Server, Password) ->
    case rest:get(Server, "/user/auth", [{"username", User}, {"password",Password}]) of
        {ok, 200, _} -> true;
        _ -> false
    end.

is_user_exists(User, Server) ->
    case rest:get(Server, "/user", [{"username", User}]) of
        {ok, 200, _} -> true;
        _ -> false
    end.

%% Functions not implemented or not relevant for REST authentication

check_password(_User, _Server, _Password, _Digest, _DigestGen) ->
    false.

set_password(_User, _Server, _Password) ->
    {error, not_allowed}.

try_register(_User, _Server, _Password) ->
    {error, not_allowed}.

dirty_get_registered_users() ->
    [].

get_vh_registered_users(_Server) ->
    [].

get_vh_registered_users(_Server, _Data) ->
    [].

get_vh_registered_users_number(_Server) ->
    0.

get_vh_registered_users_number(_Server, _Data) ->
    0.

get_password(_User, _Server) ->
    false.

get_password_s(_User, _Server) ->
    <<"">>.


remove_user(_User, _Server) ->
    false.

remove_user(_User, _Server, _Password) ->
    false.
