%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_mam_p1db).

-behaviour(mod_mam).

%% API
-export([init/2, remove_user/2, remove_room/3, delete_old_messages/3,
	 extended_fields/0, store/7, write_prefs/4, get_prefs/2, select/8,
	 need_cache/1, remove_from_archive/3]).
-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2, enc_prefs/2, dec_prefs/2]).

-include("jlib.hrl").
-include("mod_mam.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(archive_msg,
		    [{group, Group}, {nosync, true},
		     {schema, [{keys, [server, user, timestamp]},
			       {vals, [peer, packet]},
			       {enc_key, fun ?MODULE:enc_key/1},
			       {dec_key, fun ?MODULE:dec_key/1},
			       {enc_val, fun ?MODULE:enc_val/2},
			       {dec_val, fun ?MODULE:dec_val/2}]}]),
    p1db:open_table(archive_prefs,
		    [{group, Group}, {nosync, true},
		     {schema, [{keys, [server, user]},
			       {vals, [default, always, never]},
			       {enc_key, fun ?MODULE:enc_key/1},
			       {dec_key, fun ?MODULE:dec_key/1},
			       {enc_val, fun ?MODULE:enc_prefs/2},
			       {dec_val, fun ?MODULE:dec_prefs/2}]}]).

need_cache(_Host) ->
    false.

