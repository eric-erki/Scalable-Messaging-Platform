%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_carboncopy_p1db).

-behaviour(mod_carboncopy).

%% API
-export([init/2, enable/4, disable/3, list/2]).
-export([enc_key/1, dec_key/1]).

-include("mod_carboncopy.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
              Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
              ejabberd_config:get_option(
                {p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(carboncopy,
                    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user, resource]},
                               {vals, [version]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]).

enable(LUser, LServer, LResource, NS) ->
    p1db:insert(carboncopy, enc_key(LServer, LUser, LResource), NS).

disable(LUser, LServer, LResource) ->
    p1db:delete(carboncopy, enc_key(LServer, LUser, LResource)).

list(LUser, LServer) ->
    case p1db:get_by_prefix(carboncopy, enc_key(LServer, LUser)) of
        {ok, L} ->
            [{dec_key(Key2, 3), Version} || {Key2, Version, _VClock} <- L];
        {error, _} ->
            []
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
enc_key(Server, User, Resource) ->
    <<Server/binary, 0, User/binary, 0, Resource/binary>>.
enc_key(Server, User) ->
    <<Server/binary, 0, User/binary, 0>>.

enc_key(Server) ->
    <<Server/binary, 0>>.

dec_key(Key) ->
    binary:split(Key, <<0>>, [global]).
dec_key(Key, Part) ->
    lists:nth(Part, dec_key(Key)).
