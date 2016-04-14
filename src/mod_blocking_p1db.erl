%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_blocking_p1db).

-behaviour(mod_blocking).

%% API
-export([process_blocklist_block/3, unblock_by_filter/3,
	 process_blocklist_get/2]).

-include("jlib.hrl").
-include("mod_privacy.hrl").

%%%===================================================================
%%% API
%%%===================================================================
process_blocklist_block(LUser, LServer, Filter) ->
    USPrefix = mod_privacy_p1db:us_prefix(LUser, LServer),
    DefaultKey = mod_privacy_p1db:default_key(LUser, LServer),
    Res = case p1db:get_by_prefix(privacy, USPrefix) of
              {ok, [{DefaultKey, DefaultName, _}|L]} ->
                  USNKey = mod_privacy_p1db:usn2key(LUser, LServer, DefaultName),
                  case lists:keyfind(USNKey, 1, L) of
                      {_, Val, _} ->
                          {DefaultName, mod_privacy_p1db:p1db_to_items(Val)};
                      false ->
                          {<<"Blocked contacts">>, []}
                  end;
              {ok, _} ->
                  {<<"Blocked contacts">>, []};
              {error, notfound} ->
                  {<<"Blocked contacts">>, []};
              {error, _} = E ->
                  E
          end,
    case Res of
        {error, _} = Err ->
            {aborted, Err};
        {Default, List} ->
            NewList = Filter(List),
            USNKey1 = mod_privacy_p1db:usn2key(LUser, LServer, Default),
            case p1db:insert(privacy, DefaultKey, Default) of
                ok ->
                    Val1 = mod_privacy_p1db:items_to_p1db(NewList),
                    case p1db:insert(privacy, USNKey1, Val1) of
                        ok -> {atomic, {ok, Default, NewList}};
                        Err -> {aborted, Err}
                    end;
                Err ->
                    {aborted, Err}
            end
    end.

unblock_by_filter(LUser, LServer, Filter) ->
    USPrefix = mod_privacy_p1db:us_prefix(LUser, LServer),
    DefaultKey = mod_privacy_p1db:default_key(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, [{DefaultKey, Default, _}|L]} ->
            USNKey = mod_privacy_p1db:usn2key(LUser, LServer, Default),
            case lists:keyfind(USNKey, 1, L) of
                {_, Val, _} ->
                    List = mod_privacy_p1db:p1db_to_items(Val),
                    NewList = Filter(List),
                    NewVal = mod_privacy_p1db:items_to_p1db(NewList),
                    case p1db:insert(privacy, USNKey, NewVal) of
                        ok ->
                            {atomic, {ok, Default, NewList}};
                        {error, _} = Err ->
                            {aborted, Err}
                    end;
                false ->
                    {atomic, ok}
            end;
        {ok, _} -> {atomic, ok};
        {error, notfound} -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end.

process_blocklist_get(LUser, LServer) ->
    USPrefix = mod_privacy_p1db:us_prefix(LUser, LServer),
    DefaultKey = mod_privacy_p1db:default_key(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, [{DefaultKey, Default, _VClock}|L]} ->
            USNKey = mod_privacy_p1db:usn2key(LUser, LServer, Default),
            case lists:keyfind(USNKey, 1, L) of
                {_, Val, _} ->
                    mod_privacy_p1db:p1db_to_items(Val);
                false ->
                    []
            end;
        {ok, _} ->
            [];
        {error, _} ->
            error
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
