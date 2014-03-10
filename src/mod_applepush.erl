%%%----------------------------------------------------------------------
%%% File    : mod_applepush.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Push module support
%%% Created :  5 Jun 2009 by Alexey Shchepin <alexey@process-one.net>
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
%%%----------------------------------------------------------------------

-module(mod_applepush).
-author('alexey@process-one.net').

-behaviour(gen_mod).

-compile(export_all).

-export([start/2,
	 stop/1,
	 push_notification/8,
	 push_notification_with_custom_fields/9,
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
    set_local_badge/3]).


%% Debug commands
-export([get_tokens_by_jid/1]).


-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("mod_privacy.hrl").

-define(NS_P1_PUSH, <<"p1:push">>).
-define(NS_P1_PUSHED, <<"p1:pushed">>).
-define(NS_P1_ATTACHMENT, <<"http://process-one.net/attachement">>).

-record(applepush_cache, {us, device_id, options}).


start(Host, Opts) ->
    case init_host(Host) of
	true ->
            init_db(gen_mod:db_type(Opts), Host),
	    ejabberd_hooks:add(p1_push_notification, Host,
			       ?MODULE, push_notification, 50),
	    ejabberd_hooks:add(p1_push_notification_custom, Host,
			       ?MODULE, push_notification_with_custom_fields, 50),
	    ejabberd_hooks:add(p1_push_enable_offline, Host,
			       ?MODULE, enable_offline_notification, 50),
	    ejabberd_hooks:add(p1_push_disable, Host,
			       ?MODULE, disable_notification, 50),
            ejabberd_hooks:add(remove_user, Host,
                               ?MODULE, remove_user, 50),
	    ejabberd_hooks:add(offline_message_hook, Host,
			       ?MODULE, receive_offline_packet, 35),
            IQDisc = gen_mod:get_opt(
                       iqdisc, Opts, fun gen_iq_handler:check_type/1,
                       one_queue),
            gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_P1_PUSH,
                                          ?MODULE, process_sm_iq, IQDisc);
	false ->
	    ?ERROR_MSG("Cannot start ~s on host ~s. 
               Check you had the correct license for the domain and # of 
               registered users", [?MODULE, Host]),
	    ok
    end.

init_db(mnesia, _Host) ->
    mnesia:create_table(
      applepush_cache,
      [{disc_copies, [node()]},
       {attributes, record_info(fields, applepush_cache)}, {type, bag}]),
    mnesia:add_table_index(applepush_cache, device_id),
    mnesia:add_table_copy(applepush_cache, node(), ram_copies);
init_db(p1db, Host) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(applepush_cache,
		    [{group, Group},
		     {schema, [{keys, [server, user, device_id]},
			       {vals, [app_id, send_body,
				       send_from, local_badge,
				       timestamp]},
			       {enc_key, fun enc_key/1},
			       {dec_key, fun dec_key/1},
			       {enc_val, fun enc_val/2},
			       {dec_val, fun dec_val/2}]}]);
init_db(_, _) ->
    ok.

stop(Host) ->
    ejabberd_hooks:delete(p1_push_notification, Host,
			  ?MODULE, push_notification, 50),
    ejabberd_hooks:delete(p1_push_notification_custom, Host,
			  ?MODULE, push_notification_with_custom_fields, 50),
    ejabberd_hooks:delete(p1_push_enable_offline, Host,
                          ?MODULE, enable_offline_notification, 50),
    ejabberd_hooks:delete(p1_push_disable, Host,
			  ?MODULE, disable_notification, 50),
    ejabberd_hooks:delete(remove_user, Host,
                          ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(offline_message_hook, Host,
			  ?MODULE, receive_offline_packet, 35),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_P1_PUSH).



set_local_badge(JID, DeviceID, Count) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            set_local_badge_mnesia(JID, DeviceID, Count);
	p1db ->
	    set_local_badge_p1db(JID, DeviceID, Count);
        odbc ->
            set_local_badge_sql(JID, DeviceID, Count)
    end.

set_local_badge_mnesia(JID, DeviceID, Count) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    case mnesia:dirty_match_object({applepush_cache, LUS, DeviceID, '_'}) of
        [] ->
            {error, device_not_found};
        [#applepush_cache{options=Opts}=Record] ->
            %% The table is of type bag. If we just dirty_write, it will insert a new item, not update the existing one.
            %% This dirty_delete + dirty_write aren't atomic so entries could be lost in the middle.. but this is what
            %% store_cache_mnesia() uses
            mnesia:dirty_delete_object(Record),
            mnesia:dirty_write(Record#applepush_cache{options = lists:keystore(local_badge, 1, Opts, {local_badge, Count})})
    end.

set_local_badge_p1db(JID, DeviceID, Count) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Key = usd2key(LUser, LServer, DeviceID),
    case p1db:get(applepush_cache, Key) of
	{ok, Val, _VClock} ->
	    Opts = p1db_to_opts(Val),
	    NewOpts = lists:keystore(local_badge, 1, Opts, {local_badge, Count}),
	    NewVal = opts_to_p1db(NewOpts),
	    p1db:insert(applepush_cache, Key, NewVal);
	{error, notfound} ->
	    {error, device_not_found};
	{error, _} = Err ->
	    Err
    end.

set_local_badge_sql(#jid{luser =LUser, lserver=LServer}, DeviceID, Count) ->
    Username = ejabberd_odbc:escape(LUser),
    SDeviceID = erlang:integer_to_list(DeviceID, 16),
    case ejabberd_odbc:sql_query(LServer,
      [<<"UPDATE applepush_cache SET local_badge =">>, integer_to_list(Count), <<" WHERE" 
        " username='">>, Username, <<"' and ">>, <<"device_id='">>, SDeviceID, <<"';">>]) of
        {updated, 1} ->
            ok;
        {updated, 0} ->
            {error, device_not_found}  %%same contract than set_local_badge_mnesia
    end.

push_notification(Host, JID, Notification, Msg, Unread, Sound, AppID, Sender) ->
    push_notification_with_custom_fields(Host, JID, Notification, Msg, Unread, Sound, AppID, Sender, []).

push_notification_with_custom_fields(Host, JID, Notification, Msg, Unread, Sound, AppID, Sender, CustomFields) ->
    Type = xml:get_path_s(Notification, [{elem, <<"type">>}, cdata]),
    case Type of
	<<"applepush">> ->
	    DeviceID = xml:get_path_s(Notification, [{elem, <<"id">>}, cdata]),
            PushPacket = build_push_packet(DeviceID, Msg, Unread, Sound, Sender, JID, CustomFields),
            route_push_notification(Host, JID, AppID, PushPacket),
	    stop;
	_ ->
	    ok
    end.
build_push_packet(DeviceID, Msg, Unread, Sound, Sender, JID, CustomFields) ->
    Badge = jlib:integer_to_binary(Unread),
    SSound =
        if
            Sound -> <<"true">>;
            true -> <<"false">>
        end,
    Receiver = jlib:jid_to_string(JID),
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


route_push_notification(Host, JID, AppId, PushPacket) ->
    PushService = get_push_service(Host, JID, AppId),
    ServiceJID = jlib:make_jid(<<"">>, PushService, <<"">>),
    ejabberd_router:route(JID, ServiceJID, PushPacket).


enable_offline_notification(JID, Notification, SendBody, SendFrom, AppID1) ->
    Type = xml:get_path_s(Notification, [{elem, <<"type">>}, cdata]),
    case Type of
	<<"applepush">> ->
	    DeviceID = xml:get_path_s(Notification, [{elem, <<"id">>}, cdata]),
	    case catch erlang:list_to_integer(binary_to_list(DeviceID), 16) of
		ID1 when is_integer(ID1) ->
		    AppID =
			case xml:get_path_s(Notification,
					    [{elem, <<"appid">>}, cdata]) of
			    <<"">> -> AppID1;
			    A -> A
			end,
		    {MegaSecs, Secs, _MicroSecs} = now(),
		    TimeStamp = MegaSecs * 1000000 + Secs,
		    store_cache(JID, ID1, AppID, SendBody, SendFrom, TimeStamp);
		_ ->
		    ok
	    end,
	    stop;
	_ ->
	    ok
    end.

disable_notification(JID, Notification, _AppID) ->
    Type = xml:get_path_s(Notification, [{elem, <<"type">>}, cdata]),
    case Type of
	<<"applepush">> ->
	    DeviceID = xml:get_path_s(Notification, [{elem, <<"id">>}, cdata]),
	    case catch erlang:list_to_integer(binary_to_list(DeviceID), 16) of
		ID1 when is_integer(ID1) ->
	            delete_cache(JID, ID1),
        	    stop;
                _ ->
                    ok
            end;
	_ ->
	    ok
    end.

do_send_offline_packet_notification(From, To, Packet, ID, AppID, SendBody, SendFrom, BadgeCount) ->
        Host = To#jid.lserver,
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
        PushService = get_push_service(Host, To, AppID),
        ServiceJID = jlib:make_jid(<<"">>, PushService, <<"">>),
        if
            Body == <<"">>;
            Pushed ->
                ok;
            true ->
                BFrom = jlib:jid_remove_resource(From),
                SFrom = jlib:jid_to_string(BFrom),
                IncludeBody =
                    case SendBody of
                        all ->
                            true;
                        first_per_user ->
                            BadgeCount == 1;
                        first ->
                            BadgeCount == 1;
                        none ->
                            false
                    end,
                Msg =
                    if
                        IncludeBody ->
                            CBody = utf8_cut(Body, 100),
                            case SendFrom of
                                jid ->
                                    prepend_sender(SFrom, CBody);
                                username ->
                                    UnescapedFrom = unescape(BFrom#jid.user),
                                    prepend_sender(
                                      UnescapedFrom, CBody); 
                                name ->
                                    Name = get_roster_name(
                                             To, BFrom),
                                    prepend_sender(Name, CBody);
                                _ -> CBody
                            end;
                        true ->
                            <<"">>
                    end,
                SSound =
                    if
                        IncludeBody -> <<"true">>;
                        true -> <<"false">>
                    end,
                Badge = jlib:integer_to_binary(BadgeCount),
                DeviceID = jlib:integer_to_binary(ID, 16),
                STo = jlib:jid_to_string(To),
                Packet1 =
                    #xmlel{name = <<"message">>,
                           attrs = [],
                           children =
                           [#xmlel{name = <<"push">>,
                                   attrs = [{<<"xmlns">>, ?NS_P1_PUSH}],
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
                                           children = [{xmlcdata, SFrom}]},
                                    #xmlel{name = <<"to">>, attrs = [],
                                           children = [{xmlcdata, STo}]}]
                                  }
                           ]},
                ejabberd_router:route(To, ServiceJID, Packet1)
        end.

