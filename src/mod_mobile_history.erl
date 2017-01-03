%%%----------------------------------------------------------------------
%%% File    : mod_mobile_history.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Support mobile archiving
%%% Created : 10 Sep 2013 by Christophe Romain <christophe.romain@process-one.net>
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

-module(mod_mobile_history).

-export([start/2, stop/1]).

-export([log_out/4, log_message_to_user/3,
	 process_sm_iq/3, remove_user/2]).

-export([get_user_history/4, parse_read_notification/1,
	 mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").


-define(PROC_LOG_MSG, <<"log_msg">>).

-define(PROC_SET_READ, <<"set_read">>).

-define(PROC_SET_DELIVER_STATUS,
	<<"set_deliver_status">>).

-define(PROC_REMOVE_CONVERSATION_HISTORY,
	<<"remove_conversation_history">>).

-define(PROC_REMOVE_USER_HISTORY,
	<<"remove_user_history">>).

start(Host, Opts) ->
    ejabberd_hooks:add(user_send_packet, Host, ?MODULE,
		       log_out, 90),
    ejabberd_hooks:add(message_to_user, Host, ?MODULE,
		       log_message_to_user, 100),
    IQDisc = gen_mod:get_opt(iqdisc, Opts, fun gen_iq_handler:check_type/1, one_queue),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_P1_HISTORY, ?MODULE, process_sm_iq,
				  IQDisc),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host, ?MODULE,
			  log_out, 90),
    ejabberd_hooks:delete(message_to_user, Host, ?MODULE,
			  log_message_to_user, 100),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host,
				     ?NS_P1_HISTORY),
    ok.

to_binary(X) when is_binary(X) -> X;
to_binary(X) when is_list(X) -> list_to_binary(X).

get_pool_name_for(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, connection_pool, fun to_binary/1, Host).



remove_user(User, Server) ->
    remove_all_history(jid:make(User, Server, <<"">>)).

