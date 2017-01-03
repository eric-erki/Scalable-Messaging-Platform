%%%----------------------------------------------------------------------
%%% File    : mod_support.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Support chat
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

-module(mod_support).

-compile([{parse_transform, ejabberd_sql_pt}]).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').
-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

-behaviour(gen_mod).

%% API
-export([start_link/2, start/2, stop/1, export/1, import_info/0,
	 unregister_room/4, store_room/5, restore_room/3,
	 forget_room/3, create_room/5, process_iq_disco_items/4,
	 broadcast_service_message/2, register_room/4,
	 get_vh_rooms/1, shutdown_rooms/1,
	 is_broadcasted/1, moderate_room_history/2, import/5,
	 persist_recent_messages/1, can_use_nick/4,
         add_history/7,
         get_history/4,
	 enc_key/1, dec_key/1, dec_key_ts/1,
         enc_hist/2, dec_hist/2,
         enc_aff/2, dec_aff/2,
         rh_prefix/2, key2us/2, rhus2key/4, import_start/2,
         get_commands_spec/0]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 depends/2, mod_opt_type/1, opt_type/1]).

-export([register_support_channel/3, register_support_agent/3]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("jlib.hrl").
-include("ejabberd_commands.hrl").
-include("ejabberd_sql_pt.hrl").

-record(support_room, {name_host = {<<"">>, <<"">>} :: {binary(), binary()} |
                                                   {'_', binary()},
                   opts = [] :: list() | '_'}).

-record(support_online_room,
        {name_host = {<<"">>, <<"">>} :: {binary(), binary()} | {'_', '$1'} | '$1' | '_',
         timestamp = p1_time_compat:timestamp() :: erlang:timestamp() | '_',
         pid = self() :: pid() | '$1' | '$2' | '_'}).

-record(support_registered,
        {us_host = {{<<"">>, <<"">>}, <<"">>} :: {{binary(), binary()}, binary()} | '$1',
         nick = <<"">> :: binary()}).

-record(state,
	{host = <<"">> :: binary(),
         server_host = <<"">> :: binary(),
         access = {none, none, none, none} :: {atom(), atom(), atom(), atom()},
         history_size = 20 :: non_neg_integer(),
	 persist_history = false :: boolean(),
         default_room_opts = [] :: list(),
         room_shaper = none :: shaper:shaper()}).

-define(PROCNAME, ejabberd_mod_support).

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE,
                           [Host, Opts], []).

start(Host, Opts) ->
    start_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 temporary, 1000, worker, [?MODULE]},
    ejabberd_commands:register_commands(get_commands_spec()),
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Rooms = shutdown_rooms(Host),
    stop_supervisor(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, stop),
    ejabberd_commands:unregister_commands(get_commands_spec()),
    supervisor:delete_child(ejabberd_sup, Proc),
    {wait, Rooms}.

get_commands_spec() ->
    [#ejabberd_commands{name = register_support_channel,
                        tags = [support],
                        desc = "Register new support channel on server",
                        module = ?MODULE, function = register_support_channel,
                        args = [{channel, binary}, {host, binary}, {owner_jid, binary}],
                        result = {res, restuple}},
     #ejabberd_commands{name = register_support_agent,
                        tags = [support],
                        desc = "Register new support agent for channel",
                        module = ?MODULE, function = register_support_agent,
                        args = [{jid, binary},{channel, binary}, {host, binary}],
                        result = {res, restuple}}].

