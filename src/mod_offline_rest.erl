%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_offline_rest).

-behaviour(mod_offline).

-export([init/2, store_messages/5, pop_messages/2, remove_expired_messages/1,
	 remove_old_messages/2, remove_user/2, read_message_headers/2,
	 read_message/3, remove_message/3, remove_all_messages/2,
	 count_messages/2, import/1]).

-include("jlib.hrl").
-include("mod_offline.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    rest:start(Host).

store_messages(Host, {User, _}, Msgs, Len, MaxOfflineMsgs) ->
    Count = if MaxOfflineMsgs =/= infinity ->
                    Len + count_messages(User, Host);
               true -> 0
            end,
    if
        Count > MaxOfflineMsgs ->
            {atomic, discard};
        true ->
	    {atomic,
	     lists:foreach(
	       fun(#offline_msg{us = {LUser, LServer}, timestamp = Now,
				from = From, to = To,
				packet = #xmlel{attrs = _Attrs} = El} = Msg) ->
		       Path = offline_rest_path(LUser, LServer),
		       %% Retry 2 times, with a backoff of 500millisec
		       case rest:with_retry(
			      post,
			      [LServer, Path, [],
			       {[{<<"peer">>, jid:to_string(From)},
				 {<<"packet">>, fxml:element_to_binary(El)},
				 {<<"timestamp">>, jlib:now_to_utc_string(Now, 3)} ]}], 2, 500) of
			   {ok, Code, _} when Code == 200 orelse Code == 201 ->
			       ok;
			   Err ->
			       ?ERROR_MSG("failed to store packet for user ~s and peer ~s:"
					  " ~p.  Packet: ~p",
					  [From, To, Err, Msg]),
			       {error, Err}
		       end
	       end, Msgs)}
    end.

pop_messages(LUser, LServer) ->
    Path = offline_rest_path(LUser, LServer, <<"pop">>),
    case rest:with_retry(post, [LServer, Path, [], []], 2, 500) of
        {ok, 200, Resp} ->
	    {ok,
	     lists:flatmap(
	       fun ({Item}) ->
		       case item_to_offline_msg(LUser, LServer, Item) of
			   {ok, Msg} ->
			       [Msg];
			   {error, _} ->
			       []
		       end
	       end, Resp)};
        Other ->
            ?ERROR_MSG("Unexpected response for offline pop: ~p", [Other]),
            {error, rest_failed}
    end.

remove_expired_messages(_LServer) ->
    %% TODO
    {atomic, ok}.

remove_old_messages(_Days, _LServer) ->
    %% TODO
    {atomic, ok}.

remove_user(LUser, LServer) ->
    remove_all_messages(LUser, LServer).

read_message_headers(_LUser, _LServer) ->
    %% not implemented
    [].

read_message(_LUser, _LServer, _I) ->
    %% not implemented
    error.

remove_message(_LUser, _LServer, _I) ->
    %% not implemented
    ok.

remove_all_messages(LUser, LServer) ->
    Path = offline_rest_path(LUser, LServer),
    case rest:with_retry(delete, [LServer, Path], 2, 500) of
        {ok, 200, _ } ->
            {atomic, ok};
        Error ->
	    ?ERROR_MSG("Unexpected response for delete: ~p", [Error]),
            {aborted, {error, rest_failed}}
    end.

count_messages(LUser, LServer) ->
    Path = offline_rest_path(LUser, LServer, <<"count">>),
    case rest:with_retry(get, [LServer, Path], 2, 500) of
        {ok, 200, {Resp}}  ->
            proplists:get_value(<<"count">>, Resp, 0);
        Other ->
            ?ERROR_MSG("Unexpected response for offline count: ~p", [Other]),
            0
    end.

import(_) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
item_to_offline_msg(LUser, LServer, Item) ->
    To = jid:make(LUser, LServer, <<>>),
    From_s = proplists:get_value(<<"peer">>, Item, <<>>),
    Timestamp = proplists:get_value(<<"timestamp">>, Item, <<>>),
    Packet = proplists:get_value(<<"packet">>, Item, <<>>),
    try
	#xmlel{} = El = fxml_stream:parse_element(Packet),
	#jid{} = From = jid:from_string(From_s),
	Now = jlib:datetime_string_to_timestamp(Timestamp),
  HasBody = fxml:get_subtag(El, <<"body">>) /= false,
	{ok, #offline_msg{us = {LUser, LServer},
			  from = From,
			  to = To,
			  timestamp = Now,
			  expire = undefined,
        has_body = HasBody,
			  packet = El}}
    catch _:{badmatch, error} ->
	    ?ERROR_MSG("failed to get 'from' JID from REST payload ~p", [Item]),
	    {error, bad_jid_from};
	  _:{badmatch, {error, _} = Err} ->
	    ?ERROR_MSG("failed to parse XML ~s from REST payload ~p",
		       [Packet, Item]),
	    Err
    end.

offline_rest_path(User, Server) ->
    Base = ejabberd_config:get_option({ext_api_path_offline, Server},
                                      fun(X) -> iolist_to_binary(X) end,
                                      <<"/offline">>),
    <<Base/binary, "/", User/binary>>.
offline_rest_path(User, Server, Path) ->
    Base = offline_rest_path(User, Server),
    <<Base/binary, "/", Path/binary>>.
