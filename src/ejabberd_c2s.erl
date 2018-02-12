%%%----------------------------------------------------------------------
%%% File    : ejabberd_c2s.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Serve C2S connection
%%% Created : 16 Nov 2002 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_c2s).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-protocol({xep, 78, '2.5'}).
-protocol({xep, 138, '2.0'}).
-protocol({xep, 178, '1.1'}).
-protocol({xep, 198, '1.3'}).

-update_info({update, 0}).

-define(GEN_FSM, p1_fsm).

-behaviour(?GEN_FSM).

%% External exports
-export([start/2, stop_or_detach/1, start_link/3, close/1,
	 send_text/2, send_element/2, send_filtered/5,
	 get_aux_field/2, set_aux_field/3, del_aux_field/2,
	 get_presence/1, get_subscription/2, get_subscribed/1,
	 broadcast/4, transform_listen_option/2,
	 socket_type/0, is_remote_socket/1]).

-export([init/1, wakeup/2, wait_for_stream/2, wait_for_stream/3,
	 wait_for_auth/2, wait_for_auth/3,
	 wait_for_feature_request/2, wait_for_feature_request/3,
	 wait_for_bind/2, wait_for_bind/3,
	 wait_for_sasl_response/2,
	 wait_for_sasl_response/3, wait_for_resume/2,
	 session_established/2, session_established/3,
	 handle_event/3, handle_sync_event/4, code_change/4,
	 handle_info/3, terminate/3, print_state/1, migrate/3,
	 opt_type/1]).

%% API:
-export([add_rosteritem/3, del_rosteritem/2]).

-include("licence.hrl").
-include("ejabberd.hrl").
-include("logger.hrl").
-include_lib("public_key/include/public_key.hrl").
-include("OCSP.hrl").
-include("jlib.hrl").

-include("mod_privacy.hrl").

-include("ejabberd_c2s.hrl").

%%-define(DBGFSM, true).

-ifdef(DBGFSM).
-define(FSMOPTS, [{debug, [trace]}]).
-else.
-define(FSMOPTS, []).
-endif.

%% This is the timeout to apply between event when starting a new
%% session:
-define(C2S_OPEN_TIMEOUT, 60000).
-define(C2S_HIBERNATE_TIMEOUT, ejabberd_config:get_option(c2s_hibernate, fun(X) when is_integer(X); X == hibernate-> X end, 90000)).

%% Define jabs increment while hibernated (1 jabs every every X minutes)
-define(C2S_HIBERNATED_ACTIVITY, 15).

-define(STREAM_HEADER,
	<<"<?xml version='1.0'?><stream:stream "
	  "xmlns='jabber:client' xmlns:stream='http://et"
	  "herx.jabber.org/streams' id='~s' from='~s'~s"
	  "~s>">>).

-define(FLASH_STREAM_HEADER,
	<<"<?xml version='1.0'?><flash:stream xmlns='jab"
	  "ber:client' xmlns:stream='http://etherx.jabbe"
	  "r.org/streams' id='~s' from='~s'~s~s>">>).

-define(STREAM_TRAILER, <<"</stream:stream>">>).

-define(INVALID_NS_ERR, ?SERR_INVALID_NAMESPACE).

-define(INVALID_XML_ERR, ?SERR_XML_NOT_WELL_FORMED).

-define(HOST_UNKNOWN_ERR, ?SERR_HOST_UNKNOWN).

-define(POLICY_VIOLATION_ERR(Lang, Text),
	?SERRT_POLICY_VIOLATION(Lang, Text)).

-define(INVALID_FROM, ?SERR_INVALID_FROM).

%% XEP-0198:

-define(IS_STREAM_MGMT_TAG(Name),
	(Name == <<"enable">>) or
				 (Name == <<"resume">>) or
							  (Name == <<"a">>) or
									      (Name == <<"r">>)).

-define(IS_SUPPORTED_MGMT_XMLNS(Xmlns),
	(Xmlns == ?NS_STREAM_MGMT_2) or
				       (Xmlns == ?NS_STREAM_MGMT_3)).

-define(MGMT_FAILED(Condition, Attrs),
	#xmlel{name = <<"failed">>,
	       attrs = Attrs,
	       children = [#xmlel{name = Condition,
				  attrs = [{<<"xmlns">>, ?NS_STANZAS}],
				  children = []}]}).

-define(MGMT_BAD_REQUEST(Xmlns),
	?MGMT_FAILED(<<"bad-request">>, [{<<"xmlns">>, Xmlns}])).

-define(MGMT_SERVICE_UNAVAILABLE(Xmlns),
	?MGMT_FAILED(<<"service-unavailable">>, [{<<"xmlns">>, Xmlns}])).

-define(MGMT_UNEXPECTED_REQUEST(Xmlns),
	?MGMT_FAILED(<<"unexpected-request">>, [{<<"xmlns">>, Xmlns}])).

-define(MGMT_UNSUPPORTED_VERSION(Xmlns),
	?MGMT_FAILED(<<"unsupported-version">>, [{<<"xmlns">>, Xmlns}])).

-define(MGMT_ITEM_NOT_FOUND(Xmlns),
	?MGMT_FAILED(<<"item-not-found">>, [{<<"xmlns">>, Xmlns}])).

-define(MGMT_ITEM_NOT_FOUND_H(Xmlns, NumStanzasIn),
	?MGMT_FAILED(<<"item-not-found">>,
		     [{<<"xmlns">>, Xmlns},
		      {<<"h">>, jlib:integer_to_binary(NumStanzasIn)}])).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
