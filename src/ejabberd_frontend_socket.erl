%%%-------------------------------------------------------------------
%%% File    : ejabberd_frontend_socket.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Frontend socket with zlib and TLS support library
%%% Created : 23 Aug 2006 by Alexey Shchepin <alexey@process-one.net>
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

-module(ejabberd_frontend_socket).

-author('alexey@process-one.net').

-behaviour(gen_server).

%% API
-export([start/4,
	 start_link/5,
	 %connect/3,
	 starttls/2,
	 starttls/3,
	 compress/1,
	 compress/2,
	 reset_stream/1,
	 send/2,
	 change_shaper/2,
	 monitor/1,
	 get_sockmod/1,
	 get_peer_certificate/1,
	 get_verify_result/1,
	 close/1,
	 setopts/2,
	 change_controller/2,
	 sockname/1, peername/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3]).

-record(socket_state, {sockmod, socket, receiver}).

-define(HIBERNATE_TIMEOUT, 90000).

%%====================================================================
%% API
%%====================================================================
start_link(Module, SockMod, Socket, Opts, Receiver) ->
    gen_server:start_link(?MODULE,
			  [Module, SockMod, Socket, Opts, Receiver], []).

start(Module, SockMod, Socket, Opts) ->
    case Module:socket_type() of
      xml_stream ->
	  MaxStanzaSize = case lists:keysearch(max_stanza_size, 1,
					       Opts)
			      of
			    {value, {_, Size}} -> Size;
			    _ -> infinity
			  end,
	  Receiver = ejabberd_receiver:start(Socket, SockMod,
					     none, MaxStanzaSize),
	  case SockMod:controlling_process(Socket, Receiver) of
	    ok -> ok;
	    {error, _Reason} -> SockMod:close(Socket)
	  end,
	  supervisor:start_child(ejabberd_frontend_socket_sup,
				 [Module, SockMod, Socket, Opts, Receiver]);
      raw ->
	  %{ok, Pid} = Module:start({SockMod, Socket}, Opts),
	  %case SockMod:controlling_process(Socket, Pid) of
	  %    ok ->
	  %        ok;
	  %    {error, _Reason} ->
	  %        SockMod:close(Socket)
	  %end
	  todo
    end.

starttls(FsmRef, TLSOpts) ->
    starttls(FsmRef, TLSOpts, undefined).

starttls(FsmRef, TLSOpts, Data) ->
    case catch gen_server:call(FsmRef, {starttls, TLSOpts, Data}) of
        {'EXIT', Err} ->
            {error, Err};
        ok ->
            {ok, FsmRef};
        Err ->
            Err
    end.

compress(FsmRef) -> compress(FsmRef, undefined).

compress(FsmRef, Data) ->
    case catch gen_server:call(FsmRef, {compress, Data}) of
        {'EXIT', Err} ->
            {error, Err};
        ok ->
            {ok, FsmRef};
        Err ->
            Err
    end.

reset_stream(FsmRef) ->
    gen_server:call(FsmRef, reset_stream).

send(FsmRef, Data) ->
    gen_server:call(FsmRef, {send, Data}).

change_shaper(FsmRef, Shaper) ->
    gen_server:call(FsmRef, {change_shaper, Shaper}).

monitor(FsmRef) -> erlang:monitor(process, FsmRef).

get_sockmod(FsmRef) ->
    gen_server:call(FsmRef, get_sockmod).

get_peer_certificate(FsmRef) ->
    gen_server:call(FsmRef, get_peer_certificate).

get_verify_result(FsmRef) ->
    gen_server:call(FsmRef, get_verify_result).

close(FsmRef) -> gen_server:call(FsmRef, close).

sockname(FsmRef) -> gen_server:call(FsmRef, sockname).

peername(FsmRef) ->
    gen_server:call(FsmRef, peername).

setopts(FsmRef, Opts) ->
    gen_server:call(FsmRef, {setopts, Opts}).

change_controller(FsmRef, C2SPid) ->
    gen_server:call(FsmRef, {change_controller, C2SPid}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Module, SockMod, Socket, Opts, Receiver]) ->
    Node = ejabberd_node_groups:get_closest_node(backend),
    IP = case peername(SockMod, Socket) of
	   {ok, IP1} -> IP1;
	   _ -> undefined
	 end,
    case check_starttls(SockMod, Socket, Receiver, Opts) of
        {ok, SockMod2, Socket2} ->
            {ok, Pid} = ejabberd_cluster:call(
                          Node, Module, start,
                          [{?MODULE, self()}, [{frontend_ip, IP} | Opts]]),
            ejabberd_receiver:become_controller(Receiver, Pid),
            {ok,
             #socket_state{sockmod = SockMod2, socket = Socket2,
                           receiver = Receiver}};
        {error, _} ->
            {stop, normal}
    end.

