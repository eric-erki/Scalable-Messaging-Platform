%%%----------------------------------------------------------------------
%%% File    : mod_muc.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : MUC support (XEP-0045)
%%% Created : 19 Mar 2003 by Alexey Shchepin <alexey@process-one.net>
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

-module(mod_muc).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-protocol({xep, 45, '1.25'}).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

-behaviour(gen_mod).

%% API
-export([start_link/2,
	 start/2,
	 stop/1,
	 store_room/5,
	 restore_room/3,
	 forget_room/3,
	 create_room/5,
	 shutdown_rooms/1,
	 process_iq_disco_items/4,
	 broadcast_service_message/2,
	 export/1,
	 import/5,
	 import_start/2,
	 can_use_nick/4,
	 register_room/4,
	 import_info/0,
	 unregister_room/4,
	 get_vh_rooms/1,
	 is_broadcasted/1,
	 moderate_room_history/2,
	 persist_recent_messages/1,
         opts_to_binary/1]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1, opt_type/1, depends/2]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include("jlib.hrl").
-include("mod_muc.hrl").

-record(state,
	{host = <<"">> :: binary(),
         server_host = <<"">> :: binary(),
         access = {none, none, none, none} :: {atom(), atom(), atom(), atom()},
         history_size = 20 :: non_neg_integer(),
	 persist_history = false :: boolean(),
         default_room_opts = [] :: list(),
         room_shaper = none :: shaper:shaper()}).

-define(PROCNAME, ejabberd_mod_muc).

-type muc_room_opts() :: [{atom(), any()}].
-callback init(binary(), gen_mod:opts()) -> any().
-callback import(binary(), binary(), [binary()]) -> ok.
-callback store_room(binary(), binary(), binary(), list()) -> {atomic, any()}.
-callback restore_room(binary(), binary(), binary()) -> muc_room_opts() | error.
-callback forget_room(binary(), binary(), binary()) -> {atomic, any()}.
-callback can_use_nick(binary(), binary(), jid(), binary()) -> boolean().
-callback get_rooms(binary(), binary()) -> [#muc_room{}].
-callback get_nick(binary(), binary(), jid()) -> binary() | error.
-callback set_nick(binary(), binary(), jid(), binary()) -> {atomic, ok | false}.

%%====================================================================
%% API
%%====================================================================
start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE,
			  [Host, Opts], []).

start(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ChildSpec = {Proc, {?MODULE, start_link, [Host, Opts]},
		 transient, 1000, worker, [?MODULE]},
    supervisor:start_child(ejabberd_sup, ChildSpec).

stop(Host) ->
    Rooms = shutdown_rooms(Host),
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, stop),
    supervisor:delete_child(ejabberd_sup, Proc),
    {wait, Rooms}.

depends(_Host, _Opts) ->
    [{mod_mam, soft}].