send_offline_packet_notification(From, To, Packet, SDeviceID, BadgeCount) ->
    DeviceID =
        if
            is_binary(SDeviceID) -> binary_to_list(SDeviceID);
            is_list(SDeviceID) -> SDeviceID
        end,
    case catch erlang:list_to_integer(DeviceID, 16) of
        ID1 when is_integer(ID1) ->
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
    ?DEBUG("mod_applepush offline~n\tfrom ~p~n\tto ~p~n\tpacket ~P~n",
	   [From, To, Packet, 8]),
    Host = To#jid.lserver,
    case gen_mod:is_loaded(Host, mod_applepush) of
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
            SDeviceID = xml:get_tag_attr_s(<<"id">>, SubEl),
            DeviceID =
                erlang:list_to_integer(binary_to_list(SDeviceID), 16),
            case lookup_cache(To, DeviceID) of
                [{_ID, AppID, _SendBody, _SendFrom, _LocalBadge}] ->
                    PushService = get_push_service(Host, To, AppID),
                    ServiceJID = jlib:make_jid(<<"">>, PushService, <<"">>),
                    if
                        From#jid.lserver == ServiceJID#jid.lserver ->
                            delete_cache(To, DeviceID),
                            IQ#iq{type = result, sub_el = []};
                        true ->
                            IQ#iq{type = error,
                                  sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
                    end
            end;
        {set, _} ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
        {get, _} ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]}
    end.


