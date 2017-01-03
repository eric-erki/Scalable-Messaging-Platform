%%%----------------------------------------------------------------------
%%% File    : mod_gcm_service.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%%           Juan Pablo Carlino <jpcarlino@process-one.net>
%%% Purpose : Central push infrastructure
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

-module(mod_gcm_service).

-author('alexey@process-one.net').
-author('jpcarlino@process-one.net').

-behaviour(gen_server).
-behaviour(gen_mod).

%% API
-export([start_link/3, start/2, stop/1]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("logger.hrl").
-include_lib("kernel/include/file.hrl").

-define(MIN_RETRY_WAIT, 5 * 1000).
-define(MODE_ACCEPT, accept).
-define(MODE_ENQUEUE, enqueue).
-define(MODE_ACTIVE, active).

-record(state, {host = <<"">>            :: binary(),
		gateway = ""             :: string(),
		queue = {0, queue:new()} :: {non_neg_integer(), ?TQUEUE},
		apikey = ""              :: string(),
		soundfile = <<"">>       :: binary(),
		mode = ?MODE_ACCEPT      :: accept | enqueue | active,
		prev_attempts = 0        :: non_neg_integer()}).

-define(PROCNAME, ejabberd_mod_gcm_service).
-define(RECONNECT_TIMEOUT, 5000).
-define(HANDSHAKE_TIMEOUT, 60000).
-define(MAX_QUEUE_SIZE, 1000).
-define(MAX_PAYLOAD_SIZE, 4096).
-define(EXPIRY_DATE, 24 * 60 * 60).
-define(HTTP_TIMEOUT, 10 * 1000).
-define(HTTP_CONNECT_TIMEOUT, 10 * 1000).
-define(GCM_PRIORITY_HIGH, <<"high">>).

start_link(Host, ServerHost, Opts) ->
    Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
    gen_server:start_link({local, Proc}, ?MODULE, [Host, ServerHost, Opts], []).

start(Host, Opts) ->
    ejabberd:start_app(ssl),
    ejabberd:start_app(inets),
    ejabberd:start_app(jiffy),
    MyHosts = case catch gen_mod:get_opt(
                           hosts, Opts,
                           fun(L) when is_list(L) ->
                                   [{iolist_to_binary(H), O} || {H, O}<-L]
                           end, []) of
                  {'EXIT', _} ->
                      [{gen_mod:get_opt_host(Host, Opts,
                                             <<"gcm.@HOST@">>), Opts}];
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
                         Host, ?MODULE, <<"gcm.@HOST@">>)];
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

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([MyHost, ServerHost, Opts]) ->
    SoundFile = gen_mod:get_opt(sound_file, Opts,
                                fun iolist_to_binary/1,
                                <<"pushalert.wav">>),
    Gateway = gen_mod:get_opt(gateway, Opts,
                              fun iolist_to_string/1,
			      "https://fcm.googleapis.com/fcm/send"),
    ApiKey = gen_mod:get_opt(apikey, Opts, fun iolist_to_string/1, ""),
    ejabberd_router:register_route(MyHost, ServerHost),
    {ok,
     #state{host = MyHost, gateway = Gateway,
	    queue = {0, queue:new()}, apikey = ApiKey,
	    soundfile = SoundFile}}.

handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast(_Msg, State) -> {noreply, State}.

handle_info({route, From, To, Packet}, State) ->
    case catch do_route(From, To, Packet, State) of
      {'EXIT', Reason} ->
	  ?ERROR_MSG("~p", [Reason]), {noreply, State};
      Res -> Res
    end;
handle_info(resend, State) ->
    {noreply, resend_messages(State)};
handle_info(_Info, State) -> {noreply, State}.

