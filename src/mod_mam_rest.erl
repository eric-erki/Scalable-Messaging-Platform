%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_mam_rest).

-behaviour(mod_mam).

%% API
-export([init/2, remove_user/2, remove_room/3, delete_old_messages/3,
	 extended_fields/0, store/7, write_prefs/4, get_prefs/2, select/8,
	 need_cache/1, remove_from_archive/3]).

-include("jlib.hrl").
-include("mod_mam.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    rest:start(Host),
    ok.

need_cache(_Host) ->
    true.

remove_user(_LUser, _LServer) ->
    {atomic, ok}.

remove_room(_LServer, _LName, _LHost) ->
    {atomic, ok}.

remove_from_archive(_LUser, _LServer, _With) ->
    {error, not_implemented}.

delete_old_messages(_ServerHost, _TimeStamp, _Type) ->
    {error, not_implemented}.

extended_fields() ->
    [].

store(Pkt, LServer, {LUser, LHost}, Type, Peer, Nick, Dir) ->
    Now = p1_time_compat:timestamp(),
    SPeer = Peer#jid.luser,
    SUser = case Type of
		chat -> LUser;
		groupchat -> jid:to_string({LUser, LHost, <<>>})
	    end,
    ID = integer_to_binary(now_to_usec(Now)),
    T = case gen_mod:get_module_opt(LServer, ?MODULE, store_body_only,
				    fun(B) when is_boolean(B) -> B end,
				    false) of
	    true ->
		[{<<"direction">>, jlib:atom_to_binary(Dir)},
		 {<<"body">>, fxml:get_subtag_cdata(Pkt, <<"body">>)}];
	    false ->
		[{<<"xml">>, fxml:element_to_binary(Pkt)}]
	end,
    Path = ejabberd_config:get_option({ext_api_path_archive, LServer},
				      fun(X) -> iolist_to_binary(X) end,
				      <<"/archive">>),
    %% Retry 2 times, with a backoff of 500millisec
    case rest:with_retry(post, [LServer, Path, [],
		   {[{<<"username">>, SUser},
		     {<<"peer">>, SPeer},
		     {<<"type">>, jlib:atom_to_binary(Type)},
		     {<<"nick">>, Nick},
		     {<<"timestamp">>, now_to_iso(Now)} | T]}], 2, 500) of
	{ok, Code, _} when Code == 200 orelse Code == 201 ->
	    {ok, ID};
	Err ->
	    ?ERROR_MSG("failed to store packet for user ~s and peer ~s:"
		       " ~p.  Packet: ~p  direction: ~p",
		       [SUser, SPeer, Err, Pkt, Dir]),
	    {error, Err}
    end.

write_prefs(_LUser, _LServer, _Prefs, _ServerHost) ->
    {error, not_implemented}.

get_prefs(_LUser, _LServer) ->
    %% Unsupported so far
    error.

select(LServer, JidRequestor, #jid{luser = LUser} = JidArchive,
       Start, End, With, RSM, MsgType) ->
    Peer = case With of
	       {U, _S, _R} when U /= <<"">> -> [{<<"peer">>, U}];
	       _ -> []
	   end,
    Page = case RSM of
	       #rsm_in{index = Index} when is_integer(Index) ->
		   [{<<"page">>, jlib:integer_to_binary(Index)}];
	       _ ->
		   []
	   end,
    User = case MsgType of
	       chat ->
		   [{<<"username">>, LUser},
		    {<<"type">>, <<"chat">>}];
	       {groupchat, _Role, _MUCState} ->
		   [{<<"username">>, jid:to_string(JidArchive)},
		    {<<"type">>, <<"groupchat">>}]
	   end,
    After = case RSM of
		#rsm_in{direction = aft, id = <<>>} ->
		    [];
		#rsm_in{direction = aft, id = TS1} ->
		    [{<<"after">>, now_to_iso(
				     usec_to_now(
				       jlib:binary_to_integer(TS1)))}];
		_ when Start /= none ->
		    [{<<"after">>, now_to_iso(Start)}];
		_ ->
		    []
	    end,
    Before = case RSM of
		 #rsm_in{direction = before, id = <<>>} ->
		     [{<<"before">>, <<"last">>}];
		 #rsm_in{direction = before, id = TS2} ->
		     [{<<"before">>, now_to_iso(
				       usec_to_now(
					 jlib:binary_to_integer(TS2)))}];
		 _ when End /= none andalso End /= [] ->
		     [{<<"before">>, now_to_iso(End)}];
		 _ ->
		     []
	     end,
    Limit = case RSM of
		#rsm_in{max = Max} when is_integer(Max) ->
		    [{<<"limit">>, jlib:integer_to_binary(Max)}];
		_ ->
		    []
	    end,
    Params = User ++ Peer ++ After ++ Before,
    ArchivePath =
	ejabberd_config:get_option({ext_api_path_archive, LServer},
				   fun(X) -> iolist_to_binary(X) end,
				   <<"/archive">>),
    StoreBody = gen_mod:get_module_opt(LServer, ?MODULE, store_body_only,
				       fun(B) when is_boolean(B) -> B end,
				       false),
    case rest:get(LServer, ArchivePath, Params ++ Page ++ Limit) of
	{ok, 200, {Archive}} ->
	    ArchiveEls = proplists:get_value(<<"archive">>, Archive, []),
	    Count = case proplists:get_value(<<"count">>, Archive, 0) of
			    I when is_integer(I) -> I;
			    B when is_binary(B) -> jlib:binary_to_integer(B)
		    end,
	    IsComplete = proplists:get_value(<<"complete">>, Archive, false),
	    {lists:flatmap(
	       fun({Attrs}) ->
		       try
			   Pkt = build_xml_from_json(JidRequestor,
						     Attrs, StoreBody),
			   TS = proplists:get_value(<<"timestamp">>,
						    Attrs, <<"">>),
			   Nick = proplists:get_value(<<"nick">>, Attrs, <<"">>),
			   T = jlib:binary_to_atom(
				 proplists:get_value(<<"type">>, Attrs, <<"chat">>)),
			   {_, _, _} = Now = jlib:datetime_string_to_timestamp(TS),
			   ID = now_to_usec(Now),
			   [{jlib:integer_to_binary(ID), ID,
			     mod_mam:msg_to_el(#archive_msg{
						  type = T,
						  nick = Nick,
						  timestamp = Now,
						  packet = Pkt}, MsgType,
					       JidRequestor, JidArchive)}]
		       catch error:{badmatch, _} ->
			       []
		       end end, ArchiveEls), IsComplete, Count};
	{{ok, 404, _}, _} = _Err ->
	    ?INFO_MSG("failed to select: ~p for user: ~p peer: ~p",
		       [_Err, JidRequestor, With]),
	    {[], false, 0};
	{_, {ok, 404, _}} = _Err ->
	    ?INFO_MSG("failed to select: ~p for user: ~p peer: ~p",
		       [_Err, JidRequestor, With]),
	    {[], false, 0};
	_Err ->
	    ?ERROR_MSG("failed to select: ~p for user: ~p peer: ~p",
		       [_Err, JidRequestor, With]),
	    {[], false, 0}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
