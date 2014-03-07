%%%----------------------------------------------------------------------
%%% File    : mod_muc_light.erl
%%% Author  :
%%% Purpose : Tools for additional MUC administration
%%% Created : 8 Sep 2007 by Badlop <badlop@ono.com>
%%%----------------------------------------------------------------------

%%% Enable the module, and configure its option senderjid with the JID of
%%% a user with admin rights in mod_muc. For example, this allows the
%%% account mucadminuser@localhost to administer the MUC service, and that
%%% account is used to send the kick stanzas in the commands
%%% muc_remove_member and muc_kick_user:
%%%
%%% acl:
%%%   mucbots:
%%%     user:
%%%       - "mucadminuser": "localhost"
%%%
%%% access:
%%%   muc_admin:
%%%     admin: allow
%%%     mucbots: allow
%%%
%%% modules:
%%%   mod_muc:
%%%     access_admin: muc_admin
%%%   mod_muc_light:
%%%     senderjid: "mucadminuser@localhost"


-module(mod_muc_light).

-behaviour(gen_mod).

-export([
	 start/2, stop/1, % gen_mod API
	 muc_create_room/3,
	 muc_add_member/3,
	 muc_remove_member/3,
	 muc_kick_user/3,
	 muc_send_system_message/4,
	 muc_purge_archive/2,
         get_senderjid/1,
	 kick_user/1
	]).

%-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("mod_muc_room.hrl").
-include("ejabberd_commands.hrl").

%%----------------------------
%% gen_mod
%%----------------------------

start(Host, _Opts) ->
    ejabberd_commands:register_commands(commands()).

stop(Host) ->
    ejabberd_commands:unregister_commands(commands()).

%%%
%%% Register commands
%%%