start(StateName, #state{fsm_limit_opts = Opts} = State) ->
    start(StateName, State, Opts);
start(SockData, Opts) ->
    start(SockData, Opts, fsm_limit_opts(Opts)).

start(SockData, Opts, FSMLimitOpts) ->
    (?GEN_FSM):start(ejabberd_c2s,
		     [SockData, Opts, FSMLimitOpts],
		     FSMLimitOpts ++ (?FSMOPTS)).

start_link(SockData, Opts, FSMLimitOpts) ->
    (?GEN_FSM):start_link(ejabberd_c2s,
			  [SockData, Opts, FSMLimitOpts],
			  FSMLimitOpts ++ (?FSMOPTS)).

socket_type() -> xml_stream.

%% Return Username, Resource and presence information
get_presence(FsmRef) ->
    (?GEN_FSM):sync_send_all_state_event(FsmRef,
					 {get_presence}, 1000).

add_rosteritem(FsmRef, IJID, ISubscription) ->
    (?GEN_FSM):send_all_state_event(FsmRef,
				    {add_rosteritem, IJID, ISubscription}).

del_rosteritem(FsmRef, IJID) ->
    (?GEN_FSM):send_all_state_event(FsmRef,
				    {del_rosteritem, IJID}).

get_aux_field(Key, #state{aux_fields = Opts}) ->
    case lists:keysearch(Key, 1, Opts) of
	{value, {_, Val}} -> {ok, Val};
	_ -> error
    end.

set_aux_field(Key, Val, #state{aux_fields = Opts} = State) ->
    Opts1 = lists:keydelete(Key, 1, Opts),
    State#state{aux_fields = [{Key, Val} | Opts1]}.

del_aux_field(Key, #state{aux_fields = Opts} = State) ->
    Opts1 = lists:keydelete(Key, 1, Opts),
    State#state{aux_fields = Opts1}.

get_subscription(From = #jid{}, StateData) ->
    get_subscription(jid:tolower(From), StateData);
get_subscription(LFrom, StateData) ->
    LBFrom = setelement(3, LFrom, <<"">>),
    F = (?SETS):is_element(LFrom, StateData#state.pres_f)
	orelse (?SETS):is_element(LBFrom, StateData#state.pres_f),
    T = (?SETS):is_element(LFrom, StateData#state.pres_t)
	orelse (?SETS):is_element(LBFrom, StateData#state.pres_t),
    if F and T -> both;
       F -> from;
       T -> to;
       true -> none
    end.

send_filtered(FsmRef, Feature, From, To, Packet) ->
    FsmRef ! {send_filtered, Feature, From, To, Packet}.

broadcast(FsmRef, Type, From, Packet) ->
    FsmRef ! {broadcast, Type, From, Packet}.

%% Used by mod_ack and mod_ping.
%% If the client is not oor capable, we must stop the session,
%% and be sure to not return until the c2s process has really stopped. This
%% is to avoid race conditions when resending messages in mod_ack (EJABS-1677).
%% In the other side, if the client is oor capable, then this just
%% switch reception to false, and returns inmediately.
stop_or_detach(FsmRef) ->
    case ?GEN_FSM:sync_send_event(FsmRef, stop_or_detach) of
	stopped ->
	    MRef = erlang:monitor(process, FsmRef),
	    receive {'DOWN', MRef, process, FsmRef, _Reason} ->
		    ok
	    after 5 ->
		    catch exit(FsmRef, kill)
	    end,
	    erlang:demonitor(MRef, [flush]),
	    ok;
	detached ->
	    ok
    end.

close(FsmRef) -> (?GEN_FSM):send_event(FsmRef, closed).

migrate(FsmRef, Node, After) when node(FsmRef) == node() ->
    erlang:send_after(After, FsmRef, {migrate, Node});
migrate(_FsmRef, _Node, _After) ->
    ok.

is_remote_socket(Pid) when node(Pid) == node() ->
    case catch process_info(Pid, dictionary) of
	{dictionary, Dict} ->
	    SockMod = proplists:get_value(c2s_sockmod, Dict),
	    XMLSocket = proplists:get_value(c2s_xml_socket, Dict),
	    Socket = proplists:get_value(c2s_socket, Dict),
	    is_remote_socket(SockMod, XMLSocket, Socket);
	_ ->
	    false
    end;
is_remote_socket(_) ->
    false.

%%%----------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%----------------------------------------------------------------------

init([{SockMod, Socket}, Opts, FSMLimitOpts]) ->
    Access = proplists:get_value(access, Opts, all),
    Shaper = proplists:get_value(shaper, Opts, none),
    XMLSocket = proplists:get_value(xml_socket, Opts, false),
    Zlib = proplists:get_bool(zlib, Opts),
    StartTLS = proplists:get_bool(starttls, Opts),
    StartTLSRequired = proplists:get_bool(starttls_required, Opts),
    TLSEnabled = proplists:get_bool(tls, Opts),
    TLS = StartTLS orelse StartTLSRequired orelse TLSEnabled,
    TLSOpts1 = lists:filter(
		 fun ({certfile, _}) -> true;
		     ({ciphers, _}) -> true;
		     ({cafile, _}) -> true;
		     ({ocsp, _}) -> true;
		     ({crl, _}) -> true;
		     ({dhfile, _}) -> true;
		     (_) -> false
		 end,
		 Opts),
    TLSOpts2 = case lists:keysearch(protocol_options, 1, Opts) of
		   {value, {_, O}} ->
		       [_|ProtocolOptions] = lists:foldl(
					       fun(X, Acc) -> X ++ Acc end, [],
					       [["|" | binary_to_list(Opt)] || Opt <- O, is_binary(Opt)]),
		       [{protocol_options, iolist_to_binary(ProtocolOptions)} | TLSOpts1];
		   _ ->
		       TLSOpts1
	       end,
    TLSOpts3 = case proplists:get_bool(tls_compression, Opts) of
		   false -> [compression_none | TLSOpts2];
		   true -> TLSOpts2
	       end,
    TLSOpts = case proplists:get_bool(tls_verify, Opts) of
		  true -> TLSOpts3;
		  false -> [verify_none | TLSOpts3]
	      end,
    Redirect = proplists:get_value(redirect, Opts, false),
    StreamMgmtEnabled = proplists:get_value(stream_management, Opts, true),
    StreamMgmtState = if
			  StreamMgmtEnabled -> inactive;
			  true -> disabled
		      end,
    MaxAckQueue = case proplists:get_value(max_ack_queue, Opts) of
		      Limit when is_integer(Limit), Limit > 0 -> Limit;
		      infinity -> infinity;
		      _ -> 1000
		  end,
    ResumeTimeout = case proplists:get_value(resume_timeout, Opts) of
			Timeout when is_integer(Timeout), Timeout >= 0 -> Timeout;
			_ -> 300
		    end,
    MaxResumeTimeout = case proplists:get_value(max_resume_timeout, Opts) of
			   Max when is_integer(Max), Max >= ResumeTimeout -> Max;
			   _ -> ResumeTimeout
		       end,
    ResendOnTimeout = case proplists:get_value(resend_on_timeout, Opts) of
			  Resend when is_boolean(Resend) -> Resend;
			  if_offline -> if_offline;
			  _ -> false
		      end,
    IP = case lists:keysearch(frontend_ip, 1, Opts) of
	     {value, {_, IP1}} -> IP1;
	     _ -> peerip(SockMod, Socket)
	 end,
    FlashHack = ejabberd_config:get_option(flash_hack,
					   fun(B) when is_boolean(B) -> B end, false),
    StartTLSRes = if
		      TLSEnabled andalso SockMod /= ejabberd_frontend_socket ->
			  SockMod:starttls(Socket, TLSOpts);
		      true ->
			  {ok, Socket}
		  end,
    OCSPPollInterval = case proplists:get_bool(ocsp_polling, Opts) of
			   true ->
			       case proplists:get_value(ocsp_polling_interval, Opts) of
				   I when is_integer(I), I >= 0 -> I*1000;
				   _ -> 60000
			       end;
			   false ->
			       undefined
		       end,
    OCSPFallbackURIs = case proplists:get_value(ocsp_fallback_uri, Opts) of
			   URI when is_binary(URI) -> [URI];
			   URIs when is_list(URIs) -> URIs;
			   _ -> []
		       end,
    case StartTLSRes of
	{ok, Socket1} ->
	    SocketMonitor = SockMod:monitor(Socket1),
	    StateData = #state{
			   socket = Socket1,
			   sockmod = SockMod,
			   socket_monitor = SocketMonitor,
			   xml_socket = XMLSocket,
			   zlib = Zlib,
			   tls = TLS,
			   tls_required = StartTLSRequired,
			   tls_enabled = TLSEnabled,
			   tls_options = TLSOpts,
			   sid = ejabberd_sm:make_sid(),
			   streamid = new_id(),
			   access = Access,
			   shaper = Shaper,
			   ip = IP,
			   mgmt_state = StreamMgmtState,
			   mgmt_max_queue = MaxAckQueue,
			   mgmt_timeout = ResumeTimeout,
			   mgmt_max_timeout = MaxResumeTimeout,
			   mgmt_resend = ResendOnTimeout,
			   redirect = Redirect,
			   flash_hack = FlashHack,
			   ocsp_poll_interval = OCSPPollInterval,
			   ocsp_fallback_uri_list = OCSPFallbackURIs,
			   fsm_limit_opts = FSMLimitOpts},
	    erlang:send_after(?C2S_OPEN_TIMEOUT, self(), open_timeout),
	    update_internal_dict(StateData),
	    case get_jid_from_opts(Opts) of
		{ok, #jid{user = U, server = Server, resource = R} = JID} ->
		    (?GEN_FSM):send_event(self(), open_session),
		    NewStateData = StateData#state{
				     user = U,
				     server = Server,
				     resource = R,
				     jid = JID,
				     lang = <<"">>},
		    {ok, wait_for_session, NewStateData};
		_ ->
		    {ok, wait_for_stream, StateData, ?C2S_OPEN_TIMEOUT}
	    end;
	{error, _Reason} ->
	    {stop, normal}
    end;
init([StateName, StateData, _FSMLimitOpts]) ->
    MRef = (StateData#state.sockmod):monitor(StateData#state.socket),
    update_internal_dict(StateData),
    if StateName == session_established ->
	    Conn = (StateData#state.sockmod):get_conn_type(
		     StateData#state.socket),
	    Info = [{ip, StateData#state.ip}, {conn, Conn},
		    {auth_module, StateData#state.auth_module}],
	    {Time, _} = StateData#state.sid,
	    SID = {Time, self()},
	    Priority = case StateData#state.pres_last of
			   undefined -> undefined;
			   El -> get_priority_from_presence(El)
		       end,
	    USR = {jid:nodeprep(StateData#state.user),
		   jid:nameprep(StateData#state.server),
		   jid:resourceprep(StateData#state.resource)},
	    NewStateData = StateData#state{
			     sid = SID,
			     socket_monitor = MRef},
	    ejabberd_sm:drop_session(SID, USR),
	    sm_open_session(NewStateData, Priority, Info),
	    StateData2 = change_reception(NewStateData, true),
	    StateData3 = start_keepalive_timer(StateData2),
	    {ok, StateName, StateData3};
       true ->
	    {ok, StateName, StateData#state{socket_monitor = MRef}}
    end.

wakeup(StateData, TimeStamp) ->
    Diff = timer:now_diff(os:timestamp(), TimeStamp) div 1000,
    case (?C2S_HIBERNATE_TIMEOUT + Diff) div (?C2S_HIBERNATED_ACTIVITY * 60000) of
	Count when Count > 0 -> mod_jabs:add(StateData#state.server, Count);
	_ -> ok
    end,
    ?GEN_FSM:enter_loop(?MODULE, [], session_established, StateData).

%% Return list of all available resources of contacts,
get_subscribed(FsmRef) ->
    (?GEN_FSM):sync_send_all_state_event(FsmRef, get_subscribed, 1000).

wait_for_stream({xmlstreamstart, Name, Attrs}, StateData) ->
    DefaultLang = ?MYLANG,
    case {fxml:get_attr_s(<<"xmlns:stream">>, Attrs),
	  fxml:get_attr_s(<<"xmlns:flash">>, Attrs),
	  StateData#state.flash_hack,
	  StateData#state.flash_connection}
    of
	{_, ?NS_FLASH_STREAM, true, false} ->
	    NewAttrs = [{<<"xmlns:stream">>, ?NS_STREAM} | Attrs],
	    wait_for_stream({xmlstreamstart, Name, NewAttrs},
			    StateData#state{flash_connection = true});
	{?NS_STREAM, _, _, _} ->
	    Server =
		case StateData#state.server of
		    <<"">> -> jid:nameprep(fxml:get_attr_s(<<"to">>, Attrs));
		    S -> S
		end,
	    Lang = case fxml:get_attr_s(<<"xml:lang">>, Attrs) of
		       Lang1 when byte_size(Lang1) =< 35 ->
			   %% As stated in BCP47, 4.4.1:
			   %% Protocols or specifications that
			   %% specify limited buffer sizes for
			   %% language tags MUST allow for
			   %% language tags of at least 35 characters.
			   Lang1;
		       _ ->
			   %% Do not store long language tag to
			   %% avoid possible DoS/flood attacks
			   <<"">>
		   end,
	    IsBlacklistedIP = is_ip_blacklisted(StateData#state.ip, Lang),
	    case lists:member(Server, ?MYHOSTS) of
		true when IsBlacklistedIP == false ->
		    change_shaper(StateData, jid:make(<<"">>, Server, <<"">>)),
		    case fxml:get_attr_s(<<"version">>, Attrs) of
			<<"1.0">> ->
			    send_header(StateData, Server, <<"1.0">>, DefaultLang),
			    case StateData#state.authenticated of
				false ->
				    TLS = StateData#state.tls,
				    TLSEnabled = StateData#state.tls_enabled,
				    TLSRequired = StateData#state.tls_required,
				    SASLState = cyrsasl:server_new(
						  <<"jabber">>, Server, <<"">>, [],
						  fun (U) ->
							  ejabberd_auth:get_password_with_authmodule(
							    U, Server)
						  end,
					  fun(U, AuthzId, P) ->
							  ejabberd_auth:check_password_with_authmodule(
						    U, AuthzId, Server, P)
						  end,
					  fun(U, AuthzId, P, D, DG) ->
							  ejabberd_auth:check_password_with_authmodule(
						    U, AuthzId, Server, P, D, DG)
						  end,
						  fun (U) ->
							  ejabberd_auth:is_user_exists(U, Server)
						  end),
				    Mechs =
					case TLSEnabled or not TLSRequired of
					    true ->
						Ms1 = cyrsasl:listmech(Server),
						Ms2 = case is_verification_enabled(
							     StateData#state{server = Server}) of
							  false ->
							      Ms1 -- [<<"EXTERNAL">>];
							  true ->
							      Ms1
						      end,
						Ms = lists:map(fun (S) ->
								       #xmlel{name = <<"mechanism">>,
									      children = [{xmlcdata, S}]}
							       end,
							       Ms2),
						[#xmlel{name = <<"mechanisms">>,
							attrs = [{<<"xmlns">>, ?NS_SASL}],
							children = Ms}];
					    false ->
						[]
					end,
				    SockMod =
					(StateData#state.sockmod):get_sockmod(StateData#state.socket),
				    Zlib = StateData#state.zlib,
				    CompressFeature = case Zlib andalso
							  ((SockMod == gen_tcp) orelse (SockMod == fast_tls)) of
							  true ->
							      [#xmlel{name = <<"compression">>,
								      attrs = [{<<"xmlns">>, ?NS_FEATURE_COMPRESS}],
								      children = [#xmlel{name = <<"method">>,
											 children = [{xmlcdata, <<"zlib">>}]}]}];
							  _ ->
							      []
						      end,
				    TLSFeature =
					case (TLS == true) andalso
					    (TLSEnabled == false) andalso
					    (SockMod == gen_tcp) of
					    true ->
						case TLSRequired of
						    true ->
							[#xmlel{name = <<"starttls">>,
								attrs = [{<<"xmlns">>, ?NS_TLS}],
								children = [#xmlel{name = <<"required">>}]}];
						    _ ->
							[#xmlel{name = <<"starttls">>,
								attrs = [{<<"xmlns">>, ?NS_TLS}]}]
						end;
					    false ->
						[]
					end,
				    P1PushFeature = [#xmlel{name = <<"push">>,
							    attrs = [{<<"xmlns">>, ?NS_P1_PUSH}]}],
				    P1RebindFeature = [#xmlel{name = <<"rebind">>,
							      attrs = [{<<"xmlns">>, ?NS_P1_REBIND}]}],
				    P1AckFeature = [#xmlel{name = <<"ack">>,
							   attrs = [{<<"xmlns">>, ?NS_P1_ACK}]}],
				    StreamFeatures1 =
					TLSFeature ++
					CompressFeature ++
					P1PushFeature ++
					P1RebindFeature ++
					P1AckFeature ++
					Mechs,
				    StreamFeatures =
					ejabberd_hooks:run_fold(
					  c2s_stream_features,
					  Server, StreamFeatures1, [Server]),
				    send_element(StateData,
						 #xmlel{name = <<"stream:features">>,
							children = format_features(StreamFeatures)}),
				    fsm_next_state(wait_for_feature_request,
						   StateData#state{
						     server = Server,
						     sasl_state = SASLState,
						     lang = Lang});
				_ ->
				    case StateData#state.resource of
					<<"">> ->
					    RosterVersioningFeature =
						ejabberd_hooks:run_fold(roster_get_versioning_feature,
									Server, [], [Server]),
					    StreamManagementFeature =
						case stream_mgmt_enabled(StateData) of
						    true ->
							[#xmlel{name = <<"sm">>,
								attrs = [{<<"xmlns">>, ?NS_STREAM_MGMT_2}]},
							 #xmlel{name = <<"sm">>,
								attrs = [{<<"xmlns">>, ?NS_STREAM_MGMT_3}]}];
						    false ->
							[]
						end,
					    StreamFeatures1 =
						[#xmlel{name = <<"push">>,
							attrs = [{<<"xmlns">>, ?NS_P1_PUSH}]},
						 #xmlel{name = <<"bind">>,
							attrs = [{<<"xmlns">>, ?NS_BIND}]},
						 #xmlel{name = <<"session">>,
							attrs = [{<<"xmlns">>, ?NS_SESSION}],
							children =
                                                           [#xmlel{name = <<"optional">>}]}]
						++ RosterVersioningFeature
						++ StreamManagementFeature
						++ ejabberd_hooks:run_fold(c2s_post_auth_features,
									   Server, [], [Server]),
					    StreamFeatures = ejabberd_hooks:run_fold(c2s_stream_features,
										     Server, StreamFeatures1, [Server]),
					    send_element(StateData,
							 #xmlel{name = <<"stream:features">>,
								children = StreamFeatures}),
					    fsm_next_state(wait_for_bind,
							   StateData#state{server = Server, lang = Lang});
					_ ->
					    send_element(StateData,
							 #xmlel{name = <<"stream:features">>}),
					    fsm_next_state(session_established,
							   StateData#state{server = Server, lang = Lang})
				    end
			    end;
			_ ->
			    send_header(StateData, Server, <<"">>, DefaultLang),
			    if
				not StateData#state.tls_enabled
				and StateData#state.tls_required ->
				    fsm_send_and_stop(StateData,
						      ?POLICY_VIOLATION_ERR(Lang, <<"Use of STARTTLS required">>));
				true ->
				    fsm_next_state(wait_for_auth,
						   StateData#state{server = Server, lang = Lang})
			    end
		    end;
		true ->
		    IP = StateData#state.ip,
		    {true, LogReason, ReasonT} = IsBlacklistedIP,
		    ?INFO_MSG("Connection attempt from blacklisted IP ~s: ~s",
			      [jlib:ip_to_list(IP), LogReason]),
		    fsm_send_and_stop(StateData, Server, <<"">>, DefaultLang,
				      ?POLICY_VIOLATION_ERR(Lang, ReasonT));
		_ ->
		    fsm_send_and_stop(StateData, ?MYNAME, <<"">>, DefaultLang,
				      ?HOST_UNKNOWN_ERR)
	    end;
	_ ->
	    case Name of
		<<"policy-file-request">> ->
		    send_text(StateData, flash_policy_string()),
		    fsm_stop(StateData);
		_ ->
		    fsm_send_and_stop(StateData, ?MYNAME, <<"">>, DefaultLang,
				      ?INVALID_NS_ERR)
	    end
    end;
wait_for_stream(timeout, StateData) ->
    fsm_stop(StateData);
wait_for_stream({xmlstreamelement, _}, StateData) ->
    fsm_send_and_stop(StateData, ?INVALID_XML_ERR);
wait_for_stream({xmlstreamend, _}, StateData) ->
    fsm_send_and_stop(StateData, ?INVALID_XML_ERR);
wait_for_stream({xmlstreamerror, _}, StateData) ->
    Lang = StateData#state.lang,
    fsm_send_and_stop(StateData, ?MYNAME, <<"1.0">>, Lang, ?INVALID_XML_ERR);
wait_for_stream(closed, StateData) ->
    fsm_stop(StateData);
wait_for_stream(stop, StateData) ->
    fsm_stop(StateData).
wait_for_stream(stop_or_detach, _From, StateData) ->
    fsm_stopped(StateData).

wait_for_auth({xmlstreamelement, #xmlel{name = Name} = El}, StateData)
  when ?IS_STREAM_MGMT_TAG(Name) ->
    fsm_next_state(wait_for_auth, dispatch_stream_mgmt(El, StateData));
wait_for_auth({xmlstreamelement, El}, StateData) ->
    case is_auth_packet(El) of
	{auth, _ID, get, {U, _, _, _}} ->
	    UCdata = [{xmlcdata, U} || U =/= <<"">>],
	    #xmlel{name = Name, attrs = Attrs} = jlib:make_result_iq_reply(El),
	    Res = case
		      ejabberd_auth:plain_password_required(StateData#state.server) of
		      false ->
			  #xmlel{name = Name, attrs = Attrs,
				 children =
				     [#xmlel{name = <<"query">>,
					     attrs = [{<<"xmlns">>, ?NS_AUTH}],
					     children =
						 [#xmlel{name = <<"username">>, children = UCdata},
						  #xmlel{name = <<"password">>},
						  #xmlel{name = <<"digest">>},
						  #xmlel{name = <<"resource">>}]}]};
		      true ->
			  #xmlel{name = Name, attrs = Attrs,
				 children =
				     [#xmlel{name = <<"query">>,
					     attrs = [{<<"xmlns">>, ?NS_AUTH}],
					     children =
						 [#xmlel{name = <<"username">>, children = UCdata},
						  #xmlel{name = <<"password">>},
						  #xmlel{name = <<"resource">>}]}]}
		  end,
	    send_element(StateData, Res),
	    fsm_next_state(wait_for_auth, StateData);
	{auth, _ID, set, {_U, _P, _D, <<"">>}} ->
	    Lang = StateData#state.lang,
	    Txt = <<"No resource provided">>,
	    Err = jlib:make_error_reply(El, ?ERRT_NOT_ACCEPTABLE(Lang, Txt)),
	    send_element(StateData, Err),
	    fsm_next_state(wait_for_auth, StateData);
	{auth, _ID, set, {U, P, D, R}} ->
	    S = StateData#state.server,
	    JID = jid:make(U, S, R),
	    case JID /= error andalso
		acl:access_matches(StateData#state.access,
				   #{usr => jid:split(JID), ip => StateData#state.ip},
				   StateData#state.server) == allow
	    of
		true ->
		    DGen = fun (PW) ->
				   p1_sha:sha(<<(StateData#state.streamid)/binary, PW/binary>>)
			   end,
		case ejabberd_auth:check_password_with_authmodule(U, U,
								  StateData#state.server,
								  P, D, DGen)
		    of
			{true, AuthModule} ->
			    accept_auth(StateData, U, JID, AuthModule),
			    case need_redirect(StateData#state{user = U}) of
				{true, Host} ->
				    fsm_stop_seeotherhost(StateData,
							  jid:to_string(JID), Host);
				false ->
				    Conn = (StateData#state.sockmod):get_conn_type(
					     StateData#state.socket),
				    Res = jlib:make_result_iq_reply(
					    El#xmlel{children = []}),
				    send_element(StateData, Res),
				    change_shaper(StateData, JID),
				    {FSet, TSet, PrivList} = init_roster_privacy(StateData, U, JID),
				    NewStateData = StateData#state{user = U,
								   resource = R,
								   jid = JID,
								   conn = Conn,
								   auth_module = AuthModule,
								   pres_f = FSet,
								   pres_t = TSet,
								   privacy_list = PrivList},
				    DebugFlag = ejabberd_hooks:run_fold(c2s_debug_start_hook,
									NewStateData#state.server,
									false,
									[self(), NewStateData]),
				    open_session(session_established,
						 NewStateData#state{debug = DebugFlag})
			    end;
			_ ->
			    Lang = StateData#state.lang,
			    Txt = <<"Legacy authentication failed">>,
			    Err = jlib:make_error_reply(
				    El, ?ERRT_NOT_AUTHORIZED(Lang, Txt)),
			    reject_auth(StateData, U, JID, "not authorized"),
			    send_element(StateData, Err),
			    fsm_next_state(wait_for_auth, StateData)
		    end;
		_ ->
		    if JID == error ->
			    ?INFO_MSG("(~w) Failed legacy authentication "
				      "for username '~s' with resource '~s': JID malformed",
				      [StateData#state.socket, U, R]),
			    send_element(StateData, jlib:make_error_reply(El, ?ERR_JID_MALFORMED)),
			    fsm_next_state(wait_for_auth, StateData);
		       true ->
			    Lang = StateData#state.lang,
			    Txt = <<"Legacy authentication forbidden">>,
			    Err = jlib:make_error_reply(El, ?ERRT_NOT_ALLOWED(Lang, Txt)),
			    reject_auth(StateData, U, JID, "not allowed"),
			    send_element(StateData, Err),
			    fsm_next_state(wait_for_auth, StateData)
		    end
	    end;
	_ ->
	    #xmlel{name = Name, attrs = Attrs} = El,
	    case {fxml:get_attr_s(<<"xmlns">>, Attrs), Name} of
		{?NS_P1_REBIND, <<"rebind">>} ->
		    SJID = fxml:get_path_s(El, [{elem, <<"jid">>}, cdata]),
		    SID = fxml:get_path_s(El, [{elem, <<"sid">>}, cdata]),
		    case jid:from_string(SJID) of
			error ->
			    send_failure(StateData, ?NS_P1_REBIND, <<"Invalid JID">>),
			    fsm_next_state(wait_for_auth, StateData);
			JID ->
			    case rebind(StateData, JID, SID) of
				{next_state, wait_for_feature_request, NewStateData, Timeout} ->
				    {next_state, wait_for_auth, NewStateData, Timeout};
				Res ->
				    Res
			    end
		    end;
		_ ->
		    process_unauthenticated_stanza(StateData, El),
		    fsm_next_state(wait_for_auth, StateData)
	    end
    end;
wait_for_auth(timeout, StateData) ->
    fsm_stop(StateData);
wait_for_auth({xmlstreamend, _Name}, StateData) ->
    fsm_stop(StateData);
wait_for_auth({xmlstreamerror, _}, StateData) ->
    fsm_send_and_stop(StateData, ?INVALID_XML_ERR);
wait_for_auth(closed, StateData) ->
    fsm_stop(StateData);
wait_for_auth(stop, StateData) ->
    fsm_stop(StateData).
wait_for_auth(stop_or_detach,_From, StateData) ->
    fsm_stopped(StateData).

wait_for_feature_request({xmlstreamelement, #xmlel{name = Name} = El}, StateData)
  when ?IS_STREAM_MGMT_TAG(Name) ->
    fsm_next_state(wait_for_feature_request, dispatch_stream_mgmt(El, StateData));
wait_for_feature_request({xmlstreamelement, El}, StateData) ->
    #xmlel{name = Name, attrs = Attrs, children = Els} = El,
    Zlib = StateData#state.zlib,
    TLS = StateData#state.tls,
    TLSEnabled = StateData#state.tls_enabled,
    TLSRequired = StateData#state.tls_required,
    SockMod = (StateData#state.sockmod):get_sockmod(StateData#state.socket),
    case {fxml:get_attr_s(<<"xmlns">>, Attrs), Name} of
	{?NS_SASL, <<"auth">>}
	  when TLSEnabled or not TLSRequired ->
	    Mech = fxml:get_attr_s(<<"mechanism">>, Attrs),
	    ClientIn = jlib:decode_base64(fxml:get_cdata(Els)),
	    ClientCertFile = get_cert_file(StateData, Mech),
	    case cyrsasl:server_start(StateData#state.sasl_state,
				      Mech, ClientIn, ClientCertFile)
	    of
		{ok, Props} ->
		    fsm_next_sasl_state(StateData, Props, <<"">>);
		{continue, ServerOut, NewSASLState} ->
		    send_element(StateData,
				 #xmlel{name = <<"challenge">>,
					attrs = [{<<"xmlns">>, ?NS_SASL}],
					children =
					    [{xmlcdata, jlib:encode_base64(ServerOut)}]}),
		    fsm_next_state(wait_for_sasl_response,
				   StateData#state{sasl_state = NewSASLState});
		{error, Error, Username} ->
		    reject_auth(StateData, Username, "open timeout"),
		    send_failure(StateData, ?NS_SASL, Error, <<"">>),
		    {next_state, wait_for_feature_request, StateData, ?C2S_OPEN_TIMEOUT};
		{error, Error, Username, Txt} ->
		    reject_auth(StateData, Username, Txt),
		    send_failure(StateData, ?NS_SASL, Error, Txt),
		    {next_state, wait_for_feature_request, StateData, ?C2S_OPEN_TIMEOUT};
		{error, Error} ->
		    send_failure(StateData, ?NS_SASL, Error, <<"">>),
		    fsm_next_state(wait_for_feature_request, StateData)
	    end;
	{?NS_TLS, <<"starttls">>}
	  when TLS == true, TLSEnabled == false, SockMod == gen_tcp ->
	    TLSOpts1 = case
			   ejabberd_config:get_option(
			     {domain_certfile, StateData#state.server},
			     fun iolist_to_binary/1)
		       of
			   undefined ->
			       StateData#state.tls_options;
			   CertFile ->
			       [{certfile, CertFile} | lists:keydelete(certfile, 1,
								       StateData#state.tls_options)]
		       end,
	    TLSOpts = case is_verification_enabled(StateData#state{tls_enabled = true})
		      of
			  true -> TLSOpts1 -- [verify_none];
			  false -> [verify_none|TLSOpts1]
		      end,
	    Socket = StateData#state.socket,
	    case (StateData#state.sockmod):starttls(Socket, TLSOpts,
						    fxml:element_to_binary(
						      #xmlel{name = <<"proceed">>,
							     attrs = [{<<"xmlns">>, ?NS_TLS}]}))
	    of
		{ok, TLSSocket} ->
		    fsm_next_state(wait_for_stream,
				   update_internal_dict(
				     StateData#state{
				       socket = TLSSocket,
				       streamid = new_id(),
				       tls_enabled = true}));
		{error, _Why} ->
		    fsm_stop(StateData)
	    end;
	{?NS_COMPRESS, <<"compress">>}
	  when Zlib == true,
	       (SockMod == gen_tcp) or (SockMod == fast_tls) ->
	  case fxml:get_subtag(El, <<"method">>) of
		false ->
		    send_failure(StateData, ?NS_COMPRESS, <<"setup-failed">>, <<"">>),
		    fsm_next_state(wait_for_feature_request, StateData);
		Method ->
		case fxml:get_tag_cdata(Method) of
			<<"zlib">> ->
			    case (StateData#state.sockmod):compress(
				   StateData#state.socket,
				   fxml:element_to_binary(
				     #xmlel{name = <<"compressed">>,
					    attrs = [{<<"xmlns">>, ?NS_COMPRESS}]}))
			    of
				{ok, ZlibSocket} ->
				    fsm_next_state(wait_for_stream,
						   update_internal_dict(
						     StateData#state{
						       socket = ZlibSocket,
						       streamid = new_id()}));
				{error, _Reason} ->
				    fsm_stop(StateData)
			    end;
			_ ->
			    send_failure(StateData, ?NS_COMPRESS, <<"unsupported-method">>, <<"">>),
			    fsm_next_state(wait_for_feature_request, StateData)
		    end
	    end;
	{?NS_P1_REBIND, <<"rebind">>} ->
	    SJID = fxml:get_path_s(El, [{elem, <<"jid">>}, cdata]),
	    SID = fxml:get_path_s(El, [{elem, <<"sid">>}, cdata]),
	    case jid:from_string(SJID) of
		error ->
		    send_failure(StateData, ?NS_P1_REBIND, <<"Invalid JID">>),
		    fsm_next_state(wait_for_feature_request, StateData);
		JID ->
		    rebind(StateData, JID, SID)
	    end;
	{?NS_P1_ACK, <<"ack">>} ->
	    fsm_next_state(wait_for_feature_request, StateData#state{ack_enabled = true});
	_ ->
	    if TLSRequired and not TLSEnabled ->
		    fsm_stop_violation(StateData, <<"Use of STARTTLS required">>);
	       true ->
		    process_unauthenticated_stanza(StateData, El),
		    fsm_next_state(wait_for_feature_request, StateData)
	    end
    end;
wait_for_feature_request(timeout, StateData) ->
    fsm_stop(StateData);
wait_for_feature_request({xmlstreamend, _Name}, StateData) ->
    fsm_stop(StateData);
wait_for_feature_request({xmlstreamerror, _}, StateData) ->
    fsm_send_and_stop(StateData, ?INVALID_XML_ERR);
wait_for_feature_request(closed, StateData) ->
    fsm_stop(StateData);
wait_for_feature_request(stop, StateData) ->
    fsm_stop(StateData).
wait_for_feature_request(stop_or_detach, _From, StateData) ->
    fsm_stopped(StateData).

wait_for_sasl_response({xmlstreamelement, #xmlel{name = Name} = El}, StateData)
  when ?IS_STREAM_MGMT_TAG(Name) ->
    fsm_next_state(wait_for_sasl_response, dispatch_stream_mgmt(El, StateData));
wait_for_sasl_response({xmlstreamelement, El}, StateData) ->
    #xmlel{name = Name, attrs = Attrs, children = Els} = El,
    case {fxml:get_attr_s(<<"xmlns">>, Attrs), Name} of
	{?NS_SASL, <<"response">>} ->
	    ClientIn = jlib:decode_base64(fxml:get_cdata(Els)),
	    case cyrsasl:server_step(StateData#state.sasl_state, ClientIn) of
		{ok, Props} ->
		    fsm_next_sasl_state(StateData, Props, <<"">>);
		{ok, Props, ServerOut} ->
		    fsm_next_sasl_state(StateData, Props, ServerOut);
		{continue, ServerOut, NewSASLState} ->
		    send_element(StateData,
				 #xmlel{name = <<"challenge">>,
					attrs = [{<<"xmlns">>, ?NS_SASL}],
					children = [{xmlcdata, jlib:encode_base64(ServerOut)}]}),
		    fsm_next_state(wait_for_sasl_response,
				   StateData#state{sasl_state = NewSASLState});
		{error, Error, Username} ->
		    reject_auth(StateData, Username, "SASL error"),
		    send_failure(StateData, ?NS_SASL, Error, <<"">>),
		    fsm_next_state(wait_for_feature_request, StateData);
		{error, Error, Username, Txt} ->
		    reject_auth(StateData, Username, Txt),
		    send_failure(StateData, ?NS_SASL, Error, Txt),
		    {next_state, wait_for_feature_request, StateData, ?C2S_OPEN_TIMEOUT};
		{error, Error} ->
		    send_failure(StateData, ?NS_SASL, Error, <<"">>),
		    fsm_next_state(wait_for_feature_request, StateData)
	    end;
	_ ->
	    process_unauthenticated_stanza(StateData, El),
	    fsm_next_state(wait_for_feature_request, StateData)
    end;
wait_for_sasl_response(timeout, StateData) ->
    fsm_stop(StateData);
wait_for_sasl_response({xmlstreamend, _Name}, StateData) ->
    fsm_stop(StateData);
wait_for_sasl_response({xmlstreamerror, _}, StateData) ->
    fsm_send_and_stop(StateData, ?INVALID_XML_ERR);
wait_for_sasl_response(closed, StateData) ->
    fsm_stop(StateData);
wait_for_sasl_response(stop, StateData) ->
    fsm_stop(StateData).
wait_for_sasl_response(stop_or_detach, _From, StateData) ->
    fsm_stopped(StateData).

wait_for_bind({xmlstreamelement, #xmlel{name = Name, attrs = Attrs} = El}, StateData)
  when ?IS_STREAM_MGMT_TAG(Name) ->
    case Name of
	<<"resume">> ->
	    case handle_resume(StateData, Attrs) of
		{ok, ResumedState} ->
		    fsm_next_state(session_established, ResumedState);
		error ->
		    fsm_next_state(wait_for_bind, StateData)
	    end;
	_ ->
	    fsm_next_state(wait_for_bind, dispatch_stream_mgmt(El, StateData))
    end;
wait_for_bind({xmlstreamelement, El}, StateData) ->
    case jlib:iq_query_info(El) of
	#iq{type = set, lang = Lang, xmlns = ?NS_BIND, sub_el = SubEl} =
	IQ ->
	    U = StateData#state.user,
	    R1 = fxml:get_path_s(SubEl, [{elem, <<"resource">>}, cdata]),
	    R = case jid:resourceprep(R1) of
		    error -> error;
		    <<"">> -> randoms:get_string();
		    Resource -> Resource
		end,
	    case R of
		error ->
		Txt = <<"Malformed resource">>,
		Err = jlib:make_error_reply(El, ?ERRT_BAD_REQUEST(Lang, Txt)),
		    send_element(StateData, Err),
		    fsm_next_state(wait_for_bind, StateData);
		_ ->
		    JID = jid:make(U, StateData#state.server, R),
                    StateData2 = StateData#state{resource = R, jid = JID},
                    case open_session(StateData2) of
                        {ok, StateData3} ->
                            Res = IQ#iq{type = result, sub_el =
                                        [#xmlel{name = <<"bind">>,
                                                attrs = [{<<"xmlns">>, ?NS_BIND}],
                                                children =
						[#xmlel{name = <<"jid">>,
							children =
                                                        [{xmlcdata, jid:to_string(JID)}]}]}]},
			    try
				send_element(StateData3, jlib:iq_to_xml(Res))
			    catch exit:normal ->
				close(self())
			    end,
                            fsm_next_state(session_established, StateData3);
                        {error, Error} ->
                            Err = jlib:make_error_reply(El, Error),
                            send_element(StateData, Err),
                            fsm_next_state(wait_for_bind, StateData)
                    end
	    end;
	_ ->
	    fsm_next_state(wait_for_bind, StateData)
    end;
wait_for_bind(timeout, StateData) ->
    fsm_stop(StateData);
wait_for_bind({xmlstreamend, _Name}, StateData) ->
    fsm_stop(StateData);
wait_for_bind({xmlstreamerror, _}, StateData) ->
    fsm_send_and_stop(StateData, ?INVALID_XML_ERR);
wait_for_bind(closed, StateData) ->
    fsm_stop(StateData);
wait_for_bind(stop, StateData) ->
    fsm_stop(StateData).
wait_for_bind(stop_or_detach, _From, StateData) ->
    fsm_stopped(StateData).

open_session(StateData) ->
    U = StateData#state.user,
    JID = StateData#state.jid,
    Lang = StateData#state.lang,
    IP = StateData#state.ip,
    case acl:access_matches(StateData#state.access,
			    #{usr => jid:split(JID), ip => IP},
			    StateData#state.server) of
        allow ->
            ?INFO_MSG("(~w) Opened session for ~s",
                      [StateData#state.socket, jid:to_string(JID)]),
            change_shaper(StateData, JID),
            {FSet, TSet, PrivList} = init_roster_privacy(StateData, U, JID),
            Conn = (StateData#state.sockmod):get_conn_type(
                     StateData#state.socket),
            UpdatedStateData = StateData#state{
                                 conn = Conn,
                                 pres_f = FSet,
                                 pres_t = TSet,
                                 privacy_list = PrivList},
            DebugFlag = ejabberd_hooks:run_fold(c2s_debug_start_hook,
                                                UpdatedStateData#state.server, false,
                                                [self(), UpdatedStateData]),
            {ok, open_session1(UpdatedStateData#state{debug = DebugFlag})};
        _ ->
            ejabberd_hooks:run(forbidden_session_hook,
                               StateData#state.server, [JID]),
            ?INFO_MSG("(~w) Forbidden session for ~s",
                      [StateData#state.socket, jid:to_string(JID)]),
	    Txt = <<"Denied by ACL">>,
            {error, ?ERRT_NOT_ALLOWED(Lang, Txt)}
    end.

session_established({xmlstreamelement, #xmlel{name = Name} = El}, StateData)
  when ?IS_STREAM_MGMT_TAG(Name),
       not StateData#state.ack_enabled ->
    fsm_next_state(session_established, dispatch_stream_mgmt(El, StateData));
session_established({xmlstreamelement,
		     #xmlel{name = <<"active">>,
			    attrs = [{<<"xmlns">>, ?NS_CLIENT_STATE}]}},
		    StateData) ->
    NewStateData = csi_flush_queue(StateData),
    fsm_next_state(session_established, NewStateData#state{csi_state = active});
session_established({xmlstreamelement,
		     #xmlel{name = <<"inactive">>,
			    attrs = [{<<"xmlns">>, ?NS_CLIENT_STATE}]}},
		    StateData) ->
    fsm_next_state(session_established, StateData#state{csi_state = inactive});
session_established({xmlstreamelement, El}, StateData) ->
    FromJID = StateData#state.jid,
    case check_from(El, FromJID) of
	'invalid-from' ->
	    fsm_send_and_stop(StateData, ?INVALID_FROM);
	_NewEl ->
	    NSD1 = change_reception(StateData, true),
	    NSD2 = start_keepalive_timer(NSD1),
	    session_established2(El, NSD2)
    end;
%% We hibernate the process to reduce memory consumption after a
%% configurable activity timeout
session_established(timeout, StateData) ->
    Now = os:timestamp(),
    proc_lib:hibernate(?MODULE, wakeup, [StateData, Now]),
    fsm_next_state(session_established, StateData);
session_established({xmlstreamend, _Name}, StateData) ->
    fsm_stop(StateData);
session_established({xmlstreamerror,
		     <<"XML stanza is too big">> = E},
		    StateData) ->
    fsm_send_and_stop(StateData,
		      ?POLICY_VIOLATION_ERR((StateData#state.lang), E));
session_established({xmlstreamerror, _}, StateData) ->
    fsm_send_and_stop(StateData, ?INVALID_XML_ERR);
session_established(closed, #state{mgmt_state = active} = StateData) ->
    catch (StateData#state.sockmod):close(StateData#state.socket),
    fsm_next_state(wait_for_resume, StateData);
session_established(closed, StateData) ->
    if not StateData#state.reception ->
	    fsm_next_state(session_established, StateData);
       StateData#state.keepalive_timer /= undefined ->
	    NewState1 = change_reception(StateData, false),
	    NewState = start_keepalive_timer(NewState1),
	    fsm_next_state(session_established, NewState);
       true ->
	    fsm_stop(StateData)
    end;
session_established(stop, StateData) ->
    fsm_stop(StateData).
session_established(stop_or_detach, From, StateData) ->
    if
	not StateData#state.reception ->
	    ?GEN_FSM:reply(From, detached),
	    fsm_next_state(session_established, StateData);
	(StateData#state.keepalive_timer /= undefined) ->
	    NewState1 = change_reception(StateData, false),
	    NewState = start_keepalive_timer(NewState1),
	    ?GEN_FSM:reply(From, detached),
	    fsm_next_state(session_established, NewState);
	true ->
	    fsm_stopped(StateData)
    end.

%% Process packets sent by user (coming from user on c2s XMPP connection)
session_established2(El, StateData) ->
    #xmlel{name = Name, attrs = Attrs} = El,
    NewStateData = update_num_stanzas_in(StateData, El),
    User = NewStateData#state.user,
    Server = NewStateData#state.server,
    FromJID = NewStateData#state.jid,
    To = fxml:get_attr_s(<<"to">>, Attrs),
    ToJID = case To of
		<<"">> -> jid:make(User, Server, <<"">>);
		_ -> jid:from_string(To)
	    end,
    NewEl1 = jlib:remove_attr(<<"xmlns">>, El),
    NewEl = case fxml:get_attr_s(<<"xml:lang">>, Attrs) of
		<<"">> ->
		    case NewStateData#state.lang of
			<<"">> -> NewEl1;
			Lang -> fxml:replace_tag_attr(<<"xml:lang">>, Lang, NewEl1)
		    end;
		_ ->
		    NewEl1
	    end,
    NewState = case ToJID of
		   error ->
		       case fxml:get_attr_s(<<"type">>, Attrs) of
			   <<"error">> ->
			       NewStateData;
			   <<"result">> ->
			       NewStateData;
			   _ ->
			       Err = jlib:make_error_reply(NewEl, ?ERR_JID_MALFORMED),
			       send_packet(NewStateData, Err)
		       end;
		   _ ->
		       case Name of
			   <<"presence">> ->
			       PresenceEl0 = ejabberd_hooks:run_fold(c2s_update_presence,
								     Server, NewEl, [User, Server]),
			       PresenceEl = fix_packet(NewStateData, FromJID,
						       ToJID, PresenceEl0),
			       case ToJID of
				   #jid{user = User, server = Server, resource = <<"">>} ->
				       ?DEBUG("presence_update(~p,~n\t~p,~n\t~p)",
					      [FromJID, PresenceEl, NewStateData]),
				       presence_update(FromJID, PresenceEl, NewStateData);
				   _ ->
				       presence_track(FromJID, ToJID, PresenceEl, NewStateData)
			       end;
			   <<"iq">> ->
			       case jlib:iq_query_info(NewEl) of
				   #iq{xmlns = Xmlns}
				     when Xmlns == (?NS_PRIVACY);
					  Xmlns == (?NS_BLOCKING) ->
				       NewIQEl = fix_packet(NewStateData, FromJID, ToJID, NewEl),
				       IQ = jlib:iq_query_info(NewIQEl),
				       process_privacy_iq(FromJID, ToJID, IQ, NewStateData);
                                   #iq{xmlns = ?NS_SESSION} ->
                                       Res = jlib:make_result_iq_reply(
                                               NewEl#xmlel{children = []}),
                                       send_stanza(NewStateData, Res);
				   #iq{xmlns = ?NS_P1_PUSH} = IQ ->
				       process_push_iq(FromJID, ToJID, IQ, NewStateData);
				   _ ->
				       NewEl0 = fix_packet(NewStateData, FromJID, ToJID, NewEl),
				       check_privacy_route(FromJID, NewStateData,
							   FromJID, ToJID, NewEl0)
			       end;
			   <<"message">> ->
			       NewEl0 = fix_packet(NewStateData, FromJID, ToJID, NewEl),
			       check_privacy_route(FromJID, NewStateData, FromJID, ToJID, NewEl0);
			   <<"standby">> ->
			       StandBy = fxml:get_tag_cdata(NewEl) == <<"true">>,
			       change_standby(NewStateData, StandBy);
			   <<"a">> ->
			       SCounter = fxml:get_tag_attr_s(<<"h">>, NewEl),
			       receive_ack(NewStateData, SCounter);
			   _ ->
			       NewStateData
		       end
	       end,
    ejabberd_hooks:run(c2s_loop_debug, [{xmlstreamelement, El}]),
    fsm_next_state(session_established, NewState).

wait_for_resume({xmlstreamelement, _El} = Event, StateData) ->
    Result = session_established(Event, StateData),
    fsm_next_state(wait_for_resume, element(3, Result));
wait_for_resume(timeout, StateData) ->
    ?DEBUG("Timed out waiting for resumption of stream for ~s",
	   [jid:to_string(StateData#state.jid)]),
    fsm_stop(StateData#state{mgmt_state = timeout});
wait_for_resume(Event, StateData) ->
    ?DEBUG("Ignoring event while waiting for resumption: ~p", [Event]),
    fsm_next_state(wait_for_resume, StateData).

handle_event({add_rosteritem, IJID, ISubscription}, StateName, StateData) ->
    NewStateData = roster_change(IJID, ISubscription, StateData),
    fsm_next_state(StateName, NewStateData);
handle_event({del_rosteritem, IJID}, StateName, StateData) ->
    NewStateData = roster_change(IJID, none, StateData),
    fsm_next_state(StateName, NewStateData);
handle_event({xmlstreamcdata, _}, session_established = StateName, StateData) ->
    ?DEBUG("cdata ping", []),
    send_text(StateData, <<"\r\n\r\n">>),
    NSD1 = change_reception(StateData, true),
    NSD2 = start_keepalive_timer(NSD1),
    fsm_next_state(StateName, NSD2);
handle_event(_Event, StateName, StateData) ->
    fsm_next_state(StateName, StateData).

handle_sync_event({get_presence}, _From, StateName, StateData) ->
    User = StateData#state.user,
    PresLast = StateData#state.pres_last,
    Show = get_showtag(PresLast),
    Status = get_statustag(PresLast),
    Resource = StateData#state.resource,
    Reply = {User, Resource, Show, Status},
    fsm_reply(Reply, StateName, StateData);
handle_sync_event(get_subscribed, _From, StateName, StateData) ->
    Subscribed = (?SETS):to_list(StateData#state.pres_f),
    {reply, Subscribed, StateName, StateData};
handle_sync_event({resume_session, Time}, _From, _StateName, StateData)
  when element(1, StateData#state.sid) == Time ->
    %% The old session should be closed before the new one is opened, so we do
    %% this here instead of leaving it to the terminate callback
    sm_close_session(StateData),
    {stop, normal, {resume, StateData}, StateData#state{mgmt_state = resumed}};
handle_sync_event({resume_session, _Time}, _From, StateName, StateData) ->
    {reply, {error, <<"Previous session not found">>}, StateName, StateData};
handle_sync_event({messages_replaced, Msgs}, _From, StateName, StateData) ->
    %% See EJABS-2443
    ?DEBUG("Processing messages to replace connection ~p", [Msgs]),
    NewStateData = lists:foldl(fun({From, To, FixedPacket}, State) ->
				       send_or_enqueue_packet(State, From, To, FixedPacket)
			       end, StateData, Msgs),
    fsm_reply(ok, StateName, NewStateData);
handle_sync_event(_Event, _From, StateName, StateData) ->
    fsm_reply(ok, StateName, StateData).

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

handle_info({send_text, Text}, StateName, StateData) ->
    send_text(StateData, Text),
    ejabberd_hooks:run(c2s_loop_debug, [Text]),
    fsm_next_state(StateName, StateData);
handle_info({replaced, Pid}, StateName, StateData) ->
    %% We try to pass the queued messages to the new session,
    %% if that fails for some reason, do the normal workflow
    %% (re-route the messages,  on terminate() ). See discussion on EJABS-2443
    NewStateData = if
		       StateData#state.queue_len > 0 ->
			   case catch ?GEN_FSM:sync_send_all_state_event(Pid, {messages_replaced, queue:to_list(StateData#state.queue)}) of
			       ok ->
				   StateData#state{queue=queue:new(), queue_len = 0};
			       Error ->
				   ?ERROR_MSG("Messages failed to transfer to the new session, will be re-routed ~p (~p): ~p",
					      [Pid, jid:to_string(StateData#state.jid), Error]),
				   StateData
			   end;
		       true ->
			   StateData
		   end,
    handle_info(replaced, StateName, NewStateData);
handle_info(replaced, StateName, StateData) ->
    Lang = StateData#state.lang,
    Xmlelement = ?SERRT_CONFLICT(Lang, <<"Replaced by new connection">>),
    ejabberd_hooks:run(c2s_replaced, StateData#state.server, [StateData#state.jid]),
    handle_info({kick, replaced, Xmlelement}, StateName, StateData);
handle_info(kick, StateName, StateData) ->
    Lang = StateData#state.lang,
    Xmlelement = ?SERRT_POLICY_VIOLATION(Lang, <<"has been kicked">>),
    handle_info({kick, kicked_by_admin, Xmlelement}, StateName, StateData);
handle_info({kick, Reason, Xmlelement}, _StateName, StateData) ->
    %% Catch the send because the session we are kicking might be in detached state (no socket),
    %% and we want to terminate it cleanly anyway.
    catch send_element(StateData, Xmlelement),
    fsm_stop(StateData#state{authenticated = Reason});
handle_info({route, _From, _To, {broadcast, Data}}, StateName, StateData) ->
    ?DEBUG("broadcast~n~p~n", [Data]),
    case Data of
	{item, IJID, ISubscription} ->
	    fsm_next_state(StateName, roster_change(IJID, ISubscription, StateData));
	{exit, Reason} ->
	    fsm_stop_conflict(StateData, Reason);
	{privacy_list, PrivList, PrivListName} ->
	    case ejabberd_hooks:run_fold(privacy_updated_list,
					 StateData#state.server,
					 false,
					 [StateData#state.privacy_list, PrivList])
	    of
		false ->
		    fsm_next_state(StateName, StateData);
		NewPL ->
		    PrivPushIQ = #iq{type = set,
				     xmlns = ?NS_PRIVACY,
				     id = <<"push", (randoms:get_string())/binary>>,
				     sub_el =
					 [#xmlel{name = <<"query">>,
						 attrs = [{<<"xmlns">>, ?NS_PRIVACY}],
						 children =
						     [#xmlel{name = <<"list">>,
							     attrs = [{<<"name">>, PrivListName}]}]}]},
		    PrivFrom = jid:remove_resource(StateData#state.jid),
		    PrivTo = StateData#state.jid,
		    PrivPushEl = jlib:replace_from_to(PrivFrom, PrivTo,
						      jlib:iq_to_xml(PrivPushIQ)),
		    StateData2 = send_or_enqueue_packet(
				   StateData, PrivFrom, PrivTo, PrivPushEl),
		    fsm_next_state(StateName,
				   StateData2#state{privacy_list = NewPL})
	    end;
	{blocking, What} ->
	    NewState = route_blocking(What, StateData),
	    fsm_next_state(StateName, NewState);
	{rebind, Pid2, StreamID2} ->
	    if StreamID2 == StateData#state.streamid ->
		    Pid2 ! {rebind, prepare_acks_for_rebind(StateData)},
		    receive after 1000 -> ok end,
		    fsm_stop(StateData#state{authenticated = rebinded});
	       true ->
		    Pid2 ! {rebind, false},
		    fsm_next_state(StateName, StateData)
	    end;
	{stop_by_device_id, DeviceID} ->
	    case catch jlib:binary_to_integer(
			 fxml:get_path_s(StateData#state.oor_notification,
					[{elem, <<"id">>}, cdata]), 16)
	    of
		DeviceID ->
		    fsm_stop_conflict(StateData, <<"Device conflict">>);
		_ ->
		    fsm_next_state(StateName, StateData)
	    end;
	_ ->
	    fsm_next_state(StateName, StateData)
    end;
%% Process Packets that are to be send to the user
handle_info({route, From, To,
	     #xmlel{name = Name, attrs = Attrs, children = Els} = Packet},
	    StateName, StateData) ->
    {Pass, NewAttrs, NewState} = case Name of
				     <<"presence">> ->
					 State =
					     ejabberd_hooks:run_fold(c2s_presence_in,
								     StateData#state.server,
								     StateData,
								     [{From, To, Packet}]),
					 case fxml:get_attr_s(<<"type">>, Attrs) of
					     <<"probe">> ->
						 NewStateData = add_to_pres_a(State, From),
						 process_presence_probe(From, To, NewStateData),
						 {false, Attrs, NewStateData};
					     <<"error">> ->
						 NewA = remove_element(jid:tolower(From),
								       State#state.pres_a),
						 {true, Attrs, State#state{pres_a = NewA}};
					     <<"subscribe">> ->
						 SRes = is_privacy_allow(State,
									 From, To, Packet, in),
						 {SRes, Attrs, State};
					     <<"subscribed">> ->
						 SRes = is_privacy_allow(State,
									 From, To, Packet, in),
						 {SRes, Attrs, State};
					     <<"unsubscribe">> ->
						 SRes = is_privacy_allow(State,
									 From, To, Packet, in),
						 {SRes, Attrs, State};
					     <<"unsubscribed">> ->
						 SRes = is_privacy_allow(State,
									 From, To, Packet, in),
						 {SRes, Attrs, State};
					     _ ->
						 case privacy_check_packet(State,
									   From, To, Packet, in)
						 of
						     allow ->
							 {true, Attrs, add_to_pres_a(State, From)};
						     deny ->
							 {false, Attrs, State}
						 end
					 end;
				     <<"iq">> ->
					 IQ = jlib:iq_query_info(Packet),
					 case IQ of
					     #iq{xmlns = ?NS_LAST} ->
						 LFrom = jid:tolower(From),
						 LBFrom = setelement(3, LFrom, <<"">>),
						 HasFromSub = (?SETS):is_element(LFrom, StateData#state.pres_f)
						     orelse (?SETS):is_element(LBFrom, StateData#state.pres_f)
						     andalso is_privacy_allow(StateData, To, From,
									      #xmlel{name = <<"presence">>}, out),
						 case HasFromSub of
						     true ->
							 case
							     privacy_check_packet(StateData,
										  From, To, Packet, in)
							 of
							     allow ->
								{true, Attrs, StateData};
							     deny ->
								Err = jlib:make_error_reply(Packet, ?ERR_SERVICE_UNAVAILABLE),
								ejabberd_router:route(To, From, Err),
								{false, Attrs, StateData}
							 end;
						     _ ->
							 Err = jlib:make_error_reply(Packet, ?ERR_FORBIDDEN),
							 ejabberd_router:route(To, From, Err),
							 {false, Attrs, StateData}
						 end;
					     IQ when is_record(IQ, iq)
						     orelse (IQ == reply) ->
						 case
						     privacy_check_packet(StateData,
									  From, To, Packet, in)
						 of
						     allow ->
							 {true, Attrs, StateData};
						     deny when is_record(IQ, iq) ->
							 Err = jlib:make_error_reply(Packet,
										     ?ERR_SERVICE_UNAVAILABLE),
							 ejabberd_router:route(To, From, Err),
							 {false, Attrs, StateData};
						     deny when IQ == reply ->
							 {false, Attrs, StateData}
						 end;
					     IQ when (IQ == invalid)
						     or (IQ == not_iq) ->
						 {false, Attrs, StateData}
					 end;
				     <<"message">> ->
					 case privacy_check_packet(StateData,
								   From, To, Packet, in)
					 of
					     allow ->
						 if StateData#state.reception ->
							 case
							     filter_incoming_message(
                                                               StateData, From, To, Packet)
							 of
							     allow ->
								 {true, Attrs, StateData};
							     deny ->
								 {false, Attrs, StateData}
							 end;
						    true ->
							 {true, Attrs, StateData}
						 end;
					     deny ->
						 case fxml:get_attr_s(<<"type">>, Attrs) of
						     <<"error">> -> ok;
                                                   <<"groupchat">> -> ok;
                                                   <<"headline">> -> ok;
						     _ ->
						       case fxml:get_subtag_with_xmlns(Packet,
										       <<"x">>,
										       ?NS_MUC_USER)
							   of
							 false ->
							     Err =
								 jlib:make_error_reply(Packet,
										       ?ERR_SERVICE_UNAVAILABLE),
							     ejabberd_router:route(To, From,
										   Err);
							 _ -> ok
						       end
						 end,
						 {false, Attrs, StateData}
					 end;
				     _ ->
					 {true, Attrs, StateData}
				 end,
    if Pass ->
	    Attrs2 = jlib:replace_from_to_attrs(jid:to_string(From),
						jid:to_string(To), NewAttrs),
	    FixedPacket = #xmlel{name = Name, attrs = Attrs2, children = Els},
            try
                NewState2 = send_or_enqueue_packet(NewState, From, To, FixedPacket),
                ejabberd_hooks:run(c2s_loop_debug, [{route, From, To, Packet}]),
                fsm_next_state(StateName, NewState2)
            catch exit:normal ->
                    (?GEN_FSM):send_event(self(), closed),
                    self() ! {route, From, To, Packet},
                    fsm_next_state(StateName, NewState)
            end;
       true ->
	    ejabberd_hooks:run(c2s_loop_debug, [{route, From, To, Packet}]),
	    fsm_next_state(StateName, NewState)
    end;
handle_info({timeout, Timer, _}, StateName,
	    #state{keepalive_timer = Timer, reception = true} =
		StateData) ->
    NewState1 = change_reception(StateData, false),
    NewState = start_keepalive_timer(NewState1),
    fsm_next_state(StateName, NewState);
handle_info({timeout, Timer, _}, _StateName,
	    #state{keepalive_timer = Timer, reception = false} =
		StateData) ->
    fsm_stop(StateData);
handle_info({timeout, Timer, PrevCounter}, StateName,
	    #state{ack_timer = Timer} = StateData) ->
    AckCounter = StateData#state.ack_counter,
    NewState = if
		   PrevCounter >= AckCounter ->
		       StateData#state{ack_timer = undefined};
		   true ->
		       send_ack_request(StateData#state{ack_timer = undefined})
	       end,
    fsm_next_state(StateName, NewState);
handle_info({timeout, _Timer, verify_via_ocsp}, StateName, StateData) ->
    J = jid:to_string(
	  jid:make(StateData#state.user,
		   StateData#state.server,
		   StateData#state.resource)),
    case (StateData#state.sockmod):get_peer_certificate(
	   StateData#state.socket, otp) of
	{ok, Cert} ->
	    case verify_issuer(StateData, Cert) of
		{true, CAList} ->
		    case get_verify_methods(Cert, StateData) of
			{[], _} ->
			    ?ERROR_MSG("failed to get OCSP URIs during "
				       "OCSP polling for ~s", [J]),
			    fsm_stop(StateData);
			{OCSPURIs, _} ->
			    case verify_via_ocsp(OCSPURIs, Cert, CAList) of
				true ->
				    erlang:start_timer(
				      StateData#state.ocsp_poll_interval,
				      self(), verify_via_ocsp),
				    {next_state, StateName, StateData};
				{false, Reason} ->
				    ?ERROR_MSG("verification failed during "
					       "OCSP polling for ~s: ~s",
					       [J, Reason]),
				    fsm_stop(StateData)
			    end
		    end;
		{false, Reason} ->
		    ?ERROR_MSG("failed to verify issuer during OCSP polling "
			       "for ~s: ~s", [J, Reason]),
		    fsm_stop(StateData)
	    end;
	{error, Reason} ->
	    ?ERROR_MSG("failed to get peer certificate during OCSP polling "
		       " for ~s: ~s", [J, Reason]),
	    fsm_stop(StateData)
    end;
handle_info({ack_timeout, Counter}, StateName, StateData) ->
    AckQueue = StateData#state.ack_queue,
    case queue:is_empty(AckQueue) of
	true ->
	    fsm_next_state(StateName, StateData);
	false ->
	    C = element(1, queue:head(AckQueue)),
	    if C =< Counter -> fsm_stop(StateData);
	       true -> fsm_next_state(StateName, StateData)
	    end
    end;
handle_info(open_timeout, session_established, StateData) ->
    fsm_next_state(session_established, StateData);
handle_info(open_timeout, _StateName, StateData) ->
    fsm_stop(StateData);
handle_info({'DOWN', Monitor, _Type, _Object, _Info}, StateName, StateData)
  when Monitor == StateData#state.socket_monitor ->
    if (StateName == session_established) and
       not StateData#state.reception ->
	    fsm_next_state(StateName, StateData);
       (StateName == session_established) and
       (StateData#state.keepalive_timer /= undefined) ->
	    NewState1 = change_reception(StateData, false),
	    NewState = start_keepalive_timer(NewState1),
	    fsm_next_state(StateName, NewState);
       true ->
	    if
		StateData#state.mgmt_state == active;
		StateData#state.mgmt_state == pending ->
		    fsm_next_state(wait_for_resume, StateData);
		true ->
		    fsm_stop(StateData)
	    end
    end;
handle_info(system_shutdown, wait_for_stream, StateData) ->
    fsm_send_and_stop(StateData, ?MYNAME, <<"1.0">>, <<"en">>, ?SERR_SYSTEM_SHUTDOWN);
handle_info(system_shutdown, _StateName, StateData) ->
    fsm_send_and_stop(StateData, ?SERR_SYSTEM_SHUTDOWN);
handle_info({route_xmlstreamelement, El}, _StateName, StateData) ->
    {next_state, NStateName, NStateData, _Timeout} =
	session_established({xmlstreamelement, El}, StateData),
    fsm_next_state(NStateName, NStateData);
handle_info({force_update_presence, LUser, LServer}, StateName,
	    #state{jid = #jid{luser = LUser, lserver = LServer}} = StateData) ->
    NewStateData = case StateData#state.pres_last of
		       #xmlel{name = <<"presence">>} ->
			   PresenceEl = ejabberd_hooks:run_fold(c2s_update_presence,
								LServer,
								StateData#state.pres_last,
								[LUser, LServer]),
			   StateData2 = StateData#state{pres_last = PresenceEl},
			   presence_update(StateData2#state.jid, PresenceEl, StateData2),
			   StateData2;
		       _ ->
			   StateData
		   end,
    {next_state, StateName, NewStateData};
handle_info({migrate, Node}, StateName, StateData) ->
    if Node /= node() -> fsm_migrate(StateName, StateData, Node, 0);
       true -> fsm_next_state(StateName, StateData)
    end;
handle_info({send_filtered, Feature, From, To, Packet}, StateName, StateData) ->
    Drop = ejabberd_hooks:run_fold(c2s_filter_packet, StateData#state.server,
				   true, [StateData#state.server, StateData, Feature, To, Packet]),
    NewStateData = if
		       Drop ->
			   ?DEBUG("Dropping packet from ~p to ~p",
				  [jid:to_string(From), jid:to_string(To)]),
			   StateData;
		       true ->
			   FinalPacket = jlib:replace_from_to(From, To, Packet),
			   case StateData#state.jid of
			       To ->
				   case privacy_check_packet(StateData, From, To, FinalPacket, in)
				   of
				       deny -> StateData;
				       allow -> send_stanza(StateData, FinalPacket)
				   end;
			       _ ->
				   ejabberd_router:route(From, To, FinalPacket),
				   StateData
			   end
		   end,
    fsm_next_state(StateName, NewStateData);
handle_info({broadcast, Type, From, Packet}, StateName, StateData) ->
    Recipients = ejabberd_hooks:run_fold(
		   c2s_broadcast_recipients, StateData#state.server,
		   [],
		   [StateData#state.server, StateData, Type, From, Packet]),
    lists:foreach(
      fun(USR) ->
	      ejabberd_router:route(From, jid:make(USR), Packet)
      end, lists:usort(Recipients)),
    fsm_next_state(StateName, StateData);
handle_info({change_socket, Socket}, StateName, StateData) ->
    erlang:demonitor(StateData#state.socket_monitor),
    NewSocket = (StateData#state.sockmod):change_socket(StateData#state.socket, Socket),
    MRef = (StateData#state.sockmod):monitor(NewSocket),
    fsm_next_state(StateName,
		   update_internal_dict(
		     StateData#state{socket = NewSocket, socket_monitor = MRef}));
handle_info({rebind, _}, StateName, StateData) ->
    fsm_next_state(StateName, StateData);
handle_info({timeout, _Timer, _}, StateName, StateData) ->
    fsm_next_state(StateName, StateData);
handle_info(dont_ask_offline, StateName, StateData) ->
    fsm_next_state(StateName, StateData#state{ask_offline = false});
handle_info({_Ref, {resume, OldStateData}}, StateName, StateData) ->
    %% This happens if the resume_session/1 request timed out; the new session
    %% now receives the late response.
    ?DEBUG("Received old session state for ~s after failed resumption",
	   [jid:to_string(OldStateData#state.jid)]),
    handle_unacked_stanzas(OldStateData#state{mgmt_resend = false}),
    fsm_next_state(StateName, StateData);
handle_info(Info, StateName, StateData) ->
    ?ERROR_MSG("Unexpected info: ~p", [Info]),
    fsm_next_state(StateName, StateData).

print_state(State = #state{pres_t = T, pres_f = F, pres_a = A}) ->
    State#state{pres_t = {pres_t, (?SETS):size(T)},
		pres_f = {pres_f, (?SETS):size(F)},
		pres_a = {pres_a, (?SETS):size(A)}}.

terminate({migrated, ClonePid}, StateName, StateData) ->
    ejabberd_hooks:run(c2s_debug_stop_hook,
		       StateData#state.server, [self(), StateData]),
    if
	StateName == session_established ->
	    ?INFO_MSG("(~w) Migrating ~s to ~p on node ~p",
		      [StateData#state.socket,
		       jid:to_string(StateData#state.jid), ClonePid,
		       node(ClonePid)]),
	    sm_close_migrated_session(StateData);
	true ->
	    ok
    end,
    (StateData#state.sockmod):change_controller(StateData#state.socket, ClonePid),
    ok;
terminate(_Reason, StateName, StateData) ->
    if
	StateData#state.mgmt_state == resumed ->
	    ?INFO_MSG("Closing former stream of resumed session for ~s",
		      [jid:to_string(StateData#state.jid)]);
	StateName == session_established;
	StateName == wait_for_resume ->
	    case StateData#state.authenticated of
		replaced ->
		    ?INFO_MSG("(~w) Replaced session for ~s",
			      [StateData#state.socket,
			       jid:to_string(StateData#state.jid)]),
		    sm_close_session_unset_presence(StateData,
						    <<"Replaced by new connection">>);
		rebinded ->
		    sm_close_migrated_session(StateData),
		    ok;
		_ ->
		    ?INFO_MSG("(~w) Close session for ~s",
			      [StateData#state.socket,
			       jid:to_string(StateData#state.jid)]),
		    EmptySet = (?SETS):new(),
		    case StateData of
			#state{pres_last = undefined, pres_a = EmptySet} ->
			    sm_close_session(StateData);
			_ ->
			    sm_close_session_unset_presence(StateData, <<"">>)
		    end,
		    case StateData#state.mgmt_state of
			timeout ->
			    Info = [{num_stanzas_in,
				    StateData#state.mgmt_stanzas_in}],
			    ejabberd_sm:set_offline_info(StateData#state.sid,
							StateData#state.user,
							StateData#state.server,
							StateData#state.resource,
							Info);
			_ ->
			    ok
		    end
	    end,
	    case StateData#state.authenticated of
		rebinded ->
		    ok;
		_ ->
		    if not StateData#state.reception,
		       not StateData#state.oor_offline ->
			    Pkt = #xmlel{name = <<"message">>,
					 children=[#xmlel{name = <<"body">>,
							  children = [{xmlcdata, <<"Instant messaging session expired">>}]},
						   #xmlel{name = <<"customize">>,
							  attrs = [{<<"xmlns">>, <<"p1:push:customize">>},
								   {<<"sound">>, <<"false">>}]}]},
			    ejabberd_hooks:run_fold(p1_push_from_message,
						    jid:make(<<"">>, StateData#state.server, <<"">>),
						    sent,
						    [StateData#state.server,
						     StateData#state.jid, Pkt,
						     StateData#state.oor_notification,
						     StateData#state.oor_appid,
						     all, none, 0, true, true]);
		       true ->
			    ok
		    end,
		    lists:foreach(fun ({_Counter, From, To, FixedPacket}) ->
					  ejabberd_router:route(From, To, FixedPacket)
				  end,
				  queue:to_list(StateData#state.ack_queue)),
		    lists:foreach(fun ({From, To, FixedPacket}) ->
					  ejabberd_router:route(From, To, FixedPacket)
				  end,
				  queue:to_list(StateData#state.queue))
	    end,
	    handle_unacked_stanzas(StateData),
	    bounce_messages();
	true ->
	    ok
    end,
    catch send_trailer(StateData),
    (StateData#state.sockmod):close(StateData#state.socket),
    ok.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

change_shaper(StateData, JID) ->
    Shaper = acl:access_matches(StateData#state.shaper,
				#{usr => jid:split(JID), ip => StateData#state.ip},
				StateData#state.server),
    (StateData#state.sockmod):change_shaper(StateData#state.socket, Shaper).

-spec send_text(c2s_state(), iodata()) -> any().

send_text(StateData, Text) when StateData#state.mgmt_state == pending ->
    ?DEBUG("Cannot send text while waiting for resumption: ~p", [Text]);
send_text(StateData, Text) when StateData#state.xml_socket ->
    ?DEBUG("Send Text on stream = ~p", [Text]),
    (StateData#state.sockmod):send_xml(StateData#state.socket, {xmlstreamraw, Text});
send_text(StateData, Text) when StateData#state.mgmt_state == active ->
    ?DEBUG("Send XML on stream = ~p", [Text]),
    case catch (StateData#state.sockmod):send(StateData#state.socket, Text) of
	{'EXIT', _} ->
	    (StateData#state.sockmod):close(StateData#state.socket),
	    {error, closed};
	_ ->
	    ok
    end;
send_text(StateData, Text) ->
    ?DEBUG("Send XML on stream = ~p", [Text]),
    Text1 = if
		StateData#state.flash_hack and StateData#state.flash_connection ->
		    <<Text/binary, 0>>;
		true ->
		    Text
	    end,
    (StateData#state.sockmod):send(StateData#state.socket, Text1).

-spec send_element(c2s_state(), xmlel()) -> any().

send_element(StateData, El) when StateData#state.mgmt_state == pending ->
    ?DEBUG("Cannot send element while waiting for resumption: ~p", [El]);
send_element(StateData, El) when StateData#state.xml_socket ->
    ejabberd_hooks:run(feature_inspect_packet,
		       StateData#state.server,
		       [StateData#state.jid, StateData#state.server,
			StateData#state.pres_last, El]),
    (StateData#state.sockmod):send_xml(StateData#state.socket, {xmlstreamelement, El});
send_element(StateData, El) ->
    ejabberd_hooks:run(feature_inspect_packet,
		       StateData#state.server,
		       [StateData#state.jid, StateData#state.server,
			StateData#state.pres_last, El]),
    send_text(StateData, fxml:element_to_binary(El)).

send_stanza(StateData, Stanza) when StateData#state.csi_state == inactive ->
    csi_filter_stanza(StateData, Stanza);
send_stanza(StateData, Stanza) when StateData#state.mgmt_state == pending ->
    mgmt_queue_add(StateData, Stanza);
send_stanza(StateData, Stanza) when StateData#state.mgmt_state == active ->
    NewStateData = send_stanza_and_ack_req(StateData, Stanza),
    mgmt_queue_add(NewStateData, Stanza);
send_stanza(StateData, Stanza) ->
    send_element(StateData, Stanza),
    StateData.

send_packet(StateData, Packet) ->
    case is_stanza(Packet) of
	true ->
	    send_stanza(StateData, Packet);
	false ->
	    send_element(StateData, Packet),
	    StateData
    end.

send_header(StateData, Server, Version, Lang)
  when StateData#state.flash_connection ->
    Header = io_lib:format(?FLASH_STREAM_HEADER,
			   [StateData#state.streamid, Server, Version, Lang]),
    send_text(StateData, iolist_to_binary(Header));
send_header(StateData, Server, Version, Lang)
  when StateData#state.xml_socket ->
    VersionAttr = case Version of
		      <<"">> -> [];
		      _ -> [{<<"version">>, Version}]
		  end,
    LangAttr = case Lang of
		   <<"">> -> [];
		   _ -> [{<<"xml:lang">>, Lang}]
	       end,
    Header = {xmlstreamstart, <<"stream:stream">>,
	      VersionAttr ++ LangAttr ++
		  [{<<"xmlns">>, <<"jabber:client">>},
		   {<<"xmlns:stream">>, ?NS_STREAM},
		   {<<"id">>, StateData#state.streamid},
		   {<<"from">>, Server}]},
    (StateData#state.sockmod):send_xml(StateData#state.socket, Header);
send_header(StateData, Server, Version, Lang) ->
    VersionStr = case Version of
		     <<"">> -> <<"">>;
		     _ -> [<<" version='">>, Version, <<"'">>]
		 end,
    LangStr = case Lang of
		  <<"">> -> <<"">>;
		  _ -> [<<" xml:lang='">>, Lang, <<"'">>]
	      end,
    Header = io_lib:format(?STREAM_HEADER,
			   [StateData#state.streamid, Server, VersionStr, LangStr]),
    send_text(StateData, iolist_to_binary(Header)).

send_trailer(StateData)
  when StateData#state.mgmt_state == pending ->
    ?DEBUG("Cannot send stream trailer while waiting for resumption", []);
send_trailer(StateData)
  when StateData#state.xml_socket ->
    (StateData#state.sockmod):send_xml(StateData#state.socket,
				       {xmlstreamend, <<"stream:stream">>});
send_trailer(StateData) ->
    send_text(StateData, ?STREAM_TRAILER).

send_or_enqueue_packet(State, From, To, Packet) ->
    #xmlel{name = Name} = Packet,
    if State#state.reception and
       not (State#state.standby
	    and (Name /= <<"message">>)) ->
	    Packet1 = ejabberd_hooks:run_fold(
			user_receive_packet,
			State#state.server,
			Packet,
			[State, State#state.jid, From, To]),
	    State1 = send_packet(State, Packet1),
	    ack(State1, From, To, Packet1);
       true ->
	    {NewState, Packet2} = send_oor_message(State, From, To, Packet),
            Packet1 = ejabberd_hooks:run_fold(
                        user_receive_packet,
                        NewState#state.server,
                        Packet2,
                        [NewState, State#state.jid, From, To]),
	    enqueue(NewState, From, To, Packet1)
    end.

new_id() ->
    randoms:get_string().

is_auth_packet(El) ->
    case jlib:iq_query_info(El) of
	#iq{id = ID, type = Type, xmlns = ?NS_AUTH, sub_el = SubEl} ->
	    #xmlel{children = Els} = SubEl,
	    {auth, ID, Type, get_auth_tags(Els, <<"">>, <<"">>, <<"">>, <<"">>)};
	_ ->
	    false
    end.

is_stanza(#xmlel{name = Name, attrs = Attrs})
  when Name == <<"message">>;
       Name == <<"presence">>;
       Name == <<"iq">> ->
    case fxml:get_attr(<<"xmlns">>, Attrs) of
	{value, NS} when NS /= <<"jabber:client">>,
			 NS /= <<"jabber:server">> ->
	    false;
	_ ->
	    true
    end;
is_stanza(_El) ->
    false.

get_auth_tags([#xmlel{name = Name, children = Els} | L], U, P, D, R) ->
    CData = fxml:get_cdata(Els),
    case Name of
	<<"username">> -> get_auth_tags(L, CData, P, D, R);
	<<"password">> -> get_auth_tags(L, U, CData, D, R);
	<<"digest">> -> get_auth_tags(L, U, P, CData, R);
	<<"resource">> -> get_auth_tags(L, U, P, D, CData);
	_ -> get_auth_tags(L, U, P, D, R)
    end;
get_auth_tags([_ | L], U, P, D, R) ->
    get_auth_tags(L, U, P, D, R);
get_auth_tags([], U, P, D, R) ->
    {U, P, D, R}.

process_presence_probe(From, To, StateData) ->
    LFrom = jid:tolower(From),
    LBFrom = setelement(3, LFrom, <<"">>),
    case StateData#state.pres_last of
	undefined ->
	    ok;
	_ ->
	    Cond = ((?SETS):is_element(LFrom, StateData#state.pres_f)
		    orelse ((LFrom /= LBFrom)
			    andalso (?SETS):is_element(LBFrom, StateData#state.pres_f))),
	    if Cond ->
		    Packet = case StateData#state.reception of
				 true ->
				     StateData#state.pres_last;
				 false ->
				     case StateData#state.oor_show of
					 <<"">> ->
					     StateData#state.pres_last;
					 _ ->
					     #xmlel{attrs = PresAttrs,
						    children = PresEls} =
						 StateData#state.pres_last,
					     PEls1 = lists:flatmap(
						       fun (#xmlel{name = <<"show">>}) ->
							       [];
							   (#xmlel{name = <<"status">>}) ->
							       [];
							   (E) ->
							       [E]
						       end,
						       PresEls),
					     make_oor_presence(StateData, PresAttrs, PEls1)
				     end
			     end,
		    Timestamp = StateData#state.pres_timestamp,
		    Packet1 = maybe_add_delay(Packet, utc, To, <<"">>, Timestamp),
		    case ejabberd_hooks:run_fold(privacy_check_packet,
						 StateData#state.server, allow,
						 [StateData#state.user,
						  StateData#state.server,
						  StateData#state.privacy_list,
						  {To, From, Packet1}, out])
		    of
			deny ->
			    ok;
			allow ->
			    Pid = element(2, StateData#state.sid),
			    ejabberd_hooks:run(presence_probe_hook,
					       StateData#state.server,
					       [From, To, Pid]),
			    case From == To of
				false -> ejabberd_router:route(To, From, Packet1);
				true -> ok
			    end
		    end;
	       true ->
		    ok
	    end
    end.

%% User updates his presence (non-directed presence packet)
presence_update(From, Packet, StateData) ->
    #xmlel{attrs = Attrs} = Packet,
    case fxml:get_attr_s(<<"type">>, Attrs) of
	<<"unavailable">> ->
	  Status = case fxml:get_subtag(Packet, <<"status">>) of
			 false -> <<"">>;
		     StatusTag -> fxml:get_tag_cdata(StatusTag)
		     end,
	    Info = [{ip, StateData#state.ip}, {conn, StateData#state.conn},
		    {auth_module, StateData#state.auth_module}],
	    ejabberd_sm:unset_presence(StateData#state.sid,
				       StateData#state.user,
				       StateData#state.server,
				       StateData#state.resource,
				       Status, Info),
	    presence_broadcast(StateData, From, StateData#state.pres_a, Packet),
	    StateData#state{pres_last = undefined,
			    pres_timestamp = undefined, pres_a = (?SETS):new()};
	<<"error">> -> StateData;
	<<"probe">> -> StateData;
	<<"subscribe">> -> StateData;
	<<"subscribed">> -> StateData;
	<<"unsubscribe">> -> StateData;
	<<"unsubscribed">> -> StateData;
	_ ->
	    OldPriority = case StateData#state.pres_last of
			      undefined -> 0;
			      OldPresence -> get_priority_from_presence(OldPresence)
			  end,
	    NewPriority = get_priority_from_presence(Packet),
	    update_priority(NewPriority, Packet, StateData),
	    FromUnavail = (StateData#state.pres_last == undefined),
	    ?DEBUG("from unavail = ~p~n", [FromUnavail]),
	    NewStateData = StateData#state{
			     pres_last = Packet,
			     pres_timestamp = p1_time_compat:timestamp()},
	    NewState = if FromUnavail ->
			       ejabberd_hooks:run(user_available_hook,
						  NewStateData#state.server,
						  [NewStateData#state.jid]),
			       ResentStateData = if
						     NewPriority >= 0 ->
							 resend_offline_messages(NewStateData),
							 resend_subscription_requests(NewStateData);
						     true ->
							 NewStateData
						 end,
			       presence_broadcast_first(From, ResentStateData, Packet);
			  true ->
			       presence_broadcast_to_trusted(NewStateData, From,
							     NewStateData#state.pres_f,
							     NewStateData#state.pres_a,
							     Packet),
			       if
				   OldPriority < 0, NewPriority >= 0 ->
				       resend_offline_messages(NewStateData);
				   true -> ok
			       end,
			       NewStateData
		       end,
	    NewState
    end.

%% User sends a directed presence packet
presence_track(From, To, Packet, StateData) ->
    #xmlel{attrs = Attrs} = Packet,
    LTo = jid:tolower(To),
    User = StateData#state.user,
    Server = StateData#state.server,
    case fxml:get_attr_s(<<"type">>, Attrs) of
	<<"unavailable">> ->
	    A = remove_element(LTo, StateData#state.pres_a),
	    check_privacy_route(From, StateData#state{pres_a = A}, From, To, Packet);
	<<"subscribe">> ->
	    try_roster_subscribe(subscribe, User, Server, From, To, Packet, StateData);
	<<"subscribed">> ->
	    ejabberd_hooks:run(roster_out_subscription, Server,
			       [User, Server, To, subscribed]),
	    check_privacy_route(From, StateData,
				jid:remove_resource(From), To, Packet);
	<<"unsubscribe">> ->
	    try_roster_subscribe(unsubscribe, User, Server, From, To, Packet, StateData);
	<<"unsubscribed">> ->
	    ejabberd_hooks:run(roster_out_subscription, Server,
			       [User, Server, To, unsubscribed]),
	    check_privacy_route(From, StateData,
				jid:remove_resource(From), To, Packet);
	<<"error">> ->
	    check_privacy_route(From, StateData, From, To, Packet);
	<<"probe">> ->
	    check_privacy_route(From, StateData, From, To, Packet);
	_ ->
	    A = (?SETS):add_element(LTo, StateData#state.pres_a),
	    check_privacy_route(From, StateData#state{pres_a = A}, From, To, Packet)
    end.

check_privacy_route(From, StateData, FromRoute, To, Packet) ->
    case privacy_check_packet(StateData, From, To, Packet, out) of
	deny ->
	    Lang = StateData#state.lang,
	    ErrText = <<"Your active privacy list has denied "
			"the routing of this stanza.">>,
	    Err = jlib:make_error_reply(Packet,
					?ERRT_NOT_ACCEPTABLE(Lang, ErrText)),
	    Err2 = jlib:replace_from_to(To, From, Err),
	    send_stanza(StateData, Err2);
	allow ->
	    ejabberd_router:route(FromRoute, To, Packet),
	    StateData
    end.

%% Check if privacy rules allow this delivery
privacy_check_packet(StateData, From, To, Packet, Dir) ->
    ejabberd_hooks:run_fold(privacy_check_packet,
			    StateData#state.server, allow,
			    [StateData#state.user, StateData#state.server,
			     StateData#state.privacy_list, {From, To, Packet},
			     Dir]).

is_privacy_allow(StateData, From, To, Packet, Dir) ->
    allow == privacy_check_packet(StateData, From, To, Packet, Dir).

%%% Check ACL before allowing to send a subscription stanza
try_roster_subscribe(Type, User, Server, From, To, Packet, StateData) ->
    JID1 = jid:make(User, Server, <<"">>),
    Access = gen_mod:get_module_opt(
	       Server, mod_roster, access,
	       fun(A) -> A end, all),
    case acl:match_rule(Server, Access, JID1) of
	deny ->
	    %% Silently drop this (un)subscription request
	    StateData;
	allow ->
	    ejabberd_hooks:run(roster_out_subscription,
			       Server,
			       [User, Server, To, Type]),
	    check_privacy_route(From, StateData, jid:remove_resource(From),
				To, Packet)
    end.

%% Send presence when disconnecting
presence_broadcast(StateData, From, JIDSet, Packet) ->
    JIDs = format_and_check_privacy(From, StateData, Packet, JIDSet, out),
    send_multiple(From, StateData#state.server, JIDs, Packet).

%% Send presence when updating presence
presence_broadcast_to_trusted(StateData, From, Trusted, JIDSet, Packet) ->
    JIDs = ?SETS:fold(fun(JID, Accum) ->
			      case ?SETS:is_element(JID, Trusted) of
				  true ->
				      FJID = jid:make(JID),
				      case ejabberd_hooks:run_fold(
					     privacy_check_packet, StateData#state.server,
					     allow,
					     [StateData#state.user,
					      StateData#state.server,
					      StateData#state.privacy_list,
					      {From, FJID, Packet},
					      out]) of
					  deny -> Accum;
					  allow -> [FJID|Accum]
				      end;
				  false ->
				      Accum
			      end
		      end, [], JIDSet),
    send_multiple(From, StateData#state.server, JIDs, Packet).

%% Send presence when connecting
presence_broadcast_first(From, StateData, Packet) ->
    PacketProbe = #xmlel{name = <<"presence">>, attrs = [{<<"type">>, <<"probe">>}]},
    presence_broadcast(StateData, From, StateData#state.pres_t, PacketProbe),
    As = ?SETS:fold(fun ?SETS:add_element/2, StateData#state.pres_f, StateData#state.pres_a),
    presence_broadcast(StateData, From, As, Packet),
    StateData#state{pres_a = As}.

format_and_check_privacy(From, StateData, Packet, JIDs, Dir) ->
    ?SETS:fold(fun(JID, Accum) ->
		       FJID = jid:make(JID),
		       case ejabberd_hooks:run_fold(
			      privacy_check_packet, StateData#state.server,
			      allow,
			      [StateData#state.user,
			       StateData#state.server,
			       StateData#state.privacy_list,
			       {From, FJID, Packet},
			       Dir]) of
			   deny -> Accum;
			   allow -> [FJID|Accum]
		       end
	       end, [], JIDs).

send_multiple(From, Server, JIDs, Packet) ->
    ejabberd_router_multicast:route_multicast(From, Server, JIDs, Packet).

remove_element(E, Set) ->
    case (?SETS):is_element(E, Set) of
	true -> (?SETS):del_element(E, Set);
	_ -> Set
    end.

roster_change(IJID, ISubscription, StateData) ->
    LIJID = jid:tolower(IJID),
    IsFrom = (ISubscription == both) or (ISubscription == from),
    IsTo = (ISubscription == both) or (ISubscription == to),
    OldIsFrom = (?SETS):is_element(LIJID, StateData#state.pres_f),
    FSet = if
	       IsFrom -> (?SETS):add_element(LIJID, StateData#state.pres_f);
	       true -> remove_element(LIJID, StateData#state.pres_f)
	   end,
    TSet = if
	       IsTo -> (?SETS):add_element(LIJID, StateData#state.pres_t);
	       true -> remove_element(LIJID, StateData#state.pres_t)
	   end,
    case StateData#state.pres_last of
	undefined ->
	    StateData#state{pres_f = FSet, pres_t = TSet};
	P ->
	    ?DEBUG("roster changed for ~p~n", [StateData#state.user]),
	    From = StateData#state.jid,
	    To = jid:make(IJID),
	    Cond1 = IsFrom andalso not OldIsFrom,
	    Cond2 = not IsFrom andalso OldIsFrom
		andalso (?SETS):is_element(LIJID, StateData#state.pres_a),
	    if
		Cond1 ->
		    ?DEBUG("C1: ~p~n", [LIJID]),
		    case privacy_check_packet(StateData, From, To, P, out) of
			deny -> ok;
			allow -> ejabberd_router:route(From, To, P)
		    end,
		    A = (?SETS):add_element(LIJID, StateData#state.pres_a),
		    StateData#state{pres_a = A, pres_f = FSet, pres_t = TSet};
		Cond2 ->
		    ?DEBUG("C2: ~p~n", [LIJID]),
		    PU = #xmlel{name = <<"presence">>,
				attrs = [{<<"type">>, <<"unavailable">>}]},
		    case privacy_check_packet(StateData, From, To, PU, out) of
			deny -> ok;
			allow -> ejabberd_router:route(From, To, PU)
		    end,
		    A = remove_element(LIJID, StateData#state.pres_a),
		    StateData#state{pres_a = A, pres_f = FSet, pres_t = TSet};
		true ->
		    StateData#state{pres_f = FSet, pres_t = TSet}
	    end
    end.

update_priority(Priority, Packet, StateData) ->
    Info1 = [{ip, StateData#state.ip}, {conn, StateData#state.conn},
	     {auth_module, StateData#state.auth_module}],
    Info = case StateData#state.reception of
	       false -> [{oor, true} | Info1];
	       _ -> Info1
	   end,
    ejabberd_sm:set_presence(StateData#state.sid,
			     StateData#state.user,
			     StateData#state.server,
			     StateData#state.resource,
			     Priority, Packet, Info).

get_priority_from_presence(PresencePacket) ->
    case fxml:get_subtag(PresencePacket, <<"priority">>) of
	false ->
	    0;
	SubEl ->
	    case catch jlib:binary_to_integer(fxml:get_tag_cdata(SubEl)) of
		P when is_integer(P) -> P;
		_ -> 0
	    end
    end.

process_privacy_iq(From, To,
		   #iq{type = Type, lang = Lang, sub_el = SubEl} = IQ, StateData) ->
    Txt = <<"No module is handling this query">>,
    {Res, NewStateData} =
	case Type of
			      get ->
		R = ejabberd_hooks:run_fold(
		      privacy_iq_get,
							      StateData#state.server,
		      {error, ?ERRT_FEATURE_NOT_IMPLEMENTED(Lang, Txt)},
		      [From, To, IQ,
		       StateData#state.privacy_list]),
				  {R, StateData};
			      set ->
		case ejabberd_hooks:run_fold(
		       privacy_iq_set,
							       StateData#state.server,
		       {error, ?ERRT_FEATURE_NOT_IMPLEMENTED(Lang, Txt)},
							       [From, To, IQ])
				  of
				      {result, R, NewPrivList} ->
					  {{result, R},
					   StateData#state{privacy_list = NewPrivList}};
				      R ->
					  {R, StateData}
				  end
			  end,
    IQRes = case Res of
		{result, Result} ->
		    IQ#iq{type = result, sub_el = Result};
		{error, Error} ->
		    IQ#iq{type = error, sub_el = [SubEl, Error]}
	    end,
    ejabberd_router:route(To, From, jlib:iq_to_xml(IQRes)),
    NewStateData.

resend_offline_messages(#state{ask_offline = true} = StateData) ->
    F = fun() ->
                case ejabberd_hooks:run_fold(
                       resend_offline_messages_hook,
                       StateData#state.server, [],
                       [StateData#state.user, StateData#state.server])
                    of
                    Rs -> %%when is_list(Rs) ->
                        lists:foreach(
                          fun ({route, From, To, #xmlel{} = Packet}) ->
                                  case privacy_check_packet(StateData,
                                                            From, To, Packet, in)
                                      of
                                      allow ->
                                          ejabberd_router:route(From, To, Packet);
                                      deny ->
                                          ok
                                  end
                          end,
                          Rs)
                end
        end,
    case ejabberd_config:get_option(
           async_offline_resend,
           fun(B) when is_boolean(B) -> B end, false) of
        false ->
            F();
        true ->
            JID = StateData#state.jid,
            Worker = mod_offline_sup:get_worker_for(
                       JID#jid.lserver, JID#jid.luser),
            Worker ! {execute, F},
            ok
    end;
resend_offline_messages(_StateData) ->
    ok.

resend_subscription_requests(#state{user = User, server = Server} = StateData) ->
    PendingSubscriptions =
	ejabberd_hooks:run_fold(resend_subscription_requests_hook,
				Server, [], [User, Server]),
    lists:foldl(fun (XMLPacket, AccStateData) ->
			send_packet(AccStateData, XMLPacket)
		end,
		StateData,
		PendingSubscriptions).

get_showtag(undefined) ->
    <<"unavailable">>;
get_showtag(Presence) ->
    case fxml:get_path_s(Presence, [{elem, <<"show">>}, cdata]) of
	<<"">> -> <<"available">>;
	ShowTag -> ShowTag
    end.

get_statustag(undefined) ->
    <<"">>;
get_statustag(Presence) ->
    fxml:get_path_s(Presence, [{elem, <<"status">>}, cdata]).

process_unauthenticated_stanza(StateData, El) ->
    NewEl = case fxml:get_tag_attr_s(<<"xml:lang">>, El) of
		<<"">> ->
		    case StateData#state.lang of
			<<"">> -> El;
		    Lang -> fxml:replace_tag_attr(<<"xml:lang">>, Lang, El)
		    end;
		_ ->
		    El
	    end,
    case jlib:iq_query_info(NewEl) of
      #iq{lang = L} = IQ ->
	    Res = ejabberd_hooks:run_fold(c2s_unauthenticated_iq,
					  StateData#state.server, empty,
					  [StateData#state.server, IQ, StateData#state.ip]),
	    case Res of
		empty ->
		Txt = <<"Authentication required">>,
		    ResIQ = IQ#iq{type = error,
			      sub_el = [?ERRT_SERVICE_UNAVAILABLE(L, Txt)]},
		    Res1 = jlib:replace_from_to(jid:make(<<"">>,
							 StateData#state.server,
							 <<"">>),
						jid:make(<<"">>, <<"">>, <<"">>),
						jlib:iq_to_xml(ResIQ)),
		    send_element(StateData, jlib:remove_attr(<<"to">>, Res1));
		_ ->
		    send_element(StateData, Res)
	    end;
	_ ->
	    %% Drop any stanza, which isn't IQ stanza
	    ok
    end.

peerip(SockMod, Socket) ->
    IP = case SockMod of
	     gen_tcp -> inet:peername(Socket);
	     _ -> SockMod:peername(Socket)
	 end,
    case IP of
	{ok, IPOK} -> IPOK;
	_ -> undefined
    end.

open_session(StateName, StateData) ->
    fsm_next_state(StateName, open_session1(StateData)).

open_session1(StateData) ->
    PackedStateData = pack(StateData),
    {Ms,Ss,_} = os:timestamp(),
    if ?CHECK_EXPIRATION(Ms, Ss) ->
	    Conn = ejabberd_socket:get_conn_type(StateData#state.socket),
	    Info = [{ip, StateData#state.ip}, {conn, Conn},
		    {auth_module, StateData#state.auth_module}],
	    Presence = StateData#state.pres_last,
	    Priority = case Presence of
			   undefined -> undefined;
			   _ -> get_priority_from_presence(Presence)
		       end,
	    sm_open_session(StateData, Priority, Info),
	    StateData2 = change_reception(PackedStateData, true),
	    StateData3 = start_keepalive_timer(StateData2),
	    erlang:garbage_collect(),
	    StateData3;
       true ->
            ?ERROR_MSG("~s~n", [ejabberd_license:info()]),
	    application:stop(ejabberd),
	    erlang:halt()
    end.

%% fsm_next_state: Generate the next_state FSM tuple with different
%% timeout, depending on the future state
fsm_next_state(session_established, #state{mgmt_max_queue = exceeded} = StateData) ->
    ?WARNING_MSG("ACK queue too long, terminating session for ~s",
		 [jid:to_string(StateData#state.jid)]),
    Err = ?SERRT_POLICY_VIOLATION(StateData#state.lang,
				  <<"Too many unacked stanzas">>),
    fsm_send_and_stop(StateData#state{mgmt_resend = false}, Err);
fsm_next_state(session_established, #state{mgmt_state = pending} = StateData) ->
    fsm_next_state(wait_for_resume, StateData);
fsm_next_state(session_established, StateData) ->
    {next_state, session_established, StateData, ?C2S_HIBERNATE_TIMEOUT};
fsm_next_state(wait_for_resume, #state{mgmt_timeout = 0} = StateData) ->
    fsm_stop(StateData);
fsm_next_state(wait_for_resume, #state{mgmt_pending_since = undefined} = StateData) ->
    ?INFO_MSG("Waiting for resumption of stream for ~s",
	      [jid:to_string(StateData#state.jid)]),
    {next_state, wait_for_resume,
     StateData#state{mgmt_state = pending, mgmt_pending_since = os:timestamp()},
     StateData#state.mgmt_timeout};
fsm_next_state(wait_for_resume, StateData) ->
    Diff = timer:now_diff(os:timestamp(), StateData#state.mgmt_pending_since),
    Timeout = max(StateData#state.mgmt_timeout - Diff div 1000, 1),
    {next_state, wait_for_resume, StateData, Timeout};
fsm_next_state(StateName, StateData) ->
    {next_state, StateName, StateData, ?C2S_OPEN_TIMEOUT}.

fsm_migrate(StateName, StateData, Node, Timeout) ->
    {migrate, StateData,
     {Node, ?MODULE, start, [StateName, StateData]},
     Timeout}.

%% fsm_reply: Generate the reply FSM tuple with different timeout,
%% depending on the future state
fsm_reply(Reply, session_established, StateData) ->
    {reply, Reply, session_established, StateData, ?C2S_HIBERNATE_TIMEOUT};
fsm_reply(Reply, wait_for_resume, StateData) ->
    Diff = timer:now_diff(os:timestamp(), StateData#state.mgmt_pending_since),
    Timeout = max(StateData#state.mgmt_timeout - Diff div 1000, 1),
    {reply, Reply, wait_for_resume, StateData, Timeout};
fsm_reply(Reply, StateName, StateData) ->
    {reply, Reply, StateName, StateData, ?C2S_OPEN_TIMEOUT}.

%% Used by c2s blacklist plugins
is_ip_blacklisted(undefined, _Lang) ->
    false;
is_ip_blacklisted({IP, _Port}, Lang) ->
    ejabberd_hooks:run_fold(check_bl_c2s, false, [IP, Lang]).

%% Check from attributes
%% returns invalid-from|NewElement
check_from(El, FromJID) ->
    case fxml:get_tag_attr(<<"from">>, El) of
	false ->
	    El;
	{value, SJID} ->
	    JID = jid:from_string(SJID),
	    case JID of
		error ->
		    'invalid-from';
		#jid{} ->
		    if
			(JID#jid.luser == FromJID#jid.luser) and
			(JID#jid.lserver == FromJID#jid.lserver) and
			(JID#jid.lresource == FromJID#jid.lresource) ->
			    El;
			(JID#jid.luser == FromJID#jid.luser) and
			(JID#jid.lserver == FromJID#jid.lserver) and
			(JID#jid.lresource == <<"">>) ->
			    El;
			true ->
			    'invalid-from'
		    end
	    end
    end.

start_keepalive_timer(StateData) ->
    if
	is_reference(StateData#state.keepalive_timer) ->
	    cancel_timer(StateData#state.keepalive_timer);
	true ->
	    ok
    end,
    Timeout = if
		  StateData#state.reception ->
		      StateData#state.keepalive_timeout;
		  true ->
		      StateData#state.oor_timeout
	      end,
    Timer = if
		is_integer(Timeout) ->
		    erlang:start_timer(Timeout * 1000, self(), []);
		true ->
		    undefined
	    end,
    StateData#state{keepalive_timer = Timer}.

change_reception(#state{reception = Reception} = StateData, Reception) ->
    StateData;
change_reception(#state{reception = true} = StateData, false) ->
    ?DEBUG("reception -> false", []),
    case StateData#state.oor_show of
	<<"">> ->
	    ok;
	_ ->
	    Packet = make_oor_presence(StateData),
	    update_priority(0, Packet, StateData#state{reception = false}),
	    presence_broadcast_to_trusted(StateData,
					  StateData#state.jid,
					  StateData#state.pres_f,
					  StateData#state.pres_a, Packet)
    end,
    JID = StateData#state.jid,
    ejabberd_hooks:run(c2s_lost_reception,
		       JID#jid.lserver, [StateData#state.sid, JID]),
    StateData#state{reception = false};
change_reception(#state{reception = false, standby = true} = StateData, true) ->
    ?DEBUG("reception -> standby", []),
    NewQueue = lists:foldl(fun ({_From, _To,
				 #xmlel{name = <<"message">>} = FixedPacket},
				Q) ->
				   send_element(StateData, FixedPacket), Q;
			       (Item, Q) -> queue:in(Item, Q)
			   end,
			   queue:new(), queue:to_list(StateData#state.queue)),
    StateData#state{queue = NewQueue,
		    queue_len = queue:len(NewQueue), reception = true,
		    oor_unread = 0, oor_unread_users = (?SETS):new()};
change_reception(#state{reception = false} = StateData, true) ->
    ?DEBUG("reception -> true", []),
    case StateData#state.oor_show of
	<<"">> ->
	    ok;
	_ ->
	    case StateData#state.pres_last of
		undefined ->
		    ok;
		Packet ->
		    NewPriority = get_priority_from_presence(Packet),
		    update_priority(NewPriority, Packet, StateData#state{reception = true}),
		    presence_broadcast_to_trusted(StateData,
						  StateData#state.jid,
						  StateData#state.pres_f,
						  StateData#state.pres_a, Packet)
	    end
    end,
    lists:foreach(fun ({_From, _To, FixedPacket}) ->
			  send_element(StateData, FixedPacket)
		  end,
		  queue:to_list(StateData#state.queue)),
    lists:foreach(fun (FixedPacket) ->
			  send_element(StateData, FixedPacket)
		  end,
		  gb_trees:values(StateData#state.pres_queue)),
    StateData#state{queue = queue:new(), queue_len = 0,
		    pres_queue = gb_trees:empty(), reception = true,
		    oor_unread = 0, oor_unread_users = (?SETS):new()}.

change_standby(#state{standby = StandBy} = StateData, StandBy) ->
    StateData;
change_standby(#state{standby = false} = StateData, true) ->
    ?DEBUG("standby -> true", []),
    StateData#state{standby = true};
change_standby(#state{standby = true} = StateData, false) ->
    ?DEBUG("standby -> false", []),
    lists:foreach(fun ({_From, _To, FixedPacket}) ->
			  send_element(StateData, FixedPacket)
		  end,
		  queue:to_list(StateData#state.queue)),
    lists:foreach(fun (FixedPacket) ->
			  send_element(StateData, FixedPacket)
		  end,
		  gb_trees:values(StateData#state.pres_queue)),
    StateData#state{queue = queue:new(), queue_len = 0,
		    pres_queue = gb_trees:empty(), standby = false}.

send_oor_message(StateData, From, To, #xmlel{name = <<"message">>} = Packet) ->
    Type = fxml:get_tag_attr_s(<<"type">>, Packet),
    if (Type == <<"normal">>) or (Type == <<"">>) or (Type == <<"chat">>) or
       StateData#state.oor_send_groupchat and
       (Type == <<"groupchat">>) ->
	    BFrom = jid:remove_resource(From),
	    LBFrom = jid:tolower(BFrom),
	    Badge = StateData#state.oor_unread + StateData#state.oor_unread_client + 1,
	    R = ejabberd_hooks:run_fold(p1_push_from_message,
					StateData#state.server,
					sent,
					[From, To, Packet,
					 StateData#state.oor_notification,
					 StateData#state.oor_appid,
					 StateData#state.oor_send_body,
					 StateData#state.oor_send_from,
					 Badge,
					 StateData#state.oor_unread == 0,
					 not (?SETS):is_element(LBFrom, StateData#state.oor_unread_users)]),
	    Packet2 = case Packet of
			  #xmlel{name = <<"message">>} ->
                              CleanPacket =
                                  fxml:remove_subtags(
                                    Packet, <<"x">>,
                                    {<<"xmlns">>, ?NS_P1_PUSHED}),
			      fxml:append_subtags(
                                CleanPacket,
                                [#xmlel{name = <<"x">>,
                                        attrs = [{<<"xmlns">>, ?NS_P1_PUSHED}]}]);
			  _ ->
			      Packet
		      end,
	    case R of
		skipped ->
		    {StateData, Packet2};
		sent ->
		    ejabberd_hooks:run(delayed_message_hook,
				       StateData#state.server,
				       [From, To, Packet]),
		    UnreadUsers = (?SETS):add_element(LBFrom, StateData#state.oor_unread_users),
		    {StateData#state{oor_unread = StateData#state.oor_unread + 1,
                                     oor_unread_users = UnreadUsers},
                     Packet2};
		sent_silent ->
		    ejabberd_hooks:run(delayed_message_hook,
				       StateData#state.server,
				       [From, To, Packet]),
		    {StateData, Packet2}
	    end;
       true ->
	    {StateData, Packet}
    end;
send_oor_message(StateData, _From, _To, Packet) ->
    {StateData, Packet}.

make_oor_presence(StateData) ->
    make_oor_presence(StateData, [], []).

make_oor_presence(StateData, PresenceAttrs, PresenceEls) ->
    ShowEl = case StateData#state.oor_show of
		 <<"available">> ->
		     [];
		 _ ->
		     [#xmlel{name = <<"show">>,
			     children = [{xmlcdata, StateData#state.oor_show}]}]
	     end,
    #xmlel{name = <<"presence">>, attrs = PresenceAttrs,
	   children = ShowEl
	   ++ [#xmlel{name = <<"status">>,
		      children = [{xmlcdata, StateData#state.oor_status}]}]
	   ++ PresenceEls}.

cancel_timer(Timer) ->
    erlang:cancel_timer(Timer),
    receive {timeout, Timer, _} -> ok after 0 -> ok end.

enqueue(StateData, From, To, Packet) ->
    IsPresence = case Packet of
		     #xmlel{name = <<"presence">>} ->
			 case fxml:get_tag_attr_s(<<"type">>, Packet) of
			     <<"subscribe">> -> false;
			     <<"subscribed">> -> false;
			     <<"unsubscribe">> -> false;
			     <<"unsubscribed">> -> false;
			     _ -> true
			 end;
		     _ ->
			 false
		 end,
    Messages = StateData#state.queue_len +
	gb_trees:size(StateData#state.pres_queue),
    if
	Messages >= (?MAX_OOR_MESSAGES) ->
	    self() ! {timeout, StateData#state.keepalive_timer, []};
	true ->
	    ok
    end,
    if IsPresence ->
	    LFrom = jid:tolower(From),
	    case jid:tolower(StateData#state.jid) == LFrom of
		true ->
		    StateData;
		false ->
		    NewQueue = gb_trees:enter(LFrom, Packet,
					      StateData#state.pres_queue),
		    StateData#state{pres_queue = NewQueue}
	    end;
       true ->
	    Packet2 = case Packet of
			  #xmlel{name = <<"message">>} ->
			      maybe_add_delay(Packet, utc, To, <<"">>);
			  _ ->
			      Packet
		      end,
	    NewQueue = queue:in({From, To, Packet2}, StateData#state.queue),
	    NewQueueLen = StateData#state.queue_len + 1,
	    StateData#state{queue = NewQueue, queue_len = NewQueueLen}
    end.

ack(StateData, From, To, Packet) ->
    if StateData#state.ack_enabled ->
	    NeedsAck = case Packet of
			   #xmlel{name = <<"presence">>} ->
			       case fxml:get_tag_attr_s(<<"type">>, Packet) of
				   <<"subscribe">> -> true;
				   <<"subscribed">> -> true;
				   <<"unsubscribe">> -> true;
				   <<"unsubscribed">> -> true;
				   _ -> false
			       end;
			   #xmlel{name = <<"message">>} ->
			       true;
			   _ ->
			       false
		       end,
	    if NeedsAck ->
		    Counter = StateData#state.ack_counter + 1,
		    NewAckQueue = queue:in({Counter, From, To, Packet},
					   StateData#state.ack_queue),
		    send_ack_request(StateData#state{ack_queue = NewAckQueue,
						     ack_counter = Counter});
	       true ->
		    StateData
	    end;
       true ->
	    StateData
    end.

send_ack_request(StateData) ->
    case StateData#state.ack_timer of
	undefined ->
	    AckCounter = StateData#state.ack_counter,
	    AckTimer = erlang:start_timer(?C2S_P1_ACK_TIMEOUT, self(), AckCounter),
	    AckTimeout = StateData#state.keepalive_timeout + StateData#state.oor_timeout,
	    erlang:send_after(AckTimeout * 1000, self(), {ack_timeout, AckTimeout}),
	    send_element(StateData, #xmlel{
				       name = <<"r">>,
				       attrs = [{<<"h">>, iolist_to_binary(integer_to_list(AckCounter))}]}),
	    StateData#state{ack_timer = AckTimer};
	_ ->
	    StateData
    end.

receive_ack(StateData, SCounter) ->
    case catch jlib:binary_to_integer(SCounter) of
	Counter when is_integer(Counter) ->
	    NewQueue = clean_queue(StateData#state.ack_queue, Counter),
	    StateData#state{ack_queue = NewQueue};
	_ ->
	    StateData
    end.

clean_queue(Queue, Counter) ->
    case queue:is_empty(Queue) of
	true ->
	    Queue;
	false ->
	    C = element(1, queue:head(Queue)),
	    if C =< Counter -> clean_queue(queue:tail(Queue), Counter);
	       true -> Queue
	    end
    end.

prepare_acks_for_rebind(StateData) ->
    AckQueue = StateData#state.ack_queue,
    case queue:is_empty(AckQueue) of
	true ->
	    StateData;
	false ->
	    Unsent = lists:map(fun ({_Counter, From, To, FixedPacket}) ->
				       {From, To, FixedPacket}
			       end,
			       queue:to_list(AckQueue)),
	    NewQueue = queue:join(queue:from_list(Unsent),
				  StateData#state.queue),
	    StateData#state{
	      queue = NewQueue,
	      queue_len = queue:len(NewQueue),
	      ack_queue = queue:new(),
	      reception = false}
    end.

rebind(StateData, JID, StreamID) ->
    case JID#jid.lresource of
	<<"">> ->
	    send_failure(StateData, ?NS_P1_REBIND, <<"Invalid JID">>),
	    fsm_next_state(wait_for_feature_request, StateData);
	_ ->
	    ejabberd_sm:route(jid:make(<<"">>, StateData#state.server, <<"">>),
			      JID, {broadcast, {rebind, self(), StreamID}}),
	    receive
		{rebind, false} ->
		    send_failure(StateData, ?NS_P1_REBIND, <<"Session not found">>),
		    fsm_next_state(wait_for_feature_request, StateData);
		{rebind, NewStateData} ->
		    ?INFO_MSG("(~w) Reopened session for ~s",
			      [StateData#state.socket, jid:to_string(JID)]),
		    SID = ejabberd_sm:make_sid(),
		    StateData2 = NewStateData#state{
				   socket = StateData#state.socket,
				   sockmod = StateData#state.sockmod,
				   socket_monitor = StateData#state.socket_monitor,
				   sid = SID,
				   ip = StateData#state.ip,
				   keepalive_timer = StateData#state.keepalive_timer,
				   ack_timer = undefined},
		    update_internal_dict(StateData2),
		    send_element(StateData2,
				 #xmlel{name = <<"rebind">>,
					attrs = [{<<"xmlns">>, ?NS_P1_REBIND}]}),
		    DebugFlag = ejabberd_hooks:run_fold(c2s_debug_start_hook,
							StateData2#state.server,
							false,
							[self(), StateData2]),
		    open_session(session_established, StateData2#state{debug = DebugFlag})
	    after 1000 ->
		    send_failure(StateData, ?NS_P1_REBIND, <<"Session not found">>),
		    fsm_next_state(wait_for_feature_request, StateData)
	    end
    end.

notif_to_disable(El, StateData) ->
    SessionNotif = StateData#state.oor_notification,
    SessionAppId = StateData#state.oor_appid,
    SpecifiedNotif = fxml:get_path_s(El, [{elem, <<"notification">>}]),
    SpecifiedAppID = fxml:get_path_s(El, [{elem, <<"appid">>}, cdata]),
    case {SpecifiedNotif, SessionNotif} of
	{#xmlel{}, #xmlel{}} ->
	    SpecifiedNormalized = {fxml:get_path_s(SpecifiedNotif, [{elem, <<"type">>}, cdata]),
				   fxml:get_path_s(SpecifiedNotif, [{elem, <<"id">>}, cdata])},
	    SessionNormalized = {fxml:get_path_s(SessionNotif, [{elem, <<"type">>}, cdata]),
				 fxml:get_path_s(SessionNotif, [{elem, <<"id">>}, cdata])},
	    if
		(SpecifiedNormalized == SessionNormalized) and (SessionAppId == SpecifiedAppID) ->
		    {ok, SessionAppId, SessionNotif}; %% match
		true ->
		    %% device ID doesn't match
		    {error, "Device data provided doesn't match with the session"}
	    end;
	{#xmlel{}, _} when SpecifiedAppID /= "" ->
	    {ok, SpecifiedAppID, SpecifiedNotif};
	{_, #xmlel{}} ->
	    {ok, SessionAppId, SessionNotif};
	{_,_} ->
	    %% Session not enabled push, and notif element not specified neither.
	    {error, "Push not enabled in this session. To disable offline push, provide the device ID and application ID"}
    end.

process_push_iq(From, To, #iq{type = _Type, sub_el = El} = IQ, StateData) ->
    {Res, NewStateData} = case El of
			      #xmlel{name = <<"push">>} ->
				  SKeepAlive = fxml:get_path_s(El,
							      [{elem, <<"keepalive">>}, {attr, <<"max">>}]),
				  SOORTimeout = fxml:get_path_s(El,
							       [{elem, <<"session">>}, {attr, <<"duration">>}]),
				  Status = fxml:get_path_s(El,
							  [{elem, <<"status">>}, cdata]),
				  Show = fxml:get_path_s(El,
							[{elem, <<"status">>}, {attr, <<"type">>}]),
				  SSendBody = fxml:get_path_s(El,
							     [{elem, <<"body">>}, {attr, <<"send">>}]),
				  SendBody =
				      case SSendBody of
					  <<"all">> -> all;
					  <<"first-per-user">> -> first_per_user;
					  <<"first">> -> first;
					  <<"none">> -> none;
					  _ ->
					      gen_mod:get_module_opt(
						StateData#state.server,
						mod_applepush,
						send_body_default,
						fun(all) -> all;
						   (first_per_user) -> first_per_user;
						   (first) -> first;
						   (none) -> none
						end,
						none)
				      end,
				  SSendGroupchat = fxml:get_path_s(El,
								  [{elem, <<"body">>}, {attr, <<"groupchat">>}]),
				  SendGroupchat =
				      case SSendGroupchat of
					  <<"true">> -> true;
					  <<"false">> -> false;
					  _ ->
					      gen_mod:get_module_opt(
						StateData#state.server,
						mod_applepush,
						send_groupchat_default,
						fun(true) -> true;
						   (false) -> false
						end,
						none)
				      end,
				  SendFrom = send_from(StateData, El),
				  {Offline, Keep} = case fxml:get_path_s(El,
									[{elem, <<"offline">>}, cdata])
						    of
							<<"true">> -> {true, false};
							<<"keep">> -> {false, true};
							<<"false">> -> {false, false};
							_ ->
							    Off =
								gen_mod:get_module_opt(
								  StateData#state.server,
								  mod_applepush,
								  offline_default,
								  fun(true) -> true;
								     (false) -> false
								  end,
								  false),
							    {Off, false}
						    end,
				  Notification1 = fxml:get_path_s(El,
								 [{elem, <<"notification">>}]),
				  Notification = case Notification1 of
						     #xmlel{} ->
							 Notification1;
						     _ ->
							 #xmlel{name = <<"notification">>,
								children =
								    [#xmlel{name = <<"type">>,
									    children = [{xmlcdata, <<"none">>}]}]}
						 end,
				  Sandbox = fxml:get_tag_attr_s(<<"apns-sandbox">>, El),
				  AppID0 = fxml:get_path_s(El, [{elem, <<"appid">>}, cdata]),
				  Type = fxml:get_path_s(Notification, [{elem, <<"type">>}, cdata]),
				  AppID = case {Type, Sandbox} of
					      {<<"applepush">>, <<"true">>} ->
						  <<AppID0/binary, "_dev">>;
					      _ ->
						  AppID0
					  end,
				  ?INFO_MSG("Enabling p1:push with gateway type ~p for ~s with appid: ~p",
					    [Type,jid:to_string(StateData#state.jid),AppID]),
				  case catch
					   {jlib:binary_to_integer(SKeepAlive),
					    jlib:binary_to_integer(SOORTimeout)}
				       of
					   {KeepAlive, OORTimeout}
					     when OORTimeout =< (?MAX_OOR_TIMEOUT) ->
					       if Offline ->
						       ejabberd_hooks:run(
							 p1_push_enable_offline, StateData#state.server,
							 [StateData#state.jid, Notification,
							  SendBody, SendFrom, AppID]);
						  Keep ->
						       ok;
						  true ->
                                                       ?INFO_MSG("Offline p1:push set to false, disabling any previous registration for ~s",[jid:to_string(StateData#state.jid)]),
						       ejabberd_hooks:run(
							 p1_push_disable, StateData#state.server,
							 [StateData#state.jid, Notification, AppID])
					       end,
					       NSD1 = StateData#state{
							keepalive_timeout = KeepAlive,
							oor_timeout = OORTimeout*60,
							oor_status = Status,
							oor_show = Show,
							oor_notification = Notification,
							oor_send_body = SendBody,
							oor_send_groupchat = SendGroupchat,
							oor_send_from = SendFrom,
							oor_appid = AppID,
							oor_offline = Offline},
					       NSD2 = start_keepalive_timer(NSD1),
					       {{result, []}, NSD2};
					   _ ->
					       {{error, ?ERR_BAD_REQUEST}, StateData}
				       end;
			      #xmlel{name = <<"disable">>} ->
				  case notif_to_disable(El, StateData) of
				      {ok, AppId, Notif} ->
					  ejabberd_hooks:run(p1_push_disable,
							     StateData#state.server,
							     [StateData#state.jid, Notif, AppId]),
					  NSD1 = StateData#state{
						   keepalive_timeout = undefined,
						   oor_timeout = undefined,
						   oor_status = <<"">>,
						   oor_show = <<"">>,
						   oor_notification = undefined,
						   oor_send_body = all},
					  NSD2 = start_keepalive_timer(NSD1),
					  {{result, []}, NSD2};
				      {error, ErrText} ->
					  Lang = StateData#state.lang,
					  Txt = iolist_to_binary(ErrText),
					  {{error, ?ERRT_NOT_ACCEPTABLE(Lang, Txt)}, StateData}
				  end;
			      #xmlel{name = <<"badge">>} ->
				  SBadge = fxml:get_path_s(El, [{attr, <<"unread">>}]),
				  Badge = case catch jlib:binary_to_integer(SBadge) of
					      B when is_integer(B) -> B;
					      _ -> 0
					  end,
				  NSD1 = StateData#state{oor_unread_client = Badge},
				  if
				      StateData#state.oor_notification == undefined ->
					  %% User didn't enable push before in this session,
					  %% we have no idea of the token.
					  {{error, ?ERR_BAD_REQUEST}, StateData};
				      StateData#state.oor_offline == true ->
					  Notif = StateData#state.oor_notification,
					  AppId = StateData#state.oor_appid,
					  R = ejabberd_hooks:run_fold(p1_push_badge_reset,
								      StateData#state.server,
								      not_handled,
								      [StateData#state.jid, Notif, AppId, Badge]),
					  case R of
					      not_handled ->
						  {{error, ?ERR_ITEM_NOT_FOUND}, NSD1};
					      ok ->
						  {{result, []}, NSD1};
					      _ ->
						  {{error, ?ERR_BAD_REQUEST}, NSD1}
					  end;
				      true ->
					  {{result, []}, NSD1}
				  end;
			      _ ->
				  {{error, ?ERR_BAD_REQUEST}, StateData}
			  end,
    IQRes = case Res of
		{result, Result} ->
		    IQ#iq{type = result, sub_el = Result};
		{error, Error} ->
		    IQ#iq{type = error, sub_el = [El, Error]}
	    end,
    ejabberd_router:route(To, From, jlib:iq_to_xml(IQRes)),
    NewStateData.

maybe_add_delay(El, TZ, From, Desc) ->
    maybe_add_delay(El, TZ, From, Desc,
		    calendar:universal_time()).

maybe_add_delay(El, TZ, From, Desc, {_, _, _} = TimeStamp) ->
    TS = calendar:now_to_universal_time(TimeStamp),
    maybe_add_delay(El, TZ, From, Desc, TS);
maybe_add_delay(#xmlel{children = Els} = El, TZ, From, Desc, TimeStamp) ->
    HasTS = lists:any(
	      fun (#xmlel{name = <<"delay">>, attrs = Attrs}) ->
		      fxml:get_attr_s(<<"xmlns">>, Attrs) == (?NS_DELAY);
		  (_) ->
		      false
	      end,
	      Els),
    if not HasTS ->
	    {T_string, Tz_string} = jlib:timestamp_to_iso(TimeStamp, TZ),
	    fxml:append_subtags(El,
			       [#xmlel{name = <<"delay">>,
				       attrs = [
						{<<"xmlns">>, ?NS_DELAY},
						{<<"from">>, jid:to_string(From)},
						{<<"stamp">>, <<T_string/binary, Tz_string/binary>>}],
				       children = [{xmlcdata, Desc}]}]);
       true ->
	    El
    end.

send_from(StateData, El) ->
    case fxml:get_path_s(El, [{elem, <<"body">>}, {attr, <<"jid">>}]) of
	<<"false">> -> none;
	<<"true">> -> jid;
	_ ->
	    case fxml:get_path_s(
		   El, [{elem, <<"body">>}, {attr, <<"from">>}])
	    of
		<<"jid">> -> jid;
		<<"username">> -> username;
		<<"name">> -> name;
		<<"none">> -> none;
		_ ->
		    gen_mod:get_module_opt(
		      StateData#state.server,
		      mod_applepush,
		      send_from_default,
		      fun(jid) -> jid;
			 (username) -> username;
			 (name) -> name;
			 (none) -> none
		      end,
		      jid)
	    end
    end.

fsm_limit_opts(Opts) ->
    case lists:keysearch(max_fsm_queue, 1, Opts) of
	{value, {_, N}} when is_integer(N) -> [{max_queue, N}];
	_ ->
	    case ejabberd_config:get_option(
		   max_fsm_queue,
		   fun(I) when is_integer(I), I > 0 -> I end) of
		undefined -> [];
		N -> [{max_queue, N}]
	    end
    end.

bounce_messages() ->
    receive {route, From, To, El = #xmlel{}} ->
	    ejabberd_router:route(From, To, El), bounce_messages()
    after 0 ->
	    ok
    end.

get_cert_file(StateData, <<"EXTERNAL">>) ->
    case is_verification_enabled(StateData) of
	true ->
	    case (StateData#state.sockmod):get_peer_certificate(
		   StateData#state.socket, otp) of
		{ok, Cert} ->
		    case verify_cert(StateData, Cert) of
			true -> Cert;
			{false, Reason} -> {Cert, Reason}
		    end;
		{error, Reason} ->
		    ?ERROR_MSG("get_peer_certificate failed: ~s", [Reason]),
		    undefined
	    end;
	false ->
	    undefined
    end;
get_cert_file(_StateData, _Mech) ->
    undefined.

verify_cert(StateData, Cert) ->
    case verify_issuer(StateData, Cert) of
	{true, CAList} ->
	    {OCSPURIs, CRLURIs} = get_verify_methods(Cert, StateData),
	    OCSP = proplists:get_value(ocsp, StateData#state.tls_options, true),
	    CRL = proplists:get_value(crl, StateData#state.tls_options, true),
	    if (OCSP == true) and (CRL == false) ->
		    case verify_via_ocsp(OCSPURIs, Cert, CAList) of
			true when StateData#state.ocsp_poll_interval /= undefined ->
			    erlang:start_timer(
			      StateData#state.ocsp_poll_interval,
			      self(), verify_via_ocsp),
			    true;
			true ->
			    true;
			{false, _} = Err ->
			    Err
		    end;
	       (CRL == true) and (OCSP == false) ->
		    verify_via_crl(CRLURIs, Cert, CAList);
	       (CRL == true) and (OCSP == true) ->
		    case verify_via_ocsp(OCSPURIs, Cert, CAList) of
			{false, <<"certificate revoked by OCSP server">>} = Err ->
			    Err;
			{false, _} ->
			    verify_via_crl(CRLURIs, Cert, CAList);
			true when StateData#state.ocsp_poll_interval /= undefined ->
			    erlang:start_timer(
			      StateData#state.ocsp_poll_interval,
			      self(), verify_via_ocsp),
			    true;
			true ->
			    true
		    end;
	       true ->
		    false
	    end;
	{false, _} = Err ->
	    Err
    end.

is_verification_enabled(#state{tls_enabled = false}) ->
    false;
is_verification_enabled(StateData) ->
    case ejabberd_config:get_option(
	   {c2s_tls_verify, StateData#state.server},
	   fun(B) when is_boolean(B) -> B end) of
	undefined ->
	    not proplists:get_bool(verify_none, StateData#state.tls_options);
	IsEnabled ->
	    IsEnabled
    end.

verify_issuer(StateData, Cert) ->
    case lists:keyfind(cafile, 1, StateData#state.tls_options) of
	false ->
	    case (StateData#state.sockmod):get_verify_result(
		   StateData#state.socket) of
		0 -> {true, []};
		_ -> {false, <<"unknown certificate issuer">>}
	    end;
	{cafile, Path} ->
	    case file:read_file(Path) of
		{ok, PemBin} ->
		    CAList = public_key:pem_decode(PemBin),
		    case is_known_issuer(Cert, CAList) of
			true -> {true, CAList};
			false -> {false, <<"unknown certificate issuer">>}
		    end;
		{error, Why} ->
		    ?ERROR_MSG("Failed to read file ~s: ~s",
			       [Path, file:format_error(Why)]),
		    {false, <<"unknown certificate issuer">>}
	    end
    end.

verify_via_ocsp(URIs, Cert, CAList) ->
    lists:foldl(
      fun(_, true) ->
	      true;
	 (URI, {false, _Reason}) ->
	      make_ocsp_request(iolist_to_binary(URI), Cert, CAList)
      end,
      {false, <<"no OCSP URIs found in certificate">>},
      URIs).

verify_via_crl(URIs, Cert, CAList) ->
    lists:foldl(
      fun (_, true) ->
	      true;
	  (URI, {false, _Reason}) ->
	      case make_crl_request(URI) of
		  {ok, CRL} ->
		      case is_known_issuer(CRL, CAList) of
			  true ->
			      case is_revoked(Cert, CRL) of
				  true ->
				      {false, <<"certificate is revoked">>};
				  false ->
				      true
			      end;
			  false ->
			      ?ERROR_MSG("CRL from ~s is signed by unknown CA",
					 [URI]),
			      {false, <<"CRL is signed by unknown CA">>}
		      end;
		  error ->
		      {false, <<"failed to fetch CRL file">>}
	      end
      end, {false, <<"no CRL URIs found in certificate">>}, URIs).

get_verify_methods(Cert, StateData) ->
    TBSCert = Cert#'OTPCertificate'.tbsCertificate,
    lists:foldl(
      fun(#'Extension'{extnID = ?'id-pe-authorityInfoAccess', extnValue = AccessInfo},
	  {OCSPURIs, CRLURIs}) when is_list(AccessInfo) ->
	      URIs = lists:flatmap(
		       fun(#'AccessDescription'{
			      accessMethod = ?'id-pkix-ocsp',
			      accessLocation = {uniformResourceIdentifier, URI}}) ->
			       [URI];
			  (_) ->
			       []
		       end, AccessInfo),
	      {URIs ++ OCSPURIs, CRLURIs};
	 (#'Extension'{extnID = ?'id-ce-cRLDistributionPoints', extnValue = DistPoints},
	  {OCSPURIs, CRLURIs}) when is_list(DistPoints) ->
	      URIs = lists:flatmap(
		       fun(#'DistributionPoint'{
			      distributionPoint = {fullName, GenNames}}) ->
			       lists:flatmap(
				 fun({uniformResourceIdentifier, URI}) ->
					 [URI];
				    (_) ->
					 []
				 end, GenNames);
			  (_) ->
			       []
		       end, DistPoints),
	      {OCSPURIs, URIs ++ CRLURIs};
	 (_, Acc) ->
	      Acc
      end,
      {StateData#state.ocsp_fallback_uri_list, []},
      TBSCert#'OTPTBSCertificate'.extensions).

make_ocsp_request(URI0, Cert, CAList) ->
    URI = binary_to_list(URI0),
    IssuerCert = get_issuer(Cert, CAList),
    TBSCert = Cert#'OTPCertificate'.tbsCertificate,
    TBSIssuerCert = IssuerCert#'OTPCertificate'.tbsCertificate,
    SerialNumber = TBSCert#'OTPTBSCertificate'.serialNumber,
    SubjPubKeyInfo = TBSIssuerCert#'OTPTBSCertificate'.subjectPublicKeyInfo,
    RSAPubKey = SubjPubKeyInfo#'OTPSubjectPublicKeyInfo'.subjectPublicKey,
    IssuerDN = public_key:pkix_encode(
		 'Name', TBSCert#'OTPTBSCertificate'.issuer, otp),
    IssuerPubKey = public_key:pkix_encode('RSAPublicKey', RSAPubKey, otp),
    AlgoID = #'AlgorithmIdentifier'{algorithm = ?'id-sha1'},
    CertID = #'CertID'{hashAlgorithm = AlgoID,
		       issuerNameHash = crypto:hash(sha, IssuerDN),
		       issuerKeyHash = crypto:hash(sha, IssuerPubKey),
		       serialNumber = SerialNumber},
    TBSReq = #'TBSRequest'{requestList = [#'Request'{reqCert = CertID}]},
    Request = #'OCSPRequest'{tbsRequest = TBSReq},
    {ok, Body} = 'OCSP':encode('OCSPRequest', Request),
    case http_p1:post(URI, [{<<"content-type">>,
			     <<"application/ocsp-request">>}], Body) of
	{ok, 200, _, Response} ->
	    case 'OCSP':decode('OCSPResponse', Response) of
		{ok, #'OCSPResponse'{
			responseStatus = successful,
			responseBytes = #'ResponseBytes'{
					   responseType = ?'id-pkix-ocsp-basic',
					   response = RespBytes}}} ->
		    case 'OCSP':decode('BasicOCSPResponse', RespBytes) of
			{ok, #'BasicOCSPResponse'{
				tbsResponseData =
				    #'ResponseData'{
				       responses = [#'SingleResponse'{
						       certStatus = Status}]}}} ->
			    case Status of
				{good, _} ->
				    true;
				{revoked, _} ->
				    {false, <<"certificate revoked by OCSP server">>};
				{unknown, _} ->
				    {false, <<"certificate status is unknown by OCSP server">>}
			    end;
			Err ->
			    ?ERROR_MSG("failed to decode response from OCSP server: ~p",
				       [Err]),
			    {false, <<"failed to decode response from OCSP server">>}
		    end;
		{ok, #'OCSPResponse'{responseStatus = Status}} ->
		    Reason = io_lib:fwrite("rejected by OCSP server with reason: ~s", [Status]),
		    {false, list_to_binary(Reason)};
		Err ->
		    ?ERROR_MSG("failed to decode response from OCSP server: ~p",
			       [Err]),
		    {false, <<"failed to decode response from OCSP server">>}
	    end;
	Err ->
	    ?ERROR_MSG("OCSP server HTTP error: ~p", [Err]),
	    {false, <<"request to OCSP server failed">>}
    end.

make_crl_request(URI0) ->
    URI = iolist_to_binary(URI0),
    cache_tab:dirty_lookup(crls, URI, fun() -> fetch_crl_http(URI) end).

fetch_crl_http(URI0) ->
    URI = binary_to_list(URI0),
    case http_p1:get(URI) of
	{ok, 200, _, BinCRL} ->
	    {ok, public_key:der_decode('CertificateList', BinCRL)};
	Err ->
	    ?ERROR_MSG("failed to fetch CRL from ~s: ~p", [URI, Err]),
	    error
    end.

is_revoked(Cert, CRL) ->
    TBSCert = Cert#'OTPCertificate'.tbsCertificate,
    TBSCertList = CRL#'CertificateList'.tbsCertList,
    SerialNumber = TBSCert#'OTPTBSCertificate'.serialNumber,
    case TBSCertList#'TBSCertList'.revokedCertificates of
	RevokedCerts when is_list(RevokedCerts) ->
	    lists:any(
	      fun (#'TBSCertList_revokedCertificates_SEQOF'{userCertificate = N}) ->
		      SerialNumber == N;
		  (_) ->
		      false
	      end, RevokedCerts);
	_ ->
	    false
    end.

is_known_issuer(_Cert, []) ->
    true;
is_known_issuer(Cert, CAList) ->
    lists:any(
      fun ({'Certificate', Issuer, _}) ->
	      public_key:pkix_is_issuer(Cert, Issuer);
	  (_) ->
	      false
      end, CAList).

%% Cert must be issued by the CA list provided or function clause will be
%% generated. So call is_known_issuer() first.
get_issuer(Cert, [{'Certificate', DER, _}|CAList]) ->
    Issuer = public_key:pkix_decode_cert(DER, otp),
    case public_key:pkix_is_issuer(Cert, Issuer) of
	true -> Issuer;
	false -> get_issuer(Cert, CAList)
    end.

%%%----------------------------------------------------------------------
%%% XEP-0191
%%%----------------------------------------------------------------------

route_blocking(What, StateData) ->
    SubEl = case What of
		{block, JIDs} ->
		    #xmlel{name = <<"block">>,
			   attrs = [{<<"xmlns">>, ?NS_BLOCKING}],
			   children =
			       [#xmlel{name = <<"item">>,
				       attrs = [{<<"jid">>, jid:to_string(JID)}]}
				|| JID <- JIDs]};
		{unblock, JIDs} ->
		    #xmlel{name = <<"unblock">>,
			   attrs = [{<<"xmlns">>, ?NS_BLOCKING}],
			   children =
			       [#xmlel{name = <<"item">>,
				       attrs = [{<<"jid">>, jid:to_string(JID)}]}
				|| JID <- JIDs]};
		unblock_all ->
		    #xmlel{name = <<"unblock">>,
			   attrs = [{<<"xmlns">>, ?NS_BLOCKING}]}
	    end,
    PrivPushIQ = #iq{type = set, xmlns = ?NS_BLOCKING,
		     id = <<"push">>, sub_el = [SubEl]},
    PrivPushEl =
	jlib:replace_from_to(jid:remove_resource(StateData#state.jid),
			     StateData#state.jid, jlib:iq_to_xml(PrivPushIQ)),
    %% No need to replace active privacy list here,
    %% blocking pushes are always accompanied by
    %% Privacy List pushes
    send_stanza(StateData, PrivPushEl).

%%%----------------------------------------------------------------------
%%% XEP-0198
%%%----------------------------------------------------------------------

stream_mgmt_enabled(#state{mgmt_state = disabled}) ->
    false;
stream_mgmt_enabled(_StateData) ->
    true.

dispatch_stream_mgmt(El, #state{mgmt_state = MgmtState} = StateData)
    when MgmtState == active;
	 MgmtState == pending ->
    perform_stream_mgmt(El, StateData);
dispatch_stream_mgmt(El, StateData) ->
    negotiate_stream_mgmt(El, StateData).

negotiate_stream_mgmt(_El, #state{resource = <<"">>} = StateData) ->
    %% XEP-0198 says: "For client-to-server connections, the client MUST NOT
    %% attempt to enable stream management until after it has completed Resource
    %% Binding unless it is resuming a previous session".  However, it also
    %% says: "Stream management errors SHOULD be considered recoverable", so we
    %% won't bail out.
    send_element(StateData, ?MGMT_UNEXPECTED_REQUEST(?NS_STREAM_MGMT_3)),
    StateData;
negotiate_stream_mgmt(#xmlel{name = Name, attrs = Attrs}, StateData) ->
    case fxml:get_attr_s(<<"xmlns">>, Attrs) of
	Xmlns when ?IS_SUPPORTED_MGMT_XMLNS(Xmlns) ->
	    case stream_mgmt_enabled(StateData) of
		true ->
		    case Name of
			<<"enable">> ->
			    handle_enable(StateData#state{mgmt_xmlns = Xmlns}, Attrs);
			_ ->
			    Res = if Name == <<"a">>;
				     Name == <<"r">>;
				     Name == <<"resume">> ->
					  ?MGMT_UNEXPECTED_REQUEST(Xmlns);
				     true ->
					  ?MGMT_BAD_REQUEST(Xmlns)
				  end,
			    send_element(StateData, Res),
			    StateData
		    end;
		false ->
		    send_element(StateData, ?MGMT_SERVICE_UNAVAILABLE(Xmlns)),
		    StateData
	    end;
	_ ->
	    send_element(StateData, ?MGMT_UNSUPPORTED_VERSION(?NS_STREAM_MGMT_3)),
	    StateData
    end.

perform_stream_mgmt(#xmlel{name = Name, attrs = Attrs}, StateData) ->
    case fxml:get_attr_s(<<"xmlns">>, Attrs) of
	Xmlns when Xmlns == StateData#state.mgmt_xmlns ->
	    case Name of
		<<"r">> ->
		    handle_r(StateData);
		<<"a">> ->
		    handle_a(StateData, Attrs);
		_ ->
		    Res = if Name == <<"enable">>;
			     Name == <<"resume">> ->
				  ?MGMT_UNEXPECTED_REQUEST(Xmlns);
			     true ->
				  ?MGMT_BAD_REQUEST(Xmlns)
			  end,
		    send_element(StateData, Res),
		    StateData
	    end;
	_ ->
	    send_element(StateData,
			 ?MGMT_UNSUPPORTED_VERSION(StateData#state.mgmt_xmlns)),
	    StateData
    end.

handle_enable(#state{mgmt_timeout = DefaultTimeout,
		     mgmt_max_timeout = MaxTimeout} = StateData, Attrs) ->
    Timeout = case fxml:get_attr_s(<<"resume">>, Attrs) of
		  ResumeAttr when ResumeAttr == <<"true">>;
				  ResumeAttr == <<"1">> ->
		    MaxAttr = fxml:get_attr_s(<<"max">>, Attrs),
		      case catch jlib:binary_to_integer(MaxAttr) of
			  Max when is_integer(Max), Max > 0, Max =< MaxTimeout ->
			      Max;
			  _ ->
			      DefaultTimeout
		      end;
		  _ ->
		      0
	      end,
    ResAttrs = [{<<"xmlns">>, StateData#state.mgmt_xmlns}] ++
	if Timeout > 0 ->
		?INFO_MSG("Stream management with resumption enabled for ~s",
			  [jid:to_string(StateData#state.jid)]),
		[{<<"id">>, make_resume_id(StateData)},
		 {<<"resume">>, <<"true">>},
		 {<<"max">>, jlib:integer_to_binary(Timeout)}];
	   true ->
		?INFO_MSG("Stream management without resumption enabled for ~s",
			  [jid:to_string(StateData#state.jid)]),
		[]
	end,
    Res = #xmlel{name = <<"enabled">>, attrs = ResAttrs},
    send_element(StateData, Res),
    StateData#state{
      mgmt_state = active,
      mgmt_queue = queue:new(),
      mgmt_timeout = Timeout * 1000}.

handle_r(StateData) ->
    H = jlib:integer_to_binary(StateData#state.mgmt_stanzas_in),
    Res = #xmlel{name = <<"a">>,
		 attrs = [{<<"xmlns">>, StateData#state.mgmt_xmlns},
			  {<<"h">>, H}]},
    send_element(StateData, Res),
    StateData.

handle_a(StateData, Attrs) ->
    case catch jlib:binary_to_integer(fxml:get_attr_s(<<"h">>, Attrs)) of
	H when is_integer(H), H >= 0 ->
	    check_h_attribute(StateData, H);
	_ ->
	    ?DEBUG("Ignoring invalid ACK element from ~s",
		   [jid:to_string(StateData#state.jid)]),
	    StateData
    end.

handle_resume(StateData, Attrs) ->
    R = case fxml:get_attr_s(<<"xmlns">>, Attrs) of
	    Xmlns when ?IS_SUPPORTED_MGMT_XMLNS(Xmlns) ->
		case stream_mgmt_enabled(StateData) of
		    true ->
		    case {fxml:get_attr(<<"previd">>, Attrs),
			  catch jlib:binary_to_integer(fxml:get_attr_s(<<"h">>, Attrs))}
			of
			    {{value, PrevID}, H} when is_integer(H), H >= 0 ->
				case inherit_session_state(StateData, PrevID) of
				    {ok, InheritedState} ->
					{ok, InheritedState, H};
			    {error, Err, InH} ->
				{error, ?MGMT_ITEM_NOT_FOUND_H(Xmlns, InH), Err};
				    {error, Err} ->
					{error, ?MGMT_ITEM_NOT_FOUND(Xmlns), Err}
				end;
			    _ ->
				{error, ?MGMT_BAD_REQUEST(Xmlns),
				 <<"Invalid request">>}
			end;
		    false ->
			{error, ?MGMT_SERVICE_UNAVAILABLE(Xmlns),
			 <<"XEP-0198 disabled">>}
		end;
	    _ ->
		{error, ?MGMT_UNSUPPORTED_VERSION(?NS_STREAM_MGMT_3),
		 <<"Invalid XMLNS">>}
	end,
    case R of
	{ok, ResumedState, NumHandled} ->
	    NewState = check_h_attribute(ResumedState, NumHandled),
	    AttrXmlns = NewState#state.mgmt_xmlns,
	    AttrId = make_resume_id(NewState),
	    AttrH = jlib:integer_to_binary(NewState#state.mgmt_stanzas_in),
	    send_element(NewState,
			 #xmlel{name = <<"resumed">>,
				attrs = [{<<"xmlns">>, AttrXmlns},
					 {<<"h">>, AttrH},
					 {<<"previd">>, AttrId}]}),
	    SendFun = fun(_F, _T, El, Time) ->
			      NewEl = add_resent_delay_info(NewState, El, Time),
			      send_element(NewState, NewEl)
		      end,
	    handle_unacked_stanzas(NewState, SendFun),
	    send_element(NewState,
			 #xmlel{name = <<"r">>,
				attrs = [{<<"xmlns">>, AttrXmlns}]}),
	    FlushedState = csi_flush_queue(NewState),
	    NewStateData = FlushedState#state{csi_state = active},
	    ?INFO_MSG("Resumed session for ~s",
		      [jid:to_string(NewStateData#state.jid)]),
	    {ok, NewStateData};
	{error, El, Msg} ->
	    send_element(StateData, El),
	    ?INFO_MSG("Cannot resume session for ~s@~s: ~s",
		      [StateData#state.user, StateData#state.server, Msg]),
	    error
    end.

check_h_attribute(#state{mgmt_stanzas_out = NumStanzasOut} = StateData, H)
  when H > NumStanzasOut ->
    ?DEBUG("~s acknowledged ~B stanzas, but only ~B were sent",
	   [jid:to_string(StateData#state.jid), H, NumStanzasOut]),
    mgmt_queue_drop(StateData#state{mgmt_stanzas_out = H}, NumStanzasOut);
check_h_attribute(#state{mgmt_stanzas_out = NumStanzasOut} = StateData, H) ->
    ?DEBUG("~s acknowledged ~B of ~B stanzas",
	   [jid:to_string(StateData#state.jid), H, NumStanzasOut]),
    mgmt_queue_drop(StateData, H).

update_num_stanzas_in(#state{mgmt_state = MgmtState} = StateData, El)
    when MgmtState == active;
	 MgmtState == pending ->
    NewNum = case {is_stanza(El), StateData#state.mgmt_stanzas_in} of
		 {true, 4294967295} -> 0;
		 {true, Num} -> Num + 1;
		 {false, Num} -> Num
	     end,
    StateData#state{mgmt_stanzas_in = NewNum};
update_num_stanzas_in(StateData, _El) ->
    StateData.

send_stanza_and_ack_req(StateData, Stanza) ->
    AckReq = #xmlel{name = <<"r">>,
		    attrs = [{<<"xmlns">>, StateData#state.mgmt_xmlns}],
		    children = []},
    case send_element(StateData, Stanza) == ok andalso
	send_element(StateData, AckReq) == ok of
	true -> StateData;
	false -> StateData#state{mgmt_state = pending}
    end.

mgmt_queue_add(StateData, El) ->
    NewNum = case StateData#state.mgmt_stanzas_out of
		 4294967295 -> 0;
		 Num -> Num + 1
	     end,
    NewQueue = queue:in({NewNum, p1_time_compat:timestamp(), El}, StateData#state.mgmt_queue),
    NewState = StateData#state{mgmt_queue = NewQueue,
			       mgmt_stanzas_out = NewNum},
    check_queue_length(NewState).

mgmt_queue_drop(StateData, NumHandled) ->
    NewQueue = jlib:queue_drop_while(fun({N, _T, _E}) -> N =< NumHandled end,
				     StateData#state.mgmt_queue),
    StateData#state{mgmt_queue = NewQueue}.

check_queue_length(#state{mgmt_max_queue = Limit} = StateData)
  when Limit == infinity;
       Limit == exceeded ->
    StateData;
check_queue_length(#state{mgmt_queue = Queue,
			  mgmt_max_queue = Limit} = StateData) ->
    case queue:len(Queue) > Limit of
	true -> StateData#state{mgmt_max_queue = exceeded};
	false -> StateData
    end.

handle_unacked_stanzas(#state{mgmt_state = MgmtState} = StateData, F)
    when MgmtState == active;
	 MgmtState == pending;
	 MgmtState == timeout ->
    Queue = StateData#state.mgmt_queue,
    case queue:len(Queue) of
	0 ->
	    ok;
	N ->
	  ?DEBUG("~B stanza(s) were not acknowledged by ~s",
		      [N, jid:to_string(StateData#state.jid)]),
	    lists:foreach(
	      fun({_, Time, #xmlel{attrs = Attrs} = El}) ->
		    From_s = fxml:get_attr_s(<<"from">>, Attrs),
		    To_s = fxml:get_attr_s(<<"to">>, Attrs),
		    case {jid:from_string(From_s), jid:from_string(To_s)} of
		      {#jid{} = From, #jid{} = To} ->
			  F(From, To, El, Time);
		      {_, _} ->
			  ?DEBUG("Dropping stanza due to invalid JID(s)", [])
		    end
	      end, queue:to_list(Queue))
    end;
handle_unacked_stanzas(_StateData, _F) ->
    ok.

handle_unacked_stanzas(#state{mgmt_state = MgmtState} = StateData)
    when MgmtState == active;
	 MgmtState == pending;
	 MgmtState == timeout ->
    ResendOnTimeout =
	case StateData#state.mgmt_resend of
	    Resend when is_boolean(Resend) ->
		Resend;
	    if_offline ->
	      Resource = StateData#state.resource,
	      case ejabberd_sm:get_user_resources(StateData#state.user,
						  StateData#state.server) of
		[Resource] -> % Same resource opened new session
		    true;
		[] ->
		    true;
		_ ->
		    false
	      end
	end,
    Lang = StateData#state.lang,
    ReRoute = case ResendOnTimeout of
		  true ->
		      fun(From, To, El, Time) ->
			      NewEl = add_resent_delay_info(StateData, El, Time),
			      ejabberd_router:route(From, To, NewEl)
		      end;
		  false ->
		      fun(From, To, El, _Time) ->
			    Txt = <<"User session terminated">>,
			    Err =
				jlib:make_error_reply(
				  El,
				  ?ERRT_SERVICE_UNAVAILABLE(Lang, Txt)),
			      ejabberd_router:route(To, From, Err)
		      end
	      end,
    F = fun(From, _To, #xmlel{name = <<"presence">>}, _Time) ->
		?DEBUG("Dropping presence stanza from ~s",
		       [jid:to_string(From)]);
	   (From, To, #xmlel{name = <<"iq">>} = El, _Time) ->
		Txt = <<"User session terminated">>,
		Err = jlib:make_error_reply(
			El, ?ERRT_SERVICE_UNAVAILABLE(Lang, Txt)),
		ejabberd_router:route(To, From, Err);
	   (From, To, El, Time) ->
		%% We'll drop the stanza if it was <forwarded/> by some
		%% encapsulating protocol as per XEP-0297.  One such protocol is
		%% XEP-0280, which says: "When a receiving server attempts to
		%% deliver a forked message, and that message bounces with an
		%% error for any reason, the receiving server MUST NOT forward
		%% that error back to the original sender."  Resending such a
		%% stanza could easily lead to unexpected results as well.
		case is_encapsulated_forward(El) of
		    true ->
			?DEBUG("Dropping forwarded message stanza from ~s",
			     [fxml:get_attr_s(<<"from">>, El#xmlel.attrs)]);
		    false ->
		      case ejabberd_hooks:run_fold(message_is_archived,
						   StateData#state.server,
						   false,
						   [StateData, From,
						    StateData#state.jid, El]) of
			true ->
			    ?DEBUG("Dropping archived message stanza from ~s",
				   [fxml:get_attr_s(<<"from">>,
						    El#xmlel.attrs)]),
			    ok;
			false ->
			ReRoute(From, To, El, Time)
		end
		end
	end,
    handle_unacked_stanzas(StateData, F);
handle_unacked_stanzas(_StateData) ->
    ok.

is_encapsulated_forward(#xmlel{name = <<"message">>} = El) ->
    SubTag = case {fxml:get_subtag(El, <<"sent">>),
		   fxml:get_subtag(El, <<"received">>),
		   fxml:get_subtag(El, <<"result">>)}
	     of
		 {false, false, false} -> false;
		 {Tag, false, false} -> Tag;
		 {false, Tag, false} -> Tag;
		 {_, _, Tag} -> Tag
	     end,
    if SubTag == false ->
	    false;
       true ->
	    case fxml:get_subtag(SubTag, <<"forwarded">>) of
		false -> false;
		_ -> true
	    end
    end;
is_encapsulated_forward(_El) ->
    false.

inherit_session_state(#state{user = U, server = S} = StateData, ResumeID) ->
    case jlib:base64_to_term(ResumeID) of
	{term, {R, Time}} ->
	    case ejabberd_sm:get_session_pid(U, S, R) of
		none ->
		case ejabberd_sm:get_offline_info(Time, U, S, R) of
		  none ->
		    {error, <<"Previous session PID not found">>};
		  Info ->
		      case proplists:get_value(num_stanzas_in, Info) of
			undefined ->
			    {error, <<"Previous session timed out">>};
			H ->
			    {error, <<"Previous session timed out">>, H}
		      end
		end;
		OldPID ->
		    OldSID = {Time, OldPID},
		    case catch resume_session(OldSID) of
		  {resume, OldStateData} ->
			    NewSID = {Time, self()}, % Old time, new PID
			    Priority = case OldStateData#state.pres_last of
					   undefined -> 0;
					   Presence -> get_priority_from_presence(Presence)
				       end,
			    Conn = ejabberd_socket:get_conn_type(StateData#state.socket),
			    Info = [{ip, StateData#state.ip}, {conn, Conn},
				    {auth_module, StateData#state.auth_module}],
			    NewStateData = StateData#state{
					     conn = Conn,
					     sid = NewSID,
					     jid = OldStateData#state.jid,
					     resource = OldStateData#state.resource,
					     pres_t = OldStateData#state.pres_t,
					     pres_f = OldStateData#state.pres_f,
					     pres_a = OldStateData#state.pres_a,
					     pres_last = OldStateData#state.pres_last,
					     pres_timestamp = OldStateData#state.pres_timestamp,
					     privacy_list = OldStateData#state.privacy_list,
					     aux_fields = OldStateData#state.aux_fields,
					     csi_state = OldStateData#state.csi_state,
					     csi_queue = OldStateData#state.csi_queue, % remove after 3.2.15
					     mgmt_xmlns = OldStateData#state.mgmt_xmlns,
					     mgmt_queue = OldStateData#state.mgmt_queue,
					     mgmt_timeout = OldStateData#state.mgmt_timeout,
					     mgmt_stanzas_in = OldStateData#state.mgmt_stanzas_in,
					     mgmt_stanzas_out = OldStateData#state.mgmt_stanzas_out,
					     mgmt_state = active},
			    sm_open_session(NewStateData, Priority, Info),
			    {ok, NewStateData};
			{error, Msg} ->
			    {error, Msg};
			_ ->
			    {error, <<"Cannot grab session state">>}
		    end
	    end;
	_ ->
	    {error, <<"Invalid 'previd' value">>}
    end.

resume_session({Time, PID}) ->
    (?GEN_FSM):sync_send_all_state_event(PID, {resume_session, Time}, 15000).

make_resume_id(StateData) ->
    {Time, _} = StateData#state.sid,
    jlib:term_to_base64({StateData#state.resource, Time}).

fix_packet(StateData, FromJID, ToJID, El) ->
    ejabberd_hooks:run_fold(
      user_send_packet, StateData#state.server,
      El, [StateData, FromJID, ToJID]).

add_resent_delay_info(_State, #xmlel{name = <<"iq">>} = El, _Time) ->
    El;
add_resent_delay_info(#state{server = From}, El, Time) ->
    jlib:add_delay_info(El, From, Time, <<"Resent">>).

filter_incoming_message(StateData, From, To, Packet) ->
    case ejabberd_hooks:run_fold(
           feature_check_packet,
           StateData#state.server,
           allow,
           [StateData#state.jid,
            StateData#state.server,
            StateData#state.pres_last,
            {From, To, Packet}, in]) of
        allow ->
            case ejabberd_hooks:run_fold(
                   c2s_filter_incoming_packet,
                   StateData#state.server,
                   allow,
                   [StateData, From, To, Packet]) of
                allow ->
                    allow;
                deny ->
                    deny
            end;
        deny ->
            deny
    end.

%%%----------------------------------------------------------------------
%%% XEP-0352
%%%----------------------------------------------------------------------

csi_filter_stanza(#state{csi_state = CsiState, server = Server} = StateData,
		  Stanza) ->
    {StateData1, Stanzas} = ejabberd_hooks:run_fold(csi_filter_stanza, Server,
						    {StateData, [Stanza]},
						    [Server, Stanza]),
    StateData2 = lists:foldl(fun(CurStanza, AccState) ->
				     send_stanza(AccState, CurStanza)
			     end, StateData1#state{csi_state = active},
			     Stanzas),
    StateData2#state{csi_state = CsiState}.

csi_flush_queue(#state{csi_state = CsiState, server = Server} = StateData) ->
    {StateData1, Stanzas} = ejabberd_hooks:run_fold(csi_flush_queue, Server,
						    {StateData, []}, [Server]),
    StateData2 = lists:foldl(fun(CurStanza, AccState) ->
				     send_stanza(AccState, CurStanza)
			     end, StateData1#state{csi_state = active},
			     Stanzas),
    StateData2#state{csi_state = CsiState}.

%%%----------------------------------------------------------------------
%%% JID Set memory footprint reduction code
%%%----------------------------------------------------------------------

pack(S) -> S.

flash_policy_string() ->
    Listen = ejabberd_config:get_option(listen, fun(V) -> V end),
    Ports = lists:filtermap(fun(Opt) ->
				    case {lists:keyfind(module, 1, Opt), lists:keyfind(port, 1, Opt)} of
					{{module, M}, {port, P}} when M == ejabberd_c2s;
								      M == ejabberd_http ->
					    {true, integer_to_list(P)};
					_ ->
					    false
				    end
			    end, Listen),
    ToPortsString = iolist_to_binary(string:join(Ports, ",")),
    <<"<?xml version=\"1.0\"?>\n<!DOCTYPE cross-doma"
      "in-policy SYSTEM \"http://www.macromedia.com/"
      "xml/dtds/cross-domain-policy.dtd\">\n<cross-d"
      "omain-policy>\n  <allow-access-from "
      "domain=\"*\" to-ports=\"",
      ToPortsString/binary,
      "\"/>\n</cross-domain-policy>\n\000">>.

need_redirect(#state{redirect = true}) ->
    case ejabberd_config:get_option(
	   redirect_host, fun iolist_to_binary/1) of
	undefined -> false;
	Host -> {true, Host}
    end;
need_redirect(_) ->
    false.

get_jid_from_opts(Opts) ->
    case lists:keysearch(jid, 1, Opts) of
	{value, {_, JIDValue}} ->
	    JID = case JIDValue of
		      {_U, _S, _R} -> jid:make(JIDValue);
		      _ when is_list(JIDValue) ->
			  jid:from_string(list_to_binary(JIDValue));
		      _ when is_binary(JIDValue) ->
			  jid:from_string(JIDValue);
		      _ -> JIDValue
		  end,
	    {ok, JID};
	_ -> error
    end.

update_internal_dict(#state{sockmod = SockMod,
			    xml_socket = XMLSocket,
			    socket = Socket} = StateData) ->
    put(c2s_sockmod, SockMod),
    put(c2s_xml_socket, XMLSocket),
    put(c2s_socket, Socket),
    StateData.

transform_listen_option(Opt, Opts) ->
    [Opt|Opts].

is_remote_socket(SockMod, XMLSocket, Socket) ->
    SockMod == ejabberd_frontend_socket orelse
	XMLSocket == true orelse
	SockMod:is_remote_receiver(Socket).


%%% Adds a signature to features list to track customers

format_features(Els) ->
    format_features(Els, 0).

-define(FEATURES_MAGIC, 572347577).

format_features([], _N) ->
    [];
format_features([El | Els], N) ->
    S = if
	    (?FEATURES_MAGIC bsr N) band 1 == 1 -> <<"\s\n">>;
	    true -> <<"\n">>
	end,
    [El, {xmlcdata, S} | format_features(Els, N + 1)].

opt_type(c2s_tls_verify) ->
    fun (B) when is_boolean(B) -> B end;
opt_type(domain_certfile) -> fun iolist_to_binary/1;
opt_type(flash_hack) ->
    fun (B) when is_boolean(B) -> B end;
opt_type(listen) -> fun (V) -> V end;
opt_type(max_fsm_queue) ->
    fun (I) when is_integer(I), I > 0 -> I end;
opt_type(redirect_host) -> fun iolist_to_binary/1;
opt_type(async_offline_resend) ->
    fun (B) when is_boolean(B) -> B end;
opt_type(_) ->
    [c2s_tls_verify, domain_certfile, flash_hack, listen,
     max_fsm_queue, redirect_host, async_offline_resend].

%%%%%% ADDED FOR FACTORIZATION
accept_auth(StateData, Props) ->
    U = identity(Props),
    AuthModule = proplists:get_value(auth_module, Props),
    accept_auth(StateData, U, AuthModule),
    {U, AuthModule}.
accept_auth(StateData, U, AuthModule) ->
    ?INFO_MSG("(~w) Accepted authentication for ~s@~s by ~p from ~s",
	      [StateData#state.socket, U, StateData#state.server, AuthModule,
	       ejabberd_config:may_hide_data(jlib:ip_to_list(StateData#state.ip))]),
    ejabberd_hooks:run(c2s_auth_result, StateData#state.server,
		       [true, U, StateData#state.server, StateData#state.ip]).
accept_auth(StateData, U, JID, AuthModule) ->
    ?INFO_MSG("(~w) Accepted legacy authentication for ~s by ~p from ~s",
	      [StateData#state.socket, jid:to_string(JID), AuthModule,
	       ejabberd_config:may_hide_data(jlib:ip_to_list(StateData#state.ip))]),
    ejabberd_hooks:run(c2s_auth_result, StateData#state.server,
		       [true, U, StateData#state.server, StateData#state.ip]).

reject_auth(_StateData, <<"">>, _Reason) ->
    ok;
reject_auth(StateData, U, Reason) ->
    ?INFO_MSG("(~w) Failed authentication for ~s@~s from ~s: ~s",
	      [StateData#state.socket, U, StateData#state.server,
	       ejabberd_config:may_hide_data(jlib:ip_to_list(StateData#state.ip)),
	       Reason]),
    ejabberd_hooks:run(c2s_auth_result, StateData#state.server,
		       [false, U, StateData#state.server, StateData#state.ip]).
reject_auth(StateData, U, JID, Reason) ->
    ?INFO_MSG("(~w) Failed legacy authentication for ~s from ~s: ~s",
	      [StateData#state.socket, jid:to_string(JID),
	       ejabberd_config:may_hide_data(jlib:ip_to_list(StateData#state.ip)),
	       Reason]),
    ejabberd_hooks:run(c2s_auth_result, StateData#state.server,
		       [false, U, StateData#state.server, StateData#state.ip]).

fsm_next_sasl_state(StateData, Props, ServerOut) ->
    catch (StateData#state.sockmod):reset_stream(StateData#state.socket),
    {U, AuthModule} = accept_auth(StateData, Props),
    case need_redirect(StateData#state{user = U}) of
	{true, Host} ->
	    fsm_stop_seeotherhost(StateData, U, Host);
	false ->
	    send_element(StateData,
			 #xmlel{name = <<"success">>,
				attrs = [{<<"xmlns">>, ?NS_SASL}],
				children = [{xmlcdata, jlib:encode_base64(ServerOut)}
					    || ServerOut =/= <<"">>]}),
	    fsm_next_state(wait_for_stream,
			   StateData#state{streamid = new_id(),
					   authenticated = true,
					   auth_module = AuthModule,
					   sasl_state = undefined,
					   user = U})
    end.

fsm_stop_conflict(StateData, Reason) ->
    Lang = StateData#state.lang,
    fsm_send_and_stop(StateData, ?SERRT_CONFLICT(Lang, Reason)).

fsm_stop_violation(StateData, Reason) ->
    Lang = StateData#state.lang,
    fsm_send_and_stop(StateData, ?POLICY_VIOLATION_ERR(Lang, Reason)).

fsm_stop_seeotherhost(StateData, U, Host) ->
    ?INFO_MSG("(~w) Redirecting ~s to ~s", [StateData#state.socket, U, Host]),
    fsm_send_and_stop(StateData, ?SERR_SEE_OTHER_HOST(Host)).

fsm_send_and_stop(StateData, Server, Version, Lang, El) ->
    send_header(StateData, Server, Version, Lang),
    fsm_send_and_stop(StateData, El).
fsm_send_and_stop(StateData, El) ->
    send_element(StateData, El),
    fsm_stop(StateData).

fsm_stop(StateData) ->
    {stop, normal, StateData}.

fsm_stopped(StateData) ->
    {stop, normal, stopped, StateData}.

send_failure(StateData, NS, Error, Txt)
  when is_binary(Error), is_binary(Txt) ->
    send_failure(StateData, NS, [#xmlel{name = Error,
					children = [#xmlel{name = <<"text">>,
							   children = [{xmlcdata, Txt}]}
						    || Txt =/= <<"">>]}]).
send_failure(StateData, NS, Reason) when is_binary(Reason) ->
    send_failure(StateData, NS, [{xmlcdata, Reason}]);
send_failure(StateData, NS, Children) when is_list(Children) ->
    send_element(StateData,
		 #xmlel{name = <<"failure">>,
			attrs = [{<<"xmlns">>, NS}],
			children = Children}).

init_roster_privacy(StateData, U, JID) ->
    {Fs, Ts, Bs} = ejabberd_hooks:run_fold(roster_get_subscription_lists,
					   StateData#state.server, {[], [], []},
					   [U, StateData#state.server]),
    LJID = jid:tolower(jid:remove_resource(JID)),
    SharedSet = ?SETS:from_list([LJID | Bs]),
    {lists:foldl(fun ?SETS:add_element/2, SharedSet, Fs),
     lists:foldl(fun ?SETS:add_element/2, SharedSet, Ts),
     ejabberd_hooks:run_fold(privacy_get_user_list,
			     StateData#state.server, #userlist{},
			     [U, StateData#state.server])}.

add_to_pres_a(State, From) ->
    LFrom = jid:tolower(From),
    LBFrom = setelement(3, LFrom, <<"">>),
    case (?SETS):is_element(LFrom, State#state.pres_a)
	orelse (?SETS):is_element(LBFrom, State#state.pres_a)
    of
	true ->
	    State;
	false ->
	    case
		(?SETS):is_element(LFrom, State#state.pres_f)
	    of
		true ->
		    A = (?SETS):add_element(LFrom, State#state.pres_a),
		    State#state{pres_a = A};
		false ->
		    case (?SETS):is_element(LBFrom, State#state.pres_f)
		    of
			true ->
			    A = (?SETS):add_element(LBFrom, State#state.pres_a),
			    State#state{pres_a = A};
			false ->
			    State
		    end
	    end
    end.

sm_open_session(StateData, Priority, Info) ->
    ejabberd_sm:open_session(StateData#state.sid,
			     StateData#state.user,
			     StateData#state.server,
			     StateData#state.resource,
			     Priority, Info).

sm_close_session(StateData) ->
    ejabberd_sm:close_session(StateData#state.sid,
			      StateData#state.user,
			      StateData#state.server,
			      StateData#state.resource).

sm_close_session_unset_presence(StateData, Reason) ->
    From = StateData#state.jid,
    Packet = #xmlel{name = <<"presence">>,
		    attrs = [{<<"type">>, <<"unavailable">>}],
		    children = [#xmlel{name = <<"status">>, attrs = [],
				       children = [{xmlcdata, Reason}]}
				|| Reason =/= <<"">>]},
    ejabberd_sm:close_session_unset_presence(StateData#state.sid,
					     StateData#state.user,
					     StateData#state.server,
					     StateData#state.resource,
					     Reason),
    presence_broadcast(StateData, From, StateData#state.pres_a, Packet).

sm_close_migrated_session(StateData) ->
    ejabberd_sm:close_migrated_session(StateData#state.sid,
				       StateData#state.user,
				       StateData#state.server,
				       StateData#state.resource).
identity(Props) ->
	case proplists:get_value(authzid, Props, <<>>) of
		<<>> -> proplists:get_value(username, Props, <<>>);
		AuthzId -> AuthzId
	end.
