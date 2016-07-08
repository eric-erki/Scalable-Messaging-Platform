%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  8 Jul 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_jabs_p1db).

-behaviour(mod_jabs).

-include("mod_jabs.hrl").

%% API
-export([init/2, read/1, write/1, match/1, clean/1]).
-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2]).

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end, 
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    [Key|Values] = record_info(fields, jabs),
    p1db:open_table(jabs,
		    [{group, Group}, {nosync, true},
		     {schema, [{keys, [Key]},
			       {vals, Values},
			       {enc_key, fun ?MODULE:enc_key/1},
			       {dec_key, fun ?MODULE:dec_key/1},
			       {enc_val, fun ?MODULE:enc_val/2},
			       {dec_val, fun ?MODULE:dec_val/2}]}]).

read(Host) ->
    Key = enc_key({Host, node()}),
    case p1db:get(jabs, Key) of
        {ok, Val, _VClock} -> {ok, (p1db_to_jabs(Key, Val))#jabs{host = Host}};
	Err -> Err
    end.

write(Jabs) ->
    Key = enc_key({Jabs#jabs.host, node()}),
    p1db:insert(jabs, Key, jabs_to_p1db(Jabs)).

match(Host) ->
    case p1db:get_by_prefix(jabs, enc_key(Host)) of
        {ok, L} ->
            lists:map(fun(Jabs) ->
			      {Host, Node} = Jabs#jabs.host,
			      {Node, Jabs#jabs{host = Host}}
		      end, [p1db_to_jabs(Key, Val) || {Key, Val, _} <- L]);
        _ ->
            []
    end.

clean(Host) ->
    case p1db:get_by_prefix(jabs, enc_key(Host)) of
        {ok, L} -> [p1db:delete(jabs, Key) || {Key, _, _} <- L], ok;
        _ -> ok
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
jabs_to_p1db(Jabs) when is_record(Jabs, jabs) ->
    term_to_binary([
            {counter, Jabs#jabs.counter},
            {stamp, Jabs#jabs.stamp},
            {timer, Jabs#jabs.timer},
            {ignore, Jabs#jabs.ignore}]).
p1db_to_jabs(Key, Val) when is_binary(Key) ->
    p1db_to_jabs(dec_key(Key), Val);
p1db_to_jabs({Host, Node}, Val) ->
    lists:foldl(
        fun ({counter, C}, J) -> J#jabs{counter=C};
            ({stamp, S}, J) -> J#jabs{stamp=S};
            ({timer, T}, J) -> J#jabs{timer=T};
            ({ignore, I}, J) -> J#jabs{ignore=I};
            (_, J) -> J
        end, #jabs{host={Host, Node}}, binary_to_term(Val)).

enc_key({Host, Node}) ->
    N = jlib:atom_to_binary(Node),
    <<Host/binary, 0, N/binary>>;
enc_key(Host) ->
    <<Host/binary, 0>>.
dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Host:SLen/binary, 0, N/binary>> = Key,
    {Host, jlib:binary_to_atom(N)}.

enc_val(_, [Counter, Stamp, Timer, Ignore]) ->
    jabs_to_p1db(#jabs{
            counter=Counter,
            stamp=Stamp,
            timer=Timer,
            ignore=Ignore}).
dec_val(Key, Bin) ->
    J = p1db_to_jabs(Key, Bin),
    [J#jabs.counter,
     J#jabs.stamp,
     J#jabs.timer,
     J#jabs.ignore].