log_out( #xmlel{name = <<"message">>, attrs = Attrs} = OrigPacket,
            _C2SState, From, To) ->
    case filter_chat_packet(OrigPacket) of
      true ->
	  Packet = fxml:replace_tag_attr(<<"from">>,
					jid:to_string(jid:remove_resource(From)),
					OrigPacket),
	  Collection = get_collection(From, To, Packet),
	  Timestamp = get_datetime_string_for_db(p1_time_compat:timestamp()),
	  ID = fxml:get_attr_s(<<"id">>, Attrs),
	  JID =
	      ejabberd_sql:escape(jid:to_string(jid:remove_resource(From))),
	  Text =
	      ejabberd_sql:escape(fxml:element_to_binary(Packet)),
	  Query = [<<"CALL ">>, log_msg(From#jid.lserver),
		   <<"('">>, JID, <<"','">>, JID, <<"','">>,
		   ejabberd_sql:escape(Collection), <<"','">>,
		   ejabberd_sql:escape(ID), <<"','">>, Text, <<"','">>,
		   ejabberd_sql:escape(Timestamp), <<"', true)">>],
	  case ejabberd_sql:sql_query(get_pool_name_for(From#jid.server),
				  lists:flatten(Query)) of
            {error, Cause} ->
                ?ERROR_MSG("Error storing history message sent by ~p to ~p: ~p", [jid:to_string(From), jid:to_string(To), Cause]);
            _ ->
                ok
        end;
      false ->
	  Timestamp = get_datetime_string_for_db(p1_time_compat:timestamp()),
	  case parse_read_notification(OrigPacket) of
	    {read, ID} ->
		JID =
		    ejabberd_sql:escape(jid:to_string(jid:remove_resource(From))),
		Query = [<<"CALL ">>, set_read(From#jid.lserver),
			 <<"('">>, JID, <<"','">>, ejabberd_sql:escape(ID),
			 <<"', '">>, ejabberd_sql:escape(Timestamp), <<"')">>],
		case ejabberd_sql:sql_query(get_pool_name_for(From#jid.server),
					lists:flatten(Query)) of
                {error, Cause} ->
                    ?ERROR_MSG("Error storing read notification for user ~p,  message ~p : ~p", [JID, ID, Cause]);
                _ ->
                    ok
            end;
	    false -> ok
	  end
    end,
    OrigPacket;
log_out(Packet, _C2SState,_From, _To) -> Packet.

get_collection(From, To, Packet) ->
    str:join(lists:usort([jid:to_string(jid:remove_resource(From))
			  | get_target(To, Packet)]),
	     <<":">>).

get_datetime_string_for_db({MegaSecs, Secs,
			    MicroSecs}) ->
    {{Year, Month, Day}, {Hour, Minute, Second}} =
	calendar:now_to_universal_time({MegaSecs, Secs,
					MicroSecs}),
    iolist_to_binary(io_lib:format("~4..0w-~2..0w-~2..0w ~2..0w:~2..0w:~2..0w",
				   [Year, Month, Day, Hour, Minute, Second])).

get_target(To, Packet) ->
    case fxml:get_subtag(Packet, <<"addresses">>) of
      #xmlel{name = <<"addresses">>, attrs = AAttrs,
	     children = Addresses} ->
	  case fxml:get_attr_s(<<"xmlns">>, AAttrs) of
	    ?NS_ADDRESS ->
		[fxml:get_attr_s(<<"jid">>, Attrs)
		 || #xmlel{name = <<"address">>, attrs = Attrs}
			<- Addresses];
	    _ -> [jid:to_string(jid:remove_resource(To))]
	  end;
      _ -> [jid:to_string(jid:remove_resource(To))]
    end.

parse_read_notification(Packet) ->
    case fxml:get_subtag(Packet, <<"read">>) of
      #xmlel{name = <<"read">>, attrs = AAttrs} ->
	  case fxml:get_attr_s(<<"xmlns">>, AAttrs) of
	    ?NS_RECEIPTS ->
		{read, fxml:get_attr_s(<<"id">>, AAttrs)};
	    _ -> false
	  end;
      _ -> false
    end.

filter_chat_packet(#xmlel{name = <<"message">>,
			  attrs = Attrs} =
		       Msg) ->
    case fxml:get_attr_s(<<"type">>, Attrs) of
      <<"chat">> ->
	  fxml:get_subtag(Msg, <<"body">>) /= false orelse
	    fxml:get_subtag(Msg, <<"x">>) /= false;
      _ -> false
    end.

is_delayed(Packet) ->
    case fxml:get_subtag(Packet, <<"delay">>) of
      #xmlel{name = <<"delay">>, attrs = AAttrs} ->
	  case fxml:get_attr_s(<<"xmlns">>, AAttrs) of
	    ?NS_DELAY -> true;
	    _ -> false
	  end;
      _ -> false
    end.

is_pushed(#xmlel{name = <<"message">>,
		 children = Els}) ->
    [1
     || #xmlel{name = <<"x">>, attrs = Attrs} <- Els,
	fxml:get_attr_s(<<"xmlns">>, Attrs) == (?NS_P1_PUSHED)]
      /= [].

log_message_to_user(From, To,
		    #xmlel{name = <<"message">>, attrs = Attrs} =
			OrigPacket) ->
    case filter_chat_packet(OrigPacket) andalso
	   not is_delayed(OrigPacket) andalso
	     not is_pushed(OrigPacket) andalso
	       not mod_carboncopy:is_carbon_copy(OrigPacket)
	of
      true ->
	  Packet = fxml:replace_tag_attr(<<"from">>,
					jid:to_string(jid:remove_resource(From)),
					OrigPacket),
	  Collection = get_collection(From, To, Packet),
	  Timestamp = get_datetime_string_for_db(p1_time_compat:timestamp()),
	  ID = fxml:get_attr_s(<<"id">>, Attrs),
	  JIDTo =
	      ejabberd_sql:escape(jid:to_string(jid:remove_resource(To))),
	  JIDFrom =
	      ejabberd_sql:escape(jid:to_string(jid:remove_resource(From))),
	  Text =
	      ejabberd_sql:escape(fxml:element_to_binary(Packet)),
	  Query = [<<"CALL ">>, log_msg(To#jid.lserver), <<"('">>,
		   JIDTo, <<"','">>, JIDFrom, <<"','">>,
		   ejabberd_sql:escape(Collection), <<"','">>,
		   ejabberd_sql:escape(ID), <<"','">>, Text, <<"','">>,
		   ejabberd_sql:escape(Timestamp), <<"', false)">>],
	  case ejabberd_sql:sql_query(get_pool_name_for(To#jid.server),
				  lists:flatten(Query)) of
            {error, Cause} ->
                ?ERROR_MSG("Error storing history message received by ~p from ~p: ~p", [jid:to_string(To), jid:to_string(From), Cause]);
            _ ->
                ok
        end;
      false ->
	  case parse_receipt_response(OrigPacket) of
	    {ok, MsgID, Status}
		when Status /= <<"on-sender-server">> ->
		JIDTo =
		    ejabberd_sql:escape(jid:to_string(jid:remove_resource(To))),
		Timestamp =
		    ejabberd_sql:escape(get_datetime_string_for_db(p1_time_compat:timestamp())),
		Query = [<<"CALL ">>,
			 set_deliver_status(To#jid.lserver), <<"('">>, JIDTo,
			 <<"','">>, ejabberd_sql:escape(MsgID), <<"','">>,
			 ejabberd_sql:escape(Status), <<"','">>, Timestamp,
			 <<"')">>],
	    case ejabberd_sql:sql_query(get_pool_name_for(To#jid.server),
					lists:flatten(Query)) of
                {error, Cause} ->
                    ?ERROR_MSG("Error storing delivery notification for user ~p,  message ~p : ~p", [JIDTo, MsgID, Cause]);
                _ ->
                    ok
            end;
	    _ -> ok
	  end
    end;
log_message_to_user(_From, _To, _Packet) -> ok.

parse_receipt_response(#xmlel{name = <<"message">>,
			      children = Children}) ->
    case fxml:remove_cdata(Children) of
      [#xmlel{name = Status, attrs = Attrs}] ->
	  case fxml:get_attr_s(<<"xmlns">>, Attrs) of
	    ?NS_RECEIPTS ->
		{ok, fxml:get_attr_s(<<"id">>, Attrs), Status};
	    _ -> false
	  end;
      _ -> false
    end;
parse_receipt_response(_) -> false.

normalize_rsm_in(#rsm_in{id = undefined} = R) ->
    normalize_rsm_in(R#rsm_in{id = <<"0">>});
normalize_rsm_in(#rsm_in{max = undefined} = R) ->
    normalize_rsm_in(R#rsm_in{max = 50});
normalize_rsm_in(R) -> R.

process_sm_iq(From, _To,
	      #iq{type = get, sub_el = El} = IQ) ->
    Date = fxml:get_tag_attr_s(<<"start">>, El),
    {Max, Index} = case normalize_rsm_in(jlib:rsm_decode(IQ)) of
                       none ->
                           {50, 0};
                       #rsm_in{max = M, id = I} ->
                           {M, jlib:binary_to_integer(I)}
                   end,
    {History, Count} = get_user_history(From, Date, Index, Max),
    Res = [#xmlel{name = <<"history">>,
		  attrs =
		      [{<<"read">>,
			iolist_to_binary(atom_to_list(Read == <<"1">>))},
		       {<<"at">>, db_datetime_to_iso(At)},
		       {<<"deliver-status">>, DeliverStatus}],
		  children = parse_message_from_db(From, At, Message)}
	   || [Message, At, Read, DeliverStatus] <- History],
    RsmOut = jlib:rsm_encode(#rsm_out{first =
					  iolist_to_binary(integer_to_list(Index)),
				      count = Count,
				      last =
					  iolist_to_binary(integer_to_list(Index+length(History)))}),
    #xmlel{name = <<"retrieve">>, attrs = Attrs} = El,
    IQ#iq{type = result,
	  sub_el =
	      [#xmlel{name = <<"retrieve">>, attrs = Attrs,
		      children = Res ++ RsmOut}]};
process_sm_iq(From, _To,
	      #iq{type = set,
		  sub_el =
		      #xmlel{name = <<"remove-conversation">>,
			     attrs = Attrs} =
			  SubEl} =
		  IQ) ->
    Conversation = fxml:get_attr_s(<<"conversation">>,
				  Attrs),
    case remove_conversation(From, Conversation) of
      error ->
	  IQ#iq{type = error,
		sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]};
      ok -> IQ#iq{type = result, sub_el = []}
    end;
process_sm_iq(From, _To,
	      #iq{type = set,
		  sub_el = #xmlel{name = <<"remove-all">>} = SubEl} =
		  IQ) ->
    case remove_all_history(From) of
      error ->
	  IQ#iq{type = error,
		sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]};
      ok -> IQ#iq{type = result, sub_el = []}
    end;