shutdown_rooms(Host) ->
    MyHost = gen_mod:get_module_opt_host(Host, mod_muc,
					 <<"conference.@HOST@">>),
    lists:flatmap(
	fun(#muc_online_room{pid = Pid}) ->
		if node(Pid) == node() ->
			ejabberd_cluster:send(Pid, system_shutdown),
			[Pid];
		    true ->
			[]
		end
	end, get_vh_rooms_all_nodes(MyHost)).

persist_recent_messages(Host) ->
    MyHost = gen_mod:get_module_opt_host(Host, mod_muc,
					 <<"conference.@HOST@">>),
    Rooms = get_vh_rooms_all_nodes(MyHost),
    lists:foldl(fun (#muc_online_room{pid = Pid}, {NRooms, Messages}) ->
			case mod_muc_room:persist_recent_messages(Pid) of
			  {ok, {persisted, N}} -> {NRooms + 1, Messages + N};
			  {ok, not_persistent} -> {NRooms, Messages}
			end
		end,
		{0, 0}, Rooms).

moderate_room_history(RoomStr, Nick) ->
    Room = jid:from_string(RoomStr),
    Name = Room#jid.luser,
    Host = Room#jid.lserver,
    case mnesia:dirty_read(muc_online_room, {Name, Host}) of
      [] -> {error, not_found};
      [R] ->
	  Pid = R#muc_online_room.pid,
	  mod_muc_room:moderate_room_history(Pid, Nick)
    end.

%% @doc Create a room.
%% If Opts = default, the default room options are used.
%% Else use the passed options as defined in mod_muc_room.
create_room(Host, Name, From, Nick, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:call(Proc, {create, Name, From, Nick, Opts}).

store_room(ServerHost, Host, Name, Config, Affiliations) ->
    LServer = jid:nameprep(ServerHost),
    Opts = [{affiliations, Affiliations}|Config],
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:store_room(LServer, Host, Name, Opts).

restore_room(ServerHost, Host, Name) ->
    LServer = jid:nameprep(ServerHost),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:restore_room(LServer, Host, Name).

forget_room(ServerHost, Host, Name) ->
    LServer = jid:nameprep(ServerHost),
    ejabberd_hooks:run(remove_room, LServer, [LServer, Name, Host]),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:forget_room(LServer, Host, Name).

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
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:can_use_nick(LServer, Host, JID, Nick).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Opts]) ->
    MyHost = gen_mod:get_opt_host(Host, Opts,
				  <<"conference.@HOST@">>),
    update_muc_online_table(),
    Mod = gen_mod:db_mod(Host, Opts, ?MODULE),
    Mod:init(Host, [{host, MyHost}|Opts]),
    mnesia:create_table(muc_online_room,
			[{ram_copies, [node()]}, {local_content, true},
			 {attributes, record_info(fields, muc_online_room)}]),
    mnesia:add_table_copy(muc_online_room, node(),
			  ram_copies),
    catch ets:new(muc_online_users,
		  [bag, named_table, public, {keypos, 2}]),
    mnesia:subscribe(system),
    ejabberd_cluster:subscribe(),
    Access = gen_mod:get_opt(access, Opts,
                             fun acl:access_rules_validator/1, all),
    AccessCreate = gen_mod:get_opt(access_create, Opts,
                                   fun acl:access_rules_validator/1, all),
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
    DefRoomOpts1 = gen_mod:get_opt(default_room_options, Opts,
				   fun(L) when is_list(L) -> L end,
				   []),
    DefRoomOpts =
	lists:flatmap(
	  fun({Opt, Val}) ->
		  Bool = fun(B) when is_boolean(B) -> B end,
		  VFun = case Opt of
			     allow_change_subj -> Bool;
			     allow_private_messages -> Bool;
			     allow_query_users -> Bool;
			     allow_user_invites -> Bool;
			     allow_visitor_nickchange -> Bool;
			     allow_visitor_status -> Bool;
			     anonymous -> Bool;
			     captcha_protected -> Bool;
			     logging -> Bool;
			     members_by_default -> Bool;
			     members_only -> Bool;
			     moderated -> Bool;
			     password_protected -> Bool;
			     persistent -> Bool;
			     public -> Bool;
			     public_list -> Bool;
			     mam -> Bool;
			     allow_subscription -> Bool;
			     password -> fun iolist_to_binary/1;
			     title -> fun iolist_to_binary/1;
			     allow_private_messages_from_visitors ->
				 fun(anyone) -> anyone;
				    (moderators) -> moderators;
				    (nobody) -> nobody
				 end;
			     max_users ->
				 fun(I) when is_integer(I), I > 0 -> I end;
                             presence_broadcast ->
                                 fun(L) ->
                                         lists:map(
                                           fun(moderator) -> moderator;
                                              (participant) -> participant;
                                              (visitor) -> visitor
                                           end, L)
                                 end;
			     _ ->
				 ?ERROR_MSG("unknown option ~p with value ~p",
					    [Opt, Val]),
				 fun(_) -> undefined end
			 end,
		  case gen_mod:get_opt(Opt, [{Opt, Val}], VFun) of
		      undefined -> [];
		      NewVal -> [{Opt, NewVal}]
		  end
	  end, DefRoomOpts1),
    RoomShaper = gen_mod:get_opt(room_shaper, Opts,
                                 fun acl:shaper_rules_validator/1,
                                 none),
    ejabberd_router:register_route(MyHost, Host),
    load_permanent_rooms(MyHost, Host,
			 {Access, AccessCreate, AccessAdmin, AccessPersistent},
			 HistorySize, PersistHistory, RoomShaper),
    {ok, #state{host = MyHost,
		server_host = Host,
		access = {Access, AccessCreate, AccessAdmin, AccessPersistent},
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
		   room_shaper = RoomShaper} = State) ->
    ?DEBUG("MUC: create new room '~s'~n", [Room]),
    NewOpts = case Opts of
		default -> DefOpts;
		_ -> Opts
	      end,
    {ok, _Pid} = mod_muc_room:start(
		  Host, ServerHost, Access,
		  Room, HistorySize, PersistHistory,
		  RoomShaper, From,
		  Nick, NewOpts),
    {reply, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({route, From, To, Packet}, State) ->
    handle_info({route, From, To, Packet, []}, State);
handle_info({route, From, To, Packet, Hops},
	    #state{host = Host, server_host = ServerHost,
		   access = Access, default_room_opts = DefRoomOpts,
		   history_size = HistorySize,
		   persist_history = PersistHistory,
		   room_shaper = RoomShaper} = State) ->
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
	   muc_online_room,
	   ets:fun2ms(
	     fun(#muc_online_room{pid = Pid} = R)
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
      muc_online_room,
      ets:fun2ms(
        fun(#muc_online_room{pid = Pid})
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

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------
do_route(Host, ServerHost, Access, HistorySize,
	 PersistHistory, RoomShaper, From, To, Packet,
	 DefRoomOpts, Hops) ->
    {AccessRoute, _AccessCreate, _AccessAdmin, _AccessPersistent} = Access,
    case acl:match_rule(ServerHost, AccessRoute, From) of
	allow ->
	    do_route1(Host, ServerHost, Access, HistorySize,
		PersistHistory, RoomShaper,
		From, To, Packet, DefRoomOpts, Hops);
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
    {_AccessRoute, AccessCreate, AccessAdmin, _AccessPersistent} = Access,
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
							iq_disco_info(
							  ServerHost, Lang) ++
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
			#iq{type = get, xmlns = ?NS_MUCSUB,
			    sub_el = #xmlel{name = <<"subscriptions">>} = SubEl} = IQ ->
			      RoomJIDs = get_subscribed_rooms(ServerHost, Host, From),
			      Subs = lists:map(
				       fun(J) ->
					       #xmlel{name = <<"subscription">>,
						      attrs = [{<<"jid">>,
								jid:to_string(J)}]}
				       end, RoomJIDs),
			      Res = IQ#iq{type = result,
					  sub_el = [SubEl#xmlel{children = Subs}]},
			      ejabberd_router:route(To, From, jlib:iq_to_xml(Res));
			#iq{type = get, xmlns = ?NS_MUC_UNIQUE} = IQ ->
			    Res = IQ#iq{type = result,
					sub_el =
					    [#xmlel{name = <<"unique">>,
						    attrs =
							[{<<"xmlns">>,
							  ?NS_MUC_UNIQUE}],
						    children =
							[iq_get_unique(From)]}]},
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
	    case mnesia:dirty_read(muc_online_room, {Room, Host}) of
		[] ->
		    case is_create_request(Packet) of
			true ->
			    case check_user_can_create_room(ServerHost,
				    AccessCreate, From, Room) and
				check_create_roomid(ServerHost, Room) of
				true ->
				    case start_new_room(Host, ServerHost, Access,
					    Room, HistorySize, PersistHistory,
					    RoomShaper, From, Nick, DefRoomOpts)
				    of
					{ok, Pid} ->
					    mod_muc_room:route(Pid, From, Nick, Packet),
					    ok;
					_Err ->
					    Err = jlib:make_error_reply(Packet,
						    ?ERR_INTERNAL_SERVER_ERROR),
					    ejabberd_router:route(To, From, Err)
				    end;
				false ->
				    Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
				    ErrText = <<"Room creation is denied by service policy">>,
				    Err = jlib:make_error_reply(
					    Packet, ?ERRT_FORBIDDEN(Lang, ErrText)),
				    ejabberd_router:route(To, From, Err)
			    end;
			false ->
			    Lang = fxml:get_attr_s(<<"xml:lang">>, Attrs),
			    ErrText = <<"Conference room does not exist">>,
			    Err = jlib:make_error_reply(Packet,
				    ?ERRT_ITEM_NOT_FOUND(Lang, ErrText)),
			    ejabberd_router:route(To, From, Err)
		    end;
		[R] ->
		    Pid = R#muc_online_room.pid,
		    ?DEBUG("MUC: send to process ~p~n", [Pid]),
		    mod_muc_room:route(Pid, From, Nick, Packet),
		    ok
	    end
    end.

-spec is_create_request(xmlel()) -> boolean().
is_create_request(#xmlel{name = <<"presence">>} = Packet) ->
    <<"">> == fxml:get_tag_attr_s(<<"type">>, Packet);
is_create_request(#xmlel{name = <<"iq">>} = Packet) ->
    case jlib:iq_query_info(Packet) of
	#iq{type = set, xmlns = ?NS_MUCSUB,
	    sub_el = #xmlel{name = <<"subscribe">>}} ->
	    true;
	#iq{type = get, xmlns = ?NS_MUC_OWNER, sub_el = SubEl} ->
	    [] == fxml:remove_cdata(SubEl#xmlel.children);
	_ ->
	    false
    end;
is_create_request(_) ->
    false.

check_user_can_create_room(ServerHost, AccessCreate,
			   From, _RoomID) ->
    case acl:match_rule(ServerHost, AccessCreate, From) of
      allow -> true;
      _ -> false
    end.

check_create_roomid(ServerHost, RoomID) ->
    Max = gen_mod:get_module_opt(ServerHost, ?MODULE, max_room_id,
				 fun(infinity) -> infinity;
				    (I) when is_integer(I), I>0 -> I
				 end, infinity),
    Regexp = gen_mod:get_module_opt(ServerHost, ?MODULE, regexp_room_id,
				    fun iolist_to_binary/1, ""),
    (byte_size(RoomID) =< Max) and
    (re:run(RoomID, Regexp, [unicode, {capture, none}]) == match).

get_rooms(ServerHost, Host) ->
    LServer = jid:nameprep(ServerHost),
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:get_rooms(LServer, Host).

load_permanent_rooms(Host, ServerHost, Access,
		     HistorySize, PersistHistory, RoomShaper) ->
    case gen_mod:get_module_opt(ServerHost,
				?MODULE, preload_rooms,
				fun(B) when is_boolean(B) -> B end,
				true) of
	true ->
	    lists:foreach(
	      fun(R) ->
		      {Room, Host} = R#muc_room.name_host,
		      case get_room_state_if_broadcasted({Room, Host}) of
			  {ok, RoomState} ->
			      mod_muc_room:start(normal_state, RoomState);
			  error ->
			      case mnesia:dirty_read(muc_online_room, {Room, Host}) of
				  [] ->
				      {ok, _Pid} = mod_muc_room:start(
						     Host,
						     ServerHost, Access, Room,
						     HistorySize, PersistHistory, RoomShaper,
						     R#muc_room.opts);
				  _ -> ok
			      end
		      end
	      end,
	      get_rooms(ServerHost, Host));
	false ->
	    ok
    end.

start_new_room(Host, ServerHost, Access, Room,
	    HistorySize, PersistHistory, RoomShaper, From,
	    Nick, DefRoomOpts) ->
    case get_room_state_if_broadcasted({Room, Host}) of
	{ok, RoomState} ->
	    ?DEBUG("MUC: restore room '~s' from other node~n", [Room]),
	    mod_muc_room:start(normal_state, RoomState);
	error ->
	    case restore_room(ServerHost, Host, Room) of
		error ->
		    ?DEBUG("MUC: open new room '~s'~n", [Room]),
		    mod_muc_room:start(Host, ServerHost, Access, Room,
			HistorySize, PersistHistory, RoomShaper,
			From, Nick, DefRoomOpts);
		Opts ->
		    ?DEBUG("MUC: restore room '~s'~n", [Room]),
		    mod_muc_room:start(Host, ServerHost, Access, Room,
			HistorySize, PersistHistory, RoomShaper, Opts)
	    end
    end.

register_room(ServerHost, Host, Room, Pid) ->
    R = #muc_online_room{name_host = {Room, Host},
			 pid = Pid,
			 timestamp = p1_time_compat:timestamp()},
    Proc = gen_mod:get_module_proc(ServerHost, ?PROCNAME),
    lists:foreach(
      fun(Node) when Node == node() ->
	      ejabberd_hooks:run(create_room, ServerHost, [ServerHost, Room, Host]),
	      write_room(R);
	 (Node) ->
	      ejabberd_cluster:send({Proc, Node}, {write, R})
      end, ejabberd_cluster:get_nodes()).

unregister_room(ServerHost, Host, Room, Pid) ->
    Proc = gen_mod:get_module_proc(ServerHost, ?PROCNAME),
    lists:foreach(
      fun(Node) when Node == node() ->
	      ejabberd_hooks:run(destroy_room, ServerHost, [ServerHost, Room, Host]),
	      delete_room({Room, Host}, Pid);
	 (Node) ->
	      ejabberd_cluster:send({Proc, Node}, {delete, {Room, Host}, Pid})
      end, ejabberd_cluster:get_nodes()).

write_room(#muc_online_room{pid = Pid1, timestamp = T1} = S1) ->
    case mnesia:dirty_read(muc_online_room, S1#muc_online_room.name_host) of
	[#muc_online_room{pid = Pid2, timestamp = T2} = S2] ->
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
    case mnesia:dirty_read(muc_online_room, RoomHost) of
	[#muc_online_room{pid = Pid2}] when Pid1 == Pid2 ->
	    mnesia:dirty_delete(muc_online_room, RoomHost);
	_ ->
	    ok
    end.

iq_disco_info(ServerHost, Lang) ->
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
	    attrs = [{<<"var">>, ?NS_MUC}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_MUC_UNIQUE}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_REGISTER}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_RSM}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_MUCSUB}], children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_VCARD}], children = []}] ++
	case gen_mod:is_loaded(ServerHost, mod_mam) of
	    true ->
		[#xmlel{name = <<"feature">>,
			attrs = [{<<"var">>, ?NS_MAM_TMP}]},
		 #xmlel{name = <<"feature">>,
			attrs = [{<<"var">>, ?NS_MAM_0}]},
		 #xmlel{name = <<"feature">>,
			attrs = [{<<"var">>, ?NS_MAM_1}]}];
	    false ->
		[]
	end.

