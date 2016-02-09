%%%----------------------------------------------------------------------
%%% File    : mod_offline.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Store and manage offline messages.
%%% Created :  5 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
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

-module(mod_offline).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-protocol({xep, 22, '1.4'}).
-protocol({xep, 23, '1.3'}).
-protocol({xep, 160, '1.0'}).
-protocol({xep, 334, '0.2'}).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

-behaviour(gen_mod).

-export([count_offline_messages/2]).

-export([start/2,
	 start_link/2,
	 stop/1,
	 store_packet/3,
	 get_offline_els/2,
	 pop_offline_messages/3,
	 get_sm_features/5,
	 get_sm_identity/5,
	 get_sm_items/5,
	 get_info/5,
	 handle_offline_query/3,
	 remove_expired_messages/1,
	 remove_old_messages/2,
	 remove_user/2,
	 import/5,
	 export/1,
	 get_queue_length/2,
	 count_offline_messages/3,
	 webadmin_page/3,
	 webadmin_user/4,
	 webadmin_user_parse_query/5,
	 enc_key/1, dec_key/1, enc_val/2, dec_val/2,
	 import_info/0, import_start/2]).


%% Called from mod_offline_worker
-export([store_offline_msg/6, discard_warn_sender/1, get_max_user_messages/3]).

%% For debuging
-export([status/1]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_http.hrl").

-include("ejabberd_web_admin.hrl").

-include("mod_offline.hrl").

-define(PROCNAME, ejabberd_offline).

-define(OFFLINE_TABLE_LOCK_THRESHOLD, 1000).

%% default value for the maximum number of user messages
-define(MAX_USER_MESSAGES, infinity).

start_link(Host, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    ?GEN_SERVER:start_link({local, Proc}, ?MODULE,
                           [Host, Opts], [{max_queue, 5000}]).

start(Host, Opts) ->
    mod_offline_sup:start(Host, Opts).

stop(Host) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    catch ?GEN_SERVER:call(Proc, stop),
    mod_offline_sup:stop(Host).

status(Host) ->
    mod_offline_sup:status(Host).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host, Opts]) ->
    init_db(gen_mod:db_type(Host, Opts), Host),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, fun gen_iq_handler:check_type/1,
			     no_queue),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE,
		       store_packet, 50),
    ejabberd_hooks:add(resend_offline_messages_hook, Host,
		       ?MODULE, pop_offline_messages, 50),
    ejabberd_hooks:add(remove_user, Host,
		       ?MODULE, remove_user, 50),
    ejabberd_hooks:add(anonymous_purge_hook, Host,
		       ?MODULE, remove_user, 50),
    ejabberd_hooks:add(disco_sm_features, Host,
		       ?MODULE, get_sm_features, 50),
    ejabberd_hooks:add(disco_local_features, Host,
		       ?MODULE, get_sm_features, 50),
    ejabberd_hooks:add(disco_sm_identity, Host,
		       ?MODULE, get_sm_identity, 50),
    ejabberd_hooks:add(disco_sm_items, Host,
		       ?MODULE, get_sm_items, 50),
    ejabberd_hooks:add(disco_info, Host, ?MODULE, get_info, 50),
    ejabberd_hooks:add(webadmin_page_host, Host,
		       ?MODULE, webadmin_page, 50),
    ejabberd_hooks:add(webadmin_user, Host,
		       ?MODULE, webadmin_user, 50),
    ejabberd_hooks:add(webadmin_user_parse_query, Host,
		       ?MODULE, webadmin_user_parse_query, 50),
    ejabberd_hooks:add(count_offline_messages, Host,
		       ?MODULE, count_offline_messages, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_FLEX_OFFLINE,
				  ?MODULE, handle_offline_query, IQDisc),
    AccessMaxOfflineMsgs =
	gen_mod:get_opt(access_max_user_messages, Opts,
			fun(A) when is_atom(A) -> A end,
			max_user_offline_messages),
    {ok,
     #state{host = Host,
            access_max_offline_messages = AccessMaxOfflineMsgs,
            dbtype = gen_mod:db_type(Host, Opts)}}.


handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.


handle_cast(_Msg, State) -> {noreply, State}.


handle_info(_Info, State) ->
    ?ERROR_MSG("got unexpected info: ~p", [_Info]),
    {noreply, State}.


terminate(_Reason, State) ->
    Host = State#state.host,
    ejabberd_hooks:delete(offline_message_hook, Host,
			  ?MODULE, store_packet, 50),
    ejabberd_hooks:delete(resend_offline_messages_hook,
			  Host, ?MODULE, pop_offline_messages, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    ejabberd_hooks:delete(anonymous_purge_hook, Host,
			  ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(disco_sm_features, Host, ?MODULE, get_sm_features, 50),
    ejabberd_hooks:delete(disco_local_features, Host, ?MODULE, get_sm_features, 50),
    ejabberd_hooks:delete(disco_sm_identity, Host, ?MODULE, get_sm_identity, 50),
    ejabberd_hooks:delete(disco_sm_items, Host, ?MODULE, get_sm_items, 50),
    ejabberd_hooks:delete(disco_info, Host, ?MODULE, get_info, 50),
    ejabberd_hooks:delete(webadmin_page_host, Host,
			  ?MODULE, webadmin_page, 50),
    ejabberd_hooks:delete(webadmin_user, Host,
			  ?MODULE, webadmin_user, 50),
    ejabberd_hooks:delete(webadmin_user_parse_query, Host,
			  ?MODULE, webadmin_user_parse_query, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_FLEX_OFFLINE),
    ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.


init_db(mnesia, _Host) ->
    mnesia:create_table(offline_msg,
                        [{disc_only_copies, [node()]}, {type, bag},
                         {attributes, record_info(fields, offline_msg)}]),
    update_table();
init_db(p1db, Host) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(offline_msg,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user, timestamp]},
                               {vals, [expire, packet]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]);
init_db(rest, Host) ->
    rest:start(Host),
    ok;
init_db(_, _) ->
    ok.


store_offline_msg(_Host, US, Msgs, Len, MaxOfflineMsgs,
		  mnesia) ->
    F = fun () ->
		Count = if MaxOfflineMsgs =/= infinity ->
			       Len + count_mnesia_records(US);
			   true -> 0
			end,
		if Count > MaxOfflineMsgs -> discard_warn_sender(Msgs);
		   true ->
		       if Len >= (?OFFLINE_TABLE_LOCK_THRESHOLD) ->
			      mnesia:write_lock_table(offline_msg);
			  true -> ok
		       end,
		       lists:foreach(fun (M) -> mnesia:write(M) end, Msgs)
		end
	end,
    mnesia:transaction(F);
