%%%-------------------------------------------------------------------
%%% @author Pablo Polvorin <pablo.polvorin@process-one.net>
%%%   From splitted from mod_offline
%%% @doc
%%%
%%% @end
%%%
%%%
%%% ejabberd, Copyright (C) 2012-2017   ProcessOne
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
-module(mod_offline_worker).

-define(GEN_SERVER, p1_server).
-behaviour(?GEN_SERVER).

-export([start_link/2]).

-export([init/1, handle_call/3, handle_cast/2,
	 handle_info/2, terminate/2, code_change/3,
	 mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_http.hrl").

-include("mod_offline.hrl").

receive_all(US, Msgs, DBType) ->
    receive
      #offline_msg{us = US} = Msg ->
	  receive_all(US, [Msg | Msgs], DBType)
      after 0 ->
		case DBType of
		  mnesia -> Msgs;
		  sql -> lists:reverse(Msgs);
                  p1db -> Msgs;
		  riak -> Msgs;
                  rest -> Msgs
		end
    end.

start_link(MyName, [Host, Opts]) ->
    ?GEN_SERVER:start_link({local, MyName}, ?MODULE, [Host, Opts], [{max_queue,5000}]).

init([Host, Opts]) ->
    AccessMaxOfflineMsgs =
	gen_mod:get_opt(access_max_user_messages, Opts,
                        fun acl:access_rules_validator/1,
			max_user_offline_messages),
    {ok,
     #state{host = Host,
            access_max_offline_messages = AccessMaxOfflineMsgs,
            dbtype = gen_mod:db_type(Host, Opts, mod_offline)}}.


handle_cast(_Msg, State) -> {noreply, State}.


handle_info(#offline_msg{us = UserServer} = Msg, State) ->
    #state{host = Host,
           access_max_offline_messages = AccessMaxOfflineMsgs,
           dbtype = DBType} = State,
    Msgs = receive_all(UserServer, [Msg], DBType),  %%This is useless.. p1_server already consume the process queue
    Len = length(Msgs),
    MaxOfflineMsgs = mod_offline:get_max_user_messages(AccessMaxOfflineMsgs,
                                           UserServer, Host),
    mod_offline:store_offline_msg(Host, UserServer, Msgs, Len, MaxOfflineMsgs),
    {noreply, State};
handle_info({execute, F}, State) ->
    try
        F()
    catch
        Class:Reason ->
            ST = erlang:get_stacktrace(),
            ?ERROR_MSG("Internal error while executing ~p: ~p",
                       [F, {Class, Reason, ST}])
    end,
    {noreply, State};
handle_info(_Info, State) ->
    ?ERROR_MSG("got unexpected info: ~p", [_Info]),
    {noreply, State}.

handle_call(_Call,_From, State) ->
    ?ERROR_MSG("got unexpected call: ~p", [_Call]),
    {reply, ok,  State}.

terminate(_Reason, _State) ->
    ok.


code_change(_OldVsn, State, _Extra) -> {ok, State}.


mod_opt_type(access_max_user_messages) -> fun acl:access_rules_validator/1;
mod_opt_type(db_type) -> fun(T) -> ejabberd_config:v_db(mod_offline, T) end;
mod_opt_type(_) -> [access_max_user_messages, db_type].
