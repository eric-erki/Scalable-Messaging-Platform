%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 16 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_vcard_xupdate_p1db).

-behaviour(mod_vcard_xupdate).

%% API
-export([init/2, import/3, add_xupdate/3, get_xupdate/2, remove_xupdate/2]).
-export([enc_key/1, dec_key/1]).

-include("mod_vcard_xupdate.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(vcard_xupdate,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user]},
                               {vals, [hash]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]).

add_xupdate(LUser, LServer, Hash) ->
    USKey = us2key(LUser, LServer),
    {atomic, p1db:insert(vcard_xupdate, USKey, Hash)}.

get_xupdate(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    case p1db:get(vcard_xupdate, USKey) of
        {ok, Hash, _VClock} -> Hash;
        {error, _} -> undefined
    end.

remove_xupdate(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    {atomic, p1db:delete(vcard_xupdate, USKey)}.

import(LServer, <<"vcard_xupdate">>, [LUser, Hash, _TimeStamp]) ->
    USKey = us2key(LUser, LServer),
    p1db:async_insert(vcard_xupdate, USKey, Hash).

%%%===================================================================
%%% Internal functions
%%%===================================================================
us2key(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary>>.

enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, User/binary>> = Key,
    [Server, User].