process_sm_iq(_From, _To, #iq{sub_el = SubEl} = IQ) ->
    IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]}.

parse_message_from_db(User, At, Message) ->
    case fxml_stream:parse_element(Message) of
      {error, Error} ->
	  ?ERROR_MSG("Error parsing message from DB. User:~p "
		     "Message: ~p  At: ~p Error:~p",
		     [jid:to_string(jid:remove_resource(User)),
		      Message, At, Error]),
	  [];
      El -> [El]
    end.

get_user_history(JID, StartingDate, Index, Max) ->
    Date =
	get_datetime_string_for_db(jlib:datetime_string_to_timestamp(StartingDate)),
    JIDStr =
	jid:to_string(jid:remove_resource(JID)),
    Query = [<<"SELECT SQL_CALC_FOUND_ROWS message, "
	       "at, is_read, deliver_status FROM messages_vie"
	       "w WHERE jid='">>,
	     ejabberd_sql:escape(JIDStr), <<"' AND modified > '">>,
	     ejabberd_sql:escape(Date),
	     <<"' ORDER BY at ASC LIMIT ">>,
	     iolist_to_binary(integer_to_list(Index)), <<",">>,
	     iolist_to_binary(integer_to_list(Max))],
    {atomic, {Rows, Count}} =
	ejabberd_sql:sql_bloc(get_pool_name_for(JID#jid.server),
			       fun () ->
				       {selected, _, Rows} =
					   ejabberd_sql:sql_query_t(lists:flatten(Query)),
                                       {selected, _, [[Count]]} = ejabberd_sql:sql_query_t([<<"SELECT FOUND_ROWS()">>]),
				       {Rows, jlib:binary_to_integer(Count)}
			       end),
    {Rows, Count}.

remove_conversation(JID, Conversation) ->
    JIDStr =
	jid:to_string(jid:remove_resource(JID)),
    Query = [<<"CALL ">>,
	     remove_conversation_history(JID#jid.lserver), <<"('">>,
	     ejabberd_sql:escape(JIDStr), <<"','">>,
	     ejabberd_sql:escape(Conversation), <<"')">>],
    case ejabberd_sql:sql_query(get_pool_name_for(JID#jid.server),
				 lists:flatten(Query))
	of
      {error, Cause} ->
	  ?ERROR_MSG("Error removing conversation ~p for user "
		     "~p: ~p",
		     [Conversation, JIDStr, Cause]),
	  error;
      {updated, _} -> ok
    end.

remove_all_history(JID) ->
    JIDStr =
	jid:to_string(jid:remove_resource(JID)),
    Query = [<<"CALL ">>,
	     remove_user_history(JID#jid.lserver), <<"('">>, JIDStr,
	     <<"')">>],
    case ejabberd_sql:sql_query(get_pool_name_for(JID#jid.server),
				 lists:flatten(Query))
	of
      {error, Cause} ->
	  ?ERROR_MSG("Error removing user history ~p: ~p",
		     [JIDStr, Cause]),
	  error;
      {updated, _} -> ok
    end.

db_datetime_to_iso(String) ->
    [Date, Time] = str:tokens(String, <<" ">>),
    [Y, M, D] = str:tokens(Date, <<"-">>),
    [HH, MM, SS] = str:tokens(Time, <<":">>),
    {T, Tz} =
	jlib:timestamp_to_iso({{jlib:binary_to_integer(Y),
				jlib:binary_to_integer(M),
				jlib:binary_to_integer(D)},
			       {jlib:binary_to_integer(HH),
				jlib:binary_to_integer(MM),
				jlib:binary_to_integer(SS)}},
			      utc),
    <<T/binary, Tz/binary>>.

log_msg(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, proc_log_msg, fun(X) -> X end,
			   ?PROC_LOG_MSG).

set_read(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, proc_set_read, fun(X) -> X end,
			   ?PROC_SET_READ).

set_deliver_status(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, proc_set_deliver_status,  fun(X) -> X end,
        ?PROC_SET_DELIVER_STATUS).

remove_conversation_history(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, proc_remove_conversation_history, fun(X) -> X end,
			   ?PROC_REMOVE_CONVERSATION_HISTORY).

remove_user_history(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, proc_remove_user_history, fun(X) -> X end,
        ?PROC_REMOVE_USER_HISTORY).

%ejabberd_sql:sql_query(Host, "CALL log_msg(JID, Sender, Collection, ID, Packet, Date, false)");
%ejabberd_sql:sql_query(Host, "CALL set_read(JID, ID)");

%"SELECT * from message_view where user=user and at >= date offset = ? limit = ?"

mod_opt_type(connection_pool) -> fun to_binary/1;
mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(proc_log_msg) -> fun (X) -> X end;
mod_opt_type(proc_remove_conversation_history) ->
    fun (X) -> X end;
mod_opt_type(proc_remove_user_history) ->
    fun (X) -> X end;
mod_opt_type(proc_set_deliver_status) ->
    fun (X) -> X end;
mod_opt_type(proc_set_read) -> fun (X) -> X end;
mod_opt_type(_) ->
    [connection_pool, iqdisc, proc_log_msg,
     proc_remove_conversation_history,
     proc_remove_user_history, proc_set_deliver_status,
     proc_set_read].