shutdown_rooms(Host) ->
    MyHost = gen_mod:get_module_opt_host(Host, mod_support,
					 <<"support.@HOST@">>),
    lists:flatmap(
      fun(#support_online_room{pid = Pid}) ->
              if node(Pid) == node() ->
		      ejabberd_cluster:send(Pid, system_shutdown),
                      [Pid];
                 true ->
                      []
              end
      end, get_vh_rooms_all_nodes(MyHost)).

persist_recent_messages(Host) ->
    MyHost = gen_mod:get_module_opt_host(Host, mod_support,
					 <<"support.@HOST@">>),
    Rooms = get_vh_rooms_all_nodes(MyHost),
    lists:foldl(fun (#support_online_room{pid = Pid}, {NRooms, Messages}) ->
			case mod_support_room:persist_recent_messages(Pid) of
			  {ok, {persisted, N}} -> {NRooms + 1, Messages + N};
			  {ok, not_persistent} -> {NRooms, Messages}
			end
		end,
		{0, 0}, Rooms).

moderate_room_history(RoomStr, Nick) ->
    Room = jid:from_string(RoomStr),
    Name = Room#jid.luser,
    Host = Room#jid.lserver,
    case mnesia:dirty_read(support_online_room, {Name, Host}) of
      [] -> {error, not_found};
      [R] ->
	  Pid = R#support_online_room.pid,
	  mod_support_room:moderate_room_history(Pid, Nick)
    end.

create_room(Host, Name, From, Nick, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, {create, Name, From, Nick, Opts}).

store_room(ServerHost, Host, Name, Config, Affiliations) ->
    LServer = jid:nameprep(ServerHost),
    store_room(LServer, Host, Name, Config, Affiliations,
	       gen_mod:db_type(LServer, ?MODULE)).

store_room(_LServer, Host, Name, Config, Affiliations, mnesia) ->
    Opts = [{affiliations, Affiliations}|Config],
    F = fun () ->
		mnesia:write(#support_room{name_host = {Name, Host},
				       opts = Opts})
	end,
    mnesia:transaction(F);
store_room(_LServer, Host, Name, Config, _Affiliations, p1db) ->
    RoomKey = rh2key(Name, Host),
    CfgVal = term_to_binary(Config),
    case p1db:insert(support_config, RoomKey, CfgVal) of
        ok ->
            {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end;
store_room(_LServer, Host, Name, Config, Affiliations, riak) ->
    Opts = [{affiliations, Affiliations}|Config],
    {atomic, ejabberd_riak:put(#support_room{name_host = {Name, Host},
                                         opts = Opts},
			       support_room_schema())};
store_room(LServer, Host, Name, Config, Affiliations, sql) ->
    Opts = [{affiliations, Affiliations}|Config],
    SOpts = jlib:term_to_expr(Opts),
    F = fun () ->
		?SQL_UPSERT_T(
                   "support_room",
                   ["!name=%(Name)s",
                    "!host=%(Host)s",
                    "opts=%(SOpts)s"])
	end,
    ejabberd_sql:sql_transaction(LServer, F).

restore_room(ServerHost, Host, Name) ->
    LServer = jid:nameprep(ServerHost),
    restore_room(LServer, Host, Name,
                 gen_mod:db_type(LServer, ?MODULE)).

restore_room(_LServer, Host, Name, mnesia) ->
    case catch mnesia:dirty_read(support_room, {Name, Host}) of
      [#support_room{opts = Opts}] -> Opts;
      _ -> error
    end;
restore_room(_LServer, Host, Name, p1db) ->
    RoomKey = rh2key(Name, Host),
    case p1db:get(support_config, RoomKey) of
        {ok, CfgVal, _VClock} ->
            Config = binary_to_term(CfgVal),
            [{affiliations, []}|Config];
        {error, _} ->
            error
    end;
restore_room(_LServer, Host, Name, riak) ->
    case ejabberd_riak:get(support_room, support_room_schema(), {Name, Host}) of
        {ok, #support_room{opts = Opts}} -> Opts;
        _ -> error
    end;
restore_room(LServer, Host, Name, sql) ->
    case catch ejabberd_sql:sql_query(
                 LServer,
                 ?SQL("select @(opts)s from support_room where name=%(Name)s"
                      " and host=%(Host)s")) of
	{selected, [{Opts}]} ->
            opts_to_binary(ejabberd_sql:decode_term(Opts));
        _ -> error
    end.

forget_room(ServerHost, Host, Name) ->
    LServer = jid:nameprep(ServerHost),
    forget_room(LServer, Host, Name,
		gen_mod:db_type(LServer, ?MODULE)).

forget_room(_LServer, Host, Name, mnesia) ->
    F = fun () -> mnesia:delete({support_room, {Name, Host}})
	end,
    mnesia:transaction(F);
forget_room(_LServer, Host, Name, p1db) ->
    RoomKey = rh2key(Name, Host),
    DelRes = p1db:delete(support_config, RoomKey),
    if DelRes == ok; DelRes == {error, notfound} ->
            RHPrefix = rh_prefix(Name, Host),
            case p1db:get_by_prefix(support_affiliations, RHPrefix) of
                {ok, L} ->
                    lists:foreach(
                      fun({Key, _, _}) ->
                              p1db:async_delete(support_affiliations, Key)
                      end, L);
                {error, _} = Err ->
                    {aborted, Err}
            end;
       true ->
            {aborted, DelRes}
    end;
forget_room(_LServer, Host, Name, riak) ->
    {atomic, ejabberd_riak:delete(support_room, {Name, Host})};
forget_room(LServer, Host, Name, sql) ->
    F = fun () ->
		ejabberd_sql:sql_query_t(
                  ?SQL("delete from support_room where name=%(Name)s"
                       " and host=%(Host)s"))
	end,
    ejabberd_sql:sql_transaction(LServer, F).

process_iq_disco_items(Host, From, To,
		       #iq{lang = Lang} = IQ) ->
    Rsm = jlib:rsm_decode(IQ),
    Res = IQ#iq{type = result,
		sub_el =
		    [#xmlel{name = <<"query">>,
			    attrs = [{<<"xmlns">>, ?NS_DISCO_ITEMS}],
			    children = iq_disco_items(Host, From, Lang, Rsm)}]},
    ejabberd_router:route(To, From, jlib:iq_to_xml(Res)).

can_use_nick(_ServerHost, _Host, _JID, <<"">>) -> false;
can_use_nick(ServerHost, Host, JID, Nick) ->
    LServer = jid:nameprep(ServerHost),
    can_use_nick(LServer, Host, JID, Nick,
		 gen_mod:db_type(LServer, ?MODULE)).

can_use_nick(_LServer, Host, JID, Nick, mnesia) ->
    {LUser, LServer, _} = jid:tolower(JID),
    LUS = {LUser, LServer},
    case catch mnesia:dirty_select(support_registered,
				   [{#support_registered{us_host = '$1',
						     nick = Nick, _ = '_'},
				     [{'==', {element, 2, '$1'}, Host}],
				     ['$_']}])
	of
      {'EXIT', _Reason} -> true;
      [] -> true;
      [#support_registered{us_host = {U, _Host}}] -> U == LUS
    end;
can_use_nick(_LServer, Host, JID, Nick, p1db) ->
    {LUser, LServer, _} = jid:tolower(JID),
    NHKey = nh2key(Nick, Host),
    case p1db:get(support_nick, NHKey) of
        {ok, SJID, _VClock} ->
            case jid:from_string(SJID) of
                #jid{luser = LUser, lserver = LServer} ->
                    true;
                #jid{} ->
                    false;
                error ->
                    true
            end;
        {error, _} ->
            true
    end;
can_use_nick(LServer, Host, JID, Nick, riak) ->
    {LUser, LServer, _} = jid:tolower(JID),
    LUS = {LUser, LServer},
    case ejabberd_riak:get_by_index(support_registered,
				    support_registered_schema(),
                                    <<"nick_host">>, {Nick, Host}) of
        {ok, []} ->
            true;
        {ok, [#support_registered{us_host = {U, _Host}}]} ->
            U == LUS;
        {error, _} ->
            true
    end;
can_use_nick(LServer, Host, JID, Nick, sql) ->
    SJID = jid:to_string(jid:tolower(jid:remove_resource(JID))),
    case catch ejabberd_sql:sql_query(
                 LServer,
                 ?SQL("select @(jid)s from support_registered "
                      "where nick=%(Nick)s"
                      " and host=%(Host)s")) of
	{selected, [{SJID1}]} -> SJID == SJID1;
        _ -> true
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Opts]) ->
    MyHost = gen_mod:get_opt_host(Host, Opts,
				  <<"support.@HOST@">>),
    init_db(gen_mod:db_type(Host, Opts, ?MODULE), Host),
    update_support_online_table(),
    mnesia:create_table(support_online_room,
			[{ram_copies, [node()]}, {local_content, true},
			 {attributes, record_info(fields, support_online_room)}]),
    mnesia:add_table_copy(support_online_room, node(),
			  ram_copies),
    catch ets:new(support_online_users,
		  [bag, named_table, public, {keypos, 2}]),
    mnesia:subscribe(system),
    ejabberd_cluster:subscribe(),
    Access = gen_mod:get_opt(access, Opts,
                             fun acl:access_rules_validator/1, all),
    AccessCreate = gen_mod:get_opt(access_create, Opts,
                                   fun(A) when is_atom(A) -> A end, all),
    AccessAdmin = gen_mod:get_opt(access_admin, Opts,
                                  fun acl:access_rules_validator/1,
                                  none),
    AccessPersistent = gen_mod:get_opt(access_persistent, Opts,
				       fun acl:access_rules_validator/1,
                                       all),
    HistorySize = gen_mod:get_opt(history_size, Opts,
                                  fun(I) when is_integer(I), I>=0 -> I end,
                                  20),
    PersistHistory = gen_mod:get_opt(persist_history, Opts,
                                     fun(B) when is_boolean(B) -> B end,
                                     false),
    DefRoomOpts = gen_mod:get_opt(default_room_options, Opts,
                                  fun(L) when is_list(L) -> L end,
				  []),
    RoomShaper = gen_mod:get_opt(room_shaper, Opts,
                                 fun(A) when is_atom(A) -> A end,
                                 none),
    ejabberd_router:register_route(MyHost, Host),
    load_permanent_rooms(MyHost, Host,
			 {Access, AccessCreate, AccessAdmin, AccessPersistent},
			 HistorySize, PersistHistory, RoomShaper),
    {ok,
     #state{host = MyHost, server_host = Host,
	    access =
		{Access, AccessCreate, AccessAdmin, AccessPersistent},
	    default_room_opts = DefRoomOpts,
	    history_size = HistorySize,
	    persist_history = PersistHistory,
	    room_shaper = RoomShaper}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call({delete, RoomHost, Pid}, _From, State) ->
    Res = delete_room(RoomHost, Pid),
    {reply, Res, State};
handle_call({create, Room, From, Nick, Opts}, _From,
	    #state{host = Host, server_host = ServerHost,
		   access = Access, default_room_opts = DefOpts,
		   history_size = HistorySize,
		   persist_history = PersistHistory,
		   room_shaper = RoomShaper} =
		State) ->
    ?DEBUG("SUPPORT: create new room '~s'~n", [Room]),
    NewOpts = case Opts of
		default -> DefOpts;
		_ -> Opts
	      end,
    {ok, _Pid} = mod_support_room:start(Host, ServerHost, Access,
				   Room, HistorySize, PersistHistory,
				   RoomShaper, From, Nick, NewOpts),
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({route, From, To, Packet}, State) ->
    handle_info({route, From, To, Packet, []}, State);
handle_info({route, From, To, Packet, Hops},
	    #state{host = Host, server_host = ServerHost,
		   access = Access, default_room_opts = DefRoomOpts,
		   history_size = HistorySize,
		   persist_history = PersistHistory,
		   room_shaper = RoomShaper} =
		State) ->
    case catch do_route(Host, ServerHost, Access,
			HistorySize, PersistHistory, RoomShaper,
			From, To, Packet, DefRoomOpts, Hops) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]);
	_ ->
	    ok
    end,
    {noreply, State};
handle_info({write, R}, State) ->
    write_room(R),
    {noreply, State};
