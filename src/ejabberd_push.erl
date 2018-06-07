%%%----------------------------------------------------------------------
%%% File    : ejabberd_push.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Push module support
%%% Created :  5 Jun 2009 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2017   ProcessOne
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
%%%----------------------------------------------------------------------

-module(ejabberd_push).

-compile([{parse_transform, ejabberd_sql_pt}]).

-author('alexey@process-one.net').

-export([build_push_packet_from_message/12, utf8_cut/2, will_probably_push_for_message/4,
	 process_push_for_received_message/6]).

-include("ejabberd.hrl").
-include("ejabberd_sm.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("mod_privacy.hrl").
-include("ejabberd_sql_pt.hrl").

extract_payload_from_message(Packet) ->
    case fxml:get_subtag_with_xmlns(
	Packet, <<"event">>, ?NS_PUBSUB_EVENT) of
	#xmlel{} = EventEl ->
	    case fxml:get_subtag(EventEl, <<"items">>) of
		#xmlel{} = ItemsEl ->
		    case fxml:get_tag_attr_s(<<"node">>, ItemsEl) of
			Node when Node == ?NS_MUCSUB_NODES_MESSAGES;
				  Node == ?NS_MUCSUB_NODES_SUBJECT ->
			    case fxml:get_subtag(ItemsEl, <<"item">>) of
				#xmlel{} = ItemEl ->
				    case fxml:get_subtag(ItemEl, <<"message">>) of
					#xmlel{} = MessageEl ->
					    MessageEl;
					false ->
					    Packet
				    end;
				false ->
				    Packet
			    end;
			_ ->
			    Packet
		    end;
		false ->
		    Packet
	    end;
	false ->
	    Packet
    end.

will_probably_push_for_message(From, _To, Packet0, SilentPushEnabled) ->
    Packet = extract_payload_from_message(Packet0),
    Body1 = fxml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),
    Body = case check_x_attachment(Packet) of
	true ->
	    case Body1 of
		<<"">> -> <<238, 128, 136>>;
		_ ->
		    <<238, 128, 136, 32, Body1/binary>>
	    end;
	false ->
	    Body1
    end,
    Composing = fxml:get_subtag_with_xmlns(Packet, <<"composing">>, ?NS_CHATSTATES),
    if
	Body == <<"">> andalso (not SilentPushEnabled orelse Composing /= false) ->
	    false;
	true ->
	    Customizations = lists:filtermap(
		fun(#xmlel{name = <<"customize">>} = E) ->
		    case fxml:get_tag_attr_s(<<"xmlns">>, E) of
			?NS_P1_PUSH_CUSTOMIZE ->
			    {true, {
				fxml:get_tag_attr_s(<<"mute">>, E) == <<"true">>,
				case fxml:get_subtag(E, <<"body">>) of
				    false -> Body;
				    V -> fxml:get_tag_cdata(V)
				end
			    }};
			_ ->
			    false
		    end;
		   (_) ->
		       false
		end, Packet#xmlel.children),
	    {Mute, AltBody} = case Customizations of
				  [] ->
				      {false, Body};
				  [Vals | _] ->
				      Vals
			      end,
	    case Mute of
		true ->
		    skip;
		_ ->
		    {Msg, _, Custom0}  =
		    if Body /= <<>> ->
			process_muc_invitations(Packet, From, AltBody);
			true ->
			    {AltBody, From, []}
		    end,
		    CustomFields = lists:filtermap(
			fun(#xmlel{name = <<"x">>} = E) ->
			    case {fxml:get_tag_attr_s(<<"xmlns">>, E),
				  fxml:get_tag_attr_s(<<"key">>, E),
				  fxml:get_tag_attr_s(<<"value">>, E)} of
				{?NS_P1_PUSH_CUSTOM, K, V} when K /= <<"">> ->
				    {true, {K, V}};
				_ ->
				    false
			    end;
			   (_) ->
			       false
			end, Packet#xmlel.children),
		    case {Msg, Custom0, CustomFields} of
			{<<>>, [], []} ->
			    false;
			_ ->
			    true
		    end
	    end
    end.

process_push_for_received_message(From, To, #xmlel{name = <<"message">>} = Packet,
				  Server, Notification, C2SPid) ->
    #jid{lserver = LServer, luser = LUser} = To,
    C2SPids = lists:filtermap(
	fun(#session{sid = {_, Pid}}) when Pid == C2SPid ->
	       false;
	   (#session{sid = {_, Pid}}) ->
	       {true, Pid}
	end, ejabberd_sm:get_user_sessions(LUser, LServer)),
    PI = lists:map(
	     fun(Pid1) ->
		 catch ejabberd_c2s:get_push_config(Pid1)
	     end, C2SPids),
    AllNotifications = lists:filter(fun(#xmlel{}) -> true; (_) -> false end, [Notification | PI]),
    CleanPacket = fxml:remove_subtags(
	Packet, <<"x">>,
	{<<"xmlns">>, ?NS_P1_PUSHED}),
    Pushed = ejabberd_hooks:run_fold(
	push_for_received_message,
	Server,
	false,
	[AllNotifications, From, To, CleanPacket]),
    case Pushed of
	true ->
	    fxml:append_subtags(
		CleanPacket,
		[#xmlel{name  = <<"x">>,
			attrs = [{<<"xmlns">>, ?NS_P1_PUSHED}]}]);
	_ ->
	    Packet
    end;
process_push_for_received_message(_From, _To, Packet, _Server, _Notification, _C2SPid) ->
    Packet.


build_push_packet_from_message(From, To, Packet, ID, _AppID, SendBody, SendFrom, BadgeCount, First,
			       FirstPerUser, SilentPushEnabled, Module) ->
    Pushed = check_x_pushed(Packet),
    case Pushed of
	true ->
	    skip;
	_ ->
	    Packet2 = extract_payload_from_message(Packet),
	    build_push_packet_from_message2(From, To, Packet2, ID, _AppID, SendBody, SendFrom, BadgeCount,
					    First, FirstPerUser, SilentPushEnabled, Module, Pushed)
    end.

build_push_packet_from_message2(From, To, Packet, ID, _AppID, SendBody, SendFrom, BadgeCount, First,
				FirstPerUser, SilentPushEnabled, Module, Pushed) ->
    Body1 = fxml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),
    MsgId = fxml:get_tag_attr_s(<<"id">>, Packet),
    Body =
        case check_x_attachment(Packet) of
            true ->
                case Body1 of
                    <<"">> -> <<238, 128, 136>>;
                    _ ->
                        <<238, 128, 136, 32, Body1/binary>>
                end;
            false ->
                    Body1
        end,
    Composing = fxml:get_subtag_with_xmlns(Packet, <<"composing">>, ?NS_CHATSTATES),
    if
        Pushed ->
            skip;
        Body == <<"">> andalso (not SilentPushEnabled orelse Composing /= false) ->
            skip;
        true ->
            IncludeBody =
                case {Body, SendBody} of
                    {<<"">>, _} ->
                        false;
                    {_, all} ->
                        true;
                    {_, first_per_user} ->
                        FirstPerUser;
                    {_, first} ->
                        First;
                    {_, none} ->
                            false
                end,
            Customizations = lists:filtermap(fun(#xmlel{name = <<"customize">>} = E) ->
                                                     case fxml:get_tag_attr_s(<<"xmlns">>, E) of
                                                         ?NS_P1_PUSH_CUSTOMIZE ->
                                                             {true, {
                                                                fxml:get_tag_attr_s(<<"mute">>, E) == <<"true">>,
                                                                fxml:get_tag_attr_s(<<"sound">>, E),
                                                                fxml:get_tag_attr_s(<<"nick">>, E),
                                                                case fxml:get_subtag(E, <<"body">>) of
                                                                    false -> Body;
                                                                    V -> fxml:get_tag_cdata(V)
                                                                end
                                                               }};
                                                         _ ->
                                                             false
                                                     end;
                                                (_) ->
                                                     false
                                             end, Packet#xmlel.children),
            {Mute, AltSound, AltNick, AltBody} = case Customizations of
                                                     [] ->
                                                         {false, true, <<"">>, Body};
                                                     [Vals|_] ->
                                                         Vals
                                                 end,
            case Mute of
                true ->
                    skip;
                _ ->
		    {Body0, From0, Custom0}  = if IncludeBody ->
							   process_muc_invitations(Packet, From, AltBody);
						      true ->
							   {AltBody, From, []}
						   end,
		    BFrom = jid:remove_resource(From0),
		    SFrom = jid:to_string(BFrom),
                    Msg = if
                              IncludeBody ->
                                  CBody = utf8_cut(Body0, 512),
                                  case {AltNick, SendFrom} of
                                      {N, _} when N /= <<"">> ->
                                          prepend_sender(N, CBody);
                                      {_, jid} ->
                                          prepend_sender(SFrom, CBody);
                                      {_, username} ->
                                          UnescapedFrom = unescape(BFrom#jid.user),
                                          prepend_sender(
                                            UnescapedFrom, CBody);
                                      {_, name} ->
                                          Name = get_roster_name(
                                                   To, BFrom),
                                          prepend_sender(Name, CBody);
                                      _ -> CBody
                                  end;
                              true ->
                                  <<"">>
                          end,
                    CustomFields = lists:filtermap(fun(#xmlel{name = <<"x">>} = E) ->
                                                           case {fxml:get_tag_attr_s(<<"xmlns">>, E),
                                                                 fxml:get_tag_attr_s(<<"key">>, E),
                                                                 fxml:get_tag_attr_s(<<"value">>, E)} of
                                                               {?NS_P1_PUSH_CUSTOM, K, V} when K /= <<"">> ->
                                                                   {true, {K, V}};
                                                               _ ->
                                                                   false
                                                           end;
                                                      (_) ->
                                                           false
                                                   end, Packet#xmlel.children),
                    DeviceID = if is_integer(ID) -> jlib:integer_to_binary(ID, 16);
                                  true -> ID
                               end,
                    Badge = if Body == <<"">> -> none;
                               true -> BadgeCount
                            end,
                    Sound = case {IncludeBody, AltSound} of
                                {false, _} -> false;
                                {_, <<"false">>} -> false;
                                {_, S} when S /= <<"">> -> S;
                                _ -> true
                            end,
		    case build_and_customize_push_packet(DeviceID, Msg, MsgId, Badge, Sound, SFrom, To,
							 Custom0 ++ CustomFields, Module) of
			skip ->
			    skip;
			V ->
			    {V, Body == <<"">>}
		    end
            end
    end.

build_and_customize_push_packet(DeviceID, Msg, MsgId, Unread, Sound, Sender, JID, CustomFields, _Module) ->
    LServer = JID#jid.lserver,
    case gen_mod:db_type(LServer, mod_applepush) of
        sql ->
            LUser = JID#jid.luser,
            SJID = jid:remove_resource(jid:tolower(jid:from_string(Sender))),
            LSender = jid:to_string(SJID),
            case ejabberd_sql:sql_query(
                   LServer,
                   ?SQL("SELECT @(mute)b, @(sound)s FROM push_customizations"
                        " WHERE username = %(LUser)s AND"
                        " match_jid = %(LSender)s")) of
                {selected, [{true, _}]} ->
                    skip;
                {selected, [{_, S}]} when S /= null andalso Sound == true ->
                    build_push_packet(DeviceID, Msg, MsgId, Unread, S, Sender, JID, CustomFields);
                _ ->
                    build_push_packet(DeviceID, Msg, MsgId, Unread, Sound, Sender, JID, CustomFields)
            end;
	p1db ->
	    LUser = JID#jid.luser,
	    SenderJID = jid:from_string(Sender),
	    case mod_applepush:read_push_customizations(LUser, LServer, SenderJID) of
		{ok, Opts} ->
		    Mute = proplists:get_bool(mute, Opts),
		    CustomSound = proplists:get_value(sound, Opts, <<"">>),
		    if Mute ->
			    skip;
		       true ->
			    build_push_packet(DeviceID, Msg, MsgId, Unread,
					      CustomSound, Sender, JID,
					      CustomFields)
		    end;
		{error, _} ->
		    build_push_packet(DeviceID, Msg, MsgId, Unread, Sound, Sender, JID, CustomFields)
	    end;
        _ ->
            build_push_packet(DeviceID, Msg, MsgId, Unread, Sound, Sender, JID, CustomFields)
    end.

build_push_packet(DeviceID, Msg, MsgId, Unread, Sound, Sender, JID, CustomFields) ->
    Badge = case Unread of
                none -> <<"">>;
                _ -> jlib:integer_to_binary(Unread)
            end,
    SSound = case Sound of
                 true -> <<"true">>;
                 false -> <<"false">>;
                 _ -> Sound
             end,
    Receiver = jid:to_string(JID),
    #xmlel{name = <<"message">>,
           attrs = [],
           children =
           [#xmlel{name = <<"push">>, attrs = [{<<"xmlns">>, ?NS_P1_PUSH}],
                   children =
                       [#xmlel{name = <<"id">>, attrs = [],
                               children = [{xmlcdata, DeviceID}]},
                        #xmlel{name = <<"msg">>, attrs = [],
                               children = [{xmlcdata, Msg}]},
			#xmlel{name = <<"msgid">>, attrs = [],
			       children = [{xmlcdata, MsgId}]},
                        #xmlel{name = <<"badge">>, attrs = [],
                               children = [{xmlcdata, Badge}]},
                        #xmlel{name = <<"sound">>, attrs = [],
                           children = [{xmlcdata, SSound}]},
                        #xmlel{name = <<"from">>, attrs = [],
                               children = [{xmlcdata, Sender}]},
                        #xmlel{name = <<"to">>, attrs = [],
                               children = [{xmlcdata, Receiver}]}] ++
                       build_custom(CustomFields)
                  }
           ]}.

process_muc_invitations(Packet, Sender, Body) ->
    {From, Reason, Password} =
	case fxml:get_subtag_with_xmlns(Packet, <<"x">>, ?NS_MUC_USER) of
	    false ->
		{false, <<>>, <<>>};
	    XEl ->
		{From0, Reason0} =
		    case fxml:get_subtag(XEl, <<"invite">>) of
			false ->
			    {false, <<>>};
			XIEl ->
			    From1 = fxml:get_tag_attr_s(<<"from">>, XIEl),
			    Reason1 = fxml:get_path_s(XIEl, [{elem, <<"reason">>}, cdata]),
			    Reason2 = re:replace(Reason1, <<"^\\s*(.*?)\\s*$">>, <<"\\1">>),
			    {From1, iolist_to_binary(Reason2)}
                       end,
		Password0 = fxml:get_path_s(XEl, [{elem, <<"password">>}, cdata]),
		{From0, Reason0, Password0}
	end,
    case From of
	false ->
	    {Body, Sender, []};
	_ ->
	    FromJid = case jid:from_string(From) of
		       #jid{} = JID -> JID;
		       _ -> Sender
		   end,
	    Room = jid:to_string(Sender),
	    RoomName = Sender#jid.user,
	    NewBody = case Reason of
			  <<"">> ->
			      <<"Invites you to room '", RoomName/binary, "'">>;
			  _ ->
			      <<"Invites you to room '", RoomName/binary, "' - ", Reason/binary>>
			  end,
	    Extras = case Password of
			 <<"">> -> [{<<"muc_invite_room">>, Room}];
			 _ -> [{<<"muc_invite_room">>, Room}, {<<"muc_invite_pass">>, Password}]
		     end,
	    {NewBody, FromJid, Extras}
    end.

build_custom([]) -> [];
build_custom(Fields) ->
    [#xmlel{name = <<"custom">>, attrs = [],
            children =
            [#xmlel{name = <<"field">>, attrs = [{<<"name">>, Name}],
                    children =
                    [{xmlcdata, Value}]} || {Name, Value} <- Fields]}].