terminate(_Reason, State) ->
    ejabberd_router:unregister_route(State#state.host), ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------

do_route(From, To, Packet, State) ->
    #jid{user = User, resource = Resource} = To,
    if (User /= <<"">>) or (Resource /= <<"">>) ->
	   Err = jlib:make_error_reply(Packet,
				       ?ERR_SERVICE_UNAVAILABLE),
	   ejabberd_router:route(To, From, Err),
	   {noreply, State};
       true ->
	   case Packet of
	     #xmlel{name = <<"iq">>} ->
		 IQ = jlib:iq_query_info(Packet),
		 case IQ of
		   #iq{type = get, xmlns = (?NS_DISCO_INFO) = XMLNS,
		       sub_el = _SubEl, lang = Lang} =
		       IQ ->
		       Res = IQ#iq{type = result,
				   sub_el =
				       [#xmlel{name = <<"query">>,
					       attrs = [{<<"xmlns">>, XMLNS}],
					       children = iq_disco(Lang)}]},
		       ejabberd_router:route(To, From, jlib:iq_to_xml(Res)),
		       {noreply, State};
		   #iq{type = get, xmlns = (?NS_DISCO_ITEMS) = XMLNS} =
		       IQ ->
		       Res = IQ#iq{type = result,
				   sub_el =
				       [#xmlel{name = <<"query">>,
					       attrs = [{<<"xmlns">>, XMLNS}],
					       children = []}]},
		       ejabberd_router:route(To, From, jlib:iq_to_xml(Res)),
		       {noreply, State};
		   %%#iq{type = get, xmlns = ?NS_VCARD, lang = Lang} ->
		   %%    ResIQ =
		   %%	IQ#iq{type = result,
		   %%	      sub_el = [{xmlelement,
		   %%			 "vCard",
		   %%			 [{"xmlns", ?NS_VCARD}],
		   %%			 iq_get_vcard(Lang)}]},
		   %%    ejabberd_router:route(To,
		   %%			  From,
		   %%			  jlib:iq_to_xml(ResIQ));
		   _ ->
		       Err = jlib:make_error_reply(Packet,
						   ?ERR_SERVICE_UNAVAILABLE),
		       ejabberd_router:route(To, From, Err),
		       {noreply, State}
		 end;
	     #xmlel{name = <<"message">>, children = Els} ->
		 case fxml:remove_cdata(Els) of
		   [#xmlel{name = <<"push">>}] ->
		       NewState = handle_message(From, To, Packet, State),
		       {noreply, NewState};
		   [#xmlel{name = <<"disable">>}] -> {noreply, State};
		   _ -> {noreply, State}
		 end;
	     _ -> {noreply, State}
	   end
    end.

get_custom_fields(Packet) ->
    case fxml:get_subtag(fxml:get_subtag(Packet, <<"push">>),
			<<"custom">>)
	of
      false -> [];
      #xmlel{name = <<"custom">>, attrs = [],
	     children = Children} ->
	  [{fxml:get_tag_attr_s(<<"name">>, C),
	    fxml:get_tag_cdata(C)}
	   || C <- fxml:remove_cdata(Children)]
    end.

handle_message(From, To, Packet,
	       #state{mode = ?MODE_ENQUEUE} = State) ->
    queue_message(From, To, Packet, State);
handle_message(From, To, Packet, State) ->
    DeviceID = fxml:get_path_s(Packet,
			      [{elem, <<"push">>}, {elem, <<"id">>}, cdata]),
    Msg = fxml:get_path_s(Packet,
			 [{elem, <<"push">>}, {elem, <<"msg">>}, cdata]),
    Badge = fxml:get_path_s(Packet,
			   [{elem, <<"push">>}, {elem, <<"badge">>}, cdata]),
    Sound = fxml:get_path_s(Packet,
			   [{elem, <<"push">>}, {elem, <<"sound">>}, cdata]),
    Sender = fxml:get_path_s(Packet,
			    [{elem, <<"push">>}, {elem, <<"from">>}, cdata]),
    Receiver = fxml:get_path_s(Packet,
			      [{elem, <<"push">>}, {elem, <<"to">>}, cdata]),
    CustomFields = get_custom_fields(Packet),
    Payload = make_payload(State, Msg, Badge, Sound, Sender,
			   CustomFields),
    case size(DeviceID) of
      0 -> State;
      _ ->
	  Expiry = (?EXPIRY_DATE),
	  Baseurl = State#state.gateway,
	  ApiKey = "key=" ++ State#state.apikey,
	  Notification = jiffy:encode(
			   {[{<<"registration_ids">>,[DeviceID]},
			     {<<"data">>, Payload},
			     {<<"time_to_live">>, Expiry},
			     {<<"priority">>, ?GCM_PRIORITY_HIGH}]}),
	  ?DEBUG("(~p) sending notification for ~s~n~p~npayload"
		 ":~n~p~nSender: ~s~nReceiver: ~s~nDevice "
		 "ID: ~s~n",
		 [State#state.host, DeviceID, Notification, Payload,
		  Sender, Receiver, DeviceID]),
	  try httpc:request(post,
			    {Baseurl, [{"Authorization", ApiKey}],
			     "application/json", Notification},
			    [{timeout, ?HTTP_TIMEOUT},
			     {connect_timeout, ?HTTP_CONNECT_TIMEOUT}],
			    [{body_format, binary}])
	  of
	    {ok, {{_, 200, _}, Headers, RespBody}} ->
		JsonResponse = jiffy:decode(RespBody),
		process_json_response(Notification, JsonResponse,
				      Headers, From, To, Packet, DeviceID,
				      State);
	    {ok, {{_, 400, _}, _, RespBody}} ->
		?ERROR_MSG("(~p) Invalid JSON request: ~p",
			   [State#state.host, RespBody]),
		bounce_message(From, To, Packet),
		State;
	    {ok, {{_, 401, _}, _, RespBody}} ->
		?ERROR_MSG("(~p) There was an error authenticating "
			   "the sender account. Probably your API key "
			   "is invalid.: ~p",
			   [State#state.host, RespBody]),
		bounce_message(From, To, Packet),
		State;
	    {ok,
	     {{_, StatusCode, ReasonPhrase}, Headers, RespBody}} ->
		?INFO_MSG("(~p) GCM returned an error: ~p - ~p "
			  "- ~p",
			  [State#state.host, StatusCode, ReasonPhrase,
			   RespBody]),
		if (StatusCode > 500) and (StatusCode < 600) ->
		       RetryAfter = case proplists:get_value("Retry-After",
							     Headers)
					of
				      undefined -> ?MIN_RETRY_WAIT;
				      Str -> http_date_to_msecs(Str)
				    end,
		       WaitTime = exp_backoff(RetryAfter, State),
		       queue_message(From, To, Packet, WaitTime, State);
		   true -> queue_message(From, To, Packet, State)
		end;
	    {error, Reason} ->
		?ERROR_MSG("(~p) Connection error: ~p, reconnecting",
			   [State#state.host, Reason]),
		queue_message(From, To, Packet, State);
	    BigError ->
		?ERROR_MSG("(~p) Unknown GCM error: ~p",
			   [State#state.host, BigError]),
		queue_message(From, To, Packet, State)
	  catch
	    Throw ->
		?ERROR_MSG(("(~p) Unexpected error communicating "
			    "with GCM server: ~p"),
			   [State#state.host, Throw]),
		queue_message(From, To, Packet, State)
	  end
    end.

process_json_response(Request, {Attrs},
		      ResponseHeaders, From, To, Packet, DeviceID, State) ->
    Failures = proplists:get_value(<<"failure">>, Attrs, 0),
    CanonIDs = proplists:get_value(<<"canonical_ids">>,
				   Attrs, 0),
    case {Failures, CanonIDs} of
      {0, 0} -> State;
      {_Fs, _Cs} ->
	  MsgResults = proplists:get_value(<<"results">>, Attrs,
					   []),
	  NewState = lists:foldl(fun ({R}, S) ->
					 process_message_result(R, From, To,
								Packet, Request,
								ResponseHeaders,
								DeviceID, S)
				 end,
				 State, MsgResults),
	  NewState
    end.

log_gcm_error(State, ErrType, Request) ->
    log_gcm_error(State, ErrType, Request, <<"">>).
log_gcm_error(#state{gateway=G, apikey=A, host=H}, ErrType, Request, ExtraInfo) ->
    ?ERROR_MSG("(~p) Error response received from GCM gateway ~p (apikey: ~p) "
	       "with code: ~p. Original JSON request was: ~p~s",
	       [H, G, A, ErrType, Request, ExtraInfo]).

process_message_result([{<<"error">>,
			 <<"NotRegistered">> = Err}],
		       From, _To, _Packet, Request, _, DeviceID, State) ->
    log_gcm_error(State, Err, Request),
    disable_push(From, DeviceID, State),
    active(State);
process_message_result([{<<"error">>,
			 <<"InvalidRegistration">> = Err}],
		       From, _To, _Packet, Request, _, DeviceID, State) ->
    log_gcm_error(State, Err, Request),
    disable_push(From, DeviceID, State),
    active(State);
process_message_result([{<<"error">>,
			 <<"Unavailable">> = Err}],
		       From, To, Packet, Request, ResponseHeaders, _DeviceID,
		       State) ->
    log_gcm_error(State, Err, Request, <<". We will retry honoring Retry-After header">>),
    RetryAfter = case proplists:get_value("Retry-After",
					  ResponseHeaders)
		     of
		   undefined -> ?MIN_RETRY_WAIT;
		   Str -> http_date_to_msecs(Str)
		 end,
    WaitTime = exp_backoff(RetryAfter, State),
    queue_message(From, To, Packet, WaitTime, State);
process_message_result([{<<"error">>, ErrorCode}], From,
		       To, Packet, Request, _, _DeviceID, State) ->
    log_gcm_error(State, ErrorCode, Request),
    bounce_message(From, To, Packet),
    active(State);
%% everything went fine
process_message_result(Result, From, _To, _Packet,
		       _Request, _, DeviceID, State) ->
    CannonId = proplists:get_value(<<"registration_id">>,
				   Result),
    case CannonId of
      undefined -> ok;
      NewId ->
	  update_device_id(From, DeviceID, NewId, State)
    end,
    active(State).

update_device_id(JID, OldDeviceID, CanonicalID, State) ->
    ?INFO_MSG("(~p) refreshing ID: old: ~s -> new: "
	      "~s to ~s~n",
	      [State#state.host, OldDeviceID, CanonicalID,
	       jid:to_string(JID)]),
    From = jid:make(<<"">>, State#state.host, <<"">>),
    BJID = jid:remove_resource(JID),
    ejabberd_router:route(From, BJID,
			  #xmlel{name = <<"iq">>,
				 attrs =
				     [{<<"id">>, <<"update">>},
				      {<<"type">>, <<"set">>}],
				 children =
				     [#xmlel{name = <<"update">>,
					     attrs =
						 [{<<"xmlns">>, ?NS_P1_PUSH_GCM},
						  {<<"oldid">>, OldDeviceID},
						  {<<"id">>, CanonicalID}],
					     children = []}]}).

make_payload(State, Msg, Badge, Sound, Sender,
	     CustomFields) ->
    SoundPayload = case Sound of
		     <<"true">> -> State#state.soundfile;
                     <<"false">> -> <<"">>;
		     _ -> Sound
		   end,
    AppsPayloadList = [{alert, iolist_to_binary(Msg)},
		       {badge, jlib:binary_to_integer(Badge)},
		       {sound, iolist_to_binary(SoundPayload)}],
    PayloadList2 = if Sender /= <<"">> ->
			  CustomFields ++ [{from_jid, iolist_to_binary(Sender)}];
		      true -> CustomFields
		   end,
    FinalPayload = lists:flatten([{aps,
				   {AppsPayloadList}}]
				 ++ PayloadList2),
    FinalPayloadLen = length(FinalPayload),
    if FinalPayloadLen > (?MAX_PAYLOAD_SIZE) ->
	   Delta = FinalPayloadLen - (?MAX_PAYLOAD_SIZE),
	   MsgLen = size(Msg),
	   if MsgLen /= 0 ->
		  CutMsg = if MsgLen > Delta ->
				   ejabberd_push:utf8_cut(Msg, MsgLen - Delta);
			      true -> <<"">>
			   end,
		  make_payload(State, CutMsg, Badge, Sound, Sender,
			       CustomFields);
	      true -> {[{aps, {AppsPayloadList}}]}
	   end;
       true -> {FinalPayload}
    end.

bounce_message(From, To, Packet) ->
    bounce_message(From, To, Packet,
		   <<"Unable to connect to push service">>).

bounce_message(From, To, Packet, Reason) ->
    #xmlel{attrs = Attrs} = Packet,
    Type = fxml:get_attr_s(<<"type">>, Attrs),
    if Type /= <<"error">>; Type /= <<"result">> ->
	   ejabberd_router:route(
	     To, From,
	     jlib:make_error_reply(
	       Packet,
	       ?ERRT_INTERNAL_SERVER_ERROR(
		  fxml:get_attr_s(<<"xml:lang">>, Attrs), Reason)));
       true -> ok
    end.

queue_message(From, To, Packet, State) ->
    WaitTime = exp_backoff(State),
    queue_message(From, To, Packet, WaitTime, State).

queue_message(From, To, Packet, WaitTime, State) ->
    NewState = case State#state.queue of
		 {?MAX_QUEUE_SIZE, Queue} ->
		     {{value, {From1, To1, Packet1}}, Queue1} =
			 queue:out(Queue),
		     bounce_message(From1, To1, Packet1,
				    <<"Unable to connect to push service">>),
		     Queue2 = queue:in({From, To, Packet}, Queue1),
		     State#state{queue = {?MAX_QUEUE_SIZE, Queue2}};
		 {Size, Queue} ->
		     Queue1 = queue:in({From, To, Packet}, Queue),
		     ?INFO_MSG("GCM: message enqueued. Current queue "
			       "size: ~p",
			       [Size + 1]),
		     State#state{queue = {Size + 1, Queue1}}
	       end,
    enqueued(WaitTime, NewState).

enqueued(WaitTime,
	 #state{mode = ?MODE_ACCEPT, prev_attempts = Attempts} =
	     State) ->
    ?INFO_MSG("Setting GCM service to enqueue mode "
	      "(or programmed retry failed). Next retry in ~p milliseconds.",
	      [WaitTime]),
    erlang:send_after(WaitTime, self(), resend),
    State#state{mode = ?MODE_ENQUEUE,
		prev_attempts = Attempts + 1};
enqueued(_, State) -> State.

active(#state{prev_attempts = Attempts} = State)
    when Attempts > 0 ->
    ?INFO_MSG("Setting GCM service to active mode.", []),
    State#state{mode = ?MODE_ACTIVE, prev_attempts = 0};
active(State) -> State#state{mode = ?MODE_ACTIVE}.

resend_messages(#state{queue = {_, Queue}} = State) ->
    ?INFO_MSG("Resending pending messages...", []),
    lists:foldl(fun ({From, To, Packet}, AccState) ->
			case catch handle_message(From, To, Packet, AccState) of
			  {'EXIT', _} = Err ->
			      ?ERROR_MSG("error while processing message:~n** "
					 "From: ~p~n** To: ~p~n** Packet: ~p~n** "
					 "Reason: ~p",
					 [From, To, Packet, Err]),
			      AccState;
			  NewAccState -> NewAccState
			end
		end,
		State#state{queue = {0, queue:new()},
			    mode = ?MODE_ACCEPT},
		queue:to_list(Queue)).

iq_disco(Lang) ->
    [#xmlel{name = <<"identity">>,
	    attrs =
		[{<<"category">>, <<"gateway">>},
		 {<<"type">>, <<"gcm">>},
		 {<<"name">>,
		  translate:translate(Lang,
				      <<"Google Cloud Messaging Service">>)}],
	    children = []},
     #xmlel{name = <<"feature">>,
	    attrs = [{<<"var">>, ?NS_DISCO_INFO}], children = []}].

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

http_date_to_msecs(_RetryAfter) -> ?MIN_RETRY_WAIT.

exp_backoff(RetryAfter, State) ->
    erlang:max(RetryAfter, exp_backoff(State)).

exp_backoff(#state{prev_attempts = 0}) ->
    ?MIN_RETRY_WAIT;
exp_backoff(#state{prev_attempts = Attempts}) ->
    random:seed(),
    K = random:uniform(round(math:pow(2, Attempts) - 1)),
    K * (?MIN_RETRY_WAIT).

iolist_to_string(S) ->
    binary_to_list(iolist_to_binary(S)).

depends(_Host, _Opts) ->
    [{mod_gcm, hard}].

mod_opt_type(apikey) -> fun iolist_to_string/1;
mod_opt_type(gateway) -> fun iolist_to_string/1;
mod_opt_type(host) -> fun iolist_to_binary/1;
mod_opt_type(hosts) ->
    fun (L) when is_list(L) ->
	    [{iolist_to_binary(H), O} || {H, O} <- L]
    end;
mod_opt_type(sound_file) -> fun iolist_to_binary/1;
mod_opt_type(_) ->
    [apikey, gateway, host, hosts, sound_file].