iq_disco_items(Host, From, Lang, none) ->
    lists:zf(fun (#muc_online_room{name_host =
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
	     end, get_vh_rooms_all_nodes(Host));
iq_disco_items(Host, From, Lang, Rsm) ->
    {Rooms, RsmO} = get_vh_rooms(Host, Rsm),
    RsmOut = jlib:rsm_encode(RsmO),
    lists:zf(fun (#muc_online_room{name_host =
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

get_vh_rooms(Host, #rsm_in{max = M, direction = Direction, id = I, index = Index}) ->
    AllRooms = get_vh_rooms_all_nodes(Host),
    Count = erlang:length(AllRooms),
    L = get_vh_rooms_direction(Direction, I, Index, AllRooms),
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
	   {F, _} = H#muc_online_room.name_host,
	   {Last, _} = T#muc_online_room.name_host,
	   {L2,
	    #rsm_out{first = F, last = Last, count = Count,
		     index = NewIndex}}
    end.

get_vh_rooms_direction(_Direction, _I, Index, AllRooms)
    when Index =/= undefined ->
    AllRooms;
get_vh_rooms_direction(aft, I, _Index, AllRooms) ->
    {_Before, After} = lists:splitwith(fun
					 (#muc_online_room{name_host =
							       {Na, _}}) ->
					     Na < I
				       end,
				       AllRooms),
    case After of
      [] -> [];
      [#muc_online_room{name_host = {I, _Host}}
       | AfterTail] ->
	  AfterTail;
      _ -> After
    end;
get_vh_rooms_direction(before, I, _Index, AllRooms)
    when I =/= [] ->
    {Before, _} = lists:splitwith(fun
				    (#muc_online_room{name_host = {Na, _}}) ->
					Na < I
				  end,
				  AllRooms),
    Before;
get_vh_rooms_direction(_Direction, _I, _Index,
		       AllRooms) ->
    AllRooms.

get_subscribed_rooms(ServerHost, Host, From) ->
    Rooms = get_rooms(ServerHost, Host),
    BareFrom = jid:remove_resource(From),
    lists:flatmap(
      fun(#muc_room{name_host = {Name, _}, opts = Opts}) ->
	      Subscribers = proplists:get_value(subscribers, Opts, []),
	      case lists:keymember(BareFrom, 1, Subscribers) of
		  true -> [jid:make(Name, Host, <<>>)];
		  false -> []
	      end;
	 (_) ->
	      []
      end, Rooms).

%% @doc Return the position of desired room in the list of rooms.
%% The room must exist in the list. The count starts in 0.
%% @spec (Desired::muc_online_room(), Rooms::[muc_online_room()]) -> integer()
get_room_pos(Desired, Rooms) ->
    get_room_pos(Desired, Rooms, 0).

get_room_pos(Desired, [HeadRoom | _], HeadPosition)
    when Desired#muc_online_room.name_host ==
	   HeadRoom#muc_online_room.name_host ->
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
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:get_nick(LServer, Host, From).

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
	      attrs = [{<<"xmlns">>, ?NS_XDATA},
		       {<<"type">>, <<"form">>}],
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
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:set_nick(LServer, Host, From, Nick).

iq_set_register_info(ServerHost, Host, From, Nick,
		     Lang) ->
    case set_nick(ServerHost, Host, From, Nick) of
      {atomic, ok} -> {result, []};
      {atomic, false} ->
	  ErrText = <<"That nickname is registered by another "
		      "person">>,
	  {error, ?ERRT_CONFLICT(Lang, ErrText)};
      _ ->
	  Txt = <<"Database failure">>,
	  {error, ?ERRT_INTERNAL_SERVER_ERROR(Lang, Txt)}
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
			invalid ->
			      Txt = <<"Incorrect data form">>,
			      {error, ?ERRT_BAD_REQUEST(Lang, Txt)};
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
	    children = [{xmlcdata, <<"ejabberd/mod_muc">>}]},
     #xmlel{name = <<"URL">>, attrs = [],
	    children = [{xmlcdata, ?EJABBERD_URI}]},
     #xmlel{name = <<"DESC">>, attrs = [],
	    children =
		[{xmlcdata,
		  <<(translate:translate(Lang,
					 <<"ejabberd MUC module">>))/binary,
		    "\nCopyright (c) 2003-2017 ProcessOne">>}]}].

