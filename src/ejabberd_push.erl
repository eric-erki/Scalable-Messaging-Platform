%%%----------------------------------------------------------------------
%%% File    : ejabberd_push.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Push module support
%%% Created :  5 Jun 2009 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2015   ProcessOne
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

-author('alexey@process-one.net').

-export([build_push_packet_from_message/12]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("mod_privacy.hrl").

build_push_packet_from_message(From, To, Packet, ID, _AppID, SendBody, SendFrom, BadgeCount, First, FirstPerUser, SilentPushesEnabled, Module) ->
    Body1 = xml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),
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
    Pushed = check_x_pushed(Packet),
    Composing = xml:get_subtag_with_xmlns(Packet, <<"composing">>, ?NS_CHATSTATES),
    if
        Pushed ->
            skip;
        Body == <<"">> andalso (not SilentPushesEnabled orelse Composing /= false) ->
            skip;
        true ->
            BFrom = jid:remove_resource(From),
            SFrom = jid:to_string(BFrom),
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
                                                     case xml:get_tag_attr_s(<<"xmlns">>, E) of
                                                         ?NS_P1_PUSH_CUSTOMIZE ->
                                                             {true, {
                                                                xml:get_tag_attr_s(<<"mute">>, E) == <<"true">>,
                                                                xml:get_tag_attr_s(<<"sound">>, E),
                                                                xml:get_tag_attr_s(<<"nick">>, E),
                                                                case xml:get_subtag(E, <<"body">>) of
                                                                    false -> false;
                                                                    V -> xml:get_tag_cdata(V)
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
                                                         {false, true, <<"">>, false};
                                                     [Vals|_] ->
                                                         Vals
                                                 end,
            case Mute of
                true ->
                    skip;
                _ ->
                    Msg = if
                              IncludeBody ->
                                  CBody = case AltBody of
                                              false -> utf8_cut(Body, 100);
                                              _ -> utf8_cut(AltBody, 100)
                                          end,
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
                                                           case {xml:get_tag_attr_s(<<"xmlns">>, E),
                                                                 xml:get_tag_attr_s(<<"key">>, E),
                                                                 xml:get_tag_attr_s(<<"value">>, E)} of
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
                        case build_and_customize_push_packet(DeviceID, Msg, Badge, Sound, SFrom, To, CustomFields, Module) of
                            skip ->
                                skip;
                            V ->
                                {V, Body == <<"">>}
                        end
            end
    end.

build_and_customize_push_packet(DeviceID, Msg, Unread, Sound, Sender, JID, CustomFields, Module) ->
    LServer = JID#jid.lserver,
    case gen_mod:db_type(LServer, Module) of
        odbc ->
            LUser = ejabberd_odbc:escape(JID#jid.luser),
            SJID = jid:remove_resource(jid:tolower(jid:from_string(Sender))),
            LSender = ejabberd_odbc:escape(jid:to_string(SJID)),
            case ejabberd_odbc:sql_query(LServer,
                                         [<<"SELECT mute, sound FROM push_customizations WHERE username = '">>, LUser,
                                          <<"' AND match_jid = '">>, LSender, <<"';">>]) of
                {selected, _, [[1, _]]} ->
                    skip;
                {selected, _, [[_, S]]} when S /= null andalso Sound == true ->
                    build_push_packet(DeviceID, Msg, Unread, S, Sender, JID, CustomFields);
                _ ->
                    build_push_packet(DeviceID, Msg, Unread, Sound, Sender, JID, CustomFields)
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
			    build_push_packet(DeviceID, Msg, Unread,
					      CustomSound, Sender, JID,
					      CustomFields)
		    end;
		{error, _} ->
		    build_push_packet(DeviceID, Msg, Unread, Sound, Sender, JID, CustomFields)
	    end;
        _ ->
            build_push_packet(DeviceID, Msg, Unread, Sound, Sender, JID, CustomFields)
    end.

build_push_packet(DeviceID, Msg, Unread, Sound, Sender, JID, CustomFields) ->
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

utf8_cut(S, Bytes) -> utf8_cut(S, <<>>, <<>>, Bytes + 1).

utf8_cut(_S, _Cur, Prev, 0) -> Prev;
utf8_cut(<<>>, Cur, _Prev, _Bytes) -> Cur;
utf8_cut(<<C, S/binary>>, Cur, Prev, Bytes) ->
    if C bsr 6 == 2 ->
	   utf8_cut(S, <<Cur/binary, C>>, Prev, Bytes - 1);
       true -> utf8_cut(S, <<Cur/binary, C>>, Cur, Bytes - 1)
    end.

-include("mod_roster.hrl").

get_roster_name(To, JID) ->
    User = To#jid.luser,
    Server = To#jid.lserver,
    RosterItems = ejabberd_hooks:run_fold(
                    roster_get, Server, [], [{User, Server}]),
    JUser = JID#jid.luser,
    JServer = JID#jid.lserver,
    Item =
        lists:foldl(
          fun(_, Res = #roster{}) ->
                  Res;
             (I, false) ->
                  case I#roster.jid of
                      {JUser, JServer, _} ->
                          I;
                      _ ->
                          false
                  end
          end, false, RosterItems),
    case Item of
        false ->
            unescape(JID#jid.user);
        #roster{} ->
            Item#roster.name
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
    case xml:get_tag_attr_s(<<"xmlns">>, El) of
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
    case xml:get_tag_attr_s(<<"xmlns">>, El) of
	?NS_P1_ATTACHMENT ->
	    true;
	_ ->
	    check_x_attachment1(Els)
    end.