handle_info({delete, RoomHost, Pid}, State) ->
    delete_room(RoomHost, Pid),
    {noreply, State};
handle_info({node_up, Node}, State) ->
    Rs = ets:select(
	   support_online_room,
	   ets:fun2ms(
	     fun(#support_online_room{pid = Pid} = R)
		   when node(Pid) == node() ->
		     R
	     end)),
    Proc = gen_mod:get_module_proc(State#state.server_host, ?PROCNAME),
    lists:foreach(
      fun(R) ->
	      ejabberd_cluster:send({Proc, Node}, {write, R})
      end, Rs),
    {noreply, State};
handle_info({node_down, Node}, State) ->
    ets:select_delete(
      support_online_room,
      ets:fun2ms(
        fun(#support_online_room{pid = Pid})
              when node(Pid) == Node ->
                true
        end)),
    {noreply, State};
handle_info(_Info, State) ->
    ?ERROR_MSG("got unexpected info: ~p", [_Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    ejabberd_router:unregister_route(State#state.host),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

init_db(mnesia, _Host) ->
    mnesia:create_table(support_room,
                        [{disc_copies, [node()]},
                         {attributes, record_info(fields, support_room)}]),
    mnesia:create_table(support_registered,
                        [{disc_copies, [node()]},
                         {attributes,
                          record_info(fields, support_registered)}]),
    update_tables(),
    mnesia:add_table_index(support_registered, nick);
init_db(p1db, Host) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(support_config,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, room]},
                               {vals, mod_support_room:config_fields()},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun mod_support_room:encode_opts/2},
                               {dec_val, fun mod_support_room:decode_opts/2}]}]),
    p1db:open_table(support_history,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, room, server, user, timestamp]},
                               {vals, [jid, body]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key_ts/1},
                               {enc_val, fun ?MODULE:enc_hist/2},
                               {dec_val, fun ?MODULE:dec_hist/2}]}]),
    p1db:open_table(support_affiliations,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, room, server, user]},
                               {vals, [affiliation, reason]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_aff/2},
                               {dec_val, fun ?MODULE:dec_aff/2}]}]),
    p1db:open_table(support_nick,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, nick]},
                               {vals, [jid]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]),
    p1db:open_table(support_user,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, server, user]},
                               {vals, [nick]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]);
init_db(_, _) ->
    ok.

start_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host,
				   ejabberd_mod_support_sup),
    ChildSpec = {Proc,
		 {ejabberd_tmp_sup, start_link, [Proc, mod_support_room]},
		 permanent, infinity, supervisor, [ejabberd_tmp_sup]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop_supervisor(Host) ->
    Proc = gen_mod:get_module_proc(Host,
				   ejabberd_mod_support_sup),
    supervisor:terminate_child(ejabberd_sup, Proc),
    supervisor:delete_child(ejabberd_sup, Proc).

do_route(Host, ServerHost, Access, HistorySize,
	 PersistHistory, RoomShaper, From, To, Packet,
	 DefRoomOpts, Hops) ->
    {AccessRoute, _AccessCreate, _AccessAdmin,
     _AccessPersistent} =
	Access,
    case acl:match_rule(ServerHost, AccessRoute, From) of
      allow ->
	  do_route1(Host, ServerHost, Access, HistorySize,
		    PersistHistory, RoomShaper, From, To, Packet,
		    DefRoomOpts, Hops);
      _ ->
	  #xmlel{attrs = Attrs} = Packet,
	  Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
	  ErrText = <<"Access denied by service policy">>,
	  Err = jlib:make_error_reply(Packet,
				      ?ERRT_FORBIDDEN(Lang, ErrText)),
	  ejabberd_router:route_error(To, From, Err, Packet)
    end.

do_route1(Host, ServerHost, Access, HistorySize,
	  PersistHistory, RoomShaper, From, To, Packet,
	  DefRoomOpts, _Hops) ->
    {_AccessRoute, AccessCreate, AccessAdmin,
     _AccessPersistent} =
	Access,
    {Room, _, Nick} = jid:tolower(To),
    #xmlel{name = Name, attrs = Attrs} = Packet,
    case Room of
      <<"">> ->
	  case Nick of
	    <<"">> ->
		case Name of
		  <<"iq">> ->
		      case jlib:iq_query_info(Packet) of
			#iq{type = get, xmlns = (?NS_DISCO_INFO) = XMLNS,
			    sub_el = _SubEl, lang = Lang} =
			    IQ ->
			    Info = ejabberd_hooks:run_fold(disco_info,
							   ServerHost, [],
							   [ServerHost, ?MODULE,
							    <<"">>, <<"">>]),
			    Res = IQ#iq{type = result,
					sub_el =
					    [#xmlel{name = <<"query">>,
						    attrs =
							[{<<"xmlns">>, XMLNS}],
						    children =
							iq_disco_info(Lang) ++
							  Info}]},
			    ejabberd_router:route(To, From,
						  jlib:iq_to_xml(Res));
			#iq{type = get, xmlns = ?NS_DISCO_ITEMS} = IQ ->
			    spawn(?MODULE, process_iq_disco_items,
				  [Host, From, To, IQ]);
			#iq{type = get, xmlns = (?NS_REGISTER) = XMLNS,
			    lang = Lang, sub_el = _SubEl} =
			    IQ ->
			    Res = IQ#iq{type = result,
					sub_el =
					    [#xmlel{name = <<"query">>,
						    attrs =
							[{<<"xmlns">>, XMLNS}],
						    children =
							iq_get_register_info(ServerHost,
									     Host,
									     From,
									     Lang)}]},
			    ejabberd_router:route(To, From,
						  jlib:iq_to_xml(Res));
			#iq{type = set, xmlns = (?NS_REGISTER) = XMLNS,
			    lang = Lang, sub_el = SubEl} =
			    IQ ->
			    case process_iq_register_set(ServerHost, Host, From,
							 SubEl, Lang)
				of
			      {result, IQRes} ->
				  Res = IQ#iq{type = result,
					      sub_el =
						  [#xmlel{name = <<"query">>,
							  attrs =
							      [{<<"xmlns">>,
								XMLNS}],
							  children = IQRes}]},
				  ejabberd_router:route(To, From,
							jlib:iq_to_xml(Res));
			      {error, Error} ->
				  Err = jlib:make_error_reply(Packet, Error),
				  ejabberd_router:route(To, From, Err)
			    end;
			#iq{type = get, xmlns = (?NS_VCARD) = XMLNS,
			    lang = Lang, sub_el = _SubEl} =
			    IQ ->
			    Res = IQ#iq{type = result,
					sub_el =
					    [#xmlel{name = <<"vCard">>,
						    attrs =
							[{<<"xmlns">>, XMLNS}],
						    children =
							iq_get_vcard(Lang)}]},
			    ejabberd_router:route(To, From,
						  jlib:iq_to_xml(Res));
			#iq{} ->
			    Err = jlib:make_error_reply(Packet,
							?ERR_FEATURE_NOT_IMPLEMENTED),
			    ejabberd_router:route(To, From, Err);
			_ -> ok
		      end;
		  <<"message">> ->
		      case fxml:get_attr_s(<<"type">>, Attrs) of
			<<"error">> -> ok;
			_ ->
			    case acl:match_rule(ServerHost, AccessAdmin, From)
				of
			      allow ->
				  Msg = fxml:get_path_s(Packet,
						       [{elem, <<"body">>},
							cdata]),
				  broadcast_service_message(Host, Msg);
			      _ ->
				  Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
				  ErrText =
				      <<"Only service administrators are allowed "
					"to send service messages">>,
				  Err = jlib:make_error_reply(Packet,
							      ?ERRT_FORBIDDEN(Lang,
									      ErrText)),
				  ejabberd_router:route(To, From, Err)
			    end
		      end;
		  <<"presence">> -> ok
		end;
	    _ ->
		case fxml:get_attr_s(<<"type">>, Attrs) of
		  <<"error">> -> ok;
		  <<"result">> -> ok;
		  _ ->
		      Err = jlib:make_error_reply(Packet,
						  ?ERR_ITEM_NOT_FOUND),
		      ejabberd_router:route(To, From, Err)
		end
	  end;
      _ ->
	  case mnesia:dirty_read(support_online_room, {Room, Host}) of
	    [] ->
		Type = fxml:get_attr_s(<<"type">>, Attrs),
		case {Name, Type} of
		  {<<"presence">>, <<"">>} ->
		      case check_user_can_create_room(ServerHost,
						      AccessCreate, From, Room)
			  of
			true ->
			    case start_new_room(Host, ServerHost, Access, Room,
						HistorySize, PersistHistory,
						RoomShaper, From, Nick,
						DefRoomOpts)
				of
			      {ok, Pid} ->
				  mod_support_room:route(Pid, From, Nick, Packet),
				  ok;
			      _Err ->
				  Err = jlib:make_error_reply(Packet,
							      ?ERR_INTERNAL_SERVER_ERROR),
				  ejabberd_router:route(To, From, Err)
			    end;
			false ->
			    Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
			    ErrText =
				<<"Room creation is denied by service policy">>,
			    Err = jlib:make_error_reply(Packet,
							?ERRT_FORBIDDEN(Lang,
									ErrText)),
			    ejabberd_router:route(To, From, Err)
		      end;
		  _ ->
		      Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
		      ErrText = <<"Support room does not exist">>,
		      Err = jlib:make_error_reply(Packet,
						  ?ERRT_ITEM_NOT_FOUND(Lang,
								       ErrText)),
		      ejabberd_router:route(To, From, Err)
		end;
	    [R] ->
		Pid = R#support_online_room.pid,
		?DEBUG("SUPPORT: send to process ~p~n", [Pid]),
		mod_support_room:route(Pid, From, Nick, Packet),
		ok
	  end
    end.

