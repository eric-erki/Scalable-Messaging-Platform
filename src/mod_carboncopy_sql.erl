%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_carboncopy_sql).

-behaviour(mod_carboncopy).

%% API
-export([init/2, enable/4, disable/3, list/2]).

-include("mod_carboncopy.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ok.

enable(LUser, LServer, LResource, NS) ->
    S = ejabberd_sql:escape(LServer),
    U = ejabberd_sql:escape(LUser),
    R = ejabberd_sql:escape(LResource),
    case sql_queries:update(
	   LServer, <<"carboncopy">>,
	   [<<"server">>, <<"username">>, <<"resource">>, <<"version">>],
	   [S, U, R, ejabberd_sql:escape(NS)],
	   [<<"server='">>, S, <<"' and username='">>, U,
	    <<"' and resource='">>, R, <<"'">>]) of
	ok ->
	    ok;
	Err ->
	    Err
    end.

disable(LUser, LServer, LResource) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   [<<"DELETE FROM carboncopy WHERE Server='">>,
	    ejabberd_sql:escape(LServer), <<"' AND Username='">>,
	    ejabberd_sql:escape(LUser),
	    <<"' AND Resource='">>, ejabberd_sql:escape(LResource), <<"'">>]) of
        {updated, _} ->
            ok;
        {error, Err} ->
            {error, Err}
    end.

list(LUser, LServer) ->
    case ejabberd_sql:sql_query(
	   LServer,
	   [<<"SELECT Resource, Version FROM carboncopy WHERE Server='">>,
	    ejabberd_sql:escape(LServer), <<"' AND Username='">>,
	    ejabberd_sql:escape(LUser), <<"'">>]) of
        {selected, _, Values} ->
            [{R, V} || [R, V] <- Values];
        _ ->
            []
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
