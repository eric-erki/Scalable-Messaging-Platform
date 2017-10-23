-module(migrate_pubsub_p1db).

-author('jerome.sautret@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").
-include("logger.hrl").

-export([do_migrate/0]).


% node_flat_p1db cannot be reloaded before migration
-export([enc_state2_key/1, dec_state2_key/1, enc_state2_val/2, dec_state2_val/2]).


do_migrate() ->
    Group = undefined, % According to nuage config file

    [SKey|SValues] = record_info(fields, pubsub_state),
    p1db:open_table(pubsub_state,
		    [{group, Group}, {nosync, true},
		     {schema, [{keys, [SKey]},
			       {vals, SValues},
			       {enc_key, fun node_flat_p1db:enc_state_key/1},
			       {dec_key, fun node_flat_p1db:dec_state_key/1},
			       {enc_val, fun node_flat_p1db:enc_state_val/2},
			       {dec_val, fun node_flat_p1db:dec_state_val/2}]}]),
    p1db:clear(pubsub_state2),
    [SKey2|SValues2] = record_info(fields, pubsub_state2),
    p1db:open_table(pubsub_state2,
		    [{group, Group}, {nosync, true},
		     {schema, [{keys, [SKey2]},
			       {vals, SValues2},
			       {enc_key, fun ?MODULE:enc_state2_key/1},
			       {dec_key, fun ?MODULE:dec_state2_key/1},
			       {enc_val, fun ?MODULE:enc_state2_val/2},
			       {dec_val, fun ?MODULE:dec_state2_val/2}]}]),

    migrate(p1db:first(pubsub_state)).

migrate({ok, Key, _Val, _}) ->
    {USR, Nidx} = node_flat_p1db:dec_state_key(Key),
    Key2 = enc_state2_key({Nidx, USR}),
    Val2 = enc_state2_val(Nidx, USR),
    p1db:insert(pubsub_state2, Key2, Val2),
    migrate(p1db:next(pubsub_state, Key));
migrate({error, notfound}) ->
    ok;
migrate({error, E}) ->
    io:format("Error: ~p~n", [E]).



enc_state2_key({Nidx, USR}) ->
    <<Nidx/binary, 0, (jid:to_string(USR))/binary>>.
dec_state2_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Nidx:SLen/binary, 0, USR/binary>> = Key,
    {Nidx, jid:string_to_usr(USR)}.
enc_state2_val(_, {U, S, R}) ->
    jid:to_string({U, S, R}).
dec_state2_val(_, Bin) ->
    jid:string_to_usr(Bin).