prepend_sender(<<"">>, Body) ->
    Body;
prepend_sender(From, Body) ->
    <<From/binary, ": ", Body/binary>>.

utf8_cut(S, Size) when size(S) =< Size -> S;
utf8_cut(S, Bytes) -> utf8_cut(S, <<>>, <<>>, Bytes + 1).

utf8_cut(_S, _Cur, Prev, 0) -> Prev;
utf8_cut(<<>>, Cur, _Prev, _Bytes) -> Cur;
utf8_cut(<<C, S/binary>>, Cur, Prev, Bytes) ->
    if C bsr 6 == 2 ->
	   utf8_cut(S, <<Cur/binary, C>>, Prev, Bytes - 1);
       true -> utf8_cut(S, <<Cur/binary, C>>, Cur, Bytes - 1)
    end.

-include("mod_roster.hrl").

first_roster_item([#roster{jid={User, Server, _}} = RI | _], User, Server) ->
    RI;
first_roster_item([_ | Tail], User, Server) ->
    first_roster_item(Tail, User, Server);
first_roster_item([], _, _) ->
    false.

get_roster_name(To, JID) ->
    User = To#jid.luser,
    Server = To#jid.lserver,
    RosterItems = ejabberd_hooks:run_fold(
                    roster_get, Server, [], [{User, Server}]),
    JUser = JID#jid.luser,
    JServer = JID#jid.lserver,
    case first_roster_item(RosterItems, JUser, JServer) of
        false ->
            unescape(JID#jid.user);
        #roster{name = <<>>} ->
            unescape(JID#jid.user);
        #roster{name = N} ->
	    N
    end.

unescape(<<"">>) -> <<"">>;
unescape(<<"\\20", S/binary>>) ->
    <<"\s", (unescape(S))/binary>>;
unescape(<<"\\22", S/binary>>) ->
    <<"\"", (unescape(S))/binary>>;
unescape(<<"\\26", S/binary>>) ->
    <<"&", (unescape(S))/binary>>;
unescape(<<"\\27", S/binary>>) ->
    <<"'", (unescape(S))/binary>>;
unescape(<<"\\2f", S/binary>>) ->
    <<"/", (unescape(S))/binary>>;
unescape(<<"\\3a", S/binary>>) ->
    <<":", (unescape(S))/binary>>;
unescape(<<"\\3c", S/binary>>) ->
    <<"<", (unescape(S))/binary>>;
unescape(<<"\\3e", S/binary>>) ->
    <<">", (unescape(S))/binary>>;
unescape(<<"\\40", S/binary>>) ->
    <<"@", (unescape(S))/binary>>;
unescape(<<"\\5c", S/binary>>) ->
    <<"\\", (unescape(S))/binary>>;
unescape(<<C, S/binary>>) -> <<C, (unescape(S))/binary>>.

check_x_pushed(#xmlel{children = Els}) ->
    check_x_pushed1(Els).

check_x_pushed1([]) ->
    false;
check_x_pushed1([{xmlcdata, _} | Els]) ->
    check_x_pushed1(Els);
check_x_pushed1([El | Els]) ->
    case fxml:get_tag_attr_s(<<"xmlns">>, El) of
	?NS_P1_PUSHED ->
	    true;
	_ ->
	    check_x_pushed1(Els)
    end.

check_x_attachment(#xmlel{children = Els}) ->
    check_x_attachment1(Els).

check_x_attachment1([]) ->
    false;
check_x_attachment1([{xmlcdata, _} | Els]) ->
    check_x_attachment1(Els);
check_x_attachment1([El | Els]) ->
    case fxml:get_tag_attr_s(<<"xmlns">>, El) of
	?NS_P1_ATTACHMENT ->
	    true;
	_ ->
	    check_x_attachment1(Els)
    end.