commands() ->
    [
     #ejabberd_commands{name = muc_create_room, tags = [muc_room],
		       desc = "Create MUC room jid-room if room doesn’t exist"
				" add jid-user to member list, "
				" if previous step fails, destroy the room, "
				" returns 0 in res field if rooms exists, else returns 1",
		       module = ?MODULE, function = muc_create_room,
		       args = [{jid_room, binary}, {host, binary}, {jid_user, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_add_member, tags = [muc_room],
		       desc = "Add jid-user to member list of MUC room jid-room "
			    "if he’s not already part of it. Returns 0 in res field if "
			    "jid-user is in the member list, else returns 1.",
		       module = ?MODULE, function = muc_add_member,
		       args = [{jid_room, binary}, {host, binary}, {jid_user, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_remove_member, tags = [muc_room],
		       desc = "Remove jid-user from member list of MUC room jid-room "
			    "if he’s already part of it. "
			    "Remove jid-user from the occupant list if he's in the room.",
		       module = ?MODULE, function = muc_remove_member,
		       args = [{jid_room, binary}, {host, binary}, {jid_user, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_kick_user, tags = [muc_room],
		       desc = "Remove jid-user from the occupant list of MUC room "
			    "jid-room if he’s already part of it."
			    "Returns 0 in res field if jid-user is not in the "
			    "occupant list, returns 1 in case of failure.",
		       module = ?MODULE, function = muc_kick_user,
		       args = [{jid_room, binary}, {host, binary}, {jid_user, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_send_system_message, tags = [muc_room],
		       desc = "Send system messages to a MUC room with custom XML payload.",
		       module = ?MODULE, function = muc_send_system_message,
		       args = [{jid_room, binary}, {host, binary}, {body, binary}, {activity, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_purge_archive, tags = [muc_room],
		       desc = "Remove messages older than DAYS in the arhive.",
		       module = ?MODULE, function = muc_purge_archive,
		       args = [{host, binary}, {days, integer}],
		       result = {res, restuple}},

     #ejabberd_commands{name = kick_user, tags = [muc_room],
		       desc = "Kill session of jid-user "
			    "Returns 0 in res field if jid-user is not in the "
			    "occupant list, returns 1 in case of failure.",
		       module = ?MODULE, function = kick_user,
		       args = [{jid_user, binary}],
		       result = {res, restuple}}
    ].

%%
%% muc-create-room
%%
muc_create_room(RoomString, RoomHost, UserString) ->
    SenderJid = get_senderjid(RoomHost),
    RoomJid = jlib:string_to_jid(RoomString),
    RoomStringNick = jlib:jid_to_string(jlib:jid_replace_resource(RoomJid, SenderJid#jid.luser)),
    XmlEl = build_room_stanza(UserString, RoomStringNick),
    ejabberd_router:route(SenderJid, RoomJid, XmlEl),
    timer:sleep(1000),
    case check_room_exists(RoomJid#jid.luser, RoomJid#jid.lserver) of
	true ->
	    muc_create_room_opts(RoomString, RoomHost, UserString),
	    muc_add_member(RoomString, RoomHost, UserString),
	    {ok, ""};
	false ->
	    ?INFO_MSG("Problem creating the room ~p", [RoomString]),
	    {104, io_lib:format("Some problem was found when creating the room ~p.", [binary_to_list(RoomString)])}
    end.

build_room_stanza(UserString, RoomStringNick) ->
    XAttrs = [{<<"xmlns">>, ?NS_MUC}],
    El = {xmlel, <<"x">>, XAttrs, []},
    Attrs = [{<<"to">>,RoomStringNick}],
    {xmlel, <<"presence">>, Attrs, [El]}.

check_room_exists(Name, Host) ->
    case mnesia:dirty_read(muc_online_room, {Name, Host}) of
        [] -> false;
	_ -> true
    end.

muc_create_room_opts(RoomString, RoomHost, UserString) ->
    SenderJid = get_senderjid(RoomHost),
    RoomJid = jlib:string_to_jid(RoomString),
    XmlEl = build_roomopts_stanza(UserString, RoomString),
    ejabberd_router:route(SenderJid, RoomJid, XmlEl).

build_roomopts_stanza(UserString, RoomString) ->
    XXAttrs = [{<<"type">>, <<"submit">>},
	{<<"xmlns">>, ?NS_XDATA}],
    XEl = {xmlel, <<"x">>, XXAttrs, []},
    XAttrs = [{<<"xmlns">>, ?NS_MUC_OWNER}],
    El = {xmlel, <<"query">>, XAttrs, [XEl]},
    Attrs = [{<<"type">>,<<"set">>},
        {<<"to">>,RoomString}],
    {xmlel, <<"iq">>, Attrs, [El]}.

%%
%% muc-add-member
%%
muc_add_member(RoomString, RoomHost, UserString) ->
    SenderJid = get_senderjid(RoomHost),
    RoomJid = jlib:string_to_jid(RoomString),
    XmlEl = build_member_stanza(UserString, RoomString),
    ejabberd_router:route(SenderJid, RoomJid, XmlEl),
    {ok, ""}.

build_member_stanza(UserString, RoomString) ->
    XXAttrs = [{<<"affiliation">>, <<"member">>},
	{<<"jid">>,UserString}],
    XEl = {xmlel, <<"item">>, XXAttrs, []},
    XAttrs = [{<<"xmlns">>, ?NS_MUC_ADMIN}],
    El = {xmlel, <<"query">>, XAttrs, [XEl]},
    Attrs = [{<<"type">>,<<"set">>},
        {<<"to">>,RoomString}],
    {xmlel, <<"iq">>, Attrs, [El]}.

%%
%% muc-remove-member
%%
muc_remove_member(RoomString, RoomHost, UserString) ->
    SenderJid = get_senderjid(RoomHost),
    RoomJid = jlib:string_to_jid(RoomString),
    XmlEl = build_demember_stanza(UserString, RoomString),
    ejabberd_router:route(SenderJid, RoomJid, XmlEl),
    {ok, ""}.

build_demember_stanza(UserString, RoomString) ->
    XXAttrs = [{<<"affiliation">>, <<"none">>},
	{<<"jid">>,UserString}],
    XEl = {xmlel, <<"item">>, XXAttrs, []},
    XAttrs = [{<<"xmlns">>, ?NS_MUC_ADMIN}],
    El = {xmlel, <<"query">>, XAttrs, [XEl]},
    Attrs = [{<<"type">>,<<"set">>},
        {<<"to">>,RoomString}],
    {xmlel, <<"iq">>, Attrs, [El]}.

%%
%% muc-kick-user
%%
muc_kick_user(RoomString, RoomHost, UserString) ->
    SenderJid = get_senderjid(RoomHost),
    RoomJid = jlib:string_to_jid(RoomString),
    Nick = get_occupant_nick(RoomJid, UserString),
    XmlEl = build_kick_stanza(Nick, RoomString),
    case Nick of
	occupant_not_found -> ok;
	Nick -> ejabberd_router:route(SenderJid, RoomJid, XmlEl)
    end,
    {ok, ""}.

get_occupant_nick(RoomJid, UserString) ->
    Occupants = get_room_occupants(RoomJid#jid.luser, RoomJid#jid.lserver),
    List = lists:dropwhile(fun({Fulljid, Nick, Role}) ->
	    A = binary:longest_common_prefix([Fulljid, UserString]),
	    B = size(UserString),
	    A /= B
	end,
	Occupants),
    case List of
	[{_, Nick, _} | _ ] -> Nick;
	_ -> occupant_not_found
    end.

build_kick_stanza(Nick, RoomString) ->
    XXAttrs = [{<<"role">>, <<"none">>},
	{<<"nick">>,Nick}],
    XEl = {xmlel, <<"item">>, XXAttrs, []},
    XAttrs = [{<<"xmlns">>, ?NS_MUC_ADMIN}],
    El = {xmlel, <<"query">>, XAttrs, [XEl]},
    Attrs = [{<<"type">>,<<"set">>},
        {<<"to">>,RoomString}],
    {xmlel, <<"iq">>, Attrs, [El]}.

%% Copied from mod_muc_admin

%% Copied from mod_muc/mod_muc.erl
-record(muc_online_room,
        {name_host = {<<"">>, <<"">>} :: {binary(), binary()} | {'_', '$1'} | '$1' | '_',
         timestamp = now() :: erlang:timestamp() | '_',
         pid = self() :: pid() | '$1' | '$2' | '_'}).

get_room_occupants(Room, Host) ->
    case get_room_pid(Room, Host) of
        room_not_found -> throw({error, room_not_found});
        Pid -> get_room_occupants(Pid)
    end.

get_room_occupants(Pid) ->
    S = get_room_state(Pid),
    lists:map(
      fun({_LJID, Info}) ->
              {jlib:jid_to_string(Info#user.jid),
               Info#user.nick,
               atom_to_list(Info#user.role)}
      end,
      dict:to_list(S#state.users)).

%% @doc Get the Pid of an existing MUC room, or 'room_not_found'.
get_room_pid(Name, Service) ->
    case mnesia:dirty_read(muc_online_room, {Name, Service}) of
        [] ->
            room_not_found;
        [Room] ->
            Room#muc_online_room.pid
    end.

get_room_state(Room_pid) ->
    {ok, R} = gen_fsm:sync_send_all_state_event(Room_pid, get_state),
    R.


%%
%% muc-purge-archive
%%
%% Note: this code assumes odbc storage is used for the archive table.
muc_purge_archive(RoomHost, Days) ->
    TimestampLimit = get_timestamp_n_days_ago(Days),
    ?INFO_MSG("Messages older than ~p will be removed",
	[jlib:now_to_utc_string(usec_to_now(TimestampLimit))]),
    TimestampBin = jlib:integer_to_binary(TimestampLimit),
    ejabberd_odbc:sql_query(RoomHost,
                            [<<"delete from archive where timestamp<'">>,
			     TimestampBin, <<"';">>]),
    {ok, ""}.

get_timestamp_n_days_ago(Days) ->
    NowUsec = now_to_usec(os:timestamp()),
    DiffUsec = now_to_usec({0, Days*24*60*60, 0}),
    NowUsec - DiffUsec.

%% Copied from mod_mam.erl
now_to_usec({MSec, Sec, USec}) ->
    (MSec*1000000 + Sec)*1000000 + USec.
usec_to_now(Int) ->
    Secs = Int div 1000000,
    USec = Int rem 1000000,
    MSec = Secs div 1000000,
    Sec = Secs rem 1000000,
    {MSec, Sec, USec}.


%%
%% muc-send-system-message
%%
muc_send_system_message(RoomString, RoomHost, BodyBin, Activity) ->
    SenderJid = get_senderjid(RoomHost),
    RoomJid = jlib:string_to_jid(RoomString),
    case xml_stream:parse_element(Activity) of
	{xmlel, _, _, _} = ActivityEl ->
	    XmlEl = build_systemmessage_stanza(BodyBin, ActivityEl, RoomString),
	    ejabberd_router:route(SenderJid, RoomJid, XmlEl),
	    ejabberd_hooks:run_fold(
	      user_send_packet, RoomHost,
	      XmlEl, [no_state_data, SenderJid, RoomJid]),
	    {ok, ""};
	{error,_} ->
	    {103, io_lib:format("Problem parsing XML in the Activity argument: ~p", [binary_to_list(Activity)])}
    end.

build_systemmessage_stanza(BodyBin, ActivityEl, RoomString) ->
    XEl = {xmlcdata, BodyBin},
    BodyEl = {xmlel, <<"body">>, [], [XEl]},
    Attrs = [{<<"type">>,<<"groupchat">>},
        {<<"to">>,RoomString}],
    {xmlel, <<"message">>, Attrs, [BodyEl,ActivityEl]}.


get_senderjid(RoomHost) ->
    SenderJidBinary = gen_mod:get_module_opt(
                        RoomHost, ?MODULE,
                        senderjid, fun(X) -> X end, ""),
    SenderJid = jlib:string_to_jid(SenderJidBinary),
    SenderJid.

%%
%% muc-kick-user
%%
kick_user(JID) ->
    {User, Server, _R} = jlib:string_to_usr(JID),
    Resources = ejabberd_sm:get_user_resources(User, Server),
    lists:foreach(fun(Resource) ->
			  {LUser, LServer, LResource} =
			      jlib:jid_tolower({User, Server, Resource}),
			  C2SPid = ejabberd_sm:get_session_pid(
				     LUser, LServer, LResource),
			  catch ejabberd_c2s:stop_or_detach(C2SPid)
		  end,
		  Resources),
    {ok, ""}.
