%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  8 Jul 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_jabs_mnesia).

-behaviour(mod_jabs).

-include("mod_jabs.hrl").

%% API
-export([init/2, read/1, write/1, match/1, clean/1]).

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    mnesia:create_table(jabs, [{disc_copies, [node()]},
                               {local_content, true},
                               {attributes, record_info(fields, jabs)}]).

read(Host) ->
    case catch mnesia:dirty_read(jabs, {Host, node()}) of
        [#jabs{}=Jabs] -> {ok, Jabs#jabs{host = Host}};
        _ -> {error, notfound}
    end.

write(Jabs) ->
    Key = {Jabs#jabs.host, node()},
    ejabberd_cluster:multicall(mnesia, dirty_write, [Jabs#jabs{host=Key}]).

match(Host) ->
    Record = #jabs{host = {Host, '_'}, _ = '_'},
    lists:map(fun(Jabs) ->
		      {Host, Node} = Jabs#jabs.host,
		      {Node, Jabs#jabs{host = Host}}
	      end, mnesia:dirty_match_object(Record)).

clean(Host) ->
    Record = #jabs{host = {Host, '_'}, _ = '_'},
    [ejabberd_cluster:multicall(mnesia, dirty_delete, [jabs, Key])
     || Key <- [Jabs#jabs.host || Jabs <- mnesia:dirty_match_object(Record)]],
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
