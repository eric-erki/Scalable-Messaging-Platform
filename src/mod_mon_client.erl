%%%-------------------------------------------------------------------
%%% File    : mod_mon_client.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Dummy XMPP client to monitor listener connection
%%% Created : 18 Mar 2015 by Christophe Romain <christophe.romain@process-one.net>
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
%%%-------------------------------------------------------------------

-module(mod_mon_client).

-behaviour(ejabberd_config).

-export([start/1, depends/2, opt_type/1]).

-include("logger.hrl").

-define(TCP_SEND_TIMEOUT, 10000).
-define(TCP_SEND_BUFF, 1024).
-define(TCP_RECV_BUFF, 2048).
-define(EXPECT_TIMEOUT, 30000).

-record(state, {host, start, sock, inbox=[]}).

start(Host) ->
    case ejabberd_config:get_option({test_client, Host},
                                    fun(V) when is_list(V) -> V end,
                                    undefined) of
        undefined ->
            ok;
        ClientSpec ->
            {Ip, Port} = proplists:get_value(interface, ClientSpec, {{127,0,0,1},5222}),
            Start = os:timestamp(),

            case gen_tcp:connect(Ip, Port,
                                [binary, {packet, 0},
                                {send_timeout, ?TCP_SEND_TIMEOUT},
                                {recbuf, ?TCP_RECV_BUFF}, {sndbuf, ?TCP_SEND_BUFF}]) of
                {ok, Sock} ->
                    mod_mon:sum(Host, client_conn_time, age(Start)),
                    Login = proplists:get_value(login, ClientSpec),
                    Pass = proplists:get_value(password, ClientSpec),
                    self() ! connect(Host, Login, Pass, <<"test_client">>),
                    self() ! {set, client_auth_time},
                    self() ! roster(),
                    self() ! {set, client_roster_time},
                    self() ! disconnect(),
                    Result = loop(#state{host=Host, start=Start, sock=Sock}),
                    timer:sleep(1000),
                    gen_tcp:close(Sock),
                    Result;
                Error ->
                    mod_mon:sum(Host, client_conn_time, ?TCP_SEND_TIMEOUT),
                    ?ERROR_MSG("test_client connection failed: ~p", [Error]),
                    Error
            end
    end.

loop(State) ->
    receive
        {add_inbox, InboxFromWait} ->
            Inbox = State#state.inbox++InboxFromWait,
            loop(State#state{inbox = Inbox});
        {tcp, _Sock, Raw} ->
            Now = os:timestamp(),
            Packets = binary:split(Raw, <<"\r\n">>, [global,trim]), %% TODO improve, use xml from ejabberd
            Inbox = State#state.inbox++[{Packet, Now} || Packet <- Packets],
            loop(State#state{inbox = Inbox});
        flush ->
            loop(State#state{inbox = []});
        quit ->
            handle(quit, State);
        {tcp_closed, _Sock} ->
            ok;
        {set, Probe} ->
            mod_mon:sum(State#state.host, Probe, age(State#state.start)),
            loop(State);
        {recv, Match} ->
            case match_inbox(State#state.inbox, Match) of
                false ->
                    case handle({recv, Match}, State) of
                        {error, Reason} -> {error, Reason};
                        _ -> loop(State)
                    end;
                {_Stamp, Inbox} ->
                    loop(State#state{inbox = Inbox})
            end;
        OpCode ->
            case handle(OpCode, State) of
                {error, Reason} -> {error, Reason};
                _ -> loop(State)
            end
    end.


handle(Calls, State) when is_list(Calls) ->
    self() ! flush, % force inbox flush after executing block of actions
    lists:foldl(
        fun(Call, ok) -> erlang:yield(), handle(Call, State);
            (_, Res) -> Res
        end, ok, Calls);

handle({send, Data}, State) -> gen_tcp:send(State#state.sock, Data);
handle({recv, Match}, State) -> wait_tcp(State, Match, ?EXPECT_TIMEOUT);
handle(nop, _State) -> ok;
handle(quit, State) -> gen_tcp:close(State#state.sock);
handle(Other, _State) -> {error, {badarg, Other}}.

%%%
%%% utilities
%%%

match_inbox(Inbox, Pattern) -> match_inbox(Inbox, Pattern, size(Pattern), []).
match_inbox([], _, _, _) -> false;
match_inbox([{Packet,Stamp}|Tail], Pattern, Size, Acc) ->
    case binary:match(Packet, Pattern) of
        {_, Size} -> {Stamp, lists:reverse(Acc)++Tail};
        _ -> match_inbox(Tail, Pattern, Size, [{Packet,Stamp}|Acc])
    end.

wait_tcp(State, Match, Timeout) ->
    Start = os:timestamp(),
    receive
        {tcp, _Sock, Raw} ->
            Now =  os:timestamp(),
            Packets = binary:split(Raw, <<"\r\n">>, [global,trim]), %% TODO improve, use xml from ejabberd
            Inbox = [{Packet, Now} || Packet <- Packets],
            case match_inbox(Inbox, Match) of
                false ->
                    self() ! {add_inbox, Inbox},
                    wait_tcp(State, Match, Timeout-age(Start, Now));
                {_, Other} ->
                    [self() ! {add_inbox, Other} || Other=/=[]],
                    ok
            end
    after Timeout ->
            {error, recv_timeout}
    end.

age(Since) -> age(Since, os:timestamp()).
age(Since, To) -> timer:now_diff(To, Since) div 1000.

%%%
%%% XMPP Stream helpers taken from sandstorm
%%%

connect(Server, User, Pass, Resource) ->
    Auth = case User of
	undefined -> {send, auth_anon()};
	_ -> {send, auth(User, Pass)}
    end,
    Bind = case Resource of
	undefined -> {send, bind()};
	_ -> {send, bind_with_resource(Resource)}
    end,
    [{send, init(Server)},
     {recv, <<"PLAIN">>},
     Auth,
     {send, init(Server)},
     Bind,
     {send, session()},
     {recv, connected()},
     {send, online()}].

disconnect() ->
    [{send, offline()},
     {send, close()}].

roster() ->
    [{send, getroster()},
     {recv, gotroster()}].

%%%
%%% XMPP packets used
%%% TODO: use #xmlel and ejabberd jlib instead
%%%

init(Arg1) -> <<"<?xml version='1.0'?><stream:stream to='", Arg1/binary, "' version='1.0' xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'>">>.
auth(Arg1, Arg2) -> <<"<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='PLAIN'>", (base64:encode(<<"\0", Arg1/binary, "\0", Arg2/binary>>))/binary, "</auth>">>.
auth_anon() -> <<"<auth xmlns='urn:ietf:params:xml:ns:xmpp-sasl' mechanism='ANONYMOUS'/>">>.
bind() -> <<"<iq type='set' id='bind' xmlns='jabber:client'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'/></iq>">>.
bind_with_resource(Arg1) -> <<"<iq type='set' id='bind' xmlns='jabber:client'><bind xmlns='urn:ietf:params:xml:ns:xmpp-bind'><resource>", Arg1/binary, "</resource></bind></iq>">>.
session() -> <<"<iq type='set' id='session' xmlns='jabber:client'><session xmlns='urn:ietf:params:xml:ns:xmpp-session'/></iq>">>.
close() -> <<"</stream:stream>">>.
%message(Arg1, Arg2, Arg3) -> <<"<message to='", Arg1/binary, "' id='", Arg2/binary, "'><body>", Arg3/binary, "</body></message>">>.
getroster() -> <<"<iq type='get'><query xmlns='jabber:iq:roster'/></iq>">>.
gotroster() -> <<"jabber:iq:roster">>.
online() -> <<"<presence><priority>0</priority></presence>">>.
offline() -> <<"<presence type='unavailable'><status>Logged out</status></presence>">>.
connected() -> <<"<success">>.
%result() -> <<"type='result'">>.
%error() -> <<"type='error'">>.

depends(_Host, _Opts) ->
    [{mod_mon, hard}].

opt_type(test_client) ->
    fun (V) when is_list(V) -> V end;
opt_type(_) -> [test_client].
