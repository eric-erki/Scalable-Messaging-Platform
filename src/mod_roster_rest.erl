%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 19 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_roster_rest).

-behaviour(mod_roster).

%% API
-export([init/2, read_roster_version/2, write_roster_version/4,
	 get_roster/2, get_roster_by_jid/3, get_only_items/2,
	 roster_subscribe/4, get_roster_by_jid_with_groups/3,
	 remove_user/2, update_roster/4, del_roster/3, transaction/2,
	 read_subscription_and_groups/3, import/3, create_roster/1]).

-include("jlib.hrl").
-include("mod_roster.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    rest:start(Host),
    ok.

read_roster_version(_LUser, _LServer) ->
    error.

write_roster_version(_LUser, _LServer, _InTransaction, _Ver) ->
    error.

get_roster(LUser, LServer) ->
    Res = roster_rest:get_user_roster(LServer, LUser),
    case Res of
        {ok, Items} -> {ok, Items};
        Error -> Error
    end.

get_roster_by_jid(LUser, LServer, LJID) ->
    case roster_rest:get_jid_info(LServer, LUser, LJID) of
	{ok, Item} ->
	    Item;
	not_found ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer}, jid = LJID}
    end.

get_only_items(LUser, LServer) ->
    get_roster(LUser, LServer).

roster_subscribe(LUser, LServer, LJID, Item) ->
    case roster_rest:roster_subscribe(LUser, LServer, LJID, Item) of
        ok -> {atomic, ok};
        {error, Reason} -> {aborted, Reason}
    end.

transaction(_LServer, F) ->
    {atomic, F()}.

get_roster_by_jid_with_groups(LUser, LServer, LJID) ->
    get_roster_by_jid(LUser, LServer, LJID).

remove_user(LUser, LServer) ->
    case roster_rest:remove_user(LUser, LServer) of
        ok -> {atomic, ok};
        {error, Reason} ->  {aborted, Reason}
    end.

update_roster(LUser, LServer, LJID, Item) ->
    case roster_rest:update_roster(LUser, LServer, LJID, Item) of
        ok -> {atomic, ok};
        {error, Reason} ->  {aborted, Reason}
    end.

del_roster(LUser, LServer, LJID) ->
    case roster_rest:del_roster(LUser, LServer, LJID) of
        ok -> {atomic, ok};
        {error, Reason} ->  {aborted, Reason}
    end.

read_subscription_and_groups(LUser, LServer, LJID) ->
    case roster_rest:get_jid_info(LServer, LUser, LJID) of
	{ok, #roster{subscription = Subscription,
		     groups = Groups}} ->
	    {Subscription, Groups};
        _ ->
	    error
    end.

create_roster(Item) ->
    case roster_rest:create_roster(Item) of
        ok -> {atomic, ok};
        {error, Reason} -> {aborted, Reason}
    end.

import(_, _, _) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
