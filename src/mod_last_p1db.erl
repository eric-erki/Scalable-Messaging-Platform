%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 16 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_last_p1db).

-behaviour(mod_last).

%% API
-export([init/2, import/2, get_last/2, store_last_info/4, remove_user/2]).
-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2]).

-include("mod_last.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, mod_last, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(last_activity,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [server, user]},
                               {vals, [timestamp, status]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]).

get_last(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    case p1db:get(last_activity, USKey) of
        {ok, Val, _VClock} ->
            #last_activity{timestamp = TimeStamp,
                           status = Status}
                = p1db_to_la({LUser, LServer}, Val),
            {ok, TimeStamp, Status};
        {error, notfound} ->
            not_found;
        {error, _} = Err ->
            Err
    end.

store_last_info(LUser, LServer, TimeStamp, Status) ->
    USKey = us2key(LUser, LServer),
    Val = la_to_p1db(#last_activity{timestamp = TimeStamp,
                                    status = Status}),
    {atomic, p1db:insert(last_activity, USKey, Val)}.

remove_user(LUser, LServer) ->
    USKey = us2key(LUser, LServer),
    {atomic, p1db:delete(last_activity, USKey)}.

import(_LServer, #last_activity{us = {LUser, LServer}} = LA) ->
    USKey = us2key(LUser, LServer),
    p1db:async_insert(last_activity, USKey, la_to_p1db(LA)).

%%%===================================================================
%%% Internal functions
%%%===================================================================
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, User/binary>> = Key,
    [Server, User].

enc_val(_, [TimeStamp, Status]) ->
    la_to_p1db(#last_activity{timestamp = TimeStamp,
                              status = Status}).

dec_val([Server, User], Bin) ->
    #last_activity{timestamp = TimeStamp,
                   status = Status} = p1db_to_la({User, Server}, Bin),
    [TimeStamp, Status].

us2key(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary>>.

la_to_p1db(#last_activity{timestamp = TimeStamp, status = Status}) ->
    term_to_binary(
      [{timestamp, TimeStamp},
       {status, Status}]).

p1db_to_la({LUser, LServer}, Val) ->
    LA = #last_activity{us = {LUser, LServer}},
    lists:foldl(
      fun({timestamp, TimeStamp}, R) ->
              R#last_activity{timestamp = TimeStamp};
         ({status, Status}, R) ->
              R#last_activity{status = Status};
         (_, R) ->
              R
      end, LA, binary_to_term(Val)).
