%%%----------------------------------------------------------------------
%%% File    : mod_http_watchdog.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Simple watchdog
%%% Created : 2 Sep 2013 by Christophe Romain <christophe.romain@process-one.net>
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

%% Configuration:
%%
%%  request_handlers,
%%    "status": mod_http_watchdog
%%
%%  modules:
%%    ...
%%    mod_http_watchdog:
%%       test_domain: "localhost"
%%       test_user: "watchdog"
%%       test_pass: "1234"
%%    ..

-module(mod_http_watchdog).

-export([process/2]).

-behaviour(gen_mod).

-export([start/2, stop/1, depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").

-include("ejabberd_http.hrl").

-define(CONNECT_TIMEOUT, 5000).

-define(MAX_RESPONSE_BUFFER, 300).

process([<<"check">>], Request) ->
    case lists:keyfind(<<"action">>, 1, Request#request.q)
	of
      {<<"action">>, <<"CHECK">>} -> check();
      {<<"action">>, Unknown} ->
	  {501, [], <<"Unknown action: ", Unknown/binary>>};
      _ -> {400, [], <<"action parameter required">>}
    end;
process(_InvalidPath, _Request) ->
    {404, [], <<"Not found">>}.

check() ->
    [ClientDomain | _] = lists:filter(fun (V) -> V /= <<"">>
				      end,
				      [gen_mod:get_module_opt(
                                         Domain, ?MODULE,
                                         test_domain,
                                         fun iolist_to_binary/1,
                                         <<"">>)
				       || Domain <- ?MYHOSTS]),
    case check_c2s(ClientDomain) of
      ok ->
	  case check_auth(ClientDomain) of
	    ok -> {200, [], <<"XMPP_OK">>};
	    {error, Reason} -> {503, [], Reason}
	  end;
      {error, Reason} -> {503, [], Reason}
    end.

check_auth(ClientDomain) ->
    [ClientUser | _] = lists:filter(fun (V) -> V /= <<"">>
				    end,
				    [gen_mod:get_module_opt(
                                       Domain, ?MODULE,
                                       test_user,
                                       fun iolist_to_binary/1,
                                       <<"">>)
				     || Domain <- ?MYHOSTS]),
    [ClientPass | _] = lists:filter(fun (V) -> V /= <<"">>
				    end,
				    [gen_mod:get_module_opt(
                                       Domain, ?MODULE,
                                       test_pass,
                                       fun iolist_to_binary/1,
                                       <<"">>)
				     || Domain <- ?MYHOSTS]),
    case ejabberd_auth:check_password(ClientUser, <<"">>,
				      ClientDomain, ClientPass)
	of
      true -> ok;
      false ->
	  {error,
	   io_lib:format("Can't authenticate watchdog device ~p "
			 ": ~p",
			 [ClientUser, ClientPass])}
    end.

check_c2s(Domain) ->
    case get_ip_port() of
      error ->
	  {error,
	   <<"c2s listeners not configured, check "
	     "ejabberd.cfg">>};
      {Port, Ip} ->
	  case gen_tcp:connect(Ip, Port, [{active, false}, binary],
			       ?CONNECT_TIMEOUT)
	      of
	    {ok, Socket} ->
		send_header(Socket, Domain),
		wait_for_header(Socket, <<>>);
	    {error, Reason} ->
		{error,
		 io_lib:format("Error connecting with c2s port ~p:~p "
			       " ~p",
			       [Ip, Port, Reason])}
	  end
    end.

send_header(Socket, Domain) ->
    gen_tcp:send(Socket,
		 [<<"<stream:stream version='1.0' to='">>, Domain,
		  <<"' xml:lang='en' xmlns='jabber:client' "
		    "\r\n\t\t\txmlns:stream='http://etherx.jabber."
		    "org/streams'>">>]).

wait_for_header(_Socket, Buffer)
    when size(Buffer) > ?MAX_RESPONSE_BUFFER ->
    {error, <<"Invalid response on c2s:", Buffer/binary>>};
wait_for_header(Socket, Buffer) ->
    case gen_tcp:recv(Socket, 0, ?CONNECT_TIMEOUT) of
      {ok, X} ->
	  NewBuffer = <<Buffer/binary, X/binary>>,
	  case str:str(NewBuffer, <<"features>">>) of
	    0 -> wait_for_header(Socket, NewBuffer);
	    _ ->
		ok %% we receive stream features, everything seems ok
	  end;
      {error, Reason} ->
	  {error,
	   io_lib:format("Error receiving data from c2s socket: ~p",
			 [Reason])}
    end.

get_ip_port() ->
    L = ejabberd_config:get_local_option(
          listen, fun ejabberd_listener:validate_cfg/1),
    case lists:keyfind(ejabberd_c2s, 2, L) of
      false -> error;
      {{Port, Ip, _}, ejabberd_c2s, _Opt} ->
	  IPToUse = case Ip of
		      {0, 0, 0, 0} -> {127, 0, 0, 1};
		      _ -> Ip
		    end,
	  {Port, IPToUse}
    end.

%% gen mod

start(_, _) -> ok.

stop(_) -> ok.

depends(_Host, _Opts) ->
    [].

mod_opt_type(test_domain) -> fun iolist_to_binary/1;
mod_opt_type(test_pass) -> fun iolist_to_binary/1;
mod_opt_type(test_user) -> fun iolist_to_binary/1;
mod_opt_type(_) -> [test_domain, test_pass, test_user].
