%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 18 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_carboncopy_sql).

-compile([{parse_transform, ejabberd_sql_pt}]).

-behaviour(mod_carboncopy).

%% API
-export([init/2, enable/4, disable/3, list/2]).

-include("mod_carboncopy.hrl").
-include("ejabberd_sql_pt.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    ok.

enable(LUser, LServer, LResource, NS) ->
    case ?SQL_UPSERT(
            LServer,
            "carboncopy",
            ["!server=%(LServer)s",
             "!username=%(LUser)s",
             "!resource=%(LResource)s",
             "version=%(NS)s"]) of
	ok ->
	    ok;
	Err ->
	    Err
    end.

disable(LUser, LServer, LResource) ->
    case ejabberd_sql:sql_query(
           LServer,
           ?SQL("DELETE FROM carboncopy WHERE"
                " server=%(LServer)s AND username=%(LUser)s"
                " AND resource=%(LResource)s")) of
        {updated, _} ->
            ok;
        {error, Err} ->
            {error, Err}
    end.

list(LUser, LServer) ->
    case ejabberd_sql:sql_query(
           LServer,
           ?SQL("SELECT @(resource)s, @(version)s FROM carboncopy"
                " WHERE server=%(LServer)s AND username=%(LUser)s")) of
        {selected, Values} ->
            Values;
        _ ->
            []
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