check_user_can_create_room(ServerHost, AccessCreate,
			   From, RoomID) ->
    case acl:match_rule(ServerHost, AccessCreate, From) of
      allow ->
	  byte_size(RoomID) =<
	    gen_mod:get_module_opt(ServerHost, ?MODULE, max_room_id,
                                   fun(infinity) -> infinity;
                                      (I) when is_integer(I), I>0 -> I
                                   end, infinity);
      _ -> false
    end.

get_rooms(ServerHost, Host) ->
    LServer = jid:nameprep(ServerHost),
    get_rooms(LServer, Host,
              gen_mod:db_type(LServer, ?MODULE)).

get_rooms(_LServer, Host, mnesia) ->
    case catch mnesia:dirty_select(support_room,
				   [{#support_room{name_host = {'_', Host},
					       _ = '_'},
				     [], ['$_']}])
	of
      {'EXIT', Reason} -> ?ERROR_MSG("~p", [Reason]), [];
      Rs -> Rs
    end;
get_rooms(_LServer, Host, p1db) ->
    HPrefix = host_prefix(Host),
    case p1db:get_by_prefix(support_config, HPrefix) of
        {ok, CfgList} ->
            lists:map(
              fun({Key, CfgVal, _VClock}) ->
                      Room = key2room(HPrefix, Key),
                      Cfg = binary_to_term(CfgVal),
                      Opts = [{affiliations, []}|Cfg],
                      #support_room{name_host = {Room, Host},
                                opts = Opts}
              end, CfgList);
        {error, _} ->
            []
    end;
get_rooms(_LServer, Host, riak) ->
    case ejabberd_riak:get(support_room, support_room_schema()) of
        {ok, Rs} ->
            lists:filter(
              fun(#support_room{name_host = {_, H}}) ->
                      Host == H
              end, Rs);
        _Err ->
            []
    end;
get_rooms(LServer, Host, sql) ->
    case catch ejabberd_sql:sql_query(
                 LServer,
                 ?SQL("select @(name)s, @(opts)s from support_room"
                      " where host=%(Host)s")) of
	{selected, RoomOpts} ->
	    lists:map(
	      fun({Room, Opts}) ->
                      #support_room{name_host = {Room, Host},
                                    opts = opts_to_binary(
                                             ejabberd_sql:decode_term(Opts))}
              end,
              RoomOpts);
        Err ->
            ?ERROR_MSG("failed to get rooms: ~p", [Err]),
            []
    end.

load_permanent_rooms(Host, ServerHost, Access,
		     HistorySize, PersistHistory, RoomShaper) ->
    lists:foreach(
      fun(R) ->
	      {Room, Host} = R#support_room.name_host,
	      case get_room_state_if_broadcasted({Room, Host}) of
		  {ok, RoomState} ->
		      mod_support_room:start(normal_state, RoomState);
		  error ->
		      case mnesia:dirty_read(support_online_room, {Room, Host}) of
			  [] ->
			      {ok, _Pid} = mod_support_room:start(Host,
							      ServerHost,
							      Access,
							      Room,
							      HistorySize,
							      PersistHistory,
							      RoomShaper,
							      R#support_room.opts);
			  _ -> ok
		      end
	      end
      end,
      get_rooms(ServerHost, Host)).

start_new_room(Host, ServerHost, Access, Room,
	       HistorySize, PersistHistory, RoomShaper, From, Nick,
	       DefRoomOpts) ->
    case get_room_state_if_broadcasted({Room, Host}) of
      {ok, RoomState} ->
	  ?DEBUG("SUPPORT: restore room '~s' from other node~n",
		 [Room]),
	  mod_support_room:start(normal_state, RoomState);
      error ->
	  case restore_room(ServerHost, Host, Room) of
	    error ->
		?DEBUG("SUPPORT: open new room '~s'~n", [Room]),
		mod_support_room:start(Host, ServerHost, Access, Room,
				   HistorySize, PersistHistory, RoomShaper,
				   From, Nick, DefRoomOpts);
	    Opts ->
		?DEBUG("SUPPORT: restore room '~s'~n", [Room]),
		mod_support_room:start(Host, ServerHost, Access, Room,
				   HistorySize, PersistHistory, RoomShaper,
				   Opts)
	  end
    end.

register_room(ServerHost, Host, Room, Pid) ->
    R = #support_online_room{name_host = {Room, Host},
			 pid = Pid,
			 timestamp = p1_time_compat:timestamp()},
    Proc = gen_mod:get_module_proc(ServerHost, ?PROCNAME),
    lists:foreach(
      fun(Node) when Node == node() ->
	      write_room(R);
	 (Node) ->
	      ejabberd_cluster:send({Proc, Node}, {write, R})
      end, ejabberd_cluster:get_nodes()).

unregister_room(ServerHost, Host, Room, Pid) ->
    Proc = gen_mod:get_module_proc(ServerHost, ?PROCNAME),
    lists:foreach(
      fun(Node) ->
	      ejabberd_cluster:send({Proc, Node}, {delete, {Room, Host}, Pid})
      end, ejabberd_cluster:get_nodes()).

write_room(#support_online_room{pid = Pid1, timestamp = T1} = S1) ->
    case mnesia:dirty_read(support_online_room, S1#support_online_room.name_host) of
	[#support_online_room{pid = Pid2, timestamp = T2} = S2] ->
	    if Pid1 == Pid2 ->
		    mnesia:dirty_write(S1);
	       T1 < T2 ->
		    ejabberd_cluster:send(Pid2, replaced),
		    mnesia:dirty_write(S1);
	       true ->
		    ejabberd_cluster:send(Pid1, replaced),
		    mnesia:dirty_write(S2)
	    end;
	[] ->
	    mnesia:dirty_write(S1)
    end.

delete_room(RoomHost, Pid1) ->
    case mnesia:dirty_read(support_online_room, RoomHost) of
	[#support_online_room{pid = Pid2}] when Pid1 == Pid2 ->
	    mnesia:dirty_delete(support_online_room, RoomHost);
	_ ->
	    ok
    end.

iq_disco_info(Lang) ->
    [#xmlel{name = <<"identity">>,
	    attrs =
		[{<<"category">>, <<"conference">>},
		 {<<"type">>, <<"text">>},
		 {<<"name">>,
		  translate:translate(Lang, <<"Chatrooms">>)}],
	    children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_DISCO_INFO}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_DISCO_ITEMS}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_VCARD}], children = []}].

