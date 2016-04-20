%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @doc
%%%      Message Archive Management (XEP-0313)
%%% @end
%%% Created :  4 Jul 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2013-2016   ProcessOne
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
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------
-module(mod_mam_legacy).

-protocol({xep, 313, '0.3'}).

-behaviour(ejabberd_config).

-behaviour(gen_mod).

%% API
-export([start/2, stop/1]).

-export([user_send_packet/4, user_receive_packet/5,
	 enc_key/1, dec_key/1, enc_val/2, dec_val/2, enc_prefs/2,
	 dec_prefs/2, process_iq_v0_2/3, process_iq_v0_3/3, remove_user/2,
	 mod_opt_type/1, opt_type/1]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("jlib.hrl").
-include("logger.hrl").

-record(archive_msg,
	{us = {<<"">>, <<"">>}                :: {binary(), binary()} | '$2',
	 id = <<>>                            :: binary() | '_',
	 timestamp = p1_time_compat:timestamp() :: erlang:timestamp() | '_' | '$1',
	 peer = {<<"">>, <<"">>, <<"">>}      :: ljid() | '_' | '$3',
	 bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_' | '$3',
	 packet = #xmlel{}                    :: xmlel() | '_'}).

-record(archive_prefs,
	{us = {<<"">>, <<"">>} :: {binary(), binary()},
	 default = never       :: never | always | roster,
	 always = []           :: [ljid()],
	 never = []            :: [ljid()]}).

%%%===================================================================
%%% API
%%%===================================================================
start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, fun gen_iq_handler:check_type/1,
			     one_queue),
    DBType = gen_mod:db_type(Host, Opts),
    init_db(DBType, Host),
    init_cache(DBType, Opts),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_MAM_TMP, ?MODULE, process_iq_v0_2, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_MAM_TMP, ?MODULE, process_iq_v0_2, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
				  ?NS_MAM_0, ?MODULE, process_iq_v0_3, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_MAM_0, ?MODULE, process_iq_v0_3, IQDisc),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE,
		       user_receive_packet, 500),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
		       user_send_packet, 500),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    ejabberd_hooks:add(anonymous_purge_hook, Host, ?MODULE,
		       remove_user, 50),
    ok.

init_db(DBType, Host) when DBType==sql orelse DBType==sharding ->
    Muchost = gen_mod:get_module_opt_host(Host, mod_muc,
					 <<"conference.@HOST@">>),
    ets:insert(ejabberd_modules, {ejabberd_module, {mod_mam, Muchost},
				  [{db_type,DBType}]}),
    mnesia:dirty_write({local_config, {modules,Muchost},
			[{mod_mam, [{db_type,DBType}]}]});
init_db(mnesia, _Host) ->
    mnesia:create_table(archive_msg,
			[{disc_only_copies, [node()]},
			 {type, bag},
			 {attributes, record_info(fields, archive_msg)}]),
    mnesia:create_table(archive_prefs,
			[{disc_only_copies, [node()]},
			 {attributes, record_info(fields, archive_prefs)}]);
init_db(p1db, Host) ->
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
			       {dec_val, fun ?MODULE:dec_prefs/2}]}]);
init_db(rest, Host) ->
    rest:start(Host),
    ok;
init_db(_, _) ->
    ok.

init_cache(p1db, _Opts) ->
    ok;
init_cache(_DBType, Opts) ->
    MaxSize = gen_mod:get_opt(cache_size, Opts,
			      fun(I) when is_integer(I), I>0 -> I end,
			      1000),
    LifeTime = gen_mod:get_opt(cache_life_time, Opts,
			       fun(I) when is_integer(I), I>0 -> I end,
			       timer:hours(1) div 1000),
    cache_tab:new(archive_prefs, [{max_size, MaxSize},
				  {life_time, LifeTime}]).

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
			  user_send_packet, 500),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE,
			  user_receive_packet, 500),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM_TMP),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM_TMP),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM_0),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM_0),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    ejabberd_hooks:delete(anonymous_purge_hook, Host,
			  ?MODULE, remove_user, 50),
    ok.

