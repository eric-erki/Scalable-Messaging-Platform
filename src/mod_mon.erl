%%%-------------------------------------------------------------------
%%% File    : mod_mon.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Event monitor for runtime statistics
%%% Created : 10 Apr 2014 by Christophe Romain <christophe.romain@process-one.net>
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

-module(mod_mon).

-behaviour(ejabberd_config).
-author('christophe.romain@process-one.net').
-behaviour(gen_mod).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include("ejabberd_commands.hrl").
-include("mod_mon.hrl").

-define(PROCNAME, ?MODULE).
-define(CALL_TIMEOUT, 5000).

%% module API
-export([start_link/2, start/2, stop/1]).
-export([value/2, avg/2, dump/1, declare/3, info/1]).
-export([reset/2, set/3, inc/3, dec/3, sum/3]).
%% administration commands
-export([flush_probe_command/2]).
%% monitors
-export([process_queues/2, internal_queues/2, health_check/1, jabs_count/1]).
-export([node_sessions_count/1, cpu_usage/1]).
%% server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
%% helpers
-export([backend_ip_port/1]).

-export([offline_message_hook/3, resend_offline_messages_hook/3,
	 sm_register_connection_hook/3, sm_remove_connection_hook/3,
	 roster_in_subscription/6, roster_out_subscription/4,
	 user_available_hook/1, badauth/3,
	 unset_presence_hook/4, set_presence_hook/4,
	 user_send_packet/4, user_receive_packet/5,
	 c2s_replaced/1, s2s_send_packet/3, s2s_receive_packet/3,
	 privacy_iq_set/4, privacy_iq_get/5, remove_user/2,
	 register_user/2, api_call/3, backend_api_call/3,
	 backend_api_response_time/4, backend_api_timeout/3,
	 backend_api_error/3, backend_api_badauth/3,
	 pubsub_create_node/5, pubsub_delete_node/4,
	 pubsub_publish_item/6, mod_opt_type/1, opt_type/1,
	 depends/2]).
         %pubsub_broadcast_stanza/4, get_commands_spec/0 ]).

% dictionary command overrided for better control
-compile({no_auto_import, [get/1]}).

-record(mon, {probe, value}).
-record(state, {host, backends, monitors, timers=[]}).

%%====================================================================
%% API
%%====================================================================

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE, [Host, Opts],
                           [{max_queue, 10000}]).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
                 transient, 5000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    catch ?GEN_SERVER:call(Proc, stop),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

