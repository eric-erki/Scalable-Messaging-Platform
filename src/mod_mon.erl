%%% ====================================================================
%%% This software is copyright 2006-2014, ProcessOne.
%%%
%%% mod_mon
%%%
%%% @copyright 2006-2014 ProcessOne
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
%%% ====================================================================

-module(mod_mon).
-author('christophe.romain@process-one.net').
-vsn('$Id: mod_mon.erl 426 2008-01-10 22:15:00Z cromain$ ').

-behaviour(gen_mod).

%% SIZE_COUNTING is consuming but allows to know size of xmpp messages
-define(SIZE_COUNTING, false).

-define(HOUR, 3600000).
-define(DAY, 86400000).
-define(WEEK, 604800000).
-define(MONTH, 2592000000).

-ifdef(ANNON_CONNECTIONS).
-define(ANNONYMOUS_CONNECTIONS, true). %% set to true if monitored domains will accept annonymous connections
-else.
-define(ANNONYMOUS_CONNECTIONS, false). %% set to true if monitored domains will accept annonymous connections
-endif.
-define(ACTIVE_ENABLED, true).

%% dictionaries computed to generate reports
-define(COMPUTING_DICTS, [
	{hourly_active_users, ?HOUR},
	{daily_active_users, ?DAY},
	{weekly_active_users, ?WEEK},
	{montly_active_users, ?MONTH}
	]).
-define(PROCESSINFO, process_info).
% TODO use dict:update_counter instead of keysearch/keyreplace ?

%% module functions
-export([start/2, stop/1, is_loaded/0, init/1, start_monitor_worker/1]).
-export([values/2, value/3, add_monitor/4, del_monitor/3]).
-export([start_sampling/0, stop_sampling/0, sampling_loop/3]).
-export([run_sample/0, run_sample/1]).
-export([get_sampling_counters/0, get_active_counters/1]).
-export([add_sampling_condition/1, restart_sampling/0]).
%% DB wrapper, waiting a better solution
-export([db_table_size/1, db_table_size/2]).

-define(GENERATED_HOOKS,
        [presence_receive_packet, presence_send_packet,
         subscribe_receive_packet, subscribe_send_packet,
         subscribed_receive_packet, subscribed_send_packet,
         unsubscribe_receive_packet, unsubscribe_send_packet,
         unsubscribed_receive_packet, unsubscribed_send_packet,
         message_receive_packet, message_send_packet,
         normal_receive_packet, normal_send_packet,
         chat_receive_packet, chat_send_packet,
         groupchat_receive_packet, groupchat_send_packet,
         error_receive_packet, error_send_packet,
         headline_receive_packet, headline_send_packet,
         iq_error_receive_packet, iq_error_send_packet,
         iq_result_receive_packet, iq_result_send_packet,
         iq_receive_packet, iq_send_packet,
         broadcast_receive_packet, broadcast_send_packet,
         s2s_presence_receive_packet, s2s_presence_send_packet,
         s2s_subscribe_receive_packet, s2s_subscribe_send_packet,
         s2s_subscribed_receive_packet, s2s_subscribed_send_packet,
         s2s_unsubscribe_receive_packet, s2s_unsubscribe_send_packet,
         s2s_unsubscribed_receive_packet, s2s_unsubscribed_send_packet,
         s2s_message_receive_packet, s2s_message_send_packet,
         s2s_normal_receive_packet, s2s_normal_send_packet,
         s2s_chat_receive_packet, s2s_chat_send_packet,
         s2s_groupchat_receive_packet, s2s_groupchat_send_packet,
         s2s_error_receive_packet, s2s_error_send_packet,
         s2s_headline_receive_packet, s2s_headline_send_packet,
         s2s_iq_error_receive_packet, s2s_iq_error_send_packet,
         s2s_iq_result_receive_packet, s2s_iq_result_send_packet,
         s2s_iq_receive_packet, s2s_iq_send_packet,
         s2s_broadcast_receive_packet, s2s_broadcast_send_packet,
         sm_register_connection_c2s, sm_register_connection_c2s_tls,
         sm_register_connection_c2s_compressed,
         sm_register_connection_http_poll, sm_register_connection_http_bind,
         sm_register_connection_http_ws,
         sm_remove_connection_c2s, sm_remove_connection_c2s_tls,
         sm_remove_connection_c2s_compressed,
         sm_remove_connection_http_poll, sm_remove_connection_http_bind,
         sm_remove_connection_http_ws,
         muc_rooms, muc_users, muc_message_size, proxy65_size,
         message_send_size, message_receive_size, active_users,
         aim_login, aim_logout, aim_register, aim_unregister,
         aim_send_packet, aim_receive_packet,
         icq_login, icq_logout, icq_register, icq_unregister,
         icq_send_packet, icq_receive_packet,
         msn_login, msn_logout, msn_register, msn_unregister,
         msn_send_packet, msn_receive_packet,
         twitter_login, twitter_logout, twitter_register, twitter_unregister,
         twitter_send_packet, twitter_receive_packet,
         xmpp_login, xmpp_logout, xmpp_register, xmpp_unregister,
         xmpp_send_packet, xmpp_receive_packet,
         yahoo_login, yahoo_logout, yahoo_register, yahoo_unregister,
         yahoo_send_packet, yahoo_receive_packet ]).
-define(SUPPORTED_HOOKS,
        [offline_message_hook, resend_offline_messages_hook,
         sm_register_connection_hook, sm_remove_connection_hook,
         roster_in_subscription, roster_out_subscription,
         user_available_hook, unset_presence_hook, set_presence_hook,
         user_send_packet, user_receive_packet,
         remove_user, register_user,
         s2s_send_packet, s2s_receive_packet,
         muc_create, muc_destroy, muc_user_join, muc_user_leave, muc_message,
         chat_invitation_accepted,
         transport_login_hook, transport_logout_hook,
         transport_register_hook, transport_unregister_hook,
         transport_send_message_hook, transport_receive_message_hook,
         proxy65_register_stream, proxy65_unregister_stream,
         pubsub_publish_item, pubsub_broadcast_stanza ]).
-define(GLOBAL_HOOKS,
        [proxy65_http_store, chat_invitation_by_email_hook,
         turn_register_permission, turn_unregister_permission ]).
-define(DYNAMIC_HOOKS,
        [iq_set_receive_packet, iq_set_send_packet,
         iq_get_receive_packet, iq_get_send_packet,
         s2s_iq_set_receive_packet, s2s_iq_set_send_packet,
         s2s_iq_get_receive_packet, s2s_iq_get_send_packet,
         pubsub_publish_item, pubsub_broadcast_stanza ]).

