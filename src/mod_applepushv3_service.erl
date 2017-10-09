%%%----------------------------------------------------------------------
%%% File    : mod_applepushv3_service.erl
%%% Author  : Juan Pablo Carlino <jpcarlino@process-one.net>
%%% Purpose : Push infrastructure for APNs v3 (HTTP/2 based protocol)
%%% Created : 17 Mar 2017 by Juan Pablo Carlino <jpcarlino@process-one.net>
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

-module(mod_applepushv3_service).
-author('jpcarlino@process-one.net').

-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start_link/3, start/2, stop/1,
         force_reconnect/1]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 depends/2, mod_opt_type/1]).


-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-include_lib("kernel/include/file.hrl").
-include_lib("public_key/include/public_key.hrl").

-record(state, {host = <<"">>             :: binary(),
		gun_connection            :: pid(),
		gun_monitor               :: reference(),
		gateway = ""              :: string(),
		port = 443                :: inet:port_number(),
		certfile = ""             :: string(),
		certfile_mtime            :: file:date_time(),
		default_topic = <<"">>    :: binary(),
		failure_script            :: string(),
		requests = dict:new()     :: dict:dict(),
		authkeyfile = ""          :: string(),
		authkeyid = <<>>          :: binary(),
		teamid = <<>>             :: binary(),
		authkeyfile_mtime         :: file:date_time(),
		jwt			  :: binary(),
		jwt_timestamp             :: binary(),
		queue = {0, queue:new()}  :: {non_neg_integer(), ?TQUEUE},
		soundfile = <<"">>        :: binary()}).

-define(PROCNAME, ejabberd_mod_applepushv3_service).
-define(RECONNECT_TIMEOUT, 5000).
-define(FEEDBACK_RECONNECT_TIMEOUT, 30000).
-define(HANDSHAKE_TIMEOUT, 60000).
-define(SSL_TIMEOUT, 5000).
-define(MAX_QUEUE_SIZE, 1000).
-define(CACHE_SIZE, 4096).
-define(MAX_RESEND_COUNT, 5).

-define(APNS_PRIORITY_HIGH, 10).
-define(APNS_PRIORITY_NORMAL, 5).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Host, ServerHost, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, ServerHost, Opts], []).

start(Host, Opts) ->
    ejabberd:start_app(jiffy),
    ejabberd:start_app(gun),
    MyHosts = case catch gen_mod:get_opt(
                           hosts, Opts,
                           fun(L) when is_list(L) ->
                                   [{iolist_to_binary(H), O} || {H, O}<-L]
                           end, []) of
                  {'EXIT', _} ->
                      [{gen_mod:get_opt_host(Host, Opts,
                                             <<"applepush.@HOST@">>), Opts}];
                  Hs ->
                      Hs
              end,
    lists:foreach(
      fun({MyHost, MyOpts}) ->
	      Proc = gen_mod:get_module_proc(MyHost, ?PROCNAME),
	      ChildSpec =
		  {Proc,
		   {?MODULE, start_link, [MyHost, Host, MyOpts]},
		   transient,
		   1000,
		   worker,
		   [?MODULE]},
	      supervisor:start_child(ejabberd_sup, ChildSpec)
      end, MyHosts).

stop(Host) ->
    MyHosts = case gen_mod:get_module_opt(
                     Host, ?MODULE, hosts,
                     fun(Hs) when is_list(Hs) ->
                             [iolist_to_binary(H) || {H, _} <- Hs]
                     end, []) of
                  [] ->
                      [gen_mod:get_module_opt_host(
                         Host, ?MODULE, <<"applepush.@HOST@">>)];
                  Hs ->
                      Hs
              end,
    lists:foreach(
      fun(MyHost) ->
	      Proc = gen_mod:get_module_proc(MyHost, ?PROCNAME),
	      gen_server:call(Proc, stop),
	      supervisor:terminate_child(ejabberd_sup, Proc),
	      supervisor:delete_child(ejabberd_sup, Proc)
      end, MyHosts).


force_reconnect(Host) ->
    MyHosts = case gen_mod:get_module_opt(
                     Host, ?MODULE, hosts,
                     fun(Hs) when is_list(Hs) ->
                             [iolist_to_binary(H) || {H, _} <- Hs]
                     end, []) of
                  [] ->
                      [gen_mod:get_module_opt_host(
                         Host, ?MODULE, <<"applepush.@HOST@">>)];
                  Hs ->
                      Hs
              end,
    lists:foreach(
      fun(MyHost) ->
	      Proc = gen_mod:get_module_proc(MyHost, ?PROCNAME),
              gen_server:call(Proc, force_reconnect)
      end, MyHosts).


