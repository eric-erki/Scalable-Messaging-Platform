%%%-------------------------------------------------------------------
%%% File    : mod_filter_rest.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Mnesia backend for filter rules
%%% Created : 22 Jan 2018 by Christophe Romain <christophe.romain@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2017   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------

-module(mod_filter_rest).
-behaviour(mod_filter).

-author('christophe.romain@process-one.net').

-export([init/2, set_rule/4, del_rule/2, rules/1, filter/4]).
-export([opt_type/1]).

-include("jlib.hrl").
-include("mod_filter.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    rest:start(Host),
    ok.

set_rule(_Host, _Id, _Exp, _Type) ->
    % rest:post(Host, path(Host, Id), [], Content)
    {error, not_implemented}.

del_rule(_Host, _Id) ->
    % rest:delete(Host, path(Host, Id))
    {error, not_implemented}.

rules(_Host) ->
    % rest:get(Host, path(Host))
    {error, not_implemented}.

filter(Host, From, To, Packet) ->
    Content = encode_filter_request(From, To, Packet),
    case rest:post(Host, path(Host), [], Content) of
	{ok, 200, []} ->
	    pass;
	{ok, 200, Body} ->
	    case decode_filter_response(Body) of
		{ok, NewPacket} -> {filter, NewPacket};
		_ ->
		    ?ERROR_MSG("Invalid body response: ~p", [Body]),
		    pass
	    end;
	{ok, 403, Body} ->
	    {bounce, Body};
	{ok, 404, _Body} ->
	    drop;
	{ok, Code, Body} ->
	    ?ERROR_MSG("Invalid API response. Code: ~p - Body: ~p", [Code, Body]),
	    pass;
	Error ->
	    Error
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

encode_filter_request(From, To, Packet) ->
    jiffy:encode({[{<<"from">>, jid:to_string(From)},
		   {<<"to">>, jid:to_string(To)},
		   {<<"packet">>, fxml:element_to_binary(Packet)}]}).

decode_filter_response(JSon) ->
    case fxml_stream:parse_element(JSon) of
	{error, Reason} -> {error, Reason};
	El -> {ok, El}
    end.

path(Server) ->
    ejabberd_config:get_option({ext_api_path_filter, Server},
			       fun(X) -> iolist_to_binary(X) end,
			       <<"/filter">>).

path(Server, SubPath) ->
    Base = path(Server),
    Path = ejabberd_http:url_encode(SubPath),
    <<Base/binary, "/", Path/binary>>.

opt_type(ext_api_path_filter) ->
    fun (X) -> iolist_to_binary(X) end;
opt_type(_) -> [ext_api_path_filter].