handle_call({starttls, TLSOpts, Data}, _From, State) ->
    case ejabberd_receiver:starttls(State#socket_state.receiver,
                                    TLSOpts, Data) of
        {ok, TLSSocket} ->
            {reply, ok, State#socket_state{socket = TLSSocket,
                                           sockmod = fast_tls},
             ?HIBERNATE_TIMEOUT};
        {error, _} = Err ->
            {stop, normal, Err, State}
    end;
handle_call({compress, Data}, _From, State) ->
    case ejabberd_receiver:compress(State#socket_state.receiver, Data) of
        {ok, ZlibSocket} ->
            {reply, ok, State#socket_state{socket = ZlibSocket,
                                           sockmod = ezlib},
             ?HIBERNATE_TIMEOUT};
        {error, _} = Err ->
            {stop, normal, Err, State}
    end;
handle_call(reset_stream, _From, State) ->
    ejabberd_receiver:reset_stream(State#socket_state.receiver),
    Reply = ok,
    {reply, Reply, State, ?HIBERNATE_TIMEOUT};
handle_call({send, Data}, _From, State) ->
    catch (State#socket_state.sockmod):send(State#socket_state.socket, Data),
    Reply = ok,
    {reply, Reply, State, ?HIBERNATE_TIMEOUT};
handle_call({change_shaper, Shaper}, _From, State) ->
    ejabberd_receiver:change_shaper(State#socket_state.receiver,
				    Shaper),
    Reply = ok,
    {reply, Reply, State, ?HIBERNATE_TIMEOUT};
handle_call(get_sockmod, _From, State) ->
    Reply = State#socket_state.sockmod,
    {reply, Reply, State, ?HIBERNATE_TIMEOUT};
handle_call(get_peer_certificate, _From, State) ->
    Reply = fast_tls:get_peer_certificate(State#socket_state.socket),
    {reply, Reply, State, ?HIBERNATE_TIMEOUT};
handle_call(get_verify_result, _From, State) ->
    Reply = fast_tls:get_verify_result(State#socket_state.socket),
    {reply, Reply, State, ?HIBERNATE_TIMEOUT};
handle_call(close, _From, State) ->
    ejabberd_receiver:close(State#socket_state.receiver),
    Reply = ok,
    {stop, normal, Reply, State};
handle_call(sockname, _From, State) ->
    #socket_state{sockmod = SockMod, socket = Socket} = State,
    Reply = peername(SockMod, Socket),
    {reply, Reply, State, ?HIBERNATE_TIMEOUT};
handle_call(peername, _From, State) ->
    #socket_state{sockmod = SockMod, socket = Socket} = State,
    Reply = case SockMod of
	      gen_tcp -> inet:peername(Socket);
	      _ -> SockMod:peername(Socket)
	    end,
    {reply, Reply, State, ?HIBERNATE_TIMEOUT};
handle_call({setopts, Opts}, _From, State) ->
    ejabberd_receiver:setopts(State#socket_state.receiver, Opts),
    {reply, ok, State, ?HIBERNATE_TIMEOUT};
handle_call({change_controller, Pid}, _From, State) ->
    ejabberd_receiver:change_controller(State#socket_state.receiver,
					Pid),
    {reply, ok, State, ?HIBERNATE_TIMEOUT};
handle_call(_Request, _From, State) ->
    Reply = ok, {reply, Reply, State, ?HIBERNATE_TIMEOUT}.

handle_cast(_Msg, State) ->
    {noreply, State, ?HIBERNATE_TIMEOUT}.

handle_info(timeout, State) ->
    proc_lib:hibernate(gen_server, enter_loop,
		       [?MODULE, [], State]),
    {noreply, State, ?HIBERNATE_TIMEOUT};
handle_info(_Info, State) ->
    {noreply, State, ?HIBERNATE_TIMEOUT}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

check_starttls(SockMod, Socket, Receiver, Opts) ->
    TLSEnabled = proplists:get_bool(tls, Opts),
    TLSOpts = lists:filter(fun({certfile, _}) -> true;
			      (_) -> false
			   end, Opts),
    if TLSEnabled ->
           case ejabberd_receiver:starttls(Receiver, TLSOpts) of
               {ok, TLSSocket} ->
                   {ok, fast_tls, TLSSocket};
               {error, _} = Err ->
                   Err
           end;
       true -> {ok, SockMod, Socket}
    end.

peername(SockMod, Socket) ->
    case SockMod of
      gen_tcp -> inet:peername(Socket);
      _ -> SockMod:peername(Socket)
    end.
