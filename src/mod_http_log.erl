%%%----------------------------------------------------------------------
%%% File    : mod_http_log.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Log XMPP packets over HTTP
%%% Created : 18 Mar 2014 by Alexey Shchepin <alexey@process-one.net>
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

%% Example config:
%%  as child of ejabberd_http listener:
%%      request_handlers:
%%        "/log": mod_http_log
%%
%%  in the module section:
%%      mod_http_log:
%%        access: admin
%%
%% Then to get logs for test@localhost use the following URL:
%% http://localhost:5280/log/test@localhost

-module(mod_http_log).

-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, socket_handoff/6,
	 send_packet/4, receive_packet/5, depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("ejabberd_http.hrl").
-include("ejabberd_web_admin.hrl").

-record(log_http, {us :: {binary(), binary()},
                   pid :: pid(),
                   opts = []}).

%% -------------------
%% Module control
%% -------------------

start(Host, _Opts) ->
    mnesia:create_table(log_http,
			[{ram_copies, [node()]}, {local_content, true},
			 {attributes, record_info(fields, log_http)}]),
    mnesia:add_table_copy(log_http, node(), ram_copies),
    ejabberd_hooks:add(user_send_packet, Host,
                       ?MODULE, send_packet, 90),
    ejabberd_hooks:add(user_receive_packet, Host,
                       ?MODULE, receive_packet, 90),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_send_packet, Host,
                          ?MODULE, send_packet, 90),
    ejabberd_hooks:delete(user_receive_packet, Host,
			  ?MODULE, receive_packet, 90),
    ok.



socket_handoff([SJID],
               #request{method = 'GET',
                        auth = Auth},
               Socket, SockMod, _Buf, _Opts) ->
    case get_auth_admin(Auth) of
        {ok, {_User, _Server}} ->
            case jid:from_string(SJID) of
                #jid{} = JID when JID#jid.luser /= <<"">> ->
                    SockMod:send(
                      Socket,
                      <<"HTTP/1.1 200 OK\r\n"
                       "Content-Type: text/plain; charset=utf-8\r\n\r\n">>),
                    case SockMod of
                        gen_tcp ->
                            inet:setopts(Socket, [{active, true}]);
                        _ ->
                            SockMod:setopts(Socket, [{active, true}])
                    end,
                    mnesia:dirty_write(
                      #log_http{us = {JID#jid.luser, JID#jid.lserver},
                                pid = self(),
                                opts = []}),
                    case catch loop(SockMod, Socket) of
                        _ ->
                            mnesia:dirty_delete(
                              log_http, {JID#jid.luser, JID#jid.lserver}),
                            catch SockMod:close(Socket),
                            none
                    end;
                error ->
                    {400, [],
                     ejabberd_web:make_xhtml([?XC(<<"h1">>, <<"400 Bad Request">>)])}
            end;
        {unauthorized, <<"no-auth-provided">>} ->
            {401,
             [{<<"WWW-Authenticate">>,
               <<"basic realm=\"ejabberd\"">>}],
             ejabberd_web:make_xhtml([?XC(<<"h1">>, <<"Unauthorized">>)])};
        {unauthorized, _Error} ->
            {401,
             [{<<"WWW-Authenticate">>,
               <<"basic realm=\"auth error, retry login to ejabberd\"">>}],
             ejabberd_web:make_xhtml([?XC(<<"h1">>, <<"Unauthorized">>)])}
    end;
socket_handoff(_LocalPath, _Request, _Socket, _SockMod, _Buf, _Opts) ->
    ejabberd_web:error(not_found).


get_auth_admin(Auth) ->
    case Auth of
        {SJID, Pass} ->
            AccessRule =
                gen_mod:get_module_opt(
                  ?MYNAME, ?MODULE, access,
                  fun(A) -> A end, none),
            case jid:from_string(SJID) of
                error -> {unauthorized, <<"badformed-jid">>};
                #jid{user = <<"">>, server = User} ->
                    get_auth_account(?MYNAME, AccessRule, User, ?MYNAME, Pass);
                #jid{user = User, server = Server} ->
                    get_auth_account(?MYNAME, AccessRule, User, Server, Pass)
            end;
        undefined ->
            {unauthorized, <<"no-auth-provided">>}
    end.

get_auth_account(HostOfRule, AccessRule, User, Server, Pass) ->
    case ejabberd_auth:check_password(User, <<"">>, Server, Pass) of
        true ->
            case is_acl_match(HostOfRule, AccessRule,
                              jid:make(User, Server, <<"">>)) of
                false -> {unauthorized, <<"unprivileged-account">>};
                true -> {ok, {User, Server}}
            end;
        false ->
            case ejabberd_auth:is_user_exists(User, Server) of
                true -> {unauthorized, <<"bad-password">>};
                false -> {unauthorized, <<"inexistent-account">>}
            end
    end.

is_acl_match(Host, Rule, JID) ->
    allow == acl:match_rule(Host, Rule, JID).


send_packet(Packet, _StateData, From, _To) ->
    log(From, <<"SEND">>, Packet),
    Packet.

receive_packet(Packet, _StateData, JID, _From, _To) ->
    log(JID, <<"RECV">>, Packet),
    Packet.

log(JID, Prefix, Packet) ->
    case catch mnesia:dirty_read(log_http, {JID#jid.luser, JID#jid.lserver}) of
        [#log_http{pid = Pid}] ->
            TS = jlib:now_to_local_string(p1_time_compat:timestamp()),
            SPacket = fxml:element_to_binary(Packet),
            Pid ! {log, [Prefix, <<" ">>, TS, <<"\n">>, SPacket, <<"\n">>]},
            ok;
        _ ->
            ok
    end.

loop(SockMod, Socket) ->
    receive
        {log, Data} ->
            case SockMod:send(Socket, Data) of
                ok ->
                    loop(SockMod, Socket);
                _ ->
                    ok
            end;
        {tcp_closed, _} ->
            ok;
        {ssl_closed, _} ->
            ok;
        {tcp_error, _, _} ->
            ok;
        {ssl_error, _, _} ->
            ok;
        _ ->
            loop(SockMod, Socket)
    end.

depends(_Host, _Opts) ->
    [].

mod_opt_type(access) -> fun acl:access_rules_validator/1;
mod_opt_type(_) -> [access].