store_offline_msg(Host, {User, _Server}, Msgs, Len, MaxOfflineMsgs, odbc) ->
    Count = if MaxOfflineMsgs =/= infinity ->
		   Len + count_offline_messages(User, Host);
	       true -> 0
	    end,
    if Count > MaxOfflineMsgs -> discard_warn_sender(Msgs);
       true ->
	   Query = lists:map(fun (M) ->
				     Username =
					 ejabberd_odbc:escape((M#offline_msg.to)#jid.luser),
				     From = M#offline_msg.from,
				     To = M#offline_msg.to,
				     Packet =
					 jlib:replace_from_to(From, To,
							      M#offline_msg.packet),
				     NewPacket =
					 jlib:add_delay_info(Packet, Host,
							     M#offline_msg.timestamp,
							     <<"Offline Storage">>),
				     XML =
					 ejabberd_odbc:escape(xml:element_to_binary(NewPacket)),
				     odbc_queries:add_spool_sql(Username, XML)
			     end,
			     Msgs),
	   odbc_queries:add_spool(Host, Query)
    end;
store_offline_msg(Host, {User, _}, Msgs, Len, MaxOfflineMsgs, p1db) ->
    Count = if MaxOfflineMsgs =/= infinity ->
                    Len + count_offline_messages(User, Host);
               true -> 0
            end,
    if Count > MaxOfflineMsgs ->
            discard_warn_sender(Msgs);
       true ->
            lists:foreach(
              fun(#offline_msg{us = {LUser, LServer}, timestamp = Now,
                               from = From, to = To,
                               packet = #xmlel{attrs = Attrs} = El} = Msg) ->
                      NewAttrs = jlib:replace_from_to_attrs(
                                   jid:to_string(From),
                                   jid:to_string(To),
                                   Attrs),
                      NewEl = El#xmlel{attrs = NewAttrs},
                      USNKey = usn2key(LUser, LServer, Now),
                      Val = offmsg_to_p1db(Msg#offline_msg{packet = NewEl}),
                      p1db:insert(offline_msg, USNKey, Val)
              end, Msgs)
    end;
store_offline_msg(Host, {User, _}, Msgs, Len, MaxOfflineMsgs, rest) ->
    Count = if MaxOfflineMsgs =/= infinity ->
                    Len + count_offline_messages(User, Host);
               true -> 0
            end,
    if
        Count > MaxOfflineMsgs ->
            discard_warn_sender(Msgs);
        true ->
            lists:foreach(
              fun(#offline_msg{us = {LUser, LServer}, timestamp = Now,
                               from = From, to = To,
                               packet = #xmlel{attrs = _Attrs} = El} = Msg) ->
			Path = offline_rest_path(LUser, LServer),
			%% Retry 2 times, with a backoff of 500millisec
			case rest:with_retry(post, [LServer, Path, [],
				    {[{<<"peer">>, jid:to_string(From)},
				      {<<"packet">>, xml:element_to_binary(El)},
				      {<<"timestamp">>, jlib:now_to_utc_string(Now,3)} ]}], 2, 500) of
			    {ok, Code, _} when Code == 200 orelse Code == 201 ->
				ok;
			    Err ->
				?ERROR_MSG("failed to store packet for user ~s and peer ~s:"
				    " ~p.  Packet: ~p",
				    [From, To, Err, Msg]),
				{error, Err}
			end
              end, Msgs)
    end;
store_offline_msg(Host, {User, _}, Msgs, Len, MaxOfflineMsgs,
		  riak) ->
    Count = if MaxOfflineMsgs =/= infinity ->
                    Len + count_offline_messages(User, Host);
               true -> 0
            end,
    if
        Count > MaxOfflineMsgs ->
            discard_warn_sender(Msgs);
        true ->
            lists:foreach(
              fun(#offline_msg{us = US,
                               timestamp = TS} = M) ->
                      ejabberd_riak:put(M, offline_msg_schema(),
					[{i, TS}, {'2i', [{<<"us">>, US}]}])
              end, Msgs)
    end.

get_max_user_messages(AccessRule, {User, Server}, Host) ->
    case acl:match_rule(
	   Host, AccessRule, jid:make(User, Server, <<"">>)) of
	Max when is_integer(Max) -> Max;
	infinity -> infinity;
	_ -> ?MAX_USER_MESSAGES
    end.

get_sm_features(Acc, _From, _To, <<"">>, _Lang) ->
    Feats = case Acc of
		{result, I} -> I;
		_ -> []
	    end,
    {result, Feats ++ [?NS_FEATURE_MSGOFFLINE, ?NS_FLEX_OFFLINE]};

get_sm_features(_Acc, _From, _To, ?NS_FEATURE_MSGOFFLINE, _Lang) ->
    %% override all lesser features...
    {result, []};

get_sm_features(_Acc, #jid{luser = U, lserver = S}, #jid{luser = U, lserver = S},
		?NS_FLEX_OFFLINE, _Lang) ->
    {result, [?NS_FLEX_OFFLINE]};

get_sm_features(Acc, _From, _To, _Node, _Lang) ->
    Acc.

get_sm_identity(_Acc, #jid{luser = U, lserver = S}, #jid{luser = U, lserver = S},
		?NS_FLEX_OFFLINE, _Lang) ->
    Identity = #xmlel{name = <<"identity">>,
		      attrs = [{<<"category">>, <<"automation">>},
			       {<<"type">>, <<"message-list">>}]},
    [Identity];
get_sm_identity(Acc, _From, _To, _Node, _Lang) ->
    Acc.

get_sm_items(_Acc, #jid{luser = U, lserver = S, lresource = R} = JID,
	     #jid{luser = U, lserver = S},
	     ?NS_FLEX_OFFLINE, _Lang) ->
    case ejabberd_sm:get_session_pid(U, S, R) of
	Pid when is_pid(Pid) ->
	    Hdrs = read_message_headers(U, S),
	    BareJID = jid:to_string(jid:remove_resource(JID)),
	    Pid ! dont_ask_offline,
	    {result, lists:map(
		       fun({Node, From, _OfflineMsg}) ->
			       #xmlel{name = <<"item">>,
				      attrs = [{<<"jid">>, BareJID},
					       {<<"node">>, Node},
					       {<<"name">>, From}]}
		       end, Hdrs)};
	none ->
	    {result, []}
    end;
get_sm_items(Acc, _From, _To, _Node, _Lang) ->
    Acc.

get_info(_Acc, #jid{luser = U, lserver = S}, #jid{luser = U, lserver = S},
	 ?NS_FLEX_OFFLINE, _Lang) ->
    N = jlib:integer_to_binary(count_offline_messages(U, S)),
    [#xmlel{name = <<"x">>,
	    attrs = [{<<"xmlns">>, ?NS_XDATA},
		     {<<"type">>, <<"result">>}],
	    children = [#xmlel{name = <<"field">>,
			       attrs = [{<<"var">>, <<"FORM_TYPE">>},
					{<<"type">>, <<"hidden">>}],
			       children = [#xmlel{name = <<"value">>,
						  children = [{xmlcdata,
							       ?NS_FLEX_OFFLINE}]}]},
			#xmlel{name = <<"field">>,
			       attrs = [{<<"var">>, <<"number_of_messages">>}],
			       children = [#xmlel{name = <<"value">>,
						  children = [{xmlcdata, N}]}]}]}];
get_info(Acc, _From, _To, _Node, _Lang) ->
    Acc.