build_xml_from_json(User, Attrs, StoreBody) ->
    Body = proplists:get_value(<<"body">>, Attrs, <<"">>),
    Dir = jlib:binary_to_atom(
	    proplists:get_value(<<"direction">>, Attrs, <<"">>)),
    if StoreBody ->
	    Body = proplists:get_value(<<"body">>, Attrs, <<"">>),
	    Dir = jlib:binary_to_atom(
		    proplists:get_value(<<"direction">>, Attrs, <<"">>)),
	    Peer = proplists:get_value(<<"peer">>, Attrs, <<"">>),
	    {From, To} = case Dir of
			     send ->
				 {jid:to_string(User), Peer};
			     recv ->
				 {Peer, jid:to_string(User)}
			 end,
	    #xmlel{name = <<"message">>,
		   attrs = [{<<"type">>, <<"chat">>},
			    {<<"from">>, From},
			    {<<"to">>, To}],
		   children = [#xmlel{name = <<"body">>,
				      children = [{xmlcdata, Body}]}]};
       true ->
	    XML = proplists:get_value(<<"xml">>, Attrs, <<"">>),
	    #xmlel{} = fxml_stream:parse_element(XML)
    end.

now_to_usec({MSec, Sec, USec}) ->
    (MSec*1000000 + Sec)*1000000 + USec.

usec_to_now(Int) ->
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.

now_to_iso({_, _, USec} = Now) ->
    DateTime = calendar:now_to_universal_time(Now),
    {ISOTimestamp, Zone} = jlib:timestamp_to_iso(DateTime, utc, USec),
    <<ISOTimestamp/binary, Zone/binary>>.