device_reset_badge(Host, To, DeviceID, AppID, Badge) ->
    ?INFO_MSG("Sending reset badge (~p) push to ~p ~p", [Badge, To, DeviceID]),
    PushService = get_push_service(Host, To, AppID),
    ServiceJID = jlib:make_jid(<<"">>, PushService, <<"">>),
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
    case gen_mod:is_loaded(Host, mod_applepush) of
	true ->
	    case lookup_cache(To) of
		false ->
		    {error, "no cached data for the user"};
                DeviceList ->
                    lists:foreach(fun({ID, AppID, SendBody, SendFrom, LocalBadge}) ->
                        ?DEBUG("lookup: ~p~n", [{ID, AppID, SendBody, SendFrom, LocalBadge}]),
                        PushService = get_push_service(Host, To, AppID),
                        ServiceJID = jlib:make_jid(<<"">>, PushService, <<"">>),
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
                                DeviceID = jlib:integer_to_binary(ID, 16),
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
                                                           [{xmlcdata, DeviceID}]},
                                                    #xmlel{name = <<"badge">>,
                                                           attrs = [],
                                                           children =
                                                           [{xmlcdata, Badge}]}]}]},
                                ejabberd_router:route(To, ServiceJID, Packet1)
                        end
                    end, DeviceList)
                end;
	false ->
	    {error, "mod_applepush is not loaded"}
    end.