iq_disco_items(Host, From, Lang, none) ->
    lists:zf(fun (#support_online_room{name_host =
				       {Name, _Host},
				   pid = Pid}) ->
		     case catch gen_fsm:sync_send_all_state_event(Pid,
								  {get_disco_item,
								   From, Lang},
								  100)
			 of
		       {item, Desc} ->
			   flush(),
			   {true,
			    #xmlel{name = <<"item">>,
				   attrs =
				       [{<<"jid">>,
					 jid:to_string({Name, Host,
							     <<"">>})},
					{<<"name">>, Desc}],
				   children = []}};
		       _ -> false
		     end
	     end,
	     get_vh_rooms_all_nodes(Host));
iq_disco_items(Host, From, Lang, Rsm) ->
    {Rooms, RsmO} = get_vh_rooms(Host, Rsm),
    RsmOut = jlib:rsm_encode(RsmO),
    lists:zf(fun (#support_online_room{name_host =
				       {Name, _Host},
				   pid = Pid}) ->
		     case catch gen_fsm:sync_send_all_state_event(Pid,
								  {get_disco_item,
								   From, Lang},
								  100)
			 of
		       {item, Desc} ->
			   flush(),
			   {true,
			    #xmlel{name = <<"item">>,
				   attrs =
				       [{<<"jid">>,
					 jid:to_string({Name, Host,
							     <<"">>})},
					{<<"name">>, Desc}],
				   children = []}};
		       _ -> false
		     end
	     end,
	     Rooms)
      ++ RsmOut.

get_vh_rooms(Host,
	     #rsm_in{max = M, direction = Direction, id = I,
		     index = Index}) ->
    AllRooms = get_vh_rooms_all_nodes(Host),
    Count = erlang:length(AllRooms),
    L = get_vh_rooms_direction(Direction, I, Index,
			       AllRooms),
    L2 = if Index == undefined andalso
	      Direction == before ->
		lists:reverse(lists:sublist(lists:reverse(L), 1, M));
	    Index == undefined -> lists:sublist(L, 1, M);
	    Index > Count orelse Index < 0 -> [];
	    true -> lists:sublist(L, Index + 1, M)
	 end,
    if L2 == [] -> {L2, #rsm_out{count = Count}};
       true ->
	   H = hd(L2),
	   NewIndex = get_room_pos(H, AllRooms),
	   T = lists:last(L2),
	   {F, _} = H#support_online_room.name_host,
	   {Last, _} = T#support_online_room.name_host,
	   {L2,
	    #rsm_out{first = F, last = Last, count = Count,
		     index = NewIndex}}
    end.

get_vh_rooms_direction(_Direction, _I, Index, AllRooms)
    when Index =/= undefined ->
    AllRooms;
get_vh_rooms_direction(aft, I, _Index, AllRooms) ->
    {_Before, After} = lists:splitwith(fun
					 (#support_online_room{name_host =
							       {Na, _}}) ->
					     Na < I
				       end,
				       AllRooms),
    case After of
      [] -> [];
      [#support_online_room{name_host = {I, _Host}}
       | AfterTail] ->
	  AfterTail;
      _ -> After
    end;
get_vh_rooms_direction(before, I, _Index, AllRooms)
    when I =/= [] ->
    {Before, _} = lists:splitwith(fun
				    (#support_online_room{name_host = {Na, _}}) ->
					Na < I
				  end,
				  AllRooms),
    Before;
get_vh_rooms_direction(_Direction, _I, _Index,
		       AllRooms) ->
    AllRooms.

get_room_pos(Desired, Rooms) ->
    get_room_pos(Desired, Rooms, 0).

get_room_pos(Desired, [HeadRoom | _], HeadPosition)
    when Desired#support_online_room.name_host ==
	   HeadRoom#support_online_room.name_host ->
    HeadPosition;
get_room_pos(Desired, [_ | Rooms], HeadPosition) ->
    get_room_pos(Desired, Rooms, HeadPosition + 1).

flush() -> receive _ -> flush() after 0 -> ok end.

-define(XFIELD(Type, Label, Var, Val),
	#xmlel{name = <<"field">>,
	       attrs =
		   [{<<"type">>, Type},
		    {<<"label">>, translate:translate(Lang, Label)},
		    {<<"var">>, Var}],
	       children =
		   [#xmlel{name = <<"value">>, attrs = [],
			   children = [{xmlcdata, Val}]}]}).

iq_get_unique(From) ->
    {xmlcdata,
     p1_sha:sha(term_to_binary([From, p1_time_compat:timestamp(),
			     randoms:get_string()]))}.

get_nick(ServerHost, Host, From) ->
    LServer = jid:nameprep(ServerHost),
    get_nick(LServer, Host, From,
	     gen_mod:db_type(LServer, ?MODULE)).

get_nick(_LServer, Host, From, mnesia) ->
    {LUser, LServer, _} = jid:tolower(From),
    LUS = {LUser, LServer},
    case catch mnesia:dirty_read(support_registered,
				 {LUS, Host})
	of
      {'EXIT', _Reason} -> error;
      [] -> error;
      [#support_registered{nick = Nick}] -> Nick
    end;
get_nick(_LServer, Host, From, p1db) ->
    {LUser, LServer, _} = jid:tolower(From),
    USHKey = ush2key(LUser, LServer, Host),
    case p1db:get(support_user, USHKey) of
        {ok, Nick, _VClock} -> Nick;
        {error, _} -> error
    end;
get_nick(LServer, Host, From, riak) ->
    {LUser, LServer, _} = jid:tolower(From),
    US = {LUser, LServer},
    case ejabberd_riak:get(support_registered,
			   support_registered_schema(),
			   {US, Host}) of
        {ok, #support_registered{nick = Nick}} -> Nick;
        {error, _} -> error
    end;
get_nick(LServer, Host, From, sql) ->
    SJID = jid:to_string(jid:tolower(jid:remove_resource(From))),
    case catch ejabberd_sql:sql_query(
                 LServer,
                 ?SQL("select @(nick)s from support_registered where"
                      " jid=%(SJID)s and host=%(Host)s")) of
	{selected, [{Nick}]} -> Nick;
	_ -> error
    end.

iq_get_register_info(ServerHost, Host, From, Lang) ->
    {Nick, Registered} = case get_nick(ServerHost, Host,
				       From)
			     of
			   error -> {<<"">>, []};
			   N ->
			       {N,
				[#xmlel{name = <<"registered">>, attrs = [],
					children = []}]}
			 end,
    Registered ++
      [#xmlel{name = <<"instructions">>, attrs = [],
	      children =
		  [{xmlcdata,
		    translate:translate(Lang,
					<<"You need a client that supports x:data "
					  "to register the nickname">>)}]},
       #xmlel{name = <<"x">>,
	      attrs = [{<<"xmlns">>, ?NS_XDATA}],
	      children =
		  [#xmlel{name = <<"title">>, attrs = [],
			  children =
			      [{xmlcdata,
				<<(translate:translate(Lang,
						       <<"Nickname Registration at ">>))/binary,
				  Host/binary>>}]},
		   #xmlel{name = <<"instructions">>, attrs = [],
			  children =
			      [{xmlcdata,
				translate:translate(Lang,
						    <<"Enter nickname you want to register">>)}]},
		   ?XFIELD(<<"text-single">>, <<"Nickname">>, <<"nick">>,
			   Nick)]}].