%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([MyHost, ServerHost, Opts]) ->
    CertFile = gen_mod:get_opt(certfile, Opts,
                               fun iolist_to_string/1,
                               ""),
    AuthKeyFile = gen_mod:get_opt(authkeyfile, Opts,
			       fun iolist_to_string/1,
			       ""),
    AuthKeyId = gen_mod:get_opt(authkeyid, Opts,
				fun iolist_to_binary/1,
				<<>>),
    TeamId = gen_mod:get_opt(teamid, Opts,
			     fun iolist_to_binary/1,
			     <<>>),
    SoundFile = gen_mod:get_opt(sound_file, Opts,
                                fun iolist_to_binary/1,
                                <<"pushalert.wav">>),
    Gateway = gen_mod:get_opt(gateway, Opts,
                              fun iolist_to_string/1,
                              "api.push.apple.com"),
    Port = gen_mod:get_opt(port, Opts,
                           fun(I) when is_integer(I), I>0, I<65536 -> I end,
                           443),
    FailureScript = gen_mod:get_opt(failure_script, Opts,
                                    fun iolist_to_string/1,
                                    undefined),
    DefaultTopic = case gen_mod:get_opt(default_topic, Opts, fun iolist_to_binary/1, <<>>) of
		       <<>> -> get_default_topic(CertFile);
		       Val -> Val
		   end,
    self() ! connect,
    ejabberd_router:register_route(MyHost, ServerHost),
    {ok, #state{host           = MyHost,
		gateway        = Gateway,
		port           = Port,
		certfile       = CertFile,
		authkeyfile    = AuthKeyFile,
		authkeyid      = AuthKeyId,
		teamid         = TeamId,
		failure_script = FailureScript,
		queue          = {0, queue:new()},
		soundfile      = SoundFile,
		default_topic  = DefaultTopic}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(force_reconnect, _From, State) ->
    case State#state.gun_connection of
        undefined -> ok;
        Conn -> gun:close(Conn)
    end,
    self() ! connect,
    {reply, ok, State#state{gun_connection = undefined, requests = dict:new() }};
handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info({route, From, To, Packet}, State) ->
    case catch do_route(From, To, Packet, State) of
	{'EXIT', Reason} ->
	    ?ERROR_MSG("~p", [Reason]),
	    {noreply, State};
	Res ->
	    Res
    end;
handle_info(connect, State) ->
    connect(State);
handle_info({ssl, _Socket, _Packet}, State) ->
    %% TODO: handle close events
    {noreply, State};
handle_info({gun_response, _ConnPid, StreamRef, fin, Status, Headers}, #state{requests = Reqs} = State) ->
    case dict_take(StreamRef, Reqs) of
	{{From, Token}, NReqs} ->
	    {noreply, handle_http_response(From, Token, Status, Headers, <<>>, State#state{requests = NReqs})};
	_ ->
	    {noreply, State}
    end;
handle_info({gun_response, _ConnPid, StreamRef, nofin, Status, Headers}, #state{requests = Reqs} = State) ->
    try dict:update(StreamRef, fun({From, Token}) -> {From, Token, Status, Headers, <<>>} end, Reqs) of
	NReqs -> {noreply, State#state{requests = NReqs}}
    catch
	error:badarg -> {noreply, State}
    end;
handle_info({gun_data, _ConnPid, StreamRef, fin, Data}, #state{requests = Reqs} = State) ->
    case dict_take(StreamRef, Reqs) of
	{{From, Token, Status, Headers, Body}, NReqs} ->
	    {noreply, handle_http_response(From, Token, Status, Headers, <<Body/binary, Data/binary>>,
					   State#state{requests = NReqs})};
    	_ ->
	    {noreply, State}
    end;
handle_info({gun_data, _ConnPid, StreamRef, nofin, Data}, #state{requests = Reqs} = State) ->
    try dict:update(StreamRef, fun({From, Token, Status, Headers, Body}) ->
					{From, Token, Status, Headers, <<Body/binary, Data/binary>>}
			       end, Reqs) of
	NReqs -> {noreply, State#state{requests = NReqs}}
    catch
	error:badarg -> {noreply, State}
    end;
handle_info({gun_error, _ConnPid, StreamRef, Reason}, #state{requests = Reqs} = State) ->
    case dict_take(StreamRef, Reqs) of
	{{From, Token, _, _, _}, NReqs} ->
	    {noreply, handle_http_response(From, Token, Reason, State#state{requests = NReqs})};
	{{From, Token}, NReqs} ->
	    {noreply, handle_http_response(From, Token, Reason, State#state{requests = NReqs})};
	_ ->
	    {noreply, State}
    end;
handle_info({'DOWN', MRef, process, ConnPid, Reason}, #state{gun_connection = ConnPid, gun_monitor = MRef} = State) ->
    ?DEBUG("Gun connection died: ~p - reconnecting", [Reason]),
    self() ! connect,
    {noreply, State#state{gun_connection = undefined, requests = dict:new()}};
handle_info(_Info, State) ->
    io:format("Unhandled info: ~p~n", [_Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    ?DEBUG("Terminate ~p", [_Reason]),
    ejabberd_router:unregister_route(State#state.host),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

do_route(From, To, Packet, State) ->
    #jid{user = User, resource = Resource} = To,
    if
	(User /= <<"">>) or (Resource /= <<"">>) ->
	    Err = jlib:make_error_reply(Packet, ?ERR_SERVICE_UNAVAILABLE),
	    ejabberd_router:route(To, From, Err),
	    {noreply, State};
	true ->
	    case Packet of
		#xmlel{name = <<"iq">>} ->
		    IQ = jlib:iq_query_info(Packet),
		    case IQ of
			#iq{type = get, xmlns = ?NS_DISCO_INFO = XMLNS,
			    sub_el = _SubEl, lang = Lang} = IQ ->
			    Res = IQ#iq{type = result,
					sub_el =
                                        [#xmlel{name = <<"query">>,
                                                attrs = [{<<"xmlns">>, XMLNS}],
                                                children = iq_disco(Lang)}]},
			    ejabberd_router:route(To,
						  From,
						  jlib:iq_to_xml(Res)),
			    {noreply, State};
			#iq{type = get, xmlns = ?NS_DISCO_ITEMS = XMLNS} = IQ ->
			    Res = IQ#iq{type = result,
					sub_el =
                                        [#xmlel{name = <<"query">>,
                                                attrs = [{<<"xmlns">>, XMLNS}],
                                                children = []}]},
			    ejabberd_router:route(To,
						  From,
						  jlib:iq_to_xml(Res)),
			    {noreply, State};
			_ ->
			    Err = jlib:make_error_reply(Packet,
							?ERR_SERVICE_UNAVAILABLE),
			    ejabberd_router:route(To, From, Err),
			    {noreply, State}
		    end;
		#xmlel{name = <<"message">>, children = Els} ->
		    case fxml:remove_cdata(Els) of
			[#xmlel{name = <<"push">>}] ->
			    NewState = handle_message(From, To, Packet, 0, State),
			    {noreply, NewState};
			[#xmlel{name = <<"disable">>}] ->
			    {noreply, State};
			_ ->
			    {noreply, State}
		    end;
		_ ->
		    {noreply, State}
	    end
    end.

get_custom_fields(Packet) ->
    case fxml:get_subtag(fxml:get_subtag(Packet, <<"push">>), <<"custom">>) of
        false -> [];
        #xmlel{name = <<"custom">>, attrs = [], children = Children} ->
            [ {fxml:get_tag_attr_s(<<"name">>, C), fxml:get_tag_cdata(C)} ||
                C <- fxml:remove_cdata(Children) ]
    end.

handle_message(From, To, Packet, ResendCount, #state{gun_connection = undefined} = State) ->
    queue_message(From, To, Packet, ResendCount, State);
handle_message(From, To, Packet, _ResendCount, State) ->
    DeviceID =
	fxml:get_path_s(Packet,
		       [{elem, <<"push">>}, {elem, <<"id">>}, cdata]),
    Msg =
	fxml:get_path_s(Packet,
		       [{elem, <<"push">>}, {elem, <<"msg">>}, cdata]),
    Badge =
	fxml:get_path_s(Packet,
		       [{elem, <<"push">>}, {elem, <<"badge">>}, cdata]),
    Sound =
	fxml:get_path_s(Packet,
		       [{elem, <<"push">>}, {elem, <<"sound">>}, cdata]),
    Sender =
	fxml:get_path_s(Packet,
		       [{elem, <<"push">>}, {elem, <<"from">>}, cdata]),
    Receiver =
	fxml:get_path_s(Packet,
		       [{elem, <<"push">>}, {elem, <<"to">>}, cdata]),
    CustomFields  = get_custom_fields(Packet),
    PriorityFlag = check_push_priority(Msg, Badge, Sound),
    Payload = make_payload(To#jid.lserver, State, Msg, Badge, Sound, Sender, CustomFields),
    ID =
	case catch erlang:list_to_integer(binary_to_list(DeviceID), 16) of
	    ID1 when is_integer(ID1) ->
		ID1;
	    _ ->
		false
	end,
    if
    is_integer(ID) ->
        {MegaSecs, Secs, _MicroSecs} = os:timestamp(),
        Expiry = MegaSecs * 1000000 + Secs + 24 * 60 * 60,
	{Jwt, State2} = get_jwt(State),
        APNS_Headers = [{<<"apns-expiration">>, integer_to_binary(Expiry)},
                        {<<"apns-priority">>, integer_to_binary(PriorityFlag)}] ++
			if Jwt == none -> []; true -> [{<<"authorization">>, Jwt}] end ++
                        [{<<"apns-topic">>, State#state.default_topic} || State#state.default_topic /= <<"">>],
        %%TODO:
        %%   * apns-topic  ?
        %%   * apns-collapse-id : This is to collapse multiple into one.  Likely not used by us for now
        %%   * apns-thread-id  : This can be useful. For example to group all pushes of the same match together.
        %%                       or all pushes related to the same news event.
        ?INFO_MSG("(~p) sending notification for ~s~npayload:~n~s~n"
		  "Sender: ~s~n"
		  "Receiver: ~s~n"
		  "Device ID: ~s~n",
		  [State#state.host, erlang:integer_to_list(ID, 16),
		   Payload,
		   Sender,
		   Receiver, DeviceID]),
        GunConn = State#state.gun_connection,
	Token = erlang:integer_to_list(ID, 16),
        StreamRef = gun:post(GunConn, ["/3/device/", Token], APNS_Headers, Payload),
	State2#state{requests = dict:store(StreamRef, {From, Token}, State#state.requests)};
    true ->
        State
    end.

handle_http_response(_From, Token, Error, State) ->
    ?ERROR_MSG("Apnsv3 push (~p) : gun error ~p", [Token, Error]),
    State.
handle_http_response(_From, Token, 200, _Headers, _Body, State) ->
    ?DEBUG("Apnsv3 push (~p) sent", [Token]),
    State;
handle_http_response(From, Token, Status, Headers, Body, State) ->
    ?ERROR_MSG("Apnsv3 push (~p) : error ~p", [Token, {Status, Body}]),
    process_apns3_response(From, Token, Status, Headers, Body, State).

process_apns3_response(From, Token, 400, _Headers, Body, State) ->
    {Attrs} = jiffy:decode(Body),
    case proplists:get_value(<<"reason">>, Attrs) of
	<<"MissingTopic">> ->
	    ?ERROR_MSG("Error trying to push to token ~p. Missing Topic", [Token]),
	    State;
	<<"BadTopic">> ->
	    ?ERROR_MSG("Error trying to push to token ~p. Bad Topic (~p)", [Token, State#state.default_topic]),
	    State;
	<<"BadDeviceToken">> ->
	    disable_push(From, Token, State),
	    State;
	E ->
	    ?ERROR_MSG("Unexpected error trying to push to token ~p : ~p", [Token, E]),
	    State
    end;
process_apns3_response(_From, _Token, 403, _Headers, _Body, State) ->
    invalid_certificate(State);
process_apns3_response(From, Token, 410, _Headers, _Body, State) -> % Device not registered on topic
    disable_push(From, Token, State),
    State;
process_apns3_response(_From, _Token, 413, _Headers, _Body, State) -> % Too large payload
    State;
process_apns3_response(_From, _Token, 429, _Headers, _Body, State) -> % Too many payload to device
    State;
process_apns3_response(_From, _Token, 500, _Headers, _Body, State) -> % Server error
    State;
process_apns3_response(_From, _Token, 503, _Headers, _Body, State) -> % Server unavailable
    State;
process_apns3_response(_From, _Token, _Status, _Headers, _Body, State) ->
    State.

invalid_certificate(State) ->
    State.

make_payload(Host, State, Msg, Badge, Sound, Sender, CustomFields) ->
    Msg2 = json_escape(Msg),
    AlertPayload =
	case Msg2 of
	    <<"">> -> <<"">>;
	    _ -> <<"\"alert\":\"", Msg2/binary, "\"">>
	end,
    BadgePayload =
	case catch jlib:binary_to_integer(Badge) of
	    B when is_integer(B) ->
		<<"\"badge\":", Badge/binary>>;
	    _ -> <<"">>
	end,
    SoundPayload =
    	case Sound of
            <<"false">> -> <<"">>;
	    _ ->
		SoundFile = case Sound of
                                <<"true">> -> State#state.soundfile;
                                _ -> Sound
                            end,
		<<"\"sound\":\"", (json_escape(SoundFile))/binary, "\"">>
	end,
    ContentAvailablePayload = <<"\"content-available\":1">>,
    MutableContentPayload = <<"\"mutable-content\":1">>,
    Payloads = lists:filter(
                 fun(S) -> S /= <<"">> end,
                 [AlertPayload, BadgePayload, SoundPayload, ContentAvailablePayload, MutableContentPayload]),

    CustomPayloadFields =
        [<<"\"", (json_escape(Name))/binary, "\":\"",
           (json_escape(Value))/binary, "\"">>
             || {Name, Value} <- CustomFields] ++
        [<<"\"from\":\"", (json_escape(Sender))/binary, "\"">> || Sender /= <<"">>],

    Payload1 =
        [<<"{">>,
         str:join(
           [<<"\"aps\":{", (str:join(Payloads, <<",">>))/binary, "}">> | CustomPayloadFields],
           <<",">>),
         <<"}">>],
    Payload = list_to_binary(Payload1),
    PayloadLen = size(Payload),
    MaxPayloadSize = case gen_mod:get_module_opt(Host, ?MODULE, voip_service,	fun(V) when is_boolean(V) -> V end, false) of
			 true -> 5*1024;
			 false -> 4*1024
		     end,
    if
	PayloadLen > MaxPayloadSize ->
	    Delta = PayloadLen - MaxPayloadSize,
	    MsgLen = size(Msg),
	    if
		MsgLen /= 0 ->
		    CutMsg =
			if
			    MsgLen > Delta ->
                                ejabberd_push:utf8_cut(Msg, MsgLen - Delta);
			    true ->
				<<"">>
			end,
		    make_payload(Host, State, CutMsg, Badge, Sound, Sender, CustomFields);
		true ->
		    Payload2 =
			<<"{\"aps\":{", (str:join(Payloads, <<",">>))/binary, "}}">>,
		    Payload2
	    end;
	true ->
	    Payload
    end.

%% According to Apple docs: "The remote notification must trigger an alert,
%% sound, or badge on the device. It is an error to use this (high) priority
%% for a push that contains only the content-available key."
check_push_priority(Msg, Badge, Sound) ->
    BadgeSet =
        case catch jlib:binary_to_integer(Badge) of
            B when is_integer(B) -> true;
            _ -> false
        end,
    case {Msg, BadgeSet, Sound} of
        {<<"">>,false,<<"false">>} -> ?APNS_PRIORITY_NORMAL;
        _ -> ?APNS_PRIORITY_HIGH
    end.

connect(#state{gun_connection = undefined, certfile_mtime = undefined} = State) ->
    Gateway = State#state.gateway,
    Port = State#state.port,
    CertOpts = [],%[{certfile, State#state.certfile}],
    Opts = #{retry => 1,
	%trace => true,
	     transport => ssl,
             http2_opts => #{keepalive => 15000},
             transport_opts => CertOpts ++ [{sndbuf, 262144}, {buffer, 262144}],
             protocols => [http2]},
    ?INFO_MSG("(~p) connecting to APNs v3 (default topic: ~p)",
              [State#state.host, State#state.default_topic]),
    case gun:open(Gateway, Port, Opts) of
        {ok, ConnPid} ->
            GunMRef = monitor(process, ConnPid),
            wait_connection_established(State, ConnPid, GunMRef);
        {error, Reason} ->
            %% Something is wrong with our code. Errors here means bad options passed,
            %% or gun application was not started correctly.
            ?ERROR_MSG("(~p) APNs v3 connection to ~s:~p failed: ~p, "
                       "retrying after ~p seconds~n",
                       [State#state.host, Gateway, Port,
                        Reason, ?RECONNECT_TIMEOUT div 1000]),
            erlang:send_after(?RECONNECT_TIMEOUT, self(), connect),
            {noreply, State}
    end;
connect(#state{gun_connection = undefined, certfile_mtime = MTime} = State) ->
    CertFile = State#state.certfile,
    case get_mtime(CertFile) of
	MTime ->
	    Gateway = State#state.gateway,
	    Port = State#state.port,
	    Timeout = ?HANDSHAKE_TIMEOUT,
	    ?ERROR_MSG("(~p) Connection to ~p:~p postponed: "
		       "waiting for ~p update, "
		       "retrying after ~p seconds",
		       [State#state.host, Gateway, Port,
			CertFile, Timeout div 1000]),
	    erlang:send_after(Timeout, self(), connect),
	    {noreply, State};
	_ ->
	    connect(State#state{certfile_mtime = undefined})
    end;
connect(State) ->
    {noreply, State}.

wait_connection_established(State, ConnPid, GunMRef) ->
  StartConnectTS = os:timestamp(),
  case gun:await_up(ConnPid, GunMRef) of
    {ok, http2} ->
        log_time("HTTP/2 connect time", StartConnectTS),
        {noreply, resend_messages(State#state{gun_connection = ConnPid, gun_monitor = GunMRef})};
    {error, {tls_alert, TlsAlert}} = _Err when
              TlsAlert == "certificate unknown";
	      TlsAlert == "certificate revoked";
	      TlsAlert == "certificate expired";
              TlsAlert == "bad certificate" ->
        %% Unrecoverable error
        MTime = get_mtime(State#state.certfile),
        case State#state.failure_script of
            undefined -> ok;
            FailureScript ->
                CertExpired = has_cert_expired(State#state.certfile),
                os:cmd(FailureScript ++ " " ++ State#state.gateway ++ " " ++
                    if CertExpired ->
                        "expired_cert";
                    true ->
                        "connection_refused"
                    end)
        end,
        handle_connect_error(list_to_atom(TlsAlert), ?HANDSHAKE_TIMEOUT,
                             State#state{certfile_mtime = MTime});
    {error, Reason} ->
        handle_connect_error(Reason,?RECONNECT_TIMEOUT,State)
  end.

has_cert_expired(File) ->
    case file:read_file(File) of
	{ok, Data} ->
	    case public_key:pem_decode(Data) of
		[{'Certificate', Cert, not_encrypted} | _] ->
		    case public_key:pkix_decode_cert(Cert, otp) of
			#'OTPCertificate'{
			   tbsCertificate = #'OTPTBSCertificate'{
					       validity = #'Validity'{
							     notAfter = After}}} ->
			    case calendar:datetime_to_gregorian_seconds(calendar:universal_time()) >=
				pubkey_cert:time_str_2_gregorian_sec(After) of
				true ->
				    ?ERROR_MSG("Push certificate expired", []),
				    true;
				_ ->
				    false
			    end;
			_Cert ->
			    ?INFO_MSG("Unable to parse push client cert ~p", [_Cert]),
			    false
		    end;
		_Decoded ->
		    ?INFO_MSG("Unable to decode push client cert ~p", [_Decoded]),
		    false
	    end;
	_Err ->
	    ?INFO_MSG("Unable to read push client cert ~p", [_Err]),
	    false
    end.

handle_connect_error(Reason, Timeout, State) ->
    ?ERROR_MSG("(~p) Connection to ~p:~p failed: ~p, "
               "retrying after ~p seconds",
               [State#state.host, State#state.gateway,
                State#state.port,
                Reason, Timeout div 1000]),
    erlang:send_after(Timeout, self(), connect),
    {noreply, State}.

get_mtime(File) ->
    case file:read_file_info(File) of
	{ok, FileInfo} ->
	    FileInfo#file_info.mtime;
	{error, _} ->
	    no_certfile
    end.

bounce_message(From, To, Packet, Reason) ->
    #xmlel{attrs = Attrs} = Packet,
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    if Type /= <<"error">>; Type /= <<"result">> ->
	    ejabberd_router:route(
	      To, From,
	      jlib:make_error_reply(
		Packet,
		?ERRT_INTERNAL_SERVER_ERROR(
		   fxml:get_attr_s(<<"xml:lang">>, Attrs),
		   Reason)));
       true ->
	    ok
    end.

queue_message(From, To, Packet, ResendCount, State) ->
    case State#state.queue of
	{?MAX_QUEUE_SIZE, Queue} ->
	    {{value, {From1, To1, Packet1, _}}, Queue1} = queue:out(Queue),
	    bounce_message(From1, To1, Packet1,
			   <<"Unable to connect to push service">>),
	    Queue2 = queue:in({From, To, Packet, ResendCount}, Queue1),
	    State#state{queue = {?MAX_QUEUE_SIZE, Queue2}};
	{Size, Queue} ->
	    Queue1 = queue:in({From, To, Packet, ResendCount}, Queue),
	    State#state{queue = {Size+1, Queue1}}
    end.

resend_messages(#state{queue = {_, Queue}} = State) ->
    lists:foldl(
      fun({From, To, Packet, ResendCount}, AccState) ->
	      case catch handle_message(From, To, Packet, ResendCount, AccState) of
		  {'EXIT', _} = Err ->
		      ?ERROR_MSG("error while processing message:~n"
				 "** From: ~p~n"
				 "** To: ~p~n"
				 "** Packet: ~p~n"
				 "** Reason: ~p",
				 [From, To, Packet, Err]),
		      AccState;
		  NewAccState ->
		      NewAccState
	      end
      end, State#state{queue = {0, queue:new()}}, queue:to_list(Queue)).

json_escape(S) ->
    json_escape(S, <<>>).

json_escape(<<>>, Res) ->
    Res;
json_escape(<<C, S/binary>>, Res) ->
    case C of
        $" -> json_escape(S, <<Res/binary, "\\\"">>);
        $\\ -> json_escape(S, <<Res/binary, "\\\\">>);
        _ when C < 16 ->
            B = list_to_binary(erlang:integer_to_list(C, 16)),
            json_escape(S, <<Res/binary, "\\u000", B/binary>>);
        _ when C < 32 ->
            B = list_to_binary(erlang:integer_to_list(C, 16)),
            json_escape(S, <<Res/binary, "\\u00", B/binary>>);
        _ -> json_escape(S, <<Res/binary, C>>)
    end.


iq_disco(Lang) ->
    [#xmlel{name = <<"identity">>,
            attrs = [{<<"category">>, <<"gateway">>},
                     {<<"type">>, <<"apple">>},
                     {<<"name">>, translate:translate(
                                    Lang, <<"Apple Push Service">>)}],
            children = []},
     #xmlel{name = <<"feature">>,
            attrs = [{<<"var">>, ?NS_DISCO_INFO}],
            children = []}].

disable_push(JID, DeviceID, State) ->
    From = jid:make(<<"">>, State#state.host, <<"">>),
    TimeStamp = p1_time_compat:system_time(milli_seconds),
    BJID = jid:remove_resource(JID),
    ?INFO_MSG("(~p) disabling push for device ~s with JID ~s~n",
	      [State#state.host, DeviceID, jid:to_string(BJID)]),
    ejabberd_router:route(From, BJID,
			  #xmlel{name = <<"iq">>,
				 attrs =
				     [{<<"id">>, <<"disable">>},
				      {<<"type">>, <<"set">>}],
				 children =
				     [#xmlel{name = <<"disable">>,
					     attrs =
						 [{<<"xmlns">>, ?NS_P1_PUSH_GCM},
						  {<<"status">>,
						   <<"feedback">>},
						  {<<"ts">>,
						   jlib:integer_to_binary(TimeStamp)},
						  {<<"id">>, DeviceID}],
					     children = []}]}).

iolist_to_string(S) ->
    binary_to_list(iolist_to_binary(S)).

get_default_topic(CertFile) ->
    {ok, CertData} = file:read_file(CertFile),
    case lists:keyfind('Certificate', 1, public_key:pem_decode(CertData)) of
      {'Certificate', Cert2,_} ->
          OTPCert = public_key:pkix_decode_cert(Cert2, otp),
          case get_apns_topic_from_cert(OTPCert) of
              {ok, Topic} -> Topic;
              _ -> <<"">>
           end;
       false ->
          <<"">>
    end.

get_apns_topic_from_cert(OTPCert) ->
    CN = get_common_name(OTPCert),
    I = string:chr(CN, $:),
    if
        I >0 ->
            {ok, list_to_binary(string:strip(string:sub_string(CN, I+1)))};
        true ->
            {error, CN}
    end.

get_common_name(_Cert) ->
    "".

log_time(Message, StartTS) ->
    EndTimestamp = os:timestamp(),
    Microseconds = timer:now_diff(EndTimestamp, StartTS) / 1000000,
    ?INFO_MSG(Message ++ " (~p)", [Microseconds]).

get_jwt(#state{authkeyfile = ""} = State) ->
    {none, State};
get_jwt(#state{jwt = Jwt, jwt_timestamp = Time, authkeyfile = AuthKey, authkeyfile_mtime = MTime} = State) ->
    Now = p1_time_compat:system_time(seconds),
    FMTime = get_mtime(AuthKey),
    ?DEBUG("JWT: ~p ~p ~p ~p ~p", [Jwt, Time, Now, FMTime, MTime]),
    case Jwt == undefined orelse Time + 55*60 < Now orelse FMTime /= MTime of
	true ->
	    {ok, AuthKeyContent} = file:read_file(AuthKey),
	    case lists:keyfind('PrivateKeyInfo', 1, public_key:pem_decode(AuthKeyContent)) of
		{'PrivateKeyInfo', _, not_encrypted} = Pem ->
		    case public_key:pem_entry_decode(Pem) of
			{'PrivateKeyInfo', v1, _, Keys, _} ->
			    case public_key:der_decode('ECPrivateKey', Keys) of
				{'ECPrivateKey', 1, PrivKey, _, _PubKey} ->
				    Jwt2 = sign_jwt(State#state.authkeyid, State#state.teamid, PrivKey),
				    {Jwt2, State#state{jwt = Jwt2, jwt_timestamp = Now, authkeyfile_mtime = get_mtime(AuthKey)}};
				Other3 ->
				    ?ERROR_MSG("Unexpected authkeyfile content(3): ~p", [Other3]),
				    {none, State#state{jwt = none, jwt_timestamp = Now, authkeyfile_mtime = MTime}}
			    end;
			Other2 ->
			    ?ERROR_MSG("Unexpected authkeyfile content(2): ~p", [Other2]),
			    {none, State#state{jwt = none, jwt_timestamp = Now, authkeyfile_mtime = MTime}}
		    end;
		Other ->
		    ?ERROR_MSG("Unexpected authkeyfile content: ~p", [Other]),
		    {none, State#state{jwt = none, jwt_timestamp = Now, authkeyfile_mtime = MTime}}
	    end;
	false ->
	    {Jwt, State}
    end.

sign_jwt(Kid, Issuer, PrivateKey) ->
    Provider = encode_base64_url(jiffy:encode({[{<<"alg">>, <<"ES256">>}, {<<"typ">>, <<"JWT">>}, {<<"kid">>, Kid}]})),
    Claim = encode_base64_url(jiffy:encode({[{<<"iss">>, Issuer}, {<<"iat">>, p1_time_compat:system_time(seconds)}]})),
    ToEncrypt = <<Provider/binary, ".", Claim/binary>>,
    Signature = encode_base64_url(crypto:sign(ecdsa, sha256, ToEncrypt, [PrivateKey, secp256r1])),
    <<"bearer ", ToEncrypt/binary, ".", Signature/binary>>.

encode_base64_url(Data) ->
    encode_base64_url_bin(Data, <<>>).

encode_base64_url_bin(<<A:6, B:6, C:6, D:6, Tail/binary>>, Acc) ->
    encode_base64_url_bin(Tail, <<Acc/binary, (u(A)):8, (u(B)):8, (u(C)):8, (u(D)):8>>);
encode_base64_url_bin(<<A:6, B:6, C:4>>, Acc) ->
    <<Acc/binary, (u(A)):8, (u(B)):8, (u(C bsl 2)):8>>;
encode_base64_url_bin(<<A:6, B:2>>, Acc) ->
    <<Acc/binary, (u(A)):8, (u(B bsl 4)):8>>;
encode_base64_url_bin(<<>>, Acc) ->
    Acc.


u(X) when X >= 0, X < 26 -> X + 65;
u(X) when X > 25, X < 52 -> X + 71;
u(X) when X > 51, X < 62 -> X - 4;
u(62) -> $-;
u(63) -> $_;
u(X) -> exit({bad_encode_base64_token, X}).

dict_take(Key, Dict) ->
    try dict:fetch(Key, Dict) of
	Val -> {Val, dict:erase(Key, Dict)}
    catch
	_:_ ->
	    error
    end.

depends(_Host, _Opts) ->
    [{mod_applepush, hard}].

mod_opt_type(certfile) -> fun iolist_to_string/1;
mod_opt_type(authkeyfile) -> fun iolist_to_string/1;
mod_opt_type(authkeyid) -> fun iolist_to_binary/1;
mod_opt_type(teamid) -> fun iolist_to_binary/1;
mod_opt_type(failure_script) -> fun iolist_to_string/1;
mod_opt_type(gateway) -> fun iolist_to_string/1;
mod_opt_type(default_topic) -> fun iolist_to_binary/1;
mod_opt_type(voip_service) -> fun(V) when is_boolean(V) -> V end;
mod_opt_type(host) -> fun iolist_to_binary/1;
mod_opt_type(hosts) ->
    fun (L) when is_list(L) ->
	[{iolist_to_binary(H), O} || {H, O} <- L]
    end;
mod_opt_type(port) ->
    fun (I) when is_integer(I), I > 0, I < 65536 -> I end;
mod_opt_type(sound_file) -> fun iolist_to_binary/1;
mod_opt_type(_) ->
    [certfile, authkeyfile, authkeyid, teamid, failure_script, default_topic,
     gateway, host, hosts, port, sound_file].
