%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_privacy_p1db).

-behaviour(mod_privacy).

%% API
-export([init/2, process_lists_get/2, process_list_get/3,
	 process_default_set/3, process_active_set/3,
	 remove_privacy_list/3, set_privacy_list/1,
	 set_privacy_list/4, get_user_list/2, get_user_lists/2,
	 remove_user/2, import/1]).
-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2,
         p1db_to_items/1, items_to_p1db/1, us_prefix/2, usn2key/3, key2name/2,
	 default_key/2]).

-include("jlib.hrl").
-include("mod_privacy.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(privacy,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user, name]},
                               {vals, [list]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]).

process_lists_get(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, L} ->
            DefaultKey = default_key(LUser, LServer),
            lists:foldl(
              fun({Key, Val, _VClock}, {_Def, Els}) when Key == DefaultKey ->
                      {Val, Els};
                 ({Key, _Val, _VClock}, {Def, Els}) ->
                      Name = key2name(USPrefix, Key),
                      {Def, [#xmlel{name = <<"list">>,
                                    attrs = [{<<"name">>, Name}],
                                    children = []}|Els]}
              end, {none, []}, L);
        {error, notfound} ->
            {none, []};
        {error, _} ->
            error
    end.

process_list_get(LUser, LServer, Name) ->
    USNKey = usn2key(LUser, LServer, Name),
    case p1db:get(privacy, USNKey) of
        {ok, Val, _VClock} ->
            p1db_to_items(Val);
        {error, notfound} ->
            not_found;
        {error, _} ->
            error
    end.

process_default_set(LUser, LServer, {value, Name}) ->
    USNKey = usn2key(LUser, LServer, Name),
    case p1db:get(privacy, USNKey) of
        {ok, _Val, _VClock} ->
            DefaultKey = default_key(LUser, LServer),
            case p1db:insert(privacy, DefaultKey, Name) of
                ok -> {atomic, ok};
                {error, _} = Err -> {aborted, Err}
            end;
        {error, notfound} ->
            {atomic, not_found};
        {error, _} = Err ->
            {aborted, Err}
    end;
process_default_set(LUser, LServer, false) ->
    DefaultKey = default_key(LUser, LServer),
    case p1db:delete(privacy, DefaultKey) of
        ok -> {atomic, ok};
        {error, notfound} -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end.

process_active_set(LUser, LServer, Name) ->
    USNKey = usn2key(LUser, LServer, Name),
    case p1db:get(privacy, USNKey) of
        {ok, Val, _VClock} ->
            p1db_to_items(Val);
        {error, _} ->
            error
    end.

remove_privacy_list(LUser, LServer, Name) ->
    DefaultKey = default_key(LUser, LServer),
    Default = case p1db:get(privacy, DefaultKey) of
                  {ok, Val, _VClock} -> Val;
                  {error, notfound} -> <<"">>;
                  {error, _} = Err -> Err
              end,
    case Default of
        {error, _} = Err1 ->
            {aborted, Err1};
        Name ->
            {atomic, conflict};
        _ ->
            USNKey = usn2key(LUser, LServer, Name),
            case p1db:delete(privacy, USNKey) of
                ok -> {atomic, ok};
                {error, notfound} -> {atomic, ok};
                {error, _} = Err1 -> {aborted, Err1}
            end
    end.

set_privacy_list(#privacy{us = {LUser, LServer},
			  lists = Lists,
			  default = Default}) ->
    try
	if Default == none -> ok;
	   true ->
		DefaultKey = default_key(LUser, LServer),
		ok = p1db:insert(privacy, DefaultKey, Default)
	end,
	lists:foreach(
	  fun({Name, List}) ->
		  USNKey = usn2key(LUser, LServer, Name),
		  Val = items_to_p1db(List),
		  ok = p1db:insert(privacy, USNKey, Val)
	  end, Lists)
    catch _:{badmatch, {error, _} = Err} ->
	    Err
    end.

set_privacy_list(LUser, LServer, Name, List) ->
    USNKey = usn2key(LUser, LServer, Name),
    Val = items_to_p1db(List),
    case p1db:insert(privacy, USNKey, Val) of
        ok -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end.