handle_offline_query(#jid{luser = U, lserver = S} = From,
		     #jid{luser = U, lserver = S} = _To,
		     #iq{type = Type, sub_el = SubEl} = IQ) ->
    case Type of
	get ->
	    case xml:get_subtag(SubEl, <<"fetch">>) of
		#xmlel{} ->
		    handle_offline_fetch(From);
		false ->
		    handle_offline_items_view(From, SubEl)
	    end;
	set ->
	    case xml:get_subtag(SubEl, <<"purge">>) of
		#xmlel{} ->
		    delete_all_msgs(U, S);
		false ->
		    handle_offline_items_remove(From, SubEl)
	    end
    end,
    IQ#iq{type = result, sub_el = []};
handle_offline_query(_From, _To, #iq{sub_el = SubEl} = IQ) ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_FORBIDDEN]}.

handle_offline_items_view(JID, #xmlel{children = Items}) ->
    {U, S, R} = jid:tolower(JID),
    lists:foreach(
      fun(Node) ->
	      case fetch_msg_by_node(JID, Node) of
		  {ok, OfflineMsg} ->
		      case offline_msg_to_route(S, OfflineMsg) of
			  {route, From, To, El} ->
			      NewEl = set_offline_tag(El, Node),
			      case ejabberd_sm:get_session_pid(U, S, R) of
				  Pid when is_pid(Pid) ->
				      Pid ! {route, From, To, NewEl};
				  none ->
				      ok
			      end;
			  error ->
			      ok
		      end;
		  error ->
		      ok
	      end
      end, get_nodes_from_items(Items, <<"view">>)).

handle_offline_items_remove(JID, #xmlel{children = Items}) ->
    lists:foreach(
      fun(Node) ->
	      remove_msg_by_node(JID, Node)
      end, get_nodes_from_items(Items, <<"remove">>)).

get_nodes_from_items(Items, Action) ->
    lists:flatmap(
      fun(#xmlel{name = <<"item">>, attrs = Attrs}) ->
	      case xml:get_attr_s(<<"action">>, Attrs) of
		  Action ->
		      case xml:get_attr_s(<<"node">>, Attrs) of
			  <<"">> ->
			      [];
			  TS ->
			      [TS]
		      end;
		  _ ->
		      []
	      end;
	 (_) ->
	      []
      end, Items).

set_offline_tag(#xmlel{children = Els} = El, Node) ->
    OfflineEl = #xmlel{name = <<"offline">>,
		       attrs = [{<<"xmlns">>, ?NS_FLEX_OFFLINE}],
		       children = [#xmlel{name = <<"item">>,
					  attrs = [{<<"node">>, Node}]}]},
    El#xmlel{children = [OfflineEl|Els]}.

handle_offline_fetch(#jid{luser = U, lserver = S, lresource = R}) ->
    case ejabberd_sm:get_session_pid(U, S, R) of
	none ->
	    ok;
	Pid when is_pid(Pid) ->
	    Pid ! dont_ask_offline,
	    lists:foreach(
	      fun({Node, _, Msg}) ->
		      case offline_msg_to_route(S, Msg) of
			  {route, From, To, El} ->
			      NewEl = set_offline_tag(El, Node),
			      Pid ! {route, From, To, NewEl};
			  error ->
			      ok
		      end
	      end, read_message_headers(U, S))
    end.

fetch_msg_by_node(To, <<Seq:20/binary, "+", From_s/binary>>) ->
    case jid:from_string(From_s) of
	From = #jid{} ->
	    case gen_mod:db_type(To#jid.lserver, ?MODULE) of
		odbc ->
		    read_message(From, To, Seq, odbc);
		DBType ->
		    case binary_to_timestamp(Seq) of
			undefined -> ok;
			TS -> read_message(From, To, TS, DBType)
		    end
	    end;
	error ->
	    ok
    end.

remove_msg_by_node(To, <<Seq:20/binary, "+", From_s/binary>>) ->
    case jid:from_string(From_s) of
	From = #jid{} ->
	    case gen_mod:db_type(To#jid.lserver, ?MODULE) of
		odbc ->
		    remove_message(From, To, Seq, odbc);
		DBType ->
		    case binary_to_timestamp(Seq) of
			undefined -> ok;
			TS -> remove_message(From, To, TS, DBType)
		    end
	    end;
	error ->
	    ok
    end.

need_to_store(LServer, Packet) ->
    Type = xml:get_tag_attr_s(<<"type">>, Packet),
    if (Type /= <<"error">>) and (Type /= <<"groupchat">>)
       and (Type /= <<"headline">>) ->
	    case has_offline_tag(Packet) of
		false ->
	    case check_store_hint(Packet) of
		store ->
		    true;
		no_store ->
		    false;
		none ->
		    case gen_mod:get_module_opt(
			   LServer, ?MODULE, store_empty_body,
			   fun(V) when is_boolean(V) -> V;
			      (unless_chat_state) -> unless_chat_state
			   end,
			   unless_chat_state) of
			false ->
			    xml:get_subtag(Packet, <<"body">>) /= false;
			unless_chat_state ->
			    not jlib:is_standalone_chat_state(Packet);
			true ->
			    true
		    end
	    end;
       true ->
	    false
	    end;
       true ->
	    false
    end.

store_packet(From, To, Packet) ->
    case need_to_store(To#jid.lserver, Packet) of
	true ->
	    case check_event(From, To, Packet) of
		true ->
		    #jid{luser = LUser, lserver = LServer} = To,
		    TimeStamp = p1_time_compat:timestamp(),
		    #xmlel{children = Els} = Packet,
		    Expire = find_x_expire(TimeStamp, Els),
		    Worker = mod_offline_sup:get_worker_for(To#jid.lserver, To#jid.luser),
		    Worker !  #offline_msg{us = {LUser, LServer},
			timestamp = TimeStamp, expire = Expire,
			from = From, to = To, packet = Packet},
		    stop;
		_ -> ok
	    end;
	false -> ok
    end.

check_store_hint(Packet) ->
    case has_store_hint(Packet) of
	true ->
	    store;
	false ->
	    case has_no_store_hint(Packet) of
		true ->
		    no_store;
		false ->
		    none
	    end
    end.

has_store_hint(Packet) ->
    xml:get_subtag_with_xmlns(Packet, <<"store">>, ?NS_HINTS) =/= false.

has_no_store_hint(Packet) ->
    xml:get_subtag_with_xmlns(Packet, <<"no-store">>, ?NS_HINTS) =/= false
      orelse
      xml:get_subtag_with_xmlns(Packet, <<"no-storage">>, ?NS_HINTS) =/= false.

has_offline_tag(Packet) ->
    xml:get_subtag_with_xmlns(Packet, <<"offline">>, ?NS_FLEX_OFFLINE) =/= false.

%% Check if the packet has any content about XEP-0022
check_event(From, To, Packet) ->
    #xmlel{name = Name, attrs = Attrs, children = Els} =
	Packet,
    case find_x_event(Els) of
      false -> true;
      El ->
	  case xml:get_subtag(El, <<"id">>) of
	    false ->
		case xml:get_subtag(El, <<"offline">>) of
		  false -> true;
		  _ ->
		      ID = case xml:get_tag_attr_s(<<"id">>, Packet) of
			     <<"">> ->
				 #xmlel{name = <<"id">>, attrs = [],
					children = []};
			     S ->
				 #xmlel{name = <<"id">>, attrs = [],
					children = [{xmlcdata, S}]}
			   end,
		      ejabberd_router:route(To, From,
					    #xmlel{name = Name, attrs = Attrs,
						   children =
						       [#xmlel{name = <<"x">>,
							       attrs =
								   [{<<"xmlns">>,
								     ?NS_EVENT}],
							       children =
								   [ID,
								    #xmlel{name
									       =
									       <<"offline">>,
									   attrs
									       =
									       [],
									   children
									       =
									       []}]}]}),
		      true
		end;
	    _ -> false
	  end
    end.

%% Check if the packet has subelements about XEP-0022
find_x_event([]) -> false;
find_x_event([{xmlcdata, _} | Els]) ->
    find_x_event(Els);
find_x_event([El | Els]) ->
    case xml:get_tag_attr_s(<<"xmlns">>, El) of
      ?NS_EVENT -> El;
      _ -> find_x_event(Els)
    end.

find_x_expire(_, []) -> never;
find_x_expire(TimeStamp, [{xmlcdata, _} | Els]) ->
    find_x_expire(TimeStamp, Els);
find_x_expire(TimeStamp, [El | Els]) ->
    case xml:get_tag_attr_s(<<"xmlns">>, El) of
      ?NS_EXPIRE ->
	  Val = xml:get_tag_attr_s(<<"seconds">>, El),
	  case catch jlib:binary_to_integer(Val) of
	    {'EXIT', _} -> never;
	    Int when Int > 0 ->
		{MegaSecs, Secs, MicroSecs} = TimeStamp,
		S = MegaSecs * 1000000 + Secs + Int,
		MegaSecs1 = S div 1000000,
		Secs1 = S rem 1000000,
		{MegaSecs1, Secs1, MicroSecs};
	    _ -> never
	  end;
      _ -> find_x_expire(TimeStamp, Els)
    end.

pop_offline_messages(Ls, User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    pop_offline_messages(Ls, LUser, LServer,
			 gen_mod:db_type(LServer, ?MODULE)).

pop_offline_messages(Ls, LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    F = fun () ->
		Rs = mnesia:wread({offline_msg, US}),
		mnesia:delete({offline_msg, US}),
		Rs
	end,
    case mnesia:transaction(F) of
      {atomic, Rs} ->
	  TS = p1_time_compat:timestamp(),
	  Ls ++
	    lists:map(fun (R) ->
			      offline_msg_to_route(LServer, R)
		      end,
		      lists:filter(fun (R) ->
					   case R#offline_msg.expire of
					     never -> true;
					     TimeStamp -> TS < TimeStamp
					   end
				   end,
				   lists:keysort(#offline_msg.timestamp, Rs)));
      _ -> Ls
    end;
pop_offline_messages(Ls, LUser, LServer, odbc) ->
    EUser = ejabberd_odbc:escape(LUser),
    case odbc_queries:get_and_del_spool_msg_t(LServer,
					      EUser)
	of
      {atomic, {selected, [<<"username">>, <<"xml">>], Rs}} ->
	  Ls ++
	    lists:flatmap(fun ([_, XML]) ->
				  case xml_stream:parse_element(XML) of
				    {error, _Reason} ->
                                          [];
				    El ->
                                          case offline_msg_to_route(LServer, El) of
                                              error ->
                                                  [];
                                              RouteMsg ->
                                                  [RouteMsg]
                                          end
				  end
			  end,
			  Rs);
      _ -> Ls
    end;
pop_offline_messages(Ls, LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
        {ok, L} ->
            TS = p1_time_compat:timestamp(),
            Msgs = lists:flatmap(
                     fun({Key, Val, _VClock}) ->
                             DelRes = p1db:delete(offline_msg, Key),
                             if DelRes == ok; DelRes == {error, notfound} ->
                                     Now = key2now(USPrefix, Key),
                                     USN = {LUser, LServer, Now},
                                     M = p1db_to_offmsg(USN, Val),
                                     IsExpired = case M#offline_msg.expire of
                                                     never -> false;
                                                     TS1 -> TS >= TS1
                                                 end,
                                     if IsExpired ->
                                             [];
                                        true ->
                                             [offline_msg_to_route(LServer, M)]
                                     end;
                                true ->
                                     []
                             end
                     end, L),
            Ls ++ Msgs;
        _Err ->
            Ls
    end;
pop_offline_messages(Ls, LUser, LServer, riak) ->
    case ejabberd_riak:get_by_index(offline_msg, offline_msg_schema(),
                                    <<"us">>, {LUser, LServer}) of
        {ok, Rs} ->
            try
                lists:foreach(
                  fun(#offline_msg{timestamp = T}) ->
                          ok = ejabberd_riak:delete(offline_msg, T)
                  end, Rs),
                TS = p1_time_compat:timestamp(),
                Ls ++ lists:map(
                        fun (R) ->
                                offline_msg_to_route(LServer, R)
                        end,
                        lists:filter(
                          fun(R) ->
                                  case R#offline_msg.expire of
                                      never -> true;
                                      TimeStamp -> TS < TimeStamp
                                  end
                          end,
                          lists:keysort(#offline_msg.timestamp, Rs)))
            catch _:{badmatch, _} ->
                    Ls
            end;
	_ ->
	    Ls
    end;
pop_offline_messages(Ls, LUser, LServer, rest) ->
    Path = offline_rest_path(LUser, LServer, <<"pop">>),
    case rest:with_retry(post, [LServer, Path, [], []], 2, 500) of
        {ok, 200, Resp} ->
                To = jid:make(LUser, LServer, <<>>),
                Ls ++ lists:flatmap(
                        fun ({Item}) ->
                                From = jid:from_string(proplists:get_value(<<"peer">>, Item, <<>>)),
                                Timestamp = proplists:get_value(<<"timestamp">>, Item, <<>>),
                                Packet = proplists:get_value(<<"packet">>, Item, <<>>),
                                case xml_stream:parse_element(Packet) of
                                    {error,Reason} ->
                                        ?ERROR_MSG("Bad packet XML received from rest offline: ~p : ~p ", [Packet, Reason]),
                                        [];
                                    El ->
                                        [{route, From, To, jlib:add_delay_info(El, LServer, Timestamp, <<"Offline Storage">>)}]
                                end
                        end,
                        Resp);
        Other ->
            ?ERROR_MSG("Unexpected response for offline pop: ~p", [Other]),
            Ls
    end.

remove_expired_messages(Server) ->
    LServer = jid:nameprep(Server),
    remove_expired_messages(LServer,
			    gen_mod:db_type(LServer, ?MODULE)).

remove_expired_messages(_LServer, mnesia) ->
    TimeStamp = p1_time_compat:timestamp(),
    F = fun () ->
		mnesia:write_lock_table(offline_msg),
		mnesia:foldl(fun (Rec, _Acc) ->
				     case Rec#offline_msg.expire of
				       never -> ok;
				       TS ->
					   if TS < TimeStamp ->
						  mnesia:delete_object(Rec);
					      true -> ok
					   end
				     end
			     end,
			     ok, offline_msg)
	end,
    mnesia:transaction(F);
remove_expired_messages(_LServer, odbc) -> {atomic, ok};
remove_expired_messages(_LServer, p1db) -> {atomic, ok};
remove_expired_messages(_LServer, riak) -> {atomic, ok};
remove_expired_messages(_LServer, rest) -> {atomic, ok}. %%not supported

remove_old_messages(Days, Server) ->
    LServer = jid:nameprep(Server),
    remove_old_messages(Days, LServer,
			gen_mod:db_type(LServer, ?MODULE)).

remove_old_messages(Days, _LServer, mnesia) ->
    S = p1_time_compat:system_time(seconds) - 60 * 60 * 24 * Days,
    MegaSecs1 = S div 1000000,
    Secs1 = S rem 1000000,
    TimeStamp = {MegaSecs1, Secs1, 0},
    F = fun () ->
		mnesia:write_lock_table(offline_msg),
		mnesia:foldl(fun (#offline_msg{timestamp = TS} = Rec,
				  _Acc)
				     when TS < TimeStamp ->
				     mnesia:delete_object(Rec);
				 (_Rec, _Acc) -> ok
			     end,
			     ok, offline_msg)
	end,
    mnesia:transaction(F);

remove_old_messages(Days, LServer, odbc) ->
    case catch ejabberd_odbc:sql_query(
		 LServer,
		 [<<"DELETE FROM spool"
		   " WHERE created_at < "
		   "DATE_SUB(CURDATE(), INTERVAL ">>,
		  integer_to_list(Days), <<" DAY);">>]) of
	{updated, N} ->
	    ?INFO_MSG("~p message(s) deleted from offline spool", [N]);
	_Error ->
	    ?ERROR_MSG("Cannot delete message in offline spool: ~p", [_Error])
    end,
    {atomic, ok};
remove_old_messages(_Days, _LServer, p1db) ->
    {atomic, ok};
remove_old_messages(_Days, _LServer, riak) ->
    {atomic, ok};
remove_old_messages(_Days, _LServer, rest) -> %%Not supported
    {atomic, ok}.

remove_user(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    remove_user(LUser, LServer,
		gen_mod:db_type(LServer, ?MODULE)).

remove_user(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    F = fun () -> mnesia:delete({offline_msg, US}) end,
    mnesia:transaction(F);
remove_user(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    odbc_queries:del_spool_msg(LServer, Username);
remove_user(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _Val, _VClock}) ->
                      p1db:delete(offline_msg, Key)
              end, L),
            {atomic, ok};
        Err ->
            {aborted, Err}
    end;
remove_user(LUser, LServer, riak) ->
    {atomic, ejabberd_riak:delete_by_index(offline_msg,
                                           <<"us">>, {LUser, LServer})};
remove_user(LUser, LServer, rest) ->
    delete_all_msgs(LUser, LServer, rest).



jid_to_binary(#jid{user = U, server = S, resource = R,
                   luser = LU, lserver = LS, lresource = LR}) ->
    #jid{user = iolist_to_binary(U),
         server = iolist_to_binary(S),
         resource = iolist_to_binary(R),
         luser = iolist_to_binary(LU),
         lserver = iolist_to_binary(LS),
         lresource = iolist_to_binary(LR)}.

update_table() ->
    Fields = record_info(fields, offline_msg),
    case mnesia:table_info(offline_msg, attributes) of
        Fields ->
            ejabberd_config:convert_table_to_binary(
              offline_msg, Fields, bag,
              fun(#offline_msg{us = {U, _}}) -> U end,
              fun(#offline_msg{us = {U, S},
                               from = From,
                               to = To,
                               packet = El} = R) ->
                      R#offline_msg{us = {iolist_to_binary(U),
                                          iolist_to_binary(S)},
                                    from = jid_to_binary(From),
                                    to = jid_to_binary(To),
                                    packet = xml:to_xmlel(El)}
              end);
        _ ->
            ?INFO_MSG("Recreating offline_msg table", []),
            mnesia:transform_table(offline_msg, ignore, Fields)
    end.

%% Helper functions:

%% Warn senders that their messages have been discarded:
discard_warn_sender(Msgs) ->
    lists:foreach(fun (#offline_msg{from = From, to = To,
				    packet = Packet}) ->
			  ErrText = <<"Your contact offline message queue is "
				      "full. The message has been discarded.">>,
			  Lang = xml:get_tag_attr_s(<<"xml:lang">>, Packet),
			  Err = jlib:make_error_reply(Packet,
						      ?ERRT_RESOURCE_CONSTRAINT(Lang,
										ErrText)),
			  ejabberd_router:route(To, From, Err)
		  end,
		  Msgs).

webadmin_page(_, Host,
	      #request{us = _US, path = [<<"user">>, U, <<"queue">>],
		       q = Query, lang = Lang} =
		  _Request) ->
    Res = user_queue(U, Host, Query, Lang), {stop, Res};
webadmin_page(Acc, _, _) -> Acc.

get_offline_els(LUser, LServer) ->
    get_offline_els(LUser, LServer, gen_mod:db_type(LServer, ?MODULE)).

get_offline_els(LUser, LServer, DBType)
  when DBType == mnesia; DBType == riak; DBType == p1db ->
    Msgs = read_all_msgs(LUser, LServer, DBType),
    lists:map(
      fun(Msg) ->
              {route, From, To, Packet} = offline_msg_to_route(LServer, Msg),
              jlib:replace_from_to(From, To, Packet)
      end, Msgs);

get_offline_els(_LUser, _LServer, rest) ->
    %AFAIK this is only used by ejabberd_piefis
    throw({not_implemented,rest});

get_offline_els(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch ejabberd_odbc:sql_query(LServer,
				       [<<"select xml from spool  where username='">>,
					Username, <<"'  order by seq;">>]) of
        {selected, [<<"xml">>], Rs} ->
            lists:flatmap(
              fun([XML]) ->
                      case xml_stream:parse_element(XML) of
                          #xmlel{} = El ->
                              case offline_msg_to_route(LServer, El) of
                                  {route, _, _, NewEl} ->
                                      [NewEl];
                                  error ->
                                      []
                              end;
                          _ ->
                              []
                      end
              end, Rs);
        _ ->
            []
    end.

offline_msg_to_route(LServer, #offline_msg{} = R) ->
    {route, R#offline_msg.from, R#offline_msg.to,
     jlib:add_delay_info(R#offline_msg.packet, LServer, R#offline_msg.timestamp,
			 <<"Offline Storage">>)};
offline_msg_to_route(_LServer, #xmlel{} = El) ->
    To = jid:from_string(xml:get_tag_attr_s(<<"to">>, El)),
    From = jid:from_string(xml:get_tag_attr_s(<<"from">>, El)),
    if (To /= error) and (From /= error) ->
            {route, From, To, El};
       true ->
            error
    end.

binary_to_timestamp(TS) ->
    case catch jlib:binary_to_integer(TS) of
	Int when is_integer(Int) ->
	    Secs = Int div 1000000,
	    USec = Int rem 1000000,
	    MSec = Secs div 1000000,
	    Sec = Secs rem 1000000,
	    {MSec, Sec, USec};
	_ ->
	    undefined
    end.

timestamp_to_binary({MS, S, US}) ->
    format_timestamp(integer_to_list((MS * 1000000 + S) * 1000000 + US)).

format_timestamp(TS) ->
    iolist_to_binary(io_lib:format("~20..0s", [TS])).

offline_msg_to_header(#offline_msg{from = From, timestamp = Int} = Msg) ->
    TS = timestamp_to_binary(Int),
    From_s = jid:to_string(From),
    {<<TS/binary, "+", From_s/binary>>, From_s, Msg}.

read_message_headers(LUser, LServer) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    read_message_headers(LUser, LServer, DBType).

read_message_headers(LUser, LServer, mnesia) ->
    Msgs = mnesia:dirty_read({offline_msg, {LUser, LServer}}),
    Hdrs = lists:map(fun offline_msg_to_header/1, Msgs),
    lists:keysort(1, Hdrs);
read_message_headers(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
	{ok, L} ->
	    lists:map(
	      fun({Key, Val, _VClock}) ->
		      Now = key2now(USPrefix, Key),
		      USN = {LUser, LServer, Now},
		      Msg = p1db_to_offmsg(USN, Val),
		      offline_msg_to_header(Msg)
	      end, L);
	_Err ->
	    []
    end;
read_message_headers(LUser, LServer, riak) ->
    case ejabberd_riak:get_by_index(
           offline_msg, offline_msg_schema(),
	   <<"us">>, {LUser, LServer}) of
        {ok, Rs} ->
	    Hdrs = lists:map(fun offline_msg_to_header/1, Rs),
	    lists:keysort(1, Hdrs);
	_Err ->
	    []
    end;
read_message_headers(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch ejabberd_odbc:sql_query(
		 LServer, [<<"select xml, seq from spool where username ='">>,
			   Username, <<"' order by seq;">>]) of
	{selected, [<<"xml">>, <<"seq">>], Rows} ->
	    Hdrs = lists:flatmap(
		     fun([XML, Seq]) ->
			     try
				 #xmlel{} = El = xml_stream:parse_element(XML),
				 From = xml:get_tag_attr_s(<<"from">>, El),
				 #jid{} = jid:from_string(From),
				 TS = format_timestamp(Seq),
				 [{<<TS/binary, "+", From/binary>>, From, El}]
			     catch _:_ -> []
			     end
		     end, Rows),
	    lists:keysort(1, Hdrs);
	_Err ->
	    []
    end.

read_message(_From, To, TS, mnesia) ->
    {U, S, _} = jid:tolower(To),
    case mnesia:dirty_match_object(
	   offline_msg, #offline_msg{us = {U, S}, timestamp = TS, _ = '_'}) of
	[Msg|_] ->
	    {ok, Msg};
	_ ->
	    error
    end;
read_message(_From, To, TS, p1db) ->
    {U, S, _} = jid:tolower(To),
    Key = usn2key(U, S, TS),
    case p1db:get(offline_msg, Key) of
	{ok, Val, _VClock} ->
	    {ok, p1db_to_offmsg({U, S, TS}, Val)};
	_Err ->
	    error
    end;
read_message(_From, _To, TS, riak) ->
    case ejabberd_riak:get(offline_msg, offline_msg_schema(), TS) of
	{ok, Msg} ->
	    {ok, Msg};
	_ ->
	    error
    end;
read_message(_From, To, Seq, odbc) ->
    {LUser, LServer, _} = jid:tolower(To),
    Username = ejabberd_odbc:escape(LUser),
    SSeq = ejabberd_odbc:escape(Seq),
    case ejabberd_odbc:sql_query(
	   LServer,
	   [<<"select xml from spool  where username='">>, Username,
	    <<"'  and seq='">>, SSeq, <<"';">>]) of
	{selected, [<<"xml">>], [[RawXML]|_]} ->
	    case xml_stream:parse_element(RawXML) of
		#xmlel{} = El -> {ok, El};
		{error, _} -> error
	    end;
	_ ->
	    error
    end.

remove_message(_From, To, TS, mnesia) ->
    {U, S, _} = jid:tolower(To),
    Msgs = mnesia:dirty_match_object(
	     offline_msg, #offline_msg{us = {U, S}, timestamp = TS, _ = '_'}),
    lists:foreach(
      fun(Msg) ->
	      mnesia:dirty_delete_object(Msg)
      end, Msgs);
remove_message(_From, To, TS, p1db) ->
    {U, S, _} = jid:tolower(To),
    Key = usn2key(U, S, TS),
    p1db:delete(offline_msg, Key),
    ok;
remove_message(_From, _To, TS, riak) ->
    ejabberd_riak:delete(offline_msg, TS),
    ok;
remove_message(_From, To, Seq, odbc) ->
    {LUser, LServer, _} = jid:tolower(To),
    Username = ejabberd_odbc:escape(LUser),
    SSeq = ejabberd_odbc:escape(Seq),
    ejabberd_odbc:sql_query(
      LServer,
      [<<"delete from spool  where username='">>, Username,
       <<"'  and seq='">>, SSeq, <<"';">>]),
    ok.

read_all_msgs(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    lists:keysort(#offline_msg.timestamp,
		  mnesia:dirty_read({offline_msg, US}));
read_all_msgs(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, Val, _VClock}) ->
                      Now = key2now(USPrefix, Key),
                      USN = {LUser, LServer, Now},
                      p1db_to_offmsg(USN, Val)
              end, L);
        _Err ->
            []
    end;
read_all_msgs(LUser, LServer, riak) ->
    case ejabberd_riak:get_by_index(
           offline_msg, offline_msg_schema(),
	   <<"us">>, {LUser, LServer}) of
        {ok, Rs} ->
            lists:keysort(#offline_msg.timestamp, Rs);
        _Err ->
            []
    end;
read_all_msgs(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch ejabberd_odbc:sql_query(LServer,
				       [<<"select xml from spool  where username='">>,
					Username, <<"'  order by seq;">>])
	of
      {selected, [<<"xml">>], Rs} ->
	  lists:flatmap(fun ([XML]) ->
				case xml_stream:parse_element(XML) of
				  {error, _Reason} -> [];
				  El -> [El]
				end
			end,
			Rs);
      _ -> []
    end.

format_user_queue(Msgs, DBType)
  when DBType == mnesia; DBType == riak; DBType == p1db ->
    lists:map(fun (#offline_msg{timestamp = TimeStamp,
				from = From, to = To,
				packet =
				    #xmlel{name = Name, attrs = Attrs,
					   children = Els}} =
		       Msg) ->
		      ID = jlib:encode_base64((term_to_binary(Msg))),
		      {{Year, Month, Day}, {Hour, Minute, Second}} =
			  calendar:now_to_local_time(TimeStamp),
		      Time =
			  iolist_to_binary(io_lib:format("~w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w",
							 [Year, Month, Day,
							  Hour, Minute,
							  Second])),
		      SFrom = jid:to_string(From),
		      STo = jid:to_string(To),
		      Attrs2 = jlib:replace_from_to_attrs(SFrom, STo, Attrs),
		      Packet = #xmlel{name = Name, attrs = Attrs2,
				      children = Els},
		      FPacket = ejabberd_web_admin:pretty_print_xml(Packet),
		      ?XE(<<"tr">>,
			  [?XAE(<<"td">>, [{<<"class">>, <<"valign">>}],
				[?INPUT(<<"checkbox">>, <<"selected">>, ID)]),
			   ?XAC(<<"td">>, [{<<"class">>, <<"valign">>}], Time),
			   ?XAC(<<"td">>, [{<<"class">>, <<"valign">>}], SFrom),
			   ?XAC(<<"td">>, [{<<"class">>, <<"valign">>}], STo),
			   ?XAE(<<"td">>, [{<<"class">>, <<"valign">>}],
				[?XC(<<"pre">>, FPacket)])])
	      end,
	      Msgs);
format_user_queue(Msgs, odbc) ->
    lists:map(fun (#xmlel{} = Msg) ->
		      ID = jlib:encode_base64((term_to_binary(Msg))),
		      Packet = Msg,
		      FPacket = ejabberd_web_admin:pretty_print_xml(Packet),
		      ?XE(<<"tr">>,
			  [?XAE(<<"td">>, [{<<"class">>, <<"valign">>}],
				[?INPUT(<<"checkbox">>, <<"selected">>, ID)]),
			   ?XAE(<<"td">>, [{<<"class">>, <<"valign">>}],
				[?XC(<<"pre">>, FPacket)])])
	      end,
	      Msgs).

user_queue(User, Server, Query, Lang) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    US = {LUser, LServer},
    DBType = gen_mod:db_type(LServer, ?MODULE),
    Res = user_queue_parse_query(LUser, LServer, Query,
				 DBType),
    MsgsAll = read_all_msgs(LUser, LServer, DBType),
    Msgs = get_messages_subset(US, Server, MsgsAll,
			       DBType),
    FMsgs = format_user_queue(Msgs, DBType),
    [?XC(<<"h1">>,
	 list_to_binary(io_lib:format(?T(<<"~s's Offline Messages Queue">>),
                                      [us_to_list(US)])))]
      ++
      case Res of
	ok -> [?XREST(<<"Submitted">>)];
	nothing -> []
      end
	++
	[?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      [?XE(<<"table">>,
		   [?XE(<<"thead">>,
			[?XE(<<"tr">>,
			     [?X(<<"td">>), ?XCT(<<"td">>, <<"Time">>),
			      ?XCT(<<"td">>, <<"From">>),
			      ?XCT(<<"td">>, <<"To">>),
			      ?XCT(<<"td">>, <<"Packet">>)])]),
		    ?XE(<<"tbody">>,
			if FMsgs == [] ->
			       [?XE(<<"tr">>,
				    [?XAC(<<"td">>, [{<<"colspan">>, <<"4">>}],
					  <<" ">>)])];
			   true -> FMsgs
			end)]),
	       ?BR,
	       ?INPUTT(<<"submit">>, <<"delete">>,
		       <<"Delete Selected">>)])].

user_queue_parse_query(LUser, LServer, Query, mnesia) ->
    US = {LUser, LServer},
    case lists:keysearch(<<"delete">>, 1, Query) of
      {value, _} ->
	  Msgs = lists:keysort(#offline_msg.timestamp,
			       mnesia:dirty_read({offline_msg, US})),
	  F = fun () ->
		      lists:foreach(fun (Msg) ->
					    ID =
						jlib:encode_base64((term_to_binary(Msg))),
					    case lists:member({<<"selected">>,
							       ID},
							      Query)
						of
					      true -> mnesia:delete_object(Msg);
					      false -> ok
					    end
				    end,
				    Msgs)
	      end,
	  mnesia:transaction(F),
	  ok;
      false -> nothing
    end;
user_queue_parse_query(LUser, LServer, Query, p1db) ->
    case lists:keysearch(<<"delete">>, 1, Query) of
        {value, _} ->
            Msgs = read_all_msgs(LUser, LServer, p1db),
            lists:foreach(
              fun(#offline_msg{timestamp = Now} = Msg) ->
                      ID = jlib:encode_base64(term_to_binary(Msg)),
                      case lists:member({<<"selected">>, ID}, Query) of
                          true ->
                              USNKey = usn2key(LUser, LServer, Now),
                              p1db:delete(offline_msg, USNKey);
                          false ->
                              ok
                      end
              end, Msgs);
        false ->
            nothing
    end;
user_queue_parse_query(LUser, LServer, Query, riak) ->
    case lists:keysearch(<<"delete">>, 1, Query) of
        {value, _} ->
            Msgs = read_all_msgs(LUser, LServer, riak),
            lists:foreach(
              fun (Msg) ->
                      ID = jlib:encode_base64((term_to_binary(Msg))),
                      case lists:member({<<"selected">>, ID}, Query) of
                          true ->
                              ejabberd_riak:delete(offline_msg,
                                                   Msg#offline_msg.timestamp);
                          false ->
                              ok
                      end
              end,
              Msgs),
            ok;
        false ->
            nothing
    end;
user_queue_parse_query(LUser, LServer, Query, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case lists:keysearch(<<"delete">>, 1, Query) of
      {value, _} ->
	  Msgs = case catch ejabberd_odbc:sql_query(LServer,
						    [<<"select xml, seq from spool  where username='">>,
						     Username,
						     <<"'  order by seq;">>])
		     of
		   {selected, [<<"xml">>, <<"seq">>], Rs} ->
		       lists:flatmap(fun ([XML, Seq]) ->
					     case xml_stream:parse_element(XML)
						 of
					       {error, _Reason} -> [];
					       El -> [{El, Seq}]
					     end
				     end,
				     Rs);
		   _ -> []
		 end,
	  F = fun () ->
		      lists:foreach(fun ({Msg, Seq}) ->
					    ID =
						jlib:encode_base64((term_to_binary(Msg))),
					    case lists:member({<<"selected">>,
							       ID},
							      Query)
						of
					      true ->
						  SSeq =
						      ejabberd_odbc:escape(Seq),
						  catch
						    ejabberd_odbc:sql_query(LServer,
									    [<<"delete from spool  where username='">>,
									     Username,
									     <<"'  and seq='">>,
									     SSeq,
									     <<"';">>]);
					      false -> ok
					    end
				    end,
				    Msgs)
	      end,
	  mnesia:transaction(F),
	  ok;
      false -> nothing
    end.

us_to_list({User, Server}) ->
    jid:to_string({User, Server, <<"">>}).

get_queue_length(LUser, LServer) ->
    get_queue_length(LUser, LServer,
		     gen_mod:db_type(LServer, ?MODULE)).

get_queue_length(LUser, LServer, mnesia) ->
    length(mnesia:dirty_read({offline_msg,
			       {LUser, LServer}}));
get_queue_length(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:count_by_prefix(offline_msg, USPrefix) of
        {ok, N} -> N;
        _Err -> 0
    end;
get_queue_length(LUser, LServer, riak) ->
    case ejabberd_riak:count_by_index(offline_msg,
                                      <<"us">>, {LUser, LServer}) of
        {ok, N} ->
            N;
        _ ->
            0
    end;
get_queue_length(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch ejabberd_odbc:sql_query(LServer,
				       [<<"select count(*) from spool  where username='">>,
					Username, <<"';">>])
	of
      {selected, [_], [[SCount]]} ->
	  jlib:binary_to_integer(SCount);
      _ -> 0
    end.

get_messages_subset(User, Host, MsgsAll, DBType) ->
    Access = gen_mod:get_module_opt(Host, ?MODULE, access_max_user_messages,
                                    fun(A) when is_atom(A) -> A end,
				    max_user_offline_messages),
    MaxOfflineMsgs = case get_max_user_messages(Access,
						User, Host)
			 of
		       Number when is_integer(Number) -> Number;
		       _ -> 100
		     end,
    Length = length(MsgsAll),
    get_messages_subset2(MaxOfflineMsgs, Length, MsgsAll,
			 DBType).

get_messages_subset2(Max, Length, MsgsAll, _DBType)
    when Length =< Max * 2 ->
    MsgsAll;
get_messages_subset2(Max, Length, MsgsAll, DBType)
  when DBType == mnesia; DBType == riak; DBType == p1db ->
    FirstN = Max,
    {MsgsFirstN, Msgs2} = lists:split(FirstN, MsgsAll),
    MsgsLastN = lists:nthtail(Length - FirstN - FirstN,
			      Msgs2),
    NoJID = jid:make(<<"...">>, <<"...">>, <<"">>),
    IntermediateMsg = #offline_msg{timestamp = p1_time_compat:timestamp(),
				   from = NoJID, to = NoJID,
				   packet =
				       #xmlel{name = <<"...">>, attrs = [],
					      children = []}},
    MsgsFirstN ++ [IntermediateMsg] ++ MsgsLastN;
get_messages_subset2(Max, Length, MsgsAll, odbc) ->
    FirstN = Max,
    {MsgsFirstN, Msgs2} = lists:split(FirstN, MsgsAll),
    MsgsLastN = lists:nthtail(Length - FirstN - FirstN,
			      Msgs2),
    IntermediateMsg = #xmlel{name = <<"...">>, attrs = [],
			     children = []},
    MsgsFirstN ++ [IntermediateMsg] ++ MsgsLastN.

webadmin_user(Acc, User, Server, Lang) ->
    QueueLen = get_queue_length(jid:nodeprep(User),
				jid:nameprep(Server)),
    FQueueLen = [?AC(<<"queue/">>,
		     (iolist_to_binary(integer_to_list(QueueLen))))],
    Acc ++
      [?XCT(<<"h3">>, <<"Offline Messages:">>)] ++
	FQueueLen ++
	  [?C(<<" ">>),
	   ?INPUTT(<<"submit">>, <<"removealloffline">>,
		   <<"Remove All Offline Messages">>)].

delete_all_msgs(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    delete_all_msgs(LUser, LServer,
		    gen_mod:db_type(LServer, ?MODULE)).

delete_all_msgs(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    F = fun () ->
		mnesia:write_lock_table(offline_msg),
		lists:foreach(fun (Msg) -> mnesia:delete_object(Msg)
			      end,
			      mnesia:dirty_read({offline_msg, US}))
	end,
    mnesia:transaction(F);
delete_all_msgs(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(offline_msg, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _Val, _VClock}) ->
                      p1db:delete(offline_msg, Key)
              end, L),
            {atomic, ok};
        Err ->
            {aborted, Err}
    end;
delete_all_msgs(LUser, LServer, riak) ->
    Res = ejabberd_riak:delete_by_index(offline_msg,
                                        <<"us">>, {LUser, LServer}),
    {atomic, Res};
delete_all_msgs(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    odbc_queries:del_spool_msg(LServer, Username),
    {atomic, ok};

delete_all_msgs(LUser, LServer, rest) ->
    Path = offline_rest_path(LUser, LServer),
    case rest:with_retry(delete, [LServer, Path], 2, 500) of
        {ok, 200, _ } ->
            {atomic, ok};
        Error ->
            {aborder, Error}
    end.

webadmin_user_parse_query(_, <<"removealloffline">>,
			  User, Server, _Query) ->
    case delete_all_msgs(User, Server) of
      {aborted, Reason} ->
	  ?ERROR_MSG("Failed to remove offline messages: ~p",
		     [Reason]),
	  {stop, error};
      {atomic, ok} ->
	  ?INFO_MSG("Removed all offline messages for ~s@~s",
		    [User, Server]),
	  {stop, ok}
    end;
webadmin_user_parse_query(Acc, _Action, _User, _Server,
			  _Query) ->
    Acc.

%% Returns as integer the number of offline messages for a given user
count_offline_messages(User, Server) ->
    LUser = jid:nodeprep(User),
    LServer = jid:nameprep(Server),
    DBType = gen_mod:db_type(LServer, ?MODULE),
    count_offline_messages(LUser, LServer, DBType).

count_offline_messages(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    F = fun () ->
		count_mnesia_records(US)
	end,
    case catch mnesia:async_dirty(F) of
      I when is_integer(I) -> I;
      _ -> 0
    end;
count_offline_messages(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch odbc_queries:count_records_where(LServer,
						<<"spool">>,
						<<"where username='",
						  Username/binary, "'">>)
	of
      {selected, [_], [[Res]]} ->
	  jlib:binary_to_integer(Res);
      _ -> 0
    end;
count_offline_messages(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:count_by_prefix(offline_msg, USPrefix) of
        {ok, N} -> N;
        _Err -> 0
    end;
count_offline_messages(LUser, LServer, riak) ->
    case ejabberd_riak:count_by_index(
           offline_msg, <<"us">>, {LUser, LServer}) of
        {ok, Res} ->
            Res;
        _ ->
            0
    end;
count_offline_messages(LUser, LServer, rest) ->
    Path = offline_rest_path(LUser, LServer, <<"count">>),
    case rest:with_retry(get, [LServer, Path], 2, 500) of
        {ok, 200, {Resp}}  ->
            proplists:get_value(<<"count">>, Resp, []);
        Other ->
            ?ERROR_MSG("Unexpected response for offline count: ~p", [Other]),
            0
    end;

count_offline_messages(_Acc, User, Server) ->
    N = count_offline_messages(User, Server),
    {stop, N}.

%% Return the number of records matching a given match expression.
%% This function is intended to be used inside a Mnesia transaction.
%% The count has been written to use the fewest possible memory by
%% getting the record by small increment and by using continuation.
-define(BATCHSIZE, 100).

count_mnesia_records(US) ->
    MatchExpression = #offline_msg{us = US,  _ = '_'},
    case mnesia:select(offline_msg, [{MatchExpression, [], [[]]}],
		       ?BATCHSIZE, read) of
	{Result, Cont} ->
	    Count = length(Result),
	    count_records_cont(Cont, Count);
	'$end_of_table' ->
	    0
    end.

count_records_cont(Cont, Count) ->
    case mnesia:select(Cont) of
	{Result, Cont} ->
	    NewCount = Count + length(Result),
	    count_records_cont(Cont, NewCount);
	'$end_of_table' ->
	    Count
    end.

offline_msg_schema() ->
    {record_info(fields, offline_msg), #offline_msg{}}.

offline_rest_path(User, Server) ->
    Base = ejabberd_config:get_option({ext_api_path_offline, Server},
                                      fun(X) -> iolist_to_binary(X) end,
                                      <<"/offline">>),
    <<Base/binary, "/", User/binary>>.
offline_rest_path(User, Server, Path) ->
    Base = offline_rest_path(User, Server),
    <<Base/binary, "/", Path/binary>>.

us2key(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary>>.

usn2key(LUser, LServer, Now) ->
    TimeStamp = now2ts(Now),
    USKey = us2key(LUser, LServer),
    <<USKey/binary, 0, TimeStamp:64>>.

key2now(USPrefix, Key) ->
    Size = size(USPrefix),
    <<_:Size/binary, TimeStamp:64>> = Key,
    ts2now(TimeStamp).

us_prefix(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    <<USKey/binary, 0>>.

ts2now(TimeStamp) ->
    MSecs = TimeStamp div 1000000,
    USecs = TimeStamp rem 1000000,
    MegaSecs = MSecs div 1000000,
    Secs = MSecs rem 1000000,
    {MegaSecs, Secs, USecs}.

now2ts({MegaSecs, Secs, USecs}) ->
    (MegaSecs*1000000 + Secs)*1000000 + USecs.

p1db_to_offmsg({LUser, LServer, Now}, Val) ->
    OffMsg0 = #offline_msg{us = {LUser, LServer},
                           timestamp = Now},
    OffMsg = lists:foldl(
               fun({packet, Pkt}, M) -> M#offline_msg{packet = Pkt};
                  ({expire, Expire}, M) -> M#offline_msg{expire = Expire};
                  (_, M) -> M
               end, OffMsg0, binary_to_term(Val)),
    El = OffMsg#offline_msg.packet,
    #jid{} = To = jid:from_string(xml:get_tag_attr_s(<<"to">>, El)),
    #jid{} = From = jid:from_string(xml:get_tag_attr_s(<<"from">>, El)),
    OffMsg#offline_msg{from = From, to = To}.

offmsg_to_p1db(#offline_msg{packet = Pkt, expire = T}) ->
    term_to_binary([{packet, Pkt}, {expire, T}]).

%% P1DB/SQL schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, TS]) ->
    <<Server/binary, 0, User/binary, 0, TS:64>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, TS:64>> = UKey,
    [Server, User, TS].

enc_val(_, [SExpire, SPacket]) ->
    Expire = case SExpire of
                 <<"never">> -> never;
                 _ -> ts2now(SExpire)
             end,
    #xmlel{} = Packet = xml_stream:parse_element(SPacket),
    offmsg_to_p1db(#offline_msg{packet = Packet, expire = Expire}).

dec_val([Server, User, TS], Bin) ->
    #offline_msg{packet  = Packet,
                 expire = Expire}
        = p1db_to_offmsg({User, Server, ts2now(TS)}, Bin),
    SExpire = case Expire of
                  never -> <<"never">>;
                  _ -> now2ts(Expire)
              end,
    [SExpire, xml:element_to_binary(Packet)].

export(_Server) ->
    [{offline_msg,
      fun(Host, #offline_msg{us = {LUser, LServer},
                             timestamp = TimeStamp, from = From, to = To,
                             packet = Packet})
            when LServer == Host ->
              Username = ejabberd_odbc:escape(LUser),
              Packet1 = jlib:replace_from_to(From, To, Packet),
              Packet2 = jlib:add_delay_info(Packet1, LServer, TimeStamp,
                                            <<"Offline Storage">>),
              XML = ejabberd_odbc:escape(xml:element_to_binary(Packet2)),
              [[<<"delete from spool where username='">>, Username, <<"';">>],
               [<<"insert into spool(username, xml) values ('">>,
                Username, <<"', '">>, XML, <<"');">>]];
         (_Host, _R) ->
              []
      end}].

import_info() ->
    [{<<"spool">>, 4}].

import_start(LServer, DBType) ->
    init_db(DBType, LServer).

import(LServer, {odbc, _}, DBType, <<"spool">>,
       [LUser, XML, _Seq, _TimeStamp]) ->
    El = #xmlel{} = xml_stream:parse_element(XML),
    From = #jid{} = jid:from_string(
                      xml:get_attr_s(<<"from">>, El#xmlel.attrs)),
    To = #jid{} = jid:from_string(
                    xml:get_attr_s(<<"to">>, El#xmlel.attrs)),
    Stamp = xml:get_path_s(El, [{elem, <<"delay">>},
                                {attr, <<"stamp">>}]),
    TS = case jlib:datetime_string_to_timestamp(Stamp) of
             {MegaSecs, Secs, _} ->
                 {MegaSecs, Secs, 0};
             undefined ->
                 p1_time_compat:timestamp()
         end,
    US = {LUser, LServer},
    Expire = find_x_expire(TS, El#xmlel.children),
    Msg = #offline_msg{us = US, packet = El,
                       from = From, to = To,
                       timestamp = TS, expire = Expire},
    case DBType of
        mnesia ->
            mnesia:dirty_write(Msg);
        riak ->
            ejabberd_riak:put(Msg, offline_msg_schema(),
			      [{i, TS}, {'2i', [{<<"us">>, US}]}]);
        p1db ->
            USNKey = usn2key(LUser, LServer, TS),
            p1db:async_insert(offline_msg, USNKey, offmsg_to_p1db(Msg));
        odbc ->
            ok
    end.

mod_opt_type(access_max_user_messages) ->
    fun (A) when is_atom(A) -> A end;
mod_opt_type(db_type) -> fun gen_mod:v_db/1;
mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(pool_size) ->
    fun (N) when is_integer(N) -> N end;
mod_opt_type(store_empty_body) ->
    fun (V) when is_boolean(V) -> V;
        (unless_chat_state) -> unless_chat_state
    end;
mod_opt_type(_) ->
    [access_max_user_messages, db_type, p1db_group,
     pool_size, store_empty_body].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