set_nick(ServerHost, Host, From, Nick) ->
    LServer = jid:nameprep(ServerHost),
    set_nick(LServer, Host, From, Nick,
	     gen_mod:db_type(LServer, ?MODULE)).

set_nick(_LServer, Host, From, Nick, mnesia) ->
    {LUser, LServer, _} = jid:tolower(From),
    LUS = {LUser, LServer},
    F = fun () ->
		case Nick of
		  <<"">> ->
		      mnesia:delete({support_registered, {LUS, Host}}), ok;
		  _ ->
		      Allow = case mnesia:select(support_registered,
						 [{#support_registered{us_host =
								       '$1',
								   nick = Nick,
								   _ = '_'},
						   [{'==', {element, 2, '$1'},
						     Host}],
						   ['$_']}])
				  of
				[] -> true;
				[#support_registered{us_host = {U, _Host}}] ->
				    U == LUS
			      end,
		      if Allow ->
			     mnesia:write(#support_registered{us_host = {LUS, Host},
							  nick = Nick}),
			     ok;
			 true -> false
		      end
		end
	end,
    mnesia:transaction(F);
set_nick(_LServer, Host, From, <<"">>, p1db) ->
    {LUser, LServer, _} = jid:tolower(From),
    USHKey = ush2key(LUser, LServer, Host),
    case p1db:get(support_user, USHKey) of
        {ok, Nick, _VClock} ->
            NHKey = nh2key(Nick, Host),
            case p1db:delete(support_nick, NHKey) of
                ok ->
                    case p1db:delete(support_user, USHKey) of
                        ok -> {atomic, ok};
                        {error, notfound} -> {atomic, ok};
                        {error, _} = Err -> {aborted, Err}
                    end;
                {error, notfound} ->
                    {atomic, ok};
                {error, _} = Err ->
                    {aborted, Err}
            end;
	{error, notfound} ->
	    {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end;
set_nick(_LServer, Host, From, Nick, p1db) ->
    {LUser, LServer, _} = jid:tolower(From),
    NHKey = nh2key(Nick, Host),
    case can_use_nick(LServer, Host, From, Nick, p1db) of
        true ->
            case set_nick(LServer, Host, From, <<"">>, p1db) of
                {atomic, ok} ->
                    SJID = jid:to_string({LUser, LServer, <<"">>}),
                    case p1db:insert(support_nick, NHKey, SJID) of
                        ok ->
                            USHKey = ush2key(LUser, LServer, Host),
                            case p1db:insert(support_user, USHKey, Nick) of
                                ok ->
                                    {atomic, ok};
                                {error, _} = Err ->
                                    {aborted, Err}
                            end;
                        {error, _} = Err ->
                            {aborted, Err}
                    end;
                Aborted ->
                    Aborted
            end;
        false ->
            {atomic, false}
    end;
set_nick(LServer, Host, From, Nick, riak) ->
    {LUser, LServer, _} = jid:tolower(From),
    LUS = {LUser, LServer},
    {atomic,
     case Nick of
         <<"">> ->
             ejabberd_riak:delete(support_registered, {LUS, Host});
         _ ->
             Allow = case ejabberd_riak:get_by_index(
                            support_registered,
			    support_registered_schema(),
                            <<"nick_host">>, {Nick, Host}) of
                         {ok, []} ->
                             true;
                         {ok, [#support_registered{us_host = {U, _Host}}]} ->
                             U == LUS;
                         {error, _} ->
                             false
                     end,
             if Allow ->
                     ejabberd_riak:put(#support_registered{us_host = {LUS, Host},
                                                       nick = Nick},
				       support_registered_schema(),
                                       [{'2i', [{<<"nick_host">>,
                                                 {Nick, Host}}]}]);
                true ->
                     false
             end
     end};
set_nick(LServer, Host, From, Nick, sql) ->
    JID = jid:to_string(jid:tolower(jid:remove_resource(From))),
    F = fun () ->
		case Nick of
		    <<"">> ->
			ejabberd_sql:sql_query_t(
			  ?SQL("delete from support_registered where"
                               " jid=%(JID)s and host=%(Host)s")),
			ok;
		    _ ->
			Allow = case ejabberd_sql:sql_query_t(
				       ?SQL("select jid from support_registered"
                                            " where nick=%(Nick)s"
                                            " and host=%(Host)s")) of
				    {selected, [{J}]} -> J == JID;
				    _ -> true
				end,
			if Allow ->
				?SQL_UPSERT_T(
                                  "support_registered",
                                  ["!jid=%(JID)s",
                                   "!host=%(Host)s",
                                   "nick=%(Nick)s"]),
				ok;
			   true ->
				false
			end
		end
	end,
    ejabberd_sql:sql_transaction(LServer, F).

iq_set_register_info(ServerHost, Host, From, Nick,
		     Lang) ->
    case set_nick(ServerHost, Host, From, Nick) of
      {atomic, ok} -> {result, []};
      {atomic, false} ->
	  ErrText = <<"That nickname is registered by another "
		      "person">>,
	  {error, ?ERRT_CONFLICT(Lang, ErrText)};
      _ -> {error, ?ERR_INTERNAL_SERVER_ERROR}
    end.

process_iq_register_set(ServerHost, Host, From, SubEl,
			Lang) ->
    #xmlel{children = Els} = SubEl,
    case fxml:get_subtag(SubEl, <<"remove">>) of
      false ->
	  case fxml:remove_cdata(Els) of
	    [#xmlel{name = <<"x">>} = XEl] ->
		case {fxml:get_tag_attr_s(<<"xmlns">>, XEl),
		      fxml:get_tag_attr_s(<<"type">>, XEl)}
		    of
		  {?NS_XDATA, <<"cancel">>} -> {result, []};
		  {?NS_XDATA, <<"submit">>} ->
		      XData = jlib:parse_xdata_submit(XEl),
		      case XData of
			invalid -> {error, ?ERR_BAD_REQUEST};
			_ ->
			    case lists:keysearch(<<"nick">>, 1, XData) of
			      {value, {_, [Nick]}} when Nick /= <<"">> ->
				  iq_set_register_info(ServerHost, Host, From,
						       Nick, Lang);
			      _ ->
				  ErrText =
				      <<"You must fill in field \"Nickname\" "
					"in the form">>,
				  {error, ?ERRT_NOT_ACCEPTABLE(Lang, ErrText)}
			    end
		      end;
		  _ -> {error, ?ERR_BAD_REQUEST}
		end;
	    _ -> {error, ?ERR_BAD_REQUEST}
	  end;
      _ ->
	  iq_set_register_info(ServerHost, Host, From, <<"">>,
			       Lang)
    end.

iq_get_vcard(Lang) ->
    [#xmlel{name = <<"FN">>, attrs = [],
	    children = [{xmlcdata, <<"ejabberd/mod_support">>}]},
     #xmlel{name = <<"URL">>, attrs = [],
	    children = [{xmlcdata, ?EJABBERD_URI}]},
     #xmlel{name = <<"DESC">>, attrs = [],
	    children =
		[{xmlcdata,
		  <<(translate:translate(Lang,
					 <<"ejabberd SUPPORT module">>))/binary,
		    "\nCopyright (c) 2003-2014 ProcessOne">>}]}].

add_history(ServerHost, Room, Host, US, TS, Sender, Body) ->
    LServer = jid:nameprep(ServerHost),
    add_history(LServer, Room, Host, US, TS, Sender, Body,
                gen_mod:db_type(LServer, ?MODULE)).

add_history(_LServer, Room, Host, US, TS, Sender, Body, p1db) ->
    SSender = jid:to_string(Sender),
    {LUser, LServer} = US,
    Key = rhust2key(Room, Host, LUser, LServer, TS),
    Val = <<(size(SSender)):32, SSender/binary, Body/binary>>,
    p1db:insert(support_history, Key, Val).

