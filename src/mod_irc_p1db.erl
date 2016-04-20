%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_irc_p1db).

-behaviour(mod_irc).

%% API
-export([init/2, get_data/3, set_data/4, import/3]).
-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2]).

-include("jlib.hrl").
-include("mod_irc.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(irc_custom,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, server, user]},
                               {vals, [data]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]).

get_data(LServer, Host, From) ->
    #jid{luser = LUser, lserver = LServer} = From,
    USHKey = ush2key(LUser, LServer, Host),
    case p1db:get(irc_custom, USHKey) of
        {ok, Val, _VClock} ->
            binary_to_term(Val);
        {error, notfound} ->
            empty;
        _Err ->
            error
    end.

set_data(LServer, Host, From, Data) ->
    {LUser, LServer, _} = jid:tolower(From),
    USHKey = ush2key(LUser, LServer, Host),
    case p1db:insert(irc_custom, USHKey, term_to_binary(Data)) of
        ok -> {atomic, ok};
        {error, _} = Err -> {aborted, Err}
    end.

import(_LServer, <<"irc_custom">>, [SJID, IRCHost, SData, _TimeStamp]) ->
    #jid{luser = U, lserver = S} = jid:from_string(SJID),
    Data = ejabberd_sql:decode_term(SData),
    USHKey = ush2key(U, S, IRCHost),
    p1db:async_insert(irc_custom, USHKey, term_to_binary(Data)).

%%%===================================================================
%%% Internal functions
%%%===================================================================
ush2key(LUser, LServer, Host) ->
    <<Host/binary, 0, LServer/binary, 0, LUser/binary>>.

%% P1DB/SQL schema
enc_key([Host]) ->
    <<Host/binary>>;
enc_key([Host, Server]) ->
    <<Host/binary, 0, Server/binary>>;
enc_key([Host, Server, User]) ->
    <<Host/binary, 0, Server/binary, 0, User/binary>>.

dec_key(Key) ->
    HLen = str:chr(Key, 0) - 1,
    <<Host:HLen/binary, 0, SKey/binary>> = Key,
    SLen = str:chr(SKey, 0) - 1,
    <<Server:SLen/binary, 0, User/binary>> = SKey,
    [Host, Server, User].

enc_val(_, [Expr]) ->
    Term = jlib:expr_to_term(Expr),
    term_to_binary(Term).

dec_val(_, Bin) ->
    Term = binary_to_term(Bin),
    [jlib:term_to_expr(Term)].