broadcast_service_message(Host, Msg) ->
    lists:foreach(
	fun(#muc_online_room{pid = Pid}) ->
		gen_fsm:send_all_state_event(
		    Pid, {service_message, Msg})
	end, get_vh_rooms_all_nodes(Host)).

get_vh_rooms_all_nodes(Host) ->
    Rooms = mnesia:dirty_select(
	      muc_online_room,
	      ets:fun2ms(
		fun(#muc_online_room{name_host = {_, H}, pid = Pid} = R)
		      when Host == H ->
			R
		end)),
    lists:ukeysort(#muc_online_room.name_host, Rooms).

get_vh_rooms(Host) ->
    mnesia:dirty_select(muc_online_room,
      ets:fun2ms(
        fun(#muc_online_room{name_host = {_, H}, pid = Pid} = R)
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

update_muc_online_table() ->
    case catch mnesia:table_info(muc_online_room,
				 local_content)
	of
      false -> mnesia:delete_table(muc_online_room);
      true ->
            case catch mnesia:table_info(muc_online_room, attributes) of
                [name_host, pid] ->
                    mnesia:delete_table(muc_online_room);
                [name_host, timestamp, pid] ->
                    ok;
                {'EXIT', _} ->
                    ok
            end;
      {'EXIT', _} ->
            ok
    end.

is_broadcasted(RoomHost) ->
    case ejabberd_router:get_domain_balancing(RoomHost) of
        broadcast -> true;
        _ -> false
    end.

get_room_state_if_broadcasted({Room, Host}) ->
    case is_broadcasted(Host) of
	true ->
	    case mnesia:dirty_read(muc_online_room, {Room, Host}) of
		[#muc_online_room{pid = Pid}] ->
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

import_info() ->
    [{<<"muc_room">>, 4}, {<<"muc_registered">>, 4}].

import_start(LServer, DBType) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:init(LServer, []).

import(LServer, {sql, _}, DBType, Tab, L) ->
    Mod = gen_mod:db_mod(DBType, ?MODULE),
    Mod:import(LServer, Tab, L).

export(LServer) ->
    Mod = gen_mod:db_mod(LServer, ?MODULE),
    Mod:export(LServer).

mod_opt_type(access) -> fun acl:access_rules_validator/1;
mod_opt_type(access_admin) -> fun acl:access_rules_validator/1;
mod_opt_type(access_create) -> fun acl:access_rules_validator/1;
mod_opt_type(access_persistent) -> fun acl:access_rules_validator/1;
mod_opt_type(db_type) -> fun(T) -> ejabberd_config:v_db(?MODULE, T) end;
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
mod_opt_type(regexp_room_id) ->
    fun iolist_to_binary/1;
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
mod_opt_type(max_users_presence) ->
    fun (MUP) when is_integer(MUP) -> MUP end;
mod_opt_type(min_message_interval) ->
    fun (MMI) when is_number(MMI), MMI >= 0 -> MMI end;
mod_opt_type(min_presence_interval) ->
    fun (I) when is_number(I), I >= 0 -> I end;
mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(persist_history) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(room_shaper) -> fun acl:shaper_rules_validator/1;
mod_opt_type(user_message_shaper) -> fun acl:shaper_rules_validator/1;
mod_opt_type(user_presence_shaper) -> fun acl:shaper_rules_validator/1;
mod_opt_type(preload_rooms) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(_) ->
    [access, access_admin, access_create, access_persistent,
     db_type, default_room_options, hibernate_timeout,
     history_size, host, max_room_desc, max_room_id,
     max_room_name, max_user_conferences, max_users, regexp_room_id,
     max_users_admin_threshold, max_users_presence,
     min_message_interval, min_presence_interval, p1db_group,
     persist_history, room_shaper, user_message_shaper,
     user_presence_shaper, preload_rooms].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
