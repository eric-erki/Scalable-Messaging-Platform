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
    http_p1:start(),
    ok.

plain_password_required() -> true.

store_type() -> external.

check_password(_User, _Server, <<>>) ->
    false;
check_password(User, Server, Password) ->
    UID = jlib:jid_to_string(jlib:make_jid(User, Server, <<>>)),
    URI = build_url(Server, "/user/auth", [{"jid", UID}, {"password",Password}]),
    case http_p1:request(get, URI,
                         [{"connection", "keep-alive"},
                          {"content-type", "application/json"},
                          {"User-Agent", "ejabberd"}],
                         <<"">>, []) of
        {ok, 200, _, _RespBody} ->
            true;
        {ok, 401, _, _RespBody} ->
            false;
        {ok, Other, _, RespBody} ->
            ?ERROR_MSG("The authentication module ~p returned "
                                       "an error~nwhen checking user ~p password in server "
                                       "~p~nError message: ~p",
                                       [?MODULE, User, Server, {Other, RespBody}]),
            false;
        {error, Reason} ->
            ?ERROR_MSG("HTTP request failed:~n"
                       "** URI = ~s~n"
                       "** Err = ~p",
                       [URI, Reason]),
            false
    end.

is_user_exists(User, Server) ->
    UID = jlib:jid_to_string(jlib:make_jid(User, Server, <<>>)),
    URI = build_url(Server, "/user", [{"jid", UID}]),
    case http_p1:request(get, URI,
                         [{"connection", "keep-alive"},
                          {"content-type", "application/json"},
                          {"User-Agent", "ejabberd"}],
                         <<"">>, []) of
        {ok, 200, _, _RespBody} ->
            true;
        {ok, 401, _, _RespBody} ->
            false;
        {ok, Other, _, RespBody} ->
            {error, {rest_error, {Other, RespBody}}};
        {error, Reason} ->
            ?ERROR_MSG("HTTP request failed:~n"
                       "** URI = ~s~n"
                       "** Err = ~p",
                       [URI, Reason]),
            {error, {rest_error, {error, Reason}}}
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

%%%----------------------------------------------------------------------
%%% HTTP helpers
%%%----------------------------------------------------------------------

url(Server, Path) ->
    Base = ejabberd_config:get_option({ext_api_url, Server},
                                      fun(X) -> iolist_to_binary(X) end,
                                      <<"http://localhost/api">>),
    <<Base/binary, (iolist_to_binary(Path))/binary>>.

encode_params(Params) ->
    [<<$&, ParHead/binary>> | ParTail] =
        [<<"&", (iolist_to_binary(Key))/binary, "=", (ejabberd_http:url_encode(Value))/binary>>
            || {Key, Value} <- Params],
    iolist_to_binary([ParHead | ParTail]).

build_url(Server, Path, []) ->
    binary_to_list(url(Server, Path));
build_url(Server, Path, Params) ->
    Base = url(Server, Path),
    Pars = encode_params(Params),
    binary_to_list(<<Base/binary, $?, Pars/binary>>).  %%httpc requires lists
