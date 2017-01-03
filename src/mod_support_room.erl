%%%----------------------------------------------------------------------
%%% File    : mod_support_room.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Support chat room
%%% Created : 15 Aug 2014 by Alexey Shchepin <alexey@process-one.net>
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

-module(mod_support_room).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-define(GEN_FSM, p1_fsm).

-behaviour(?GEN_FSM).

%% External exports
-export([start_link/10, start_link/8, start_link/2,
	 start/10, start/8, start/2, migrate/3, route/4,
	 moderate_room_history/2, persist_recent_messages/1,
         expand_opts/1, encode_opts/2, decode_opts/2,
         config_fields/0]).

-export([init/1, normal_state/2, handle_event/3,
	 handle_sync_event/4, handle_info/3, terminate/3,
	 print_state/1, code_change/4, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-define(MAX_USERS_DEFAULT, 200).
-define(RING_TIMEOUT, 15000).

-define(SETS, gb_sets).

-define(DICT, dict).

-record(lqueue,
{
    queue :: ?TQUEUE,
    len :: integer(),
    max :: integer()
}).

-type lqueue() :: #lqueue{}.

-record(config,
{
    title                                = <<"">> :: binary(),
    description                          = <<"">> :: binary(),
    allow_change_subj                    = true :: boolean(),
    allow_query_users                    = true :: boolean(),
    allow_private_messages               = true :: boolean(),
    allow_private_messages_from_visitors = anyone :: anyone | moderators | nobody ,
    allow_visitor_status                 = true :: boolean(),
    allow_visitor_nickchange             = true :: boolean(),
    public                               = true :: boolean(),
    public_list                          = true :: boolean(),
    persistent                           = false :: boolean(),
    moderated                            = true :: boolean(),
    captcha_protected                    = false :: boolean(),
    members_by_default                   = true :: boolean(),
    members_only                         = false :: boolean(),
    allow_user_invites                   = false :: boolean(),
    password_protected                   = false :: boolean(),
    password                             = <<"">> :: binary(),
    anonymous                            = true :: boolean(),
    allow_voice_requests                 = true :: boolean(),
    voice_request_min_interval           = 1800 :: non_neg_integer(),
    max_users                            = ?MAX_USERS_DEFAULT :: non_neg_integer() | none,
    logging                              = false :: boolean(),
    vcard                                = <<"">> :: binary(),
    hibernate_time                       = 0 :: non_neg_integer(),
    captcha_whitelist                    = (?SETS):empty() :: ?TGB_SET
}).

-type config() :: #config{}.

-type role() :: moderator | participant | visitor | none.

-record(user,
{
    jid :: jid(),
    status,
    ts,
    nick :: binary(),
    role :: role(),
    last_presence :: xmlel(),
    is_available = false :: boolean(),
    push_info
}).

-record(activity,
{
    message_time    = 0 :: integer(),
    presence_time   = 0 :: integer(),
    message_shaper :: shaper:shaper(),
    presence_shaper :: shaper:shaper(),
    message :: xmlel(),
    presence :: {binary(), xmlel()}
}).

-record(state,
{
    room                    = <<"">> :: binary(),
    host                    = <<"">> :: binary(),
    server_host             = <<"">> :: binary(),
    access                  = {none,none,none,none} :: {atom(), atom(), atom(), atom()},
    jid                     = #jid{} :: jid(),
    config                  = #config{} :: config(),
    users                   = (?DICT):new() :: ?TDICT,
    last_voice_request_time = treap:empty() :: treap:treap(),
    robots                  = (?DICT):new() :: ?TDICT,
    nicks                   = (?DICT):new() :: ?TDICT,
    affiliations            = (?DICT):new() :: ?TDICT,
    agent_status            = (?DICT):new() :: ?TDICT,
    user_status             = (?DICT):new() :: ?TDICT,
    available_agents        = treap:empty() :: treap:treap(),
    user_queue              = treap:empty() :: treap:treap(),
    ringing_queue           = treap:empty() :: treap:treap(),
    history                 :: lqueue(),
    persist_history         = false :: boolean(),
    subject                 = <<"">> :: binary(),
    subject_author          = <<"">> :: binary(),
    just_created            = false :: boolean(),
    activity                = treap:empty() :: treap:treap(),
    hibernate_timer         = make_ref() :: reference(),
    room_shaper             = none :: shaper:shaper(),
    shutdown_reason         :: atom(),
    room_queue              = queue:new() :: ?TQUEUE
}).

-record(support_online_users, {us = {<<>>, <<>>} :: {binary(), binary()},
                           resource = <<>> :: binary() | '_',
                           room = <<>> :: binary() | '_',
                           host = <<>> :: binary() | '_'}).


-define(NS_SUPPORT, <<"p1:support">>).
-define(NS_SUPPORT_USER,
	<<"p1:support#user">>).
-define(NS_SUPPORT_ADMIN,
	<<"p1:support#admin">>).
-define(NS_SUPPORT_OWNER,
	<<"p1:support#owner">>).



-define(MAX_USERS_DEFAULT_LIST,
	[5, 10, 20, 30, 50, 100, 200, 500, 1000, 2000, 5000]).

%-define(DBGFSM, true).

-ifdef(DBGFSM).

-define(FSMOPTS, [{debug, [trace]}|fsm_limit_opts()]).

-else.

-define(FSMOPTS, fsm_limit_opts()).

-endif.

start(Host, ServerHost, Access, Room, HistorySize,
      PersistHistory, RoomShaper, Creator, Nick,
      DefRoomOpts) ->
    Supervisor = gen_mod:get_module_proc(ServerHost,
					 ejabberd_mod_support_sup),
    supervisor:start_child(Supervisor,
		[Host, ServerHost, Access, Room, HistorySize,
		 PersistHistory, RoomShaper, Creator, Nick, DefRoomOpts]).

start(Host, ServerHost, Access, Room, HistorySize,
      PersistHistory, RoomShaper, Opts) ->
    Supervisor = gen_mod:get_module_proc(ServerHost,
					 ejabberd_mod_support_sup),
    supervisor:start_child(Supervisor,
		[Host, ServerHost, Access, Room, HistorySize,
		 PersistHistory, RoomShaper, Opts]).

start(StateName, StateData) ->
    ServerHost = StateData#state.server_host,
    Supervisor = gen_mod:get_module_proc(ServerHost,
					 ejabberd_mod_support_sup),
    supervisor:start_child(Supervisor, [StateName, StateData]).

start_link(Host, ServerHost, Access, Room, HistorySize,
	   PersistHistory, RoomShaper, Creator, Nick,
	   DefRoomOpts) ->
    (?GEN_FSM):start_link(?MODULE,
			  [Host, ServerHost, Access, Room, HistorySize,
			   PersistHistory, RoomShaper, Creator, Nick,
			   DefRoomOpts],
			  ?FSMOPTS).

start_link(Host, ServerHost, Access, Room, HistorySize,
	   PersistHistory, RoomShaper, Opts) ->
    (?GEN_FSM):start_link(?MODULE,
			  [Host, ServerHost, Access, Room, HistorySize,
			   PersistHistory, RoomShaper, Opts],
			  ?FSMOPTS).

start_link(StateName, StateData) ->
    (?GEN_FSM):start_link(?MODULE, [StateName, StateData],
			  ?FSMOPTS).

migrate(FsmRef, Node, After) when node(FsmRef) == node() ->
    erlang:send_after(After, FsmRef, {migrate, Node});
migrate(_FsmRef, _Node, _After) ->
    ok.

moderate_room_history(FsmRef, Nick) ->
    (?GEN_FSM):sync_send_all_state_event(FsmRef,
					 {moderate_room_history, Nick}).

persist_recent_messages(FsmRef) ->
    (?GEN_FSM):sync_send_all_state_event(FsmRef,
					 persist_recent_messages).

init([Host, ServerHost, Access, Room, HistorySize,
      PersistHistory, RoomShaper, Creator, _Nick,
      DefRoomOpts]) ->
    process_flag(trap_exit, true),
    mod_support:register_room(ServerHost, Host, Room, self()),
    Shaper = shaper:new(RoomShaper),
    State = #state{host = Host, server_host = ServerHost,
                   access = Access, room = Room,
                   history = lqueue_new(HistorySize),
                   persist_history = PersistHistory,
                   jid = jid:make(Room, Host, <<"">>),
                   just_created = true, room_shaper = Shaper},
    State1 = set_opts(DefRoomOpts, State),
    State2 = set_affiliation(Creator, owner, State1),
    if (State2#state.config)#config.persistent ->
	   mod_support:store_room(State2#state.server_host,
                              State2#state.host, State2#state.room,
			      make_opts(State2), make_affiliations(State2));
       true -> ok
    end,
    ?INFO_MSG("Created SUPPORT room ~s@~s by ~s",
	      [Room, Host, jid:to_string(Creator)]),
    add_to_log(room_existence, created, State2),
    add_to_log(room_existence, started, State2),
    {ok, normal_state, State2};
init([Host, ServerHost, Access, Room, HistorySize,
      PersistHistory, RoomShaper, Opts]) ->
    process_flag(trap_exit, true),
    mod_support:register_room(ServerHost, Host, Room, self()),
    Shaper = shaper:new(RoomShaper),
    State = set_opts(Opts,
		     #state{host = Host, server_host = ServerHost,
			    access = Access, room = Room,
			    history =
				load_history(ServerHost, Room, PersistHistory,
					     lqueue_new(HistorySize)),
			    persist_history = PersistHistory,
			    jid = jid:make(Room, Host, <<"">>),
			    room_shaper = Shaper}),
    add_to_log(room_existence, started, State),
    State1 = set_hibernate_timer_if_empty(State),
    {ok, normal_state, State1};
init([StateName,
      #state{room = Room, host = Host, server_host = ServerHost} = StateData]) ->
    process_flag(trap_exit, true),
    mod_support:register_room(ServerHost, Host, Room, self()),
    StateData1 = set_hibernate_timer_if_empty(StateData),
    {ok, StateName, StateData1}.

normal_state({route, From, <<"">>,
	      #xmlel{name = <<"message">>, attrs = Attrs,
		     children = Els} = MPacket},
	     StateData) ->
    PushInfo = fxml:get_subtag(#xmlel{children=Els}, <<"push_info">>),
    case {is_agent(From, StateData), fxml:get_attr_s(<<"type">>, Attrs), PushInfo} of
        {true, _, _} ->
            {next_state, normal_state, StateData};
        {_, <<"error">>, _} ->
            {next_state, normal_state, StateData};
        {_, _, #xmlel{}} ->
            US = {From#jid.luser, From#jid.lserver},
            case (?DICT):find(US, StateData#state.user_status) of
                {ok, Data} ->
                    Product = fxml:get_tag_attr_s(<<"product">>, PushInfo),
                    Push = fxml:get_tag_attr_s(<<"push">>, PushInfo),
                    Alias = fxml:get_tag_attr_s(<<"alias">>, PushInfo),
                    Data1 = Data#user{push_info = {Product, Push, Alias}},
                    UserStatus = (?DICT):store(US, Data1,
                                               StateData#state.user_status),

                    {next_state, normal_state, StateData#state{user_status=UserStatus}};
                _ ->
                    {next_state, normal_state, StateData}
            end;
        _ ->
            US = {From#jid.luser, From#jid.lserver},
            TS = p1_time_compat:timestamp(),
            add_history(US, From, MPacket, StateData),
            StateData1 =
                case (?DICT):find(US, StateData#state.user_status) of
                    {ok, Data} when Data#user.status /= offline andalso Data#user.status /= waiting ->
                        case Data#user.status of
                            {connecting, _AgentLJID} ->
                                StateData;
                            {talking, AgentLJID} ->
                                Packet =
                                    #xmlel{name = <<"message">>,
                                           attrs = [{<<"type">>, <<"chat">>}],
                                           children = Els},
                                route_stanza(
                                  make_chat_jid(US, StateData),
                                  jid:make(AgentLJID),
                                  Packet),
                                StateData
                        end;
                    Val ->
                        Data = case Val of
                                   error ->
                                       #user{jid = From,
                                             status = waiting,
                                             ts = TS};
                                   {ok, DataX} ->
                                       DataX#user{jid = From,
                                                  status = waiting,
                                                  ts = TS}
                               end,
                        UserStatus = (?DICT):store(US, Data,
                                                   StateData#state.user_status),
                        UserQueue = queue_insert(US, Data#user.ts, ok,
                                                 StateData#state.user_queue),
                        UQSize = treap_size(UserQueue) + treap_size(StateData#state.ringing_queue),
                        Packet =
                            #xmlel{name = <<"message">>,
                                   attrs = [{<<"type">>, <<"chat">>}],
                                   children =
                                   [#xmlel{name = <<"body">>,
                                           attrs = [],
                                           children = [{xmlcdata,
                                                        <<"You were placed in queue">>}
                                                      ]},
                                    #xmlel{name = <<"queue-info">>,
                                           attrs = [{<<"pos">>, jlib:integer_to_binary(UQSize)},
                                                    {<<"xmlns">>, ?NS_SUPPORT}],
                                           children = []}
                                   ]},
                        route_stanza(
                          StateData#state.jid,
                          From,
                          Packet),
                        SD1 = StateData#state{user_status = UserStatus,
                                              user_queue = UserQueue},
                        try_connect(SD1)
                end,
            {next_state, normal_state, StateData1}
    end;
normal_state({route, From, <<"">>,
	      #xmlel{name = <<"iq">>} = Packet},
	     StateData) ->
    case jlib:iq_query_info(Packet) of
      #iq{type = Type, xmlns = XMLNS, lang = Lang,
	  sub_el = #xmlel{name = SubElName} = SubEl} =
	  IQ
	  when (XMLNS == (?NS_SUPPORT_ADMIN)) or
		 (XMLNS == (?NS_SUPPORT_OWNER))
		 or (XMLNS == (?NS_DISCO_INFO))
		 or (XMLNS == (?NS_DISCO_ITEMS))
	         or (XMLNS == (?NS_VCARD))
		 or (XMLNS == (?NS_CAPTCHA)) ->
	  Res1 = case XMLNS of
		   ?NS_SUPPORT_ADMIN ->
		       process_iq_admin(From, Type, Lang, SubEl, StateData);
		   ?NS_SUPPORT_OWNER ->
		       process_iq_owner(From, Type, Lang, SubEl, StateData);
		   ?NS_DISCO_INFO ->
		       process_iq_disco_info(From, Type, Lang, StateData);
		   ?NS_DISCO_ITEMS ->
		       process_iq_disco_items(From, Type, Lang, StateData);
		   ?NS_VCARD ->
		       process_iq_vcard(From, Type, Lang, SubEl, StateData);
		   ?NS_CAPTCHA ->
		       process_iq_captcha(From, Type, Lang, SubEl, StateData)
		 end,
	  {IQRes, NewStateData} = case Res1 of
				    {result, Res, SD} ->
					{IQ#iq{type = result,
					       sub_el =
						   [#xmlel{name = SubElName,
							   attrs =
							       [{<<"xmlns">>,
								 XMLNS}],
							   children = Res}]},
					 SD};
				    {error, Error} ->
					{IQ#iq{type = error,
					       sub_el = [SubEl, Error]},
					 StateData}
				  end,
	  route_stanza(StateData#state.jid, From,
		       jlib:iq_to_xml(IQRes)),
	  case NewStateData of
	    stop -> {stop, normal, StateData};
	    _ -> {next_state, normal_state, NewStateData}
	  end;
      reply -> {next_state, normal_state, StateData};
      _ ->
	  Err = jlib:make_error_reply(Packet,
				      ?ERR_FEATURE_NOT_IMPLEMENTED),
	  route_stanza(StateData#state.jid, From, Err),
	  {next_state, normal_state, StateData}
    end;
normal_state({route, From, Nick,
	      #xmlel{name = <<"presence">>} = Packet},
	     StateData) ->
    process_presence(From, Nick, Packet, StateData);
normal_state({route, From, Resource,
	      #xmlel{name = <<"message">>, children = Els}},
	     StateData) ->
    case is_agent(From, StateData) of
        true ->
            UserJID = jid:from_string(Resource),
            case UserJID of
                error ->
                    {next_state, normal_state, StateData};
                #jid{} ->
                    US = {UserJID#jid.luser, UserJID#jid.lserver},
                    AgentLJID = jid:tolower(From),
                    StateData1 =
                        case (?DICT):find(US, StateData#state.user_status) of
                            {ok, UserData} ->
                                case UserData#user.status of
                                    offline ->
                                        handle_agent_message(
                                          US, UserData, AgentLJID, Els,
                                          StateData);
                                    waiting ->
                                        Text = <<"The user is in the waiting queue">>,
                                        Packet =
                                            #xmlel{name = <<"message">>,
                                                   attrs = [{<<"type">>, <<"chat">>}],
                                                   children =
                                                   [#xmlel{name = <<"body">>,
                                                           attrs = [],
                                                           children =
                                                           [{xmlcdata, Text}]}]},
                                        route_stanza(
                                          make_chat_jid(US, StateData),
                                          jid:make(AgentLJID),
                                          Packet),
                                        StateData;
                                    {connecting, AgentLJID} ->
                                        handle_agent_message(
                                          US, UserData, AgentLJID, Els,
                                          StateData);
                                    {talking, AgentLJID} ->
                                        handle_agent_message(
                                          US, UserData, AgentLJID, Els,
                                          StateData);
                                    {connecting, AgentLJID2} ->
                                        SText = io_lib:format(
                                                  "~s is assigned to the user",
                                                  [jid:to_string(
                                                     AgentLJID2)]),
                                        Text = iolist_to_binary(SText),
                                        Packet =
                                            #xmlel{name = <<"message">>,
                                                   attrs = [{<<"type">>, <<"chat">>}],
                                                   children =
                                                   [#xmlel{name = <<"body">>,
                                                           attrs = [],
                                                           children =
                                                           [{xmlcdata, Text}]}]},
                                        route_stanza(
                                          make_chat_jid(US, StateData),
                                          jid:make(AgentLJID),
                                          Packet),
                                        StateData;
                                    {talking, AgentLJID2} ->
                                        SText = io_lib:format(
                                                  "~s is handling the user",
                                                  [jid:to_string(
                                                     AgentLJID2)]),
                                        Text = iolist_to_binary(SText),
                                        Packet =
                                            #xmlel{name = <<"message">>,
                                                   attrs = [{<<"type">>, <<"chat">>}],
                                                   children =
                                                   [#xmlel{name = <<"body">>,
                                                           attrs = [],
                                                           children =
                                                           [{xmlcdata, Text}]}]},
                                        route_stanza(
                                          make_chat_jid(US, StateData),
                                          jid:make(AgentLJID),
                                          Packet),
                                        StateData
                                end;
                            error ->
                                %Text = <<"The user is not in the waiting queue">>,
                                %Packet =
                                %    #xmlel{name = <<"message">>,
                                %           attrs = [{<<"type">>, <<"chat">>}],
                                %           children =
                                %           [#xmlel{name = <<"body">>,
                                %                   attrs = [],
                                %                   children =
                                %                   [{xmlcdata, Text}]}]},
                                %route_stanza(
                                %  make_chat_jid(US, StateData),
                                %  jid:make(AgentLJID),
                                %  Packet),
                                %StateData
                                SD = direct_connect(US, AgentLJID, StateData),
                                case (?DICT):find(US, SD#state.user_status) of
                                    {ok, UserData} ->
                                        handle_agent_message(
                                          US, UserData, AgentLJID, Els,
                                          SD);
                                    error ->
                                        SD
                                end
                        end,
                    {next_state, normal_state, StateData1}
            end;
        false ->
            {next_state, normal_state, StateData}
    end;
normal_state({route, From, ToNick,
	      #xmlel{name = <<"iq">>, attrs = Attrs} = Packet},
	     StateData) ->
    Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
    StanzaId = fxml:get_attr_s(<<"id">>, Attrs),
    case {(StateData#state.config)#config.allow_query_users,
	  is_user_online_iq(StanzaId, From, StateData)}
	of
      {true, {true, NewId, FromFull}} ->
	  case find_jid_by_nick(ToNick, StateData) of
	    false ->
		case jlib:iq_query_info(Packet) of
		  reply -> ok;
		  _ ->
		      ErrText = <<"Recipient is not in the conference room">>,
		      Err = jlib:make_error_reply(Packet,
						  ?ERRT_ITEM_NOT_FOUND(Lang,
								       ErrText)),
		      route_stanza(jid:replace_resource(StateData#state.jid,
							     ToNick),
				   From, Err)
		end;
	    ToJID ->
		{ok, #user{nick = FromNick}} =
		    (?DICT):find(jid:tolower(FromFull),
				 StateData#state.users),
		{ToJID2, Packet2} = handle_iq_vcard(FromFull, ToJID,
						    StanzaId, NewId, Packet),
		route_stanza(jid:replace_resource(StateData#state.jid,
						       FromNick),
			     ToJID2, Packet2)
	  end;
      {_, {false, _, _}} ->
	  case jlib:iq_query_info(Packet) of
	    reply -> ok;
	    _ ->
		ErrText =
		    <<"Only occupants are allowed to send queries "
		      "to the conference">>,
		Err = jlib:make_error_reply(Packet,
					    ?ERRT_NOT_ACCEPTABLE(Lang,
								 ErrText)),
		route_stanza(jid:replace_resource(StateData#state.jid,
						       ToNick),
			     From, Err)
	  end;
      _ ->
	  case jlib:iq_query_info(Packet) of
	    reply -> ok;
	    _ ->
		ErrText = <<"Queries to the conference members are "
			    "not allowed in this room">>,
		Err = jlib:make_error_reply(Packet,
					    ?ERRT_NOT_ALLOWED(Lang, ErrText)),
		route_stanza(jid:replace_resource(StateData#state.jid,
						       ToNick),
			     From, Err)
	  end
    end,
    {next_state, normal_state, StateData};
normal_state(hibernate, #state{config = Config} = StateData) ->
    case ?DICT:size(StateData#state.users) of
	0 ->
	    StateData1 = StateData#state{shutdown_reason = hibernated},
	    if Config#config.persistent ->
		    TS = p1_time_compat:system_time(micro_seconds),
		    Config1 = Config#config{hibernate_time = TS},
		    StateData2 = StateData1#state{config = Config1},
		    mod_support:store_room(StateData2#state.server_host,
				       StateData2#state.host,
				       StateData2#state.room,
				       make_opts(StateData2),
				       make_affiliations(StateData2)),
		    {stop, normal, StateData2};
	       true ->
		    {stop, normal, StateData1}
	    end;
	_ ->
	    {next_state, normal_state, StateData}
    end;
normal_state(_Event, StateData) ->
    {next_state, normal_state, StateData}.

handle_event({service_message, Msg}, _StateName,
	     StateData) ->
    MessagePkt = #xmlel{name = <<"message">>,
			attrs = [{<<"type">>, <<"groupchat">>}],
			children =
			    [#xmlel{name = <<"body">>, attrs = [],
				    children = [{xmlcdata, Msg}]}]},
    send_multiple(
      StateData#state.jid,
      StateData#state.server_host,
      StateData#state.users,
      MessagePkt),
    NSD = add_message_to_history(<<"">>,
				 StateData#state.jid, MessagePkt, StateData),
    {next_state, normal_state, NSD};
handle_event({destroy, Reason}, _StateName,
	     StateData) ->
    {result, [], stop} = destroy_room(#xmlel{name =
						 <<"destroy">>,
					     attrs =
						 [{<<"xmlns">>, ?NS_SUPPORT_OWNER}],
					     children =
						 case Reason of
						   none -> [];
						   _Else ->
						       [#xmlel{name =
								   <<"reason">>,
							       attrs = [],
							       children =
								   [{xmlcdata,
								     Reason}]}]
						 end},
				      StateData),
    ?INFO_MSG("Destroyed SUPPORT room ~s with reason: ~p",
	      [jid:to_string(StateData#state.jid), Reason]),
    add_to_log(room_existence, destroyed, StateData),
    {stop, normal, StateData#state{shutdown_reason = destroyed}};
handle_event(destroy, StateName, StateData) ->
    ?INFO_MSG("Destroyed SUPPORT room ~s",
	      [jid:to_string(StateData#state.jid)]),
    handle_event({destroy, none}, StateName, StateData);
handle_event({set_affiliation, JID, Affiliation},
	     StateName, StateData) ->
    NewStateData = set_affiliation(JID, Affiliation, StateData),
    {next_state, StateName, NewStateData};
handle_event({set_affiliations, Affiliations},
	     StateName, StateData) ->
    NewStateData = set_affiliations(Affiliations, StateData),
    {next_state, StateName, NewStateData};
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event({moderate_room_history, Nick}, _From,
		  StateName, #state{history = History} = StateData) ->
    NewHistory = lqueue_filter(fun ({FromNick, _TSPacket,
				     _HaveSubject, _Timestamp, _Size}) ->
				       FromNick /= Nick
			       end,
			       History),
    Moderated = History#lqueue.len - NewHistory#lqueue.len,
    {reply,
     {ok, iolist_to_binary(integer_to_list(Moderated))},
     StateName, StateData#state{history = NewHistory}};
handle_sync_event(persist_recent_messages, _From,
		  StateName, StateData) ->
    {reply, persist_support_history(StateData), StateName,
     StateData};
handle_sync_event({get_disco_item, JID, Lang}, _From,
		  StateName, StateData) ->
    Reply = get_roomdesc_reply(JID, StateData,
			       get_roomdesc_tail(StateData, Lang)),
    {reply, Reply, StateName, StateData};
handle_sync_event(get_config, _From, StateName,
		  StateData) ->
    {reply, {ok, StateData#state.config}, StateName,
     StateData};
handle_sync_event(get_state, _From, StateName,
		  StateData) ->
    {reply, {ok, StateData}, StateName, StateData};
handle_sync_event({change_config, Config}, _From,
		  StateName, StateData) ->
    {result, [], NSD} = change_config(Config, StateData),
    {reply, {ok, NSD#state.config}, StateName, NSD};
handle_sync_event({change_state, NewStateData}, _From,
		  StateName, _StateData) ->
    {reply, {ok, NewStateData}, StateName, NewStateData};
handle_sync_event(_Event, _From, StateName,
		  StateData) ->
    Reply = ok, {reply, Reply, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

print_state(StateData) -> StateData.

handle_info({process_user_presence, From},
	    normal_state = _StateName, StateData) ->
    RoomQueueEmpty =
	queue:is_empty(StateData#state.room_queue),
    RoomQueue = queue:in({presence, From},
			 StateData#state.room_queue),
    StateData1 = StateData#state{room_queue = RoomQueue},
    if RoomQueueEmpty ->
	   StateData2 = prepare_room_queue(StateData1),
	   {next_state, normal_state, StateData2};
       true -> {next_state, normal_state, StateData1}
    end;
handle_info({process_user_message, From},
	    normal_state = _StateName, StateData) ->
    RoomQueueEmpty =
	queue:is_empty(StateData#state.room_queue),
    RoomQueue = queue:in({message, From},
			 StateData#state.room_queue),
    StateData1 = StateData#state{room_queue = RoomQueue},
    if RoomQueueEmpty ->
	   StateData2 = prepare_room_queue(StateData1),
	   {next_state, normal_state, StateData2};
       true -> {next_state, normal_state, StateData1}
    end;
handle_info(process_room_queue,
	    normal_state = StateName, StateData) ->
    case queue:out(StateData#state.room_queue) of
      {{value, {message, From}}, RoomQueue} ->
	  Activity = get_user_activity(From, StateData),
	  Packet = Activity#activity.message,
	  NewActivity = Activity#activity{message = undefined},
	  StateData1 = store_user_activity(From, NewActivity,
					   StateData),
	  StateData2 = StateData1#state{room_queue = RoomQueue},
	  StateData3 = prepare_room_queue(StateData2),
	  process_groupchat_message(From, Packet, StateData3);
      {{value, {presence, From}}, RoomQueue} ->
	  Activity = get_user_activity(From, StateData),
	  {Nick, Packet} = Activity#activity.presence,
	  NewActivity = Activity#activity{presence = undefined},
	  StateData1 = store_user_activity(From, NewActivity,
					   StateData),
	  StateData2 = StateData1#state{room_queue = RoomQueue},
	  StateData3 = prepare_room_queue(StateData2),
	  process_presence(From, Nick, Packet, StateData3);
      {empty, _} -> {next_state, StateName, StateData}
    end;
handle_info({captcha_succeed, From}, normal_state,
	    StateData) ->
    NewState = case (?DICT):find(From,
				 StateData#state.robots)
		   of
		 {ok, {Nick, Packet}} ->
		     Robots = (?DICT):store(From, passed,
					    StateData#state.robots),
		     add_new_user(From, Nick, Packet,
				  StateData#state{robots = Robots});
		 _ -> StateData
	       end,
    {next_state, normal_state, NewState};
handle_info({captcha_failed, From}, normal_state,
	    StateData) ->
    NewState = case (?DICT):find(From,
				 StateData#state.robots)
		   of
		 {ok, {Nick, Packet}} ->
		     Robots = (?DICT):erase(From, StateData#state.robots),
		     Err = jlib:make_error_reply(Packet,
						 ?ERR_NOT_AUTHORIZED),
		     route_stanza % TODO: s/Nick/""/
				 (jid:replace_resource(StateData#state.jid,
							    Nick),
				  From, Err),
		     StateData#state{robots = Robots};
		 _ -> StateData
	       end,
    {next_state, normal_state, NewState};
handle_info({timeout, Timer, {ring, AgentLJID, US}}, StateName,
	    StateData) ->
    case (?DICT):find(AgentLJID, StateData#state.agent_status) of
        {ok, Statuses} ->
            case {lists:keysearch(US, 2, Statuses),
                  treap:is_empty(StateData#state.available_agents) orelse
                  treap:is_empty(StateData#state.user_queue)} of
                {{value, {{connecting, Timer}, _}}, false} ->
                    Packet = #xmlel{name = <<"message">>,
                                    attrs = [{<<"type">>, <<"chat">>}],
                                    children =
                                    [#xmlel{name = <<"cancel">>,
                                            attrs = [{<<"xmlns">>, ?NS_SUPPORT}]
                                           },
                                     #xmlel{name= <<"body">>,
                                            attrs = [],
                                            children = [{xmlcdata, <<"Support session canceled">>}]
                                           }
                                    ]},
                    route_stanza(
                      make_chat_jid(US, StateData),
                      jid:make(AgentLJID),
                      Packet),
                    SD1 = change_agent_status(AgentLJID, waiting, US, StateData),
                    SD2 = update_agent_queue(AgentLJID, SD1),
                    SD3 = move_user_to_queue(US, SD2),
                    SD4 = try_connect(SD3),
                    {next_state, StateName, SD4};
                {{value, {{connecting, Timer}, _}}, true} ->
                    RingTimer = erlang:start_timer(?RING_TIMEOUT,
                                                   self(), {ring, AgentLJID, US}),
                    StateData2 = change_agent_status(AgentLJID,
                                                     {connecting, RingTimer}, US,
                                                     StateData),
                    {next_state, StateName, StateData2};
                _ ->
                    {next_state, StateName, StateData}
            end;
        _ ->
            {next_state, StateName, StateData}
    end;
handle_info({migrate, Node}, StateName, StateData) ->
    if Node /= node() ->
	   {migrate, StateData,
	    {Node, ?MODULE, start, [StateName, StateData]}, 0};
       true -> {next_state, StateName, StateData}
    end;
handle_info(system_shutdown, _StateName, StateData) ->
    {stop, normal, StateData#state{shutdown_reason = system_shutdown}};
handle_info(replaced, _StateName, StateData) ->
    {stop, normal, StateData#state{shutdown_reason = replaced}};
handle_info({route, From, ToNick, Packet}, normal_state, StateData) ->
    normal_state({route, From, ToNick, Packet}, StateData);
handle_info(_Info, StateName, StateData) ->
    {next_state, StateName, StateData}.

terminate({migrated, Clone}, _StateName, StateData) ->
    ?INFO_MSG("Migrating room ~s@~s to ~p on node ~p",
	      [StateData#state.room, StateData#state.host, Clone,
	       node(Clone)]),
    mod_support:unregister_room(StateData#state.server_host,
			    StateData#state.host,
                            StateData#state.room,
			    self()),
    ok;
terminate(_Reason, _StateName, StateData) ->
    Reason = StateData#state.shutdown_reason,
    ?INFO_MSG("Stopping SUPPORT room ~s@~s with reason: ~p",
	      [StateData#state.room, StateData#state.host, Reason]),
    ReasonT = case Reason of
		system_shutdown ->
		    <<"You are being removed from the room "
		      "because of a system shutdown">>;
                destroyed ->
                    <<"The room has been destroyed">>;
                replaced ->
                    <<"The room has been moved">>;
		hibernated ->
		    <<"The room has been hibernated">>;
		_ -> <<"Room terminates">>
	      end,
    ItemAttrs = [{<<"affiliation">>, <<"none">>},
		 {<<"role">>, <<"none">>}],
    ReasonEl = #xmlel{name = <<"reason">>, attrs = [],
		      children = [{xmlcdata, ReasonT}]},
    Packet = #xmlel{name = <<"presence">>,
		    attrs = [{<<"type">>, <<"unavailable">>}],
		    children =
			[#xmlel{name = <<"x">>,
				attrs = [{<<"xmlns">>, ?NS_SUPPORT_USER}],
				children =
				    [#xmlel{name = <<"item">>,
					    attrs = ItemAttrs,
					    children = [ReasonEl]},
				     #xmlel{name = <<"status">>,
					    attrs = [{<<"code">>, <<"332">>}],
					    children = []}]}]},
    (?DICT):fold(fun (LJID, Info, _) ->
			 Nick = Info#user.nick,
			 if Reason == system_shutdown;
                            Reason == destroyed;
			    Reason == hibernated;
                            Reason == replaced ->
			       route_stanza(jid:replace_resource(StateData#state.jid,
								      Nick),
					    Info#user.jid, Packet);
			   true -> ok
			 end,
			 tab_remove_online_user(LJID, StateData)
		 end,
		 [], StateData#state.users),
    add_to_log(room_existence, stopped, StateData),
    if Reason == system_shutdown; Reason == hibernated ->
	    persist_support_history(StateData);
       true -> ok
    end,
    mod_support:unregister_room(StateData#state.server_host,
			    StateData#state.host,
                            StateData#state.room,
			    self()),
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

load_history(_Host, _Room, false, Queue) -> Queue;
load_history(Host, Room, true, Queue) ->
    ?INFO_MSG("Loading history for room ~s on host ~s",
	      [Room, Host]),
    case sql_queries:load_roomhistory(Host, Room) of
      {selected, Items} ->
	  ?DEBUG("Found ~p messages on history for ~s",
		 [length(Items), Room]),
	  lists:foldl(fun (I, Q) ->
			      {Nick, XML, HS, Ts, Size} = I,
			      Item = {Nick, fxml_stream:parse_element(XML),
				      HS,
				      calendar:gregorian_seconds_to_datetime(Ts),
				      Size},
			      lqueue_in(Item, Q)
		      end,
		      Queue, Items);
      _ -> Queue
    end.

persist_support_history(#state{room = Room,
			   server_host = Server,
			   config = #config{persistent = true},
			   persist_history = true, history = Q}) ->
    ?INFO_MSG("Persisting history for room ~s on host ~s",
	      [Room, Server]),
    Queries = lists:map(fun ({FromNick, Packet, HaveSubject,
			      Timestamp, Size}) ->
				sql_queries:add_roomhistory_sql(
                                  Room,
                                  FromNick,
                                  fxml:element_to_binary(Packet),
                                  HaveSubject,
                                  calendar:datetime_to_gregorian_seconds(
                                    Timestamp),
                                  Size)
			end,
			lqueue_to_list(Q)),
    sql_queries:clear_and_add_roomhistory(Server, Room, Queries),
    {ok, {persisted, length(Queries)}};
%% en mod_support, cuando se levantan los support persistentes, si se crea, y el flag persist_history esta en true,
%% se levantan los mensajes persistentes tb.
persist_support_history(_) -> {ok, not_persistent}.

route(Pid, From, ToNick, Packet) ->
    ejabberd_cluster:send(Pid, {route, From, ToNick, Packet}).

process_groupchat_message(From,
			  #xmlel{name = <<"message">>, attrs = Attrs} = Packet,
			  StateData) ->
    Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
    case is_user_online(From, StateData) orelse
	   is_user_allowed_message_nonparticipant(From, StateData)
	of
      true ->
	  {FromNick, Role} = get_participant_data(From,
						  StateData),
	  if (Role == moderator) or (Role == participant) or
	       ((StateData#state.config)#config.moderated == false) ->
		 {NewStateData1, IsAllowed} = case check_subject(Packet)
						  of
						false -> {StateData, true};
						Subject ->
						    case
						      can_change_subject(Role,
									 StateData)
							of
						      true ->
							  NSD =
							      StateData#state{subject
										  =
										  Subject,
									      subject_author
										  =
										  FromNick},
							  case
							    (NSD#state.config)#config.persistent
							      of
							    true ->
								mod_support:store_room(NSD#state.server_host,
										   NSD#state.host,
										   NSD#state.room,
										   make_opts(NSD),
                                                                                   make_affiliations(NSD));
							    _ -> ok
							  end,
							  {NSD, true};
						      _ -> {StateData, false}
						    end
					      end,
		 case IsAllowed of
		   true ->
			   send_multiple(
			      jid:replace_resource(StateData#state.jid, FromNick),
			      StateData#state.server_host,
			      StateData#state.users,
			      Packet),
		       NewStateData2 = case has_body_or_subject(Packet) of
			   true ->
				add_message_to_history(FromNick, From,
							      Packet,
							      NewStateData1);
			   false ->
				NewStateData1
			 end,
		       {next_state, normal_state, NewStateData2};
		   _ ->
		       Err = case
			       (StateData#state.config)#config.allow_change_subj
				 of
			       true ->
				   ?ERRT_FORBIDDEN(Lang,
						   <<"Only moderators and participants are "
						     "allowed to change the subject in this "
						     "room">>);
			       _ ->
				   ?ERRT_FORBIDDEN(Lang,
						   <<"Only moderators are allowed to change "
						     "the subject in this room">>)
			     end,
		       route_stanza(StateData#state.jid, From,
				    jlib:make_error_reply(Packet, Err)),
		       {next_state, normal_state, StateData}
		 end;
	     true ->
		 ErrText = <<"Visitors are not allowed to send messages "
			     "to all occupants">>,
		 Err = jlib:make_error_reply(Packet,
					     ?ERRT_FORBIDDEN(Lang, ErrText)),
		 route_stanza(StateData#state.jid, From, Err),
		 {next_state, normal_state, StateData}
	  end;
      false ->
	  ErrText =
	      <<"Only occupants are allowed to send messages "
		"to the conference">>,
	  Err = jlib:make_error_reply(Packet,
				      ?ERRT_NOT_ACCEPTABLE(Lang, ErrText)),
	  route_stanza(StateData#state.jid, From, Err),
	  {next_state, normal_state, StateData}
    end.

is_user_allowed_message_nonparticipant(JID,
				       StateData) ->
    case get_service_affiliation(JID, StateData) of
      owner -> true;
      _ -> false
    end.

get_participant_data(From, StateData) ->
    case (?DICT):find(jid:tolower(From),
		      StateData#state.users)
	of
      {ok, #user{nick = FromNick, role = Role}} ->
	  {FromNick, Role};
      error -> {<<"">>, moderator}
    end.

process_presence(From, _Nick,
		 #xmlel{name = <<"presence">>, attrs = Attrs},
		 StateData) ->
    case is_agent(From, StateData) of
        true ->
            Type = fxml:get_attr_s(<<"type">>, Attrs),
            %Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
            StateData1 =
                if
                    Type == <<"unavailable">>;
                    Type == <<"error">> ->
                        LFrom = jid:tolower(From),
                            case (?DICT):find(LFrom, StateData#state.agent_status) of
                                {ok, Statuses} ->
                                    AgentStatus =
                                        (?DICT):erase(
                                          LFrom, StateData#state.agent_status),
                                    NewStateData =
                                        update_agent_queue(
                                          LFrom,
                                          StateData#state{
                                            agent_status = AgentStatus}),
                                    lists:foldl(
                                      fun({Status, US}, SD) ->
                                              case Status of
                                                  talking ->
                                                      Packet =
                                                          #xmlel{name = <<"message">>,
                                                                 attrs = [{<<"type">>, <<"chat">>}],
                                                                 children =
                                                                 [#xmlel{name = <<"body">>,
                                                                         attrs = [],
                                                                         children = [{xmlcdata,
                                                                                      <<"sorry, the support agent is not available anymore, you will be switched to another one shortly">>}
                                                                                    ]}
                                                                 ]},
                                                      {ok, UserData} =
                                                          (?DICT):find(US, StateData#state.user_status),
                                                      route_stanza(
                                                        StateData#state.jid,
                                                        UserData#user.jid,
                                                        Packet);
                                                  _ ->
                                                      ok
                                              end,
                                              SD1 = move_user_to_queue(US, SD),
                                              SD2 = try_connect(SD1),
                                              SD2
                                      end, NewStateData, Statuses);
                                error -> StateData
                            end;
                    Type == <<"">> ->
                        LFrom = jid:tolower(From),
                        case (?DICT):is_key(LFrom, StateData#state.agent_status) of
                            false ->
                                AgentStatus =
                                    (?DICT):store(
                                      LFrom, [],
                                      StateData#state.agent_status),
                                SD1 = update_agent_queue(
                                        LFrom,
                                        StateData#state{
                                          agent_status = AgentStatus}),
                                try_connect(SD1);
                            true -> StateData
                        end;
                    Type == <<"subscribe">> ->
                        Subscribed =
                            #xmlel{name = <<"presence">>,
                                   attrs = [{<<"type">>, <<"subscribed">>}],
                                   children = []},
                        route_stanza(
                          StateData#state.jid,
                          jid:remove_resource(From),
                          Subscribed),
                        Subscribe =
                            #xmlel{name = <<"presence">>,
                                   attrs = [{<<"type">>, <<"subscribe">>}],
                                   children = []},
                        route_stanza(
                          StateData#state.jid,
                          jid:remove_resource(From),
                          Subscribe),
                        StateData;
                    true -> StateData
                end,
            {next_state, normal_state, StateData1};
        false ->
            Type = fxml:get_attr_s(<<"type">>, Attrs),
            %Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
            US = {From#jid.luser, From#jid.lserver},
            Data1 = case (?DICT):find(US, StateData#state.user_status) of
                        {ok, Data} ->
                            Data;
                        _ ->
                            TS = p1_time_compat:timestamp(),
                            #user{jid = From,
                                  status = waiting,
                                  ts = TS}
                    end,
            NS =
                if
                    Type == <<"unavailable">>;
                    Type == <<"error">> ->
                        ?DEBUG("UNAV: ~p ~p", [Data1#user.status, Data1]),
                        case Data1#user.status of
                            {Mode, AgentLJID} when Mode == connecting orelse Mode == talking ->
                                Text = <<"User closed session">>,
                                Packet =
                                    #xmlel{name = <<"message">>,
                                           attrs = [{<<"type">>, <<"chat">>}],
                                           children =
                                               [#xmlel{name = <<"body">>,
                                                       attrs = [],
                                                       children =
                                                           [{xmlcdata, Text}]}]},
                                route_stanza(
                                  make_chat_jid(US, StateData),
                                  jid:make(AgentLJID),
                                  Packet),
                                SD1 = change_agent_status(AgentLJID, waiting, US, StateData),
                                SD2 = update_agent_queue(AgentLJID, SD1),
                                SD3 = case Mode of
                                          connecting ->
                                              SD2#state{ringing_queue = treap:delete(US,  SD2#state.ringing_queue)};
                                          _ ->
                                              SD2
                                      end,

                                Dict = (?DICT):store(
                                         US, Data1#user{is_available = false, status = offline},
                                         SD3#state.user_status),
                                SD3#state{user_status = Dict};
                            waiting ->
                                StateData;
                            _ ->
                                Dict = (?DICT):store(
                                         US, Data1#user{is_available = false, status = offline},
                                         StateData#state.user_status),
                                StateData#state{user_status = Dict}
                        end;
                    Type == <<"">> ->
                        Dict = (?DICT):store(
                                 US, Data1#user{is_available = true},
                                 StateData#state.user_status),
                        StateData#state{user_status = Dict};
                    true ->
                        StateData
                end,
            {next_state, normal_state, NS}
    end.

is_user_online(JID, StateData) ->
    LJID = jid:tolower(JID),
    (?DICT):is_key(LJID, StateData#state.users).

is_occupant_or_admin(JID, StateData) ->
    FAffiliation = get_affiliation(JID, StateData),
    FRole = get_role(JID, StateData),
    case FRole /= none orelse
	   FAffiliation == member orelse
	   FAffiliation == admin orelse FAffiliation == owner
	of
      true -> true;
      _ -> false
    end.

is_agent(JID, StateData) ->
    FAffiliation = get_affiliation(JID, StateData),
    case FAffiliation of
        member -> true;
        _ -> false
    end.

is_user_online_iq(StanzaId, JID, StateData)
    when JID#jid.lresource /= <<"">> ->
    {is_user_online(JID, StateData), StanzaId, JID};
is_user_online_iq(StanzaId, JID, StateData)
    when JID#jid.lresource == <<"">> ->
    try stanzaid_unpack(StanzaId) of
      {OriginalId, Resource} ->
	  JIDWithResource = jid:replace_resource(JID,
						      Resource),
	  {is_user_online(JIDWithResource, StateData), OriginalId,
	   JIDWithResource}
    catch
      _:_ -> {is_user_online(JID, StateData), StanzaId, JID}
    end.

handle_iq_vcard(FromFull, ToJID, StanzaId, NewId,
		Packet) ->
    ToBareJID = jid:remove_resource(ToJID),
    IQ = jlib:iq_query_info(Packet),
    handle_iq_vcard2(FromFull, ToJID, ToBareJID, StanzaId,
		     NewId, IQ, Packet).

handle_iq_vcard2(_FromFull, ToJID, ToBareJID, StanzaId,
		 _NewId, #iq{type = get, xmlns = ?NS_VCARD}, Packet)
    when ToBareJID /= ToJID ->
    {ToBareJID, change_stanzaid(StanzaId, ToJID, Packet)};
handle_iq_vcard2(_FromFull, ToJID, _ToBareJID,
		 _StanzaId, NewId, _IQ, Packet) ->
    {ToJID, change_stanzaid(NewId, Packet)}.

stanzaid_pack(OriginalId, Resource) ->
    <<"berd",
      (jlib:encode_base64(<<"ejab\000",
		       OriginalId/binary, "\000",
		       Resource/binary>>))/binary>>.

stanzaid_unpack(<<"berd", StanzaIdBase64/binary>>) ->
    StanzaId = jlib:decode_base64(StanzaIdBase64),
    [<<"ejab">>, OriginalId, Resource] =
	str:tokens(StanzaId, <<"\000">>),
    {OriginalId, Resource}.

change_stanzaid(NewId, Packet) ->
    #xmlel{name = Name, attrs = Attrs, children = Els} =
	jlib:remove_attr(<<"id">>, Packet),
    #xmlel{name = Name, attrs = [{<<"id">>, NewId} | Attrs],
	   children = Els}.

change_stanzaid(PreviousId, ToJID, Packet) ->
    NewId = stanzaid_pack(PreviousId, ToJID#jid.lresource),
    change_stanzaid(NewId, Packet).

%%%
%%%

role_to_list(Role) ->
    case Role of
      moderator -> <<"moderator">>;
      participant -> <<"participant">>;
      visitor -> <<"visitor">>;
      none -> <<"none">>
    end.

affiliation_to_list(Affiliation) ->
    case Affiliation of
      owner -> <<"owner">>;
      admin -> <<"admin">>;
      member -> <<"member">>;
      outcast -> <<"outcast">>;
      none -> <<"none">>
    end.

list_to_role(Role) ->
    case Role of
      <<"moderator">> -> moderator;
      <<"participant">> -> participant;
      <<"visitor">> -> visitor;
      <<"none">> -> none
    end.

list_to_affiliation(Affiliation) ->
    case Affiliation of
      <<"owner">> -> owner;
      <<"admin">> -> admin;
      <<"member">> -> member;
      <<"outcast">> -> outcast;
      <<"none">> -> none
    end.

set_affiliation(JID, Affiliation, StateData) ->
    set_affiliation(JID, Affiliation, StateData, <<"">>).

set_affiliation(JID, Affiliation, StateData, Reason) ->
    DBType = gen_mod:db_type(StateData#state.server_host, mod_support),
    set_affiliation(JID, Affiliation, StateData, Reason, DBType).

set_affiliation(JID, Affiliation,
                #state{config = #config{persistent = true}} = StateData,
                Reason, p1db) ->
    {LUser, LServer, _} = jid:tolower(JID),
    Room = StateData#state.room,
    Host = StateData#state.host,
    AffKey = mod_support:rhus2key(Room, Host, LUser, LServer),
    case Affiliation of
        none ->
            p1db:delete(support_affiliations, AffKey);
        _ ->
            Val = term_to_binary([{affiliation, Affiliation},
                                  {reason, Reason}]),
            p1db:insert(support_affiliations, AffKey, Val)
    end,
    StateData;
set_affiliation(JID, Affiliation, StateData, Reason, _) ->
    LJID = jid:remove_resource(jid:tolower(JID)),
    Affiliations = case Affiliation of
		     none ->
			 (?DICT):erase(LJID, StateData#state.affiliations);
		     _ ->
			 (?DICT):store(LJID, {Affiliation, Reason},
				       StateData#state.affiliations)
		   end,
    StateData#state{affiliations = Affiliations}.

set_affiliations(Affiliations, StateData) ->
    DBType = gen_mod:db_type(StateData#state.server_host, mod_support),
    set_affiliations(Affiliations, StateData, DBType).

set_affiliations(Affiliations,
                 #state{config = #config{persistent = true}} = StateData,
                 p1db) ->
    Room = StateData#state.room,
    Host = StateData#state.host,
    case clear_affiliations(StateData) of
        ok ->
            lists:foreach(
              fun({_JID, {none, _Reason}}) ->
                      ok;
                 ({JID, {Affiliation, Reason}}) ->
                      {LUser, LServer, _} = jid:tolower(JID),
                      AffKey = mod_support:rhus2key(Room, Host, LUser, LServer),
                      Val = term_to_binary([{affiliation, Affiliation},
                                            {reason, Reason}]),
                      p1db:insert(support_affiliations, AffKey, Val)
              end, (?DICT):to_list(Affiliations)),
            StateData;
        {error, _} ->
            StateData
    end;
set_affiliations(Affiliations, StateData, _DBType) ->
    StateData#state{affiliations = Affiliations}.

clear_affiliations(StateData) ->
    DBType = gen_mod:db_type(StateData#state.server_host, mod_support),
    clear_affiliations(StateData, DBType).

clear_affiliations(#state{config = #config{persistent = true}} = StateData,
                   p1db) ->
    Room = StateData#state.room,
    Host = StateData#state.host,
    RHPrefix = mod_support:rh_prefix(Room, Host),
    case p1db:get_by_prefix(support_affiliations, RHPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _, _}) ->
                      p1db:async_delete(support_affiliations, Key)
              end, L);
        {error, _} = Err ->
            Err
    end;
clear_affiliations(_StateData, _DBType) ->
    ok.

get_affiliation(JID, StateData) ->
    case get_service_affiliation(JID, StateData) of
        owner ->
            owner;
        none ->
            DBType = gen_mod:db_type(StateData#state.server_host, mod_support),
            case get_affiliation(JID, StateData, DBType) of
                {Affiliation, _Reason} -> Affiliation;
                Affiliation -> Affiliation
            end
    end.

get_affiliation(JID, #state{config = #config{persistent = true}} = StateData,
                p1db) ->
    Room = StateData#state.room,
    Host = StateData#state.host,
    LServer = JID#jid.lserver,
    LUser = JID#jid.luser,
    AffKey = mod_support:rhus2key(Room, Host, LUser, LServer),
    case p1db:get(support_affiliations, AffKey) of
        {ok, Val, _VClock} ->
            PropList = binary_to_term(Val),
            proplists:get_value(affiliation, PropList, none);
	{error, notfound} ->
	    ServAffKey = mod_support:rhus2key(Room, Host, <<>>, LServer),
	    case p1db:get(support_affiliations, ServAffKey) of
		{ok, Val, _VClock} ->
		    PropList = binary_to_term(Val),
		    proplists:get_value(affiliation, PropList, none);
		{error, _} ->
		    none
	    end;
        {error, _} ->
            none
    end;
get_affiliation(JID, StateData, _DBType) ->
    LJID = jid:tolower(JID),
    case (?DICT):find(LJID, StateData#state.affiliations) of
        {ok, Affiliation} -> Affiliation;
        _ ->
            LJID1 = jid:remove_resource(LJID),
            case (?DICT):find(LJID1, StateData#state.affiliations)
            of
                {ok, Affiliation} -> Affiliation;
                _ ->
                    LJID2 = setelement(1, LJID, <<"">>),
                    case (?DICT):find(LJID2,
                                      StateData#state.affiliations)
                    of
                        {ok, Affiliation} -> Affiliation;
                        _ ->
                            LJID3 = jid:remove_resource(LJID2),
                            case (?DICT):find(LJID3,
                                              StateData#state.affiliations)
                            of
                                {ok, Affiliation} -> Affiliation;
                                _ -> none
                            end
                    end
            end
    end.

get_affiliations(StateData) ->
    DBType = gen_mod:db_type(StateData#state.server_host, mod_support),
    get_affiliations(StateData, DBType).

get_affiliations(#state{config = #config{persistent = true}} = StateData,
                 p1db) ->
    Room = StateData#state.room,
    Host = StateData#state.host,
    RHPrefix = mod_support:rh_prefix(Room, Host),
    case p1db:get_by_prefix(support_affiliations, RHPrefix) of
        {ok, L} ->
            (?DICT):from_list(
              lists:map(
                fun({Key, Val, _VClock}) ->
                        PropList = binary_to_term(Val),
                        Reason = proplists:get_value(reason, PropList, <<>>),
                        Affiliation = proplists:get_value(
                                        affiliation, PropList, none),
                        {LUser, LServer} = mod_support:key2us(RHPrefix, Key),
                        {{LUser, LServer, <<"">>}, {Affiliation, Reason}}
                end, L));
        {error, _} ->
            StateData#state.affiliations
    end;
get_affiliations(StateData, _DBType) ->
    StateData#state.affiliations.

get_service_affiliation(JID, StateData) ->
    {_AccessRoute, _AccessCreate, AccessAdmin,
     _AccessPersistent} =
	StateData#state.access,
    case acl:match_rule(StateData#state.server_host,
			AccessAdmin, JID)
	of
      allow -> owner;
      _ -> none
    end.

set_role(JID, Role, StateData) ->
    LJID = jid:tolower(JID),
    LJIDs = case LJID of
	      {U, S, <<"">>} ->
		  (?DICT):fold(fun (J, _, Js) ->
				       case J of
					 {U, S, _} -> [J | Js];
					 _ -> Js
				       end
			       end,
			       [], StateData#state.users);
	      _ ->
		  case (?DICT):is_key(LJID, StateData#state.users) of
		    true -> [LJID];
		    _ -> []
		  end
	    end,
    {Users, Nicks} = case Role of
		       none ->
			   lists:foldl(fun (J, {Us, Ns}) ->
					       NewNs = case (?DICT):find(J, Us)
							   of
							 {ok,
							  #user{nick = Nick}} ->
							     (?DICT):erase(Nick,
									   Ns);
							 _ -> Ns
						       end,
					       {(?DICT):erase(J, Us), NewNs}
				       end,
				       {StateData#state.users,
					StateData#state.nicks},
				       LJIDs);
		       _ ->
			   {lists:foldl(fun (J, Us) ->
						{ok, User} = (?DICT):find(J,
									  Us),
						(?DICT):store(J,
							      User#user{role =
									    Role},
							      Us)
					end,
					StateData#state.users, LJIDs),
			    StateData#state.nicks}
		     end,
    set_hibernate_timer_if_empty(
      StateData#state{users = Users, nicks = Nicks}).

get_role(JID, StateData) ->
    LJID = jid:tolower(JID),
    case (?DICT):find(LJID, StateData#state.users) of
      {ok, #user{role = Role}} -> Role;
      _ -> none
    end.

get_default_role(Affiliation, StateData) ->
    case Affiliation of
      owner -> moderator;
      admin -> moderator;
      member -> participant;
      outcast -> none;
      none ->
	  case (StateData#state.config)#config.members_only of
	    true -> none;
	    _ ->
		case (StateData#state.config)#config.members_by_default
		    of
		  true -> participant;
		  _ -> visitor
		end
	  end
    end.

get_max_users(StateData) ->
    MaxUsers = (StateData#state.config)#config.max_users,
    ServiceMaxUsers = get_service_max_users(StateData),
    if MaxUsers =< ServiceMaxUsers -> MaxUsers;
       true -> ServiceMaxUsers
    end.

get_service_max_users(StateData) ->
    gen_mod:get_module_opt(StateData#state.server_host,
			   mod_support, max_users,
                           fun(I) when is_integer(I), I>0 -> I end,
                           ?MAX_USERS_DEFAULT).

get_max_users_admin_threshold(StateData) ->
    gen_mod:get_module_opt(StateData#state.server_host,
			   mod_support, max_users_admin_threshold,
                           fun(I) when is_integer(I), I>0 -> I end,
                           5).

get_user_activity(JID, StateData) ->
    case treap:lookup(jid:tolower(JID),
		      StateData#state.activity)
	of
      {ok, _P, A} -> A;
      error ->
	  MessageShaper =
	      shaper:new(gen_mod:get_module_opt(StateData#state.server_host,
						mod_support, user_message_shaper,
                                                fun(A) when is_atom(A) -> A end,
						none)),
	  PresenceShaper =
	      shaper:new(gen_mod:get_module_opt(StateData#state.server_host,
						mod_support, user_presence_shaper,
                                                fun(A) when is_atom(A) -> A end,
						none)),
	  #activity{message_shaper = MessageShaper,
		    presence_shaper = PresenceShaper}
    end.

store_user_activity(JID, UserActivity, StateData) ->
    MinMessageInterval =
	gen_mod:get_module_opt(StateData#state.server_host,
			       mod_support, min_message_interval,
                               fun(I) when is_integer(I), I>=0 -> I end,
                               0),
    MinPresenceInterval =
	gen_mod:get_module_opt(StateData#state.server_host,
			       mod_support, min_presence_interval,
                               fun(I) when is_integer(I), I>=0 -> I end,
                               0),
    Key = jid:tolower(JID),
    Now = p1_time_compat:system_time(micro_seconds),
    Activity1 = clean_treap(StateData#state.activity,
			    {1, -Now}),
    Activity = case treap:lookup(Key, Activity1) of
		 {ok, _P, _A} -> treap:delete(Key, Activity1);
		 error -> Activity1
	       end,
    StateData1 = case MinMessageInterval == 0 andalso
			MinPresenceInterval == 0 andalso
			  UserActivity#activity.message_shaper == none andalso
			    UserActivity#activity.presence_shaper == none
			      andalso
			      UserActivity#activity.message == undefined andalso
				UserActivity#activity.presence == undefined
		     of
		   true -> StateData#state{activity = Activity};
		   false ->
		       case UserActivity#activity.message == undefined andalso
			      UserActivity#activity.presence == undefined
			   of
			 true ->
			     {_, MessageShaperInterval} =
				 shaper:update(UserActivity#activity.message_shaper,
					       100000),
			     {_, PresenceShaperInterval} =
				 shaper:update(UserActivity#activity.presence_shaper,
					       100000),
			     Delay = lists:max([MessageShaperInterval,
						PresenceShaperInterval,
						MinMessageInterval * 1000,
						MinPresenceInterval * 1000])
				       * 1000,
			     Priority = {1, -(Now + Delay)},
			     StateData#state{activity =
						 treap:insert(Key, Priority,
							      UserActivity,
							      Activity)};
			 false ->
			     Priority = {0, 0},
			     StateData#state{activity =
						 treap:insert(Key, Priority,
							      UserActivity,
							      Activity)}
		       end
		 end,
    StateData1.

clean_treap(Treap, CleanPriority) ->
    case treap:is_empty(Treap) of
      true -> Treap;
      false ->
	  {_Key, Priority, _Value} = treap:get_root(Treap),
	  if Priority > CleanPriority ->
		 clean_treap(treap:delete_root(Treap), CleanPriority);
	     true -> Treap
	  end
    end.

prepare_room_queue(StateData) ->
    case queue:out(StateData#state.room_queue) of
      {{value, {message, From}}, _RoomQueue} ->
	  Activity = get_user_activity(From, StateData),
	  Packet = Activity#activity.message,
	  Size = element_size(Packet),
	  {RoomShaper, RoomShaperInterval} =
	      shaper:update(StateData#state.room_shaper, Size),
	  erlang:send_after(RoomShaperInterval, self(),
			    process_room_queue),
	  StateData#state{room_shaper = RoomShaper};
      {{value, {presence, From}}, _RoomQueue} ->
	  Activity = get_user_activity(From, StateData),
	  {_Nick, Packet} = Activity#activity.presence,
	  Size = element_size(Packet),
	  {RoomShaper, RoomShaperInterval} =
	      shaper:update(StateData#state.room_shaper, Size),
	  erlang:send_after(RoomShaperInterval, self(),
			    process_room_queue),
	  StateData#state{room_shaper = RoomShaper};
      {empty, _} -> StateData
    end.

add_online_user(JID, Nick, Role, StateData) ->
    LJID = jid:tolower(JID),
    Users = (?DICT):store(LJID,
			  #user{jid = JID, nick = Nick, role = Role},
			  StateData#state.users),
    add_to_log(join, Nick, StateData),
    Nicks = (?DICT):update(Nick,
			   fun (Entry) ->
				   case lists:member(LJID, Entry) of
				     true -> Entry;
				     false -> [LJID | Entry]
				   end
			   end,
			   [LJID], StateData#state.nicks),
    tab_add_online_user(JID, StateData),
    ?GEN_FSM:cancel_timer(StateData#state.hibernate_timer),
    StateData#state{users = Users, nicks = Nicks}.

make_chat_jid(US, StateData) ->
    {U, S} = US,
    Resource = <<U/binary, "@", S/binary>>,
    jid:replace_resource(StateData#state.jid, Resource).

change_user_status(US, Status, StateData) ->
    case (?DICT):find(US, StateData#state.user_status) of
        {ok, Data} ->
            Data1 = Data#user{status = Status},
            UserStatus = (?DICT):store(US, Data1,
                                       StateData#state.user_status),
            StateData#state{user_status = UserStatus};
        error ->
            ?ERROR_MSG("Internal error: ~p not found~n", [US]),
            StateData
    end.

change_agent_status(AgentLJID, Status, US, StateData) ->
    case (?DICT):find(AgentLJID, StateData#state.agent_status) of
        {ok, Statuses} ->
            Statuses1 = lists:keydelete(US, 2, Statuses),
            Statuses2 =
                case Status of
                    waiting ->
                        Statuses1;
                    _ ->
                        [{Status, US} | Statuses1]
                end,
            AgentStatus = (?DICT):store(AgentLJID, Statuses2,
                                        StateData#state.agent_status),
            StateData#state{agent_status = AgentStatus};
        error ->
            ?ERROR_MSG("Internal error: ~p not found~n", [AgentLJID]),
            StateData
    end.

update_agent_queue(AgentLJID, StateData) ->
    case (?DICT):find(AgentLJID, StateData#state.agent_status) of
        {ok, Statuses} ->
            Len = length(Statuses),
            AvailableAgents =
                queue_insert(
                  AgentLJID, {Len, p1_time_compat:timestamp()}, ok,
                  StateData#state.available_agents),
            StateData#state{available_agents = AvailableAgents};
        error ->
            AvailableAgents =
                treap:delete(
                  AgentLJID, StateData#state.available_agents),
            StateData#state{available_agents = AvailableAgents}
    end.


move_user_to_queue(US, StateData) ->
    case (?DICT):find(US, StateData#state.user_status) of
        {ok, #user{status = waiting}} ->
            StateData;
        {ok, Data} ->
            Data1 = Data#user{status = waiting},
            UserStatus = (?DICT):store(US, Data1,
                                       StateData#state.user_status),
            UserQueue = queue_insert(US, Data#user.ts, ok,
                                     StateData#state.user_queue),
            RingingQueue = treap:delete(US,  StateData#state.ringing_queue),
            StateData#state{user_status = UserStatus,
                            user_queue = UserQueue,
                            ringing_queue = RingingQueue};
        error ->
            ?ERROR_MSG("Internal error: ~p not found~n", [US]),
            StateData
    end.

try_connect(StateData) ->
io:format("asd ~p~n", [{StateData#state.available_agents, StateData#state.user_queue}]),
    case treap:is_empty(StateData#state.available_agents) orelse
        treap:is_empty(StateData#state.user_queue) of
        true ->
            StateData;
        false ->
            {US, _, _} = treap:get_root(StateData#state.user_queue),
            UserQueue = treap:delete_root(StateData#state.user_queue),
            {AgentLJID, _, _} =
                treap:get_root(StateData#state.available_agents),
            AvailableAgents =
                treap:delete_root(StateData#state.available_agents),
            RingingQueue = case (?DICT):find(US, StateData#state.user_status) of
                               {ok, Data} ->
                                   History =
                                       get_history(
                                         US, Data#user.ts,
                                         StateData),
                                   send_history(
                                     US, AgentLJID, History,
                                     StateData),
                                   queue_insert(US, Data#user.ts, ok,
                                                StateData#state.ringing_queue);
                               error ->
                                   StateData#state.ringing_queue
                           end,
            StateData0 = StateData#state{user_queue = UserQueue,
                                         available_agents = AvailableAgents,
                                         ringing_queue = RingingQueue},
            StateData1 = change_user_status(US, {connecting, AgentLJID},
                                            StateData0),
            RingTimer = erlang:start_timer(?RING_TIMEOUT,
                                           self(), {ring, AgentLJID, US}),
            StateData2 = change_agent_status(AgentLJID,
                                             {connecting, RingTimer}, US,
                                             StateData1),
            StateData3 = update_agent_queue(AgentLJID, StateData2),
            Packet = #xmlel{name = <<"message">>,
                            attrs = [{<<"type">>, <<"chat">>}],
                            children =
                            [#xmlel{name = <<"ring">>,
                                    attrs = [{<<"xmlns">>, ?NS_SUPPORT}]
                                   },
                             #xmlel{name= <<"body">>,
                                    attrs = [],
                                    children = [{xmlcdata, <<"New support session">>}]
                                   }]},
            route_stanza(
              make_chat_jid(US, StateData3),
              jid:make(AgentLJID),
              Packet),
            try_connect(StateData3)
    end.

direct_connect(US, AgentLJID, StateData) ->
    StateData1 =
        case (?DICT):find(US, StateData#state.user_status) of
            {ok, Data} ->
                case Data#user.status of
                    waiting ->
                        Data1 = Data#user{status = {talking, AgentLJID}},
                        UserStatus = (?DICT):store(US, Data1,
                                                   StateData#state.user_status),
                        UserQueue =
                            treap:delete(
                              US, StateData#state.user_queue),
                        StateData#state{user_status = UserStatus,
                                        user_queue = UserQueue};
                    {connecting, _AgentLJID} ->
                        false;
                    {talking, AgentLJID} ->
                        false
                end;
            error ->
                {LUser, LServer} = US,
                UserJID = jid:make(LUser, LServer, <<"">>),
                TS = p1_time_compat:timestamp(),
                Data = #user{jid = UserJID,
                             status = {talking, AgentLJID},
                             ts = TS},
                UserStatus = (?DICT):store(US, Data,
                                           StateData#state.user_status),
                StateData#state{user_status = UserStatus}
        end,
    case StateData1 of
        false ->
            StateData;
        _ ->
            StateData2 =
                case (?DICT):find(AgentLJID,
                                  StateData1#state.agent_status) of
                    {ok, Statuses} ->
                        case lists:keysearch(US, 2, Statuses) of
                            {value, {{connecting, _Timer}, _}} ->
                                false;
                            {value, {talking, _}} ->
                                false;
                            false ->
                                SD = change_agent_status(AgentLJID,
                                                         talking, US,
                                                         StateData1),
                                update_agent_queue(AgentLJID, SD)
                        end;
                    error ->
                        false
                end,
            case StateData2 of
                false ->
                    StateData;
                _ ->
                    StateData2
            end
    end.

get_agent_nick_and_avatar(AgentLJID) ->
    IQ = mod_vcard:process_sm_iq(<<"">>, jid:make(AgentLJID), #iq{type=get}),
    {N,A} = case IQ#iq.sub_el of
                [#xmlel{name = <<"vCard">>}=El|_] ->
                    {fxml:get_path_s(El, [{elem, <<"NICKNAME">>}, cdata]),
                     binary:replace(fxml:get_path_s(El, [{elem, <<"PHOTO">>}, {elem, <<"BINVAL">>}, cdata]),
                                    [<<" ">>, <<"\n">>], <<"">>, [global])};
                _ ->
                    {<<"">>, <<"">>}
            end,
    case N of
        <<"">> ->
            {AgentId, _, _} = AgentLJID,
            {AgentId, A};
        _ ->
            {N, A}
    end.

send_to_user(AgentLJID, US, Els, StateData, First) ->
    case (?DICT):find(US, StateData#state.user_status) of
        {ok, Data} ->
            JID = Data#user.jid,
            {Nick, Avatar} = get_agent_nick_and_avatar(AgentLJID),
            Attrs = case First of
                        true ->
                            [{<<"name">>, Nick}, {<<"avatar">>, Avatar}];
                        _ ->
                            [{<<"name">>, Nick}]
                    end,
            Packet = #xmlel{name = <<"message">>,
                            attrs = [{<<"type">>, <<"chat">>}],
                            children = [#xmlel{name = <<"agent">>,
                                               attrs = Attrs} | Els]},
            add_history(US, jid:make(AgentLJID), Packet, StateData),
            route_stanza(
              StateData#state.jid,
              JID,
              Packet);
        error ->
            ok
    end.


handle_agent_message(US, UserData, AgentLJID, Els, StateData) ->
    case (?DICT):find(AgentLJID,
                      StateData#state.agent_status) of
        {ok, Statuses} ->
            ?DEBUG("HAM: ~p ~p", [lists:keysearch(US, 2, Statuses), UserData]),
            case lists:keysearch(US, 2, Statuses) of
                {value, {{connecting, _Timer}, _}} ->
                    case get_el_xmlns(Els) of
                        {#xmlel{name = <<"accept">>},
                         ?NS_SUPPORT} ->
                            handle_accept_event(StateData, UserData, AgentLJID, US);
                        _ ->
                            case check_for_push_message(US, UserData, AgentLJID, Els, StateData) of
                                {StD1, false} ->
                                    StD2 = handle_accept_event(StD1, UserData, AgentLJID, US),
                                    send_to_user(AgentLJID, US,
                                                 Els, StD2, true),
                                    StD2;
                                {StD3, true} ->
                                    StD3
                            end
                    end;
                {value, {talking, _}} ->
                    case get_el_xmlns(Els) of
                        {#xmlel{name = <<"done">>},
                         ?NS_SUPPORT} ->
                            handle_done_event(StateData, UserData, AgentLJID, US);
                        {#xmlel{name = <<"get-history">>} = XEl,
                         ?NS_SUPPORT} ->
                            Since =
                                case jlib:datetime_string_to_timestamp(
                                       fxml:get_tag_attr_s(<<"since">>, XEl)) of
                                    undefined -> {0, 0, 0};
                                    TS -> TS
                                end,
                            History =
                                get_history(
                                  US, Since, StateData),
                            send_history(US, AgentLJID, History,
                                         StateData),
                            StateData;
                        _ ->
                            case fxml:get_path_s(#xmlel{children=Els}, [{elem, <<"body">>}, cdata]) of
                                <<":done">> ->
                                    handle_done_event(StateData, UserData, AgentLJID, US);
                                _ ->
                                    send_to_user(AgentLJID, US,
                                                 Els, StateData, false),
                                    StateData
                            end
                    end;
                false ->
                    case check_for_push_message(US, UserData, AgentLJID, Els, StateData) of
                        {SD1, _} ->
                            SD1
                    end;
                _ ->
                    ?ERROR_MSG("Internal error: ~p not consistent~n", [{US, AgentLJID}])
            end;
        error -> StateData
    end.

check_for_push_message(US, UserData, AgentLJID, Els, StateData) ->
    case {fxml:get_path_s(#xmlel{children=Els}, [{elem, <<"body">>}, cdata]), UserData#user.is_available, UserData#user.push_info /= unavailable} of
        {<<":push ",_Tail/binary>>, _, false} ->
            Text = <<"This user don't have push information stored">>,
            Packet =
                #xmlel{name = <<"message">>,
                       attrs = [{<<"type">>, <<"chat">>}],
                       children =
                           [#xmlel{name = <<"body">>,
                                   attrs = [],
                                   children =
                                       [{xmlcdata, Text}]}]},
            route_stanza(
              make_chat_jid(US, StateData),
              jid:make(AgentLJID),
              Packet),
            {StateData, true};
        {<<":push ",Tail/binary>>, Avail, true} ->
            case Avail of
                true ->
                    Text = <<"User is currently available, not sending push">>,
                    Packet =
                        #xmlel{name = <<"message">>,
                               attrs = [{<<"type">>, <<"chat">>}],
                               children =
                                   [#xmlel{name = <<"body">>,
                                           attrs = [],
                                           children =
                                               [{xmlcdata, Text}]}]},
                    route_stanza(
                      make_chat_jid(US, StateData),
                      jid:make(AgentLJID),
                      Packet);
                false ->
                    Text = send_push(US, UserData, AgentLJID, Tail),
                    Packet =
                        #xmlel{name = <<"message">>,
                               attrs = [{<<"type">>, <<"chat">>}],
                               children =
                                   [#xmlel{name = <<"body">>,
                                           attrs = [],
                                           children =
                                               [{xmlcdata, Text}]}]},
                    route_stanza(
                      make_chat_jid(US, StateData),
                      jid:make(AgentLJID),
                      Packet)
            end,
            {StateData, true};
        {<<"">>, _, _} ->
            {StateData, true};
        {_, false, false} ->
            Text = <<"User is not currently available">>,
            Packet =
                #xmlel{name = <<"message">>,
                       attrs = [{<<"type">>, <<"chat">>}],
                       children =
                           [#xmlel{name = <<"body">>,
                                   attrs = [],
                                   children =
                                       [{xmlcdata, Text}]}]},
            route_stanza(
              make_chat_jid(US, StateData),
              jid:make(AgentLJID),
              Packet),
            {StateData, true};
        {_, false, true} ->
            ?DEBUG("Unavilable user ~p", [[AgentLJID, UserData]]),
            Text = <<"User is not currently available, to send push message send ':push <message>'">>,
            Packet =
                #xmlel{name = <<"message">>,
                       attrs = [{<<"type">>, <<"chat">>}],
                       children =
                           [#xmlel{name = <<"body">>,
                                   attrs = [],
                                   children =
                                       [{xmlcdata, Text}]}]},
            route_stanza(
              make_chat_jid(US, StateData),
              jid:make(AgentLJID),
              Packet),
            {StateData, true};
        _ ->
            {StateData, false}
    end.

update_queue_pos_after_user_removal(US, StateData) ->
    Fun = fun({US1, _, _}, {Pos, _}) when US1 == US ->
                  {Pos, true};
             ({US2, _, _}, {Pos, true}) ->
                  send_system_msg_to_user(US2,
                                          [#xmlel{name = <<"queue-info">>,
                                                  attrs = [{<<"pos">>, jlib:integer_to_binary(Pos)},
                                                           {<<"xmlns">>, ?NS_SUPPORT}],
                                                  children = []}
                                          ], StateData),
                  {Pos+1, true};
             (_, {Pos, false}) ->
                  {Pos+1, false}
          end,
    V = treap:fold(Fun, {1, false}, StateData#state.ringing_queue),
    treap:fold(Fun, V, StateData#state.user_queue).

handle_accept_event(StateData, _UserData, AgentLJID, US) ->
    SD1 = change_agent_status(
            AgentLJID,
            talking, US,
            StateData),
    SD2 = change_user_status(
            US,
            {talking, AgentLJID},
            SD1),
    update_queue_pos_after_user_removal(US, SD2),
    SD3 = SD2#state{ringing_queue = treap:delete(US, SD2#state.ringing_queue)},
%    History =
%        get_history(
%          US, UserData#user.ts,
%          StateData),
%    send_history(
%      US, AgentLJID, History,
%      StateData),
    SD3.

handle_done_event(StateData, UserData, AgentLJID, US) ->
    Packet =
        #xmlel{name = <<"message">>,
               attrs = [{<<"type">>, <<"chat">>}],
               children =
                   [#xmlel{name = <<"body">>,
                           attrs = [],
                           children = [{xmlcdata,
                                        <<"[the conversation has been closed]">>}
                                      ]},
                    #xmlel{name = <<"done">>,
                           attrs = [{<<"xmlns">>, ?NS_SUPPORT}],
                           children = []}
                   ]},
    route_stanza(
      StateData#state.jid,
      UserData#user.jid,
      Packet),
    SD1 = change_agent_status(
            AgentLJID,
            waiting, US,
            StateData),
    SD2 = update_agent_queue(AgentLJID, SD1),
    UserStatus = (?DICT):store(US, UserData#user{status = offline, is_available = false},
                               StateData#state.user_status),
    SD3 = SD2#state{user_status =
                        UserStatus},
    try_connect(SD3).

send_system_msg_to_user(US, Els, StateData) ->
    case (?DICT):find(US, StateData#state.user_status) of
        {ok, Data} ->
            JID = Data#user.jid,
            Packet = #xmlel{name = <<"message">>,
                            attrs = [{<<"type">>, <<"chat">>}],
                            children = Els},
            route_stanza(
              StateData#state.jid,
              JID,
              Packet);
        error ->
            ok
    end.

shell_quote(L) ->
    shell_quote(L, [$\"]).

cmd(Argv) ->
    os:cmd(cmd_string(Argv)).

cmd_string(Argv) ->
    string:join([shell_quote(X) || X <- Argv], " ").

shell_quote([], Acc) ->
    lists:reverse([$\" | Acc]);
shell_quote([C | Rest], Acc) when C =:= $\" orelse C =:= $\` orelse
                                  C =:= $\\ orelse C =:= $\$ ->
    shell_quote(Rest, [C, $\\ | Acc]);
shell_quote([C | Rest], Acc) ->
    shell_quote(Rest, [C | Acc]).

send_push(_US, UserData, _AgentLJID, Message) ->
    case UserData#user.push_info of
        {Product, Push, Alias} ->
            cmd(["boxcar_chat_support.py", binary_to_list(Product),
                 binary_to_list(Push), binary_to_list(Alias),
                 binary_to_list(Message)]),
            <<"Push sent">>;
        _ ->
            <<"Client don't have push enabled">>
    end.

queue_insert(US, {MSecs, Secs, MicroSecs}, Data,
             Queue) ->
    Priority = {-MSecs, -Secs, -MicroSecs},
    treap:insert(US, Priority, Data, Queue);
queue_insert(US, {Len, {MSecs, Secs, MicroSecs}}, Data,
             Queue) ->
    Priority = {-Len, {-MSecs, -Secs, -MicroSecs}},
    treap:insert(US, Priority, Data, Queue).


add_history(US, From, Packet, StateData) ->
    Body = fxml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),
    case Body of
        <<"">> ->
            ok;
        _ ->
            TS = p1_time_compat:system_time(micro_seconds),
            mod_support:add_history(
              StateData#state.server_host,
              StateData#state.room,
              StateData#state.host,
              US, TS, From, Body)
    end.

get_history(US, Since, StateData) ->
    SinceTS = now2ts(Since),
    History =
        mod_support:get_history(
          StateData#state.server_host,
          StateData#state.room,
          StateData#state.host,
          US),
    lists:filtermap(
      fun({TS, Sender, Body}) ->
              if
                  TS >= SinceTS ->
                      {true, {ts2now(TS), Sender, Body}};
                  true ->
                      false
              end
      end, History).

send_history(US, AgentLJID, History, StateData) ->
    lists:foreach(
      fun({Now, Sender, Body}) ->
              SSender = jid:to_string(Sender),
              Text = <<"<", SSender/binary, "> ", Body/binary>>,
              {T_string, Tz_string} = jlib:timestamp_to_iso(calendar:now_to_universal_time(Now), utc),
              Delay = #xmlel{name = <<"delay">>, attrs = [{<<"xmlns">>, ?NS_DELAY},
                                                          {<<"from">>, SSender},
                                                          {<<"stamp">>, <<T_string/binary, Tz_string/binary>>}],
                             children = [{xmlcdata, <<"Offline Storage">>}]},
              Packet =
                  #xmlel{name = <<"message">>,
                         attrs = [{<<"type">>, <<"chat">>}],
                         children =
                         [#xmlel{name = <<"body">>, attrs = [],
                                 children = [{xmlcdata, Text}]},
                          Delay]},
              route_stanza(
                make_chat_jid(US, StateData),
                jid:make(AgentLJID),
                Packet)
      end, History).

ts2now(TimeStamp) ->
    MSecs = TimeStamp div 1000000,
    USecs = TimeStamp rem 1000000,
    MegaSecs = MSecs div 1000000,
    Secs = MSecs rem 1000000,
    {MegaSecs, Secs, USecs}.

now2ts({MegaSecs, Secs, USecs}) ->
    (MegaSecs*1000000 + Secs)*1000000 + USecs.


get_el_xmlns(Els) ->
    case fxml:remove_cdata(Els) of
        [XEl] ->
            {XEl, fxml:get_tag_attr_s(<<"xmlns">>, XEl)};
        _ -> false
    end.


filter_presence(#xmlel{name = <<"presence">>,
		       attrs = Attrs, children = Els}) ->
    FEls = lists:filter(fun (El) ->
				case El of
				  {xmlcdata, _} -> false;
				  #xmlel{attrs = Attrs1} ->
                                        XMLNS = fxml:get_attr_s(<<"xmlns">>,
                                                               Attrs1),
                                        NS_SUPPORT = ?NS_SUPPORT,
                                        Size = byte_size(NS_SUPPORT),
                                        case XMLNS of
                                            <<NS_SUPPORT:Size/binary, _/binary>> ->
                                                false;
                                            _ ->
                                                true
                                        end
				end
			end,
			Els),
    #xmlel{name = <<"presence">>, attrs = Attrs,
	   children = FEls}.

add_user_presence(JID, Presence, StateData) ->
    LJID = jid:tolower(JID),
    FPresence = filter_presence(Presence),
    Users = (?DICT):update(LJID,
			   fun (#user{} = User) ->
				   User#user{last_presence = FPresence}
			   end,
			   StateData#state.users),
    StateData#state{users = Users}.

find_jids_by_nick(Nick, StateData) ->
    case (?DICT):find(Nick, StateData#state.nicks) of
      {ok, [User]} -> [jid:make(User)];
      {ok, Users} -> [jid:make(LJID) || LJID <- Users];
      error -> false
    end.

find_jid_by_nick(Nick, StateData) ->
    case (?DICT):find(Nick, StateData#state.nicks) of
      {ok, [User]} -> jid:make(User);
      {ok, [FirstUser | Users]} ->
	  #user{last_presence = FirstPresence} =
	      (?DICT):fetch(FirstUser, StateData#state.users),
	  {LJID, _} = lists:foldl(fun (Compare,
				       {HighestUser, HighestPresence}) ->
					  #user{last_presence = P1} =
					      (?DICT):fetch(Compare,
							    StateData#state.users),
					  case higher_presence(P1,
							       HighestPresence)
					      of
					    true -> {Compare, P1};
					    false ->
						{HighestUser, HighestPresence}
					  end
				  end,
				  {FirstUser, FirstPresence}, Users),
	  jid:make(LJID);
      error -> false
    end.

higher_presence(Pres1, Pres2) ->
    Pri1 = get_priority_from_presence(Pres1),
    Pri2 = get_priority_from_presence(Pres2),
    Pri1 > Pri2.

get_priority_from_presence(PresencePacket) ->
    case fxml:get_subtag(PresencePacket, <<"priority">>) of
      false -> 0;
      SubEl ->
	  case catch
		 jlib:binary_to_integer(fxml:get_tag_cdata(SubEl))
	      of
	    P when is_integer(P) -> P;
	    _ -> 0
	  end
    end.

nick_collision(User, Nick, StateData) ->
    UserOfNick = find_jid_by_nick(Nick, StateData),
    (UserOfNick /= false andalso
      jid:remove_resource(jid:tolower(UserOfNick))
	/= jid:remove_resource(jid:tolower(User))).

add_new_user(From, Nick,
	     #xmlel{attrs = Attrs, children = Els} = Packet,
	     StateData) ->
    Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
    MaxUsers = get_max_users(StateData),
    MaxAdminUsers = MaxUsers +
		      get_max_users_admin_threshold(StateData),
    NUsers = dict:fold(fun (_, _, Acc) -> Acc + 1 end, 0,
		       StateData#state.users),
    Affiliation = get_affiliation(From, StateData),
    ServiceAffiliation = get_service_affiliation(From,
						 StateData),
    NConferences = tab_count_user(From),
    MaxConferences =
	gen_mod:get_module_opt(StateData#state.server_host,
			       mod_support, max_user_conferences,
                               fun(I) when is_integer(I), I>0 -> I end,
                               10),
    Collision = nick_collision(From, Nick, StateData),
    case {(ServiceAffiliation == owner orelse
	     (Affiliation == admin orelse Affiliation == owner)
	       andalso NUsers < MaxAdminUsers
	       orelse NUsers < MaxUsers)
	    andalso NConferences < MaxConferences,
	  Collision,
	  mod_support:can_use_nick(StateData#state.server_host,
			       StateData#state.host, From, Nick),
	  get_default_role(Affiliation, StateData)}
	of
      {false, _, _, _} ->
	  Err = jlib:make_error_reply(Packet,
				      ?ERR_SERVICE_UNAVAILABLE),
	  route_stanza % TODO: s/Nick/""/
		      (jid:replace_resource(StateData#state.jid, Nick),
		       From, Err),
	  StateData;
      {_, _, _, none} ->
	  Err = jlib:make_error_reply(Packet,
				      case Affiliation of
					outcast ->
					    ErrText =
						<<"You have been banned from this room">>,
					    ?ERRT_FORBIDDEN(Lang, ErrText);
					_ ->
					    ErrText =
						<<"Membership is required to enter this room">>,
					    ?ERRT_REGISTRATION_REQUIRED(Lang,
									ErrText)
				      end),
	  route_stanza % TODO: s/Nick/""/
		      (jid:replace_resource(StateData#state.jid, Nick),
		       From, Err),
	  StateData;
      {_, true, _, _} ->
	  ErrText = <<"That nickname is already in use by another occupant">>,
	  Err = jlib:make_error_reply(Packet,
				      ?ERRT_CONFLICT(Lang, ErrText)),
	  route_stanza(jid:replace_resource(StateData#state.jid,
						 Nick),
		       From, Err),
	  StateData;
      {_, _, false, _} ->
	  ErrText = <<"That nickname is registered by another person">>,
	  Err = jlib:make_error_reply(Packet,
				      ?ERRT_CONFLICT(Lang, ErrText)),
	  route_stanza(jid:replace_resource(StateData#state.jid,
						 Nick),
		       From, Err),
	  StateData;
      {_, _, _, Role} ->
	  case check_password(ServiceAffiliation, Affiliation,
			      Els, From, StateData)
	      of
	    true ->
		NewState = add_user_presence(From, Packet,
					     add_online_user(From, Nick, Role,
							     StateData)),
		if not (NewState#state.config)#config.anonymous ->
		       WPacket = #xmlel{name = <<"message">>,
					attrs = [{<<"type">>, <<"groupchat">>}],
					children =
					    [#xmlel{name = <<"body">>,
						    attrs = [],
						    children =
							[{xmlcdata,
							  translate:translate(Lang,
									      <<"This room is not anonymous">>)}]},
					     #xmlel{name = <<"x">>,
						    attrs =
							[{<<"xmlns">>,
							  ?NS_SUPPORT_USER}],
						    children =
							[#xmlel{name =
								    <<"status">>,
								attrs =
								    [{<<"code">>,
								      <<"100">>}],
								children =
								    []}]}]},
		       route_stanza(StateData#state.jid, From, WPacket);
		   true -> ok
		end,
		send_existing_presences(From, NewState),
		send_new_presence(From, NewState),
		Shift = count_stanza_shift(Nick, Els, NewState),
		case send_history(From, Shift, NewState) of
		  true -> ok;
		  _ -> send_subject(From, Lang, StateData)
		end,
		case NewState#state.just_created of
		  true -> NewState#state{just_created = false};
		  false ->
		      Robots = (?DICT):erase(From, StateData#state.robots),
		      NewState#state{robots = Robots}
		end;
	    nopass ->
		ErrText = <<"A password is required to enter this room">>,
		Err = jlib:make_error_reply(Packet,
					    ?ERRT_NOT_AUTHORIZED(Lang,
								 ErrText)),
		route_stanza % TODO: s/Nick/""/
			    (jid:replace_resource(StateData#state.jid,
						       Nick),
			     From, Err),
		StateData;
	    captcha_required ->
		SID = fxml:get_attr_s(<<"id">>, Attrs),
		RoomJID = StateData#state.jid,
		To = jid:replace_resource(RoomJID, Nick),
		Limiter = {From#jid.luser, From#jid.lserver},
		case ejabberd_captcha:create_captcha(SID, RoomJID, To,
						     Lang, Limiter, From)
		    of
		  {ok, ID, CaptchaEls} ->
		      MsgPkt = #xmlel{name = <<"message">>,
				      attrs = [{<<"id">>, ID}],
				      children = CaptchaEls},
		      Robots = (?DICT):store(From, {Nick, Packet},
					     StateData#state.robots),
		      route_stanza(RoomJID, From, MsgPkt),
		      StateData#state{robots = Robots};
		  {error, limit} ->
		      ErrText = <<"Too many CAPTCHA requests">>,
		      Err = jlib:make_error_reply(Packet,
						  ?ERRT_RESOURCE_CONSTRAINT(Lang,
									    ErrText)),
		      route_stanza % TODO: s/Nick/""/
				  (jid:replace_resource(StateData#state.jid,
							     Nick),
				   From, Err),
		      StateData;
		  _ ->
		      ErrText = <<"Unable to generate a CAPTCHA">>,
		      Err = jlib:make_error_reply(Packet,
						  ?ERRT_INTERNAL_SERVER_ERROR(Lang,
									      ErrText)),
		      route_stanza % TODO: s/Nick/""/
				  (jid:replace_resource(StateData#state.jid,
							     Nick),
				   From, Err),
		      StateData
		end;
	    _ ->
		ErrText = <<"Incorrect password">>,
		Err = jlib:make_error_reply(Packet,
					    ?ERRT_NOT_AUTHORIZED(Lang,
								 ErrText)),
		route_stanza % TODO: s/Nick/""/
			    (jid:replace_resource(StateData#state.jid,
						       Nick),
			     From, Err),
		StateData
	  end
    end.

check_password(owner, _Affiliation, _Els, _From,
	       _StateData) ->
    %% Don't check pass if user is owner in SUPPORT service (access_admin option)
    true;
check_password(_ServiceAffiliation, Affiliation, Els,
	       From, StateData) ->
    case (StateData#state.config)#config.password_protected
	of
      false -> check_captcha(Affiliation, From, StateData);
      true ->
	  Pass = extract_password(Els),
	  case Pass of
	    false -> nopass;
	    _ ->
		case (StateData#state.config)#config.password of
		  Pass -> true;
		  _ -> false
		end
	  end
    end.

check_captcha(Affiliation, From, StateData) ->
    case (StateData#state.config)#config.captcha_protected
	   andalso ejabberd_captcha:is_feature_available()
	of
      true when Affiliation == none ->
	  case (?DICT):find(From, StateData#state.robots) of
	    {ok, passed} -> true;
	    _ ->
		WList =
		    (StateData#state.config)#config.captcha_whitelist,
		#jid{luser = U, lserver = S, lresource = R} = From,
		case (?SETS):is_element({U, S, R}, WList) of
		  true -> true;
		  false ->
		      case (?SETS):is_element({U, S, <<"">>}, WList) of
			true -> true;
			false ->
			    case (?SETS):is_element({<<"">>, S, <<"">>}, WList)
				of
			      true -> true;
			      false -> captcha_required
			    end
		      end
		end
	  end;
      _ -> true
    end.

extract_password([]) -> false;
extract_password([#xmlel{attrs = Attrs} = El | Els]) ->
    case fxml:get_attr_s(<<"xmlns">>, Attrs) of
      ?NS_SUPPORT ->
	  case fxml:get_subtag(El, <<"password">>) of
	    false -> false;
	    SubEl -> fxml:get_tag_cdata(SubEl)
	  end;
      _ -> extract_password(Els)
    end;
extract_password([_ | Els]) -> extract_password(Els).

count_stanza_shift(Nick, Els, StateData) ->
    HL = lqueue_to_list(StateData#state.history),
    Since = extract_history(Els, <<"since">>),
    Shift0 = case Since of
	       false -> 0;
	       _ ->
		   Sin = calendar:datetime_to_gregorian_seconds(Since),
		   count_seconds_shift(Sin, HL)
	     end,
    Seconds = extract_history(Els, <<"seconds">>),
    Shift1 = case Seconds of
	       false -> 0;
	       _ ->
		   Sec =
		       calendar:datetime_to_gregorian_seconds(calendar:universal_time())
			 - Seconds,
		   count_seconds_shift(Sec, HL)
	     end,
    MaxStanzas = extract_history(Els, <<"maxstanzas">>),
    Shift2 = case MaxStanzas of
	       false -> 0;
	       _ -> count_maxstanzas_shift(MaxStanzas, HL)
	     end,
    MaxChars = extract_history(Els, <<"maxchars">>),
    Shift3 = case MaxChars of
	       false -> 0;
	       _ -> count_maxchars_shift(Nick, MaxChars, HL)
	     end,
    lists:max([Shift0, Shift1, Shift2, Shift3]).

count_seconds_shift(Seconds, HistoryList) ->
    lists:sum(lists:map(fun ({_Nick, _Packet, _HaveSubject,
			      TimeStamp, _Size}) ->
				T =
				    calendar:datetime_to_gregorian_seconds(TimeStamp),
				if T < Seconds -> 1;
				   true -> 0
				end
			end,
			HistoryList)).

count_maxstanzas_shift(MaxStanzas, HistoryList) ->
    S = length(HistoryList) - MaxStanzas,
    if S =< 0 -> 0;
       true -> S
    end.

count_maxchars_shift(Nick, MaxSize, HistoryList) ->
    NLen = byte_size(Nick) + 1,
    Sizes = lists:map(fun ({_Nick, _Packet, _HaveSubject,
			    _TimeStamp, Size}) ->
			      Size + NLen
		      end,
		      HistoryList),
    calc_shift(MaxSize, Sizes).

calc_shift(MaxSize, Sizes) ->
    Total = lists:sum(Sizes),
    calc_shift(MaxSize, Total, 0, Sizes).

calc_shift(_MaxSize, _Size, Shift, []) -> Shift;
calc_shift(MaxSize, Size, Shift, [S | TSizes]) ->
    if MaxSize >= Size -> Shift;
       true -> calc_shift(MaxSize, Size - S, Shift + 1, TSizes)
    end.

extract_history([], _Type) -> false;
extract_history([#xmlel{attrs = Attrs} = El | Els],
		Type) ->
    case fxml:get_attr_s(<<"xmlns">>, Attrs) of
      ?NS_SUPPORT ->
	  AttrVal = fxml:get_path_s(El,
				   [{elem, <<"history">>}, {attr, Type}]),
	  case Type of
	    <<"since">> ->
		case jlib:datetime_string_to_timestamp(AttrVal) of
		  undefined -> false;
		  TS -> calendar:now_to_universal_time(TS)
		end;
	    _ ->
		case catch jlib:binary_to_integer(AttrVal) of
		  IntVal when is_integer(IntVal) and (IntVal >= 0) ->
		      IntVal;
		  _ -> false
		end
	  end;
      _ -> extract_history(Els, Type)
    end;
extract_history([_ | Els], Type) ->
    extract_history(Els, Type).

send_update_presence(JID, StateData) ->
    send_update_presence(JID, <<"">>, StateData).

send_update_presence(JID, Reason, StateData) ->
    LJID = jid:tolower(JID),
    LJIDs = case LJID of
	      {U, S, <<"">>} ->
		  (?DICT):fold(fun (J, _, Js) ->
				       case J of
					 {U, S, _} -> [J | Js];
					 _ -> Js
				       end
			       end,
			       [], StateData#state.users);
	      _ ->
		  case (?DICT):is_key(LJID, StateData#state.users) of
		    true -> [LJID];
		    _ -> []
		  end
	    end,
    lists:foreach(fun (J) ->
			  send_new_presence(J, Reason, StateData)
		  end,
		  LJIDs).

send_new_presence(NJID, StateData) ->
    send_new_presence(NJID, <<"">>, StateData).

send_new_presence(NJID, Reason, StateData) ->
    #user{nick = Nick} =
	(?DICT):fetch(jid:tolower(NJID),
		      StateData#state.users),
    LJID = find_jid_by_nick(Nick, StateData),
    {ok,
     #user{jid = RealJID, role = Role,
	   last_presence = Presence}} =
	(?DICT):find(jid:tolower(LJID),
		     StateData#state.users),
    Affiliation = get_affiliation(LJID, StateData),
    SAffiliation = affiliation_to_list(Affiliation),
    SRole = role_to_list(Role),
    lists:foreach(fun ({_LJID, Info}) ->
			  ItemAttrs = case Info#user.role == moderator orelse
					     (StateData#state.config)#config.anonymous
					       == false
					  of
					true ->
					    [{<<"jid">>,
					      jid:to_string(RealJID)},
					     {<<"affiliation">>, SAffiliation},
					     {<<"role">>, SRole}];
					_ ->
					    [{<<"affiliation">>, SAffiliation},
					     {<<"role">>, SRole}]
				      end,
			  ItemEls = case Reason of
				      <<"">> -> [];
				      _ ->
					  [#xmlel{name = <<"reason">>,
						  attrs = [],
						  children =
						      [{xmlcdata, Reason}]}]
				    end,
			  Status = case StateData#state.just_created of
				     true ->
					 [#xmlel{name = <<"status">>,
						 attrs =
						     [{<<"code">>, <<"201">>}],
						 children = []}];
				     false -> []
				   end,
			  Status2 = case
				      (StateData#state.config)#config.anonymous
					== false
					andalso NJID == Info#user.jid
					of
				      true ->
					  [#xmlel{name = <<"status">>,
						  attrs =
						      [{<<"code">>, <<"100">>}],
						  children = []}
					   | Status];
				      false -> Status
				    end,
			  Status3 = case NJID == Info#user.jid of
				      true ->
					  [#xmlel{name = <<"status">>,
						  attrs =
						      [{<<"code">>, <<"110">>}],
						  children = []}
					   | Status2];
				      false -> Status2
				    end,
			  Packet = fxml:append_subtags(Presence,
						      [#xmlel{name = <<"x">>,
							      attrs =
								  [{<<"xmlns">>,
								    ?NS_SUPPORT_USER}],
							      children =
								  [#xmlel{name =
									      <<"item">>,
									  attrs
									      =
									      ItemAttrs,
									  children
									      =
									      ItemEls}
								   | Status3]}]),
			  route_stanza(jid:replace_resource(StateData#state.jid,
								 Nick),
				       Info#user.jid, Packet)
		  end,
		  (?DICT):to_list(StateData#state.users)).

send_existing_presences(ToJID, StateData) ->
    LToJID = jid:tolower(ToJID),
    {ok, #user{jid = RealToJID, role = Role}} =
	(?DICT):find(LToJID, StateData#state.users),
    lists:foreach(fun ({FromNick, _Users}) ->
			  LJID = find_jid_by_nick(FromNick, StateData),
			  #user{jid = FromJID, role = FromRole,
				last_presence = Presence} =
			      (?DICT):fetch(jid:tolower(LJID),
					    StateData#state.users),
			  case RealToJID of
			    FromJID -> ok;
			    _ ->
				FromAffiliation = get_affiliation(LJID,
								  StateData),
				ItemAttrs = case Role == moderator orelse
						   (StateData#state.config)#config.anonymous
						     == false
						of
					      true ->
						  [{<<"jid">>,
						    jid:to_string(FromJID)},
						   {<<"affiliation">>,
						    affiliation_to_list(FromAffiliation)},
						   {<<"role">>,
						    role_to_list(FromRole)}];
					      _ ->
						  [{<<"affiliation">>,
						    affiliation_to_list(FromAffiliation)},
						   {<<"role">>,
						    role_to_list(FromRole)}]
					    end,
				Packet = fxml:append_subtags(Presence,
							    [#xmlel{name =
									<<"x">>,
								    attrs =
									[{<<"xmlns">>,
									  ?NS_SUPPORT_USER}],
								    children =
									[#xmlel{name
										    =
										    <<"item">>,
										attrs
										    =
										    ItemAttrs,
										children
										    =
										    []}]}]),
				route_stanza(jid:replace_resource(StateData#state.jid,
								       FromNick),
					     RealToJID, Packet)
			  end
		  end,
		  (?DICT):to_list(StateData#state.nicks)).

now_to_usec({MSec, Sec, USec}) ->
    (MSec * 1000000 + Sec) * 1000000 + USec.

lqueue_new(Max) ->
    #lqueue{queue = queue:new(), len = 0, max = Max}.

lqueue_in(_Item, LQ = #lqueue{max = 0}) -> LQ;
%% Otherwise, rotate messages in the queue store.
lqueue_in(Item,
	  #lqueue{queue = Q1, len = Len, max = Max}) ->
    Q2 = queue:in(Item, Q1),
    if Len >= Max ->
	   Q3 = lqueue_cut(Q2, Len - Max + 1),
	   #lqueue{queue = Q3, len = Max, max = Max};
       true -> #lqueue{queue = Q2, len = Len + 1, max = Max}
    end.

lqueue_cut(Q, 0) -> Q;
lqueue_cut(Q, N) ->
    {_, Q1} = queue:out(Q), lqueue_cut(Q1, N - 1).

lqueue_to_list(#lqueue{queue = Q1}) ->
    queue:to_list(Q1).

lqueue_filter(F, #lqueue{queue = Q1} = LQ) ->
    Q2 = queue:filter(F, Q1),
    LQ#lqueue{queue = Q2, len = queue:len(Q2)}.

add_message_to_history(FromNick, FromJID, Packet,
		       StateData) ->
    HaveSubject = case fxml:get_subtag(Packet, <<"subject">>)
		      of
		    false -> false;
		    _ -> true
		  end,
    TimeStamp = calendar:universal_time(),
    SenderJid = case
		  (StateData#state.config)#config.anonymous
		    of
		  true -> StateData#state.jid;
		  false -> FromJID
		end,
    {T_string, Tz_string} = jlib:timestamp_to_iso(TimeStamp, utc),
    Delay = [#xmlel{name = <<"delay">>, attrs = [{<<"xmlns">>, ?NS_DELAY},
                                                 {<<"from">>, jid:to_string(SenderJid)},
                                                 {<<"stamp">>, <<T_string/binary, Tz_string/binary>>}],
                    children = [{xmlcdata, <<>>}]}],

    TSPacket = fxml:append_subtags(Packet, Delay),
    SPacket =
	jlib:replace_from_to(jid:replace_resource(StateData#state.jid,
						       FromNick),
			     StateData#state.jid, TSPacket),
    Size = element_size(SPacket),
    Q1 = lqueue_in({FromNick, TSPacket, HaveSubject,
		    TimeStamp, Size},
		   StateData#state.history),
    add_to_log(text, {FromNick, Packet}, StateData),
    StateData#state{history = Q1}.

send_history(JID, Shift, StateData) ->
    lists:foldl(fun ({Nick, Packet, HaveSubject, _TimeStamp,
		      _Size},
		     B) ->
			route_stanza(jid:replace_resource(StateData#state.jid,
							       Nick),
				     JID, Packet),
			B or HaveSubject
		end,
		false,
		lists:nthtail(Shift,
			      lqueue_to_list(StateData#state.history))).

send_subject(JID, Lang, StateData) ->
    case StateData#state.subject_author of
      <<"">> -> ok;
      Nick ->
	  Subject = StateData#state.subject,
	  Packet = #xmlel{name = <<"message">>,
			  attrs = [{<<"type">>, <<"groupchat">>}],
			  children =
			      [#xmlel{name = <<"subject">>, attrs = [],
				      children = [{xmlcdata, Subject}]},
			       #xmlel{name = <<"body">>, attrs = [],
				      children =
					  [{xmlcdata,
					    <<Nick/binary,
					      (translate:translate(Lang,
								   <<" has set the subject to: ">>))/binary,
					      Subject/binary>>}]}]},
	  route_stanza(StateData#state.jid, JID, Packet)
    end.

check_subject(Packet) ->
    case fxml:get_subtag(Packet, <<"subject">>) of
      false -> false;
      SubjEl -> fxml:get_tag_cdata(SubjEl)
    end.

can_change_subject(Role, StateData) ->
    case (StateData#state.config)#config.allow_change_subj
	of
      true -> Role == moderator orelse Role == participant;
      _ -> Role == moderator
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Admin stuff

process_iq_admin(From, set, Lang, SubEl, StateData) ->
    #xmlel{children = Items} = SubEl,
    process_admin_items_set(From, Items, Lang, StateData);
process_iq_admin(From, get, Lang, SubEl, StateData) ->
    case fxml:get_subtag(SubEl, <<"item">>) of
      false -> {error, ?ERR_BAD_REQUEST};
      Item ->
	  FAffiliation = get_affiliation(From, StateData),
	  FRole = get_role(From, StateData),
	  case fxml:get_tag_attr(<<"role">>, Item) of
	    false ->
		case fxml:get_tag_attr(<<"affiliation">>, Item) of
		  false -> {error, ?ERR_BAD_REQUEST};
		  {value, StrAffiliation} ->
		      case catch list_to_affiliation(StrAffiliation) of
			{'EXIT', _} -> {error, ?ERR_BAD_REQUEST};
			SAffiliation ->
			    if (FAffiliation == owner) or
				 (FAffiliation == admin) or
				 ((FAffiliation == member) and (SAffiliation == member)) ->
				   Items = items_with_affiliation(SAffiliation,
								  StateData),
				   {result, Items, StateData};
			       true ->
				   ErrText =
				       <<"Administrator privileges required">>,
				   {error, ?ERRT_FORBIDDEN(Lang, ErrText)}
			    end
		      end
		end;
	    {value, StrRole} ->
		case catch list_to_role(StrRole) of
		  {'EXIT', _} -> {error, ?ERR_BAD_REQUEST};
		  SRole ->
		      if FRole == moderator ->
			     Items = items_with_role(SRole, StateData),
			     {result, Items, StateData};
			 true ->
			     ErrText = <<"Moderator privileges required">>,
			     {error, ?ERRT_FORBIDDEN(Lang, ErrText)}
		      end
		end
	  end
    end.

items_with_role(SRole, StateData) ->
    lists:map(fun ({_, U}) -> user_to_item(U, StateData)
	      end,
	      search_role(SRole, StateData)).

items_with_affiliation(SAffiliation, StateData) ->
    lists:map(fun ({JID, {Affiliation, Reason}}) ->
		      #xmlel{name = <<"item">>,
			     attrs =
				 [{<<"affiliation">>,
				   affiliation_to_list(Affiliation)},
				  {<<"jid">>, jid:to_string(JID)}],
			     children =
				 [#xmlel{name = <<"reason">>, attrs = [],
					 children = [{xmlcdata, Reason}]}]};
		  ({JID, Affiliation}) ->
		      #xmlel{name = <<"item">>,
			     attrs =
				 [{<<"affiliation">>,
				   affiliation_to_list(Affiliation)},
				  {<<"jid">>, jid:to_string(JID)}],
			     children = []}
	      end,
	      search_affiliation(SAffiliation, StateData)).

user_to_item(#user{role = Role, nick = Nick, jid = JID},
	     StateData) ->
    Affiliation = get_affiliation(JID, StateData),
    #xmlel{name = <<"item">>,
	   attrs =
	       [{<<"role">>, role_to_list(Role)},
		{<<"affiliation">>, affiliation_to_list(Affiliation)},
		{<<"nick">>, Nick},
		{<<"jid">>, jid:to_string(JID)}],
	   children = []}.

search_role(Role, StateData) ->
    lists:filter(fun ({_, #user{role = R}}) -> Role == R
		 end,
		 (?DICT):to_list(StateData#state.users)).

search_affiliation(Affiliation, StateData) ->
    DBType = gen_mod:db_type(StateData#state.server_host, mod_support),
    search_affiliation(Affiliation, StateData, DBType).

search_affiliation(Affiliation,
                   #state{config = #config{persistent = true}} = StateData,
                   p1db) ->
    Room = StateData#state.room,
    Host = StateData#state.host,
    RHPrefix = mod_support:rh_prefix(Room, Host),
    case p1db:get_by_prefix(support_affiliations, RHPrefix) of
        {ok, L} ->
            lists:flatmap(
              fun({Key, Val, _VClock}) ->
                      PropList = binary_to_term(Val),
                      Reason = proplists:get_value(reason, PropList, <<>>),
                      case proplists:get_value(affiliation, PropList, none) of
                          Affiliation ->
                              {LUser, LServer} = mod_support:key2us(RHPrefix, Key),
                              [{{LUser, LServer, <<"">>},
                                {Affiliation, Reason}}];
                          _ ->
                              []
                      end
              end, L);
        {error, _} ->
            []
    end;
search_affiliation(Affiliation, StateData, _DBType) ->
    lists:filter(fun ({_, A}) ->
			 case A of
			   {A1, _Reason} -> Affiliation == A1;
			   _ -> Affiliation == A
			 end
		 end,
		 (?DICT):to_list(StateData#state.affiliations)).

process_admin_items_set(UJID, Items, Lang, StateData) ->
    UAffiliation = get_affiliation(UJID, StateData),
    URole = get_role(UJID, StateData),
    case find_changed_items(UJID, UAffiliation, URole,
			    Items, Lang, StateData, [])
	of
      {result, Res} ->
	  ?INFO_MSG("Processing SUPPORT admin query from ~s in "
		    "room ~s:~n ~p",
		    [jid:to_string(UJID),
		     jid:to_string(StateData#state.jid), Res]),
	  NSD = lists:foldl(fun (E, SD) ->
				    case catch case E of
						 {JID, affiliation, owner, _}
						     when JID#jid.luser ==
							    <<"">> ->
						     %% If the provided JID does not have username,
						     %% forget the affiliation completely
						     SD;
						 {JID, role, none, Reason} ->
						     catch
						       send_kickban_presence(JID,
									     Reason,
									     <<"307">>,
									     SD),
						     set_role(JID, none, SD);
						 {JID, affiliation, none,
						  Reason} ->
						     case
						       (SD#state.config)#config.members_only
							 of
						       true ->
							   catch
							     send_kickban_presence(JID,
										   Reason,
										   <<"321">>,
										   none,
										   SD),
							   SD1 =
							       set_affiliation(JID,
									       none,
									       SD),
							   set_role(JID, none,
								    SD1);
						       _ ->
							   SD1 =
							       set_affiliation(JID,
									       none,
									       SD),
							   send_update_presence(JID,
										SD1),
							   SD1
						     end;
						 {JID, affiliation, outcast,
						  Reason} ->
						     catch
						       send_kickban_presence(JID,
									     Reason,
									     <<"301">>,
									     outcast,
									     SD),
						       SD1 = set_affiliation(
							       JID,
							       outcast,
							       set_role(JID,
									none,
									SD),
							       Reason),
						      kick_users_from_banned_server(
							JID, Reason, SD1);
						 {JID, affiliation, A, Reason}
						     when (A == admin) or
							    (A == owner) ->
						     SD1 = set_affiliation(JID,
									   A,
									   SD,
									   Reason),
						     SD2 = set_role(JID,
								    moderator,
								    SD1),
						     send_update_presence(JID,
									  Reason,
									  SD2),
						     SD2;
						 {JID, affiliation, member,
						  Reason} ->
						     SD1 = set_affiliation(JID,
									   member,
									   SD,
									   Reason),
						     SD2 = set_role(JID,
								    participant,
								    SD1),
						     send_update_presence(JID,
									  Reason,
									  SD2),
						     SD2;
						 {JID, role, Role, Reason} ->
						     SD1 = set_role(JID, Role,
								    SD),
						     catch
						       send_new_presence(JID,
									 Reason,
									 SD1),
						     SD1;
						 {JID, affiliation, A,
						  _Reason} ->
						     SD1 = set_affiliation(JID,
									   A,
									   SD),
						     send_update_presence(JID,
									  SD1),
						     SD1
					       end
					of
				      {'EXIT', ErrReason} ->
					  ?ERROR_MSG("SUPPORT ITEMS SET ERR: ~p~n",
						     [ErrReason]),
					  SD;
				      NSD -> NSD
				    end
			    end,
			    StateData, lists:flatten(Res)),
	  case (NSD#state.config)#config.persistent of
	    true ->
		mod_support:store_room(NSD#state.server_host,
				   NSD#state.host, NSD#state.room,
				   make_opts(NSD), make_affiliations(NSD));
	    _ -> ok
	  end,
	  {result, [], NSD};
      Err -> Err
    end.

find_changed_items(_UJID, _UAffiliation, _URole, [],
		   _Lang, _StateData, Res) ->
    {result, Res};
find_changed_items(UJID, UAffiliation, URole,
		   [{xmlcdata, _} | Items], Lang, StateData, Res) ->
    find_changed_items(UJID, UAffiliation, URole, Items,
		       Lang, StateData, Res);
find_changed_items(UJID, UAffiliation, URole,
		   [#xmlel{name = <<"item">>, attrs = Attrs} = Item
		    | Items],
		   Lang, StateData, Res) ->
    TJID = case fxml:get_attr(<<"jid">>, Attrs) of
	     {value, S} ->
		 case jid:from_string(S) of
		   error ->
		       ErrText = iolist_to_binary(
                                   io_lib:format(translate:translate(
                                                   Lang,
                                                   <<"Jabber ID ~s is invalid">>),
                                                 [S])),
		       {error, ?ERRT_NOT_ACCEPTABLE(Lang, ErrText)};
		   J -> {value, [J]}
		 end;
	     _ ->
		 case fxml:get_attr(<<"nick">>, Attrs) of
		   {value, N} ->
		       case find_jids_by_nick(N, StateData) of
			 false ->
			     ErrText = iolist_to_binary(
                                         io_lib:format(
                                           translate:translate(
                                             Lang,
                                             <<"Nickname ~s does not exist in the room">>),
                                           [N])),
			     {error, ?ERRT_NOT_ACCEPTABLE(Lang, ErrText)};
			 J -> {value, J}
		       end;
		   _ -> {error, ?ERR_BAD_REQUEST}
		 end
	   end,
    case TJID of
      {value, [JID | _] = JIDs} ->
	  TAffiliation = get_affiliation(JID, StateData),
	  TRole = get_role(JID, StateData),
	  case fxml:get_attr(<<"role">>, Attrs) of
	    false ->
		case fxml:get_attr(<<"affiliation">>, Attrs) of
		  false -> {error, ?ERR_BAD_REQUEST};
		  {value, StrAffiliation} ->
		      case catch list_to_affiliation(StrAffiliation) of
			{'EXIT', _} ->
			    ErrText1 = iolist_to_binary(
                                         io_lib:format(
                                           translate:translate(
                                             Lang,
                                             <<"Invalid affiliation: ~s">>),
                                           [StrAffiliation])),
			    {error, ?ERRT_NOT_ACCEPTABLE(Lang, ErrText1)};
			SAffiliation ->
			    ServiceAf = get_service_affiliation(JID, StateData),
			    CanChangeRA = case can_change_ra(UAffiliation,
							     URole,
							     TAffiliation,
							     TRole, affiliation,
							     SAffiliation,
							     ServiceAf)
					      of
					    nothing -> nothing;
					    true -> true;
					    check_owner ->
						case search_affiliation(owner,
									StateData)
						    of
						  [{OJID, _}] ->
						      jid:remove_resource(OJID)
							/=
							jid:tolower(jid:remove_resource(UJID));
						  _ -> true
						end;
					    _ -> false
					  end,
			    case CanChangeRA of
			      nothing ->
				  find_changed_items(UJID, UAffiliation, URole,
						     Items, Lang, StateData,
						     Res);
			      true ->
				  Reason = fxml:get_path_s(Item,
							  [{elem, <<"reason">>},
							   cdata]),
				  MoreRes = [{jid:remove_resource(Jidx),
					      affiliation, SAffiliation, Reason}
					     || Jidx <- JIDs],
				  find_changed_items(UJID, UAffiliation, URole,
						     Items, Lang, StateData,
						     [MoreRes | Res]);
			      false -> {error, ?ERR_NOT_ALLOWED}
			    end
		      end
		end;
	    {value, StrRole} ->
		case catch list_to_role(StrRole) of
		  {'EXIT', _} ->
		      ErrText1 = iolist_to_binary(
                                   io_lib:format(translate:translate(
                                                   Lang,
                                                   <<"Invalid role: ~s">>),
                                                 [StrRole])),
		      {error, ?ERRT_BAD_REQUEST(Lang, ErrText1)};
		  SRole ->
		      ServiceAf = get_service_affiliation(JID, StateData),
		      CanChangeRA = case can_change_ra(UAffiliation, URole,
						       TAffiliation, TRole,
						       role, SRole, ServiceAf)
					of
				      nothing -> nothing;
				      true -> true;
				      check_owner ->
					  case search_affiliation(owner,
								  StateData)
					      of
					    [{OJID, _}] ->
						jid:remove_resource(OJID)
						  /=
						  jid:tolower(jid:remove_resource(UJID));
					    _ -> true
					  end;
				      _ -> false
				    end,
		      case CanChangeRA of
			nothing ->
			    find_changed_items(UJID, UAffiliation, URole, Items,
					       Lang, StateData, Res);
			true ->
			    Reason = fxml:get_path_s(Item,
						    [{elem, <<"reason">>},
						     cdata]),
			    MoreRes = [{Jidx, role, SRole, Reason}
				       || Jidx <- JIDs],
			    find_changed_items(UJID, UAffiliation, URole, Items,
					       Lang, StateData,
					       [MoreRes | Res]);
			_ -> {error, ?ERR_NOT_ALLOWED}
		      end
		end
	  end;
      Err -> Err
    end;
find_changed_items(_UJID, _UAffiliation, _URole, _Items,
		   _Lang, _StateData, _Res) ->
    {error, ?ERR_BAD_REQUEST}.

can_change_ra(_FAffiliation, _FRole, owner, _TRole,
	      affiliation, owner, owner) ->
    %% A room owner tries to add as persistent owner a
    %% participant that is already owner because he is SUPPORT admin
    true;
can_change_ra(_FAffiliation, _FRole, _TAffiliation,
	      _TRole, _RoleorAffiliation, _Value, owner) ->
    %% Nobody can decrease SUPPORT admin's role/affiliation
    false;
can_change_ra(_FAffiliation, _FRole, TAffiliation,
	      _TRole, affiliation, Value, _ServiceAf)
    when TAffiliation == Value ->
    nothing;
can_change_ra(_FAffiliation, _FRole, _TAffiliation,
	      TRole, role, Value, _ServiceAf)
    when TRole == Value ->
    nothing;
can_change_ra(FAffiliation, _FRole, outcast, _TRole,
	      affiliation, none, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(FAffiliation, _FRole, outcast, _TRole,
	      affiliation, member, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(owner, _FRole, outcast, _TRole,
	      affiliation, admin, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, outcast, _TRole,
	      affiliation, owner, _ServiceAf) ->
    true;
can_change_ra(FAffiliation, _FRole, none, _TRole,
	      affiliation, outcast, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(FAffiliation, _FRole, none, _TRole,
	      affiliation, member, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(owner, _FRole, none, _TRole, affiliation,
	      admin, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, none, _TRole, affiliation,
	      owner, _ServiceAf) ->
    true;
can_change_ra(FAffiliation, _FRole, member, _TRole,
	      affiliation, outcast, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(FAffiliation, _FRole, member, _TRole,
	      affiliation, none, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(owner, _FRole, member, _TRole,
	      affiliation, admin, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, member, _TRole,
	      affiliation, owner, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, admin, _TRole, affiliation,
	      _Affiliation, _ServiceAf) ->
    true;
can_change_ra(owner, _FRole, owner, _TRole, affiliation,
	      _Affiliation, _ServiceAf) ->
    check_owner;
can_change_ra(_FAffiliation, _FRole, _TAffiliation,
	      _TRole, affiliation, _Value, _ServiceAf) ->
    false;
can_change_ra(_FAffiliation, moderator, _TAffiliation,
	      visitor, role, none, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, moderator, _TAffiliation,
	      visitor, role, participant, _ServiceAf) ->
    true;
can_change_ra(FAffiliation, _FRole, _TAffiliation,
	      visitor, role, moderator, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(_FAffiliation, moderator, _TAffiliation,
	      participant, role, none, _ServiceAf) ->
    true;
can_change_ra(owner, none, _TAffiliation,
	      participant, role, none, _ServiceAf) ->
    true; %% This happens when running mod_support_light command 'support_kick_user'
can_change_ra(_FAffiliation, moderator, _TAffiliation,
	      participant, role, visitor, _ServiceAf) ->
    true;
can_change_ra(FAffiliation, _FRole, _TAffiliation,
	      participant, role, moderator, _ServiceAf)
    when (FAffiliation == owner) or
	   (FAffiliation == admin) ->
    true;
can_change_ra(_FAffiliation, _FRole, owner, moderator,
	      role, visitor, _ServiceAf) ->
    false;
can_change_ra(owner, _FRole, _TAffiliation, moderator,
	      role, visitor, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, _FRole, admin, moderator,
	      role, visitor, _ServiceAf) ->
    false;
can_change_ra(admin, _FRole, _TAffiliation, moderator,
	      role, visitor, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, _FRole, owner, moderator,
	      role, participant, _ServiceAf) ->
    false;
can_change_ra(owner, _FRole, _TAffiliation, moderator,
	      role, participant, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, _FRole, admin, moderator,
	      role, participant, _ServiceAf) ->
    false;
can_change_ra(admin, _FRole, _TAffiliation, moderator,
	      role, participant, _ServiceAf) ->
    true;
can_change_ra(_FAffiliation, _FRole, _TAffiliation,
	      _TRole, role, _Value, _ServiceAf) ->
    false.

send_kickban_presence(JID, Reason, Code, StateData) ->
    NewAffiliation = get_affiliation(JID, StateData),
    send_kickban_presence(JID, Reason, Code, NewAffiliation,
			  StateData).

send_kickban_presence(JID, Reason, Code, NewAffiliation,
		      StateData) ->
    LJID = jid:tolower(JID),
    LJIDs = case LJID of
	      {U, S, <<"">>} ->
		  (?DICT):fold(fun (J, _, Js) ->
				       case J of
					 {U, S, _} -> [J | Js];
					 _ -> Js
				       end
			       end,
			       [], StateData#state.users);
	      _ ->
		  case (?DICT):is_key(LJID, StateData#state.users) of
		    true -> [LJID];
		    _ -> []
		  end
	    end,
    lists:foreach(fun (J) ->
			  {ok, #user{nick = Nick}} = (?DICT):find(J,
								  StateData#state.users),
			  add_to_log(kickban, {Nick, Reason, Code}, StateData),
			  tab_remove_online_user(J, StateData),
			  send_kickban_presence1(J, Reason, Code,
						 NewAffiliation, StateData)
		  end,
		  LJIDs),
    LJIDs.

send_kickban_presence1(UJID, Reason, Code, Affiliation,
		       StateData) ->
    {ok, #user{jid = RealJID, nick = Nick}} =
	(?DICT):find(jid:tolower(UJID),
		     StateData#state.users),
    SAffiliation = affiliation_to_list(Affiliation),
    BannedJIDString = jid:to_string(RealJID),
    lists:foreach(fun ({_LJID, Info}) ->
			  JidAttrList = case Info#user.role == moderator orelse
					       (StateData#state.config)#config.anonymous
						 == false
					    of
					  true ->
					      [{<<"jid">>, BannedJIDString}];
					  false -> []
					end,
			  ItemAttrs = [{<<"affiliation">>, SAffiliation},
				       {<<"role">>, <<"none">>}]
					++ JidAttrList,
			  ItemEls = case Reason of
				      <<"">> -> [];
				      _ ->
					  [#xmlel{name = <<"reason">>,
						  attrs = [],
						  children =
						      [{xmlcdata, Reason}]}]
				    end,
			  Packet = #xmlel{name = <<"presence">>,
					  attrs =
					      [{<<"type">>, <<"unavailable">>}],
					  children =
					      [#xmlel{name = <<"x">>,
						      attrs =
							  [{<<"xmlns">>,
							    ?NS_SUPPORT_USER}],
						      children =
							  [#xmlel{name =
								      <<"item">>,
								  attrs =
								      ItemAttrs,
								  children =
								      ItemEls},
							   #xmlel{name =
								      <<"status">>,
								  attrs =
								      [{<<"code">>,
									Code}],
								  children =
								      []}]}]},
			  route_stanza(jid:replace_resource(StateData#state.jid,
								 Nick),
				       Info#user.jid, Packet)
		  end,
		  (?DICT):to_list(StateData#state.users)).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Owner stuff

process_iq_owner(From, set, Lang, SubEl, StateData) ->
    FAffiliation = get_affiliation(From, StateData),
    case FAffiliation of
      owner ->
	  #xmlel{children = Els} = SubEl,
	  case fxml:remove_cdata(Els) of
	    [#xmlel{name = <<"x">>} = XEl] ->
		case {fxml:get_tag_attr_s(<<"xmlns">>, XEl),
		      fxml:get_tag_attr_s(<<"type">>, XEl)}
		    of
		  {?NS_XDATA, <<"cancel">>} -> {result, [], StateData};
		  {?NS_XDATA, <<"submit">>} ->
		      case is_allowed_log_change(XEl, StateData, From) andalso
			     is_allowed_persistent_change(XEl, StateData, From)
			       andalso
			       is_allowed_room_name_desc_limits(XEl, StateData)
				 andalso
				 is_password_settings_correct(XEl, StateData)
			  of
			true -> set_config(XEl, StateData);
			false -> {error, ?ERR_NOT_ACCEPTABLE}
		      end;
		  _ -> {error, ?ERR_BAD_REQUEST}
		end;
	    [#xmlel{name = <<"destroy">>} = SubEl1] ->
		?INFO_MSG("Destroyed SUPPORT room ~s by the owner ~s",
			  [jid:to_string(StateData#state.jid),
			   jid:to_string(From)]),
		add_to_log(room_existence, destroyed, StateData),
		destroy_room(SubEl1, StateData);
	    Items ->
		process_admin_items_set(From, Items, Lang, StateData)
	  end;
      _ ->
	  ErrText = <<"Owner privileges required">>,
	  {error, ?ERRT_FORBIDDEN(Lang, ErrText)}
    end;
process_iq_owner(From, get, Lang, SubEl, StateData) ->
    FAffiliation = get_affiliation(From, StateData),
    case FAffiliation of
      owner ->
	  #xmlel{children = Els} = SubEl,
	  case fxml:remove_cdata(Els) of
	    [] -> get_config(Lang, StateData, From);
	    [Item] ->
		case fxml:get_tag_attr(<<"affiliation">>, Item) of
		  false -> {error, ?ERR_BAD_REQUEST};
		  {value, StrAffiliation} ->
		      case catch list_to_affiliation(StrAffiliation) of
			{'EXIT', _} ->
			    ErrText = iolist_to_binary(
                                        io_lib:format(
                                          translate:translate(
                                            Lang,
                                            <<"Invalid affiliation: ~s">>),
                                          [StrAffiliation])),
			    {error, ?ERRT_NOT_ACCEPTABLE(Lang, ErrText)};
			SAffiliation ->
			    Items = items_with_affiliation(SAffiliation,
							   StateData),
			    {result, Items, StateData}
		      end
		end;
	    _ -> {error, ?ERR_FEATURE_NOT_IMPLEMENTED}
	  end;
      _ ->
	  ErrText = <<"Owner privileges required">>,
	  {error, ?ERRT_FORBIDDEN(Lang, ErrText)}
    end.

is_allowed_log_change(XEl, _StateData, _From) ->
    case lists:keymember(<<"support#roomconfig_enablelogging">>,
			 1, jlib:parse_xdata_submit(XEl))
	of
      false -> true;
      true ->
	  allow == false
	    %mod_support_log:check_access_log(StateData#state.server_host, From)
    end.

is_allowed_persistent_change(XEl, StateData, From) ->
    case
      lists:keymember(<<"support#roomconfig_persistentroom">>, 1,
		      jlib:parse_xdata_submit(XEl))
	of
      false -> true;
      true ->
	  {_AccessRoute, _AccessCreate, _AccessAdmin,
	   AccessPersistent} =
	      StateData#state.access,
	  allow ==
	    acl:match_rule(StateData#state.server_host,
			   AccessPersistent, From)
    end.

is_allowed_room_name_desc_limits(XEl, StateData) ->
    IsNameAccepted = case
		       lists:keysearch(<<"support#roomconfig_roomname">>, 1,
				       jlib:parse_xdata_submit(XEl))
			 of
		       {value, {_, [N]}} ->
			   byte_size(N) =<
			     gen_mod:get_module_opt(StateData#state.server_host,
						    mod_support, max_room_name,
                                                    fun(infinity) -> infinity;
                                                       (I) when is_integer(I),
                                                                I>0 -> I
                                                    end, infinity);
		       _ -> true
		     end,
    IsDescAccepted = case
		       lists:keysearch(<<"support#roomconfig_roomdesc">>, 1,
				       jlib:parse_xdata_submit(XEl))
			 of
		       {value, {_, [D]}} ->
			   byte_size(D) =<
			     gen_mod:get_module_opt(StateData#state.server_host,
						    mod_support, max_room_desc,
                                                    fun(infinity) -> infinity;
                                                       (I) when is_integer(I),
                                                                I>0 ->
                                                            I
                                                    end, infinity);
		       _ -> true
		     end,
    IsNameAccepted and IsDescAccepted.

is_password_settings_correct(XEl, StateData) ->
    Config = StateData#state.config,
    OldProtected = Config#config.password_protected,
    OldPassword = Config#config.password,
    NewProtected = case
		     lists:keysearch(<<"support#roomconfig_passwordprotectedroom">>,
				     1, jlib:parse_xdata_submit(XEl))
		       of
		     {value, {_, [<<"1">>]}} -> true;
		     {value, {_, [<<"0">>]}} -> false;
		     _ -> undefined
		   end,
    NewPassword = case
		    lists:keysearch(<<"support#roomconfig_roomsecret">>, 1,
				    jlib:parse_xdata_submit(XEl))
		      of
		    {value, {_, [P]}} -> P;
		    _ -> undefined
		  end,
    case {OldProtected, NewProtected, OldPassword,
	  NewPassword}
	of
      {true, undefined, <<"">>, undefined} -> false;
      {true, undefined, _, <<"">>} -> false;
      {_, true, <<"">>, undefined} -> false;
      {_, true, _, <<"">>} -> false;
      _ -> true
    end.

-define(XFIELD(Type, Label, Var, Val),
	#xmlel{name = <<"field">>,
	       attrs =
		   [{<<"type">>, Type},
		    {<<"label">>, translate:translate(Lang, Label)},
		    {<<"var">>, Var}],
	       children =
		   [#xmlel{name = <<"value">>, attrs = [],
			   children = [{xmlcdata, Val}]}]}).

-define(BOOLXFIELD(Label, Var, Val),
	?XFIELD(<<"boolean">>, Label, Var,
		case Val of
		  true -> <<"1">>;
		  _ -> <<"0">>
		end)).

-define(STRINGXFIELD(Label, Var, Val),
	?XFIELD(<<"text-single">>, Label, Var, Val)).

-define(PRIVATEXFIELD(Label, Var, Val),
	?XFIELD(<<"text-private">>, Label, Var, Val)).

-define(JIDMULTIXFIELD(Label, Var, JIDList),
	#xmlel{name = <<"field">>,
	       attrs =
		   [{<<"type">>, <<"jid-multi">>},
		    {<<"label">>, translate:translate(Lang, Label)},
		    {<<"var">>, Var}],
	       children =
		   [#xmlel{name = <<"value">>, attrs = [],
			   children = [{xmlcdata, jid:to_string(JID)}]}
		    || JID <- JIDList]}).

get_default_room_maxusers(RoomState) ->
    DefRoomOpts =
	gen_mod:get_module_opt(RoomState#state.server_host,
			       mod_support, default_room_options,
                               fun(L) when is_list(L) -> L end,
                               []),
    RoomState2 = set_opts(DefRoomOpts, RoomState),
    (RoomState2#state.config)#config.max_users.

get_config(Lang, StateData, From) ->
    {_AccessRoute, _AccessCreate, _AccessAdmin,
     AccessPersistent} =
	StateData#state.access,
    ServiceMaxUsers = get_service_max_users(StateData),
    DefaultRoomMaxUsers =
	get_default_room_maxusers(StateData),
    Config = StateData#state.config,
    {MaxUsersRoomInteger, MaxUsersRoomString} = case
						  get_max_users(StateData)
						    of
						  N when is_integer(N) ->
						      {N,
						       jlib:integer_to_binary(N)};
						  _ -> {0, <<"none">>}
						end,
    Res = [#xmlel{name = <<"title">>, attrs = [],
		  children =
		      [{xmlcdata,
			iolist_to_binary(
                          io_lib:format(
                            translate:translate(
                              Lang,
                              <<"Configuration of room ~s">>),
                            [jid:to_string(StateData#state.jid)]))}]},
	   #xmlel{name = <<"field">>,
		  attrs =
		      [{<<"type">>, <<"hidden">>},
		       {<<"var">>, <<"FORM_TYPE">>}],
		  children =
		      [#xmlel{name = <<"value">>, attrs = [],
			      children =
				  [{xmlcdata,
				    <<"p1:support#roomconfig">>}]}]},
	   ?STRINGXFIELD(<<"Room title">>,
			 <<"support#roomconfig_roomname">>, (Config#config.title)),
	   ?STRINGXFIELD(<<"Room description">>,
			 <<"support#roomconfig_roomdesc">>,
			 (Config#config.description))]
	    ++
	    case acl:match_rule(StateData#state.server_host,
				AccessPersistent, From)
		of
	      allow ->
		  [?BOOLXFIELD(<<"Make room persistent">>,
			       <<"support#roomconfig_persistentroom">>,
			       (Config#config.persistent))];
	      _ -> []
	    end
	      ++
	      [?BOOLXFIELD(<<"Make room public searchable">>,
			   <<"support#roomconfig_publicroom">>,
			   (Config#config.public)),
	       ?BOOLXFIELD(<<"Make participants list public">>,
			   <<"public_list">>, (Config#config.public_list)),
	       ?BOOLXFIELD(<<"Make room password protected">>,
			   <<"support#roomconfig_passwordprotectedroom">>,
			   (Config#config.password_protected)),
	       ?PRIVATEXFIELD(<<"Password">>,
			      <<"support#roomconfig_roomsecret">>,
			      case Config#config.password_protected of
				true -> Config#config.password;
				false -> <<"">>
			      end),
	       #xmlel{name = <<"field">>,
		      attrs =
			  [{<<"type">>, <<"list-single">>},
			   {<<"label">>,
			    translate:translate(Lang,
						<<"Maximum Number of Occupants">>)},
			   {<<"var">>, <<"support#roomconfig_maxusers">>}],
		      children =
			  [#xmlel{name = <<"value">>, attrs = [],
				  children = [{xmlcdata, MaxUsersRoomString}]}]
			    ++
			    if is_integer(ServiceMaxUsers) -> [];
			       true ->
				   [#xmlel{name = <<"option">>,
					   attrs =
					       [{<<"label">>,
						 translate:translate(Lang,
								     <<"No limit">>)}],
					   children =
					       [#xmlel{name = <<"value">>,
						       attrs = [],
						       children =
							   [{xmlcdata,
							     <<"none">>}]}]}]
			    end
			      ++
			      [#xmlel{name = <<"option">>,
				      attrs =
					  [{<<"label">>,
					    jlib:integer_to_binary(N)}],
				      children =
					  [#xmlel{name = <<"value">>,
						  attrs = [],
						  children =
						      [{xmlcdata,
							jlib:integer_to_binary(N)}]}]}
			       || N
				      <- lists:usort([ServiceMaxUsers,
						      DefaultRoomMaxUsers,
						      MaxUsersRoomInteger
						      | ?MAX_USERS_DEFAULT_LIST]),
				  N =< ServiceMaxUsers]},
	       #xmlel{name = <<"field">>,
		      attrs =
			  [{<<"type">>, <<"list-single">>},
			   {<<"label">>,
			    translate:translate(Lang,
						<<"Present real Jabber IDs to">>)},
			   {<<"var">>, <<"support#roomconfig_whois">>}],
		      children =
			  [#xmlel{name = <<"value">>, attrs = [],
				  children =
				      [{xmlcdata,
					if Config#config.anonymous ->
					       <<"moderators">>;
					   true -> <<"anyone">>
					end}]},
			   #xmlel{name = <<"option">>,
				  attrs =
				      [{<<"label">>,
					translate:translate(Lang,
							    <<"moderators only">>)}],
				  children =
				      [#xmlel{name = <<"value">>, attrs = [],
					      children =
						  [{xmlcdata,
						    <<"moderators">>}]}]},
			   #xmlel{name = <<"option">>,
				  attrs =
				      [{<<"label">>,
					translate:translate(Lang,
							    <<"anyone">>)}],
				  children =
				      [#xmlel{name = <<"value">>, attrs = [],
					      children =
						  [{xmlcdata,
						    <<"anyone">>}]}]}]},
	       ?BOOLXFIELD(<<"Make room members-only">>,
			   <<"support#roomconfig_membersonly">>,
			   (Config#config.members_only)),
	       ?BOOLXFIELD(<<"Make room moderated">>,
			   <<"support#roomconfig_moderatedroom">>,
			   (Config#config.moderated)),
	       ?BOOLXFIELD(<<"Default users as participants">>,
			   <<"members_by_default">>,
			   (Config#config.members_by_default)),
	       ?BOOLXFIELD(<<"Allow users to change the subject">>,
			   <<"support#roomconfig_changesubject">>,
			   (Config#config.allow_change_subj)),
	       ?BOOLXFIELD(<<"Allow users to send private messages">>,
			   <<"allow_private_messages">>,
			   (Config#config.allow_private_messages)),
	       #xmlel{name = <<"field">>,
		      attrs =
			  [{<<"type">>, <<"list-single">>},
			   {<<"label">>,
			    translate:translate(Lang,
						<<"Allow visitors to send private messages to">>)},
			   {<<"var">>,
			    <<"allow_private_messages_from_visitors">>}],
		      children =
			  [#xmlel{name = <<"value">>, attrs = [],
				  children =
				      [{xmlcdata,
					case
					  Config#config.allow_private_messages_from_visitors
					    of
					  anyone -> <<"anyone">>;
					  moderators -> <<"moderators">>;
					  nobody -> <<"nobody">>
					end}]},
			   #xmlel{name = <<"option">>,
				  attrs =
				      [{<<"label">>,
					translate:translate(Lang,
							    <<"nobody">>)}],
				  children =
				      [#xmlel{name = <<"value">>, attrs = [],
					      children =
						  [{xmlcdata, <<"nobody">>}]}]},
			   #xmlel{name = <<"option">>,
				  attrs =
				      [{<<"label">>,
					translate:translate(Lang,
							    <<"moderators only">>)}],
				  children =
				      [#xmlel{name = <<"value">>, attrs = [],
					      children =
						  [{xmlcdata,
						    <<"moderators">>}]}]},
			   #xmlel{name = <<"option">>,
				  attrs =
				      [{<<"label">>,
					translate:translate(Lang,
							    <<"anyone">>)}],
				  children =
				      [#xmlel{name = <<"value">>, attrs = [],
					      children =
						  [{xmlcdata,
						    <<"anyone">>}]}]}]},
	       ?BOOLXFIELD(<<"Allow users to query other users">>,
			   <<"allow_query_users">>,
			   (Config#config.allow_query_users)),
	       ?BOOLXFIELD(<<"Allow users to send invites">>,
			   <<"support#roomconfig_allowinvites">>,
			   (Config#config.allow_user_invites)),
	       ?BOOLXFIELD(<<"Allow visitors to send status text in "
			     "presence updates">>,
			   <<"support#roomconfig_allowvisitorstatus">>,
			   (Config#config.allow_visitor_status)),
	       ?BOOLXFIELD(<<"Allow visitors to change nickname">>,
			   <<"support#roomconfig_allowvisitornickchange">>,
			   (Config#config.allow_visitor_nickchange)),
	       ?BOOLXFIELD(<<"Allow visitors to send voice requests">>,
			   <<"support#roomconfig_allowvoicerequests">>,
			   (Config#config.allow_voice_requests)),
	       ?STRINGXFIELD(<<"Minimum interval between voice requests "
			       "(in seconds)">>,
			     <<"support#roomconfig_voicerequestmininterval">>,
			     (jlib:integer_to_binary(Config#config.voice_request_min_interval)))]
		++
		case ejabberd_captcha:is_feature_available() of
		  true ->
		      [?BOOLXFIELD(<<"Make room CAPTCHA protected">>,
				   <<"captcha_protected">>,
				   (Config#config.captcha_protected))];
		  false -> []
		end
		  ++
		  [?JIDMULTIXFIELD(<<"Exclude Jabber IDs from CAPTCHA challenge">>,
				   <<"support#roomconfig_captcha_whitelist">>,
				   ((?SETS):to_list(Config#config.captcha_whitelist)))]
		    ++
		    case forbiden
		      %mod_support_log:check_access_log(StateData#state.server_host, From)
			of
		      allow ->
			  [?BOOLXFIELD(<<"Enable logging">>,
				       <<"support#roomconfig_enablelogging">>,
				       (Config#config.logging))];
		      _ -> []
		    end,
    {result,
     [#xmlel{name = <<"instructions">>, attrs = [],
	     children =
		 [{xmlcdata,
		   translate:translate(Lang,
				       <<"You need an x:data capable client to "
					 "configure room">>)}]},
      #xmlel{name = <<"x">>,
	     attrs =
		 [{<<"xmlns">>, ?NS_XDATA}, {<<"type">>, <<"form">>}],
	     children = Res}],
     StateData}.

set_config(XEl, StateData) ->
    XData = jlib:parse_xdata_submit(XEl),
    case XData of
      invalid -> {error, ?ERR_BAD_REQUEST};
      _ ->
	  case set_xoption(XData, StateData#state.config) of
	    #config{} = Config ->
		Res = change_config(Config, StateData),
		{result, _, NSD} = Res,
		Type = case {(StateData#state.config)#config.logging,
			     Config#config.logging}
			   of
			 {true, false} -> roomconfig_change_disabledlogging;
			 {false, true} -> roomconfig_change_enabledlogging;
			 {_, _} -> roomconfig_change
		       end,
		Users = [{U#user.jid, U#user.nick, U#user.role}
			 || {_, U} <- (?DICT):to_list(StateData#state.users)],
		add_to_log(Type, Users, NSD),
		Res;
	    Err -> Err
	  end
    end.

-define(SET_BOOL_XOPT(Opt, Val),
	case Val of
	  <<"0">> ->
	      set_xoption(Opts, Config#config{Opt = false});
	  <<"false">> ->
	      set_xoption(Opts, Config#config{Opt = false});
	  <<"1">> -> set_xoption(Opts, Config#config{Opt = true});
	  <<"true">> ->
	      set_xoption(Opts, Config#config{Opt = true});
	  _ -> {error, ?ERR_BAD_REQUEST}
	end).

-define(SET_NAT_XOPT(Opt, Val),
	case catch jlib:binary_to_integer(Val) of
	  I when is_integer(I), I > 0 ->
	      set_xoption(Opts, Config#config{Opt = I});
	  _ -> {error, ?ERR_BAD_REQUEST}
	end).

-define(SET_STRING_XOPT(Opt, Val),
	set_xoption(Opts, Config#config{Opt = Val})).

-define(SET_JIDMULTI_XOPT(Opt, Vals),
	begin
	  Set = lists:foldl(fun ({U, S, R}, Set1) ->
				    (?SETS):add_element({U, S, R}, Set1);
				(#jid{luser = U, lserver = S, lresource = R},
				 Set1) ->
				    (?SETS):add_element({U, S, R}, Set1);
				(_, Set1) -> Set1
			    end,
			    (?SETS):empty(), Vals),
	  set_xoption(Opts, Config#config{Opt = Set})
	end).

set_xoption([], Config) -> Config;
set_xoption([{<<"support#roomconfig_roomname">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_STRING_XOPT(title, Val);
set_xoption([{<<"support#roomconfig_roomdesc">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_STRING_XOPT(description, Val);
set_xoption([{<<"support#roomconfig_changesubject">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(allow_change_subj, Val);
set_xoption([{<<"allow_query_users">>, [Val]} | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(allow_query_users, Val);
set_xoption([{<<"allow_private_messages">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(allow_private_messages, Val);
set_xoption([{<<"allow_private_messages_from_visitors">>,
	      [Val]}
	     | Opts],
	    Config) ->
    case Val of
      <<"anyone">> ->
	  ?SET_STRING_XOPT(allow_private_messages_from_visitors,
			   anyone);
      <<"moderators">> ->
	  ?SET_STRING_XOPT(allow_private_messages_from_visitors,
			   moderators);
      <<"nobody">> ->
	  ?SET_STRING_XOPT(allow_private_messages_from_visitors,
			   nobody);
      _ -> {error, ?ERR_BAD_REQUEST}
    end;
set_xoption([{<<"support#roomconfig_allowvisitorstatus">>,
	      [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(allow_visitor_status, Val);
set_xoption([{<<"support#roomconfig_allowvisitornickchange">>,
	      [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(allow_visitor_nickchange, Val);
set_xoption([{<<"support#roomconfig_publicroom">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(public, Val);
set_xoption([{<<"public_list">>, [Val]} | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(public_list, Val);
set_xoption([{<<"support#roomconfig_persistentroom">>,
	      [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(persistent, Val);
set_xoption([{<<"support#roomconfig_moderatedroom">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(moderated, Val);
set_xoption([{<<"members_by_default">>, [Val]} | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(members_by_default, Val);
set_xoption([{<<"support#roomconfig_membersonly">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(members_only, Val);
set_xoption([{<<"captcha_protected">>, [Val]} | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(captcha_protected, Val);
set_xoption([{<<"support#roomconfig_allowinvites">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(allow_user_invites, Val);
set_xoption([{<<"support#roomconfig_passwordprotectedroom">>,
	      [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(password_protected, Val);
set_xoption([{<<"support#roomconfig_roomsecret">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_STRING_XOPT(password, Val);
set_xoption([{<<"anonymous">>, [Val]} | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(anonymous, Val);
set_xoption([{<<"support#roomconfig_allowvoicerequests">>,
	      [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(allow_voice_requests, Val);
set_xoption([{<<"support#roomconfig_voicerequestmininterval">>,
	      [Val]}
	     | Opts],
	    Config) ->
    ?SET_NAT_XOPT(voice_request_min_interval, Val);
set_xoption([{<<"support#roomconfig_whois">>, [Val]}
	     | Opts],
	    Config) ->
    case Val of
      <<"moderators">> ->
	  ?SET_BOOL_XOPT(anonymous,
			 (iolist_to_binary(integer_to_list(1))));
      <<"anyone">> ->
	  ?SET_BOOL_XOPT(anonymous,
			 (iolist_to_binary(integer_to_list(0))));
      _ -> {error, ?ERR_BAD_REQUEST}
    end;
set_xoption([{<<"support#roomconfig_maxusers">>, [Val]}
	     | Opts],
	    Config) ->
    case Val of
      <<"none">> -> ?SET_STRING_XOPT(max_users, none);
      _ -> ?SET_NAT_XOPT(max_users, Val)
    end;
set_xoption([{<<"support#roomconfig_enablelogging">>, [Val]}
	     | Opts],
	    Config) ->
    ?SET_BOOL_XOPT(logging, Val);
set_xoption([{<<"support#roomconfig_captcha_whitelist">>,
	      Vals}
	     | Opts],
	    Config) ->
    JIDs = [jid:from_string(Val) || Val <- Vals],
    ?SET_JIDMULTI_XOPT(captcha_whitelist, JIDs);
set_xoption([{<<"FORM_TYPE">>, _} | Opts], Config) ->
    set_xoption(Opts, Config);
set_xoption([_ | _Opts], _Config) ->
    {error, ?ERR_BAD_REQUEST}.

change_config(Config, StateData) ->
    StateData1 = StateData#state{config = Config},
    StateData2 =
        case {(StateData#state.config)#config.persistent,
              Config#config.persistent} of
            {WasPersistent, true} ->
                if not WasPersistent ->
                        set_affiliations(StateData1#state.affiliations,
                                         StateData1);
                   true ->
                        ok
                end,
                mod_support:store_room(StateData1#state.server_host,
                                   StateData1#state.host, StateData1#state.room,
                                   make_opts(StateData1),
                                   make_affiliations(StateData1)),
                StateData1;
            {true, false} ->
                Affiliations = get_affiliations(StateData),
                mod_support:forget_room(StateData1#state.server_host,
                                    StateData1#state.host,
                                    StateData1#state.room),
                StateData1#state{affiliations = Affiliations};
            {false, false} ->
                StateData1
        end,
    case {(StateData#state.config)#config.members_only,
	  Config#config.members_only} of
        {false, true} ->
            StateData3 = remove_nonmembers(StateData2),
            {result, [], StateData3};
        _ ->
            {result, [], StateData2}
    end.

remove_nonmembers(StateData) ->
    lists:foldl(fun ({_LJID, #user{jid = JID}}, SD) ->
			Affiliation = get_affiliation(JID, SD),
			case Affiliation of
			  none ->
			      catch send_kickban_presence(JID, <<"">>,
							  <<"322">>, SD),
			      set_role(JID, none, SD);
			  _ -> SD
			end
		end,
		StateData, (?DICT):to_list(StateData#state.users)).

kick_users_from_banned_server(#jid{luser = <<"">>, lserver = BannedServer},
			      Reason, StateData) ->
    lists:foldl(
      fun({_LJID, #user{jid = JID}}, SD) when JID#jid.lserver == BannedServer ->
	      Aff = get_affiliation(JID, SD),
	      if Aff /= owner, Aff /= admin, Aff /= member ->
		      catch send_kickban_presence(JID, Reason,
						  <<"301">>, outcast, SD),
		      set_role(JID, none, SD);
		 true ->
		      SD
	      end;
	 (_, SD) ->
	      SD
      end, StateData, ?DICT:to_list(StateData#state.users));
kick_users_from_banned_server(_JID, _Reason, StateData) ->
    StateData.

set_opts([], StateData) -> StateData;
set_opts([{Opt, Val} | Opts], StateData) ->
    NSD = case Opt of
	    title ->
		StateData#state{config =
				    (StateData#state.config)#config{title =
									Val}};
	    description ->
		StateData#state{config =
				    (StateData#state.config)#config{description
									= Val}};
	    allow_change_subj ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_change_subj
									= Val}};
	    allow_query_users ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_query_users
									= Val}};
	    allow_private_messages ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_private_messages
									= Val}};
	    allow_private_messages_from_visitors ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_private_messages_from_visitors
									= Val}};
	    allow_visitor_nickchange ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_visitor_nickchange
									= Val}};
	    allow_visitor_status ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_visitor_status
									= Val}};
	    public ->
		StateData#state{config =
				    (StateData#state.config)#config{public =
									Val}};
	    public_list ->
		StateData#state{config =
				    (StateData#state.config)#config{public_list
									= Val}};
	    persistent ->
		StateData#state{config =
				    (StateData#state.config)#config{persistent =
									Val}};
	    moderated ->
		StateData#state{config =
				    (StateData#state.config)#config{moderated =
									Val}};
	    members_by_default ->
		StateData#state{config =
				    (StateData#state.config)#config{members_by_default
									= Val}};
	    members_only ->
		StateData#state{config =
				    (StateData#state.config)#config{members_only
									= Val}};
	    allow_user_invites ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_user_invites
									= Val}};
	    password_protected ->
		StateData#state{config =
				    (StateData#state.config)#config{password_protected
									= Val}};
	    captcha_protected ->
		StateData#state{config =
				    (StateData#state.config)#config{captcha_protected
									= Val}};
	    password ->
		StateData#state{config =
				    (StateData#state.config)#config{password =
									Val}};
	    anonymous ->
		StateData#state{config =
				    (StateData#state.config)#config{anonymous =
									Val}};
	    logging ->
		StateData#state{config =
				    (StateData#state.config)#config{logging =
									Val}};
	    captcha_whitelist ->
		StateData#state{config =
				    (StateData#state.config)#config{captcha_whitelist
									=
									(?SETS):from_list(Val)}};
	    allow_voice_requests ->
		StateData#state{config =
				    (StateData#state.config)#config{allow_voice_requests
									= Val}};
	    voice_request_min_interval ->
		StateData#state{config =
				    (StateData#state.config)#config{voice_request_min_interval
									= Val}};
	    max_users ->
		ServiceMaxUsers = get_service_max_users(StateData),
		MaxUsers = if Val =< ServiceMaxUsers -> Val;
			      true -> ServiceMaxUsers
			   end,
		StateData#state{config =
				    (StateData#state.config)#config{max_users =
									MaxUsers}};
	    vcard ->
		StateData#state{config =
				    (StateData#state.config)#config{vcard =
									Val}};
	    affiliations ->
		StateData#state{affiliations = (?DICT):from_list(Val)};
	    subject -> StateData#state{subject = Val};
	    subject_author -> StateData#state{subject_author = Val};
	    _ -> StateData
	  end,
    set_opts(Opts, NSD).

make_affiliations(StateData) ->
    (?DICT):to_list(StateData#state.affiliations).

make_opts(StateData) ->
    Config = StateData#state.config,
    DefConfig = #config{},
    Fields = record_info(fields, config),
    {_, Opts1} =
        lists:foldl(
          fun(Field, {Pos, L}) ->
                  V = element(Pos, Config),
                  DefV = element(Pos, DefConfig),
                  Val = case (?SETS):is_set(V) of
                            true -> (?SETS):to_list(V);
                            false -> V
                        end,
                  DefVal = case (?SETS):is_set(DefV) of
                               true -> (?SETS):to_list(DefV);
                               false -> DefV
                           end,
                  if Val == DefVal ->
                          {Pos+1, L};
                     true ->
                          {Pos+1, [{Field, Val}|L]}
                  end
          end, {2, []}, Fields),
    Opts2 = lists:reverse(Opts1),
    Opts3 = case StateData#state.subject_author of
                <<"">> -> Opts2;
                SubjectAuthor -> [{subject_author, SubjectAuthor}|Opts2]
            end,
    Opts4 = case StateData#state.subject of
                <<"">> -> Opts3;
                Subject -> [{subject, Subject}|Opts3]
            end,
    Opts4.

expand_opts(CompactOpts) ->
    DefConfig = #config{},
    Fields = record_info(fields, config),
    {_, Opts1} =
        lists:foldl(
          fun(Field, {Pos, Opts}) ->
                  case lists:keyfind(Field, 1, CompactOpts) of
                      false ->
                          DefV = element(Pos, DefConfig),
                          DefVal = case (?SETS):is_set(DefV) of
                                       true -> (?SETS):to_list(DefV);
                                       false -> DefV
                                   end,
                          {Pos+1, [{Field, DefVal}|Opts]};
                      {_, Val} ->
                          {Pos+1, [{Field, Val}|Opts]}
                  end
          end, {2, []}, Fields),
    SubjectAuthor = proplists:get_value(subject_author, CompactOpts, <<"">>),
    Subject = proplists:get_value(subject, CompactOpts, <<"">>),
    [{subject, Subject},
     {subject_author, SubjectAuthor}
     | lists:reverse(Opts1)].

config_fields() ->
    [subject, subject_author | record_info(fields, config)].

%% Part of P1DB/SQL schema value encoding/decoding
decode_opts(_, Bin) ->
    CompactOpts = binary_to_term(Bin),
    Opts = expand_opts(CompactOpts),
    lists:map(
      fun({_Key, Val}) ->
              if is_atom(Val) ->
                      jlib:atom_to_binary(Val);
                 is_integer(Val) ->
                      Val;
                 is_binary(Val) ->
                      Val;
                 true ->
                      jlib:term_to_expr(Val)
              end
      end, Opts).

encode_opts(_, Vals) ->
    Opts = lists:map(
             fun({Key, BinVal}) ->
                     Val = case Key of
                               subject -> BinVal;
                               subject_author -> BinVal;
                               title -> BinVal;
                               description -> BinVal;
                               password -> BinVal;
                               voice_request_min_interval ->
                                   BinVal;
                               max_users when BinVal == <<"none">> ->
                                   none;
                               max_users ->
                                   BinVal;
			       vcard ->
				   BinVal;
			       hibernate_time ->
				   BinVal;
                               captcha_whitelist ->
                                   jlib:expr_to_term(BinVal);
                               _ ->
                                   jlib:binary_to_atom(BinVal)
                           end,
                     {Key, Val}
             end, lists:zip(config_fields(), Vals)),
    term_to_binary(Opts).

destroy_room(DEl, StateData) ->
    lists:foreach(fun ({_LJID, Info}) ->
			  Nick = Info#user.nick,
			  ItemAttrs = [{<<"affiliation">>, <<"none">>},
				       {<<"role">>, <<"none">>}],
			  Packet = #xmlel{name = <<"presence">>,
					  attrs =
					      [{<<"type">>, <<"unavailable">>}],
					  children =
					      [#xmlel{name = <<"x">>,
						      attrs =
							  [{<<"xmlns">>,
							    ?NS_SUPPORT_USER}],
						      children =
							  [#xmlel{name =
								      <<"item">>,
								  attrs =
								      ItemAttrs,
								  children =
								      []},
							   DEl]}]},
			  route_stanza(jid:replace_resource(StateData#state.jid,
								 Nick),
				       Info#user.jid, Packet)
		  end,
		  (?DICT):to_list(StateData#state.users)),
    case (StateData#state.config)#config.persistent of
      true ->
	  mod_support:forget_room(StateData#state.server_host,
			      StateData#state.host, StateData#state.room);
      false -> ok
    end,
    {result, [], stop}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Disco

-define(FEATURE(Var),
	#xmlel{name = <<"feature">>, attrs = [{<<"var">>, Var}],
	       children = []}).

-define(CONFIG_OPT_TO_FEATURE(Opt, Fiftrue, Fiffalse),
	case Opt of
	  true -> ?FEATURE(Fiftrue);
	  false -> ?FEATURE(Fiffalse)
	end).

process_iq_disco_info(_From, set, _Lang, _StateData) ->
    {error, ?ERR_NOT_ALLOWED};
process_iq_disco_info(_From, get, Lang, StateData) ->
    Config = StateData#state.config,
    {result,
     [#xmlel{name = <<"identity">>,
	     attrs =
		 [{<<"category">>, <<"conference">>},
		  {<<"type">>, <<"text">>},
		  {<<"name">>, get_title(StateData)}],
	     children = []},
      #xmlel{name = <<"feature">>,
	     attrs = [{<<"var">>, ?NS_VCARD}], children = []},
      #xmlel{name = <<"feature">>,
	     attrs = [{<<"var">>, ?NS_SUPPORT}], children = []},
      ?CONFIG_OPT_TO_FEATURE((Config#config.public),
			     <<"support_public">>, <<"support_hidden">>),
      ?CONFIG_OPT_TO_FEATURE((Config#config.persistent),
			     <<"support_persistent">>, <<"support_temporary">>),
      ?CONFIG_OPT_TO_FEATURE((Config#config.members_only),
			     <<"support_membersonly">>, <<"support_open">>),
      ?CONFIG_OPT_TO_FEATURE((Config#config.anonymous),
			     <<"support_semianonymous">>, <<"support_nonanonymous">>),
      ?CONFIG_OPT_TO_FEATURE((Config#config.moderated),
			     <<"support_moderated">>, <<"support_unmoderated">>),
      ?CONFIG_OPT_TO_FEATURE((Config#config.password_protected),
			     <<"support_passwordprotected">>, <<"support_unsecured">>)]
       ++ iq_disco_info_extras(Lang, StateData),
     StateData}.

-define(RFIELDT(Type, Var, Val),
	#xmlel{name = <<"field">>,
	       attrs = [{<<"type">>, Type}, {<<"var">>, Var}],
	       children =
		   [#xmlel{name = <<"value">>, attrs = [],
			   children = [{xmlcdata, Val}]}]}).

-define(RFIELD(Label, Var, Val),
	#xmlel{name = <<"field">>,
	       attrs =
		   [{<<"label">>, translate:translate(Lang, Label)},
		    {<<"var">>, Var}],
	       children =
		   [#xmlel{name = <<"value">>, attrs = [],
			   children = [{xmlcdata, Val}]}]}).

iq_disco_info_extras(Lang, StateData) ->
    Len = (?DICT):size(StateData#state.users),
    RoomDescription =
	(StateData#state.config)#config.description,
    [#xmlel{name = <<"x">>,
	    attrs =
		[{<<"xmlns">>, ?NS_XDATA}, {<<"type">>, <<"result">>}],
	    children =
		[?RFIELDT(<<"hidden">>, <<"FORM_TYPE">>,
			  <<"p1:support#roominfo">>),
		 ?RFIELD(<<"Room description">>,
			 <<"support#roominfo_description">>, RoomDescription),
		 ?RFIELD(<<"Number of occupants">>,
			 <<"support#roominfo_occupants">>,
			 (iolist_to_binary(integer_to_list(Len))))]}].

process_iq_disco_items(_From, set, _Lang, _StateData) ->
    {error, ?ERR_NOT_ALLOWED};
process_iq_disco_items(From, get, _Lang, StateData) ->
    case (StateData#state.config)#config.public_list of
      true ->
	  {result, get_supportroom_disco_items(StateData), StateData};
      _ ->
	  case is_occupant_or_admin(From, StateData) of
	    true ->
		{result, get_supportroom_disco_items(StateData), StateData};
	    _ -> {error, ?ERR_FORBIDDEN}
	  end
    end.

process_iq_captcha(_From, get, _Lang, _SubEl,
		   _StateData) ->
    {error, ?ERR_NOT_ALLOWED};
process_iq_captcha(_From, set, _Lang, SubEl,
		   StateData) ->
    case ejabberd_captcha:process_reply(SubEl) of
      ok -> {result, [], StateData};
      _ -> {error, ?ERR_NOT_ACCEPTABLE}
    end.

process_iq_vcard(_From, get, _Lang, _SubEl, StateData) ->
    #state{config = #config{vcard = VCardRaw}} = StateData,
    case fxml_stream:parse_element(VCardRaw) of
	#xmlel{children = VCardEls} ->
	    {result, VCardEls, StateData};
	{error, _} ->
	    {result, [], StateData}
    end;
process_iq_vcard(From, set, Lang, SubEl, StateData) ->
    case get_affiliation(From, StateData) of
	owner ->
	    VCardRaw = fxml:element_to_binary(SubEl),
	    Config = StateData#state.config,
	    NewConfig = Config#config{vcard = VCardRaw},
	    change_config(NewConfig, StateData);
	_ ->
	    ErrText = <<"Owner privileges required">>,
	    {error, ?ERRT_FORBIDDEN(Lang, ErrText)}
    end.

get_title(StateData) ->
    case (StateData#state.config)#config.title of
      <<"">> -> StateData#state.room;
      Name -> Name
    end.

get_roomdesc_reply(JID, StateData, Tail) ->
    IsOccupantOrAdmin = is_occupant_or_admin(JID,
					     StateData),
    if (StateData#state.config)#config.public or
	 IsOccupantOrAdmin ->
	   if (StateData#state.config)#config.public_list or
		IsOccupantOrAdmin ->
		  {item, <<(get_title(StateData))/binary,Tail/binary>>};
	      true -> {item, get_title(StateData)}
	   end;
       true -> false
    end.

get_roomdesc_tail(StateData, Lang) ->
    Desc = case (StateData#state.config)#config.public of
	     true -> <<"">>;
	     _ -> translate:translate(Lang, <<"private, ">>)
	   end,
    Len = (?DICT):fold(fun (_, _, Acc) -> Acc + 1 end, 0,
		       StateData#state.users),
    <<" (", Desc/binary,
      (iolist_to_binary(integer_to_list(Len)))/binary, ")">>.

get_supportroom_disco_items(StateData) ->
    lists:map(fun ({_LJID, Info}) ->
		      Nick = Info#user.nick,
		      #xmlel{name = <<"item">>,
			     attrs =
				 [{<<"jid">>,
				   jid:to_string({StateData#state.room,
						       StateData#state.host,
						       Nick})},
				  {<<"name">>, Nick}],
			     children = []}
	      end,
	      (?DICT):to_list(StateData#state.users)).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Logging

add_to_log(_Type, _Data, _StateData) ->
    ok.

%% add_to_log(Type, Data, StateData)
%%     when false andalso Type == roomconfig_change_disabledlogging ->
%%     mod_support_log:add_to_log(StateData#state.server_host,
%% 			   roomconfig_change, Data, StateData#state.jid,
%% 			   make_opts(StateData));
%% add_to_log(Type, Data, StateData) ->
%%     case false andalso (StateData#state.config)#config.logging of
%%       true ->
%% 	  mod_support_log:add_to_log(StateData#state.server_host,
%% 				 Type, Data, StateData#state.jid,
%% 				 make_opts(StateData));
%%       false -> ok
%%     end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Users number checking

tab_add_online_user(JID, StateData) ->
    {LUser, LServer, LResource} = jid:tolower(JID),
    US = {LUser, LServer},
    Room = StateData#state.room,
    Host = StateData#state.host,
    catch ets:insert(support_online_users,
		     #support_online_users{us = US, resource = LResource,
				       room = Room, host = Host}).

tab_remove_online_user(JID, StateData) ->
    {LUser, LServer, LResource} = jid:tolower(JID),
    US = {LUser, LServer},
    Room = StateData#state.room,
    Host = StateData#state.host,
    catch ets:delete_object(support_online_users,
			    #support_online_users{us = US, resource = LResource,
					      room = Room, host = Host}).

tab_count_user(JID) ->
    {LUser, LServer, _} = jid:tolower(JID),
    US = {LUser, LServer},
    case catch ets:select(support_online_users,
			  [{#support_online_users{us = US, _ = '_'}, [], [[]]}])
	of
      Res when is_list(Res) -> length(Res);
      _ -> 0
    end.

element_size(El) -> byte_size(fxml:element_to_binary(El)).

fsm_limit_opts() ->
    case ejabberd_config:get_option(
           max_fsm_queue,
           fun(I) when is_integer(I), I > 0 -> I end) of
        undefined -> [];
        N -> [{max_queue, N}]
    end.

route_stanza(From, To, El) ->
    ejabberd_router:route(From, To, El).

set_hibernate_timer_if_empty(StateData) ->
    case ?DICT:size(StateData#state.users) of
	0 ->
	    ?GEN_FSM:cancel_timer(StateData#state.hibernate_timer),
	    Timeout = gen_mod:get_module_opt(StateData#state.server_host,
					     mod_support, hibernate_timeout,
					     fun(I) when is_integer(I), I>0 ->
						     I
					     end, undefined),
	    if Timeout /= undefined ->
		    TRef = ?GEN_FSM:send_event_after(
			      timer:seconds(Timeout), hibernate),
		    StateData#state{hibernate_timer = TRef};
	       true ->
		    StateData
	    end;
	_ ->
	    StateData
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Multicast

send_multiple(From, Server, Users, Packet) ->
    JIDs = [ User#user.jid || {_, User} <- ?DICT:to_list(Users)],
    ejabberd_router_multicast:route_multicast(From, Server, JIDs, Packet).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Detect messange stanzas that don't have meaninful content

has_body_or_subject(Packet) ->
    [] /= lists:dropwhile(fun
	(#xmlel{name = <<"body">>}) -> false;
	(#xmlel{name = <<"subject">>}) -> false;
	(_) -> true
    end, Packet#xmlel.children).

treap_size(Queue) ->
    treap:fold(fun(_, Acc) -> Acc+1 end, 0, Queue).

opt_type(max_fsm_queue) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(_) -> [max_fsm_queue].
