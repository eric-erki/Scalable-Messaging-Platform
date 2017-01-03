%%%----------------------------------------------------------------------
%%% File    : ejabberd_auth_rest.erl
%%% Author  : Pablo Polvorin <pablo.polvorin@process-one.net>
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

-module(roster_rest).
-behaviour(ejabberd_config).

-export([start/2, stop/1, get_user_roster/2,
	 get_jid_info/3, opt_type/1,
         roster_subscribe/4, remove_user/2, update_roster/4,
         del_roster/3, create_roster/1]).


-include("jlib.hrl").
-include("ejabberd.hrl").
-include("logger.hrl").
-include("mod_roster.hrl").

start(Host, _Opts) ->
    rest:start(Host),
    ok.

stop(_Host) ->
    ok.

get_jid_info(LServer, LUser, LJID) ->
    {ok, Roster} = get_user_roster(LServer, LUser),
    case lists:keyfind(LJID, #roster.jid, Roster) of
      false -> not_found;
      Item -> {ok, Item}
    end.

get_user_roster(Server, User) ->
    case rest:get(Server, path(Server), [{"username", User}]) of
        {ok, 200, JSon} -> json_to_rosteritems(Server, User, JSon);
        {ok, Code, JSon} -> {error, {Code, JSon}};
        {error, Reason} -> {error, Reason}
    end.

roster_subscribe(_LUser, LServer, _LJID, Item) ->
    Content = rosteritem_to_json(Item),
    case rest:post(LServer, path(LServer), [], Content) of
        {ok, 201, _Body} ->
            ok;
        {ok, Code, Body} ->
            ?ERROR_MSG("roster_subscribe error. Code: ~p - Body: ~p", [Code, Body]),
            {error, build_error_msg(Code,Body)};
        {error, Error} ->
            ?ERROR_MSG("roster_subscribe error: ~p", [Error]),
            {error, Error}
    end.

remove_user(LUser, LServer) ->
    case rest:delete(LServer, path(LServer, LUser)) of
        {ok, 200, _Body} ->
            ok;
        {ok, Code, Body} ->
            ?ERROR_MSG("remove_roster error. Code: ~p - Body: ~p", [Code, Body]),
            {error, build_error_msg(Code,Body)};
        {error, Error} ->
            ?ERROR_MSG("remove_roster error: ~p", [Error]),
            {error, Error}
    end.

update_roster(_LUser, LServer, _LJID, Item) ->
    Content = rosteritem_to_json(Item),
    case rest:patch(LServer, path(LServer), [], Content) of
        {ok, 204, _Body} ->
            ok;
        {ok, Code, Body} ->
            ?ERROR_MSG("update_roster error. Code: ~p - Body: ~p", [Code, Body]),
            {error, build_error_msg(Code,Body)};
        {error, Error} ->
            ?ERROR_MSG("update_roster error: ~p", [Error]),
            {error, Error}
    end.

del_roster(LUser, LServer, LJID) ->
    SJID = jid:to_string(LJID),
    Entry = <<LUser/binary, "/", SJID/binary>>,
    case rest:delete(LServer, path(LServer, Entry)) of
        {ok, 200, _Body} ->
            ok;
        {ok, Code, Body} ->
            ?ERROR_MSG("del_roster error. Code: ~p - Body: ~p", [Code, Body]),
            {error, build_error_msg(Code,Body)};
        {error, Error} ->
            ?ERROR_MSG("del_roster error: ~p", [Error]),
            {error, Error}
    end.

create_roster(Item) ->
    {_LUser, LServer} = Item#roster.us,
    Content = rosteritem_to_json(Item),
    case rest:put(LServer, path(LServer), [], Content) of
        {ok, 200, _Body} ->
            ok;
        {ok, Code, Body} ->
            ?ERROR_MSG("create_roster error. Code: ~p - Body: ~p", [Code, Body]),
            {error, build_error_msg(Code,Body)};
        {error, Error} ->
            ?ERROR_MSG("create_roster error: ~p", [Error]),
            {error, Error}
    end.

json_to_rosteritems(LServer, LUser, {[{<<"roster">>, Roster}]}) ->
    try lists:map(fun ({Fields}) ->
                          fields_to_roster(LServer, LUser, #roster{}, Fields)
                  end,
                  Roster)
    of
      Items -> {ok, Items}
    catch
      _:Error -> {error, {invalid_roster, Error}}
    end.

fields_to_roster(_LServer, _LUser, Item, []) -> Item;
fields_to_roster(LServer, LUser, Item,
                 [{<<"username">>, Username} | Rest]) ->
    case jid:make(Username, LServer, <<>>) of
        error ->
            ?ERROR_MSG("Invalid roster item for user ~s: username ~s", [LUser, Username]),
            fields_to_roster(LServer, LUser, Item, Rest);
        JID ->
            US = {LUser, LServer},
            USJ = {LUser, LServer, jid:tolower(JID)},
            USR = {JID#jid.user, JID#jid.server, JID#jid.resource},
            fields_to_roster(LServer, LUser,
                             Item#roster{usj = USJ, us = US, jid = USR}, Rest)
    end;
fields_to_roster(LServer, LUser, Item,
                 [{<<"jid">>, JidBin} | Rest]) ->
    case jid:from_string((JidBin)) of
        error ->
            ?ERROR_MSG("Invalid roster item for user ~s: jid ~s", [LUser, JidBin]),
            fields_to_roster(LServer, LUser, Item, Rest);
        JID ->
            US = {LUser, LServer},
            USJ = {LUser, LServer, jid:tolower(JID)},
            USR = {JID#jid.user, JID#jid.server, JID#jid.resource},
            fields_to_roster(LServer, LUser,
                             Item#roster{usj = USJ, us = US, jid = USR}, Rest)
    end;
fields_to_roster(LServer, LUser, Item,
                 [{<<"subscription">>, <<"both">>} | Rest]) ->
    fields_to_roster(LServer, LUser,
                     Item#roster{subscription = both}, Rest);
fields_to_roster(LServer, LUser, Item,
                 [{<<"subscription">>, <<"from">>} | Rest]) ->
    fields_to_roster(LServer, LUser,
                     Item#roster{subscription = from}, Rest);
fields_to_roster(LServer, LUser, Item,
                 [{<<"subscription">>, <<"to">>} | Rest]) ->
    fields_to_roster(LServer, LUser,
                     Item#roster{subscription = to}, Rest);
fields_to_roster(LServer, LUser, Item,
                 [{<<"subscription">>, <<"none">>} | Rest]) ->
    fields_to_roster(LServer, LUser,
                     Item#roster{subscription = none}, Rest);
fields_to_roster(LServer, LUser, Item,
                 [{<<"subscription">>, <<"remove">>} | Rest]) ->
    fields_to_roster(LServer, LUser,
                     Item#roster{subscription = remove}, Rest);
fields_to_roster(LServer, LUser, Item,
                 [{<<"subscription">>, Sub} | Rest]) ->
    ?ERROR_MSG("Invalid roster item for user ~s: subscription ~s", [LUser, Sub]),
    fields_to_roster(LServer, LUser, Item, Rest);
fields_to_roster(LServer, LUser, Item,
                 [{<<"nick">>, Nick} | Rest]) ->
    fields_to_roster(LServer, LUser,
                     Item#roster{name = (Nick)}, Rest);
fields_to_roster(LServer, LUser, Item,
                 [{Field, Value} | Rest]) ->
    ?ERROR_MSG("Invalid roster item for user ~s: unknown field ~s=~p", [LUser, Field, Value]),
    fields_to_roster(LServer, LUser, Item, Rest).
    %throw({unknown_field, {Field, Value}}).

rosteritem_to_json(
  #roster{us = {LUser, _LServer},
          jid = JID, name = Name, subscription = Subscription,
          ask = Ask, askmessage = AskMessage,
          groups = Groups}) ->
    SJID = jid:to_string(jid:tolower(JID)),
    SSubscription = jlib:atom_to_binary(Subscription),
    SAsk = jlib:atom_to_binary(Ask),
    {[{<<"username">>, LUser},
      {<<"jid">>, SJID},
      {<<"nick">>, Name},
      {<<"subscription">>, SSubscription},
      {<<"ask">>, SAsk},
      {<<"askmessage">>, AskMessage},
      {<<"groups">>, Groups}]}.
%%%----------------------------------------------------------------------
%%% HTTP helpers
%%%----------------------------------------------------------------------

path(Server) ->
    ejabberd_config:get_option({ext_api_path_roster, Server},
			       fun(X) -> iolist_to_binary(X) end,
			       <<"/roster">>).

path(Server, SubPath) ->
    Base = path(Server),
    Path = ejabberd_http:url_encode(SubPath),
    <<Base/binary, "/", Path/binary>>.

opt_type(ext_api_path_roster) ->
    fun (X) -> iolist_to_binary(X) end;
opt_type(_) -> [ext_api_path_roster].

build_error_msg(Code, []) ->
    integer_to_binary(Code);
build_error_msg(Code, Body) when is_binary(Body) ->
    CodeBin = integer_to_binary(Code),
    <<CodeBin/binary,":",Body/binary>>;
build_error_msg(Code, Body) when is_list(Body) ->
    CodeBin = integer_to_binary(Code),
    BodyBin = list_to_binary(Body),
    <<CodeBin/binary,":",BodyBin/binary>>.
