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
	 get_vh_registered_users/2, init_db/0,
	 get_vh_registered_users_number/1,
	 get_vh_registered_users_number/2, get_password/2,
	 get_password_s/2, is_user_exists/2, remove_user/2,
	 remove_user/3, store_type/0, export/1, import/2,
	 plain_password_required/0]).

-include("ejabberd.hrl").
-include("logger.hrl").



%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(_Host) ->
    inets:start(),
    ok.

plain_password_required() ->
    true.

store_type() ->
    external.  %%TODO:  is this ok?.  We need plain password to be able to pass them to the api..

get_base_url(Server) ->
    Url = ejabberd_config:get_option({base_url, Server}, fun(X) when is_list(X) orelse is_binary(X) -> X end, no_default),
    Url.

url_encode(B) when is_binary(B) ->
    url_encode(binary_to_list(B));
url_encode(L) when is_list(L) ->
    http_uri:encode(L).

encode_params(Params) ->
    string:join([ [url_encode(Key), "=", url_encode(Val)] || {Key, Val} <- Params], "&").
build_url_for(Server, Path, Params) ->
    Base = get_base_url(Server),
    binary_to_list(iolist_to_binary([Base, Path,"?", encode_params(Params)])).  %%httpc requires lists

check_password(User, Server, Password) ->
    UserJid = jlib:jid_to_string(jlib:make_jid(User, Server, <<>>)),
    case httpc:request(build_url_for(Server, "/auth", [{"jid", UserJid}, {"password",Password}])) of
        {ok, {{_,200,_},_,_RespBody}} ->
            true;
        {ok, {{_,401,_},_,_RespBody}} ->
            false;
        {ok, {{_,Other,_},_,RespBody}} ->
            ?ERROR_MSG("The authentication module ~p returned "
				       "an error~nwhen checking user ~p password in server "
				       "~p~nError message: ~p",
				       [?MODULE, User, Server, {Other, RespBody}]),
            false
    end.

%% @spec (User, Server) -> true | false | {error, Error}
is_user_exists(User, Server) ->
    UserJid = jlib:jid_to_string(jlib:make_jid(User, Server, <<>>)),
    case httpc:request(build_url_for(Server, "/user", [{"jid", UserJid}])) of
        {ok, {{_,200,_},_,_RespBody}} ->
            true;
        {ok, {{_,401,_},_,_RespBody}} ->
            false;
        {ok, {{_,Other,_},_,RespBody}} ->
            {error, {rest_error, {Other, RespBody}}}
    end.


%% Functions not implemented or not relevant for REST authentication

init_db() ->
    ok. %%TODO: Is this neccesary?

check_password(_User, _Server, _Password, _Digest,
	       _DigestGen) ->
    not_implemented.  %% TODO:  we need this?  can use digest?

%% @spec (User::string(), Server::string(), Password::string()) ->
%%       ok | {error, invalid_jid}
set_password(_User, _Server, _Password) ->
    not_implemented.  %%TODO:  return error?

%% @spec (User, Server, Password) -> {atomic, ok} | {atomic, exists} | {error, invalid_jid} | {aborted, Reason}
try_register(_User, _Server, _PasswordList) ->
    not_implemented. %%TODO:  return error?

%% Get all registered users in Mnesia
dirty_get_registered_users() ->
    not_implemented. %%TODO

get_vh_registered_users(_Server) ->
    not_implemented.

get_vh_registered_users(_Server,
			[{from, Start}, {to, End}])
    when is_integer(Start) and is_integer(End) ->
    not_implemented;
get_vh_registered_users(_Server,
			[{limit, Limit}, {offset, Offset}])
    when is_integer(Limit) and is_integer(Offset) ->
    not_implemented;
get_vh_registered_users(_Server, [{prefix, Prefix}])
    when is_binary(Prefix) ->
    not_implemented;
get_vh_registered_users(_Server,
			[{prefix, Prefix}, {from, Start}, {to, End}])
    when is_binary(Prefix) and is_integer(Start) and
	   is_integer(End) ->
    not_implemented;
get_vh_registered_users(_Server,
			[{prefix, Prefix}, {limit, Limit}, {offset, Offset}])
    when is_binary(Prefix) and is_integer(Limit) and
	   is_integer(Offset) ->
    not_implemented;
get_vh_registered_users(_Server, _) ->
    not_implemented.

get_vh_registered_users_number(_Server) ->
    not_implemented.

get_vh_registered_users_number(_Server,
			       [{prefix, Prefix}])
    when is_binary(Prefix) ->
    not_implemented;
get_vh_registered_users_number(_Server, _) ->
    not_implemented.

get_password(_User, _Server) ->
    not_implemented.

get_password_s(_User, _Server) ->
    not_implemented.


%% @spec (User, Server) -> ok
%% @doc Remove user.
%% Note: it returns ok even if there was some problem removing the user.
remove_user(_User, _Server) ->
    not_implemented.

%% @spec (User, Server, Password) -> ok | not_exists | not_allowed | bad_request
%% @doc Remove user if the provided password is correct.
remove_user(_User, _Server, _Password) ->
    not_implemented.


export(_Server) ->
    not_implemented.

import(_LServer, [_LUser, _Password, _TimeStamp]) ->
    not_implemented.
