-module(sm_remove_offline).
-export([remove_offline/0]).

-include("ejabberd_sm.hrl").

remove_offline() ->
    traverse(ets:first(session)).

traverse('$end_of_table') ->
    ok;
traverse(Key) ->
    NextKey = ets:next(session, Key),
    case ets:lookup(session, Key) of
        [S] ->
            case proplists:get_bool(offline, S#session.info) of
                true ->
                    mnesia:dirty_delete(session, Key);
                false ->
                    ok
            end;
        _ ->
            ok
    end,
    traverse(NextKey).
