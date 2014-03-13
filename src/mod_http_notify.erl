%%%----------------------------------------------------------------------
%%% File    : mod_http_notify.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Send HTTP notifications about some events
%%% Created :  9 Oct 2013 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2014   ProcessOne
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
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(mod_http_notify).
-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2,
	 stop/1,
         offline_packet/3,
         user_available/1,
         set_presence/4,
         user_unavailable/4]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

start(Host, _Opts) ->
    ejabberd:start_app(inets),
    ejabberd_hooks:add(offline_message_hook, Host, ?MODULE,
		       offline_packet, 35),
    ejabberd_hooks:add(user_available_hook, Host,
		       ?MODULE, user_available, 50),
    ejabberd_hooks:add(set_presence_hook, Host,
		       ?MODULE, set_presence, 50),
    ejabberd_hooks:add(unset_presence_hook, Host,
		       ?MODULE, user_unavailable, 50),
    ok.


stop(Host) ->
    ejabberd_hooks:delete(offline_message_hook, Host, ?MODULE,
                          offline_packet, 35),
    ejabberd_hooks:delete(user_available_hook, Host,
                          ?MODULE, user_available, 50),
    ejabberd_hooks:delete(set_presence_hook, Host,
                          ?MODULE, set_presence, 50),
    ejabberd_hooks:delete(unset_presence_hook, Host,
                          ?MODULE, user_unavailable, 50),
    ok.


offline_packet(From, To, Packet) ->
    Host = To#jid.lserver,
    case get_opt(Host, offline_message) of
        {URL, AuthToken} ->
            Type = xml:get_tag_attr_s(<<"type">>, Packet),
            Body = xml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),
            if (Type == <<"normal">>) or (Type == <<"">>) or
               (Type == <<"chat">>),
               Body /= <<"">> ->
                    SFrom = jlib:jid_to_string(From),
                    STo = jlib:jid_to_string(To),
                    Params =
                        [{"notification_type", "offline"},
                         {"from", SFrom},
                         {"to", STo},
                         {"body", Body},
                         {"access_token", AuthToken}],
                    send_notification(URL, Params),
                    ok;
               true ->
                    ok
            end;
        none ->
            ok
    end.

user_available(JID) ->
    Host = JID#jid.lserver,
    case get_opt(Host, user_available) of
        {URL, AuthToken} ->
            SJID = jlib:jid_to_string(JID),
            Params =
                [{"notification_type", "available"},
                 {"jid", SJID},
                 {"access_token", AuthToken}],
            send_notification(URL, Params),
            ok;
        none ->
            ok
    end.

set_presence(User, Server, Resource, _Presence) ->
    Host = jlib:nameprep(Server),
    case get_opt(Host, set_presence) of
        {URL, AuthToken} ->
            JID = jlib:make_jid(User, Server, Resource),
            SJID = jlib:jid_to_string(JID),
            Params =
                [{"notification_type", "set-presence"},
                 {"jid", SJID},
                 {"access_token", AuthToken}],
            send_notification(URL, Params),
            ok;
        none ->
            ok
    end.

user_unavailable(User, Server, Resource, _Status) ->
    Host = jlib:nameprep(Server),
    case get_opt(Host, unset_presence) of
        {URL, AuthToken} ->
            JID = jlib:make_jid(User, Server, Resource),
            SJID = jlib:jid_to_string(JID),
            Params =
                [{"notification_type", "unavailable"},
                 {"jid", SJID},
                 {"access_token", AuthToken}],
            send_notification(URL, Params),
            ok;
        none ->
            ok
    end.


send_notification(URL, Params) ->
    KVs = lists:map(
            fun({K, V})->
                    K1 = iolist_to_binary(K),
                    V1 = ejabberd_http:url_encode(
                           iolist_to_binary(V)),
                    <<K1/binary, "=", V1/binary>>
            end, Params),
    Data = str:join(KVs, "&"),
    httpc:request(
      post,
      {URL, [], "application/x-www-form-urlencoded", Data},
      [], []).


get_opt(Host, Name) ->
    gen_mod:get_module_opt(
      Host, ?MODULE, Name,
      fun(L) when is_list(L) ->
              URL = proplists:get_value(url, L),
              AuthToken = proplists:get_value(auth_token, L, ""),
              if
                  is_list(URL) ->
                      {URL, AuthToken};
                  is_binary(URL) ->
                      {binary_to_list(URL), AuthToken}
              end
      end,
      none).




