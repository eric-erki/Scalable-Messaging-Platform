%%%----------------------------------------------------------------------
%%% File    : mod_gcm.erl
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

-module(mod_gcm).

-compile([{parse_transform, ejabberd_sql_pt}]).

-behaviour(ejabberd_config).
-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2,
	 stop/1,
	 push_from_message/11,
	 enable_offline_notification/5,
	 disable_notification/3,
	 receive_offline_packet/3,
         %% other clients may be online, but we still want to push to this one
         send_offline_packet_notification/5,
	 resend_badge/1,
	 multi_resend_badge/1,
	 offline_resend_badge/0,
         device_reset_badge/5,
	 remove_user/2,
         transform_module_options/1,
         process_sm_iq/3,
         export/1,
	 enc_key/1,
	 dec_key/1,
	 enc_val/2,
	 dec_val/2,
	 set_local_badge/3,
	 badge_reset/5]).

-export([get_tokens_by_jid/1, mod_opt_type/1,
	 depends/2, opt_type/1]).


-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("mod_privacy.hrl").
-include("ejabberd_sql_pt.hrl").

-record(gcm_cache, {us, device_id, options}).


start(Host, Opts) ->
    case init_host(Host) of
	true ->
            init_db(gen_mod:db_type(Host, Opts, ?MODULE), Host),
            ejabberd_hooks:add(p1_push_from_message, Host,
                               ?MODULE, push_from_message, 50),
	    ejabberd_hooks:add(p1_push_enable_offline, Host,
			       ?MODULE, enable_offline_notification, 50),
	    ejabberd_hooks:add(p1_push_disable, Host,
			       ?MODULE, disable_notification, 50),
            ejabberd_hooks:add(remove_user, Host,
                               ?MODULE, remove_user, 50),
	    ejabberd_hooks:add(offline_message_hook, Host,
			       ?MODULE, receive_offline_packet, 35),
            ejabberd_hooks:add(p1_push_badge_reset, Host,
                               ?MODULE, badge_reset, 50),
            IQDisc = gen_mod:get_opt(
                       iqdisc, Opts, fun gen_iq_handler:check_type/1,
                       one_queue),
            gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_P1_PUSH_GCM,
                                          ?MODULE, process_sm_iq, IQDisc);
	false ->
	    ?ERROR_MSG("Cannot start ~s on host ~s.
               Check you had the correct license for the domain and # of
               registered users", [?MODULE, Host]),
	    ok
    end.

init_db(mnesia, _Host) ->
    mnesia:create_table(
      gcm_cache,
      [{disc_copies, [node()]},
       {attributes, record_info(fields, gcm_cache)}, {type, bag}]),
    mnesia:add_table_index(gcm_cache, device_id),
    mnesia:add_table_copy(gcm_cache, node(), ram_copies);
init_db(p1db, Host) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(gcm_cache,
		    [{group, Group}, {nosync, true},
		     {schema, [{keys, [server, user, device_id]},
			       {vals, [app_id, send_body,
				       send_from, local_badge,
				       timestamp]},
			       {enc_key, fun ?MODULE:enc_key/1},
			       {dec_key, fun ?MODULE:dec_key/1},
			       {enc_val, fun ?MODULE:enc_val/2},
			       {dec_val, fun ?MODULE:dec_val/2}]}]);
init_db(_, _) ->
    ok.

stop(Host) ->
    ejabberd_hooks:delete(p1_push_from_message, Host,
			  ?MODULE, push_from_message, 50),
    ejabberd_hooks:delete(p1_push_enable_offline, Host,
                          ?MODULE, enable_offline_notification, 50),
    ejabberd_hooks:delete(p1_push_disable, Host,
			  ?MODULE, disable_notification, 50),
    ejabberd_hooks:delete(remove_user, Host,
                          ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(offline_message_hook, Host,
			  ?MODULE, receive_offline_packet, 35),
    ejabberd_hooks:delete(p1_push_badge_reset, Host,
			  ?MODULE, badge_reset, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_P1_PUSH).



badge_reset(Acc, JID, Notification, _AppID, Count) ->
    Type = fxml:get_path_s(Notification, [{elem, <<"type">>}, cdata]),
    case Type of
	<<"gcm">> ->
	    DeviceID = fxml:get_path_s(Notification, [{elem, <<"id">>}, cdata]),
            ?INFO_MSG("Reseting badge for ~s with applepush token ~p",[jid:to_string(JID),DeviceID]),
	    case DeviceID of
		ID1 when is_binary(ID1), size(ID1) > 0 ->
		    {stop, set_local_badge(JID, ID1, Count)};
                _ ->
                    Acc
            end;
	_ ->
	    Acc
    end.

set_local_badge(JID, DeviceID, Count) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            set_local_badge_mnesia(JID, DeviceID, Count);
	p1db ->
	    set_local_badge_p1db(JID, DeviceID, Count);
        sql ->
            set_local_badge_sql(JID, DeviceID, Count)
    end.

set_local_badge_mnesia(JID, DeviceID, Count) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    case mnesia:dirty_match_object({gcm_cache, LUS, DeviceID, '_'}) of
        [] ->
            {error, device_not_found};
        [#gcm_cache{options=Opts}=Record] ->
            %% The table is of type bag. If we just dirty_write, it will insert a new item, not update the existing one.
            %% This dirty_delete + dirty_write aren't atomic so entries could be lost in the middle.. but this is what
            %% store_cache_mnesia() uses
            mnesia:dirty_delete_object(Record),
            mnesia:dirty_write(Record#gcm_cache{options = lists:keystore(local_badge, 1, Opts, {local_badge, Count})})
    end.

set_local_badge_p1db(JID, DeviceID, Count) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Key = usd2key(LUser, LServer, DeviceID),
    case p1db:get(gcm_cache, Key) of
	{ok, Val, _VClock} ->
	    Opts = p1db_to_opts(Val),
	    NewOpts = lists:keystore(local_badge, 1, Opts, {local_badge, Count}),
	    NewVal = opts_to_p1db(NewOpts),
	    p1db:insert(gcm_cache, Key, NewVal);
	{error, notfound} ->
	    {error, device_not_found};
	{error, _} = Err ->
	    Err
    end.

set_local_badge_sql(#jid{luser =LUser, lserver=LServer}, DeviceID, Count) ->
    case ejabberd_sql:sql_query(
           LServer,
           ?SQL("UPDATE gcm_cache SET local_badge=%(Count)d"
                " WHERE username=%(LUser)s and device_id=%(DeviceID)s")) of
        {updated, 1} ->
            ok;
        {updated, 0} ->
            {error, device_not_found}  %%same contract than set_local_badge_mnesia
    end.
push_from_message(Val, From, To, Packet, Notification, AppID, SendBody, SendFrom, Badge, First, FirstFromUser) ->
    Type = fxml:get_path_s(Notification, [{elem, <<"type">>}, cdata]),
    case Type of
	<<"gcm">> ->
	    DeviceID = fxml:get_path_s(Notification, [{elem, <<"id">>}, cdata]),
            SilentPushEnabled = gen_mod:get_module_opt(
                                  To#jid.lserver, ?MODULE,
                                  silent_push_enabled,
                                  mod_opt_type(silent_push_enabled),
                                  false),
            case ejabberd_push:build_push_packet_from_message(From, To, Packet, DeviceID, AppID,
                                                              SendBody, SendFrom, Badge,
                                                              First, FirstFromUser,
                                                              SilentPushEnabled,
							      ?MODULE) of
                skip ->
                    {stop, skipped};
                {V, Silent} ->
                    route_push_notification(To#jid.lserver, To, AppID, V),
                    {stop, if Silent -> sent_silent; true -> sent end}
            end;
        _ ->
            Val
    end.

route_push_notification(Host, JID, AppId, PushPacket) ->
    PushService = get_push_service(Host, JID, AppId),
    ServiceJID = jid:make(<<"">>, PushService, <<"">>),
    ejabberd_router:route(JID, ServiceJID, PushPacket).


enable_offline_notification(JID, Notification, SendBody, SendFrom, AppID1) ->
    Type = fxml:get_path_s(Notification, [{elem, <<"type">>}, cdata]),
    case Type of
	<<"gcm">> ->
	    DeviceID = fxml:get_path_s(Notification, [{elem, <<"id">>}, cdata]),
	    case DeviceID of
		ID1 when is_binary(ID1), size(ID1) > 0 ->
		    AppID =
			case fxml:get_path_s(Notification,
					    [{elem, <<"appid">>}, cdata]) of
			    <<"">> -> AppID1;
			    A -> A
			end,
		    TimeStamp = p1_time_compat:system_time(seconds),
		    store_cache(JID, ID1, AppID, SendBody, SendFrom, TimeStamp);
		_ ->
		    ok
	    end,
	    stop;
	_ ->
	    ok
    end.

disable_notification(JID, Notification, _AppID) ->
    Type = fxml:get_path_s(Notification, [{elem, <<"type">>}, cdata]),
    case Type of
	<<"gcm">> ->
	    DeviceID = fxml:get_path_s(Notification, [{elem, <<"id">>}, cdata]),
            ?INFO_MSG("Disabling p1:push for ~s with gcm token ~p",[jid:to_string(JID),DeviceID]),
	    case DeviceID of
		ID1 when is_binary(ID1), size(ID1) > 0 ->
	            delete_cache(JID, ID1),
        	    stop;
                _ ->
                    ok
            end;
	_ ->
	    ok
    end.

do_send_offline_packet_notification(From, To, Packet, ID, AppID, SendBody, SendFrom, BadgeCount) ->
    SilentPushEnabled = gen_mod:get_module_opt(
                          To#jid.lserver, ?MODULE,
                          silent_push_enabled,
                          mod_opt_type(silent_push_enabled),
                          false),
    case ejabberd_push:build_push_packet_from_message(From, To, Packet, ID, AppID,
                                                      SendBody, SendFrom, BadgeCount,
                                                      BadgeCount == 0, BadgeCount == 0,
                                                      SilentPushEnabled, ?MODULE) of
        skip ->
            ok;
        {V, _Silent} ->
            route_push_notification(To#jid.lserver, To, AppID, V)
    end.

send_offline_packet_notification(From, To, Packet, DeviceID, BadgeCount) ->
    case DeviceID of
        ID1 when is_binary(ID1), size(ID1) > 0 ->
            case lookup_cache(To, ID1) of
                [{ID, AppID, SendBody, SendFrom, _LocalBadge}] -> %% LocalBadge is already counted here..
                    do_send_offline_packet_notification(From, To, Packet, ID, AppID, SendBody, SendFrom, BadgeCount);
                _ ->
                    ok
            end;
        _ ->
            ok
    end.
receive_offline_packet(From, To, Packet) ->
    ?DEBUG("mod_gcm offline~n\tfrom ~p~n\tto ~p~n\tpacket ~P~n",
	   [From, To, Packet, 8]),
    Host = To#jid.lserver,
    case gen_mod:is_loaded(Host, mod_gcm) of
	true ->
	    case lookup_cache(To) of
		false ->
		    ok;
                DeviceList ->
                    Offline = ejabberd_hooks:run_fold(
                                count_offline_messages,
                                Host,
                                0,
                                [To#jid.luser, Host]) + 1,
                    lists:foreach(fun({ID, AppID, SendBody, SendFrom, LocalBadge}) ->
                                          ?DEBUG("lookup: ~p~n", [{ID, AppID, SendBody, SendFrom, LocalBadge}]),
                                          do_send_offline_packet_notification(From, To, Packet, ID, AppID, SendBody, SendFrom, Offline + LocalBadge)
                                  end, DeviceList)
            end;
	false ->
	    ok
    end.


process_sm_iq(From, To, #iq{type = Type, sub_el = SubEl} = IQ) ->
    case {Type, SubEl} of
	{set, #xmlel{name = <<"disable">>}} ->
            Host = To#jid.lserver,
            DeviceID = fxml:get_tag_attr_s(<<"id">>, SubEl),
            case lookup_cache(To, DeviceID) of
                [{_ID, AppID, _SendBody, _SendFrom, _LocalBadge}] ->
                    PushService = get_push_service(Host, To, AppID),
                    ServiceJID = jid:make(<<"">>, PushService, <<"">>),
                    if
                        From#jid.lserver == ServiceJID#jid.lserver ->
                            delete_cache(To, DeviceID),
                            IQ#iq{type = result, sub_el = []};
                        true ->
                            IQ#iq{type = error,
                                  sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
                    end;
                _ ->
                    IQ#iq{type = error,
                          sub_el = [SubEl, ?ERR_ITEM_NOT_FOUND]}
            end;
	{set, #xmlel{name = <<"update">>}} ->
	    Host = To#jid.lserver,
	    OldDeviceID = fxml:get_tag_attr_s(<<"oldid">>, SubEl),
            NewDeviceID = fxml:get_tag_attr_s(<<"id">>, SubEl),
            case lookup_cache(To, OldDeviceID) of
		[{_ID, AppID, _SendBody, _SendFrom, _LocalBadge}] ->
		    PushService = get_push_service(Host, To, AppID),
		    ServiceJID = jid:make(<<"">>, PushService, <<"">>),
		    if
			From#jid.lserver == ServiceJID#jid.lserver ->
			    update_cache(To, OldDeviceID, NewDeviceID),
			    IQ#iq{type = result, sub_el = []};
			true ->
			    IQ#iq{type = error,
				  sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
		    end;
		_ ->
		    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
	    end;
        {set, _} ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
        {get, _} ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
    end.


device_reset_badge(Host, To, DeviceID, AppID, Badge) ->
    ?INFO_MSG("Sending reset badge (~p) push to ~p ~p", [Badge, To, DeviceID]),
    PushService = get_push_service(Host, To, AppID),
    ServiceJID = jid:make(<<"">>, PushService, <<"">>),
    LBadge = jlib:integer_to_binary(Badge),
    Packet1 =
        #xmlel{name = <<"message">>, attrs = [],
               children =
               [#xmlel{name = <<"push">>, attrs = [{<<"xmlns">>, ?NS_P1_PUSH}],
                       children =
                       [#xmlel{name = <<"id">>, attrs = [],
                               children =
                               [{xmlcdata, DeviceID}]},
                        #xmlel{name = <<"badge">>, attrs = [],
                               children =
                               [{xmlcdata, LBadge}]}]}]},
    ejabberd_router:route(To, ServiceJID, Packet1).



resend_badge(To) ->
    Host = To#jid.lserver,
    case gen_mod:is_loaded(Host, mod_gcm) of
	true ->
	    case lookup_cache(To) of
		false ->
		    {error, "no cached data for the user"};
                DeviceList ->
                    lists:foreach(fun({ID, AppID, SendBody, SendFrom, LocalBadge}) ->
                        ?DEBUG("lookup: ~p~n", [{ID, AppID, SendBody, SendFrom, LocalBadge}]),
                        PushService = get_push_service(Host, To, AppID),
                        ServiceJID = jid:make(<<"">>, PushService, <<"">>),
                        Offline = ejabberd_hooks:run_fold(
                                    count_offline_messages,
                                    Host,
                                    0,
                                    [To#jid.luser, Host]),
                        if
                            Offline == 0 ->
                                ok;
                            true ->
                                Badge = jlib:integer_to_binary(Offline + LocalBadge),
                                Packet1 =
                                    #xmlel{name = <<"message">>,
                                           attrs = [],
                                           children =
                                           [#xmlel{name = <<"push">>,
                                                   attrs = [{<<"xmlns">>, ?NS_P1_PUSH}],
                                                   children =
                                                   [#xmlel{name = <<"id">>,
                                                           attrs = [],
                                                           children =
                                                           [{xmlcdata, ID}]},
                                                    #xmlel{name = <<"badge">>,
                                                           attrs = [],
                                                           children =
                                                           [{xmlcdata, Badge}]}]}]},
                                ejabberd_router:route(To, ServiceJID, Packet1)
                        end
                    end, DeviceList)
                end;
	false ->
	    {error, "mod_gcm is not loaded"}
    end.

multi_resend_badge(JIDs) ->
    lists:foreach(fun resend_badge/1, JIDs).

offline_resend_badge() ->
    USs = mnesia:dirty_all_keys(gcm_cache),
    JIDs = lists:map(fun({U, S}) -> jid:make(U, S, <<"">>) end, USs),
    multi_resend_badge(JIDs).

lookup_cache(JID) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            lookup_cache_mnesia(JID);
	p1db ->
	    lookup_cache_p1db(JID);
        sql ->
            lookup_cache_sql(JID)
    end.

lookup_cache_mnesia(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    do_lookup_cache_mnesia(#gcm_cache{us = LUS, _ = '_'}).

lookup_cache_p1db(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(gcm_cache, USPrefix) of
	{ok, L} ->
	    lists:map(
	      fun({Key, Val, _VClock}) ->
		      DeviceID = key2did(USPrefix, Key),
		      Opts = p1db_to_opts(Val),
		      format_options(DeviceID, Opts)
	      end, L);
	{error, _} = Err ->
	    Err
    end.

lookup_cache_sql(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    do_lookup_cache_sql(
      LServer,
      ?SQL("select @(device_id)s, @(app_id)s, @(send_body)s,"
           " @(send_from)s, @(local_badge)s from gcm_cache "
           "where username=%(LUser)s")).

lookup_cache(JID, DeviceID) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            lookup_cache_mnesia(JID, DeviceID);
	p1db ->
	    lookup_cache_p1db(JID, DeviceID);
        sql ->
            lookup_cache_sql(JID, DeviceID)
    end.

lookup_cache_mnesia(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    do_lookup_cache_mnesia(#gcm_cache{device_id = DeviceID, us = LUS, _ = '_'}).

lookup_cache_p1db(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Key = usd2key(LUser, LServer, DeviceID),
    case p1db:get(gcm_cache, Key) of
	{ok, Val, _VClock} ->
	    Opts = p1db_to_opts(Val),
	    [format_options(DeviceID, Opts)];
	{error, _} ->
	    false
    end.

lookup_cache_sql(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    do_lookup_cache_sql(
      LServer,
      ?SQL("select @(device_id)s, @(app_id)s, @(send_body)s,"
           " @(send_from)s, @(local_badge)s from gcm_cache "
           "where username=%(LUser)s and device_id=%(DeviceID)s")).

do_lookup_cache_mnesia(MatchSpec) ->
    case mnesia:dirty_match_object(MatchSpec) of
	EntryList when is_list(EntryList) ->
            lists:map(fun(#gcm_cache{device_id = DeviceID, options = Options}) ->
			      format_options(DeviceID, Options)
            end, EntryList);
	_ ->
	    false
    end.

format_options(DeviceID, Options) ->
    AppID = proplists:get_value(appid, Options, <<"gcm.localhost">>),
    SendBody = proplists:get_value(send_body, Options, none),
    SendFrom = proplists:get_value(send_from, Options, true),
    LocalBadge = proplists:get_value(local_badge, Options, 0),
    {DeviceID, AppID, SendBody, SendFrom, LocalBadge}.

do_lookup_cache_sql(LServer, Query) ->
    case ejabberd_sql:sql_query(LServer, Query) of
        {selected, EntryList} ->
            lists:map(
              fun({DeviceID, AppID, SSendBody, SSendFrom, LocalBadgeStr}) ->
                      SendBody =
                          case SSendBody of
                              <<"A">> -> all;
                              <<"U">> -> first_per_user;
                              <<"F">> -> first;
                              _ -> none
                          end,
                      SendFrom =
                          case SSendFrom of
                              <<"J">> -> jid;
                              <<"U">> -> username;
                              <<"N">> -> name;
                              _ -> none
                          end,
                      LocalBadge =
                        if
                            is_binary(LocalBadgeStr) ->
                                jlib:binary_to_integer(LocalBadgeStr);
                            true ->
                                0  %%is null
                        end,
                      {DeviceID, AppID, SendBody, SendFrom, LocalBadge}
            end, EntryList);
	_ ->
	    false
    end.


store_cache(JID, DeviceID, AppID, SendBody, SendFrom, TimeStamp) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        sql ->
	    store_cache_sql(JID, DeviceID, AppID, SendBody, SendFrom);
	DBType ->
	    Options = [{appid, AppID},
		       {send_body, SendBody},
		       {send_from, SendFrom},
		       {timestamp, TimeStamp}],
	    case DBType of
		mnesia ->
		    store_cache_mnesia(JID, DeviceID, Options);
		p1db ->
		    store_cache_p1db(JID, DeviceID, Options);
		_ ->
		    erlang:error({unsupported_db_type, DBType})
	    end
    end.


store_cache_mnesia(JID, DeviceID, Options) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    R = #gcm_cache{us = LUS,
			 device_id = DeviceID,
			 options = Options},
   case mnesia:dirty_match_object({gcm_cache, LUS, DeviceID, '_'}) of
        [] ->
            %%no previous entry, just write the new record
            mnesia:dirty_write(R);

        [R] ->
            %%previous entry exists but is equal, don't do anything
            ok;

        [#gcm_cache{options = OldOptions} = OldRecord] ->
            case lists:keyfind(local_badge, 1, OldOptions) of
                false ->
                    %% There was no local_badge set in previous record.
                    %% As the record don't match anyway, write the new one
                    mnesia:dirty_delete_object(OldRecord),
                    mnesia:dirty_write(R);
                {local_badge, Count} ->
                    %% Use the new record, but copy the previous local_badge value
                    %% We keep that as local_badge isn't provide in the enable notification
                    %% call.
                    mnesia:dirty_delete_object(OldRecord),
                    mnesia:dirty_write(R#gcm_cache{options = [{local_badge, Count} | Options]})
            end
       %% Other cases are error. If there is more than one entry for the same UserServer and same DeviceID,
       %% it is an error.
    end.

store_cache_p1db(JID, DeviceID, Options) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Key = usd2key(LUser, LServer, DeviceID),
    Val = opts_to_p1db(Options),
    case p1db:get(gcm_cache, Key) of
	{ok, Val, _VClock} ->
	    %%previous entry exists but is equal, don't do anything
            ok;
	{error, notfound} ->
	    %%no previous entry, just write the new record
	    p1db:insert(gcm_cache, Key, Val);
	{ok, OldVal, _VClock} ->
	    OldOptions = p1db_to_opts(OldVal),
	    case lists:keyfind(local_badge, 1, OldOptions) of
                false ->
		    %% There was no local_badge set in previous record.
                    %% As the record don't match anyway, write the new one
		    p1db:insert(gcm_cache, Key, Val);
		{local_badge, Count} ->
		    %% Use the new record, but copy the previous local_badge value
                    %% We keep that as local_badge isn't provide in the enable notification
                    %% call.
		    NewVal = opts_to_p1db([{local_badge, Count} | Options]),
		    p1db:insert(gcm_cache, Key, NewVal)
	    end;
	{error, _} = Err ->
	    Err
    end.

store_cache_sql(JID, DeviceID, AppID, SendBody, SendFrom) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    SSendBody =
        case SendBody of
            all -> <<"A">>;
            first_per_user -> <<"U">>;
            first -> <<"F">>;
            _ -> <<"-">>
        end,
    SSendFrom =
        case SendFrom of
            jid -> <<"J">>;
            username -> <<"U">>;
            name -> <<"N">>;
            _ -> <<"-">>
        end,
    F = fun() ->
                %% We must keep the previous local_badge if it exists.
                ?SQL_UPSERT_T(
                   "gcm_cache",
                   ["!username=%(LUser)s",
                    "!device_id=%(DeviceID)s",
                    "app_id=%(AppID)s",
                    "send_body=%(SSendBody)s",
                    "send_from=%(SSendFrom)s",
                    "-local_badge=0"
                   ])
        end,
        {atomic, _} = sql_queries:sql_transaction(LServer, F).

update_cache(JID, OldDeviceID, NewDeviceID) ->
    case lookup_cache(JID, OldDeviceID) of
	[{_ID, AppID, SendBody, SendFrom, _LocalBadge}] ->
	    delete_cache(JID, OldDeviceID),
	    TimeStamp = p1_time_compat:system_time(seconds),
	    store_cache(JID, NewDeviceID, AppID, SendBody, SendFrom, TimeStamp);
	_ -> ok
    end.

delete_cache(JID, DeviceID) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            delete_cache_mnesia(JID, DeviceID);
	p1db ->
	    delete_cache_p1db(JID, DeviceID);
        sql ->
            delete_cache_sql(JID, DeviceID)
    end.

delete_cache_mnesia(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    [ mnesia:dirty_delete_object(Obj) || Obj <-  mnesia:dirty_match_object(#gcm_cache{device_id = DeviceID, us = LUS, _ = '_'})].

delete_cache_p1db(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Key = usd2key(LUser, LServer, DeviceID),
    [p1db:delete(gcm_cache, Key)].

delete_cache_sql(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("delete from gcm_cache"
           " where username=%(LUser)s and"
           " device_id=%(DeviceID)s")).

delete_cache(JID) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            delete_cache_mnesia(JID);
	p1db ->
	    delete_cache_p1db(JID);
        sql ->
            delete_cache_sql(JID)
    end.

delete_cache_mnesia(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    catch mnesia:dirty_delete(gcm_cache, LUS).

delete_cache_p1db(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(gcm_cache, USPrefix) of
	{ok, L} ->
	    lists:foreach(
	      fun({Key, _Val, _VClock}) ->
		      p1db:delete(gcm_cache, Key)
	      end, L);
	{error, _} = Err ->
	    Err
    end.

delete_cache_sql(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    ejabberd_sql:sql_query(
      LServer,
      ?SQL("delete from gcm_cache"
           " where username=%(LUser)s")).


remove_user(User, Server) ->
    delete_cache(jid:make(User, Server, <<"">>)).

get_push_service(Host, JID, AppID) ->
    PushServices =
	gen_mod:get_module_opt(
	  Host, ?MODULE,
	  push_services,
          fun(L) when is_list(L) -> L end,
          []),
    PushService =
	case lists:keysearch(AppID, 1, PushServices) of
	    false ->
		DefaultServices =
		    gen_mod:get_module_opt(
		      Host, ?MODULE,
		      default_services,
                      fun(L) when is_list(L) -> L end,
                      []),
		case lists:keysearch(JID#jid.lserver, 1, DefaultServices) of
		    false ->
			gen_mod:get_module_opt(
			  Host, ?MODULE,
			  default_service,
                          fun(S) when is_binary(S) -> S end,
                          <<"gcm.localhost">>);
		    {value, {_, PS}} ->
			PS
		end;
	    {value, {AppID, PS}} ->
		PS
	end,
    PushService.

usd2key(LUser, LServer, DeviceID) ->
    <<LServer/binary, 0, LUser/binary, 0, DeviceID/binary>>.

key2did(USPrefix, Key) ->
    Size = size(USPrefix),
    <<_:Size/binary, DeviceID/binary>> = Key,
    DeviceID.

us_prefix(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary, 0>>.

p1db_to_opts(Val) ->
    binary_to_term(Val).

opts_to_p1db(Opts) ->
    term_to_binary(Opts).

%% P1DB/SQL schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, SDeviceID]) ->
    <<Server/binary, 0, User/binary, 0, SDeviceID/binary>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, SDeviceID/binary>> = UKey,
    [Server, User, SDeviceID].

enc_val(_, [AppID, SendBody, SendFrom, LocalBadge, TimeStamp]) ->
    Options = [{appid, AppID},
	       {send_body, jlib:binary_to_atom(SendBody)},
	       {send_from, jlib:binary_to_atom(SendFrom)},
	       {local_badge, jlib:binary_to_integer(LocalBadge)},
	       {timestamp, jlib:binary_to_integer(TimeStamp)}],
    opts_to_p1db(Options).

dec_val(_, Bin) ->
    Options = p1db_to_opts(Bin),
    [proplists:get_value(appid, Options, <<"gcm.localhost">>),
     jlib:atom_to_binary(proplists:get_value(send_body, Options, none)),
     jlib:atom_to_binary(proplists:get_value(send_from, Options, true)),
     jlib:integer_to_binary(proplists:get_value(local_badge, Options, 0)),
     jlib:integer_to_binary(proplists:get_value(timestamp, Options, 0))].

export(_Server) ->
    [{gcm_cache,
      fun(Host, #gcm_cache{us = {LUser, LServer},
                                 device_id = DeviceID,
                                 options = Options})
	 when LServer == Host ->
              AppID = proplists:get_value(appid, Options, "gcm.localhost"),
              SendBody = proplists:get_value(send_body, Options, none),
              SendFrom = proplists:get_value(send_from, Options, true),
              SSendBody =
                  case SendBody of
                      all -> "A";
                      first_per_user -> "U";
                      first -> "F";
                      _ -> "-"
                  end,
              SSendFrom =
                  case SendFrom of
                      jid -> "J";
                      username -> "U";
                      name -> "N";
                      _ -> "-"
                  end,
              [?SQL("delete from gcm_cache"
                    " where username=%(LUser)s and"
                    " device_id=%(DeviceID)s;"),
               ?SQL("insert into gcm_cache(username, device_id, app_id, "
                    "                            send_body, send_from) "
                    "values (%(LUser)s, %(DeviceID)s, "
                    "%(AppID)s, %(SSendBody)s, %(SSendFrom)s);")];
	 (_Host, _R) ->
      	      []
      end
     }].


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal module protection

-define(VALID_HOSTS, []). % default is unlimited use
-define(MAX_USERS, 0). % default is unlimited use

init_host(VHost) ->
    case ?VALID_HOSTS of
    [] -> % unlimited use
        true;
    ValidList -> % limited use
        init_host(VHost, ValidList)
    end.
init_host([], _) ->
    false;
init_host(VHost, ValidEncryptedList) ->
    EncryptedHost = erlang:md5(lists:reverse(VHost)),
    case lists:member(EncryptedHost, ValidEncryptedList) of
    true ->
	case ?MAX_USERS of
	0 -> true;
	N -> ejabberd_auth:get_vh_registered_users_number(VHost) =< N
	end;
    false ->
	case string:chr(VHost, $.) of
	0 -> false;
	Pos -> init_host(string:substr(VHost, Pos+1), ValidEncryptedList)
	end
    end.

%% Debug commands
%% JID is of form
get_tokens_by_jid(JIDString) when is_binary(JIDString) ->
	get_tokens_by_jid(jid:from_string(JIDString));
get_tokens_by_jid(#jid{luser = LUser, lserver = LServer}) ->
    LUS = {LUser, LServer},
    [I || {gcm_cache,_,I,_} <- mnesia:dirty_read(gcm_cache, LUS)].

transform_module_options(Opts) ->
    lists:map(
      fun({backend, sql}) ->
              ?WARNING_MSG("Option 'backend' is obsoleted, "
                           "use 'db_type' instead", []),
              {db_type, sql};
         ({backend, mnesia}) ->
              ?WARNING_MSG("Option 'backend' is obsoleted, "
                           "use 'db_type' instead", []),
              {db_type, mnesia};
	 ({backend, p1db}) ->
	      ?WARNING_MSG("Option 'backend' is obsoleted, "
			   "use 'db_type' instead", []),
	      {db_type, p1db};
         (Opt) ->
              Opt
      end, Opts).

depends(_Host, _Opts) ->
    [].

mod_opt_type(db_type) ->
    fun(DB) when DB == p1db;
		 DB == mnesia;
		 DB == sql ->
	    DB
    end;
mod_opt_type(default_service) ->
    fun (S) when is_binary(S) -> S end;
mod_opt_type(default_services) ->
    fun (L) when is_list(L) -> L end;
mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(push_services) ->
    fun (L) when is_list(L) -> L end;
mod_opt_type(silent_push_enabled) ->
    fun (L) when is_boolean(L) -> L end;
mod_opt_type(_) ->
    [db_type, default_service, default_services, iqdisc,
     p1db_group, push_services, silent_push_enabled].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
