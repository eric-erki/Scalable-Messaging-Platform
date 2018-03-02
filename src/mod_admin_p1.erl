%%%-------------------------------------------------------------------
%%% File    : mod_admin_p1.erl
%%% Author  : Badlop / Mickael Remond / Christophe Romain
%%% Purpose : Administrative functions and commands for ProcessOne customers
%%% Created : 21 May 2008 by Badlop <badlop@process-one.net>
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
%%%-------------------------------------------------------------------

%%% @doc Administrative functions and commands for ProcessOne customers
%%%
%%% This ejabberd module defines and registers many ejabberd commands
%%% that can be used for performing administrative tasks in ejabberd.
%%%
%%% The documentation of all those commands can be read using ejabberdctl
%%% in the shell.
%%%
%%% The commands can be executed using any frontend to ejabberd commands.
%%% Currently ejabberd_xmlrpc and ejabberdctl. Using ejabberd_xmlrpc it is possible
%%% to call any ejabberd command. However using ejabberdctl not all commands
%%% can be called.

-module(mod_admin_p1).

-author('ProcessOne').

-export([start/2, stop/1,
	% module
	 module_options/1,
	% users
	 create_account/3, delete_account/2,
	% sessions
	 get_resources/2, user_info/2,
	% roster
	 add_rosteritem_groups/5, del_rosteritem_groups/5, modify_rosteritem_groups/6,
	 get_roster/2, get_roster_with_presence/2,
	 set_rosternick/3,
	 transport_register/5,
	% stats
	 local_sessions_number/0, local_muc_rooms_number/0,
	 p1db_records_number/0, iq_handlers_number/0,
	 server_info/0, server_version/0, server_health/0,
	% mass notification
	 start_mass_message/3, stop_mass_message/1,
	 send_mass_message/4, mass_message/5,
	% mam
	 purge_mam/2,
	 get_commands_spec/0,
	% certificates
	 get_apns_config/1, update_apns/3, setup_apns/3,
	 get_apns3_config/1, update_apns3/5, setup_apns3/5,
	 get_gcm_config/1, update_gcm/3, setup_gcm/3,
	 get_webhook_config/1, update_webhook/3, setup_webhook/3,
	 add_push_entry/4, del_push_entry/3,
	 get_push_config/2, set_push_config/3,
	% API IP whitelist
	 get_whitelist_ip/0, set_whitelist_ip/1,
	 opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("ejabberd_commands.hrl").
-include("mod_roster.hrl").
-include("jlib.hrl").
-include("ejabberd_sm.hrl").
-include("ejabberd_c2s.hrl").
-include("mod_muc.hrl").

-define(MASSLOOP, massloop).

start(_Host, _Opts) ->
    ejabberd_commands:register_commands(get_commands_spec()).

stop(_Host) ->
    ejabberd_commands:unregister_commands(get_commands_spec()).

%%%
%%% Register commands
%%%

get_commands_spec() ->
    [#ejabberd_commands{name = create_account,
			tags = [accounts],
			desc = "Create an ejabberd user account",
			longdesc = "This command is similar to 'register'.",
			module = ?MODULE, function = create_account,
			args =
			    [{user, binary}, {server, binary},
			     {password, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = delete_account,
			tags = [accounts],
			desc = "Remove an account from the server",
			longdesc = "This command is similar to 'unregister'.",
			module = ?MODULE, function = delete_account,
			args = [{user, binary}, {server, binary}],
			result = {res, integer}},
     % XXX Works only for mnesia & sql, TODO: move to mod_roster
     #ejabberd_commands{name = add_rosteritem_groups,
			tags = [roster],
			desc = "Add new groups in an existing roster item",
			longdesc =
			    "The argument Groups must be a string "
			    "with group names separated by the character ;",
			module = ?MODULE, function = add_rosteritem_groups,
			args =
			    [{user, binary}, {server, binary}, {jid, binary},
			     {groups, binary}, {push, binary}],
			result = {res, integer}},
     % XXX Works only for mnesia & sql, TODO: move to mod_roster
     #ejabberd_commands{name = del_rosteritem_groups,
			tags = [roster],
			desc = "Delete groups in an existing roster item",
			longdesc =
			    "The argument Groups must be a string "
			    "with group names separated by the character ;",
			module = ?MODULE, function = del_rosteritem_groups,
			args =
			    [{user, binary}, {server, binary}, {jid, binary},
			     {groups, binary}, {push, binary}],
			result = {res, integer}},
     % XXX Works only for mnesia & sql, TODO: move to mod_roster
     #ejabberd_commands{name = modify_rosteritem_groups,
			tags = [roster],
			desc = "Modify the groups of an existing roster item",
			longdesc =
			    "The argument Groups must be a string "
			    "with group names separated by the character ;",
			module = ?MODULE, function = modify_rosteritem_groups,
			args =
			    [{user, binary}, {server, binary}, {jid, binary},
			     {groups, binary}, {subs, binary}, {push, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = get_roster,
			tags = [roster],
			desc = "Retrieve the roster for a given user",
			longdesc =
			    "Returns a list of the contacts in a "
			    "user roster.\n\nAlso returns the state "
			    "of the contact subscription. Subscription "
			    "can be either  \"none\", \"from\", \"to\", "
			    "\"both\". Pending can be \"in\", \"out\" "
			    "or \"none\".",
                        policy = user,
			module = ?MODULE, function = get_roster,
			args = [],
			result =
			    {contacts,
			     {list,
			      {contact,
			       {tuple,
				[{jid, string},
				 {groups, {list, {group, string}}},
				 {nick, string}, {subscription, string},
				 {pending, string}]}}}}},
     #ejabberd_commands{name = get_roster_with_presence,
			tags = [roster],
			desc =
			    "Retrieve the roster for a given user "
			    "including presence information",
			longdesc =
			    "The 'show' value contains the user presence. "
			    "It can take limited values:\n - available\n "
			    "- chat (Free for chat)\n - away\n - "
			    "dnd (Do not disturb)\n - xa (Not available, "
			    "extended away)\n - unavailable (Not "
			    "connected)\n\n'status' is a free text "
			    "defined by the user client.\n\nAlso "
			    "returns the state of the contact subscription"
			    ". Subscription can be either \"none\", "
			    "\"from\", \"to\", \"both\". Pending "
			    "can be \"in\", \"out\" or \"none\".\n\nNote: "
			    "If user is connected several times, "
			    "only keep the resource with the highest "
			    "non-negative priority.",
			module = ?MODULE, function = get_roster_with_presence,
			args = [{user, binary}, {server, binary}],
			result =
			    {contacts,
			     {list,
			      {contact,
			       {tuple,
				[{jid, string}, {resource, string},
				 {group, string}, {nick, string},
				 {subscription, string}, {pending, string},
				 {show, string}, {status, string}]}}}}},
     % XXX Works only with mnesia or sql. Doesn't work with
     % s2s. Doesn't work with virtual hosts.
     #ejabberd_commands{name = set_rosternick,
			tags = [roster],
			desc = "Set the nick of an roster item",
			module = ?MODULE, function = set_rosternick,
			args =
			    [{user, binary}, {server, binary},
			     {nick, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = get_resources,
			tags = [session],
			desc = "Get all available resources for a given user",
			module = ?MODULE, function = get_resources,
			args = [{user, binary}, {server, binary}],
			result = {resources, {list, {resource, string}}}},
     #ejabberd_commands{name = transport_register,
			tags = [transports],
			desc = "Register a user in a transport",
			module = ?MODULE, function = transport_register,
			args =
			    [{host, binary}, {transport, binary},
			     {jidstring, binary}, {username, binary},
			     {password, binary}],
			result = {res, string}},
     #ejabberd_commands{name = local_sessions_number,
			tags = [stats],
			desc = "Number of sessions in local node",
			module = ?MODULE, function = local_sessions_number,
			args = [],
			result = {res, integer}},
     #ejabberd_commands{name = local_muc_rooms_number,
			tags = [stats],
			desc = "Number of MUC rooms in local node",
			module = ?MODULE, function = local_muc_rooms_number,
			args = [],
			result = {res, integer}},
     #ejabberd_commands{name = p1db_records_number,
			tags = [stats],
			desc = "Number of records in p1db tables",
			module = ?MODULE, function = p1db_records_number,
			args = [],
			result = {modules, {list, {module, {tuple, [{name, string}, {size, integer}]}}}}
		       },
     #ejabberd_commands{name = start_mass_message,
			tags = [stanza],
			desc = "Send chat message or stanza to all online users",
			module = ?MODULE, function = start_mass_message,
			args = [{server, binary}, {payload, binary}, {rate, integer}],
			result = {res, integer}},
     #ejabberd_commands{name = send_mass_message,
			tags = [stanza],
			desc = "Send chat message or stanza to a mass of users",
			module = ?MODULE, function = send_mass_message,
			args = [{server, binary}, {payload, binary}, {rate, integer},
			        {uids, {list, {uid, binary}}}],
			result = {res, integer}},
     #ejabberd_commands{name = stop_mass_message,
			tags = [stanza],
			desc = "Force stop of current mass message job",
			module = ?MODULE, function = stop_mass_message,
			args = [{server, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = iq_handlers_number,
			tags = [internal],
			desc = "Number of IQ handlers in the node",
			module = ?MODULE, function = iq_handlers_number,
			args = [],
			result = {res, integer}},
     #ejabberd_commands{name = server_info,
			tags = [stats],
			desc = "Big picture of server use and status",
			module = ?MODULE, function = server_info,
			jabs = 0,  %% Do not count tabs for our monitoring
			args = [],
			result = {res, {list,
			    {probe, {tuple, [{name, atom}, {value, integer}]}}}}},
     #ejabberd_commands{name = server_version,
			tags = [],
			desc = "Build version of running server",
			module = ?MODULE, function = server_version,
			args = [],
			result = {res, {list,
			    {probe, {tuple, [{name, atom}, {value, string}]}}}}},
     #ejabberd_commands{name = server_health,
			tags = [stats],
			desc = "Server health, returns warnings or alerts",
			module = ?MODULE, function = server_health,
			args = [],
			result = {res, {list,
			    {probe, {tuple, [{level, atom}, {message, string}]}}}}},
     #ejabberd_commands{name = user_info,
			tags = [session],
			desc = "Information about a user's online sessions",
			module = ?MODULE, function = user_info,
			args = [{user, binary}, {server, binary}],
			result = {res, {tuple, [
				    {status, string},
				    {sessions, {list,
					{session, {list,
					    {info, {tuple, [{name, atom}, {value, string}]}}}}}}]}}},
     #ejabberd_commands{name = remove_offline,
			tags = [session],
			desc = "Remove offline sessions records used by stream management",
			module = sm_remove_offline, function = remove_offline,
			args = [],
			result = {res, rescode}},
	  #ejabberd_commands{name = purge_mam,
			     tags = [mam],
			     desc = "Purge MAM archive for old messages",
			     longdesc = "First parameter is virtual host "
			     "name.\n"
			     "Second parameter is the age of messages "
			     "to delete, in days.\n"
			     "It returns the number of deleted messages, "
			     "or a negative error code.",
			     module = ?MODULE, function = purge_mam,
			     args = [{server, binary}, {days, integer}],
			     result = {res, integer}},
     #ejabberd_commands{name = get_apns_config,
			tags = [config],
			desc = "Fetch the Apple Push Notification Service configuration",
			module = ?MODULE, function = get_apns_config,
			args = [{host, binary}],
			result = {res, {list,
			    {value, {list,
			      {value, {tuple, [{name, atom}, {value, string}]}}}}}}},
     #ejabberd_commands{name = get_apns3_config,
			tags = [config],
			desc = "Fetch the Apple Push Notification Service v3 configuration",
			module = ?MODULE, function = get_apns3_config,
			args = [{host, binary}],
			result = {res, {list,
			    {value, {list,
			      {value, {tuple, [{name, atom}, {value, string}]}}}}}}},
     #ejabberd_commands{name = get_gcm_config,
			tags = [config],
			desc = "Fetch the Google Cloud Messaging service configuration",
			module = ?MODULE, function = get_gcm_config,
			args = [{host, binary}],
			result = {res, {list,
			    {value, {list,
			      {value, {tuple, [{name, atom}, {value, string}]}}}}}}},
     #ejabberd_commands{name = get_webhook_config,
			tags = [config],
			desc = "Fetch the webhook push service configuration",
			module = ?MODULE, function = get_webhook_config,
			args = [{host, binary}],
			result = {res, {list,
			    {value, {list,
			      {value, {tuple, [{name, atom}, {value, string}]}}}}}}},
     #ejabberd_commands{name = update_apns,
			tags = [config],
			desc = "Update the Apple Push Notification Service certificate",
			module = ?MODULE, function = update_apns,
			args = [{host, binary}, {cert, binary}, {appid, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = setup_apns,
			tags = [config],
			desc = "Setup the Apple Push Notification Service",
			module = ?MODULE, function = setup_apns,
			args = [{host, binary}, {cert, binary}, {appid, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = update_apns3,
			tags = [config],
			desc = "Update the Apple Push Notification Service v3",
			module = ?MODULE, function = update_apns3,
			args = [{host, binary}, {key, binary}, {keyid, binary},
				{teamid, binary}, {appid, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = setup_apns3,
			tags = [config],
			desc = "Setup the Apple Push Notification Service v3",
			module = ?MODULE, function = setup_apns3,
			args = [{host, binary}, {key, binary}, {keyid, binary},
				{teamid, binary}, {appid, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = update_gcm,
			tags = [config],
			desc = "Update the Google Cloud Messaging service ApiKey",
			module = ?MODULE, function = update_gcm,
			args = [{host, binary}, {apikey, binary}, {appid, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = setup_gcm,
			tags = [config],
			desc = "Setup the Google Cloud Messaging service",
			module = ?MODULE, function = setup_gcm,
			args = [{host, binary}, {apikey, binary}, {appid, binary}],
			result = {res, integer}},
     #ejabberd_commands{name = update_webhook,
			tags = [config],
			desc = "Update the Web Hook based Push API service gateway",
			module = ?MODULE, function = update_webhook,
			args = [{host, binary}, {gateway, binary}, {appid, binary}],
			result = {res, integer}},
      #ejabberd_commands{name = setup_webhook,
			tags = [config],
			desc = "Setup the Web Hook based Push API service",
			module = ?MODULE, function = setup_webhook,
			args = [{host, binary}, {gateway, binary}, {appid, binary}],
			result = {res, integer}},
      #ejabberd_commands{name = get_whitelist_ip,
			tags = [config],
			desc = "Get the list of whitelisted IP for REST API",
			module = ?MODULE, function = get_whitelist_ip,
			args = [],
			result = {ips, {list, {ip, string}}}},
      #ejabberd_commands{name = set_whitelist_ip,
			tags = [config],
			desc = "Get the list of whitelisted IP for REST API",
			module = ?MODULE, function = set_whitelist_ip,
			args = [{ips, {list, {ip, string}}}],
			result = {res, integer}},
      #ejabberd_commands{name = license_info,
			tags = [config],
			desc = "Display the product license",
			module = ejabberd_license, function = info,
			args = [],
			result = {license, string}}
    ].


%%%
%%% Erlang
%%%

module_options(Module) ->
    [{Host, proplists:get_value(Module, gen_mod:loaded_modules_with_opts(Host))}
     || Host <- ejabberd_config:get_myhosts()].


%%%
%%% Accounts
%%%

create_account(U, S, P) ->
    case ejabberd_auth:try_register(U, S, P) of
      {atomic, ok} -> 0;
      {atomic, exists} -> 409;
      _ -> 1
    end.

delete_account(U, S) ->
    Fun = fun () -> ejabberd_auth:remove_user(U, S) end,
    user_action(U, S, Fun, ok).


%%%
%%% Sessions
%%%


get_resources(U, S) ->
    case ejabberd_auth:is_user_exists(U, S) of
      true -> get_resources2(U, S);
      false -> 404
    end.

user_info(U, S) ->
    case ejabberd_auth:is_user_exists(U, S) of
	true ->
	    case get_sessions(U, S) of
		[] -> {<<"offline">>, [last_info(U, S)]};
		Ss -> {<<"online">>, [session_info(Session) || Session <- Ss]}
	    end;
	false ->
	    {<<"unregistered">>, [[]]}
    end.

%%%
%%% Vcard
%%%


%%%
%%% Roster
%%%





unlink_contacts(JID1, JID2) ->
    unlink_contacts(JID1, JID2, true).

unlink_contacts(JID1, JID2, Push) ->
    {U1, S1, _} =
	jid:tolower(jid:from_string(JID1)),
    {U2, S2, _} =
	jid:tolower(jid:from_string(JID2)),
    case {ejabberd_auth:is_user_exists(U1, S1),
	  ejabberd_auth:is_user_exists(U2, S2)}
	of
      {true, true} ->
	  case unlink_contacts2(JID1, JID2, Push) of
	    {atomic, ok} -> 0;
	    _ -> 1
	  end;
      _ -> 404
    end.

get_roster(U, S) ->
    case ejabberd_auth:is_user_exists(U, S) of
      true -> format_roster(get_roster2(U, S));
      false -> 404
    end.

get_roster_with_presence(U, S) ->
    case ejabberd_auth:is_user_exists(U, S) of
      true -> format_roster_with_presence(get_roster2(U, S));
      false -> 404
    end.

set_rosternick(U, S, N) ->
    Fun = fun() -> change_rosternick(U, S, N) end,
    user_action(U, S, Fun, ok).

change_rosternick(User, Server, Nick) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    LJID = {LUser, LServer, <<"">>},
    JID = jid:to_string(LJID),
    Push = fun(Subscription) ->
	jlib:iq_to_xml(#iq{type = set, xmlns = ?NS_ROSTER, id = <<"push">>,
			   sub_el = [#xmlel{name = <<"query">>, attrs = [{<<"xmlns">>, ?NS_ROSTER}],
				     children = [#xmlel{name = <<"item">>, attrs = [{<<"jid">>, JID}, {<<"name">>, Nick}, {<<"subscription">>, atom_to_binary(Subscription, utf8)}]}]}]})
	end,
    Result = case roster_backend(Server) of
	mnesia ->
	    %% XXX This way of doing can not work with s2s
	    mnesia:transaction(
		fun() ->
		    lists:foreach(fun(Roster) ->
			{U, S} = Roster#roster.us,
			mnesia:write(Roster#roster{name = Nick}),
			lists:foreach(fun(R) ->
			    UJID = jid:make(U, S, R),
			    ejabberd_router:route(UJID, UJID, Push(Roster#roster.subscription))
			end, get_resources(U, S))
		    end, mnesia:match_object(#roster{jid = LJID, _ = '_'}))
		end);
	sql ->
	    %%% XXX This way of doing does not work with several domains
	    ejabberd_sql:sql_transaction(LServer,
		fun() ->
		    SNick = ejabberd_sql:escape(Nick),
		    SJID = ejabberd_sql:escape(JID),
		    ejabberd_sql:sql_query_t(
				["update rosterusers"
				 " set nick='", SNick, "'"
				 " where jid='", SJID, "';"]),
		    case ejabberd_sql:sql_query_t(
			["select username from rosterusers"
			 " where jid='", SJID, "'"
			 " and subscription = 'B';"]) of
			{selected, [<<"username">>], Users} ->
			    lists:foreach(fun({RU}) ->
				lists:foreach(fun(R) ->
				    UJID = jid:make(RU, Server, R),
				    ejabberd_router:route(UJID, UJID, Push(both))
				end, get_resources(RU, Server))
			    end, Users);
			_ ->
			    ok
		    end
		end);
	none ->
	    {error, no_roster}
    end,
    case Result of
	{atomic, ok} -> ok;
	_ -> error
    end.


%%%
%%% Groups of Roster Item
%%%

add_rosteritem_groups(User, Server, JID,
		      NewGroupsString, PushString) ->
    {U1, S1, _} = jid:tolower(jid:from_string(JID)),
    NewGroups = str:tokens(NewGroupsString, <<";">>),
    Push = jlib:binary_to_atom(PushString),
    case {ejabberd_auth:is_user_exists(U1, S1),
	  ejabberd_auth:is_user_exists(User, Server)}
	of
      {true, true} ->
	  case add_rosteritem_groups2(User, Server, JID,
				      NewGroups, Push)
	      of
	    ok -> 0;
	    Error -> ?INFO_MSG("Error found: ~n~p", [Error]), 1
	  end;
      _ -> 404
    end.

del_rosteritem_groups(User, Server, JID,
		      NewGroupsString, PushString) ->
    {U1, S1, _} = jid:tolower(jid:from_string(JID)),
    NewGroups = str:tokens(NewGroupsString, <<";">>),
    Push = jlib:binary_to_atom(PushString),
    case {ejabberd_auth:is_user_exists(U1, S1),
	  ejabberd_auth:is_user_exists(User, Server)}
	of
      {true, true} ->
	  case del_rosteritem_groups2(User, Server, JID,
				      NewGroups, Push)
	      of
	    ok -> 0;
	    Error -> ?INFO_MSG("Error found: ~n~p", [Error]), 1
	  end;
      _ -> 404
    end.

modify_rosteritem_groups(User, Server, JID,
			 NewGroupsString, SubsString, PushString) ->
    Nick = <<"">>,
    Subs = jlib:binary_to_atom(SubsString),
    {_, _, _} = jid:tolower(jid:from_string(JID)),
    NewGroups = str:tokens(NewGroupsString, <<";">>),
    Push = jlib:binary_to_atom(PushString),
    case ejabberd_auth:is_user_exists(User, Server) of
      true ->
	  case modify_rosteritem_groups2(User, Server, JID,
					 NewGroups, Push, Nick, Subs)
	      of
	    ok -> 0;
	    Error -> ?INFO_MSG("Error found: ~n~p", [Error]), 1
	  end;
      _ -> 404
    end.

add_rosteritem_groups2(User, Server, JID, NewGroups,
		       Push) ->
    GroupsFun = fun (Groups) ->
			lists:usort(NewGroups ++ Groups)
		end,
    change_rosteritem_group(User, Server, JID, GroupsFun,
			    Push).

del_rosteritem_groups2(User, Server, JID, NewGroups,
		       Push) ->
    GroupsFun = fun (Groups) -> Groups -- NewGroups end,
    change_rosteritem_group(User, Server, JID, GroupsFun,
			    Push).

modify_rosteritem_groups2(User, Server, JID2, NewGroups,
			  _Push, _Nick, _Subs)
    when NewGroups == [] ->
    JID1 = jid:to_string(jid:make(User, Server,
					    <<"">>)),
    case unlink_contacts(JID1, JID2) of
      0 -> ok;
      Error -> Error
    end;
modify_rosteritem_groups2(User, Server, JID, NewGroups,
			  Push, Nick, Subs) ->
    GroupsFun = fun (_Groups) -> NewGroups end,
    change_rosteritem_group(User, Server, JID, GroupsFun,
			    Push, NewGroups, Nick, Subs).

change_rosteritem_group(User, Server, JID, GroupsFun,
			Push) ->
    change_rosteritem_group(User, Server, JID, GroupsFun,
			    Push, [], <<"">>, <<"both">>).

change_rosteritem_group(User, Server, JID, GroupsFun,
			Push, NewGroups, Nick, Subs) ->
    {RU, RS, _} = jid:tolower(jid:from_string(JID)),
    LJID = {RU, RS, <<>>},
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    Result = case roster_backend(LServer) of
	       mnesia ->
		   mnesia:transaction(fun () ->
					      case mnesia:read({roster,
								{LUser, LServer,
								 LJID}})
						  of
						[#roster{} = Roster] ->
						    NewGroups2 =
							GroupsFun(Roster#roster.groups),
						    NewRoster =
							Roster#roster{groups =
									  NewGroups2},
						    mnesia:write(NewRoster),
						    {ok, NewRoster#roster.name,
						     NewRoster#roster.subscription,
						     NewGroups2};
						_ -> not_in_roster
					      end
				      end);
	       sql ->
		   ejabberd_sql:sql_transaction(LServer,
						 fun () ->
							 Username =
							     ejabberd_sql:escape(User),
							 SJID =
							     ejabberd_sql:escape(jid:to_string(LJID)),
							 case
							   ejabberd_sql:sql_query_t([<<"select nick, subscription from rosterusers "
											"      where username='">>,
										      Username,
										      <<"'         and jid='">>,
										      SJID,
										      <<"';">>])
							     of
							   {selected,
							    [<<"nick">>,
							     <<"subscription">>],
							    [[Name,
							      SSubscription]]} ->
							       Subscription =
								   case
								     SSubscription
								       of
								     <<"B">> ->
									 both;
								     <<"T">> ->
									 to;
								     <<"F">> ->
									 from;
								     _ -> none
								   end,
							       Groups = case
									  sql_queries:get_roster_groups(LServer,
													 Username,
													 SJID)
									    of
									  {selected,
									   [<<"grp">>],
									   JGrps}
									      when
										is_list(JGrps) ->
									      [JGrp
									       || [JGrp]
										      <- JGrps];
									  _ ->
									      []
									end,
							       NewGroups2 =
								   GroupsFun(Groups),
							       ejabberd_sql:sql_query_t([<<"delete from rostergroups       where "
											    "username='">>,
											  Username,
											  <<"'         and jid='">>,
											  SJID,
											  <<"';">>]),
							       lists:foreach(fun
									       (Group) ->
										   ejabberd_sql:sql_query_t([<<"insert into rostergroups(           "
														"   username, jid, grp)  values ('">>,
													      Username,
													      <<"','">>,
													      SJID,
													      <<"','">>,
													      ejabberd_sql:escape(Group),
													      <<"');">>])
									     end,
									     NewGroups2),
							       {ok, Name,
								Subscription,
								NewGroups2};
							   _ -> not_in_roster
							 end
						 end);
	       none -> {atomic, {ok, Nick, Subs, NewGroups}}
	     end,
    case {Result, Push} of
      {{atomic, {ok, Name, Subscription, NewGroups3}},
       true} ->
	  roster_push(User, Server, JID, Name,
		      iolist_to_binary(atom_to_list(Subscription)),
		      NewGroups3),
	  ok;
      {{atomic, {ok, _Name, _Subscription, _NewGroups3}},
       false} ->
	  ok;
      {{atomic, not_in_roster}, _} -> not_in_roster;
      Error -> {error, Error}
    end.

transport_register(Host, TransportString, JIDString,
		   Username, Password) ->
    TransportAtom = jlib:binary_to_atom(TransportString),
    case {lists:member(Host, ?MYHOSTS),
	  jid:from_string(JIDString)}
	of
      {true, JID} when is_record(JID, jid) ->
	  case catch apply(gen_transport, register, [Host, TransportAtom,
					    JIDString, Username, Password])
	      of
	    ok -> <<"OK">>;
	    {error, Reason} ->
		<<"ERROR: ",
		  (iolist_to_binary(atom_to_list(Reason)))/binary>>;
	    {'EXIT', {timeout, _}} -> <<"ERROR: timed_out">>;
	    {'EXIT', _} -> <<"ERROR: unexpected_error">>
	  end;
      {false, _} -> <<"ERROR: unknown_host">>;
      _ -> <<"ERROR: bad_jid">>
    end.

%%%
%%% Mass message
%%%

start_mass_message(Host, Payload, Rate) ->
    send_mass_message(Host, Payload, Rate, []).

send_mass_message(Host, Payload, Rate, Rs)
	when is_binary(Host), is_binary(Payload), is_integer(Rate), is_list(Rs) ->
    From = jid:make(<<>>, Host, <<>>),
    Proc = gen_mod:get_module_proc(Host, ?MASSLOOP),
    Delay = 60000 div Rate,
    case global:whereis_name(Proc) of
	undefined ->
	    case mass_message_parse(Payload, Rs) of
		{error, _} -> 4;
		{ok, _, []} -> 3;
		{ok, <<>>, _} -> 2;
		{ok, Body, Tos} when is_binary(Body) ->
		    Stanza = #xmlel{name = <<"message">>,
			    attrs = [{<<"type">>, <<"chat">>}],
			    children = [#xmlel{name = <<"body">>, attrs = [],
					    children = [{xmlcdata, Body}]}]},
		    Pid = spawn(?MODULE, mass_message, [Host, Delay, Stanza, From, Tos]),
		    global:register_name(Proc, Pid),
		    0;
		{ok, Stanza, Tos} ->
		    Pid = spawn(?MODULE, mass_message, [Host, Delay, Stanza, From, Tos]),
		    global:register_name(Proc, Pid),
		    0
	    end;
	_ ->
	    % return error if loop already/still running
	    1
    end.

stop_mass_message(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?MASSLOOP),
    case global:whereis_name(Proc) of
	undefined -> 1;
	Pid -> Pid ! stop, 0
    end.

%%%
%%% Stats
%%%

local_sessions_number() ->
    Iterator = fun(#session{sid = {_, Pid}}, Acc)
		  when node(Pid) == node() ->
		       Acc+1;
		  (_Session, Acc) ->
		       Acc
	       end,
    F = fun() -> mnesia:foldl(Iterator, 0, session) end,
    mnesia:ets(F).

local_muc_rooms_number() ->
    Iterator = fun(#muc_online_room{pid = Pid}, Acc)
		  when node(Pid) == node() ->
		       Acc+1;
		  (_Room, Acc) ->
		       Acc
	       end,
    F = fun() -> mnesia:foldl(Iterator, 0, muc_online_room) end,
    mnesia:ets(F).

p1db_records_number() ->
    [{atom_to_list(Table), Count} || Table <- p1db:opened_tables(),
		       {ok, Count} <- [p1db:count(Table)]].

%%%
%%% Misc
%%%

iq_handlers_number() ->
    ets:info(sm_iqtable, size).

server_info() ->
    Hosts = ejabberd_config:get_myhosts(),
    Memory = erlang:memory(total),
    Processes = erlang:system_info(process_count),
    IqHandlers = iq_handlers_number(),
    Nodes = ejabberd_cluster:get_nodes(),
    {LocalSessions, LocalFailed} = ejabberd_cluster:multicall(Nodes, ?MODULE, local_sessions_number, []),
    Sessions = ejabberd_sm:get_sessions_number(),
    OdbcPoolSize = lists:sum(
	    [workers_number(gen_mod:get_module_proc(Host, ejabberd_sql_sup))
		|| Host <- Hosts]),
    HttpPoolSize = case catch http_p1:get_pool_size() of
	{'EXIT', _} -> 0;
	Size -> Size
    end,
    {Jabs, {MegaSecs,Secs,_}} = lists:foldr(fun(Host, {J,S}) ->
		    case catch mod_jabs:value(Host) of
			{'EXIT', _} -> {J,S};
			{Int, Now} -> {J+Int, Now};
			_ -> {J,S}
		    end
	    end, {0, os:timestamp()}, Hosts),
    JabsSince = MegaSecs*1000000+Secs,
    [AH | AT] = [lists:sort(ejabberd_command(active_counters, [Host], []))
                 || Host <- Hosts],
    Active = lists:foldl(
            fun(AL, Acc1) ->
                    lists:foldl(
                        fun({K, V1}, Acc2) ->
                                case lists:keyfind(K, 1, Acc2) of
                                    {K, V2} -> lists:keyreplace(K, 1, Acc2, {K, V1+V2});
                                    false -> [{K, V1}|Acc2]
                                end
                        end, Acc1, AL)
            end, AH, AT),
    {LogLevel, _, _} = ejabberd_logger:get(),
    lists:flatten([
	[{online, Sessions} | lists:zip(Nodes--LocalFailed, LocalSessions)],
	[{jlib:binary_to_atom(Key), Val} || {Key, Val} <- Active],
	{jabs, Jabs},
	{jabs_since, JabsSince},
	{memory, Memory},
	{processes, Processes},
	{iq_handlers, IqHandlers},
	{sql_pool_size, OdbcPoolSize},
	{http_pool_size, HttpPoolSize},
	{loglevel, LogLevel}
	]).

server_version() ->
    {ok, Version} = application:get_key(ejabberd, vsn),
    {ok, Modules} = application:get_key(ejabberd, modules),
    [{Build,Secs}|Stamps] = lists:usort([build_stamp(M) || M<-Modules]),
    [{Patch, Last}|_] = lists:reverse(Stamps),
    [{version, list_to_binary(Version)}, {build, Build} | [{patch, Patch} || Last-Secs > 120]].

server_health() ->
    Hosts = ejabberd_config:get_myhosts(),
    Health = lists:usort(lists:foldl(
		fun(Host, Acc) ->
			case catch mod_mon:value(Host, health) of
			    H when is_list(H) -> H++Acc;
			    _ -> Acc
			end
		end, [], Hosts)),
    [{Level, <<Componant/binary, ": ", Message/binary>>}
     || {Level, Componant, Message} <- Health].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internal functions

%% -----------------------------
%% Internal roster handling
%% -----------------------------

get_roster2(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    ejabberd_hooks:run_fold(roster_get, LServer, [], [{LUser, LServer}]).



del_rosteritem(User, Server, JID, Push) ->
    {RU, RS, _} = jid:tolower(jid:from_string(JID)),
    LJID = {RU, RS, <<>>},
    Result = case roster_backend(Server) of
	       mnesia ->
		   mnesia:transaction(fun () ->
					      mnesia:delete({roster,
							     {User, Server,
							      LJID}})
				      end);
	       sql ->
		   case ejabberd_sql:sql_transaction(Server,
						      fun () ->
							      SJID =
								  jid:to_string(LJID),
							      sql_queries:del_roster(Server,
										      User,
										      SJID)
						      end)
		       of
		     {atomic, _} -> {atomic, ok};
		     Error -> Error
		   end;
	       none -> {atomic, ok}
	     end,
    case {Result, Push} of
      {{atomic, ok}, true} ->
	  roster_push(User, Server, JID, <<"">>, <<"remove">>,
		      []);
      {{atomic, ok}, false} -> ok;
      _ -> error
    end,
    Result.

unlink_contacts2(JID1, JID2, Push) ->
    {U1, S1, _} =
	jid:tolower(jid:from_string(JID1)),
    {U2, S2, _} =
	jid:tolower(jid:from_string(JID2)),
    case del_rosteritem(U1, S1, JID2, Push) of
      {atomic, ok} -> del_rosteritem(U2, S2, JID1, Push);
      Error -> Error
    end.

roster_push(User, Server, JID, Nick, Subscription,
	    Groups) ->
    TJID = jid:from_string(JID),
    {TU, TS, _} = jid:tolower(TJID),

    mod_roster:invalidate_roster_cache(jid:nodeprep(User), jid:nameprep(Server)),

    Presence = #xmlel{name = <<"presence">>,
		      attrs =
			  [{<<"type">>,
			    case Subscription of
			      <<"remove">> -> <<"unsubscribed">>;
			      <<"none">> -> <<"unsubscribe">>;
			      <<"both">> -> <<"subscribed">>;
			      _ -> <<"subscribe">>
			    end}],
		      children = []},
    ItemAttrs = case Nick of
		  <<"">> ->
		      [{<<"jid">>, JID}, {<<"subscription">>, Subscription}];
		  _ ->
		      [{<<"jid">>, JID}, {<<"name">>, Nick},
		       {<<"subscription">>, Subscription}]
		end,
    ItemGroups = lists:map(fun (G) ->
				   #xmlel{name = <<"group">>, attrs = [],
					  children = [{xmlcdata, G}]}
			   end,
			   Groups),
    Result = jlib:iq_to_xml(#iq{type = set,
				xmlns = ?NS_ROSTER, id = <<"push">>,
				lang = <<"langxmlrpc-en">>,
				sub_el =
				    [#xmlel{name = <<"query">>,
					    attrs = [{<<"xmlns">>, ?NS_ROSTER}],
					    children =
						[#xmlel{name = <<"item">>,
							attrs = ItemAttrs,
							children =
							    ItemGroups}]}]}),
    lists:foreach(fun (Resource) ->
			  UJID = jid:make(User, Server, Resource),
			  ejabberd_router:route(TJID, UJID, Presence),
			  ejabberd_router:route(UJID, UJID, Result),
			  case Subscription of
			    <<"remove">> -> none;
			    _ ->
				lists:foreach(fun (TR) ->
						      ejabberd_router:route(jid:make(TU,
											  TS,
											  TR),
									    UJID,
									    #xmlel{name
										       =
										       <<"presence">>,
										   attrs
										       =
										       [],
										   children
										       =
										       []})
					      end,
					      get_resources(TU, TS))
			  end
		  end,
		  [R || R <- get_resources(User, Server)]).

roster_backend(Server) ->
    Modules = gen_mod:loaded_modules(Server),
    Mnesia = lists:member(mod_roster, Modules),
    Odbc = lists:member(mod_roster_sql, Modules),
    if Mnesia -> mnesia;
       true ->
	   if Odbc -> sql;
	      true -> none
	   end
    end.

format_roster([]) -> [];
format_roster(Items) -> format_roster(Items, []).

format_roster([], Structs) -> Structs;
format_roster([#roster{jid = JID, name = Nick,
		       groups = Group, subscription = Subs, ask = Ask}
	       | Items],
	      Structs) ->
    JidBinary = jid:to_string(jid:make(JID)),
    Struct = {JidBinary, Group,
	      Nick, iolist_to_binary(atom_to_list(Subs)),
	      iolist_to_binary(atom_to_list(Ask))},
    format_roster(Items, [Struct | Structs]).

format_roster_with_presence([]) -> [];
format_roster_with_presence(Items) ->
    format_roster_with_presence(Items, []).

format_roster_with_presence([], Structs) -> Structs;
format_roster_with_presence([#roster{jid = JID,
				     name = Nick, groups = Group,
				     subscription = Subs, ask = Ask}
			     | Items],
			    Structs) ->
    {User, Server, _R} = JID,
    Presence = case Subs of
		 both -> get_presence2(User, Server);
		 from -> get_presence2(User, Server);
		 _Other -> {<<"">>, <<"unavailable">>, <<"">>}
	       end,
    {Resource, Show, Status} = Presence,
    Struct = {jid:to_string(jid:make(User, Server, <<>>)),
	      Resource, extract_group(Group), Nick,
	      iolist_to_binary(atom_to_list(Subs)),
	      iolist_to_binary(atom_to_list(Ask)), Show, Status},
    format_roster_with_presence(Items, [Struct | Structs]).

extract_group([]) -> [];
%extract_group([Group|_Groups]) -> Group.
extract_group(Groups) -> str:join(Groups, <<";">>).

%% -----------------------------
%% Internal session handling
%% -----------------------------

get_presence2(User, Server) ->
    case get_sessions(User, Server) of
      [] -> {<<"">>, <<"unavailable">>, <<"">>};
      Ss ->
	  Session = hd(Ss),
	  if Session#session.priority >= 0 ->
		 Pid = element(2, Session#session.sid),
		 {_User, Resource, Show, Status} =
		     ejabberd_c2s:get_presence(Pid),
		 {Resource, Show, Status};
	     true -> {<<"">>, <<"unavailable">>, <<"">>}
	  end
    end.

get_resources2(User, Server) ->
    lists:map(fun (S) -> element(3, S#session.usr) end,
	      get_sessions(User, Server)).

get_sessions(User, Server) ->
    Result = ejabberd_sm:get_user_sessions(User, Server),
    lists:reverse(lists:keysort(#session.priority,
				clean_session_list(Result))).

clean_session_list(Ss) ->
    clean_session_list(lists:keysort(#session.usr, Ss), []).

clean_session_list([], Res) -> Res;
clean_session_list([S], Res) -> [S | Res];
clean_session_list([S1, S2 | Rest], Res) ->
    if S1#session.usr == S2#session.usr ->
	   if S1#session.sid > S2#session.sid ->
		  clean_session_list([S1 | Rest], Res);
	      true -> clean_session_list([S2 | Rest], Res)
	   end;
       true -> clean_session_list([S2 | Rest], [S1 | Res])
    end.

mass_message_uids([]) -> ejabberd_sm:connected_users();
mass_message_uids(L) -> L.

mass_message_parse(Payload, Rs) ->
    case file:open(Payload, [read]) of
	{ok, IoDevice} ->
	    %% if argument is a file, read message and user list from it
	    case mass_message_parse_body(IoDevice) of
		{ok, Header} when is_binary(Header) ->
		    Packet = case fxml_stream:parse_element(Header) of
			    {error, _} -> Header;  % Header is message Body
			    Stanza -> Stanza       % Header is xmpp stanza
			end,
		    Uids = case mass_message_parse_uids(IoDevice) of
			    {ok, List} when is_list(List) -> List;
			    _ -> mass_message_uids(Rs)
			end,
		    file:close(IoDevice),
		    {ok, Packet, Uids};
		Error ->
		    file:close(IoDevice),
		    Error
	    end;
	{error, FError} ->
	    % if argument is payload, send it to all online users or defined recipients
	    case fxml_stream:parse_element(Payload) of
		{error, XError} ->
		    {error, {FError, XError}};
		Packet ->
		    Uids = mass_message_uids(Rs),
		    {ok, Packet, Uids}
	    end
    end.

mass_message_parse_body(IoDevice) ->
    mass_message_parse_body(IoDevice, file:read_line(IoDevice), <<>>).
mass_message_parse_body(_IoDevice, {ok, "\n"}, Acc) -> {ok, Acc};
mass_message_parse_body(IoDevice, {ok, Data}, Acc) ->
    [Line|_] = binary:split(list_to_binary(Data), <<"\n">>),
    NextLine = file:read_line(IoDevice),
    mass_message_parse_body(IoDevice, NextLine, <<Acc/binary, Line/binary>>);
mass_message_parse_body(_IoDevice, eof, Acc) -> {ok, Acc};
mass_message_parse_body(_IoDevice, Error, _) -> Error.

mass_message_parse_uids(IoDevice) ->
    mass_message_parse_uids(IoDevice, file:read_line(IoDevice), []).
mass_message_parse_uids(IoDevice, {ok, Data}, Acc) ->
    [Uid|_] = binary:split(list_to_binary(Data), <<"\n">>),
    NextLine = file:read_line(IoDevice),
    mass_message_parse_uids(IoDevice, NextLine, [Uid|Acc]);
mass_message_parse_uids(_IoDevice, eof, Acc) -> {ok, lists:reverse(Acc)};
mass_message_parse_uids(_IoDevice, Error, _) -> Error.

mass_message(_Host, _Delay, _Stanza, _From, []) -> done;
mass_message(Host, Delay, Stanza, From, [Uid|Others]) ->
    receive stop ->
	    Proc = gen_mod:get_module_proc(Host, ?MASSLOOP),
	    ?ERROR_MSG("~p mass messaging stopped~n"
		       "Was about to send message to ~s~n"
		       "With ~p remaining recipients",
		    [Proc, Uid, length(Others)]),
	    stopped
    after Delay ->
	    To = case jid:make(Uid, Host, <<>>) of
		error -> jid:from_string(Uid);
		Ret -> Ret
	    end,
	    Attrs = lists:keystore(<<"id">>, 1, Stanza#xmlel.attrs,
			{<<"id">>, <<"job:", (randoms:get_string())/binary>>}),
	    mod_jabs:add(Host, 1),
	    ejabberd_router:route(From, To, Stanza#xmlel{attrs = Attrs}),
	    mass_message(Host, Delay, Stanza, From, Others)
    end.

%% -----------------------------
%% MAM
%% -----------------------------

purge_mam(Host, Days) ->
    case lists:member(Host, ?MYHOSTS) of
	true ->
	    purge_mam(Host, Days, gen_mod:db_type(Host, mod_mam));
	_ ->
	    ?ERROR_MSG("Unknown Host name: ~s", [Host]),
	    -1
    end.

purge_mam(Host, Days, sql) ->
    Timestamp = p1_time_compat:system_time(micro_seconds) - (3600*24 * Days * 1000000),
    case ejabberd_sql:sql_query(Host,
				 [<<"DELETE FROM archive "
				   "WHERE timestamp < ">>,
				  integer_to_binary(Timestamp),
				  <<";">>]) of
	{updated, N} ->
	    N;
	_Err ->
	    ?ERROR_MSG("Cannot purge MAM on Host ~s: ~p~n", [Host, _Err]),
	    -1
    end;
purge_mam(_Host, _Days, _Backend) ->
    ?ERROR_MSG("MAM purge not implemented for backend ~p~n",
	       [_Backend]),
    -2.

%% -----------------------------
%% Push setup API
%% -----------------------------

get_apns_config(Host) ->
    Setup = get_push_config(<<"applepush">>, Host),
    [setup_struct(cert, Entry) || Entry <- Setup, is_binary(element(2,Entry))].
get_apns3_config(Host) ->
    Setup = lists:usort([{undev_appid(App), Arg}
			  || {App, Arg} <- get_push_config(<<"applepush">>, Host)]),
    [setup_struct(apns3, Entry) || Entry <- Setup, is_tuple(element(2,Entry))].
get_gcm_config(Host) ->
    Setup = get_push_config(<<"gcm">>, Host),
    [setup_struct(apikey, Entry) || Entry <- Setup].
get_webhook_config(Host) ->
    Setup = get_push_config(<<"webhook">>, Host),
    [setup_struct(gateway, Entry) || Entry <- Setup].

setup_apns(Host, <<>>, App) ->
    del_push_entry(<<"applepush">>, Host, App);
setup_apns(Host, Cert, App) ->
    add_push_entry(<<"applepush">>, Host, App, Cert).
setup_apns3(Host, <<>>, _Id, _Team, App) ->
    Setup0 = get_push_config(<<"applepush">>, Host),
    Setup1 = lists:keydelete(App, 1, Setup0),
    Setup2 = lists:keydelete(dev_appid(App), 1, Setup1),
    cluster_set_push_config(<<"applepush">>, Host, Setup2);
setup_apns3(Host, Key, Id, Team, App) ->
    Setup0 = get_push_config(<<"applepush">>, Host),
    Setup1 = lists:keydelete(App, 1, Setup0),
    Setup2 = lists:filter(
	       fun({AppId, _}) ->
		   binary:longest_common_suffix([AppId, <<"_dev">>]) < 4
	       end, Setup1),
    cluster_set_push_config(<<"applepush">>, Host, [{App, {Key, Id, Team}}|Setup2]).
setup_gcm(Host, <<>>, App) ->
    del_push_entry(<<"gcm">>, Host, App);
setup_gcm(Host, Key, App) ->
    add_push_entry(<<"gcm">>, Host, App, Key).
setup_webhook(Host, <<>>, App) ->
    del_push_entry(<<"webhook">>, Host, App);
setup_webhook(Host, Url, App) ->
    add_push_entry(<<"webhook">>, Host, App, Url).

update_apns(Host, Cert, App) ->
    upd_push_entry(<<"applepush">>, Host, App, Cert).
update_apns3(Host, Key, Id, Team, App) ->
    setup_apns3(Host, Key, Id, Team, App).
update_gcm(Host, Key, App) ->
    upd_push_entry(<<"gcm">>, Host, App, Key).
update_webhook(Host, Url, App) ->
    upd_push_entry(<<"webhook">>, Host, App, Url).

upd_push_entry(Service, Host, App, Key) ->
    Setup = lists:keydelete(App, 1, get_push_config(Service, Host)),
    cluster_set_push_config(Service, Host, [{App, Key}|Setup]).
add_push_entry(Service, Host, App, Key) ->
    Setup = get_push_config(Service, Host),
    cluster_set_push_config(Service, Host, [{App, Key}|Setup]).
del_push_entry(Service, Host, App) ->
    Setup = get_push_config(Service, Host),
    cluster_set_push_config(Service, Host, lists:keydelete(App, 1, Setup)).

get_push_config(Service, Host) ->
    ConfigFile = <<Service/binary, ".yml">>,
    Config = proplists:get_value(Host, read_extra_config(ConfigFile), []),
    case proplists:get_value(modules, Config, []) of
	[{_, Opts} | Services] ->
	    SrvOpts = lists:flatten([SOpts || {_, [{hosts, SOpts}]} <- Services]),
	    [push_setup(Service, App, proplists:get_value(Srv, SrvOpts, []))
	     || {App, Srv} <- proplists:get_value(push_services, Opts, [])];
	_ ->
	    []
    end.

set_push_config(Service, Host, Setup) ->
    ConfigFile = <<Service/binary, ".yml">>,
    OldConfig = proplists:get_value(Host, read_extra_config(ConfigFile), []),
    NewConfig = push_cfg(Service, Host, Setup),
    case update_extra_config(ConfigFile, Host, NewConfig) of
	ok ->
	    [gen_mod:stop_module(Host, Mod)
	     || {Mod, _} <- proplists:get_value(modules, OldConfig, [])],
	    [gen_mod:start_module(Host, Mod, Opts)
	     || {Mod, Opts} <- proplists:get_value(modules, NewConfig, [])],
	    0;
	_ ->
	    1
    end.

cluster_set_push_config(Service, Host, Setup) ->
    {Good, _} = ejabberd_cluster:multicall(
		    ?MODULE, set_push_config, [Service, Host, Setup]),
    case Good of
	[] -> 1;
	[Res|_] -> Res
    end.

%% -----------------------------
%% API IP whitelist
%% -----------------------------

get_whitelist_ip() ->
    BaseDir = filename:dirname(os:getenv("EJABBERD_CONFIG_PATH")),
    File = filename:append(BaseDir, "api_whitelist.txt"),
    case file:read_file(File) of
	{ok, Content} -> str:tokens(Content, <<"\n">>);
	_ -> []
    end.

set_whitelist_ip(IPs) ->
    BaseDir = filename:dirname(os:getenv("EJABBERD_CONFIG_PATH")),
    File = filename:append(BaseDir, "api_whitelist.txt"),
    Content = str:join(lists:usort(IPs), <<"\n">>),
    file:write_file(File, <<Content/binary, "\n">>).

%% -----------------------------
%% Internal functions
%% -----------------------------

push_backend() ->
    ejabberd_config:get_option(
      push_cache_db_type,
      fun(V) when is_atom(V) -> V end,
      p1db).

push_cfg(Service, Host, Setup) ->
    RawConfig = lists:flatten([push_service_cfg(Service, App, Arg)
			       || {App, Arg} <- lists:usort(Setup)]),
    Config = lists:reverse(lists:foldl(
	    fun({Mod, AppId, Cfg}, Acc) ->
		Num = integer_to_binary(length(Acc)+1),
		Srv = <<Service/binary, Num/binary, ".", Host/binary>>,
		[{Mod, AppId, Srv, Cfg} | Acc];
	       (_, Acc) ->
		Acc
	    end, [], RawConfig)),
    Services = [{SrvMod,
		 [{hosts,
		    lists:filtermap(
			  fun({Mod, _, Srv, Cfg}) when Mod==SrvMod -> {true, {Srv, Cfg}};
			     (_) -> false
			  end, Config)}]}
		|| SrvMod <- lists:usort([Mod || {Mod, _, _, _} <- Config])],
    [{modules,
      [{jlib:binary_to_atom(<<"mod_", Service/binary>>),
	[{db_type, push_backend()},
	 {iqdisc, 50},
	 {silent_push_enabled, true},
	 {push_services, [{AppId, Srv} || {_, AppId, Srv, _} <- Config]}
	]}
       | Services]} || Config=/=[]].

push_service_cfg(<<"applepush">>, AppId, {Key, Id, Team}) ->
    case write_file(Id, Key) of
	{ok, KeyFile, apns3} ->
	    [{mod_applepushv3_service, AppId,
	     [{default_topic, AppId},
	      {authkeyfile, KeyFile},
	      {authkeyid, Id},
	      {teamid, Team},
	      {gateway, <<"api.push.apple.com">>},
	      {port, 443}]},
	     {mod_applepushv3_service, dev_appid(AppId),
	     [{default_topic, AppId},
	      {authkeyfile, KeyFile},
	      {authkeyid, Id},
	      {teamid, Team},
	      {gateway, <<"api.development.push.apple.com">>},
	      {port, 443}]}];
	_ ->
	    undefined
    end;
push_service_cfg(<<"applepush">>, AppId, Cert) ->
    case write_file(AppId, Cert) of
	{ok, CertFile, apns_prod} ->
	    {mod_applepush_service, AppId,
	     [{certfile, CertFile},
	      {gateway, <<"gateway.push.apple.com">>},
	      {port, 2195}]};
	{ok, CertFile, apns_dev} ->
	    {mod_applepush_service, dev_appid(AppId),
	     [{certfile, CertFile},
	      {gateway, <<"gateway.sandbox.push.apple.com">>},
	      {port, 2195}]};
	_ ->
	    undefined
    end;
push_service_cfg(<<"gcm">>, AppId, ApiKey) ->
    {mod_gcm_service, AppId,
     [{gateway, <<"https://fcm.googleapis.com/fcm/send">>},
      {apikey, ApiKey}]};
push_service_cfg(<<"webhook">>, AppId, Gateway) ->
    {mod_webhook_service, AppId,
     [{gateway, Gateway}]};
push_service_cfg(_, _, _) ->
    undefined.

push_setup(<<"applepush">>, AppId, Cfg) ->
    case proplists:get_value(certfile, Cfg) of
	undefined ->
	    KeyFile = proplists:get_value(authkeyfile, Cfg),
	    case read_file(KeyFile) of
		{ok, Key} -> {AppId, apns3_setup(Key, Cfg)};
		_ -> {AppId, <<>>}
	    end;
	CertFile ->
	    case read_file(CertFile) of
		{ok, Cert} -> {undev_appid(AppId), Cert};
		_ -> {undev_appid(AppId), <<>>}
	    end
    end;
push_setup(<<"gcm">>, AppId, Cfg) ->
    {AppId, proplists:get_value(apikey, Cfg, <<>>)};
push_setup(<<"webhook">>, AppId, Cfg) ->
    {AppId, proplists:get_value(gateway, Cfg, <<>>)};
push_setup(_, AppId, _) ->
    {AppId, <<>>}.

apns3_setup(Key, Cfg) ->
    Id = proplists:get_value(authkeyid, Cfg, <<>>),
    Team = proplists:get_value(teamid, Cfg, <<>>),
    {Key, Id, Team}.

setup_struct(apns3, {AppId, {Key, Id, Team}}) ->
    [{appid, AppId}, {key, Key}, {keyid, Id}, {teamid, Team}];
setup_struct(Type, {AppId, Data}) ->
    [{appid, AppId}, {Type, Data}].

read_file(File) ->
    case file:read_file(File) of
	{ok, Data} -> {ok, Data};
	Error -> Error
    end.

write_file(_, <<>>) ->
    {error, undefined};
write_file(Id, CertData) ->
    BaseDir = filename:dirname(os:getenv("EJABBERD_CONFIG_PATH")),
    TmpFile = filename:append(BaseDir, <<"pem">>),
    case file:write_file(TmpFile, CertData) of
	ok ->
	    {Name, Type, Ext} = case cert_type(TmpFile) of
		apns_prod -> {Id, apns_prod, <<".pem">>};
		apns_dev -> {dev_appid(Id), apns_dev, <<".pem">>};
		apns3 -> {Id, apns3, <<".p8">>};
		_ -> {Id, undefined, undefined}
	    end,
	    case Type of
		undefined ->
		    {error, undefined};
		_ ->
		    File = filename:append(BaseDir, <<Name/binary, Ext/binary>>),
		    case file:rename(TmpFile, File) of
			ok -> {ok, File, Type};
			Error -> Error
		    end
	    end;
	Error ->
	    Error
    end.

dev_appid(AppId) ->
    <<AppId/binary, "_dev">>.
undev_appid(DevId) ->
    case lists:reverse(string:tokens(binary_to_list(DevId), "_")) of
	["dev" | Id] -> iolist_to_binary(string:join(lists:reverse(Id), "_"));
	_ -> DevId
    end.

cert_type(CertFile) ->
    Subject = os:cmd("openssl x509 -in " ++ binary_to_list(CertFile) ++ " -noout -subject"),
    case {string:str(Subject, "Apple Push"), string:str(Subject, "Apple Development")} of
	{0, 0} -> key_type(CertFile);
	{_, 0} -> apns_prod;
	{0, _} -> apns_dev;
	_ -> undefined
    end.

key_type(KeyFile) ->
    Key = os:cmd("openssl pkcs8 -nocrypt -in " ++ binary_to_list(KeyFile)),
    case string:str(Key, "BEGIN PRIVATE KEY") of
	0 -> undefined;
	_ -> apns3
    end.

read_extra_config(ConfigFile) ->
    BaseDir = filename:dirname(os:getenv("EJABBERD_CONFIG_PATH")),
    File = filename:append(BaseDir, ConfigFile),
    case catch ejabberd_config:get_plain_terms_file(File) of
	[{append_host_config, Config}] -> Config;
	_ -> []
    end.

update_extra_config(ConfigFile, Host, Config) ->
    OldConfig = read_extra_config(ConfigFile),
    NewConfig = case Config of
	[] -> lists:keydelete(Host, 1, OldConfig);
	_ -> lists:keystore(Host, 1, OldConfig, {Host, Config})
    end,
    write_extra_config(ConfigFile, NewConfig).

write_extra_config(ConfigFile, []) ->
    write_yaml_config(ConfigFile, "# Empty configuration file\n");
write_extra_config(ConfigFile, Config) ->
    case catch fast_yaml:encode([{append_host_config, Config}]) of
	{'EXIT', R1} ->
	    ?ERROR_MSG("Can not encode config: ~p", [R1]),
	    {error, R1};
	Yaml ->
	    write_yaml_config(ConfigFile, Yaml)
    end.

write_yaml_config(ConfigFile, Yaml) ->
    BaseDir = filename:dirname(os:getenv("EJABBERD_CONFIG_PATH")),
    File = filename:append(BaseDir, ConfigFile),
    case file:write_file(File, Yaml) of
	{error, R2} ->
	    ?ERROR_MSG("Can not write config: ~p", [R2]),
	    {error, R2};
	ok ->
	    ok
    end.

user_action(User, Server, Fun, OK) ->
    case ejabberd_auth:is_user_exists(User, Server) of
      true ->
	  case catch Fun() of
	    OK -> 0;
	    _ -> 1
	  end;
      false -> 404
    end.

session_info(#session{usr = {U,S,R}, priority = Priority, sid = {Sid, Pid}}) ->
    {_User, Resource, Show, _Status} = ejabberd_c2s:get_presence(Pid),
    ConnDateTime = calendar:now_to_local_time(Sid),
    State = lists:nth(3, sys:get_state(Pid)),
    Features = case ejabberd_c2s:get_aux_field(caps_resources, State) of
                {ok, Rs} ->
                    case gb_trees:lookup({U,S,R}, Rs) of
                        {value, Caps} -> mod_caps:get_features(S, Caps);
                        none -> []
                    end;
                error ->
                    []
           end,
    [{resource, Resource},
     {presence, Show},
     case Priority of
       I when is_integer(I) -> {priority, integer_to_binary(I)};
       _ -> {priority, <<"undefined">>}
     end,
     {since, jlib:timestamp_to_iso(ConnDateTime)},
     {msg_queue_len, integer_to_binary(State#state.queue_len)},
     {ack_queue_len, integer_to_binary(queue:len(State#state.ack_queue))},
     {standby, jlib:atom_to_binary(State#state.standby)},
     {reception, jlib:atom_to_binary(State#state.reception)},
     {features, str:join(Features, <<",">>)}
    ].

last_info(U, S) ->
    case catch mod_last:get_last_info(U, S) of
	{ok, T1, Reason} ->
	    LastDateTime = calendar:now_to_local_time(seconds_to_now(T1)),
	    %T2 = now_to_seconds(os:timestamp()),
	    %{Days, {H, M, _S}} = calendar:seconds_to_daystime(T2-T1),
	    [{last, jlib:timestamp_to_iso(LastDateTime)},
	     {reason, Reason}];
	_ ->
	    []
    end.

ejabberd_command(Cmd, Args, Default) ->
    case catch ejabberd_commands:execute_command(Cmd, Args) of
	{'EXIT', _} -> Default;
	{error, _} -> Default;
	unknown_command -> Default;
	Result -> Result
    end.

workers_number(Supervisor) ->
    case whereis(Supervisor) of
	undefined -> 0;
	_ -> proplists:get_value(active, supervisor:count_children(Supervisor))
    end.

%now_to_seconds({MegaSecs, Secs, _MicroSecs}) ->
%    MegaSecs * 1000000 + Secs.

seconds_to_now(Secs) ->
    {Secs div 1000000, Secs rem 1000000, 0}.

build_stamp(Module) ->
    {Y,M,D,HH,MM,SS} = proplists:get_value(time, Module:module_info(compile)),
    DateTime = {{Y,M,D},{HH,MM,SS}},
    {jlib:timestamp_to_iso(DateTime), calendar:datetime_to_gregorian_seconds(DateTime)}.

opt_type(push_cache_db_type) ->
    fun(V) when is_atom(V) -> V end;
opt_type(_) -> [push_cache_db_type].