get_history(ServerHost, Room, Host, US) ->
    LServer = jid:nameprep(ServerHost),
    get_history(LServer, Room, Host, US,
                gen_mod:db_type(LServer, ?MODULE)).

get_history(_LServer, Room, Host, US, p1db) ->
    {LUser, LServer} = US,
    Prefix = rhus_prefix(Room, Host, LUser, LServer),
    case p1db:get_by_prefix(support_history, Prefix) of
        {ok, L} ->
            lists:flatmap(
              fun({Key, Val, _VClock}) ->
                      TS = key2ts(Key),
                      <<Len:32, SJID:Len/binary, Body/binary>> = Val,
                      case jid:from_string(SJID) of
                          #jid{} = JID ->
                              [{TS, JID, Body}];
                          error ->
                              []
                      end
              end, L);
        _Err ->
            []
    end.

broadcast_service_message(Host, Msg) ->
    lists:foreach(fun (#support_online_room{pid = Pid}) ->
			  gen_fsm:send_all_state_event(Pid,
						       {service_message, Msg})
		  end,
		  get_vh_rooms_all_nodes(Host)).

get_vh_rooms_all_nodes(Host) ->
    Rooms = mnesia:dirty_select(
	      support_online_room,
	      ets:fun2ms(
		fun(#support_online_room{name_host = {_, H}, pid = Pid} = R)
		      when Host == H ->
			R
		end)),
    lists:ukeysort(#support_online_room.name_host, Rooms).

get_vh_rooms(Host) ->
    mnesia:dirty_select(
      support_online_room,
      ets:fun2ms(
        fun(#support_online_room{name_host = {_, H}, pid = Pid} = R)
              when Host == H, node(Pid) == node() ->
                R
        end)).

opts_to_binary(Opts) ->
    lists:map(
      fun({title, Title}) ->
              {title, iolist_to_binary(Title)};
         ({description, Desc}) ->
              {description, iolist_to_binary(Desc)};
         ({password, Pass}) ->
              {password, iolist_to_binary(Pass)};
         ({subject, Subj}) ->
              {subject, iolist_to_binary(Subj)};
         ({subject_author, Author}) ->
              {subject_author, iolist_to_binary(Author)};
         ({affiliations, Affs}) ->
              {affiliations, lists:map(
                               fun({{U, S, R}, Aff}) ->
                                       NewAff =
                                           case Aff of
                                               {A, Reason} ->
                                                   {A, iolist_to_binary(Reason)};
                                               _ ->
                                                   Aff
                                           end,
                                       {{iolist_to_binary(U),
                                         iolist_to_binary(S),
                                         iolist_to_binary(R)},
                                        NewAff}
                               end, Affs)};
         ({captcha_whitelist, CWList}) ->
              {captcha_whitelist, lists:map(
                                    fun({U, S, R}) ->
                                            {iolist_to_binary(U),
                                             iolist_to_binary(S),
                                             iolist_to_binary(R)}
                                    end, CWList)};
         (Opt) ->
              Opt
      end, Opts).

support_room_schema() ->
    {record_info(fields, support_room), #support_room{}}.

support_registered_schema() ->
    {record_info(fields, support_registered), #support_registered{}}.

update_tables() ->
    update_support_room_table(),
    update_support_registered_table().

update_support_online_table() ->
    case catch mnesia:table_info(support_online_room,
				 local_content)
	of
      false -> mnesia:delete_table(support_online_room);
      true ->
            case catch mnesia:table_info(support_online_room, attributes) of
                [name_host, pid] ->
                    mnesia:delete_table(support_online_room);
                [name_host, timestamp, pid] ->
                    ok;
                {'EXIT', _} ->
                    ok
            end;
      {'EXIT', _} ->
            ok
    end.

update_support_room_table() ->
    Fields = record_info(fields, support_room),
    case mnesia:table_info(support_room, attributes) of
      Fields ->
          ejabberd_config:convert_table_to_binary(
            support_room, Fields, set,
            fun(#support_room{name_host = {N, _}}) -> N end,
            fun(#support_room{name_host = {N, H},
                          opts = Opts} = R) ->
                    R#support_room{name_host = {iolist_to_binary(N),
                                            iolist_to_binary(H)},
                               opts = opts_to_binary(Opts)}
            end);
      _ ->
	  ?INFO_MSG("Recreating support_room table", []),
	  mnesia:transform_table(support_room, ignore, Fields)
    end.

update_support_registered_table() ->
    Fields = record_info(fields, support_registered),
    case mnesia:table_info(support_registered, attributes) of
      Fields ->
          ejabberd_config:convert_table_to_binary(
            support_registered, Fields, set,
            fun(#support_registered{us_host = {_, H}}) -> H end,
            fun(#support_registered{us_host = {{U, S}, H},
                                nick = Nick} = R) ->
                    R#support_registered{us_host = {{iolist_to_binary(U),
                                                 iolist_to_binary(S)},
                                                iolist_to_binary(H)},
                                     nick = iolist_to_binary(Nick)}
            end);
      _ ->
	  ?INFO_MSG("Recreating support_registered table", []),
	  mnesia:transform_table(support_registered, ignore, Fields)
    end.

is_broadcasted(RoomHost) ->
    case ejabberd_router:get_domain_balancing(RoomHost) of
        broadcast -> true;
        _ -> false
    end.

get_room_state_if_broadcasted({Room, Host}) ->
    case is_broadcasted(Host) of
	true ->
	    case mnesia:dirty_read(support_online_room, {Room, Host}) of
		[#support_online_room{pid = Pid}] ->
		    case catch gen_fsm:sync_send_all_state_event(Pid,
								 get_state,
								 5000) of
			{ok, StateData} ->
			    {ok, StateData};
			_ ->
			    error
		    end;
		[] ->
		    error
	    end;
	false ->
	    error
    end.

rh2key(Room, Host) ->
    <<Host/binary, 0, Room/binary>>.

nh2key(Nick, Host) ->
    <<Host/binary, 0, Nick/binary>>.

ush2key(LUser, LServer, Host) ->
    <<Host/binary, 0, LServer/binary, 0, LUser/binary>>.

host_prefix(Host) ->
    <<Host/binary, 0>>.

rh_prefix(Room, Host) ->
    <<Host/binary, 0, Room/binary, 0>>.

rhus_prefix(Room, Host, LUser, LServer) ->
    <<Host/binary, 0, Room/binary, 0, LServer/binary, 0, LUser/binary, 0>>.

rhus2key(Room, Host, LUser, LServer) ->
    <<Host/binary, 0, Room/binary, 0, LServer/binary, 0, LUser/binary>>.

rhust2key(Room, Host, LUser, LServer, TS) ->
    <<Host/binary, 0, Room/binary, 0, LServer/binary, 0, LUser/binary, 0,
     TS:64>>.

key2us(RHPrefix, Key) ->
    Size = size(RHPrefix),
    <<_:Size/binary, SKey/binary>> = Key,
    SLen = str:chr(SKey, 0) - 1,
    <<Server:SLen/binary, 0, User/binary>> = SKey,
    {User, Server}.

key2room(HPrefix, Key) ->
    Size = size(HPrefix),
    <<_:Size/binary, Room/binary>> = Key,
    Room.

key2ts(Key) ->
    Len = size(Key) - 9,
    {_Key1, Key2} = split_binary(Key, Len),
    <<0, TS:64>> = Key2,
    TS.

%% P1DB/SQL schema
enc_key([Host]) ->
    <<Host/binary>>;
enc_key([Host, Val]) ->
    <<Host/binary, 0, Val/binary>>;
enc_key([Host, Server, User]) ->
    <<Host/binary, 0, Server/binary, 0, User/binary>>;
enc_key([Host, Room, Server, User]) ->
    <<Host/binary, 0, Room/binary, 0, Server/binary, 0, User/binary>>;
enc_key([Host, Room, Server, User, TS]) ->
    <<Host/binary, 0, Room/binary, 0, Server/binary, 0, User/binary, 0, TS:64>>.

dec_key(Key) ->
    binary:split(Key, <<0>>, [global]).

dec_key_ts(Key) ->
    Len = size(Key) - 9,
    {Key1, Key2} = split_binary(Key, Len),
    <<0, TS:64>> = Key2,
    binary:split(Key1, <<0>>, [global]) ++ [TS].

enc_aff(_, [Affiliation, Reason]) ->
    term_to_binary([{affiliation, jlib:binary_to_atom(Affiliation)},
                    {reason, Reason}]).

dec_aff(_, Bin) ->
    PropList = binary_to_term(Bin),
    Affiliation = proplists:get_value(affiliation, PropList, none),
    Reason = proplists:get_value(reason, PropList, <<>>),
    [jlib:atom_to_binary(Affiliation), Reason].

enc_hist(_, [SJID, Body]) ->
    <<(size(SJID)):32, SJID/binary, Body/binary>>.

dec_hist(_, Bin) ->
    <<Len:32, SJID:Len/binary, Body/binary>> = Bin,
    [SJID, Body].

export(_Server) ->
    [{support_room,
      fun(Host, #support_room{name_host = {Name, RoomHost}, opts = Opts}) ->
              case str:suffix(Host, RoomHost) of
                  true ->
                      SOpts = jlib:term_to_expr(Opts),
                      [?SQL("delete from support_room where name=%(Name)s"
                            " and host=%(RoomHost)s;"),
                       ?SQL("insert into support_room(name, host, opts) "
                            "values ("
                            "%(Name)s, %(RoomHost)s, %(SOpts)s);")];
                  false ->
                      []
              end
      end},
     {support_registered,
      fun(Host, #support_registered{us_host = {{U, S}, RoomHost},
                                nick = Nick}) ->
              case str:suffix(Host, RoomHost) of
                  true ->
                      SJID = jid:to_string(jid:make(U, S, <<"">>)),
                      [?SQL("delete from support_registered where"
                            " jid=%(SJID)s and host=%(RoomHost)s;"),
                       ?SQL("insert into support_registered(jid, host, "
                            "nick) values ("
                            "%(SJID)s, %(RoomHost)s, %(Nick)s);")];
                  false ->
                      []
              end
      end}].

import_info() ->
    [{<<"support_room">>, 4}, {<<"support_registered">>, 4}].

import_start(LServer, DBType) ->
    init_db(DBType, LServer).

import(_LServer, {sql, _}, mnesia, <<"support_room">>,
       [Name, RoomHost, SOpts, _TimeStamp]) ->
    Opts = opts_to_binary(ejabberd_sql:decode_term(SOpts)),
    mnesia:dirty_write(
      #support_room{name_host = {Name, RoomHost},
                opts = Opts});
import(_LServer, {sql, _}, mnesia, <<"support_registered">>,
       [J, RoomHost, Nick, _TimeStamp]) ->
    #jid{user = U, server = S} = jid:from_string(J),
    mnesia:dirty_write(
      #support_registered{us_host = {{U, S}, RoomHost},
                      nick = Nick});
