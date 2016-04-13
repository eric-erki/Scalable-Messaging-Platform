%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 16 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_announce_p1db).

-behaviour(mod_announce).

%% API
-export([init/2, set_motd_users/2, set_motd/2, delete_motd/1,
	 get_motd/1, is_motd_user/2, set_motd_user/2, import/3]).
-export([enc_key/1, dec_key/1]).

-include("jlib.hrl").
-include("mod_announce.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(motd,
                    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user]},
                               {vals, [motd]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]).

set_motd_users(_LServer, USRs) ->
    lists:foreach(
      fun({U, S, _R}) ->
	      USKey = us2key(U, S),
	      p1db:async_insert(motd, USKey, <<>>)
      end, USRs),
    {atomic, ok}.

set_motd(LServer, Packet) ->
    MsgKey = msg_key(LServer),
    XML = fxml:element_to_binary(Packet),
    case p1db:insert(motd, MsgKey, XML) of
	ok -> {atomic, ok};
	{error, _} = Err -> {aborted, Err}
    end.

delete_motd(LServer) ->
    SPrefix = server_prefix(LServer),
    case p1db:get_by_prefix(motd, SPrefix) of
	{ok, L} ->
	    lists:foreach(
	      fun({Key, _Val, _VClock}) ->
		      p1db:async_delete(motd, Key)
	      end, L),
	    {atomic, ok};
	{error, _} = Err ->
	    {aborted, Err}
    end.

get_motd(LServer) ->
    MsgKey = msg_key(LServer),
    case p1db:get(motd, MsgKey) of
	{ok, XML, _VClock} ->
	    case fxml_stream:parse_element(XML) of
		#xmlel{} = Packet ->
		    {ok, Packet};
		Err ->
		    ?ERROR_MSG("got error ~p when parsing stored XML ~s",
			       [Err, XML]),
		    error
	    end;
	{error, _} ->
	    error
    end.

is_motd_user(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    case p1db:get(motd, USKey) of
        {ok, <<>>, _VClock} ->
	    true;
	{error, notfound} ->
	    false
    end.

set_motd_user(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    {atomic, p1db:insert(motd, USKey, <<>>)}.

import(LServer, <<"motd">>, [<<>>, XML, _TimeStamp]) ->
    MsgKey = msg_key(LServer),
    p1db:async_insert(motd, MsgKey, XML);
import(LServer, <<"motd">>, [LUser, <<>>, _TimeStamp]) ->
    USKey = us2key(LUser, LServer),
    p1db:async_insert(motd, USKey, <<>>).

%%%===================================================================
%%% Internal functions
%%%===================================================================
us2key(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary>>.

server_prefix(LServer) ->
    <<LServer/binary, 0>>.

msg_key(LServer) ->
    <<LServer/binary, 0, 0>>.

%% P1DB/SQL schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, null]) ->
    <<Server/binary, 0, 0>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, User/binary>> = Key,
    case User of
        <<0>> -> [Server, null];
        _ -> [Server, User]
    end.
