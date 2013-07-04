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
               {attributes, record_info(fields, archive_msg)}]);
        _ ->
            ok
    end,
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
            NewPkt = strip_my_archived_tag(
                       jlib:replace_from_to(JID, Peer, Pkt), LServer),
            store(NewPkt, LUser, LServer, Peer),
            NewPkt;
        false ->
            Acc
    end.

process_iq(#jid{lserver = LServer} = From,
           #jid{lserver = LServer} = To,
           #iq{type = get, sub_el = SubEl} = IQ) ->
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

store(Pkt, LUser, LServer, Peer) ->
    store(Pkt, LUser, LServer, Peer,
          gen_mod:db_type(LServer, ?MODULE)).

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
    end.

select_and_send(#jid{lserver = LServer} = From,
                To, Start, End, With, RSM, QID) ->
    select_and_send(From, To, Start, End, With, RSM, QID,
                    gen_mod:db_type(LServer, ?MODULE)).

select_and_send(From, To, Start, End, With, RSM, QID, mnesia) ->
    Msgs = select(From, Start, End, With, RSM, mnesia),
    send(From, To, Msgs, RSM, QID).

select(#jid{luser = LUser, lserver = LServer},
       Start, End, With, none, mnesia) ->
    MS = make_matchspec(LUser, LServer, Start, End, With),
    lists:map(
      fun(Msg) ->
              {Msg#archive_msg.id, msg_to_el(Msg)}
      end, mnesia:dirty_select(archive_msg, MS)).

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
