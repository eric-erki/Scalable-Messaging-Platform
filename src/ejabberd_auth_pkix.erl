%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  8 Feb 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(ejabberd_auth_pkix).

%% API
-behaviour(ejabberd_auth).

-export([start/1, set_password/3, check_password/4,
	 check_password/6, try_register/3,
	 dirty_get_registered_users/0, get_vh_registered_users/1,
	 get_vh_registered_users/2,
	 get_vh_registered_users_number/1,
	 get_vh_registered_users_number/2, get_password/2,
	 get_password_s/2, is_user_exists/2, remove_user/2,
	 remove_user/3, store_type/0, plain_password_required/0]).

%%%===================================================================
%%% API
%%%===================================================================
start(_Host) ->
    ok.

set_password(_User, _Server, _Password) ->
    {error, not_allowed}.

check_password(_User, _AuthzId, _Host, _Password) ->
    false.

check_password(_User, _AuthzId, _Server, _Password, _Digest, _DigestGen) ->
    false.

try_register(_User, _Server, _Password) ->
    {atomic, exists}.

dirty_get_registered_users() -> [].

get_vh_registered_users(_Host) -> [].

get_vh_registered_users(_Host, _) -> [].

get_vh_registered_users_number(_Host) -> 0.

get_vh_registered_users_number(_Host, _) -> 0.

get_password(_User, _Server) -> false.

get_password_s(_User, _Server) -> <<"">>.

is_user_exists(_User, _Host) -> true.

remove_user(_User, _Server) -> {error, not_allowed}.

remove_user(_User, _Server, _Password) -> not_allowed.

plain_password_required() -> true.

store_type() -> external.

%%%===================================================================
%%% Internal functions
%%%===================================================================
