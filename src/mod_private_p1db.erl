%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 17 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_private_p1db).

-behaviour(mod_private).

%% API
-export([init/2, set_data/3, get_data/3, get_all_data/2, remove_user/2,
	 import/3]).
-export([enc_key/1, dec_key/1]).

-include("jlib.hrl").
-include("mod_private.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(private_storage,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user, xmlns]},
                               {vals, [xml]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]).

set_data(LUser, LServer, Data) ->
    {atomic,
     lists:foreach(
       fun({XMLNS, El}) ->
	       USNKey = usn2key(LUser, LServer, XMLNS),
	       Val = fxml:element_to_binary(El),
	       p1db:insert(private_storage, USNKey, Val)
       end, Data)}.

get_data(LUser, LServer, XMLNS) ->
    USNKey = usn2key(LUser, LServer, XMLNS),
    case p1db:get(private_storage, USNKey) of
        {ok, XML, _VClock} ->
            parse_element(XML);
	{error, notfound} ->
	    error;
	{error, Reason} ->
	    ?ERROR_MSG("p1db:get() failed on table ~p: ~p",
		       [private_storage, p1db:format_error(Reason)]),
	    error
    end.

get_all_data(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(private_storage, USPrefix) of
        {ok, L} ->
            lists:flatmap(
              fun({_Key, Val, _VClock}) ->
		      case parse_element(Val) of
			  {ok, El} -> [El];
			  error -> []
		      end
              end, L);
        {error, _} ->
            []
    end.

remove_user(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(private_storage, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _Val, VClock}) ->
                      p1db:async_delete(private_storage, Key, VClock)
              end, L),
            {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end.

import(LServer, <<"private_storage">>,
       [LUser, XMLNS, XML, _TimeStamp]) ->
    USNKey = usn2key(LUser, LServer, XMLNS),
    p1db:async_insert(private_storage, USNKey, XML).

%%%===================================================================
%%% Internal functions
%%%===================================================================
parse_element(XML) ->
    case fxml_stream:parse_element(XML) of
	{error, _} = Err ->
	    ?ERROR_MSG("got ~p when parsing stored XML ~s",
		       [Err, XML]),
	    error;
	El ->
	    {ok, El}
    end.

usn2key(LUser, LServer, XMLNS) ->
    USPrefix = us_prefix(LUser, LServer),
    <<USPrefix/binary, XMLNS/binary>>.

us_prefix(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary, 0>>.

enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, XMLNS]) ->
    <<Server/binary, 0, User/binary, 0, XMLNS/binary>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, XMLNS/binary>> = UKey,
    [Server, User, XMLNS].