remove_user(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(archive_msg, USPrefix) of
	{ok, L} ->
	    DelRes = p1db:delete(archive_prefs, USKey),
	    if DelRes == ok; DelRes == {error, notfound} ->
		    lists:foreach(
		      fun({Key, _, _}) ->
			      p1db:async_delete(archive_msg, Key)
		      end, L),
		    {atomic, ok};
	       true ->
		    {aborted, DelRes}
	    end;
	{error, _} = Err ->
	    {aborted, Err}
    end.

remove_room(_LServer, LName, LHost) ->
    remove_user(LName, LHost).

remove_from_archive(LUser, LServer, none) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(archive_msg, USPrefix) of
	{ok, L} ->
		lists:foreach(
		    fun({Key, _, _}) ->
			p1db:async_delete(archive_msg, Key)
		    end, L);
	{error, _} = Err ->
	    Err
    end;
remove_from_archive(LUser, LServer, WithJid) ->
    USPrefix = us_prefix(LUser, LServer),
    With = jid:split(WithJid),
    case p1db:get_by_prefix(archive_msg, USPrefix) of
	{ok, L} ->
	    lists:foreach(
		fun({Key, Val, _}) ->
		    Opts = binary_to_term(Val),
		    Peer = proplists:get_value(peer, Opts),
		    case match_with(Peer, With) of
			true ->
			    p1db:async_delete(archive_msg, Key);
			_ ->
			    ok
		    end
		end, L);
	{error, _} = Err ->
	    Err
    end.

delete_old_messages(_ServerHost, TimeStamp, Type) ->
    delete_old_messages_p1db(TimeStamp, Type, p1db:first(archive_msg)).

extended_fields() ->
    [].

delete_old_messages_p1db(TimeStamp, Type, {ok, Key, Val, _VClock}) ->
    Next = p1db:next(archive_msg, Key),
    case split_key(Key) of
	{_User, _Server, TS} ->
	    Opts = binary_to_term(Val),
	    MsgType = proplists:get_value(type, Opts, chat),
	    MsgTS = usec_to_now(TS),
	    if MsgTS < TimeStamp, MsgType == Type orelse Type == all ->
		    p1db:delete(archive_msg, Key);
	       true ->
		    ok
	    end;
	_ ->
	    ok
    end,
    delete_old_messages_p1db(TimeStamp, Type, Next);
delete_old_messages_p1db(_TimeStamp, _Type, {error, _}) ->
    ok.

store(Pkt, _, {LUser, LServer}, Type, Peer, Nick, _Dir) ->
    Now = p1_time_compat:timestamp(),
    USNKey = usn2key(LUser, LServer, Now),
    XML = fxml:element_to_binary(Pkt),
    Val = term_to_binary([{peer, Peer},
			  {nick, Nick},
			  {type, Type},
			  {packet, XML}]),
    case p1db:insert(archive_msg, USNKey, Val) of
	ok ->
	    ID = jlib:integer_to_binary(now_to_usec(Now)),
	    {ok, ID};
	{error, _} = Err ->
	    Err
    end.

write_prefs(LUser, LServer, Prefs, _ServerHost) ->
    Val = prefs_to_p1db(Prefs),
    USKey = us2key(LUser, LServer),
    p1db:insert(archive_prefs, USKey, Val).

get_prefs(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    case p1db:get(archive_prefs, USKey) of
	{ok, Val, _} ->
	    {ok, p1db_to_prefs({LUser, LServer}, Val)};
	{error, _} ->
	    error
    end.

select(_LServer, JidRequestor, #jid{luser = LUser, lserver = LServer} = JidArchive,
       Start, End, With, RSM, MsgType) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(archive_msg, USPrefix) of
	{ok, L} ->
	    Msgs = lists:flatmap(
		     fun({Key, Val, _}) ->
			     TS = get_suffix(USPrefix, Key),
			     Now = usec_to_now(TS),
			     Opts = binary_to_term(Val),
			     Peer = proplists:get_value(peer, Opts),
			     Nick = proplists:get_value(nick, Opts, <<"">>),
			     T = proplists:get_value(type, Opts, chat),
			     case match_interval(Now, Start, End) and
				 match_with(Peer, With) and
				 match_rsm(Now, RSM) of
				 true ->
				     #xmlel{} = Pkt =
					 fxml_stream:parse_element(
					   proplists:get_value(packet,
							       Opts)),
				     [{jlib:integer_to_binary(TS), TS,
				       mod_mam:msg_to_el(#archive_msg{
							    type = T,
							    timestamp = Now,
							    peer = Peer,
							    nick = Nick,
							    packet = Pkt},
							 MsgType,
							 JidRequestor, JidArchive)}];
				 false ->
				     []
			     end
		     end, L),
	    case RSM of
		#rsm_in{max = Max, direction = before} ->
		    {NewMsgs, IsComplete} = filter_by_max(lists:reverse(Msgs), Max),
		    {NewMsgs, IsComplete, length(L)};
		#rsm_in{max = Max} ->
		    {NewMsgs, IsComplete} = filter_by_max(Msgs, Max),
		    {NewMsgs, IsComplete, length(L)};
		_ ->
		    {Msgs, true, length(L)}
	    end;
	{error, _} ->
	    {[], false, 0}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
us2key(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary>>.

usn2key(LUser, LServer, Now) ->
    TimeStamp = now_to_usec(Now),
    <<LServer/binary, 0, LUser/binary, 0, TimeStamp:64>>.

us_prefix(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary, 0>>.

get_suffix(Prefix, Key) ->
    Size = size(Prefix),
    <<_:Size/binary, TS:64>> = Key,
    TS.

split_key(Key) ->
    [Server, Tail] = binary:split(Key, <<0>>),
    case binary:split(Tail, <<0>>) of
	[User, <<TS:64>>] ->
	    {User, Server, TS};
	[User|_] ->
	    {User, Server}
    end.

prefs_to_p1db(Prefs) ->
    Keys = record_info(fields, archive_prefs),
    DefPrefs = #archive_prefs{us = Prefs#archive_prefs.us},
    {_, PropList} =
	lists:foldl(
	  fun(Key, {Pos, L}) ->
		  Val = element(Pos, Prefs),
		  DefVal = element(Pos, DefPrefs),
		  if Val == DefVal ->
			  {Pos+1, L};
		     true ->
			  {Pos+1, [{Key, Val}|L]}
		  end
	  end, {2, []}, Keys),
    term_to_binary(PropList).

p1db_to_prefs({LUser, LServer}, Bin) ->
    Prefs = #archive_prefs{us = {LUser, LServer}},
    lists:foldl(
      fun({default, Default}, P) -> P#archive_prefs{default = Default};
	 ({always, Always}, P) -> P#archive_prefs{always = Always};
	 ({never, Never}, P) -> P#archive_prefs{never = Never};
	 (_, P) -> P
      end, Prefs, binary_to_term(Bin)).

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
    case str:chr(UKey, 0) of
	0 ->
	    [Server, UKey];
	L ->
	    ULen = L - 1,
	    <<User:ULen/binary, 0, TS:64>> = UKey,
	    [Server, User, TS]
    end.

enc_val(_, [SPeer, SNick, SType, XML]) ->
    term_to_binary([{peer, #jid{} = jid:from_string(SPeer)},
		    {nick, SNick},
		    {type, jlib:binary_to_atom(SType)},
		    {packet, XML}]).

dec_val(_, Bin) ->
    Opts = binary_to_term(Bin),
    Packet = proplists:get_value(packet, Opts),
    #jid{} = Peer = proplists:get_value(peer, Opts),
    Nick = proplists:get_value(nick, Opts, <<"">>),
    Type = proplists:get_value(type, Opts, chat),
    [jid:to_string(Peer), Nick, jlib:atom_to_binary(Type), Packet].

enc_prefs(_, [Default, Always, Never]) ->
    prefs_to_p1db(#archive_prefs{
		     default = jlib:binary_to_atom(Default),
		     always = jlib:expr_to_term(Always),
		     never = jlib:expr_to_term(Never)}).

dec_prefs(_, Bin) ->
    Prefs = p1db_to_prefs({<<>>, <<>>}, Bin),
    [jlib:atom_to_binary(Prefs#archive_prefs.default),
     jlib:term_to_expr(Prefs#archive_prefs.always),
     jlib:term_to_expr(Prefs#archive_prefs.never)].

now_to_usec({MSec, Sec, USec}) ->
    (MSec*1000000 + Sec)*1000000 + USec.

usec_to_now(Int) ->
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.

match_with({jid, U, S, _, _, _, _}, {U, S, _}) -> true;
match_with({U, S, _}, {U, S, <<"">>}) -> true;
match_with(_, none) -> true;
match_with(Peer, With) -> Peer == With.

match_interval(Now, Start, End) ->
    (Now >= Start) and (Now =< End).

match_rsm(Now, #rsm_in{id = ID, direction = aft}) when ID /= <<"">> ->
    Now1 = (catch usec_to_now(jlib:binary_to_integer(ID))),
    Now > Now1;
match_rsm(Now, #rsm_in{id = ID, direction = before}) when ID /= <<"">> ->
    Now1 = (catch usec_to_now(jlib:binary_to_integer(ID))),
    Now < Now1;
match_rsm(_Now, _) ->
    true.

filter_by_max(Msgs, undefined) ->
    {Msgs, true};
filter_by_max(Msgs, Len) when is_integer(Len), Len >= 0 ->
    {lists:sublist(Msgs, Len), length(Msgs) =< Len};
filter_by_max(_Msgs, _Junk) ->
    {[], true}.
