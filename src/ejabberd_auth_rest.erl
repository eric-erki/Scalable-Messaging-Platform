%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_rest.erl
%%% Author  : Pablo Polvorin <pablo.polvorin@process-one.net>
%%% Based on ejabberd_auth_mnesia
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

-module(ejabberd_auth_rest).

-behaviour(ejabberd_config).

-behaviour(ejabberd_auth).

-export([start/1, set_password/3, check_password/4,
	 check_password/6, try_register/3,
	 dirty_get_registered_users/0, get_vh_registered_users/1,
	 get_vh_registered_users/2,
	 get_vh_registered_users_number/1,
	 get_vh_registered_users_number/2, get_password/2,
	 get_password_s/2, is_user_exists/2, remove_user/2,
	 remove_user/3, store_type/0, plain_password_required/0,
	 test/2, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(Host) ->
    rest:start(Host),
    ok.

test(Host, Pairs) when is_binary(Host), is_list(Pairs) ->
    [{User, is_user_exists(User, Host), check_password(User, <<>>, Host, Password)}
     || {User, Password} <- Pairs].

plain_password_required() -> true.

store_type() -> external.

check_password(_User, _AuthzId, _Server, <<>>) ->
    false;
check_password(User, AuthzId, Server, Password) ->
    if AuthzId /= <<>> andalso AuthzId /= User ->
        false;
    true ->
        Path = path(Server, auth),
        case rest:get(Server, Path ,
    		  [{"username", User}, {"password",Password}]) of
    	{ok, 200, _RespBody} ->
                true;
            {ok, 401, _RespBody} ->
                ?WARNING_MSG("API rejected authentication for user ~p (~p) password ~p, resp: ~p" ,[User, Server, Password, _RespBody]),
                ejabberd_hooks:run(backend_api_badauth, Server, [Server, get, Path]),
                false;
            {ok, Other, RespBody} ->
                ?ERROR_MSG("The authentication module ~p returned "
    		       "an error~nwhen checking user ~p password "
    		       "in server ~p~nError message: ~p",
    		       [?MODULE, User, Server, {Other, RespBody}]),
                false;
            {error, Reason} ->
                ?ERROR_MSG("HTTP request failed:~n"
                           "** URI = ~p~n"
                           "** Err = ~p",
                           [{Server, Path}, Reason]),
                false
        end
    end.

is_user_exists(User, Server) ->
    Path = path(Server, user),
    case rest:get(Server, Path, [{"username", User}]) of
        {ok, 200, _RespBody} ->
            true;
        {ok, 401, _RespBody} ->
            false;
        _ ->
            % documentation states that error means user doesn't exist
            false
    end.

%% Functions not implemented or not relevant for REST authentication

check_password(_User, _AuthzId, _Server, _Password, _Digest, _DigestGen) ->
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

%%%----------------------------------------------------------------------
%%% HTTP helpers
%%%----------------------------------------------------------------------

path(Server, auth) ->
    ejabberd_config:get_option({ext_api_path_auth, Server},
			       fun(X) -> iolist_to_binary(X) end,
			       <<"/auth">>);
path(Server, user) ->
    ejabberd_config:get_option({ext_api_path_user, Server},
			       fun(X) -> iolist_to_binary(X) end,
			       <<"/user">>);
path(_Server, Method) when is_binary(Method) orelse is_list(Method)->
    Method.

opt_type(ext_api_path_auth) ->
    fun (X) -> iolist_to_binary(X) end;
opt_type(ext_api_path_user) ->
    fun (X) -> iolist_to_binary(X) end;
opt_type(_) -> [ext_api_path_auth, ext_api_path_user].