get_user_list(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    DefaultKey = default_key(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, [{DefaultKey, Default, _VClock}|L]} ->
            USNKey = usn2key(LUser, LServer, Default),
            case lists:keyfind(USNKey, 1, L) of
                {_, Val, _} ->
                    {Default, p1db_to_items(Val)};
                false ->
                    {none, []}
            end;
        {ok, _} ->
            {none, []};
        {error, _} ->
            {none, []}
    end.

get_user_lists(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, L} ->
            DefaultKey = default_key(LUser, LServer),
            Privacy = #privacy{us = {LUser, LServer}},
            lists:foldl(
              fun({Key, Val, _VClock}, P) when Key == DefaultKey ->
                      P#privacy{default = Val};
                 ({Key, Val, _VClock}, #privacy{lists = Lists} = P) ->
                      Name = key2name(USPrefix, Key),
                      List = p1db_to_items(Val),
                      P#privacy{lists = [{Name, List}|Lists]}
              end, Privacy, L);
        {error, _} ->
            error
    end.

remove_user(LUser, LServer) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(privacy, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _, _}) ->
                      p1db:async_delete(privacy, Key)
              end, L),
            {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end.

import(P) ->
    {LUser, LServer} = P#privacy.us,
    Lists = P#privacy.lists,
    case P#privacy.default of
	none ->
	    ok;
	Default ->
	    DefaultKey = default_key(LUser, LServer),
	    p1db:async_insert(privacy, DefaultKey, Default)
    end,
    lists:foreach(
      fun({Name, List}) ->
	      USNKey = usn2key(LUser, LServer, Name),
	      Val = items_to_p1db(List),
	      p1db:async_insert(privacy, USNKey, Val)
      end, Lists).

%%%===================================================================
%%% Internal functions
%%%===================================================================
us_prefix(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary, 0>>.

usn2key(LUser, LServer, Name) ->
    <<LServer/binary, 0, LUser/binary, 0, Name/binary>>.

default_key(LUser, LServer) ->
    usn2key(LUser, LServer, <<0>>).

key2name(USPrefix, Key) ->
    Size = size(USPrefix),
    <<_:Size/binary, Name/binary>> = Key,
    Name.

%% P1DB/SQL schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, null]) ->
    <<Server/binary, 0, User/binary, 0, 0>>;
enc_key([Server, User, Name]) ->
    <<Server/binary, 0, User/binary, 0, Name/binary>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, Rest/binary>> = UKey,
    case Rest of
        <<0>> ->
            [Server, User, null];
        Name ->
            [Server, User, Name]
    end.

enc_val([_, _, null], [Bin]) ->
    Bin;
enc_val(_, [Expr]) ->
    Term = jlib:expr_to_term(Expr),
    term_to_binary(Term).

dec_val([_, _, null], Bin) ->
    [Bin];
dec_val(_, Bin) ->
    Term = binary_to_term(Bin),
    [jlib:term_to_expr(Term)].

p1db_to_items(Val) ->
    lists:map(fun proplist_to_item/1, binary_to_term(Val)).

items_to_p1db(Items) ->
    term_to_binary(lists:map(fun item_to_proplist/1, Items)).

proplist_to_item(PropList) ->
    lists:foldl(
      fun({type, V}, I) -> I#listitem{type = V};
         ({value, V}, I) -> I#listitem{value = V};
         ({action, V}, I) -> I#listitem{action = V};
         ({order, V}, I) -> I#listitem{order = V};
         ({match_all, V}, I) -> I#listitem{match_all = V};
         ({match_iq, V}, I) -> I#listitem{match_iq = V};
         ({match_message, V}, I) -> I#listitem{match_message = V};
         ({match_presence_in, V}, I) -> I#listitem{match_presence_in = V};
         ({match_presence_out, V}, I) -> I#listitem{match_presence_out = V};
         (_, I) -> I
      end, #listitem{}, PropList).

item_to_proplist(Item) ->
    Keys = record_info(fields, listitem),
    DefItem = #listitem{},
    {_, PropList} =
        lists:foldl(
          fun(Key, {Pos, L}) ->
                  Val = element(Pos, Item),
                  DefVal = element(Pos, DefItem),
                  if Val == DefVal ->
                          {Pos+1, L};
                     true ->
                          {Pos+1, [{Key, Val}|L]}
                  end
          end, {2, []}, Keys),
    PropList.
