%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2013, Evgeniy Khramtsov
%%% @doc
%%%      Message Archive Management (XEP-0313)
%%% @end
%%% Created :  4 Jul 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_mam).

-behaviour(gen_mod).

%% API
-export([start/2, stop/1]).
-export([user_send_packet/4, user_receive_packet/5, process_iq/3]).

-include_lib("stdlib/include/ms_transform.hrl").
-include("jlib.hrl").
-include("logger.hrl").

-define(NS_FORWARD, <<"urn:xmpp:forward:0">>).

-record(archive_msg,
        {us = {<<"">>, <<"">>}                :: {binary(), binary()},
         id = <<>>                            :: binary(),
         timestamp = now()                    :: erlang:timestamp() | '_',
         peer = {<<"">>, <<"">>, <<"">>}      :: ljid() | '_',
         bare_peer = {<<"">>, <<"">>, <<"">>} :: ljid() | '_',
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
    case gen_mod:db_type(Opts) of
        mnesia ->
            mnesia:create_table(
              archive_msg,
              [{disc_only_copies, [node()]},
               {type, bag},
               {attributes, record_info(fields, archive_msg)}]),
            mnesia:create_table(
              archive_prefs,
              [{disc_only_copies, [node()]},
               {attributes, record_info(fields, archive_prefs)}]);
        _ ->
            ok
    end,
    cache_tab:new(archive_prefs, []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
        			  ?NS_MAM, ?MODULE, process_iq, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
        			  ?NS_MAM, ?MODULE, process_iq, IQDisc),
    ejabberd_hooks:add(user_receive_packet, Host, ?MODULE,
                       user_receive_packet, 500),
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
                       user_send_packet, 500),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
			  user_send_packet, 500),
    ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE,
			  user_receive_packet, 500),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_MAM),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_MAM),
    ok.