import(_LServer, {sql, _}, riak, <<"support_room">>,
       [Name, RoomHost, SOpts, _TimeStamp]) ->
    Opts = opts_to_binary(ejabberd_sql:decode_term(SOpts)),
    ejabberd_riak:put(
      #support_room{name_host = {Name, RoomHost}, opts = Opts},
      support_room_schema());
import(_LServer, {sql, _}, riak, <<"support_registered">>,
       [J, RoomHost, Nick, _TimeStamp]) ->
    #jid{user = U, server = S} = jid:from_string(J),
    R = #support_registered{us_host = {{U, S}, RoomHost}, nick = Nick},
    ejabberd_riak:put(R, support_registered_schema(),
		      [{'2i', [{<<"nick_host">>, {Nick, RoomHost}}]}]);
import(_LServer, {sql, _}, p1db, <<"support_room">>,
       [Room, Host, SOpts, _TimeStamp]) ->
    Opts = opts_to_binary(ejabberd_sql:decode_term(SOpts)),
    {Affiliations, Config} = lists:partition(
                               fun({affiliations, _}) -> true;
                                  (_) -> false
                               end, Opts),
    RHKey = rh2key(Room, Host),
    p1db:async_insert(support_config, RHKey, term_to_binary(Config)),
    lists:foreach(
      fun({affiliations, Affs}) ->
              lists:foreach(
                fun({JID, Aff}) ->
                        {Affiliation, Reason} = case Aff of
                                                    {A, R} -> {A, R};
                                                    A -> {A, <<"">>}
                                                end,
                        {LUser, LServer, _} = jid:tolower(JID),
                        RHUSKey = rhus2key(Room, Host, LUser, LServer),
                        Val = term_to_binary([{affiliation, Affiliation},
                                              {reason, Reason}]),
                        p1db:async_insert(support_affiliations, RHUSKey, Val)
                end, Affs)
      end, Affiliations);
import(_LServer, {sql, _}, p1db, <<"support_registered">>,
       [J, Host, Nick, _TimeStamp]) ->
    #jid{user = U, server = S} = jid:from_string(J),
    NHKey = nh2key(Nick, Host),
    USHKey = ush2key(U, S, Host),
    SJID = jid:to_string({U, S, <<"">>}),
    p1db:async_insert(support_nick, NHKey, SJID),
    p1db:async_insert(support_user, USHKey, Nick);
import(_LServer, {sql, _}, sql, _, _) ->
    ok.

register_support_channel(Channel, Host, AdminJid) ->
    case create_room(Host, Channel, jid:from_string(AdminJid),
                     <<"admin">>, [{persistent, true}]) of
        _ -> {ok, <<"">>}
    end.
register_support_agent(Jid, Channel, Host) ->
    MyHost = gen_mod:get_module_opt_host(Host, mod_support,
					 <<"support.@HOST@">>),
    case mnesia:dirty_read(support_online_room, {Channel, MyHost}) of
      [] -> {error, <<"Support room not found">>};
      [R] ->
	  Pid = R#support_online_room.pid,
            gen_fsm:send_all_state_event(Pid,
                                         {set_affiliation, jid:from_string(Jid), member}),
            {ok, <<"">>}
    end.

depends(_Host, _Opts) ->
    [].

mod_opt_type(access) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(access_admin) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(access_create) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(access_persistent) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(db_type) -> fun(p1db) -> p1db end;
mod_opt_type(default_room_options) ->
    fun (L) when is_list(L) -> L end;
mod_opt_type(hibernate_timeout) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(history_size) ->
    fun (I) when is_integer(I), I >= 0 -> I end;
mod_opt_type(host) -> fun iolist_to_binary/1;
mod_opt_type(max_room_desc) ->
    fun (infinity) -> infinity;
	(I) when is_integer(I), I > 0 -> I
    end;
mod_opt_type(max_room_id) ->
    fun (infinity) -> infinity;
	(I) when is_integer(I), I > 0 -> I
    end;
mod_opt_type(max_room_name) ->
    fun (infinity) -> infinity;
	(I) when is_integer(I), I > 0 -> I
    end;
mod_opt_type(max_user_conferences) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(max_users) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(max_users_admin_threshold) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(min_message_interval) ->
    fun (I) when is_integer(I), I >= 0 -> I end;
mod_opt_type(min_presence_interval) ->
    fun (I) when is_integer(I), I >= 0 -> I end;
mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(persist_history) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(room_shaper) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(user_message_shaper) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(user_presence_shaper) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(_) ->
    [access, access_admin, access_create, access_persistent,
     db_type, default_room_options, hibernate_timeout,
     history_size, host, max_room_desc, max_room_id,
     max_room_name, max_user_conferences, max_users,
     max_users_admin_threshold, min_message_interval,
     min_presence_interval, p1db_group, persist_history,
     room_shaper, user_message_shaper, user_presence_shaper].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