%% handled ejabberd hooks
-export([
         offline_message_hook/3,
         resend_offline_messages_hook/3,
         sm_register_connection_hook/2,
         sm_register_connection_hook/3,
         sm_remove_connection_hook/2,
         sm_remove_connection_hook/3,
         roster_in_subscription/6,
         roster_out_subscription/4,
         user_available_hook/1,
         unset_presence_hook/4,
         set_presence_hook/4,
         user_send_packet/3,
         user_send_packet/4,
         user_receive_packet/4,
         user_receive_packet/5,
         s2s_send_packet/3,
         s2s_receive_packet/3,
         remove_user/2,
         register_user/2,
         muc_create/4,
         muc_destroy/3,
         muc_user_join/4,
         muc_user_leave/4,
         muc_message/6,
         proxy65_http_store/4,
         proxy65_register_stream/3,
         proxy65_unregister_stream/3,
         chat_invitation_by_email_hook/4,
         chat_invitation_accepted/5,
         transport_login_hook/5,
         transport_logout_hook/4,
         transport_register_hook/5,
         transport_unregister_hook/3,
         transport_send_message_hook/4,
         transport_receive_message_hook/4,
         turn_register_permission/2,
         turn_unregister_permission/2,
         pubsub_publish_item/6,
         pubsub_broadcast_stanza/4 ]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-define(PROCNAME, ?MODULE).
-define(MONITORS, monitors).

-record(mon, {key, value}).

% dictionary commands are overrided for persistency
-compile({no_auto_import, [put/2]}).
-compile({no_auto_import, [get/1]}).
-compile({no_auto_import, [get/0]}).

%%Opts should have a proplists compatible format:
%%[{monitors,MonitorList},...]
start(Host, Opts) ->
    %% Note: we use priority of 20 cause some modules
    %% can block execution of hooks
    %% example mod_offline stops execution if it stores packets
    %% so if we set an higher value, we just loose the hook
    %% that's why we put 20 here.
    Components = list_components(Host),

    lists:foreach(
        fun(Component) ->
            lists:foreach(
                fun(Hook) ->
                    ?DEBUG("ejabberd_hooks:add(~p, ~p, ~p, ~p, 20)",[Hook, Component, ?MODULE, Hook]),
                    ejabberd_hooks:add(Hook, Component, ?MODULE, Hook, 20)
                end, ?SUPPORTED_HOOKS)
        end, Components),

    lists:foreach(
        fun(Hook) ->
            ejabberd_hooks:add(Hook, global, ?MODULE, Hook, 20)
        end, ?GLOBAL_HOOKS),

    ProcName = gen_mod:get_module_proc(Host, ?PROCNAME),
    Monitors = proplists:get_value(?MONITORS, Opts, []),
    case whereis(ProcName) of
        undefined ->
            ?INFO_MSG("Starting monitor process ~p", [ProcName]),
            catch supervisor:delete_child(ejabberd_sup, ProcName),
            ModMonProcSpec = {ProcName,
                              {?MODULE, start_monitor_worker, [Host]},
                               transient,
                               100,
                               worker,
                               [?MODULE]},
            WorkerStarted =
                case supervisor:start_child(ejabberd_sup, ModMonProcSpec) of
                    {ok,_,_} -> ok;
                    {ok, _} -> ok;
                    {error, E} ->
                        ?ERROR_MSG("Error attaching mod mon worker process to supervisor: ~p", [E]),
                        error
                end,
            case WorkerStarted of
                ok ->
                    lists:foreach(fun({Class, Monitor, Module}) ->
                                      ProcName ! {add, Class, Monitor, Module}
                                  end, Monitors),
                    start;
                error ->
                    not_started
            end;
        _Pid ->
            started
    end.

stop(Host) ->
    stop_sampling(),
    lists:foreach(fun(Hook) ->
                          ejabberd_hooks:delete(Hook, Host, ?MODULE, Hook, 20)
                  end, ?SUPPORTED_HOOKS),
    lists:foreach(fun(Hook) ->
                          ejabberd_hooks:delete(Hook, global, ?MODULE, Hook, 20)
                  end, ?GLOBAL_HOOKS),
    ProcName = gen_mod:get_module_proc(Host, ?PROCNAME),
    exit(whereis(ProcName), normal),
    catch supervisor:delete_child(ejabberd_sup, ProcName),
    {wait, ProcName}.

start_monitor_worker(Host) ->
    ?INFO_MSG("Starting mod_mon worker on host ~s...",[Host]),
    case proc_lib:start_link(?MODULE, init, [Host], 1000) of
        {ok, Pid} ->
            ?INFO_MSG("mod_mon worker process started with PID: ~p", [Pid]),
            {ok, Pid};
        {error, Cause} ->
            ?ERROR_MSG("Error starting mod_mon worker process. Cause: ~p", [Cause]),
            {error, Cause};
        R ->
            ?ERROR_MSG("Unknown error starting mod_mon worker process: ~p", [R]),
            {error, unknown}
    end.

init(Host) ->
try
    TableName = gen_mod:get_module_proc(Host, ?PROCESSINFO),
    case ets:info(TableName) of
        undefined -> ets:new(TableName, [public,named_table]);
        _ -> ets:delete_all_objects(TableName)
    end,
    ets:insert(TableName,{vhost,Host}),

    mnesia:create_table(mon,
                        [{disc_copies, [node()]},
                         {local_content, true},
                         {attributes, record_info(fields, mon)}]),
    case mnesia:table_info(mon, size) of
        0 ->
            lists:foreach(fun(Hook) -> put(Hook, 0) end, ?SUPPORTED_HOOKS++?GLOBAL_HOOKS++?GENERATED_HOOKS),
            lists:foreach(fun(Hook) -> put(Hook, []) end, ?DYNAMIC_HOOKS);
        _ ->
            ok
    end,
    try put(muc_rooms, db_table_size(muc_online_room))
    catch _:_ -> put(muc_rooms, 0)
    end,
    try put(muc_users, db_table_size(muc_registered))
    catch _:_ -> put(muc_users, 0)
    end,
    [put(C, 0) || C <- [muc_message_size, message_send_size, message_receive_size]],

    %% create the list of dictionaries updated by monitoring loop
    Dicts = lists:foldl(fun({DictName, FlushTimeout}, Acc) ->
                        case timer:send_interval(FlushTimeout, self(), {flush_dict, DictName}) of
                            {ok, TRef} ->
                                [{DictName, {ehyperloglog:new(16), TRef} } | Acc];
                            {error, Reason} ->
                                ?ERROR_MSG("Error creating refresh timer for dictionary ~p. Reason: ~p",
                                           [DictName, Reason]),
                                Acc
                        end
                end, [], ?COMPUTING_DICTS),

    ProcName = gen_mod:get_module_proc(Host, ?PROCNAME),
    register(ProcName, self()),
    proc_lib:init_ack({ok, self()}),

    %% start monitoring loop
    loop(Host,[], Dicts)
catch
    E:{{R}} ->
        ?ERROR_MSG("*** WARNING *** Monitoring process for host ~p died. Error: ~p - Reason: ~p", [Host,E,R]),
        proc_lib:init_ack({error, {E,R}})
end.

is_loaded() ->
    ok.

action(Host, Msg) ->
    %%Prior to this, we used Host, now we ignore this parameter because
    %%Host can have other formats (like "conference.Host", etc) which
    %%won't return any process. IN THE FUTURE we could have one process
    %%for each service. That way, we will not need to query for Vhost like
    %%we do now.
    VHost = get_vhost_name(Host),
    ProcName = gen_mod:get_module_proc(VHost, ?PROCNAME),
    try
        ProcName ! Msg,
        ok
    catch _:_ ->
        ?ERROR_MSG("Tried to send message to ~p process but it's not alive", [ProcName]),
        error
    end.

wait(Result) ->
    receive
        {Result, Data} -> Data
    after 4000 -> timeout
    end.

get_vhost_name(Host) ->
   Table = gen_mod:get_module_proc(Host, ?PROCESSINFO),
   %First, try the vhost passed as a parameter.
   TableName = case ets:info(Table) of
                 undefined -> find_table(Host);
                 _ -> Table
               end,
   case TableName of
     [] -> Host;
     _ ->
         [{_, Info}] = ets:lookup(TableName,vhost),
         Info
   end.

find_table(Host) ->
    SubDomain = str:substr(Host, str:str(Host,<<".">>)+1),
    Table = gen_mod:get_module_proc(SubDomain, ?PROCESSINFO),
    case ets:info(Table) of
        undefined ->
            case str:str(SubDomain, <<".">>) of
                0 -> [];
                _ -> find_table(SubDomain)
            end;
        _ -> Table
    end.

compute(_Host, Msg) ->
    ?DEBUG("compute ~p",[Msg]),
    %%send_message_to_sampling_process(Host, compute,Msg).
    ok.

sample(Msg) ->
    ?DEBUG("Sample ~p",[Msg]),
    catch mod_mon_sampling_loop ! Msg.

loop(Host, Monitors, Dicts) ->
    receive
        {packet, Type, From, To, Packet} ->
            sample({packet, Host, Type, From, To, Packet}),
            loop(Host, Monitors, Dicts);
        {set, User, Resource, {Hook, Namespace, Count}} ->
            NewValues = update_probe_array(Hook, Namespace, Count),
            put(Hook, NewValues),
            sample({hook, {User, Host, Resource}, Hook}),
            loop(Host, Monitors, Dicts);
        {set, User, Resource, {Hook, Namespace}} ->
            NewValues = update_probe_array(Hook, Namespace),
            put(Hook, NewValues),
            sample({hook, {User, Host, Resource}, Hook}),
            loop(Host, Monitors, Dicts);
        {set, {Hook, Namespace, Count}} ->
            NewValues = update_probe_array(Hook, Namespace, Count),
            put(Hook, NewValues),
            loop(Host, Monitors, Dicts);
        {set, {Hook, Namespace}} ->
            NewValues = update_probe_array(Hook, Namespace),
            put(Hook, NewValues),
            loop(Host, Monitors, Dicts);
        {set, User, Resource, Hook} ->
            OldValue = case get(Hook) of
                        undefined -> 0;
                        V -> V
                        end,
            put(Hook, OldValue + 1),
            sample({hook, {User, Host, Resource}, Hook}),
            loop(Host, Monitors, Dicts);
        {set, User, Server, Resource, Hook} ->
            OldValue = case get(Hook) of
                        undefined -> 0;
                        V -> V
                        end,
            put(Hook, OldValue + 1),
            sample({hook, {User, Server, Resource}, Hook}),
            loop(Host, Monitors, Dicts);
        {active, Key} ->
            %% ?DEBUG("ACTIVE USER: ~p", [Key]),
            NewDicts = lists:map(fun({DictName, {Dict, TRef}}) ->
                    UpdatedDict = ehyperloglog:update(Key, Dict),
                    ActiveUsers = round(ehyperloglog:cardinality(UpdatedDict)),
                    put(DictName, ActiveUsers),
                    {DictName, {UpdatedDict, TRef}}
                end, Dicts),
            loop(Host, Monitors, NewDicts);
        {flush_dict, DictName} ->
            NewDicts = lists:map(
                    fun({Name, {_Dict, TRef}}) when Name==DictName ->
                            {Name, {ehyperloglog:new(16), TRef}};
                       (Other) ->
                            Other
                    end, Dicts),
            loop(Host, Monitors, NewDicts);
        {get, From, hooks} ->
            From ! {values, get()},
            loop(Host, Monitors, Dicts);
        {get, From, hooks, Hook} ->
            From ! {value, get(Hook)},
            loop(Host, Monitors, Dicts);
        {get, From, Class} ->
            Values = case lists:keysearch(Class, 1, Monitors) of
                         {value, {Class, List}} ->
                             lists:map(fun({I, M, F, A}) -> {I, apply(M, F, A)} end, List);
                         _ ->
                             undefined_class
                     end,
            From ! {values, Values},
            loop(Host, Monitors, Dicts);
        {get, From, Class, Mon} ->
            Value = case lists:keysearch(Class, 1, Monitors) of
                        {value, {Class, List}} ->
                            case lists:keysearch(Mon, 1, List) of
                                {value, {Mon, M, F, A}} ->
                                    apply(M, F, A);
                                _ ->
                                    undefined_monitor
                            end;
                        _ ->
                            undefined_class
                    end,
            From ! {value, Value},
            loop(Host, Monitors, Dicts);
        {add, Class, Monitor, Module} ->
            NewMonitors = case ejabberd_config:get_local_option({modules, Host},
                                                                                fun(V) when is_list(V) -> V end) of
                              undefined ->
                                  Monitors;
                              Modules ->
                                  ActiveModules = lists:map(fun({M, _O}) -> M end, Modules),
                                  case lists:member(Module, ActiveModules) of
                                      false ->
                                          Monitors;
                                      true ->
                                          case lists:keysearch(Class, 1, Monitors) of
                                              {value, {Class, List}} ->
                                                  NewClassMonitors = {Class, [Monitor|List]},
                                                  lists:keyreplace(Class, 1, Monitors, NewClassMonitors);
                                              _ ->
                                                  [{Class, [Monitor]}|Monitors]
                                          end
                                  end
                          end,
            loop(Host, NewMonitors, Dicts);
        {del, Class, Monitor} ->
            NewMonitors = case lists:keysearch(Class, 1, Monitors) of
                              {value, {Class, List}} ->
                                  NewClassMonitors = lists:filter(fun(X) -> X /= Monitor end, List),
                                  lists:keyreplace(Class, 1, Monitors, NewClassMonitors);
                              _ ->
                                  Monitors
                          end,
            loop(Host, NewMonitors, Dicts);
        {muc, _Room, create} ->
            OldValue = get(muc_rooms),
            put(muc_rooms, OldValue + 1),
            loop(Host, Monitors, Dicts);
        {muc, _Room, destroy} ->
            OldValue = get(muc_rooms),
            put(muc_rooms, OldValue - 1),
            loop(Host, Monitors, Dicts);
        {muc, _Room, join} ->
            OldValue = get(muc_users),
            put(muc_users, OldValue + 1),
            loop(Host, Monitors, Dicts);
        {muc, _Room, leave} ->
            OldValue = get(muc_users),
            put(muc_users, OldValue - 1),
            loop(Host, Monitors, Dicts);
        {muc, _Room, muc_message_size, Size} ->
            OldValue = get(muc_message_size),
            Current = case is_list(Size) of
                true ->
                    case str:to_integer(Size) of
                        {error, _} -> 0;
                        {N, _} -> N
                    end;
                false ->
                    Size
                end,
            put(muc_message_size, OldValue + Current),
            loop(Host, Monitors, Dicts);
        {message_send_size, _User, _Resource, Size} ->
            OldValue = get(message_send_size),
            put(message_send_size, OldValue + Size),
            loop(Host, Monitors, Dicts);
        {message_receive_size, _User, _Resource, Size} ->
            OldValue = get(message_receive_size),
            put(message_receive_size, OldValue + Size),
            loop(Host, Monitors, Dicts);
        {proxy65, _FileName, Size} ->
            OldValue = case get(proxy65_size) of
                        undefined -> 0;
                        V -> V
                        end,
            Current = case is_list(Size) of
                true ->
                    case str:to_integer(Size) of
                        {error, _} -> 0;
                        {N, _} -> N
                    end;
                false ->
                     Size
                end,
            put(proxy65_size, OldValue + Current),
            loop(Host, Monitors, Dicts);
        stop ->
            lists:foreach(  fun({_, {_, TRef}}) ->
                                catch timer:cancel(TRef)
                            end, Dicts ),
            ok;
        Unknown ->
            ?INFO_MSG("Unknown message received on mod_mon loop process for host ~p: ~p", [Host, Unknown]),
            loop(Host, Monitors, Dicts)
    end.

%% private function used by loop to update array probes (like IQ or PubSub probes)
update_probe_array(Hook, Namespace) ->
    update_probe_array(Hook, Namespace, 1).
update_probe_array(Hook, Namespace, Count) ->
    OldValues = case get(Hook) of
                    undefined -> [];
                    V -> V
                end,
    case lists:keysearch(Namespace, 1, OldValues) of
        {value, {Namespace, OldValue}} -> lists:keyreplace(Namespace, 1, OldValues,
                                                           {Namespace, OldValue + Count});
        _ -> [{Namespace, Count}|OldValues]
    end.


sampling_loop(Hooks, Packets, Conditions) ->
    receive
        {packet, Host, Type, From, To, Packet} ->
        try
            {jid, _, _, _, UF, SF, RF} = From,
            {jid, _, _, _, UT, ST, RT} = To,
            {JID, Peer} = case Type of
                              recv -> {{UT, ST, RT}, {UF, SF}};
                              offline -> {{UT, ST, RT}, {UF, SF}};
                              _ -> {{UF, SF, RF}, {UT, ST}}
                          end,
            NewConditions = case Type of
                                recv ->
                                    sample_packet(Host, recv, From, To, Packet, UF, SF, UT, ST, Conditions);
                                send ->
                                    sample_packet(Host, send, From, To, Packet, UF, SF, UT, ST, Conditions);
                                _ ->
                                    Conditions
                            end,
            Size = size(term_to_binary(Packet)),
            Key = {JID, Type, Peer, direction(Host, SF, ST)},
            NewPackets = case lists:keysearch(Key, 1, Packets) of
                             {value, {_, C, S}} ->
                                 lists:keyreplace(Key, 1, Packets, {Key, C+1, S+Size});
                             _ ->
                                 [{Key, 1, Size} | Packets]
                         end,
            sampling_loop(Hooks, NewPackets, NewConditions)
        catch
            _:R ->
                ?ERROR_MSG("Error processing packet: ~p. Reason: ~p",
                    [{packet, Host, Type, From, To, Packet}, R]),
                sampling_loop(Hooks, Packets, Conditions)
        end;
        {hook, JID, Hook} ->
            try
                Key = {JID, Hook},
                NewHooks = case lists:keysearch(Key, 1, Hooks) of
                           {value, {_, C}} ->
                               lists:keyreplace(Key, 1, Hooks, {Key, C+1});
                           _ ->
                               [{Key, 1} | Hooks]
                       end,
                sampling_loop(NewHooks, Packets, Conditions)
            catch
                _:R ->
                    ?ERROR_MSG("Error processing message: ~p. Reason: ~p",
                        [{hook, JID, Hook}, R]),
                    sampling_loop(Hooks, Packets, Conditions)
            end;
        {add_condition, Condition} ->
            sampling_loop(Hooks, Packets, [Condition|Conditions]);
        {restart, Sender} ->
            Sender ! {restart, ok},
            sampling_loop([], [], []);
        {get_sampling_hook_counters, Sender} ->
            Sender ! {hooks, Hooks},
            sampling_loop(Hooks, Packets, Conditions);
        {get_sampling_packet_counters, Sender} ->
            Sender ! {packets, Packets},
            sampling_loop(Hooks, Packets, Conditions);
        stop ->
            ?DEBUG("sampling_loop: receiving 'stop' message",[]),
            ok
    end.

%% private function used by sample_loop to check if a packet matches with
%% current conditions
sample_packet(_Host, _Type, _From, _To, _Packet, UF, SF, UT, ST, Conditions) ->
    lists:foldl(
        fun({Action, A, B}=Condition, CondAcc) ->
            Filter = case Action of
                from -> (UF == A) and (SF == B);
                to -> (UT == A) and (ST == B);
                fromto -> {UA, SA} = A, {UB, SB} = B, (UF == UA) and (SF == SA) and (UT == UB) and (ST == SB)
            end,
            if Filter ->
                %Forward message to sampling loop
                %%send_message_to_sampling_process(Host, sample,{packet, Host, Type, From, To, Packet, Condition}),
                CondAcc;
            true ->
                [Condition|CondAcc]
            end
        end, [], Conditions).

add_monitor(Host, Class, Monitor, Module) ->
    action(Host, {add, Class, Monitor, Module}).

del_monitor(Host, Class, Monitor) ->
    action(Host, {del, Class, Monitor}).

values(Host, Class) ->
        VHost = list_to_binary(Host),
    action(VHost, {get, self(), Class}),
    wait(values).

value(Host, Class, Mon) ->
        VHost = list_to_binary(Host),
    action(VHost, {get, self(), Class, Mon}),
    wait(value).

get_sampling_hook_counters() ->
    sample({get_sampling_hook_counters, self()}),
    receive
        {hooks, Hooks} -> Hooks
    after 300000 -> []
    end.

get_sampling_packet_counters() ->
    sample({get_sampling_packet_counters, self()}),
    receive
        {packets, Packets} -> Packets
    after 300000 -> []
    end.

%Function to get packet and hook counters
%in only one call.
get_sampling_counters() ->
    Hooks = get_sampling_hook_counters(),
    Packets = get_sampling_packet_counters(),
    [{hooks,Hooks}, {packets,Packets}].

%%Add a filtering condition in sample_loop
add_sampling_condition(Condition) ->
    sample({add_condition, Condition}).

%%Reset sample process queues
%% restart_sampling -> ok | {error, timeout}
restart_sampling() ->
    sample({restart, self()}),
    receive
        {restart, ok} -> ok
    after 10000 -> {error, timeout}
    end.

start_sampling() ->
    case whereis(mod_mon_sampling_loop) of
        undefined ->
            ?DEBUG("Starting mod_mon_sampling_loop", []),
            Pid = spawn(?MODULE, sampling_loop, [[],[],[]]),
            register(mod_mon_sampling_loop, Pid),
            Pid;
        Pid ->
            ?DEBUG("mod_mon_sampling_loop already running with pid ~p, nothing to do.", [Pid]),
            Pid
    end.

stop_sampling() ->
    case whereis(mod_mon_sampling_loop) of
        undefined ->
            {error, not_started};
        _ ->
            mod_mon_sampling_loop ! stop,
            unregister(mod_mon_sampling_loop)
    end.

run_sample() ->
    run_sample(10).  % default it 10s sampling
run_sample(Delay) ->
    start_sampling(),
    timer:sleep(Delay*1000),
    stop_sampling().

%%%%%%%%%%%%%%%%%%%%%%
%% DB wrapper implementation
%% this is a temporary solution, waiting for a better one
%% monitor should use add_monitor to perform initialisation
%% TODO: integration into ejabberd database layer

db_mnesia_to_sql(roster) -> <<"rosterusers">>;
db_mnesia_to_sql(offline_msg) -> <<"spool">>;
db_mnesia_to_sql(passwd) -> <<"users">>;
db_mnesia_to_sql(Table) -> jlib:atom_to_binary(Table).

db_table_size(passwd) ->
    lists:foldl(fun(Host, Acc) ->
                        Acc + ejabberd_auth:get_vh_registered_users_number(Host)
                end, 0, ejabberd_config:get_global_option(hosts, fun(V) when is_list(V) -> V end));
db_table_size(Table) ->
    [ModName|_] = str:tokens(jlib:atom_to_binary(Table), <<"_">>),
    Module = jlib:binary_to_atom(<<"mod_",ModName/binary>>),
    SqlTableSize = lists:foldl(fun(Host, Acc) ->
                                       case gen_mod:is_loaded(Host, Module) of
                                           true -> Acc + db_table_size(Table, Host);
                                           false -> Acc
                                       end
                               end, 0, ejabberd_config:get_global_option(hosts, fun(V) when is_list(V) -> V end)),
    Info = mnesia:table_info(Table, all),
    case proplists:get_value(local_content, Info) of
        true -> proplists:get_value(size, Info) + other_nodes_db_size(Table) + SqlTableSize;
        false -> proplists:get_value(size, Info) + SqlTableSize
    end.

db_table_size(session, _Host) ->
    0;
db_table_size(s2s, _Host) ->
    0;
db_table_size(Table, Host) ->
    Query = case undefined %TODO%?SGBD
 of
                mysql -> [<<"select table_rows from information_schema.tables where table_name='">>, (db_mnesia_to_sql(Table))/binary, <<"'">>];
                _ -> [<<"select count(*) from ">>, (db_mnesia_to_sql(Table))/binary]
            end,
    case catch ejabberd_odbc:sql_query(Host, Query) of
        V when is_integer(V) ->
            V;
        V when is_binary(V) ->
            case catch jlib:binary_to_integer(V) of
                {'EXIT', _} -> 0;
                Int -> Int
            end;
        {selected, [_], [{V}]} when is_integer(V) ->
            V;
        {selected, [_], [{V}]} when is_binary(V) ->
            case catch jlib:binary_to_integer(V) of
                {'EXIT', _} -> 0;
                Int -> Int
            end;
        _ ->
            0
    end.

%% calculates table size on cluster excluding current node
other_nodes_db_size(Table) ->
    lists:foldl(fun(Node, Acc) ->
                    Acc + rpc:call(Node, mnesia, table_info, [Table, size])
                end, 0, lists:delete(node(), ejabberd_cluster:get_nodes())).

%%%%%%%%%%%%%%%%%%%%%%
%% Helper functions

xmlns(Hook, Els) ->
    case lists:keysearch(<<"query">>, 2, Els) of
        {value, #xmlel{name = <<"query">>, attrs = Xml}} ->
            {Hook, xml:get_attr_s(<<"xmlns">>, Xml)};
        _ ->
            {Hook, <<"unknown">>}
    end.

direction(Host, Host, Host) -> self;
direction(Host, Host, _)    -> out;
direction(Host, _, Host)    -> in;
direction(_Host, _, _)       -> relay.

s2s({Hook, Els}) ->
        {s2s(Hook), Els};
s2s(Hook) ->
    jlib:binary_to_atom(<<"s2s_",(jlib:atom_to_binary(Hook))/binary>>).

serverhost(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    case whereis(Proc) of
        undefined ->
            case str:chr(Host, $.) of
            0 -> <<"">>;
            P -> serverhost(str:substr(Host, P+1))
            end;
        _ ->
            Host
    end.

%%%%%%%%%%%%%%%%%%%%%%
                                                % Hooks implementation

offline_message_hook(From, #jid{luser=LUser,lserver=LServer,lresource=LResource} = To, Packet) ->
    action(LServer, {packet, offline, From, To, Packet}),
    action(LServer, {set, LUser, LResource, offline_message_hook}).
resend_offline_messages_hook(Ls, User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    action(LServer, {set, LUser, <<"">>, resend_offline_messages_hook}),
    Ls.

sm_register_connection_hook(SID, JID) ->
    sm_register_connection_hook(SID, JID, []).
sm_register_connection_hook(SID, #jid{luser=LUser,lserver=LServer,lresource=LResource} = _JID, Info) ->
    case proplists:get_value(conn, Info) of
        c2s -> action(LServer, {set, LUser, LResource, sm_register_connection_c2s});
        c2s_tls -> action(LServer, {set, LUser, LResource, sm_register_connection_c2s_tls});
        c2s_compressed -> action(LServer, {set, LUser, LResource, sm_register_connection_c2s_compressed});
        http_bind -> action(LServer, {set, LUser, LResource, sm_register_connection_http_bind});
        http_poll -> action(LServer, {set, LUser, LResource, sm_register_connection_http_poll});
        http_ws -> action(LServer, {set, LUser, LResource, sm_register_connection_http_ws});
        _ -> none
    end,
    AuthModule = xml:get_attr_s(auth_module, Info),
    Annonymous = (AuthModule == ejabberd_auth_anonymous),
    US = <<LUser/binary,"@",LServer/binary>>,
    active_user(LUser, LServer, LResource),
    compute(LServer, {register_connection, US, element(1, SID), LServer, Annonymous}),
    action(LServer, {set, LUser, LResource, sm_register_connection_hook}).
sm_remove_connection_hook(SID, JID) ->
    sm_remove_connection_hook(SID, JID, []).
sm_remove_connection_hook(_SID, #jid{luser=LUser,lserver=LServer,lresource=LResource} = _JID, Info) ->
    case proplists:get_value(conn, Info) of
        c2s -> action(LServer, {set, LUser, LResource, sm_remove_connection_c2s});
        c2s_tls -> action(LServer, {set, LUser, LResource, sm_remove_connection_c2s_tls});
        c2s_compressed -> action(LServer, {set, LUser, LResource, sm_remove_connection_c2s_compressed});
        http_bind -> action(LServer, {set, LUser, LResource, sm_remove_connection_http_bind});
        http_poll -> action(LServer, {set, LUser, LResource, sm_remove_connection_http_poll});
        http_ws -> action(LServer, {set, LUser, LResource, sm_remove_connection_http_ws});
        _ -> none
    end,
    AuthModule = xml:get_attr_s(auth_module, Info),
    Annonymous = (AuthModule == ejabberd_auth_anonymous),
    US = <<LUser/binary,"@",LServer/binary>>,
    compute(LServer, {remove_connection, US, LServer, Annonymous}),
    action(LServer, {set, LUser, LResource, sm_remove_connection_hook}).

roster_in_subscription(Ls, User, Server, _To, _Type, _Reason) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    action(LServer, {set, LUser, <<"">>, roster_in_subscription}),
    Ls.
roster_out_subscription(User, Server, _To, _Type) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    action(LServer, {set, LUser, <<"">>, roster_out_subscription}).

user_available_hook(#jid{luser=LUser,lserver=LServer,lresource=LResource} = _JID) ->
    action(LServer, {set, LUser, LResource, user_available_hook}).

unset_presence_hook(User, Server, Resource, _Status) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    LResource = jlib:resourceprep(Resource),
    action(LServer, {set, LUser, LResource, unset_presence_hook}).
set_presence_hook(User, Server, Resource, _Presence) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    LResource = jlib:resourceprep(Resource),
    action(LServer, {set, LUser, LResource, set_presence_hook}).

user_send_packet(Packet, _StateData, From, To) ->
    user_send_packet(From, To, Packet),
    Packet.

user_send_packet(#jid{luser=LUser,lserver=LServer,lresource=LResource} = From,
                 To, #xmlel{name=Name, attrs=Attrs, children=Els} = Packet) ->
    Hook = receive_hook(LUser, LServer, LResource, Name, Attrs, Els),
    action(LServer, {packet, recv, From, To, Packet}),
    action(LServer, {set, LUser, LResource, user_receive_packet}),
    action(LServer, {set, LUser, LResource, Hook}).

s2s_send_packet(#jid{luser=LUser,lserver=LServer,lresource=LResource} = From,
                To, #xmlel{name=Name, attrs=Attrs, children=Els} = Packet) ->
    Hook = send_hook(LUser, LServer, LResource, Name, Attrs, Els),
    Host = serverhost(LServer),
    action(Host, {packet, send, From, To, Packet}),
    action(Host, {set, LUser, LResource, s2s_send_packet}),
    action(Host, {set, LUser, LResource, s2s(Hook)}).

%% Be carefull: One action is triggered on message for summing up
send_hook(LUser, LServer, LResource, Name, Attrs, Els) ->
    case Name of
        <<"presence">> ->
            case xml:get_attr_s(<<"type">>, Attrs) of
                <<"subscribe">> -> subscribe_send_packet;
                <<"subscribed">> -> subscribed_send_packet;
                <<"unsubscribe">> -> unsubscribe_send_packet;
                <<"unsubscribed">> -> unsubscribed_send_packet;
                _ -> presence_send_packet
            end;
        <<"message">> ->
            if ?SIZE_COUNTING ->
                    Size = lists:foldl(fun(
                                         #xmlel{name = <<"body">>, children=[{xmlcdata, Data}]},
                                         Acc) ->
                                               Acc+size(Data);
                                          (_, Acc) -> Acc
                                       end, 0, Els),
                    action(LServer, {message_send_size, LUser, LResource, Size});
                true ->
                    ok
            end,
            %% this acts as a sum value
            action(LServer, {set, LUser, LResource, message_send_packet}),
            case xml:get_attr_s(<<"type">>, Attrs) of
                <<"normal">> -> normal_send_packet;
                <<"chat">> -> chat_send_packet;
                <<"groupchat">> -> groupchat_send_packet;
                <<"error">> -> error_send_packet;
                <<"headline">> -> headline_send_packet;
                _ -> normal_send_packet %% default message type
            end;
        <<"iq">> ->
            case xml:get_attr_s(<<"type">>, Attrs) of
                <<"error">> -> iq_error_send_packet;
                <<"result">> -> iq_result_send_packet;
                <<"set">> -> xmlns(iq_set_send_packet, Els);
                <<"get">> -> xmlns(iq_get_send_packet, Els);
                _ -> iq_send_packet
            end;
        <<"broadcast">> ->
            broadcast_send_packet
    end.

user_receive_packet(Packet, _StateData, JID, From, To) ->
    user_receive_packet(JID, From, To, Packet),
    Packet.

user_receive_packet(_JID, From, #jid{luser=LUser,lserver=LServer,lresource=LResource} = To, #xmlel{name=Name, attrs=Attrs, children=Els} = Packet) ->
    Hook = send_hook(LUser, LServer, LResource, Name, Attrs, Els),
    action(LServer, {packet, send, From, To, Packet}),
    action(LServer, {set, LUser, LResource, user_send_packet}),
    action(LServer, {set, LUser, LResource, Hook}).

s2s_receive_packet(From, #jid{luser=LUser,lserver=LServer,lresource=LResource}=To,
                   #xmlel{name=Name, attrs=Attrs, children=Els} = Packet) ->
    Hook = receive_hook(LUser, LServer, LResource, Name, Attrs, Els),
    Host = serverhost(LServer),
    action(Host, {packet, recv, From, To, Packet}),
    action(Host, {set, LUser, LResource, s2s_receive_packet}),
    action(Host, {set, LUser, LResource, s2s(Hook)}).

%% Be carefull: One action is triggered on message for summing up
receive_hook(LUser, LServer, LResource, Name, Attrs, Els) ->
    case Name of
        <<"presence">> ->
            case xml:get_attr_s(<<"type">>, Attrs) of
                <<"subscribe">> -> subscribe_receive_packet;
                <<"subscribed">> -> subscribed_receive_packet;
                <<"unsubscribe">> -> unsubscribe_receive_packet;
                <<"unsubscribed">> -> unsubscribed_receive_packet;
                _ -> presence_receive_packet
            end;
        <<"message">> ->
            if ?SIZE_COUNTING ->
                    Size = lists:foldl(fun
                                           (#xmlel{name = <<"body">>, children=[{xmlcdata, Data}]}, Acc) -> Acc+size(Data);
                                           (_, Acc) -> Acc
                                       end, 0, Els),
                    action(LServer, {message_receive_size, LUser, LResource, Size});
                true ->
                    ok
            end,
            %% This acts as a sum value:
            action(LServer, {set, LUser, LResource, message_receive_packet}),
            case xml:get_attr_s(<<"type">>, Attrs) of
                <<"normal">> -> normal_receive_packet;
                <<"chat">> -> chat_receive_packet;
                <<"groupchat">> -> groupchat_receive_packet;
                <<"error">> -> error_receive_packet;
                <<"headline">> -> headline_receive_packet;
                _ -> normal_receive_packet %% default message type
            end;
        <<"iq">> ->
            case xml:get_attr_s(<<"type">>, Attrs) of
                <<"error">> -> iq_error_receive_packet;
                <<"result">> -> iq_result_receive_packet;
                <<"set">> -> xmlns(iq_set_receive_packet, Els);
                <<"get">> -> xmlns(iq_get_receive_packet, Els);
                _ -> iq_receive_packet
            end;
        <<"broadcast">> ->
            broadcast_receive_packet
    end.

remove_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    action(LServer, {set, LUser, <<"">>, remove_user}).

%%%%%%%%%%%%%%%%%%%%%%
%% Transports hooks

transport_login_hook(Host, T, _PID, #jid{luser=LUser,lserver=LServer,lresource=LResource}, _SN) ->
    Hook = jlib:binary_to_atom(<<(jlib:atom_to_binary(T))/binary,"_login">>),
    action(Host, {set, LUser, LServer, LResource, Hook}).

transport_logout_hook(Host, T, #jid{luser=LUser,lserver=LServer,lresource=LResource}, _SN) ->
    Hook = jlib:binary_to_atom(<<(jlib:atom_to_binary(T))/binary,"_logout">>),
    action(Host, {set, LUser, LServer, LResource, Hook}).

transport_register_hook(Host, T, _Success, #jid{luser=LUser,lserver=LServer,lresource=LResource}, _SN) ->
    Hook = jlib:binary_to_atom(<<(jlib:atom_to_binary(T))/binary,"_register">>),
    action(Host, {set, LUser, LServer, LResource, Hook}).

transport_unregister_hook(Host, T, #jid{luser=LUser,lserver=LServer,lresource=LResource}) ->
    Hook = jlib:binary_to_atom(<<(jlib:atom_to_binary(T))/binary,"_unregister">>),
    action(Host, {set, LUser, LServer, LResource, Hook}).

transport_send_message_hook(Host, T, #jid{luser=LUser,lserver=LServer,lresource=LResource}, _SN) ->
    Hook = jlib:binary_to_atom(<<(jlib:atom_to_binary(T))/binary,"_send_packet">>),
    action(Host, {set, LUser, LServer, LResource, Hook}).

transport_receive_message_hook(Host, T, #jid{luser=LUser,lserver=LServer,lresource=LResource}, _SN) ->
    Hook = jlib:binary_to_atom(<<(jlib:atom_to_binary(T))/binary,"_receive_packet">>),
    action(Host, {set, LUser, LServer, LResource, Hook}).

%%%%%%%%%%%%%%%%%%%%%%
%% Customers specific hooks

register_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    action(LServer, {set, LUser, <<"">>, register_user}).

muc_create(_Host, ServerHost, Room, #jid{luser=LUser,lserver=LServer,lresource=LResource}) ->
    action(ServerHost, {muc, Room, create}),
    action(ServerHost, {set, LUser, LServer, LResource, muc_create}).

muc_destroy(_Host, ServerHost, Room) ->
    action(ServerHost, {muc, Room, destroy}),
    action(ServerHost, {set, <<"">>, ServerHost, <<"">>, muc_destroy}).

muc_user_join(_Host, ServerHost, Room, #jid{luser=LUser,lserver=LServer,lresource=LResource}) ->
    action(ServerHost, {muc, Room, join}),
    action(ServerHost, {set, LUser, LServer, LResource, muc_user_join}).

muc_user_leave(_Host, ServerHost, Room, #jid{luser=LUser,lserver=LServer,lresource=LResource}) ->
    action(ServerHost, {muc, Room, leave}),
    action(ServerHost, {set, LUser, LServer, LResource, muc_user_leave}).

muc_message(_Host, ServerHost, Room, #jid{luser=LUser,lserver=LServer,lresource=LResource}, _Packet, Size) ->
    action(ServerHost, {muc, Room, muc_message_size, Size}),
    action(ServerHost, {set, LUser, LServer, LResource, muc_message}).

proxy65_http_store(#jid{luser=LUser,lserver=LServer,lresource=LResource}, _To, FileName, Size) ->
    action(LServer, {proxy65, FileName, Size}),
    action(LServer, {set, LUser, LServer, LResource, proxy65_http_store}).

%% proxy65 bytestream activation
%% see mod_proxy65_stream:activate/2
proxy65_register_stream(#jid{luser=LUser,
                             lserver=LServer,
                             lresource=LResource}, _To, _Addr ) ->
    action(LServer, {set, LUser, LServer, LResource, proxy65_register_stream}).

%% see mod_proxy65_stream:terminate/3
proxy65_unregister_stream(#jid{luser=LUser,
                               lserver=LServer,
                               lresource=LResource}, _To, _Addr ) ->
    action(LServer, {set, LUser, LServer, LResource, proxy65_unregister_stream}).

%% TURN (rfc 5766 section 9) CreatePermission Request
%% see ejabberd_turn:active/2 (method: STUN_METHOD_CREATE_PERMISSION)
turn_register_permission( undefined, _Addr ) ->
    undefined;
turn_register_permission( JidStr, _Addr ) ->
    case jlib:string_to_jid(JidStr) of
        error -> error;
        #jid{luser=LUser,lserver=LServer,lresource=LResource} ->
            action(LServer, {set, LUser, LServer, LResource,
                             turn_register_permission})
    end.

%% TURN (rfc 5766) Permission deallocation - see ejabberd_turn:terminate/3
turn_unregister_permission(undefined, _Addr ) ->
    undefined;
turn_unregister_permission(JidStr, _Addr ) ->
    case jlib:string_to_jid(JidStr) of
        error -> error;
        #jid{luser=LUser,lserver=LServer,lresource=LResource} ->
            action(LServer, {set, LUser, LServer, LResource,
                             turn_unregister_permission})
    end.

%% PubSub dynamic hook handling
pubsub_publish_item(Host, Node, _Publisher, _HostJID, _ItemId, _Payload) ->
    action(Host, {set, {pubsub_publish_item, Node}}).

pubsub_broadcast_stanza(Host, Node, Count, _Stanza) ->
    action(Host, {set, {pubsub_broadcast_stanza, Node, Count}}).

chat_invitation_by_email_hook(#jid{luser=LUser,lserver=LServer,lresource=LResource}, _To, _Password, _Room) ->
    %% TODO: Host = f(Room) ?
    action(LServer, {set, LUser, LServer, LResource, chat_invitation_by_email_hook}).

chat_invitation_accepted(_Host, ServerHost, _Room, #jid{luser=LUser,lserver=LServer,lresource=LResource}, _Password) ->
    action(ServerHost, {set, LUser, LServer, LResource, chat_invitation_accepted}).

%% active user feature
active_user(LUser, LServer, LResource) ->
    if (not ?ANNONYMOUS_CONNECTIONS)
        and ?ACTIVE_ENABLED ->
            Key = <<LUser/binary, LResource/binary>>,
            action(LServer, {active, Key});
        true ->
            ok
    end.

get_active_counters(Host) when is_binary(Host) ->
    if ?ACTIVE_ENABLED ->
            lists:foldl(fun({DictName, _}, Acc) ->
                    action(Host, {get, self(), DictName}),
                    case wait(value) of
                        timeout -> Acc;
                        Value -> [{DictName, Value}|Acc]
                    end
                end, [], ?COMPUTING_DICTS);
       true ->
            []
    end.

%%--------------------------------------------------------------------
%% Function: is_subdomain(Domain1, Domain2) -> true | false
%% Description: Return true if Domain1 (a string representing an
%% internet domain name) is a subdomain (or the same domain) of
%% Domain2
%% --------------------------------------------------------------------
is_subdomain(Domain1, Domain2) ->
    lists:suffix(str:tokens(Domain2, <<".">>), str:tokens(Domain1, <<".">>)).

%% Return the list of components which are a subdomain of Host (including Host itself)
list_components(Host) ->
    Components = mnesia:dirty_all_keys(route),
    lists:foldl(fun(Component, Acc) ->
                        case is_subdomain(Component, Host) of
                                true -> [Component | Acc];
                                false -> Acc
                        end
                end, [], Components).

%% other available hooks
%%adhoc_local_commands
%%adhoc_local_items
%%adhoc_sm_commands
%%adhoc_sm_items
%%c2s_stream_features
%%c2s_unauthenticated_iq
%%s2s_loop_debug
%%s2s_connect_hook
%%disco_local_features
%%disco_local_identity
%%disco_local_items
%%disco_sm_features
%%disco_sm_identity
%%disco_sm_items
%%ejabberd_ctl_process
%%local_send_to_resource_hook
%%resend_subscription_requests_hook
%%roster_get
%%roster_get_jid_info
%%roster_get_subscription_lists
%%roster_process_item

put(Key, Value) ->
    mnesia:dirty_write(#mon{key = Key, value = Value}).

get(Key) ->
    case mnesia:dirty_read(mon, Key) of
        [R] ->
            R#mon.value;
        _ ->
            undefined
    end.

get() ->
    mnesia:dirty_select(
      mon, [{#mon{key = '$1', value = '$2', _ = '_'}, [], [{{'$1', '$2'}}]}]).
