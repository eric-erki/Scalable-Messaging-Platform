%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_shared_roster_p1db).

-behaviour(mod_shared_roster).

%% API
-export([init/2, list_groups/1, groups_with_opts/1, create_group/3,
	 delete_group/2, get_group_opts/2, set_group_opts/3,
	 get_user_groups/2, get_group_explicit_users/2,
	 get_user_displayed_groups/3, is_user_in_group/3,
	 add_user_to_group/3, remove_user_from_group/3, import/3]).
-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2]).

-include("jlib.hrl").
-include("mod_roster.hrl").
-include("mod_shared_roster.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    OptsFields = [Field || {Field, _} <- default_group_opts()],
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(sr_group,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [host, group, server, user]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]),
    p1db:open_table(sr_opts,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [host, group]},
                               {vals, OptsFields},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]),
    p1db:open_table(sr_user,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [host, server, user, group]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]).

list_groups(Host) ->
    HPrefix = host_prefix(Host),
    case p1db:get_by_prefix(sr_opts, HPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, _Val, _VClock}) ->
                      get_suffix(HPrefix, Key)
              end, L);
        {error, _} ->
            []
    end.

groups_with_opts(Host) ->
    HPrefix = host_prefix(Host),
    case p1db:get_by_prefix(sr_opts, HPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, Val, _VClock}) ->
                      Group = get_suffix(HPrefix, Key),
                      Opts = binary_to_term(Val),
                      {Group, Opts}
              end, L);
        {error, _} ->
            []
    end.

create_group(Host, Group, Opts) ->
    GHKey = gh2key(Group, Host),
    Val = term_to_binary(Opts),
    case p1db:insert(sr_opts, GHKey, Val) of
        ok -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end.

delete_group(Host, Group) ->
    GHKey = gh2key(Group, Host),
    GHPrefix = gh_prefix(Group, Host),
    DelRes = p1db:delete(sr_opts, GHKey),
    if DelRes == ok; DelRes == {error, notfound} ->
            try
                {ok, L1} = p1db:get_by_prefix(sr_group, GHPrefix),
                lists:foreach(
                  fun({Key, _, _}) ->
                          ok = p1db:async_delete(sr_group, Key)
                  end, L1),
                {ok, L2} = p1db:get(sr_user),
                lists:foreach(
                  fun({Key, _, _}) ->
                          case get_group_from_ushg(Key) of
                              Group ->
                                  ok = p1db:async_delete(sr_user, Key);
                              _ ->
                                  ok
                          end
                  end, L2),
                {atomic, ok}
            catch error:{badmatch, {error, _} = Err} ->
                    {aborted, Err}
            end;
       true ->
            {aborted, DelRes}
    end.

get_group_opts(Host, Group) ->
    GHKey = gh2key(Group, Host),
    case p1db:get(sr_opts, GHKey) of
        {ok, Val, _VClock} ->
            binary_to_term(Val);
        {error, _} ->
            error
    end.

set_group_opts(Host, Group, Opts) ->
    GHKey = gh2key(Group, Host),
    Val = term_to_binary(Opts),
    case p1db:insert(sr_opts, GHKey, Val) of
        ok -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end.

get_user_groups(US, Host) ->
    USHPrefix = ush_prefix(US, Host),
    case p1db:get_by_prefix(sr_user, USHPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, _, _}) ->
                      get_suffix(USHPrefix, Key)
              end, L);
        {error, _} ->
            []
    end.

get_group_explicit_users(Host, Group) ->
    GHPrefix = gh_prefix(Group, Host),
    case p1db:get_by_prefix(sr_group, GHPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, _, _}) ->
                      decode_us(get_suffix(GHPrefix, Key))
              end, L);
        {error, _} ->
            []
    end.

get_user_displayed_groups(LUser, LServer, GroupsOpts) ->
    USHPrefix = ush_prefix({LUser, LServer}, LServer),
    case p1db:get_by_prefix(sr_user, USHPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, _, _}) ->
                      Group = get_suffix(USHPrefix, Key),
                      {Group, proplists:get_value(Group, GroupsOpts, [])}
              end, L);
        {error, _} ->
            []
    end.

is_user_in_group(US, Group, Host) ->
    USHGKey = ushg2key(US, Host, Group),
    case p1db:get(sr_user, USHGKey) of
        {ok, _, _} ->
            true;
        {error, _} ->
            false
    end.

