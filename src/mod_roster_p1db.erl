%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 19 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_roster_p1db).

-behaviour(mod_roster).

%% API
-export([init/2, read_roster_version/2, write_roster_version/4,
	 get_roster/2, get_roster_by_jid/3, get_only_items/2,
	 roster_subscribe/4, get_roster_by_jid_with_groups/3,
	 remove_user/2, update_roster/4, del_roster/3, transaction/2,
	 read_subscription_and_groups/3, import/3, create_roster/1]).
-export([enc_key/1, enc_val/2, dec_val/2, dec_roster_key/1,
	 dec_roster_version_key/1]).

-include("jlib.hrl").
-include("mod_roster.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(roster,
		    [{group, Group}, {nosync, true},
		     {nosync, true},
                     {schema, [{keys, [server, user, jid]},
                               {vals, [name, subscription,
                                       ask, groups, askmessage,
                                       xs]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_roster_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]),
    p1db:open_table(roster_version,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user]},
                               {vals, [version]},
                               {dec_key, fun ?MODULE:dec_roster_version_key/1},
                               {enc_key, fun ?MODULE:enc_key/1}]}]).

read_roster_version(LUser, LServer) ->
    US = us2key(LUser, LServer),
    case p1db:get(roster_version, US) of
        {ok, Version, _VClock} -> Version;
        {error, _} -> error
    end.

write_roster_version(LUser, LServer, _InTransaction, Ver) ->
    US = us2key(LUser, LServer),
    p1db:insert(roster_version, US, Ver).

get_roster(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(roster, USPrefix) of
        {ok, L} ->
            {ok, lists:map(
		   fun({Key, Val, _VClock}) ->
			   LJID = key2jid(USPrefix, Key),
			   USJ = {LUser, LServer, LJID},
			   p1db_to_item(USJ, Val)
		   end, L)};
        {error, _} ->
	    error
    end.

get_roster_by_jid(LUser, LServer, LJID) ->
    USJKey = usj2key(LUser, LServer, LJID),
    case p1db:get(roster, USJKey) of
        {ok, Val, _VClock} ->
            I = p1db_to_item({LUser, LServer, LJID}, Val),
            I#roster{jid = LJID, name = <<"">>, groups = [], xs = []};
        {error, notfound} ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer}, jid = LJID};
        {error, _} = Err ->
            exit(Err)
    end.

get_only_items(LUser, LServer) ->
    get_roster(LUser, LServer).

roster_subscribe(LUser, LServer, LJID, Item) ->
    USJKey = usj2key(LUser, LServer, LJID),
    Val = item_to_p1db(Item),
    p1db:insert(roster, USJKey, Val).

transaction(_LServer, F) ->
    {atomic, F()}.

get_roster_by_jid_with_groups(LUser, LServer, LJID) ->
    USJKey = usj2key(LUser, LServer, LJID),
    case p1db:get(roster, USJKey) of
        {ok, Val, _VClock} ->
            p1db_to_item({LUser, LServer, LJID}, Val);
        {error, notfound} ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer}, jid = LJID};
        {error, _} = Err ->
            exit(Err)
    end.

remove_user(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(roster, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _Val, VClock}) ->
                      p1db:delete(roster, Key,
                                  p1db:incr_vclock(VClock))
              end, L),
            {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end.

update_roster(LUser, LServer, LJID, Item) ->
    USJKey = usj2key(LUser, LServer, LJID),
    p1db:insert(roster, USJKey, item_to_p1db(Item)).

del_roster(LUser, LServer, LJID) ->
    USJKey = usj2key(LUser, LServer, LJID),
    p1db:delete(roster, USJKey).

read_subscription_and_groups(LUser, LServer, LJID) ->
    USJKey = usj2key(LUser, LServer, LJID),
    case p1db:get(roster, USJKey) of
        {ok, Val, _VClock} ->
            #roster{subscription = Subscription,
                    groups = Groups}
                = p1db_to_item({LUser, LServer, LJID}, Val),
            {Subscription, Groups};
        {error, _} ->
            error
    end.