user_receive_packet(Acc, JID, Peer, _To, Pkt) ->
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    case should_archive(Pkt) of
        true ->
            NewPkt = strip_my_archived_tag(Pkt, LServer),
            case store(NewPkt, LUser, LServer, Peer) of
                {ok, ID} ->
                    Archived = #xmlel{name = <<"archived">>,
                                      attrs = [{<<"by">>, LServer},
                                               {<<"xmlns">>, ?NS_MAM},
                                               {<<"id">>, ID}]},
                    NewEls = [Archived|NewPkt#xmlel.children],
                    NewPkt#xmlel{children = NewEls};
                _ ->
                    NewPkt
            end;
        false ->
            Acc
    end.

user_send_packet(Acc, JID, Peer, Pkt) ->
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    case should_archive(Pkt) of
        true ->
            NewPkt = strip_my_archived_tag(Pkt, LServer),
            store(jlib:replace_from_to(JID, Peer, NewPkt),
                  LUser, LServer, Peer),
            NewPkt;
        false ->
            Acc
    end.

process_iq(#jid{lserver = LServer} = From,
           #jid{lserver = LServer} = To,
           #iq{type = get, sub_el = #xmlel{name = <<"query">>} = SubEl} = IQ) ->
    case catch lists:foldl(
                 fun(#xmlel{name = <<"start">>} = El, {_, End, With, RSM}) ->
                         {{_, _, _} = 
                              jlib:datetime_string_to_timestamp(
                                xml:get_tag_cdata(El)),
                          End, With, RSM};
                    (#xmlel{name = <<"end">>} = El, {Start, _, With, RSM}) ->
                         {Start,
                          {_, _, _} =
                              jlib:datetime_string_to_timestamp(
                                xml:get_tag_cdata(El)),
                          With, RSM};
                    (#xmlel{name = <<"with">>} = El, {Start, End, _, RSM}) ->
                         {Start, End,
                          jlib:jid_tolower(
                            jlib:string_to_jid(xml:get_tag_cdata(El))),
                          RSM};
                    (#xmlel{name = <<"set">>}, {Start, End, With, _}) ->
                         {Start, End, With, jlib:rsm_decode(SubEl)};
                    (_, Acc) ->
                         Acc
                 end, {none, [], none, none},
                 SubEl#xmlel.children) of
        {'EXIT', _} ->
            IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]};
        {Start, End, With, RSM} ->
            QID = xml:get_tag_attr_s(<<"queryid">>, SubEl),
            select_and_send(From, To, Start, End, With, RSM, QID),
            IQ#iq{type = result, sub_el = []}
    end;
process_iq(#jid{luser = LUser, lserver = LServer},
           #jid{lserver = LServer},
           #iq{type = set, sub_el = #xmlel{name = <<"prefs">>} = SubEl} = IQ) ->
    Default = case xml:get_tag_attr_s(<<"default">>, SubEl) of
                  <<"always">> -> always;
                  <<"never">> -> never;
                  <<"roster">> -> roster
              end,
    {Always, Never} =
        lists:foldl(
          fun(#xmlel{name = <<"always">>, children = Els}, {A, N}) ->
                  {get_jids(Els) ++ A, N};
             (#xmlel{name = <<"never">>, children = Els}, {A, N}) ->
                  {A, get_jids(Els) ++ N};
             (_, {A, N}) ->
                  {A, N}
          end, {[], []}, SubEl#xmlel.children),
    case write_prefs(LUser, LServer, Default,
                     lists:usort(Always), lists:usort(Never)) of
        ok ->
            IQ#iq{type = result, sub_el = []};
        _Err ->
            IQ#iq{type = error, sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]}
    end;
process_iq(_, _, #iq{sub_el = SubEl} = IQ) ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
should_archive(#xmlel{name = <<"message">>} = Pkt) ->
    case {xml:get_attr_s(<<"type">>, Pkt#xmlel.attrs),
          xml:get_subtag_cdata(Pkt, <<"body">>)} of
        {<<"error">>, _} ->
            false;
        {<<"groupchat">>, _} ->
            %% FIXME: should we archive MUC?
            false;
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
               fun(#xmlel{name = <<"archived">>,
                          attrs = Attrs}) ->
                       case catch jlib:nameprep(
                                    jlib:string_to_jid(
                                      xml:get_attr_s(
                                        <<"by">>, Attrs))) of
                           LServer ->
                               false;
                           _ ->
                               true
                       end;
                  (_) ->
                       true
               end, Pkt#xmlel.children),
    Pkt#xmlel{children = NewEls}.

should_archive_peer(#archive_prefs{default = Default,
                                   always = Always,
                                   never = Never},
                    Peer) ->
    LPeer = jlib:jid_tolower(Peer),
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
                            %% TODO: implement this
                            false
                    end
            end
    end.

store(Pkt, LUser, LServer, Peer) ->
    case get_prefs(LUser, LServer) of
        {ok, Prefs} ->
            case should_archive_peer(Prefs, Peer) of
                true ->
                    store(Pkt, LUser, LServer, Peer,
                          gen_mod:db_type(LServer, ?MODULE));
                false ->
                    pass
            end;
        _Err ->
            pass
    end.

store(Pkt, LUser, LServer, Peer, mnesia) ->
    ID = randoms:get_string(),
    LPeer = {PUser, PServer, _} = jlib:jid_tolower(Peer),
    case mnesia:dirty_write(
           #archive_msg{us = {LUser, LServer},
                        id = ID,
                        timestamp = now(),
                        peer = LPeer,
                        bare_peer = {PUser, PServer, <<>>},
                        packet = Pkt}) of
        ok ->
            {ok, ID};
        Err ->
            Err
    end;
store(Pkt, LUser, LServer, Peer, odbc) ->
    ID = TS = now_to_usec(now()),
    BarePeer = jlib:jid_to_string(
                 jlib:jid_tolower(
                   jlib:jid_remove_resource(Peer))),
    LPeer = jlib:jid_to_string(
              jlib:jid_tolower(Peer)),
    XML = xml:element_to_binary(Pkt),
    case ejabberd_odbc:sql_query(
           LServer,
           [<<"insert into archive (username, timestamp, "
              "peer, bare_peer, xml) values (">>,
            <<"'">>, ejabberd_odbc:escape(LUser), <<"', ">>,
            <<"'">>, TS, <<"', ">>,
            <<"'">>, ejabberd_odbc:escape(LPeer), <<"', ">>,
            <<"'">>, ejabberd_odbc:escape(BarePeer), <<"', ">>,
            <<"'">>, ejabberd_odbc:escape(XML), <<"');">>]) of
        {updated, _} ->
            {ok, ID};
        Err ->
            Err
    end.

write_prefs(LUser, LServer, Default, Always, Never) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    Prefs = #archive_prefs{us = {LUser, LServer},
                           default = Default,
                           always = Always,
                           never = Never},
    cache_tab:dirty_insert(
      archive_prefs, {LUser, LServer}, Prefs,
      fun() ->  write_prefs(LUser, LServer, Prefs, DBType) end).

write_prefs(_LUser, _LServer, Prefs, mnesia) ->
    mnesia:dirty_write(Prefs);
write_prefs(LUser, LServer, #archive_prefs{default = Default,
                                           never = Never,
                                           always = Always},
            odbc) ->
    SUser = ejabberd_odbc:escape(LUser),
    SDefault = erlang:atom_to_binary(Default, utf8),
    SAlways = ejabberd_odbc:encode_term(Always),
    SNever = ejabberd_odbc:encode_term(Never),
    case update(LServer, <<"archive_prefs">>,
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
    cache_tab:lookup(archive_prefs, {LUser, LServer},
                     fun() -> get_prefs(LUser, LServer, DBType) end).

get_prefs(LUser, LServer, mnesia) ->
    case mnesia:dirty_read(archive_prefs, {LUser, LServer}) of
        [Prefs] ->
            {ok, Prefs};
        _ ->
            {ok, #archive_prefs{us = {LUser, LServer}}}
    end;
get_prefs(LUser, LServer, odbc) ->
    case ejabberd_odbc:sql_query(
           LServer, [<<"select def, always, never from archive_prefs ">>,
                     <<"where username='">>,
                     ejabberd_odbc:escape(LUser), <<"';">>]) of
        {selected, _, [[SDefault, SAlways, SNever]]} ->
            Default = erlang:binary_to_existing_atom(SDefault, utf8),
            Always = ejabberd_odbc:decode_term(SAlways),
            Never = ejabberd_odbc:decode_term(SNever),
            {ok, #archive_prefs{us = {LUser, LServer},
                                default = Default,
                                always = Always,
                                never = Never}};
        _ ->
            {ok, #archive_prefs{us = {LUser, LServer}}}
    end.

select_and_send(#jid{lserver = LServer} = From,
                To, Start, End, With, RSM, QID) ->
    select_and_send(From, To, Start, End, With, RSM, QID,
                    gen_mod:db_type(LServer, ?MODULE)).

select_and_send(From, To, Start, End, With, RSM, QID, DBType) ->
    Msgs = select(From, Start, End, With, RSM, DBType),
    send(From, To, Msgs, RSM, QID).

select(#jid{luser = LUser, lserver = LServer},
       Start, End, With, none, mnesia) ->
    MS = make_matchspec(LUser, LServer, Start, End, With),
    lists:map(
      fun(Msg) ->
              {Msg#archive_msg.id, msg_to_el(Msg)}
      end, mnesia:dirty_select(archive_msg, MS));
select(#jid{luser = LUser, lserver = LServer},
       Start, End, With, none, odbc) ->
    Query = make_sql_query(LUser, LServer, Start, End, With),
    case ejabberd_odbc:sql_query(LServer, Query) of
        {selected, _, Res} ->
            lists:map(
              fun([TS, XML]) ->
                      #xmlel{} = El = xml_stream:parse_element(XML),
                      Now = usec_to_now(TS),
                      {TS,
                       msg_to_el(#archive_msg{timestamp = Now, packet = El})}
              end, Res);
        _ ->
            []
    end.

msg_to_el(#archive_msg{timestamp = TS, packet = Pkt}) ->
    Delay = jlib:now_to_utc_string(TS),
    #xmlel{name = <<"forwarded">>,
           attrs = [{<<"xmlns">>, ?NS_FORWARD}],
           children = [#xmlel{name = <<"delay">>,
                              attrs = [{<<"xmlns">>, ?NS_DELAY},
                                       {<<"stamp">>, Delay}]},
                       xml:replace_tag_attr(
                         <<"xmlns">>, <<"jabber:client">>, Pkt)]}.

send(From, To, Msgs, _RSMOut, QID) ->
    lists:foreach(
      fun({ID, El}) ->
              ejabberd_router:route(
                To, From,
                #xmlel{name = <<"message">>,
                       children = [#xmlel{name = <<"result">>,
                                          attrs = [{<<"xmlns">>, ?NS_MAM},
                                                   {<<"id">>, ID}|
                                                   if QID /= <<>> ->
                                                           [{<<"queryid">>, QID}];
                                                      true ->
                                                           []
                                                   end],
                                          children = [El]}]})
      end, Msgs).

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

make_sql_query(LUser, _LServer, Start, End, With) ->
    WithClause = case With of
                     {_, _, <<>>} ->
                         [<<" and bare_peer='">>,
                          ejabberd_odbc:escape(jlib:jid_to_string(With)),
                          <<"'">>];
                     {_, _, _} ->
                         [<<" and peer='">>,
                          ejabberd_odbc:escape(jlib:jid_to_string(With)),
                          <<"'">>];
                     none ->
                         []
                 end,
    StartClause = case Start of
                      {_, _, _} ->
                          [<<" and timestamp >= ">>, now_to_usec(Start)];
                      _ ->
                          []
                  end,
    EndClause = case End of
                    {_, _, _} ->
                        [<<" and timestamp <= ">>, now_to_usec(Start)];
                    _ ->
                        []
                end,
    SUser = ejabberd_odbc:escape(LUser),
    [<<"select timestamp, xml from archive where username='">>, SUser, <<"'">>]
        ++ WithClause ++ StartClause ++ EndClause ++ [<<";">>].

now_to_usec({MSec, Sec, USec}) ->
    jlib:integer_to_binary((MSec*1000000 + Sec)*1000000 + USec).

usec_to_now(S) ->
    Int = jlib:binary_to_integer(S),
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.

get_jids(Els) ->
    lists:flatmap(
      fun(#xmlel{name = <<"jid">>} = El) ->
              J = jlib:string_to_jid(xml:get_tag_cdata(El)),
              [jlib:jid_tolower(jlib:jid_remove_resource(J)),
               jlib:jid_tolower(J)];
         (_) ->
              []
      end, Els).

update(LServer, Table, Fields, Vals, Where) ->
    UPairs = lists:zipwith(fun (A, B) ->
				   <<A/binary, "='", B/binary, "'">>
			   end,
			   Fields, Vals),
    case ejabberd_odbc:sql_query(LServer,
				 [<<"update ">>, Table, <<" set ">>,
				  join(UPairs, <<", ">>), <<" where ">>, Where,
				  <<";">>])
	of
      {updated, 1} -> {updated, 1};
      _ ->
	  ejabberd_odbc:sql_query(LServer,
				  [<<"insert into ">>, Table, <<"(">>,
				   join(Fields, <<", ">>), <<") values ('">>,
				   join(Vals, <<"', '">>), <<"');">>])
    end.

%% Almost a copy of string:join/2.
join([], _Sep) -> [];
join([H | T], Sep) -> [H, [[Sep, X] || X <- T]].