multi_resend_badge(JIDs) ->
    lists:foreach(fun resend_badge/1, JIDs).

offline_resend_badge() ->
    USs = mnesia:dirty_all_keys(applepush_cache),
    JIDs = lists:map(fun({U, S}) -> jlib:make_jid(U, S, <<"">>) end, USs),
    multi_resend_badge(JIDs).

lookup_cache(JID) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            lookup_cache_mnesia(JID);
	p1db ->
	    lookup_cache_p1db(JID);
        odbc ->
            lookup_cache_sql(JID)
    end.

lookup_cache_mnesia(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    do_lookup_cache_mnesia(#applepush_cache{us = LUS, _ = '_'}).

lookup_cache_p1db(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(applepush_cache, USPrefix) of
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
    Username = ejabberd_odbc:escape(LUser),
    do_lookup_cache_sql(
      LServer,
      [<<"select device_id, app_id, send_body, send_from, local_badge from applepush_cache "
        "where username='">>, Username, <<"'">>]).

lookup_cache(JID, DeviceID) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            lookup_cache_mnesia(JID, DeviceID);
	p1db ->
	    lookup_cache_p1db(JID, DeviceID);
        odbc ->
            lookup_cache_sql(JID, DeviceID)
    end.

lookup_cache_mnesia(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    do_lookup_cache_mnesia(#applepush_cache{device_id = DeviceID, us = LUS, _ = '_'}).

lookup_cache_p1db(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Key = usd2key(LUser, LServer, DeviceID),
    case p1db:get(applepush_cache, Key) of
	{ok, Val, _VClock} ->
	    Opts = p1db_to_opts(Val),
	    [format_options(DeviceID, Opts)];
	{error, _} ->
	    false
    end.

lookup_cache_sql(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Username = ejabberd_odbc:escape(LUser),
    SDeviceID = erlang:integer_to_list(DeviceID, 16),
    do_lookup_cache_sql(
      LServer,
      [<<"select device_id, app_id, send_body, send_from, local_badge from applepush_cache "
        "where username='">>, Username, <<"' and device_id='">>,
       SDeviceID, <<"'">>]).

do_lookup_cache_mnesia(MatchSpec) ->
    case mnesia:dirty_match_object(MatchSpec) of
	EntryList when is_list(EntryList) ->
            lists:map(fun(#applepush_cache{device_id = DeviceID, options = Options}) ->
			      format_options(DeviceID, Options)
            end, EntryList);
	_ ->
	    false
    end.

format_options(DeviceID, Options) ->
    AppID = proplists:get_value(appid, Options, <<"applepush.localhost">>),
    SendBody = proplists:get_value(send_body, Options, none),
    SendFrom = proplists:get_value(send_from, Options, true),
    LocalBadge = proplists:get_value(local_badge, Options, 0),
    {DeviceID, AppID, SendBody, SendFrom, LocalBadge}.

do_lookup_cache_sql(LServer, Query) ->
    case ejabberd_odbc:sql_query(LServer, Query) of
        {selected, [<<"device_id">>, <<"app_id">>, <<"send_body">>, <<"send_from">>, <<"local_badge">>],
         EntryList} ->
            lists:map(
              fun([SDeviceID, AppID, SSendBody, SSendFrom, LocalBadgeStr]) ->
                      DeviceID = jlib:binary_to_integer(SDeviceID, 16),
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
        odbc ->
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
    R = #applepush_cache{us = LUS,
			 device_id = DeviceID,
			 options = Options},
   case mnesia:dirty_match_object({applepush_cache, LUS, DeviceID, '_'}) of
        [] ->
            %%no previous entry, just write the new record
            mnesia:dirty_write(R);  

        [R] ->
            %%previous entry exists but is equal, don't do anything
            ok; 

        [#applepush_cache{options = OldOptions} = OldRecord] ->
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
                    mnesia:dirty_write(R#applepush_cache{options = [{local_badge, Count} | Options]})
            end
       %% Other cases are error. If there is more than one entry for the same UserServer and same DeviceID,
       %% it is an error.
    end.

store_cache_p1db(JID, DeviceID, Options) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Key = usd2key(LUser, LServer, DeviceID),
    Val = opts_to_p1db(Options),
    case p1db:get(applepush_cache, Key) of
	{ok, Val, _VClock} ->
	    %%previous entry exists but is equal, don't do anything
            ok;
	{error, notfound} ->
	    %%no previous entry, just write the new record
	    p1db:insert(applepush_cache, Key, Val);
	{ok, OldVal, _VClock} ->
	    OldOptions = p1db_to_opts(OldVal),
	    case lists:keyfind(local_badge, 1, OldOptions) of
                false ->
		    %% There was no local_badge set in previous record.
                    %% As the record don't match anyway, write the new one
		    p1db:insert(applepush_cache, Key, Val);
		{local_badge, Count} ->
		    %% Use the new record, but copy the previous local_badge value
                    %% We keep that as local_badge isn't provide in the enable notification
                    %% call.
		    NewVal = opts_to_p1db([{local_badge, Count} | Options]),
		    p1db:insert(applepush_cache, Key, NewVal)
	    end;
	{error, _} = Err ->
	    Err
    end.

store_cache_sql(JID, DeviceID, AppID, SendBody, SendFrom) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Username = ejabberd_odbc:escape(LUser),
    SDeviceID = erlang:integer_to_list(DeviceID, 16),
    SAppID = ejabberd_odbc:escape(AppID),
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
                case ejabberd_odbc:sql_query_t(
                  [<<"select app_id, send_body, send_from from applepush_cache "
                    "where username='">>, Username, <<"' and ">>,
                   <<"device_id='">>, SDeviceID, <<"';">>]) of
                        {selected, _Fields, [[AppID, SSendBody, SSendFrom]]} ->
                            %% Nothing to change
                            ok;
                        {selected, _Fields, [[_AppId, _SSendBody, _SSendFrom]]} ->
                            %% Something changed,  use the new values (but keep the previous local_badge)
                            ejabberd_odbc:sql_query_t(
                              [<<"UPDATE applepush_cache SET app_id ='">>, SAppID, <<"', send_body='">>,
                                SSendBody, <<"', send_from='">>, SSendFrom, <<"' WHERE" 
                                " username='">>, Username, <<"' and ">>, <<"device_id='">>, SDeviceID, <<"';">>]);

                        {selected, _Fields, []} ->
                            %% No previous entry, add the new one
                            ejabberd_odbc:sql_query_t(
                              [<<"insert into applepush_cache(username, device_id, app_id, "
                                "                            send_body, send_from) "
                                "values ('">>, Username, <<"', '">>, SDeviceID, <<"', '">>,
                               SAppID, <<"', '">>, SSendBody, <<"', '">>, SSendFrom, <<"');">>])
                end
        end,
        {atomic, _} = odbc_queries:sql_transaction(LServer, F).

delete_cache(JID, DeviceID) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            delete_cache_mnesia(JID, DeviceID);
	p1db ->
	    delete_cache_p1db(JID, DeviceID);
        odbc ->
            delete_cache_sql(JID, DeviceID)
    end.

delete_cache_mnesia(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    [ mnesia:dirty_delete_object(Obj) || Obj <-  mnesia:dirty_match_object(#applepush_cache{device_id = DeviceID, us = LUS, _ = '_'})].

delete_cache_p1db(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Key = usd2key(LUser, LServer, DeviceID),
    [p1db:delete(applepush_cache, Key)].

delete_cache_sql(JID, DeviceID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Username = ejabberd_odbc:escape(LUser),
    SDeviceID = erlang:integer_to_list(DeviceID, 16),
    ejabberd_odbc:sql_query(
      LServer,
      [<<"delete from applepush_cache "
        "where username='">>, Username, <<"' and ">>,
       <<"device_id='">>, SDeviceID, <<"';">>]).

delete_cache(JID) ->
    case gen_mod:db_type(JID#jid.lserver, ?MODULE) of
        mnesia ->
            delete_cache_mnesia(JID);
	p1db ->
	    delete_cache_p1db(JID);
        odbc ->
            delete_cache_sql(JID)
    end.

delete_cache_mnesia(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    LUS = {LUser, LServer},
    catch mnesia:dirty_delete(applepush_cache, LUS).

delete_cache_p1db(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(applepush_cache, USPrefix) of
	{ok, L} ->
	    lists:foreach(
	      fun({Key, _Val, _VClock}) ->
		      p1db:delete(applepush_cache, Key)
	      end, L);
	{error, _} = Err ->
	    Err
    end.

delete_cache_sql(JID) ->
    #jid{luser = LUser, lserver = LServer} = JID,
    Username = ejabberd_odbc:escape(LUser),
    ejabberd_odbc:sql_query(
      LServer,
      [<<"delete from applepush_cache "
        "where username='">>, Username, <<"';">>]).


remove_user(User, Server) ->
    delete_cache(jlib:make_jid(User, Server, <<"">>)).


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
                          <<"applepush.localhost">>);
		    {value, {_, PS}} ->
			PS
		end;
	    {value, {AppID, PS}} ->
		PS
	end,
    PushService.

usd2key(LUser, LServer, DeviceID) ->
    SDeviceID = jlib:integer_to_binary(DeviceID, 16),
    <<LServer/binary, 0, LUser/binary, 0, SDeviceID/binary>>.

key2did(USPrefix, Key) ->
    Size = size(USPrefix),
    <<_:Size/binary, SDeviceID/binary>> = Key,
    jlib:binary_to_integer(SDeviceID, 16).

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
    [proplists:get_value(appid, Options, <<"applepush.localhost">>),
     jlib:atom_to_binary(proplists:get_value(send_body, Options, none)),
     jlib:atom_to_binary(proplists:get_value(send_from, Options, true)),
     jlib:integer_to_binary(proplists:get_value(local_badge, Options, 0)),
     jlib:integer_to_binary(proplists:get_value(timestamp, Options, 0))].

export(_Server) ->
    [{applepush_cache,
      fun(Host, #applepush_cache{us = {LUser, LServer},
                                 device_id = DeviceID,
                                 options = Options})
	 when LServer == Host ->
	      Username = ejabberd_odbc:escape(LUser),
              SDeviceID = erlang:integer_to_list(DeviceID, 16),
              AppID = proplists:get_value(appid, Options, "applepush.localhost"),
              SendBody = proplists:get_value(send_body, Options, none),
              SendFrom = proplists:get_value(send_from, Options, true),
              SAppID = ejabberd_odbc:escape(AppID),
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
              [["delete from applepush_cache "
                "where username='", Username, "' and "
                "device_id='", SDeviceID, "';"],
               ["insert into applepush_cache(username, device_id, app_id, "
                "                            send_body, send_from) "
                "values ('", Username, "', '", SDeviceID, "', '",
                SAppID, "', '", SSendBody, "', '", SSendFrom, "');"]];
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
	get_tokens_by_jid(jlib:string_to_jid(JIDString));
get_tokens_by_jid(#jid{luser = LUser, lserver = LServer}) ->
    LUS = {LUser, LServer},
    [erlang:integer_to_list(I, 16) || {applepush_cache,_,I,_} <- 
       mnesia:dirty_read(applepush_cache, LUS)].

transform_module_options(Opts) ->
    lists:map(
      fun({backend, sql}) ->
              ?WARNING_MSG("Option 'backend' is obsoleted, "
                           "use 'db_type' instead", []),
              {db_type, odbc};
         ({backend, mnesia}) ->
              ?WARNING_MSG("Option 'backend' is obsoleted, "
                           "use 'db_type' instead", []),
              {db_type, internal};
	 ({backend, p1db}) ->
	      ?WARNING_MSG("Option 'backend' is obsoleted, "
			   "use 'db_type' instead", []),
	      {db_type, p1db};
         (Opt) ->
              Opt
      end, Opts).