create_roster(#roster{usj = {LUser, LServer, LJID}} = RItem) ->
    USJKey = usj2key(LUser, LServer, LJID),
    Val = item_to_p1db(RItem),
    VClock = p1db:new_vclock(node()),
    p1db:async_insert(roster, USJKey, Val, VClock).

import(_LServer, <<"rosterusers">>, RosterItem) ->
    {LUser, LServer, LJID} = RosterItem#roster.usj,
    USJKey = usj2key(LUser, LServer, LJID),
    Val = item_to_p1db(RosterItem),
    p1db:async_insert(roster, USJKey, Val);
import(LServer, <<"roster_version">>, [LUser, Ver]) ->
    USKey = us2key(LUser, LServer),
    p1db:async_insert(roster_version, USKey, Ver).

%%%===================================================================
%%% Internal functions
%%%===================================================================
us2key(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary>>.

usj2key(User, Server, JID) ->
    USKey = us2key(User, Server),
    SJID = jid:to_string(JID),
    <<USKey/binary, 0, SJID/binary>>.

key2jid(USPrefix, Key) ->
    Size = size(USPrefix),
    <<_:Size/binary, SJID/binary>> = Key,
    jid:tolower(jid:from_string(SJID)).

us_prefix(User, Server) ->
    USKey = us2key(User, Server),
    <<USKey/binary, 0>>.

item_to_p1db(Roster) ->
    Keys = record_info(fields, roster),
    DefRoster = #roster{us = Roster#roster.us,
                        usj = Roster#roster.usj,
                        jid = Roster#roster.jid},
    {_, PropList} =
        lists:foldl(
          fun(Key, {Pos, L}) ->
                  Val = element(Pos, Roster),
                  DefVal = element(Pos, DefRoster),
                  if Val == DefVal ->
                          {Pos+1, L};
                     true ->
                          {Pos+1, [{Key, Val}|L]}
                  end
          end, {2, []}, Keys),
    term_to_binary(PropList).

p1db_to_item({LUser, LServer, LJID}, Val) ->
    Item = #roster{usj = {LUser, LServer, LJID},
                   us = {LUser, LServer},
                   jid = LJID},
    lists:foldl(
      fun({name, Name}, I) -> I#roster{name = Name};
         ({subscription, S}, I) -> I#roster{subscription = S};
         ({ask, Ask}, I) -> I#roster{ask = Ask};
         ({groups, Groups}, I) -> I#roster{groups = Groups};
         ({askmessage, AskMsg}, I) -> I#roster{askmessage = AskMsg};
         ({xs, Xs}, I) -> I#roster{xs = Xs};
         (_, I) -> I
      end, Item, binary_to_term(Val)).

%% P1DB/SQL schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, JID]) ->
    <<Server/binary, 0, User/binary, 0, JID/binary>>.

dec_roster_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, JID/binary>> = UKey,
    [Server, User, JID].

dec_roster_version_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, User/binary>> = Key,
    [Server, User].

enc_val(_, [Name, SSubscription, SAsk, SGroups, AskMsg, SXs]) ->
    Item = #roster{name = Name,
                   subscription = jlib:binary_to_atom(SSubscription),
                   ask = jlib:binary_to_atom(SAsk),
                   groups = jlib:expr_to_term(SGroups),
                   askmessage = AskMsg,
                   xs = jlib:expr_to_term(SXs)},
    item_to_p1db(Item).

dec_val([Server, User, SJID], Bin) ->
    LJID = jid:tolower(jid:from_string(SJID)),
    #roster{name = Name,
            subscription = Subscription,
            ask = Ask,
            groups = Groups,
            askmessage = AskMsg,
            xs = Xs} = p1db_to_item({User, Server, LJID}, Bin),
    [Name,
     jlib:atom_to_binary(Subscription),
     jlib:atom_to_binary(Ask),
     jlib:term_to_expr(Groups),
     AskMsg,
     jlib:term_to_expr(Xs)].