add_user_to_group(Host, US, Group) ->
    GHUSKey = ghus2key(Group, Host, US),
    USHGKey = ushg2key(US, Host, Group),
    try
        ok = p1db:insert(sr_user, USHGKey, <<>>),
        ok = p1db:insert(sr_group, GHUSKey, <<>>),
        {atomic, ok}
    catch error:{badmatch, {error, _} = Err} ->
            {aborted, Err}
    end.

remove_user_from_group(Host, US, Group) ->
    GHUSKey = ghus2key(Group, Host, US),
    USHGKey = ushg2key(US, Host, Group),
    DelRes = p1db:delete(sr_user, USHGKey),
    if DelRes == ok; DelRes == {error, notfound} ->
            case p1db:delete(sr_group, GHUSKey) of
                ok -> {atomic, ok};
                {error, notfound} -> {atomic, ok};
                {error, _} = Err -> {aborted, Err}
            end;
       true ->
            {aborted, DelRes}
    end.

import(LServer, <<"sr_group">>,
       [Group, SOpts, _TimeStamp]) ->
    Opts = ejabberd_odbc:decode_term(SOpts),
    GHKey = gh2key(Group, LServer),
    Val = term_to_binary(Opts),
    p1db:async_insert(sr_opts, GHKey, Val);
import(LServer, <<"sr_user">>,
       [SJID, Group, _TimeStamp]) ->
    #jid{luser = U, lserver = S} = jid:from_string(SJID),
    US = {U, S},
    GHUSKey = ghus2key(Group, LServer, US),
    USHGKey = ushg2key(US, LServer, Group),
    p1db:async_insert(sr_group, GHUSKey, <<>>),
    p1db:async_insert(sr_user, USHGKey, <<>>).

%%%===================================================================
%%% Internal functions
%%%===================================================================
host_prefix(Host) ->
    <<Host/binary, 0>>.

get_suffix(Prefix, Key) ->
    Size = size(Prefix),
    <<_:Size/binary, Suffix/binary>> = Key,
    Suffix.

gh2key(Group, Host) ->
    <<Host/binary, 0, Group/binary>>.

ghus2key(Group, Host, {User, Server}) ->
    <<Host/binary, 0, Group/binary, 0, Server/binary, 0, User/binary>>.

ushg2key({User, Server}, Host, Group) ->
    <<Host/binary, 0, Server/binary, 0, User/binary, 0, Group/binary>>.

gh_prefix(Group, Host) ->
    <<Host/binary, 0, Group/binary, 0>>.

ush_prefix({User, Server}, Host) ->
    <<Host/binary, 0, Server/binary, 0, User/binary, 0>>.

get_group_from_ushg(Key) ->
    [Group|_] = lists:reverse(binary:split(Key, <<0>>, [global])),
    Group.

decode_us(Bin) ->
    [Server, User] = binary:split(Bin, <<0>>, [global]),
    {User, Server}.

enc_key(L) ->
    str:join(L, 0).

dec_key(Key) ->
    binary:split(Key, <<0>>, [global]).

default_group_opts() ->
    [{name, <<"">>},
     {description, <<"">>},
     {displayed_groups, []},
     {all_users, false},
     {online_users, false},
     {disabled, false}].

enc_val(_, Vals) ->
    Opts = lists:map(
             fun({{Key, _}, BinVal}) ->
                     Val = if Key == name; Key == description ->
                                   BinVal;
                              Key == all_users; Key == online_users;
                              Key == disabled ->
                                   jlib:binary_to_atom(BinVal);
                              true ->
                                   jlib:expr_to_term(BinVal)
                           end,
                     {Key, Val}
             end, lists:zip(default_group_opts(), Vals)),
    term_to_binary(Opts).

dec_val(_, Bin) ->
    Opts = binary_to_term(Bin),
    lists:map(
      fun({Key, DefVal}) ->
              Val = case lists:keyfind(Key, 1, Opts) of
                        {_, V} -> V;
                        false -> DefVal
                    end,
              if is_binary(Val) -> Val;
                 is_atom(Val) -> jlib:atom_to_binary(Val);
                 true -> jlib:term_to_expr(Val)
              end
      end, default_group_opts()).
