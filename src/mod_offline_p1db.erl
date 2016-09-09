%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_offline_p1db).

-behaviour(mod_offline).

-export([init/2, store_messages/5, pop_messages/2, remove_expired_messages/1,
	 remove_old_messages/2, remove_user/2, read_message_headers/2,
	 read_message/3, remove_message/3, read_all_messages/2,
	 remove_all_messages/2, count_messages/2, import/1]).
-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2]).

-include("jlib.hrl").
-include("mod_offline.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(offline_msg,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user, timestamp]},
                               {vals, [expire, packet]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]).

store_messages(Host, {User, _}, Msgs, Len, MaxOfflineMsgs) ->
    Count = if MaxOfflineMsgs =/= infinity ->
                    Len + count_messages(User, Host);
               true -> 0
            end,
    if Count > MaxOfflineMsgs ->
            {atomic, discard};
       true ->
	    {atomic,
	     lists:foreach(
	       fun(#offline_msg{us = {LUser, LServer}, timestamp = Now,
				from = From, to = To,
				packet = #xmlel{attrs = Attrs} = El} = Msg) ->
		       NewAttrs = jlib:replace_from_to_attrs(
				    jid:to_string(From),
				    jid:to_string(To),
				    Attrs),
		       NewEl = El#xmlel{attrs = NewAttrs},
		       USNKey = usn2key(LUser, LServer, Now),
		       Val = offmsg_to_p1db(Msg#offline_msg{packet = NewEl}),
		       p1db:insert(offline_msg, USNKey, Val)
	       end, Msgs)}
    end.

pop_messages(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
        {ok, L} ->
	    {ok,
	     lists:flatmap(
	       fun({Key, Val, _VClock}) ->
		       DelRes = p1db:delete(offline_msg, Key),
		       if DelRes == ok; DelRes == {error, notfound} ->
			       Now = key2now(USPrefix, Key),
			       USN = {LUser, LServer, Now},
			       [p1db_to_offmsg(USN, Val)];
			  true ->
			       []
		       end
	       end, L)};
        Err ->
            Err
    end.

remove_expired_messages(_LServer) ->
    %% TODO
    {atomic, ok}.

remove_old_messages(_Days, _LServer) ->
    %% TODO
    {atomic, ok}.

remove_user(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _Val, _VClock}) ->
                      p1db:delete(offline_msg, Key)
              end, L),
            {atomic, ok};
        Err ->
            {aborted, Err}
    end.

read_message_headers(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
	{ok, L} ->
	    lists:map(
	      fun({Key, Val, _VClock}) ->
		      Now = key2now(USPrefix, Key),
		      USN = {LUser, LServer, Now},
		      #offline_msg{from = From,
				   to = To,
				   packet = Pkt} = p1db_to_offmsg(USN, Val),
		      Seq = now2ts(Now),
		      NewPkt = jlib:add_delay_info(Pkt, LServer, Now,
						   <<"Offline Storage">>),
		      {Seq, From, To, NewPkt}
	      end, L);
	_Err ->
	    []
    end.

read_message(LUser, LServer, I) ->
    TS = ts2now(I),
    Key = usn2key(LUser, LServer, TS),
    case p1db:get(offline_msg, Key) of
	{ok, Val, _VClock} ->
	    {ok, p1db_to_offmsg({LUser, LServer, TS}, Val)};
	_Err ->
	    error
    end.

remove_message(LUser, LServer, I) ->
    TS = ts2now(I),
    Key = usn2key(LUser, LServer, TS),
    p1db:delete(offline_msg, Key),
    ok.

read_all_messages(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, Val, _VClock}) ->
                      Now = key2now(USPrefix, Key),
                      USN = {LUser, LServer, Now},
                      p1db_to_offmsg(USN, Val)
              end, L);
        _Err ->
            []
    end.

remove_all_messages(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
        {ok, L} ->
	    try
		{atomic,
		 lists:foreach(
		   fun({Key, _Val, _VClock}) ->
			   ok = p1db:delete(offline_msg, Key)
		   end, L)}
	    catch _:{badmatch, {error, _} = Err} ->
		    {aborted, Err}
	    end;
        Err ->
	    {aborted, Err}
    end.

count_messages(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:count_by_prefix(offline_msg, USPrefix) of
        {ok, N} -> N;
        _Err -> 0
    end.

import(#offline_msg{us = {LUser, LServer},
		    timestamp = TS} = Msg) ->
    USNKey = usn2key(LUser, LServer, TS),
    p1db:async_insert(offline_msg, USNKey, offmsg_to_p1db(Msg)).

%%%===================================================================
%%% Internal functions
%%%===================================================================
us2key(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary>>.

usn2key(LUser, LServer, Now) ->
    TimeStamp = now2ts(Now),
    USKey = us2key(LUser, LServer),
    <<USKey/binary, 0, TimeStamp:64>>.

key2now(USPrefix, Key) ->
    Size = size(USPrefix),
    <<_:Size/binary, TimeStamp:64>> = Key,
    ts2now(TimeStamp).

us_prefix(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    <<USKey/binary, 0>>.

ts2now(TimeStamp) ->
    MSecs = TimeStamp div 1000000,
    USecs = TimeStamp rem 1000000,
    MegaSecs = MSecs div 1000000,
    Secs = MSecs rem 1000000,
    {MegaSecs, Secs, USecs}.

now2ts({MegaSecs, Secs, USecs}) ->
    (MegaSecs*1000000 + Secs)*1000000 + USecs.

p1db_to_offmsg({LUser, LServer, Now}, Val) ->
    OffMsg0 = #offline_msg{us = {LUser, LServer},
                           timestamp = Now},
    OffMsg = lists:foldl(
               fun({packet, Pkt}, M) -> M#offline_msg{packet = Pkt};
                  ({expire, Expire}, M) -> M#offline_msg{expire = Expire};
                  (_, M) -> M
               end, OffMsg0, binary_to_term(Val)),
    El = OffMsg#offline_msg.packet,
    HasBody = fxml:get_subtag(El, <<"body">>) /= false,
    #jid{} = To = jid:from_string(fxml:get_tag_attr_s(<<"to">>, El)),
    #jid{} = From = jid:from_string(fxml:get_tag_attr_s(<<"from">>, El)),
    OffMsg#offline_msg{from = From, to = To, has_body = HasBody}.

offmsg_to_p1db(#offline_msg{packet = Pkt, expire = T}) ->
    term_to_binary([{packet, Pkt}, {expire, T}]).

%% P1DB/SQL schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, TS]) ->
    <<Server/binary, 0, User/binary, 0, TS:64>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, TS:64>> = UKey,
    [Server, User, TS].

enc_val(_, [SExpire, SPacket]) ->
    Expire = case SExpire of
                 <<"never">> -> never;
                 _ -> ts2now(SExpire)
             end,
    #xmlel{} = Packet = fxml_stream:parse_element(SPacket),
    offmsg_to_p1db(#offline_msg{packet = Packet, expire = Expire}).

dec_val([Server, User, TS], Bin) ->
    #offline_msg{packet  = Packet,
                 expire = Expire}
        = p1db_to_offmsg({User, Server, ts2now(TS)}, Bin),
    SExpire = case Expire of
                  never -> <<"never">>;
                  _ -> now2ts(Expire)
              end,
    [SExpire, fxml:element_to_binary(Packet)].