value(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    cheap_counters:get(Host, Probe).

set(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    cheap_counters:set(Host, Probe, Value).

inc(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    cheap_counters:inc(Host, Probe, Value).

dec(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    cheap_counters:dec(Host, Probe, Value).

sum(Host, Probe, Value) when is_binary(Host), is_atom(Probe) ->
    cheap_counters:inc_pair(Host, Probe, Value).

avg(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    case cheap_counters:get_pair(Host, Probe) of
        {_, 0} -> 0;
        {Sum, Count} -> Sum div Count
    end.

reset(Host, Probe) when is_binary(Host), is_atom(Probe) ->
    cheap_counters:reset(Host, Probe).

dump(Host) when is_binary(Host) ->
    [{Probe, Value} || {_, Probe, Value} <- cheap_counters:get(Host)].

declare(Host, Probe, Type) when is_binary(Host), is_atom(Probe) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, {declare, Probe, Type}, ?CALL_TIMEOUT).

%%====================================================================
%% server callbacks
%%====================================================================

init([Host, Opts]) ->
    % List enabled monitors, defaults all
    MonitorsBase = gen_mod:get_opt(monitors_base, Opts,
                               fun(L) when is_list(L) -> L end,
                               ?DEFAULT_MONITORS),
    MonitorsDesc = gen_mod:get_opt(monitors, Opts,
                               fun(L) when is_list(L) -> L end,
                               []) ++ MonitorsBase,
    Monitors = [monitor_spec(Desc) || Desc<-MonitorsDesc],

    % List enabled hooks, defaults all supported hooks
    Hooks = gen_mod:get_opt(hooks, Opts,
                               fun(L) when is_list(L) -> L end,
                               ?SUPPORTED_HOOKS),

    % Statistics backends
    BackendsSpec = gen_mod:get_opt(backends, Opts,
                                   fun(List) when is_list(List) -> List
                                   end, []),
    Backends = lists:usort([init_backend(Host, Spec)
                            || Spec <- lists:flatten(BackendsSpec)]),

    %% Note: we use priority of 20 cause some modules can block execution of hooks
    %% example; mod_offline stops the hook if it stores packets
    %Components = [Dom || Dom <- mnesia:dirty_all_keys(route),
    %                     lists:suffix(
    %                        str:tokens(Dom, <<".">>),
    %                        str:tokens(Host, <<".">>))],

    % efficient local sessions count
    EfficientNodeSessions =
      lists:member(sm_register_connection_hook, Hooks)
      andalso lists:member(sm_remove_connection_hook, Hooks),
    if EfficientNodeSessions ->
         cheap_counters:set(Host, sessions, node_sessions_count(Host))
    end,

    [ejabberd_hooks:add(Hook, Component, ?MODULE, Hook, 20)
     || Component <- [Host], % Todo, Components for muc and pubsub
        Hook <- Hooks],
    ejabberd_hooks:add(api_call, ?MODULE, api_call, 20),
    ejabberd_commands:register_commands(get_commands_spec()),

    % Store probes specs
    catch ets:new(mon_probes, [named_table, public]),
    [ets:insert(mon_probes, {Probe, gauge}) || Probe<-?GAUGE],
    [ets:insert(mon_probes, {Probe, average}) || Probe<-?AVG],

    % Start timer for backends sync
    {ok, T} = timer:send_interval(?MINUTE, push_metrics),

    {ok, #state{host = Host,
                backends = Backends,
                monitors = Monitors,
                timers = [T]}}.

handle_call({declare, Probe, Type}, _From, State) ->
    Result = case Type of
        gauge ->
            [ets:insert(mon_probes, {Probe, gauge}) || not lists:member(Probe, ?GAUGE)],
            ok;
        average ->
            [ets:insert(mon_probes, {Probe, average}) || not lists:member(Probe, ?AVG)],
            ok;
        counter ->
            ok;
        _ ->
            error
    end,
    {reply, Result, State};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(push_metrics, State) ->
    Host = State#state.host,
    Probes = compute_probes(Host, State#state.monitors),
    ExtProbes = ejabberd_hooks:run_fold(mon_monitors, Host, [], [Host]),
    [_, NodeId] = str:tokens(jlib:atom_to_binary(node()), <<"@">>),
    [Node | _] = str:tokens(NodeId, <<".">>),
    DateTime = erlang:universaltime(),
    UnixTime = calendar:datetime_to_gregorian_seconds(DateTime) - 62167219200,
    [push(Host, Node, Probes++ExtProbes, UnixTime, Backend)
     || Backend <- State#state.backends],
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    Host = State#state.host,
    [timer:cancel(T) || T <- State#state.timers],
    [ejabberd_hooks:delete(Hook, Host, ?MODULE, Hook, 20)
     || Hook <- ?SUPPORTED_HOOKS],
    ejabberd_hooks:delete(api_call, ?MODULE, api_call, 20),
    ejabberd_commands:unregister_commands(get_commands_spec()).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% ejabberd commands
%%====================================================================

get_commands_spec() ->
    [#ejabberd_commands{name = flush_probe,
                        tags = [stats],
                        desc = "Returns last value from probe and resets its historical data if any.",
                        module = ?MODULE, function = flush_probe_command,
                        args = [{server, binary}, {probe_name, binary}],
                        result = {probe_value, integer}}].

flush_probe_command(Host, Probe) ->
    case lists:reverse(str:tokens(Probe, <<"_">>)) of
        [<<"users">>,<<"active">> | _] ->
            % add temporary hack for active probe backward compatibility
            mod_mon_active:flush_active_command(Host, Probe);
        _ ->
            case reset(Host, jlib:binary_to_atom(Probe)) of
                N when is_integer(N) -> N;
                _ -> 0
            end
    end.

%%====================================================================
%% Helper functions
%%====================================================================

hookid(Name) when is_binary(Name) -> jlib:binary_to_atom(Name).

packet(Main, Name, <<>>) -> <<Name/binary, "_", Main/binary, "_packet">>;
packet(Main, _Name, Type) -> <<Type/binary, "_", Main/binary, "_packet">>.

concat(Pre, <<>>) -> Pre;
concat(Pre, Post) -> <<Pre/binary, "_", Post/binary>>.

%serverhost(Host) ->
%    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
%    case whereis(Proc) of
%        undefined ->
%            case str:chr(Host, $.) of
%                0 -> {undefined, <<>>};
%                P -> serverhost(str:substr(Host, P+1))
%            end;
%        _ ->
%            {Proc, Host}
%    end.

get_probe_value(Probe, Value) ->
    case catch ets:lookup(mon_probes, Probe) of
        [{Probe, average}] ->
            % note: we can also call avg(Host, Probe)
            Sum = Value bsr 24,
            case Value band 16#ffffff of
                0 -> {average, 0};
                Count -> {average, Sum div Count}
            end;
        [{Probe, gauge}] ->
            {gauge, Value};
        _ ->
            {counter, Value}
    end.

%%====================================================================
%% database api
%%====================================================================

%% this is a temporary solution, waiting for a better one, to get table size

% db_mnesia_to_sql(roster) -> <<"rosterusers">>;
% db_mnesia_to_sql(offline_msg) -> <<"spool">>;
% db_mnesia_to_sql(passwd) -> <<"users">>;
% db_mnesia_to_sql(Table) -> jlib:atom_to_binary(Table).
% 
% db_table_size(passwd) ->
%     lists:foldl(fun(Host, Acc) ->
%                         Acc + ejabberd_auth:get_vh_registered_users_number(Host)
%                 end, 0, ejabberd_config:get_global_option(hosts, fun(V) when is_list(V) -> V end));
% db_table_size(Table) ->
%     [ModName|_] = str:tokens(jlib:atom_to_binary(Table), <<"_">>),
%     Module = jlib:binary_to_atom(<<"mod_",ModName/binary>>),
%     SqlTableSize = lists:foldl(fun(Host, Acc) ->
%                                        case gen_mod:is_loaded(Host, Module) of
%                                            true -> Acc + db_table_size(Table, Host);
%                                            false -> Acc
%                                        end
%                                end, 0, ejabberd_config:get_global_option(hosts, fun(V) when is_list(V) -> V end)),
%     Info = mnesia:table_info(Table, all),
%     case proplists:get_value(local_content, Info) of
%         true -> proplists:get_value(size, Info) + other_nodes_db_size(Table) + SqlTableSize;
%         false -> proplists:get_value(size, Info) + SqlTableSize
%     end.
% 
% db_table_size(session, _Host) ->
%     0;
% db_table_size(s2s, _Host) ->
%     0;
% db_table_size(Table, Host) ->
%     %% TODO (for MySQL):
%     %% Query = [<<"select table_rows from information_schema.tables where table_name='">>,
%     %%          db_mnesia_to_sql(Table), <<"'">>];
%     %% can use sql_queries:count_records_where(Host, db_mnesia_to_sql(Table), <<>>)
%     Query = [<<"select count(*) from ">>, db_mnesia_to_sql(Table)],
%     case catch ejabberd_sql:sql_query(Host, Query) of
%         {selected, [_], [[V]]} ->
%             case catch jlib:binary_to_integer(V) of
%                 {'EXIT', _} -> 0;
%                 Int -> Int
%             end;
%         _ ->
%             0
%     end.
% 
% %% calculates table size on cluster excluding current node
% other_nodes_db_size(Table) ->
%     lists:foldl(fun(Node, Acc) ->
%                     Acc + rpc:call(Node, mnesia, table_info, [Table, size])
%                 end, 0, lists:delete(node(), ejabberd_cluster:get_nodes())).

%%====================================================================
%% Hooks handlers
%%====================================================================

offline_message_hook(_From, #jid{lserver=LServer}, _Packet) ->
    inc(LServer, offline_message, 1).
resend_offline_messages_hook(Ls, _User, Server) ->
    inc(jid:nameprep(Server), resend_offline_messages, 1),
    Ls.

sm_register_connection_hook(_SID, #jid{lserver=LServer}, Info) ->
    Post = case proplists:get_value(conn, Info) of
        undefined -> <<>>;
        Atom -> jlib:atom_to_binary(Atom)
    end,
    Hook = hookid(concat(<<"sm_register_connection">>, Post)),
    inc(LServer, sessions, 1),
    inc(LServer, Hook, 1).
sm_remove_connection_hook(_SID, #jid{lserver=LServer}, Info) ->
    Post = case proplists:get_value(conn, Info) of
        undefined -> <<>>;
        Atom -> jlib:atom_to_binary(Atom)
    end,
    Hook = hookid(concat(<<"sm_remove_connection">>, Post)),
    dec(LServer, sessions, 1),
    inc(LServer, Hook, 1).

roster_in_subscription(Ls, _User, Server, _To, _Type, _Reason) ->
    inc(jid:nameprep(Server), roster_in_subscription, 1),
    Ls.
roster_out_subscription(_User, Server, _To, _Type) ->
    inc(jid:nameprep(Server), roster_out_subscription, 1).

user_available_hook(#jid{lserver=LServer}) ->
    inc(LServer, user_available_hook, 1).
unset_presence_hook(_User, Server, _Resource, _Status) ->
    inc(jid:nameprep(Server), unset_presence_hook, 1).
set_presence_hook(_User, Server, _Resource, _Presence) ->
    inc(jid:nameprep(Server), set_presence_hook, 1).

user_send_packet(#xmlel{name=Name, attrs=Attrs} = Packet,
                 _C2SState, #jid{lserver=LServer}, _To) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(packet(<<"receive">>, Name, Type)), % user send = server receive
    inc(LServer, Hook, 1),
    Packet.
user_receive_packet(#xmlel{name=Name, attrs=Attrs} = Packet,
                    _C2SState, _JID, _From, #jid{lserver=LServer}) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(packet(<<"send">>, Name, Type)), % user receive = server send
    inc(LServer, Hook, 1),
    Packet.

c2s_replaced(#jid{lserver=LServer}) ->
    inc(LServer, c2s_replaced, 1).

s2s_send_packet(#jid{lserver=LServer}, _To,
                #xmlel{name=Name, attrs=Attrs}) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(concat(<<"s2s">>, packet(<<"send">>, Name, Type))),
    inc(LServer, Hook, 1).
s2s_receive_packet(_From, #jid{lserver=LServer},
                   #xmlel{name=Name, attrs=Attrs}) ->
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    Hook = hookid(concat(<<"s2s">>, packet(<<"receive">>, Name, Type))),
    inc(LServer, Hook, 1).

privacy_iq_set(Acc, #jid{lserver=LServer}, _To, _Iq) ->
    inc(LServer, privacy_iq_set, 1),
    Acc.

privacy_iq_get(Acc, #jid{lserver=LServer}, _To, _Iq, _) ->
    inc(LServer, privacy_iq_get, 1),
    Acc.

api_call(_Module, _Function, _Arguments) ->
    [inc(LServer, api_call, 1) || LServer <- ejabberd_config:get_myhosts()].
backend_api_call(LServer, _Method, _Path) ->
    inc(LServer, backend_api_call, 1).
backend_api_response_time(LServer, _Method, _Path, Ms) ->
    sum(LServer, backend_api_response_time, Ms).
backend_api_timeout(LServer, _Method, _Path) ->
    inc(LServer, backend_api_timeout, 1).
backend_api_error(LServer, _Method, _Path) ->
    inc(LServer, backend_api_error, 1).
backend_api_badauth(LServer, _Method, _Path) ->
    inc(LServer, backend_api_badauth, 1).

badauth(_LUser, LServer, _Password) ->
    inc(LServer, badauth, 1).

remove_user(_User, Server) ->
    inc(jid:nameprep(Server), remove_user, 1).
register_user(_User, Server) ->
    inc(jid:nameprep(Server), register_user, 1).

%muc_create(_Host, ServerHost, _Room, _JID) ->
%    inc(ServerHost, muc_rooms, 1),
%    inc(ServerHost, muc_create, 1).
%muc_destroy(_Host, ServerHost, _Room) ->
%    dec(ServerHost, muc_rooms, 1),
%    inc(ServerHost, muc_destroy, 1).
%muc_user_join(_Host, ServerHost, _Room, _JID) ->
%    inc(ServerHost, muc_users, 1),
%    inc(ServerHost, muc_user_join, 1).
%muc_user_leave(_Host, ServerHost, _Room, _JID) ->
%    dec(ServerHost, muc_users, 1),
%    inc(ServerHost, muc_user_leave, 1).

pubsub_create_node(ServerHost, _Host, _Node, _Nidx, _NodeOptions) ->
    inc(ServerHost, pubsub_create_node, 1).
pubsub_delete_node(ServerHost, _Host, _Node, _Nidx) ->
    inc(ServerHost, pubsub_delete_node, 1).
pubsub_publish_item(ServerHost, _Node, _Publisher, _From, _ItemId, _Packet) ->
    inc(ServerHost, pubsub_publish_item, 1).
%pubsub_broadcast_stanza(Host, Node, Count, _Stanza) ->
%    inc(Host, {inc, {pubsub_broadcast_stanza, Node, Count}}).

%%====================================================================
%% monitors spec parser
%%====================================================================

monitor_spec([{Name, Desc}]) ->
    monitor_spec({Name, Desc});
monitor_spec({Name, Desc}) when is_binary(Desc) ->
    Spec = case erl_scan:string(binary_to_list(Desc)) of
        {ok,[{atom,1,Fun}],_} -> parse_call(?MODULE, Fun, [], []);
        {ok,[{atom,1,Fun},Arg],_} -> parse_call(?MODULE, Fun, [Arg], []);
        {ok,[{atom,1,Mod},{':',1},{atom,1,Fun}|Args],_} -> parse_call(Mod, Fun, Args, []);
        {ok,Tokens,_} -> parse_descr(Tokens, []);
        _ -> undefined
    end,
    if Spec == undefined ->
         ?WARNING_MSG("Invalid description of monitor ~s: ~p", [Name, Desc]);
       true ->
         ?DEBUG("Monitor ~s defined as ~p", [Name, Spec])
    end,
    {Name, Spec};
% backward compatibility with old erlang term configuration
monitor_spec({Name, Fun}) when is_atom(Fun) ->
    {Name, {?MODULE, Fun, []}};
monitor_spec({Name, Fun, Arg}) when is_atom(Fun) ->
    {Name, {?MODULE, Fun, [Arg]}};
monitor_spec({Name, Mod, Fun, Args}) ->
    {Name, {Mod, Fun, Args}};
monitor_spec({Name, Mod, Fun, Args, Filter}) ->
    ?WARNING_MSG("Unsupported filtered monitor ~s: filter ~p not applied",
                [Name, Filter]),
    {Name, {Mod, Fun, Args}};
monitor_spec({Name, Desc}) ->
    ?WARNING_MSG("Invalid description of monitor ~s: ~p", [Name, Desc]),
    {Name, undefined}.

parse_call(Mod, Fun, [], Acc) ->
    {Mod, Fun, lists:reverse(Acc)};
parse_call(Mod, Fun, [{dot,1}|Tail], Acc) ->
   parse_call(Mod, Fun, Tail, Acc);
parse_call(Mod, Fun, [{'(',1}|Tail], Acc) ->
   parse_call(Mod, Fun, Tail, Acc);
parse_call(Mod, Fun, [{')',1}|Tail], Acc) ->
   parse_call(Mod, Fun, Tail, Acc);
parse_call(Mod, Fun, [{',',1}|Tail], Acc) ->
   parse_call(Mod, Fun, Tail, Acc);
parse_call(Mod, Fun, [{_,1,Arg}|Tail], Acc) ->
    parse_call(Mod, Fun, Tail, [Arg|Acc]);
parse_call(_Mod, _Fun, _Tail, _Acc) ->
    undefined.

parse_descr([], Acc) ->
    lists:reverse(Acc);
parse_descr([{'+',1}, {atom,1,Probe}|Tail], Acc) ->
    parse_descr(Tail, [{'+', Probe}|Acc]);
parse_descr([{'-',1}, {atom,1,Probe}|Tail], Acc) ->
    parse_descr(Tail, [{'-', Probe}|Acc]);
parse_descr(_Other, _Acc) ->
    undefined.

%%====================================================================
%% high level monitors
%%====================================================================

compute_probes(Host, Monitors) ->
    Probes = [dump_probe(Host, Probe, Value) || {Probe, Value} <- dump(Host)],
    Computed = lists:foldl(
            fun({I, {?MODULE, F, A}}, Acc) -> acc_monitor(I, apply(?MODULE, F, [Host|A]), Acc);
               ({I, {M, F, A}}, Acc) -> acc_monitor(I, apply(M, F, A), Acc);
               ({I, Spec}, Acc) when is_list(Spec) -> acc_monitor(I, eval_monitors(Probes, Spec, 0), Acc);
               (_, Acc) -> Acc
            end, [], Monitors),
    Probes ++ Computed.

dump_probe(Host, Probe, RawValue) ->
    case get_probe_value(Probe, RawValue) of
        {average, Value} ->
            % note: later we may need to call cheap_counters:reset_pair instead
            % but for now, both just set 0 as value
            reset(Host, Probe),
            {Probe, gauge, Value};
        {gauge, Value} ->
            {Probe, gauge, Value};
        {counter, Value} ->
            reset(Host, Probe),
            {Probe, counter, Value}
    end.

eval_monitors(_, [], Acc) ->
    Acc;
eval_monitors(Probes, [Action|Tail], Acc) ->
    eval_monitors(Probes, Tail, compute_monitor(Probes, Action, Acc)).

compute_monitor(Probes, Probe, Acc) when is_atom(Probe) ->
    compute_monitor(Probes, {'+', Probe}, Acc);
compute_monitor(Probes, {'+', Probe}, Acc) ->
    case lists:keyfind(Probe, 1, Probes) of
        {Probe, _Type, Val} -> Acc+Val;
        _ -> Acc
    end;
compute_monitor(Probes, {'-', Probe}, Acc) ->
    case lists:keyfind(Probe, 1, Probes) of
        {Probe, _Type, Val} -> Acc-Val;
        _ -> Acc
    end.

acc_monitor(dynamic, Values, Acc) when is_list(Values) ->
    lists:foldl(
        fun({Probe, Value}, Res) ->
                acc_monitor(Probe, Value, Res);
            (_, Res) ->
                Res
        end, Acc, Values);
acc_monitor(Probe, Value, Acc) ->
    [{Probe, gauge, Value}|Acc].

%%====================================================================
%% Cache sync
%%====================================================================

init_backend(Host, statsd) ->
    init_backend(Host, {statsd, <<"127.0.0.1:8125">>});
init_backend(Host, influxdb) ->
    init_backend(Host, {influx, <<"127.0.0.1:8089">>});
init_backend(Host, grapherl) ->
    init_backend(Host, {grapherl, <<"127.0.0.1:11111">>});
init_backend(Host, mnesia) ->
    Table = gen_mod:get_module_proc(Host, mon),
    mnesia:create_table(Table,
                        [{disc_copies, [node()]},
                         {local_content, true},
                         {record_name, mon},
                         {attributes, record_info(fields, mon)}]),
    mnesia;
init_backend(_Host, {Backend, EndPoint}) ->
    init_udp_backend(Backend, backend_ip_port(EndPoint));
init_backend(_, _) ->
    none.

init_udp_backend(_, undefined) ->
    none;
init_udp_backend(Backend, {Ip, Port}) ->
    case get_udp_socket(Ip, Port) of
        {ok, Socket} ->
            case gen_udp:send(Socket, Ip, Port, <<>>) of
                ok ->
                    gen_udp:close(Socket),
                    {Backend, Ip, Port};
                Error ->
                    ?ERROR_MSG("Can not send data to ~s backend: ~p", [Backend, Error]),
                    gen_udp:close(Socket),
                    none
            end;
        _ ->
            none
    end.

backend_ip_port(EndPoint) when is_binary(EndPoint) ->
    case string:tokens(binary_to_list(EndPoint), ":") of
        [Ip, Port|_] ->
            {backend_ip(Ip), backend_port(Port)};
        _ ->
            ?WARNING_MSG("backend endoint is invalid: ~p", [EndPoint]),
            undefined
    end.
backend_ip(Server) when is_list(Server) ->
    case catch inet:getaddr(Server, inet) of
        {ok, IpAddr} ->
            IpAddr;
        _ ->
            ?WARNING_MSG("backend address is invalid: ~p, fallback to localhost", [Server]),
            {127,0,0,1}
    end.
backend_port(Port) when is_list(Port) ->
    case catch list_to_integer(Port) of
        I when is_integer(I) ->
            I;
        _ ->
            ?WARNING_MSG("backend port is invalid: ~p", [Port]),
            0
    end.

get_udp_socket(Ip, Port) ->
    case gen_udp:open(0, [{active, false}, {sndbuf, 1500}]) of
        {ok, Socket} ->
            {ok, Socket};
        Error ->
            ?WARNING_MSG("can not open udp socket to ~p port ~p: ~p", [Ip, Port, Error]),
            Error
    end.

push(Host, _Node, Probes, _Time, mnesia) ->
    Table = gen_mod:get_module_proc(Host, mon),
    Cache = [{Key, Val} || {mon, Key, Val} <- ets:tab2list(Table)],
    lists:foreach(
        fun({Key, counter, Val}) ->
                case proplists:get_value(Key, Cache) of
                    undefined -> mnesia:dirty_write(Table, #mon{probe = Key, value = Val});
                    Old -> [mnesia:dirty_write(Table, #mon{probe = Key, value = Old+Val}) || Val > 0]
                end;
           ({Key, gauge, Val}) ->
                case proplists:get_value(Key, Cache) of
                    Val -> ok;
                    _ -> mnesia:dirty_write(Table, #mon{probe = Key, value = Val})
                end;
           ({health, _Type, _Val}) ->
                ok;
           ({Key, Type, Val}) ->
                ?WARNING_MSG("can not push ~p metric ~p with value ~p", [Type, Key, Val])
        end, Probes);
push(Host, Node, Probes, _Time, {statsd, Ip, Port}) ->
    % host.xmpp.node.metric:value|type
    % example: process-one.net.xmpp.xmpp-1.chat_receive_packet:1|c
    BaseId = <<Host/binary, ".xmpp.", Node/binary, ".">>,
    push_udp(Ip, Port, Probes, fun(Key, Val, Type) ->
            <<BaseId/binary, Key/binary, ":", Val/binary, "|", Type>>
        end);
push(Host, Node, Probes, _Time, {dogstatsd, Ip, Port}) ->
    % metric:value|type|#tag1:value,tag2
    % example: chat_receive_packet:1|c|#host=process-one.net,node=xmpp-1
    Tags = <<"#host:", Host/binary, ",node:", Node/binary>>,
    push_udp(Ip, Port, Probes, fun(Key, Val, Type) ->
            <<Key/binary, ":", Val/binary, "|", Type, "|", Tags/binary>>
        end);
push(Host, Node, Probes, Time, {influxdb, Ip, Port}) ->
    % metric,tag1=v1,tag2:v2 value=value timestamp
    % example: chat_receive_packet,host=process-one.net,node=xmpp-1 1 0
    Tags = <<"host=", Host/binary, ",node=", Node/binary>>,
    TS = <<(integer_to_binary(Time))/binary, "000000000">>,
    push_udp(Ip, Port, Probes, fun(Key, Val, _Type) ->
            <<Key/binary, ",", Tags/binary, " value=", Val/binary, " ", TS/binary>>
        end);
push(Host, Node, Probes, Time, {grapherl, Ip, Port}) ->
    % host/node.metric:type/timestamp:value
    % example: process-one.net/xmpp-1.chat_receive_packet:c/0:1
    BaseId = <<Host/binary, "/", Node/binary, ".">>,
    TS = integer_to_binary(Time),
    push_udp(Ip, Port, Probes, fun(Key, Val, Type) ->
            <<BaseId/binary, Key/binary, ":", Type, "/", TS/binary, ":", Val/binary>>
        end);
push(_Host, _Node, _Probes, _Time, _Backend) ->
    ok.

push_udp(Ip, Port, Probes, Format) ->
    case get_udp_socket(Ip, Port) of
        {ok, Socket} ->
            [gen_udp:send(Socket, Ip, Port, Packet)
             || Packet <- line_packets(Probes, Format)],
            gen_udp:close(Socket);
        Error ->
            Error
    end.

line_packets(Probes, Format) ->
    line_packets(Probes, Format, [<<>>]).
line_packets([], _Format, Pks) ->
    Pks;
line_packets([{health, _T, _V}|Probes], Format, Pks) ->
    line_packets(Probes, Format, Pks);
line_packets([{K, T, V}|Probes], Format, [Pk|Pks]) ->
    Key = jlib:atom_to_binary(K),
    Line = Format(Key, integer_to_binary(V), type_to_char(T)),
    NewPk = <<Line/binary, 10, Pk/binary>>,
    if size(NewPk) > 1300 ->
         line_packets(Probes, Format, [<<>>,NewPk|Pks]);
       true ->
         line_packets(Probes, Format, [NewPk|Pks])
    end.

type_to_char(counter) -> $c;
type_to_char(gauge) -> $g;
type_to_char(Type) ->
    ?WARNING_MSG("invalid probe type ~p, assuming counter", [Type]),
    $c.

%%====================================================================
%% Monitors helpers
%%====================================================================

process_queues(_Host, all) ->
    weight([queue(Pid, message_queue_len) || Pid <- processes()]);
process_queues(Host, Sup) ->
    weight([queue(Pid, message_queue_len) || Pid <- workers(Host, Sup)]).

internal_queues(Host, Sup) ->
    weight([queue(Pid, dictionary) || Pid <- workers(Host, Sup)]).

weight([]) -> 0;
weight(List) when is_list(List) ->
    {Sum, Max} = lists:foldl(
            fun(X, {S, M}) when is_integer(X) ->
                    if X>M -> {S+X, X};
                        true -> {S+X, M}
                    end;
                (_, Acc) ->
                    Acc
            end, {0, 0}, List),
    Avg = Sum div length(List),
    (Avg + Max) div 2.

queue(Pid, Attr) -> queue(erlang:process_info(Pid, Attr)).
queue({message_queue_len, I}) -> I;
queue({dictionary, D}) -> proplists:get_value('$internal_queue_len', D, 0);
queue(_) -> 0.

workers(Host, ejabberd_mod_pubsub_loop) ->
    [whereis(pubsub_send_pool_name(I, Host)) || I <- lists:seq(1,100)];
workers(Host, ejabberd_sql_sup) ->
    Sup = gen_mod:get_module_proc(Host, ejabberd_sql_sup),
    workers(Host, Sup);
workers(Host, mod_offline_pool) ->
    Sup = gen_mod:get_module_proc(Host, mod_offline_pool),
    workers(Host, Sup);
workers(Host, Sup) ->
    case catch supervisor:which_children(Sup) of
        {'EXIT', _} ->
            case whereis(gen_mod:get_module_proc(Host, Sup)) of
                undefined -> [];
                Pid -> [Pid]
            end;
        Workers ->
            [Pid || {_,Pid,_,_} <- Workers]
    end.

pubsub_send_pool_name(I, ServerHost) ->
    list_to_atom("ejabberd_mod_pubsub_loop_" ++ binary_to_list(ServerHost)
	++ "_" ++ integer_to_list(I)).

% Note: health_check must be called last from monitors list
%       as it uses gauges values as they are pushed
%       it can not check counters (as they are reset at that time)
health_check(Host) ->
    spawn(mod_mon_client, start, [Host]),
    HealthCfg = ejabberd_config:get_option({health, Host},
                               fun(V) when is_list(V) -> V end,
                               []),
    lists:foldr(fun({Component, Check}, Acc) ->
                lists:foldr(fun({Probe, Message, Critical}, Acc2) ->
                            Spec = case proplists:get_value(Probe, HealthCfg, []) of
                                L when is_list(L) -> L;
                                Other -> [Other]
                            end,
                            case level(Host, Probe, Spec) of
                                ok -> Acc2;
                                critical -> [{critical, Component, Critical}|Acc2];
                                Level -> [{Level, Component, Message}|Acc2]
                            end
                    end, Acc, Check)
            end, [],
        [{<<"REST API">>,
          [{backend_api_response_time, <<"slow responses">>, <<"no response">>},
           {backend_api_error, <<"error responses">>, <<"total failure">>},
           {backend_api_badauth, <<"logins with bad credentials">>, <<"auth flooding">>}]},
         {<<"Router">>,
          [{c2s_queues, <<"c2s processes overloaded">>, <<"c2s dead">>},
           {s2s_queues, <<"s2s processes overloaded">>, <<"s2s dead">>},
           {iq_queues, <<"iq handlers overloaded">>, <<"iq handlers dead">>},
           {sm_queues, <<"session managers overloaded">>, <<"sessions dead">>}]},
         {<<"Database">>,
          [{sql_queues, <<"sql driver overloaded">>, <<"service down">>},
           {offline_queues, <<"offline spool overloaded">>, <<"service down">>}]},
         {<<"Client">>,
          [{client_conn_time, <<"connection is slow">>, <<"service unavailable">>},
           {client_auth_time, <<"authentification is slow">>, <<"auth broken">>},
           {client_roster_time, <<"roster response is slow">>, <<"roster broken">>}]}]).

jabs_count(Host) ->
    case catch mod_jabs:value(Host) of
        {'EXIT', _} -> 0;
        undefined -> 0;
        {Count, _} -> Count
    end.

node_sessions_count(_Host) ->
    length(ejabberd_sm_mnesia:get_node_sessions(node())).

cpu_usage(_Host) ->
    Threads = erlang:system_info(schedulers),
    {_, Runtime} = erlang:statistics(runtime),
    % we assume cpu_usage is called only by push_metrics event
    % every minute, and we get this runtime delta for reference
    % ?MINUTE div 100
    Runtime div (600 * Threads).

%%====================================================================
%% Health check helpers
%%====================================================================

level(_Host, _Probe, []) ->
    ok;
level(Host, iq_queues, Spec) ->
    Value = value(Host, iq_message_queues)+value(Host, iq_internal_queues),
    check_level(ok, Value, Spec);
level(Host, sm_queues, Spec) ->
    Value = value(Host, sm_message_queues)+value(Host, sm_internal_queues),
    check_level(ok, Value, Spec);
level(Host, c2s_queues, Spec) ->
    Value = value(Host, c2s_message_queues)+value(Host, c2s_internal_queues),
    check_level(ok, Value, Spec);
level(Host, s2s_queues, Spec) ->
    Value = value(Host, s2s_message_queues)+value(Host, s2s_internal_queues),
    check_level(ok, Value, Spec);
level(Host, sql_queues, Spec) ->
    Value = value(Host, sql_message_queues)+value(Host, sql_internal_queues),
    check_level(ok, Value, Spec);
level(Host, offline_queues, Spec) ->
    Value = value(Host, offline_message_queues)+value(Host, offline_internal_queues),
    check_level(ok, Value, Spec);
level(Host, Probe, Spec) ->
    {_Type, Value} =  get_probe_value(Probe, value(Host, Probe)),
    check_level(ok, Value, Spec).

check_level(Acc, _, []) -> Acc;
check_level(Acc, Value, [{Level, gt, Limit}|Tail]) ->
    if Value > Limit -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, lt, Limit}|Tail]) ->
    if Value < Limit -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, in, Low, Up}|Tail]) ->
    if (Value >= Low) and (Value =< Up) -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, out, Low, Up}|Tail]) ->
    if (Value < Low) or (Value > Up) -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, eq, Limit}|Tail]) ->
    if Value == Limit -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [{Level, neq, Limit}|Tail]) ->
    if Value =/= Limit -> check_level(Level, Value, Tail);
        true -> check_level(Acc, Value, Tail)
    end;
check_level(Acc, Value, [Invalid|Tail]) ->
    ?WARNING_MSG("invalid health limit spec: ~p", [Invalid]),
    check_level(Acc, Value, Tail).

%%====================================================================
%% Temporary helper to get clear cluster view of most important probes
%%====================================================================

merge_sets([L]) -> L;
merge_sets([L1,L2]) -> merge_set(L1,L2);
merge_sets([L1,L2|Tail]) -> merge_sets([merge_set(L1,L2)|Tail]).
merge_set(L1, L2) ->
    lists:foldl(fun({K,V}, Acc) ->
                case proplists:get_value(K, Acc) of
                    undefined -> [{K,V}|Acc];
                    Old -> lists:keyreplace(K, 1, Acc, {K,Old+V})
                end
        end, L1, L2).

tab2set(Mons) when is_list(Mons) ->
    [{K,V} || {mon,K,V} <- Mons];
tab2set(_) ->
    [].

info(Host) when is_binary(Host) ->
    Table = gen_mod:get_module_proc(Host, mon),
    Probes = merge_sets([tab2set(rpc:call(Node, ets, tab2list, [Table])) || Node <- ejabberd_cluster:get_nodes()]),
    [{Key, Val} || {Key, Val} <- Probes,
                   lists:member(Key, [c2s_receive, c2s_send, s2s_receive, s2s_send])].

depends(_Host, _Opts) ->
    [].

mod_opt_type(hooks) ->
    fun (List) when is_list(List) -> List end;
mod_opt_type(monitors_base) ->
    fun (List) when is_list(List) -> List end;
mod_opt_type(backends) ->
    fun (List) when is_list(List) -> List end;
mod_opt_type(monitors) ->
    fun (L) when is_list(L) -> L end;
mod_opt_type(_) -> [hooks, monitors_base, backends, monitors].

opt_type(health) -> fun (V) when is_list(V) -> V end;
opt_type(_) -> [health].
