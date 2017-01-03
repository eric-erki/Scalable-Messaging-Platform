%%%----------------------------------------------------------------------
%%% File    : ejabberd_http_ws_muc_log.erl
%%% Author  : Pawel Chmielowski <pawel@process-one.net>
%%% Purpose : Websocket access to MUC room logs
%%% Created : 25-11-2014 by Pawel Chmielowski <pawel@process-one.net>
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
-module(ejabberd_http_ws_muc_log).

-author('ecestari@process-one.net').

-behaviour(gen_fsm).

% External exports
-export([start/1, start_link/1, init/1, handle_event/3,
	 handle_sync_event/4, code_change/4, handle_info/3,
	 terminate/3, send/2, setopts/2, sockname/1, peername/1,
	 controlling_process/2, become_controller/2, close/1,
	 socket_handoff/6]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_http.hrl").

-define(WEBSOCKET_TIMEOUT, 300).

-record(state,
        {socket                       :: ws_socket(),
         ws                           :: {#ws{}, pid()}}).

%-define(DBGFSM, true).

-ifdef(DBGFSM).

-define(FSMOPTS, [{debug, [trace]}]).

-else.

-define(FSMOPTS, []).

-endif.

-type ws_socket() :: {http_ws, pid(), {inet:ip_address(), inet:port_number()}}.
-export_type([ws_socket/0]).

start(WS) ->
    gen_fsm:start(?MODULE, [WS], ?FSMOPTS).

start_link(WS) ->
    gen_fsm:start_link(?MODULE, [WS], ?FSMOPTS).

send({http_ws, FsmRef, _IP}, Packet) ->
    gen_fsm:sync_send_all_state_event(FsmRef,
				      {send, Packet}).

setopts({http_ws, FsmRef, _IP}, Opts) ->
    case lists:member({active, once}, Opts) of
      true ->
	  gen_fsm:send_all_state_event(FsmRef,
				       {activate, self()});
      _ -> ok
    end.

sockname(_Socket) -> {ok, {{0, 0, 0, 0}, 0}}.

peername({http_ws, _FsmRef, IP}) -> {ok, IP}.

controlling_process(_Socket, _Pid) -> ok.

become_controller(FsmRef, C2SPid) ->
    gen_fsm:send_all_state_event(FsmRef,
				 {become_controller, C2SPid}).

close({http_ws, FsmRef, _IP}) ->
    catch gen_fsm:sync_send_all_state_event(FsmRef, close).

socket_handoff(LocalPath, Request, Socket, SockMod, Buf, Opts) ->
    ejabberd_websocket:socket_handoff(LocalPath, Request, Socket, SockMod,
                                      Buf, Opts, ?MODULE, fun get_human_html_xmlel/0).

%%% Internal

get_human_html_xmlel() ->
    Heading = <<"ejabberd ", (jlib:atom_to_binary(?MODULE))/binary>>,
    #xmlel{name = <<"html">>,
           attrs =
               [{<<"xmlns">>, <<"http://www.w3.org/1999/xhtml">>}],
           children =
               [#xmlel{name = <<"head">>, attrs = [],
                       children =
                           [#xmlel{name = <<"title">>, attrs = [],
                                   children = [{xmlcdata, Heading}]}]},
                #xmlel{name = <<"body">>, attrs = [],
                       children =
                           [#xmlel{name = <<"h1">>, attrs = [],
                                   children = [{xmlcdata, Heading}]},
                            #xmlel{name = <<"p">>, attrs = [],
                                   children =
                                       [{xmlcdata, <<"Access point for getting your muc logs over WebSocket connection">>}]
                                  }]}]}.

init([{WsState, _} = WS]) ->
    %% Opts = ejabberd_c2s_config:get_c2s_limits(),
    Socket = {http_ws, self(), WsState#ws.ip},
    ?DEBUG("Muc log client connected through websocket ~p",
	   [[Socket, WsState#ws.local_path]]),
    mod_muc_log:register_listener(hd(WsState#ws.local_path), self()),

    {ok, loop,
     #state{socket = Socket, ws = WS}}.

handle_event({activate, _From}, StateName, StateData) ->
    {next_state, StateName, StateData}.

handle_sync_event(close, _From, _StateName, StateData) ->
    {stop, normal, StateData}.

handle_info(closed, _StateName, StateData) ->
    {stop, normal, StateData};
handle_info({browser, _Packet}, StateName, StateData) ->
    {next_state, StateName, StateData};
handle_info({muc_message, Msg, Nick, _RoomJid, _RoomInfo}, StateName,
            #state{ws = {_, WsPid}} = StateData) ->
    JSON = case Msg of
               join ->
                   [{<<"type">>, <<"user_join">>}, {<<"nick">>, Nick}];
               leave ->
                   [{<<"type">>, <<"user_leave">>}, {<<"nick">>, Nick}];
               {leave, Reason} ->
                   [{<<"type">>, <<"user_leave">>}, {<<"nick">>, Nick}, {<<"reason">>, Reason}];
               {kickban, <<"301">>, <<"">>} ->
                   [{<<"type">>, <<"user_banned">>}, {<<"nick">>, Nick}];
               {kickban, <<"301">>, Reason} ->
                   [{<<"type">>, <<"user_banned">>}, {<<"nick">>, Nick}, {<<"reason">>, Reason}];
               {kickban, <<"307">>, <<"">>} ->
                   [{<<"type">>, <<"user_kicked">>}, {<<"nick">>, Nick}];
               {kickban, <<"307">>, Reason} ->
                   [{<<"type">>, <<"user_kicked">>}, {<<"nick">>, Nick}, {<<"reason">>, Reason}];
               {kickban, <<"321">>, <<"">>} ->
                   [{<<"type">>, <<"user_kicked">>}, {<<"nick">>, Nick}, {<<"reason">>, <<"Affiliation change">>}];
               {kickban, <<"322">>, <<"">>} ->
                   [{<<"type">>, <<"user_kicked">>}, {<<"nick">>, Nick}, {<<"reason">>, <<"Room switched to members-only">>}];
               {kickban, <<"332">>, <<"">>} ->
                   [{<<"type">>, <<"user_kicked">>}, {<<"nick">>, Nick}, {<<"reason">>, <<"System shutdown">>}];
               {nickchange, OldNick} ->
                   [{<<"type">>, <<"nick_change">>}, {<<"nick">>, Nick}, {<<"old_nick">>, OldNick}];
               {subject, T} ->
                   [{<<"type">>, <<"subject_change">>}, {<<"nick">>, Nick}, {<<"new_subject">>, T}];
               {body, T} ->
                   [{<<"type">>, <<"message">>}, {<<"nick">>, Nick}, {<<"body">>, T}];
               _ ->
                   []
           end,
    Packet = jiffy:encode({JSON}),
    WsPid ! {send, Packet},
    {next_state, StateName, StateData};
handle_info(_, StateName, StateData) ->
    {next_state, StateName, StateData}.

code_change(_OldVsn, StateName, StateData, _Extra) ->
    {ok, StateName, StateData}.

terminate(_Reason, _StateName, _StateData) ->
    ok.
