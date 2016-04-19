%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 17 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_vcard_p1db).

-behaviour(mod_vcard).

%% API
-export([init/2, get_vcard/2, set_vcard/4, search/4, remove_user/2,
	 import/3, is_search_supported/1]).
-export([enc_key/1, dec_key/1]).

-include("jlib.hrl").
-include("mod_vcard.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(vcard,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user]},
                               {vals, [vcard]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]).

is_search_supported(_LServer) ->
    false.

get_vcard(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    case p1db:get(vcard, USKey) of
        {ok, VCard, _} ->
	    parse_element(VCard);
        {error, notfound} ->
            [];
        {error, _} ->
            error
    end.

set_vcard(LUser, LServer, VCARD, _VCardSearch) ->
    USKey = us2key(LUser, LServer),
    {atomic, p1db:insert(vcard, USKey, fxml:element_to_binary(VCARD))}.

search(_LServer, _Data, _AllowReturnAll, _MaxMatch) ->
    [].

remove_user(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    {atomic, p1db:async_delete(vcard, USKey)}.

import(LServer, <<"vcard">>, [LUser, XML, _TimeStamp]) ->
    USKey = us2key(LUser, LServer),
    p1db:async_insert(vcard, USKey, XML);
import(_LServer, <<"vcard_search">>, _) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
parse_element(XML) ->
    case fxml_stream:parse_element(XML) of
	{error, _Reason} = Err ->
	    ?ERROR_MSG("got ~p when parsing vCard ~s",
		       [Err, XML]),
	    error;
	El ->
	    [El]
    end.

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