remove_user(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    remove_user(LUser, LServer,
		gen_mod:db_type(LServer, ?MODULE)).

remove_user(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    F = fun () ->
		mnesia:delete({archive_msg, US}),
		mnesia:delete({archive_prefs, US})
	end,
    mnesia:transaction(F);
remove_user(LUser, LServer, p1db) ->
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
    end;
remove_user(_LUser, _LServer, rest) ->
    {atomic, ok};
remove_user(LUser, LServer, DBType) when DBType==sql orelse
					 DBType==sharding ->
    SUser = ejabberd_sql:escape(LUser),
    Key = case DBType of
	      sql -> undefined;
	      sharding -> LUser
    end,
    ejabberd_sql:sql_query(
      LServer, Key,
      [<<"delete from archive where username='">>, SUser, <<"';">>]),
    ejabberd_sql:sql_query(
      LServer, Key,
      [<<"delete from archive_prefs where username='">>, SUser, <<"';">>]).

user_receive_packet(Pkt, C2SState, JID, Peer, To) ->
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    IsBareCopy = is_bare_copy(JID, To),
    case should_archive(Pkt) of
	true when not IsBareCopy ->
	    NewPkt = strip_my_archived_tag(Pkt, LServer),
	    case store(C2SState, NewPkt, LUser, LServer,
		       Peer, true, recv) of
		{ok, ID} ->
		    Archived = #xmlel{name = <<"archived">>,
				      attrs = [{<<"by">>, LServer},
					       {<<"xmlns">>, ?NS_MAM_TMP},
					       {<<"id">>, ID}]},
		    NewEls = [Archived|NewPkt#xmlel.children],
		    NewPkt#xmlel{children = NewEls};
		_ ->
		    NewPkt
	    end;
	_ ->
	    Pkt
    end.

user_send_packet(Pkt, C2SState, JID, Peer) ->
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    case should_archive(Pkt) of
	S when (S==true) ->
	    NewPkt = strip_my_archived_tag(Pkt, LServer),
	    store0(C2SState, jlib:replace_from_to(JID, Peer, NewPkt),
		  LUser, LServer, Peer, S, send),
	    NewPkt;
	S when (S==muc) ->
	    NewPkt = strip_my_archived_tag(Pkt, LServer),
	    case store0(C2SState, jlib:replace_from_to(JID, Peer, NewPkt),
		  LUser, LServer, Peer, S, send) of
		{ok, ID} ->
		    By = jid:to_string(Peer),
		    Archived = #xmlel{name = <<"archived">>,
			    attrs = [{<<"by">>, By}, {<<"xmlns">>, ?NS_MAM_TMP},
			    {<<"id">>, ID}]},
		    NewEls = [Archived|NewPkt#xmlel.children],
		    NewPkt#xmlel{children = NewEls};
		_ ->
		    NewPkt
	    end;
	false ->
	    Pkt
    end.

% Query archive v0.2
process_iq_v0_2(#jid{lserver = LServer} = From,
	       #jid{lserver = LServer} = To,
	       #iq{type = get, sub_el = #xmlel{name = <<"query">>} = SubEl} = IQ) ->
    Fs = lists:flatmap(
	    fun(#xmlel{name = <<"start">>} = El) ->
		    [{<<"start">>, [fxml:get_tag_cdata(El)]}];
		(#xmlel{name = <<"end">>} = El) ->
		    [{<<"end">>, [fxml:get_tag_cdata(El)]}];
		(#xmlel{name = <<"with">>} = El) ->
		    [{<<"with">>, [fxml:get_tag_cdata(El)]}];
		(#xmlel{name = <<"withroom">>} = El) ->
		    [{<<"withroom">>, [fxml:get_tag_cdata(El)]}];
		(#xmlel{name = <<"withtext">>} = El) ->
		    [{<<"withtext">>, [fxml:get_tag_cdata(El)]}];
		(#xmlel{name = <<"set">>}) ->
		    [{<<"set">>, SubEl}];
		(_) ->
		   []
	   end, SubEl#xmlel.children),
    process_iq(From, To, IQ, SubEl, Fs);
process_iq_v0_2(From, To, IQ) ->
    process_iq(From, To, IQ).

% Query archive v0.3
process_iq_v0_3(#jid{lserver = LServer} = From,
		#jid{lserver = LServer} = To,
		#iq{type = set, sub_el = #xmlel{name = <<"query">>} = SubEl} = IQ) ->
    Fs = case {fxml:get_subtag_with_xmlns(SubEl, <<"x">>, ?NS_XDATA),
	       fxml:get_subtag_with_xmlns(SubEl, <<"set">>, ?NS_RSM)} of
	     {#xmlel{} = XData, false} ->
		 jlib:parse_xdata_submit(XData);
	     {#xmlel{} = XData, #xmlel{}} ->
		 [{<<"set">>, SubEl} | jlib:parse_xdata_submit(XData)];
	     {false, #xmlel{}} ->
		 [{<<"set">>, SubEl}];
	     {false, false} ->
		 []
	 end,
    process_iq(From, To, IQ, SubEl, Fs);
process_iq_v0_3(From, To, IQ) ->
    process_iq(From, To, IQ).

%%%===================================================================
%%% Internal functions
%%%===================================================================

% Preference setting (both v0.2 & v0.3)
process_iq(#jid{luser = LUser, lserver = LServer},
	   #jid{lserver = LServer},
	   #iq{type = set, sub_el = #xmlel{name = <<"prefs">>} = SubEl} = IQ) ->
    try {case fxml:get_tag_attr_s(<<"default">>, SubEl) of
	    <<"always">> -> always;
	    <<"never">> -> never;
	    <<"roster">> -> roster
	    end,
	    lists:foldl(
		fun(#xmlel{name = <<"always">>, children = Els}, {A, N}) ->
			{get_jids(Els) ++ A, N};
		    (#xmlel{name = <<"never">>, children = Els}, {A, N}) ->
			{A, get_jids(Els) ++ N};
		    (_, {A, N}) ->
			{A, N}
		end, {[], []}, SubEl#xmlel.children)} of
	{Default, {Always, Never}} ->
	    case write_prefs(LUser, LServer, LServer, Default,
		    lists:usort(Always), lists:usort(Never)) of
		ok ->
		    IQ#iq{type = result, sub_el = []};
		_Err ->
		    IQ#iq{type = error,
			sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]}
	    end
    catch _:_ ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]}
    end;
process_iq(_, _, #iq{sub_el = SubEl} = IQ) ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}.

process_iq(From, To, IQ, SubEl, Fs) ->
    case catch lists:foldl(
		 fun({<<"start">>, [Data|_]}, {_, End, With, RSM}) ->
			 {{_, _, _} = jlib:datetime_string_to_timestamp(Data),
			  End, With, RSM};
		    ({<<"end">>, [Data|_]}, {Start, _, With, RSM}) ->
			 {Start,
			  {_, _, _} = jlib:datetime_string_to_timestamp(Data),
			  With, RSM};
		    ({<<"with">>, [Data|_]}, {Start, End, _, RSM}) ->
			 {Start, End, jid:tolower(jid:from_string(Data)), RSM};
		    ({<<"withroom">>, [Data|_]}, {Start, End, _, RSM}) ->
			 {Start, End,
			  {room, jid:tolower(jid:from_string(Data))},
			  RSM};
		    ({<<"withtext">>, [Data|_]}, {Start, End, _, RSM}) ->
			 {Start, End, {text, Data}, RSM};
		    ({<<"set">>, El}, {Start, End, With, _}) ->
			 {Start, End, With, jlib:rsm_decode(El)};
		    (_, Acc) ->
			 Acc
		 end, {none, [], none, none}, Fs) of
	{'EXIT', _} ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]};
	{Start, End, With, RSM} ->
	    select_and_send(From, To, Start, End, With, RSM, IQ)
    end.

should_archive(#xmlel{name = <<"message">>} = Pkt) ->
    case {fxml:get_attr_s(<<"type">>, Pkt#xmlel.attrs),
	  fxml:get_subtag_cdata(Pkt, <<"body">>)} of
	{<<"error">>, _} ->
	    false;
	{<<"groupchat">>, _} ->
	    To = fxml:get_attr_s(<<"to">>, Pkt#xmlel.attrs),
	    case (jid:from_string(To))#jid.resource of
		<<"">> -> muc;
		_ -> false
	    end;
	{_, <<>>} ->
	    %% Empty body
	    false;
	_ ->
	    true
    end;
should_archive(#xmlel{}) ->
    false.

strip_my_archived_tag(Pkt, LServer) ->
    NewEls = lists:filter(
	    fun(#xmlel{name = <<"archived">>, attrs = Attrs}) ->
		    case catch jid:nameprep(
			    fxml:get_attr_s(
				<<"by">>, Attrs)) of
			LServer ->
			    false;
			_ ->
			    true
		    end;
		(_) ->
		    true
	    end, Pkt#xmlel.children),
    Pkt#xmlel{children = NewEls}.

should_archive_peer(C2SState,
		    #archive_prefs{default = Default,
				   always = Always,
				   never = Never},
		    Peer) ->
    LPeer = jid:tolower(Peer),
    case lists:member(LPeer, Always) of
	true ->
	    true;
	false ->
	    case lists:member(LPeer, Never) of
		true ->
		    false;
		false ->
		    case Default of
			always -> true;
			never -> false;
			roster ->
			    case ejabberd_c2s:get_subscription(
				   LPeer, C2SState) of
				both -> true;
				from -> true;
				to -> true;
				_ -> false
			    end
		    end
	    end
    end.

store0(C2SState, Pkt, LUser, LServer, Peer, Type, Dir) ->
    case Type of
	muc -> store(C2SState, Pkt, Peer#jid.luser, LServer,
		    jid:replace_resource(Peer, LUser), Type, Dir);
	true -> store(C2SState, Pkt, LUser, LServer, Peer, Type, Dir)
    end.

store(C2SState, Pkt, LUser, LServer, Peer, Type, Dir) ->
    Prefs = get_prefs(LUser, LServer),
    case should_archive_peer(C2SState, Prefs, Peer) of
	true ->
	    do_store(Pkt, LUser, LServer, Peer, Type, Dir,
		     gen_mod:db_type(LServer, ?MODULE));
	false ->
	    pass
    end.

do_store(Pkt, LUser, LServer, Peer, Type, _Dir, mnesia) ->
    LPeer = {PUser, PServer, _} = jid:tolower(Peer),
    LServer2 = case Type of muc -> Peer#jid.lserver; _ -> LServer end,
    TS = p1_time_compat:timestamp(),
    ID = jlib:integer_to_binary(now_to_usec(TS)),
    case mnesia:dirty_write(
	   #archive_msg{us = {LUser, LServer2},
			id = ID,
			timestamp = TS,
			peer = LPeer,
			bare_peer = {PUser, PServer, <<>>},
			packet = Pkt}) of
	ok ->
	    {ok, ID};
	Err ->
	    Err
    end;
do_store(Pkt, LUser, LServer, Peer, Type, _Dir, p1db) ->
    Now = p1_time_compat:timestamp(),
    LServer2 = case Type of muc -> Peer#jid.lserver; _ -> LServer end,
    USNKey = usn2key(LUser, LServer2, Now),
    XML = fxml:element_to_binary(Pkt),
    Val = term_to_binary([{peer, Peer},
			  {packet, XML}]),
    case p1db:insert(archive_msg, USNKey, Val) of
	ok ->
	    ID = jlib:integer_to_binary(now_to_usec(Now)),
	    {ok, ID};
	{error, _} = Err ->
	    Err
    end;
do_store(Pkt, LUser, LServer, Peer, Type, Dir, rest) ->
    Now = p1_time_compat:timestamp(),
    LServer2 = case Type of muc -> Peer#jid.lserver; _ -> LServer end,
    SPeer = Peer#jid.luser,
    SUser = LUser,
    ID = jlib:integer_to_binary(now_to_usec(Now)),
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
    case rest:with_retry(post, [LServer2, Path, [],
		   {[{<<"username">>, SUser},
		     {<<"peer">>, SPeer},
		     {<<"timestamp">>, now_to_iso(Now)} | T]}], 2, 500) of
	{ok, Code, _} when Code == 200 orelse Code == 201 ->
	    {ok, ID};
	Err ->
	    ?ERROR_MSG("failed to store packet for user ~s and peer ~s:"
		       " ~p.  Packet: ~p  direction: ~p",
		       [SUser, SPeer, Err, Pkt, Dir]),
	    {error, Err}
    end;
do_store(Pkt, LUser, LServer, Peer, _Type, _Dir, DBType)
  when DBType==sql orelse DBType==sharding->
    TSinteger = p1_time_compat:system_time(micro_seconds),
    ID = TS = jlib:integer_to_binary(TSinteger),
    BarePeer = jid:to_string(
		 jid:tolower(
		   jid:remove_resource(Peer))),
    LPeer = jid:to_string(
	      jid:tolower(Peer)),
    XML = fxml:element_to_binary(Pkt),
    Body = fxml:get_subtag_cdata(Pkt, <<"body">>),
    Key = case DBType of
	      sql -> undefined;
	      sharding -> LUser
	  end,
    case ejabberd_sql:sql_query(
	    LServer, Key,
	    [<<"insert into archive (username, timestamp, "
		    "peer, bare_peer, xml, txt) values (">>,
		<<"'">>, ejabberd_sql:escape(LUser), <<"', ">>,
		<<"'">>, TS, <<"', ">>,
		<<"'">>, ejabberd_sql:escape(LPeer), <<"', ">>,
		<<"'">>, ejabberd_sql:escape(BarePeer), <<"', ">>,
		<<"'">>, ejabberd_sql:escape(XML), <<"', ">>,
		<<"'">>, ejabberd_sql:escape(Body), <<"');">>]) of
	{updated, _} ->
	    {ok, ID};
	Err ->
	    Err
    end.

write_prefs(LUser, LServer, Host, Default, Always, Never) ->
    DBType = case gen_mod:db_type(Host, ?MODULE) of
		 sql -> {sql, Host};
		 sharding -> {sharding, Host};
		 DB -> DB
	     end,
    Prefs = #archive_prefs{us = {LUser, LServer},
			   default = Default,
			   always = Always,
			   never = Never},
    case DBType of
	p1db ->
	    %% No need to cache as P1DB takes care of it
	    write_prefs(LUser, LServer, Prefs, DBType);
	_ ->
	    cache_tab:dirty_insert(
	      archive_prefs, {LUser, LServer}, Prefs,
	      fun() ->  write_prefs(LUser, LServer, Prefs, DBType) end)
    end.

write_prefs(_LUser, _LServer, Prefs, mnesia) ->
    mnesia:dirty_write(Prefs);
write_prefs(LUser, LServer, Prefs, p1db) ->
    Val = prefs_to_p1db(Prefs),
    USKey = us2key(LUser, LServer),
    p1db:insert(archive_prefs, USKey, Val);
write_prefs(_LUser, _LServer, _Prefs, rest) ->
    {error, unsupported_database};
write_prefs(LUser, _LServer, #archive_prefs{default = Default,
					   never = Never,
					   always = Always},
	    {DBType, Host}) ->
    SUser = ejabberd_sql:escape(LUser),
    SDefault = erlang:atom_to_binary(Default, utf8),
    SAlways = ejabberd_sql:encode_term(Always),
    SNever = ejabberd_sql:encode_term(Never),
    Key = case DBType of
	      sql -> undefined;
	      sharding -> LUser
    end,
    case update(Host, Key, <<"archive_prefs">>,
		[<<"username">>, <<"def">>, <<"always">>, <<"never">>],
		[SUser, SDefault, SAlways, SNever],
		[<<"username='">>, SUser, <<"'">>]) of
	{updated, _} ->
	    ok;
	Err ->
	    Err
    end.

get_prefs(LUser, LServer) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    Res = case DBType of
	      p1db ->
		  %% No need to cache as P1DB takes care of it
		  get_prefs(LUser, LServer, DBType);
	      _ ->
		  cache_tab:lookup(archive_prefs, {LUser, LServer},
				   fun() -> get_prefs(LUser, LServer,
						      DBType)
				   end)
	  end,
    case Res of
	{ok, Prefs} ->
	    Prefs;
	error ->
	    Default = gen_mod:get_module_opt(
		    LServer, ?MODULE, default,
		    fun(always) -> always;
			(never) -> never;
			(roster) -> roster
		    end, never),
	    #archive_prefs{us = {LUser, LServer}, default = Default}
    end.

get_prefs(LUser, LServer, mnesia) ->
    case mnesia:dirty_read(archive_prefs, {LUser, LServer}) of
	[Prefs] ->
	    {ok, Prefs};
	_ ->
	    error
    end;
get_prefs(LUser, LServer, p1db) ->
    USKey = us2key(LUser, LServer),
    case p1db:get(archive_prefs, USKey) of
	{ok, Val, _} ->
	    {ok, p1db_to_prefs({LUser, LServer}, Val)};
	{error, _} ->
	    error
    end;
get_prefs(_LUser, _LServer, rest) ->
    %% Unsupported so far
    error;
get_prefs(LUser, LServer, DBType)
  when DBType==sql orelse DBType==sharding->
    Key = case DBType of
	      sql -> undefined;
	      sharding -> LUser
	  end,
    case ejabberd_sql:sql_query(
	   LServer, Key,
	   [<<"select def, always, never from archive_prefs ">>,
	    <<"where username='">>,
	    ejabberd_sql:escape(LUser), <<"';">>]) of
	{selected, _, [[SDefault, SAlways, SNever]]} ->
	    Default = erlang:binary_to_existing_atom(SDefault, utf8),
	    Always = ejabberd_sql:decode_term(SAlways),
	    Never = ejabberd_sql:decode_term(SNever),
	    {ok, #archive_prefs{us = {LUser, LServer},
		    default = Default,
		    always = Always,
		    never = Never}};
	_ ->
	    error
    end.

select_and_send(#jid{lserver = LServer} = From,
		To, Start, End, With, RSM, IQ) ->
    DBType = case gen_mod:db_type(LServer, ?MODULE) of
		 sql -> {sql, LServer};
		 sharding -> {sharding, LServer};
		 DB -> DB
	     end,
    select_and_send(From, To, Start, End, With, RSM, IQ,
		    DBType).

select_and_send(From, To, Start, End, With, RSM, IQ, DBType) ->
    {Msgs, IsComplete, Count} = select_and_start(From, To, Start, End, With,
						 RSM, DBType),
    SortedMsgs = lists:keysort(2, Msgs),
    send(From, To, SortedMsgs, RSM, Count, IsComplete, IQ).

select_and_start(From, _To, StartUser, End, With, RSM, DB) ->
    {JidRequestor, Start, With2} = case With of
	{room, {LUserRoom, LServerRoom, <<>>} = WithJid} ->
	    JR = jid:make(LUserRoom,LServerRoom,<<>>),
	    St = StartUser,
	    {JR, St, WithJid};
	_ ->
	    {From, StartUser, With}
    end,
    select(JidRequestor, Start, End, With2, RSM, DB).

select(#jid{luser = LUser, lserver = LServer} = JidRequestor,
       Start, End, With, RSM, mnesia) ->
    MS = make_matchspec(LUser, LServer, Start, End, With),
    Msgs = mnesia:dirty_select(archive_msg, MS),
    {FilteredMsgs, IsComplete} = filter_by_rsm(Msgs, RSM),
    Count = length(Msgs),
    {lists:map(
       fun(Msg) ->
	       {Msg#archive_msg.id,
		jlib:binary_to_integer(Msg#archive_msg.id),
		msg_to_el(Msg, JidRequestor)}
       end, FilteredMsgs), IsComplete, Count};
select(#jid{luser = LUser, lserver = LServer} = JidRequestor,
       Start, End, With, RSM, rest) ->
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
    User = [{<<"username">>, LUser}],
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
	    Count = jlib:binary_to_integer(
		      proplists:get_value(<<"count">>, Archive, 0)),
	    IsComplete = proplists:get_value(<<"complete">>, Archive, false),
	    {lists:flatmap(
	       fun({Attrs}) ->
		       try
			   Pkt = build_xml_from_json(JidRequestor,
						     Attrs, StoreBody),
			   TS = proplists:get_value(<<"timestamp">>,
						    Attrs, <<"">>),
			   {_, _, _} = Now = jlib:datetime_string_to_timestamp(TS),
			   ID = now_to_usec(Now),
			   [{jlib:integer_to_binary(ID), ID,
			     msg_to_el(#archive_msg{
					  timestamp = Now,
					  packet = Pkt}, JidRequestor)}]
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
    end;
select(#jid{luser = LUser, lserver = LServer} = JidRequestor,
       Start, End, With, RSM, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(archive_msg, USPrefix) of
	{ok, L} ->
	    Msgs = lists:flatmap(
		     fun({Key, Val, _}) ->
			     TS = get_suffix(USPrefix, Key),
			     Now = usec_to_now(TS),
			     Opts = binary_to_term(Val),
			     Peer = proplists:get_value(peer, Opts),
			     case match_interval(Now, Start, End) and
				 match_with(Peer, With) and
				 match_rsm(Now, RSM) of
				 true ->
				     #xmlel{} = Pkt =
					 fxml_stream:parse_element(
					   proplists:get_value(packet,
							       Opts)),
				     [{jlib:integer_to_binary(TS), TS,
				       msg_to_el(#archive_msg{
						    timestamp = Now,
						    peer = Peer,
						    packet = Pkt},
						 JidRequestor)}];
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
    end;
select(#jid{luser = LUser, lserver = LServer} = JidRequestor,
       Start, End, With, RSM, {DBType, Host}) ->
	{Query, CountQuery} = make_sql_query(LUser, LServer,
					     Start, End, With, RSM),
    Key = case DBType of
	      sql -> undefined;
	      sharding -> LUser
	  end,
    % XXX TODO from XEP-0313:
    % To conserve resources, a server MAY place a reasonable limit on
    % how many stanzas may be pushed to a client in one request. If a
    % query returns a number of stanzas greater than this limit and
    % the client did not specify a limit using RSM then the server
    % should return a policy-violation error to the client.
    case {ejabberd_sql:sql_query(Host, Key, Query),
	  ejabberd_sql:sql_query(Host, Key, CountQuery)} of
	{{selected, _, Res}, {selected, _, [[Count]]}} ->
	    {Max, Direction} = case RSM of
				   #rsm_in{max = M, direction = D} -> {M, D};
				   _ -> {undefined, undefined}
			       end,
	    {Res1, IsComplete} =
		if Max >= 0 andalso Max /= undefined andalso length(Res) > Max ->
			if Direction == before ->
				{lists:nthtail(1, Res), false};
			   true ->
				{lists:sublist(Res, Max), false}
			end;
		   true ->
			{Res, true}
		end,
	    {lists:map(
	       fun([TS, XML, PeerBin]) ->
		       #xmlel{} = El = fxml_stream:parse_element(XML),
		       Now = usec_to_now(jlib:binary_to_integer(TS)),
		       PeerJid = jid:tolower(jid:from_string(PeerBin)),
		       {TS, jlib:binary_to_integer(TS),
			msg_to_el(#archive_msg{timestamp = Now,
					       packet = El,
					       peer = PeerJid},
				  JidRequestor)}
		    end, Res1), IsComplete, jlib:binary_to_integer(Count)};
	_ ->
	    {[], false, 0}
    end.

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

msg_to_el(#archive_msg{timestamp = TS, packet = Pkt1, peer = Peer},
	  JidRequestor) ->
    Delay = jlib:now_to_utc_string(TS),
    Pkt = maybe_update_from_to(Pkt1, JidRequestor, Peer),
    #xmlel{name = <<"forwarded">>,
	   attrs = [{<<"xmlns">>, ?NS_FORWARD}],
	   children = [#xmlel{name = <<"delay">>,
			      attrs = [{<<"xmlns">>, ?NS_DELAY},
				       {<<"stamp">>, Delay}]},
		       fxml:replace_tag_attr(
			 <<"xmlns">>, <<"jabber:client">>, Pkt)]}.

maybe_update_from_to(Pkt, _JIDRequestor, undefined) ->
    Pkt;
maybe_update_from_to(Pkt, JidRequestor, Peer) ->
    case fxml:get_attr_s(<<"type">>, Pkt#xmlel.attrs) of
	<<"groupchat">> ->
	    Pkt2 = fxml:replace_tag_attr(<<"to">>,
					jid:to_string(JidRequestor),
					Pkt),
	    fxml:replace_tag_attr(<<"from">>, jid:to_string(Peer),
				 Pkt2);
	_ -> Pkt
    end.

is_bare_copy(#jid{luser = U, lserver = S, lresource = R}, To) ->
    PrioRes = ejabberd_sm:get_user_present_resources(U, S),
    MaxRes = case catch lists:max(PrioRes) of
		 {_Prio, Res} when is_binary(Res) ->
		     Res;
		 _ ->
		     undefined
	     end,
    IsBareTo = case To of
		   #jid{lresource = <<"">>} ->
		       true;
		   #jid{lresource = LRes} ->
		       %% Unavailable resources are handled like bare JIDs.
		       lists:keyfind(LRes, 2, PrioRes) =:= false
	       end,
    case {IsBareTo, R} of
	{true, MaxRes} ->
	    ?DEBUG("Recipient of message to bare JID has top priority: ~s@~s/~s",
		   [U, S, R]),
	    false;
	{true, _R} ->
	    %% The message was sent to our bare JID, and we currently have
	    %% multiple resources with the same highest priority, so the session
	    %% manager routes the message to each of them. We store the message
	    %% only from the resource where R equals MaxRes.
	    ?DEBUG("Additional recipient of message to bare JID: ~s@~s/~s",
		   [U, S, R]),
	    true;
	{false, _R} ->
	    false
    end.

send(From, To, Msgs, RSM, Count, IsComplete, #iq{sub_el = SubEl} = IQ) ->
    QID = fxml:get_tag_attr_s(<<"queryid">>, SubEl),
    NS = fxml:get_tag_attr_s(<<"xmlns">>, SubEl),
    QIDAttr = if QID /= <<>> ->
		      [{<<"queryid">>, QID}];
		 true ->
		    []
	      end,
    CompleteAttr = if NS == ?NS_MAM_TMP ->
			   [];
		      NS == ?NS_MAM_0 ->
			   [{<<"complete">>, jlib:atom_to_binary(IsComplete)}]
		   end,
    Els = lists:map(
	    fun({ID, _IDInt, El}) ->
		    #xmlel{name = <<"message">>,
			   children = [#xmlel{name = <<"result">>,
					      attrs = [{<<"xmlns">>, NS},
						       {<<"id">>, ID}|QIDAttr],
					      children = [El]}]}
	    end, Msgs),
    RSMOut = make_rsm_out(Msgs, RSM, Count, QIDAttr ++ CompleteAttr, NS),
    case NS of
	?NS_MAM_TMP ->
	    lists:foreach(
	      fun(El) ->
		      ejabberd_router:route(To, From, El)
	      end, Els),
	    IQ#iq{type = result, sub_el = RSMOut};
	?NS_MAM_0 ->
	    ejabberd_router:route(
	      To, From, jlib:iq_to_xml(IQ#iq{type = result, sub_el = []})),
	    lists:foreach(
	      fun(El) ->
		      ejabberd_router:route(To, From, El)
	      end, Els),
	    ejabberd_router:route(
	      To, From, #xmlel{name = <<"message">>,
			       children = RSMOut}),
	    ignore
    end.


make_rsm_out(_Msgs, none, _Count, _Attrs, ?NS_MAM_TMP) ->
    [];
make_rsm_out(_Msgs, none, _Count, Attrs, ?NS_MAM_0) ->
    [#xmlel{name = <<"fin">>, attrs = [{<<"xmlns">>, ?NS_MAM_0}|Attrs]}];
make_rsm_out([], #rsm_in{}, Count, Attrs, NS) ->
    Tag = if NS == ?NS_MAM_TMP -> <<"query">>;
	     true -> <<"fin">>
	  end,
    [#xmlel{name = Tag, attrs = [{<<"xmlns">>, NS}|Attrs],
	    children = jlib:rsm_encode(#rsm_out{count = Count})}];
make_rsm_out([{FirstID, _, _}|_] = Msgs, #rsm_in{}, Count, Attrs, NS) ->
    {LastID, _, _} = lists:last(Msgs),
    Tag = if NS == ?NS_MAM_TMP -> <<"query">>;
	     true -> <<"fin">>
	  end,
    [#xmlel{name = Tag, attrs = [{<<"xmlns">>, NS}|Attrs],
	    children = jlib:rsm_encode(
			 #rsm_out{first = FirstID, count = Count,
				  last = LastID})}].

filter_by_rsm(Msgs, none) ->
    {Msgs, true};
filter_by_rsm(_Msgs, #rsm_in{max = Max}) when Max < 0 ->
    {[], true};
filter_by_rsm(Msgs, #rsm_in{max = Max, direction = Direction, id = ID}) ->
    NewMsgs = case Direction of
		  aft when ID /= <<"">> ->
		      lists:filter(
			fun(#archive_msg{id = I}) ->
				I > ID
			end, Msgs);
		  before when ID /= <<"">> ->
		      lists:foldl(
			fun(#archive_msg{id = I} = Msg, Acc) when I < ID ->
				[Msg|Acc];
			   (_, Acc) ->
				Acc
			end, [], Msgs);
		  before when ID == <<"">> ->
		      lists:reverse(Msgs);
		  _ ->
		      Msgs
	      end,
    filter_by_max(NewMsgs, Max).

filter_by_max(Msgs, undefined) ->
    {Msgs, true};
filter_by_max(Msgs, Len) when is_integer(Len), Len >= 0 ->
    {lists:sublist(Msgs, Len), length(Msgs) =< Len};
filter_by_max(_Msgs, _Junk) ->
    {[], true}.

match_interval(Now, Start, End) ->
    (Now >= Start) and (Now =< End).

match_with({jid, U, S, _, _, _, _}, {U, S, _}) -> true;
match_with({U, S, _}, {U, S, <<"">>}) -> true;
match_with(_, none) -> true;
match_with(Peer, With) -> Peer == With.

match_rsm(Now, #rsm_in{id = ID, direction = aft}) when ID /= <<"">> ->
    Now1 = (catch usec_to_now(jlib:binary_to_integer(ID))),
    Now > Now1;
match_rsm(Now, #rsm_in{id = ID, direction = before}) when ID /= <<"">> ->
    Now1 = (catch usec_to_now(jlib:binary_to_integer(ID))),
    Now < Now1;
match_rsm(_Now, _) ->
    true.

make_matchspec(LUser, LServer, Start, End, {_, _, <<>>} = With) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
		       us = US,
		       bare_peer = BPeer} = Msg)
	    when Start =< TS, End >= TS,
		 US == {LUser, LServer},
		 BPeer == With ->
	      Msg
      end);
make_matchspec(LUser, LServer, Start, End, {_, _, _} = With) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
		       us = US,
		       peer = Peer} = Msg)
	    when Start =< TS, End >= TS,
		 US == {LUser, LServer},
		 Peer == With ->
	      Msg
      end);
make_matchspec(LUser, LServer, Start, End, none) ->
    ets:fun2ms(
      fun(#archive_msg{timestamp = TS,
		       us = US,
		       peer = Peer} = Msg)
	    when Start =< TS, End >= TS,
		 US == {LUser, LServer} ->
	      Msg
      end).

make_sql_query(LUser, _LServer, Start, End, With, RSM) ->
    {Max, Direction, ID} = case RSM of
	#rsm_in{} ->
	    {RSM#rsm_in.max,
		RSM#rsm_in.direction,
		RSM#rsm_in.id};
	none ->
	    {none, none, <<>>}
    end,
    LimitClause = if is_integer(Max), Max >= 0 ->
			  [<<" limit ">>, jlib:integer_to_binary(Max+1)];
		     true ->
			  []
		  end,
    WithClause = case With of
		     {text, <<>>} ->
			 [];
		     {text, Txt} ->
			 [<<" and match (txt) against ('">>,
			  ejabberd_sql:escape(Txt), <<"')">>];
		     {_, _, <<>>} ->
			 [<<" and bare_peer='">>,
			  ejabberd_sql:escape(jid:to_string(With)),
			  <<"'">>];
		     {_, _, _} ->
			 [<<" and peer='">>,
			  ejabberd_sql:escape(jid:to_string(With)),
			  <<"'">>];
		     none ->
			 []
		 end,
    PageClause = case catch jlib:binary_to_integer(ID) of
		     I when is_integer(I), I >= 0 ->
			 case Direction of
			     before ->
				 [<<" AND timestamp < ">>, ID];
			     aft ->
				 [<<" AND timestamp > ">>, ID];
			     _ ->
				 []
			 end;
		     _ ->
			 []
		 end,
    StartClause = case Start of
		      {_, _, _} ->
			  [<<" and timestamp >= ">>,
			   jlib:integer_to_binary(now_to_usec(Start))];
		      _ ->
			  []
		  end,
    EndClause = case End of
		    {_, _, _} ->
			[<<" and timestamp <= ">>,
			 jlib:integer_to_binary(now_to_usec(End))];
		    _ ->
			[]
		end,
    SUser = ejabberd_sql:escape(LUser),

    Query = [<<"SELECT timestamp, xml, peer"
	      " FROM archive WHERE username='">>,
	     SUser, <<"'">>, WithClause, StartClause, EndClause,
	     PageClause],

    QueryPage =
	case Direction of
	    before ->
		% ID can be empty because of
		% XEP-0059: Result Set Management
		% 2.5 Requesting the Last Page in a Result Set
		[<<"SELECT timestamp, xml, peer FROM (">>, Query,
		 <<" ORDER BY timestamp DESC ">>,
		 LimitClause, <<") AS t ORDER BY timestamp ASC;">>];
	    _ ->
		[Query, <<" ORDER BY timestamp ASC ">>,
		 LimitClause, <<";">>]
	end,
    {QueryPage,
     [<<"SELECT COUNT(*) FROM archive WHERE username='">>,
      SUser, <<"'">>, WithClause, StartClause, EndClause, <<";">>]}.

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

get_jids(Els) ->
    lists:flatmap(
      fun(#xmlel{name = <<"jid">>} = El) ->
	      J = jid:from_string(fxml:get_tag_cdata(El)),
	      [jid:tolower(jid:remove_resource(J)),
	       jid:tolower(J)];
	 (_) ->
	      []
      end, Els).

update(LServer, Key, Table, Fields, Vals, Where) ->
    UPairs = lists:zipwith(fun (A, B) ->
				   <<A/binary, "='", B/binary, "'">>
			   end,
			   Fields, Vals),
    case ejabberd_sql:sql_query(LServer, Key,
				 [<<"update ">>, Table, <<" set ">>,
				  join(UPairs, <<", ">>), <<" where ">>, Where,
				  <<";">>])
	of
	{updated, 1} -> {updated, 1};
	_ ->
	    ejabberd_sql:sql_query(LServer, Key,
				    [<<"insert into ">>, Table, <<"(">>,
				     join(Fields, <<", ">>), <<") values ('">>,
				     join(Vals, <<"', '">>), <<"');">>])
    end.

%% Almost a copy of string:join/2.
join([], _Sep) -> [];
join([H | T], Sep) -> [H, [[Sep, X] || X <- T]].

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

enc_val(_, [SPeer, XML]) ->
    term_to_binary([{peer, #jid{} = jid:from_string(SPeer)},
		    {packet, XML}]).

dec_val(_, Bin) ->
    Opts = binary_to_term(Bin),
    Packet = proplists:get_value(packet, Opts),
    #jid{} = Peer = proplists:get_value(peer, Opts),
    [jid:to_string(Peer), Packet].

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

mod_opt_type(cache_life_time) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(cache_size) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(db_type) -> fun gen_mod:v_db/1;
mod_opt_type(default) ->
    fun (always) -> always;
	(never) -> never;
	(roster) -> roster
    end;
mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(store_body_only) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(_) ->
    [cache_life_time, cache_size, db_type, default, iqdisc,
     p1db_group, store_body_only].

opt_type(ext_api_path_archive) ->
    fun (X) -> iolist_to_binary(X) end;
opt_type(ext_api_path_items) ->
    fun (X) -> iolist_to_binary(X) end;
opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) ->
    [ext_api_path_archive, ext_api_path_items, p1db_group].
