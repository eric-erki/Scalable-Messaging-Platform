%%%----------------------------------------------------------------------
%%% File    : mod_muc_light.erl
%%% Author  :
%%% Purpose : Tools for additional MUC administration
%%% Created : 8 Sep 2007 by Badlop <badlop@ono.com>
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

-export([start/2, stop/1, muc_create_room/3,
	 muc_delete_room/2, muc_add_member/3,
	 muc_remove_member/3, muc_kick_user/3,
	 muc_send_system_message/4, muc_purge_archive/2,
	 get_senderjid/1, kick_user/1, mod_opt_type/1,
	 get_commands_spec/0, depends/2]).

%-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("mod_muc_room.hrl").
-include("mod_muc.hrl").
-include("ejabberd_commands.hrl").

%%----------------------------
%% gen_mod
%%----------------------------

start(_Host, _Opts) ->
    ejabberd_commands:register_commands(get_commands_spec()).

stop(_Host) ->
    ejabberd_commands:unregister_commands(get_commands_spec()).

%%%
%%% Register commands
%%%

get_commands_spec() ->
    [
     #ejabberd_commands{name = muc_create_room, tags = [muc_room],
		       desc = "Create MUC room jid-room if room doesn't exist"
				" add jid-user to member list, "
				" if previous step fails, destroy the room, "
				" returns 0 in res field if rooms exists, else returns 1",
		       module = ?MODULE, function = muc_create_room,
		       args = [{jid_room, binary}, {host, binary}, {jid_user, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_delete_room, tags = [muc_room],
		       desc = "Delete MUC room jid-room if room exist",
		       module = ?MODULE, function = muc_delete_room,
		       args = [{jid_room, binary}, {reason, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_add_member, tags = [muc_room],
		       desc = "Add jid-user to member list of MUC room jid-room "
			    "if he's not already part of it. Returns 0 in res field if "
			    "jid-user is in the member list, else returns 1.",
		       module = ?MODULE, function = muc_add_member,
		       args = [{jid_room, binary}, {host, binary}, {jid_user, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_remove_member, tags = [muc_room],
		       desc = "Remove jid-user from member list of MUC room jid-room "
			    "if he's already part of it. "
			    "Remove jid-user from the occupant list if he's in the room.",
		       module = ?MODULE, function = muc_remove_member,
		       args = [{jid_room, binary}, {host, binary}, {jid_user, binary}],
		       result = {res, restuple}},

     #ejabberd_commands{name = muc_kick_user, tags = [muc_room],
		       desc = "Remove jid-user from the occupant list of MUC room "
			    "jid-room if he's already part of it."
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

%% Adapted from muc_create_room/3
muc_delete_room(RoomJid, <<>>) ->
    muc_delete_room(RoomJid, none);
muc_delete_room(RoomJid, Reason) ->
    #jid{luser = RoomName, lserver = Host} = jid:from_string(RoomJid),
    %%TODO: check get_room_pid/2 . It is working well on cluster?  table muc_online_room is set to local_content
    case get_room_pid(RoomName, Host) of
        room_not_found ->
            {104, "Room not found"};
        RoomPid when is_pid(RoomPid) ->
	        gen_fsm:send_all_state_event(RoomPid, {destroy, Reason}),
            {ok, ""}
    end.


%%
%% muc-create-room
%%
muc_create_room(RoomString, RoomHost, UserString) ->
    #jid{luser = U, lserver = S} = From = jid:from_string(UserString),
    Nodes = lists:flatmap(
	      fun(R) ->
		      case ejabberd_sm:get_session_pid(U, S, R) of
			  none -> [];
			  Pid -> [node(Pid)]
		      end
	      end, ejabberd_sm:get_user_resources(U, S)),
    case Nodes of
	[Node|_] ->
	    #jid{luser = Name} = jid:from_string(RoomString),
	    Host = iolist_to_binary(RoomHost),
	    Nick = From#jid.luser,
	    case catch ejabberd_cluster:call(Node, mod_muc, create_room,
					     [Host, Name, From, Nick, default]) of
		ok ->
		    {ok, ""};
		Err ->
		    ErrTxt = lists:flatten(
			       io_lib:format(
				 "failed to create room ~s for ~s: ~p",
				 [RoomString, UserString, Err])),
		    {104, ErrTxt}
	    end;
	[] ->
	    ErrTxt = lists:flatten(
		       io_lib:format(
			 "failed to create room ~s for ~s: user session not found",
			 [RoomString, UserString])),
	    ?ERROR_MSG(ErrTxt, []),
	    {104, ErrTxt}
    end.

%%
%% muc-add-member
%%
muc_add_member(RoomString, RoomHost, UserString) ->
    SenderJid = get_senderjid(RoomHost),
    RoomJid = jid:from_string(RoomString),
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
    RoomJid = jid:from_string(RoomString),
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
    RoomJid = jid:from_string(RoomString),
    case get_occupant_nick(RoomJid, UserString) of
	{ok, Nick} ->
	    XmlEl = build_kick_stanza(Nick, RoomString),
	    ejabberd_router:route(SenderJid, RoomJid, XmlEl),
	    {ok, ""};
	{error, room_not_found} ->
	    {104, "Room not found"};
	{error, occupant_not_found} ->
	    {104, "User not found"}
    end.

get_occupant_nick(RoomJid, UserString) ->
    case jid:from_string(iolist_to_binary(UserString)) of
	#jid{luser = LUser, lserver = LServer, lresource = LResource} = JID ->
	    LJID = jid:tolower(JID),
	    case get_room_occupants(RoomJid#jid.luser, RoomJid#jid.lserver) of
		{ok, Occupants} ->
		    if LResource /= <<"">> ->
			    case dict:find(LJID, Occupants) of
				{ok, Occupant} ->
				    {ok, Occupant#user.nick};
				error ->
				    {error, occupant_not_found}
			    end;
		       true ->
			    dict:fold(
			      fun({U, S, _}, Occupant, {error, occupant_not_found})
				    when U == LUser, S == LServer ->
				      {ok, Occupant#user.nick};
				 (_, _, Acc) ->
				      Acc
			      end, {error, occupant_not_found}, Occupants)
		    end;
		Err ->
		    Err
	    end;
	error ->
	    {error, occupant_not_found}
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

get_room_occupants(Room, Host) ->
    case get_room_pid(Room, Host) of
        room_not_found -> {error, room_not_found};
        Pid -> get_room_occupants(Pid)
    end.

get_room_occupants(Pid) ->
    case catch get_room_state(Pid) of
	{ok, S} ->
	    {ok, S#state.users};
	_Err ->
	    {error, room_not_found}
    end.

%% @doc Get the Pid of an existing MUC room, or 'room_not_found'.
get_room_pid(Name, Service) ->
    case mnesia:dirty_read(muc_online_room, {Name, Service}) of
        [] ->
            room_not_found;
        [Room] ->
            Room#muc_online_room.pid
    end.

get_room_state(Room_pid) ->
    gen_fsm:sync_send_all_state_event(Room_pid, get_state).

%%
%% muc-purge-archive
%%
%% Note: this code assumes sql storage is used for the archive table.
muc_purge_archive(RoomHost, Days) ->
    TimestampLimit = get_timestamp_n_days_ago(Days),
    ?INFO_MSG("Messages older than ~p will be removed",
	[jlib:now_to_utc_string(usec_to_now(TimestampLimit))]),
    TimestampBin = jlib:integer_to_binary(TimestampLimit),
    ejabberd_sql:sql_query(RoomHost,
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
    RoomJid = jid:from_string(RoomString),
    case fxml_stream:parse_element(Activity) of
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
    SenderJid = jid:from_string(SenderJidBinary),
    SenderJid.

%%
%% muc-kick-user
%%
kick_user(JID) ->
    {User, Server, _R} = jid:string_to_usr(JID),
    Resources = ejabberd_sm:get_user_resources(User, Server),
    lists:foreach(fun(Resource) ->
			  {LUser, LServer, LResource} =
			      jid:tolower({User, Server, Resource}),
			  C2SPid = ejabberd_sm:get_session_pid(
				     LUser, LServer, LResource),
			  catch ejabberd_c2s:stop_or_detach(C2SPid)
		  end,
		  Resources),
    {ok, ""}.

depends(_Host, _Opts) ->
    [{mod_muc, hard}].

mod_opt_type(senderjid) -> fun (X) -> X end;
mod_opt_type(_) -> [senderjid].
