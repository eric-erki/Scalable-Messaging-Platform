%%%----------------------------------------------------------------------
%%% File    : mod_vcard_rest.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : REST mode for Vcard management
%%% Created : 17 Nov 2017 by Christophe Romain <christophe.romain@process-one.net>
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
%%%----------------------------------------------------------------------

-module(mod_vcard_rest).

-behaviour(mod_vcard).

%% API
-export([init/2, get_vcard/2, set_vcard/4, search/4, remove_user/2,
	 import/3, is_search_supported/1]).

-include("jlib.hrl").
-include("mod_vcard.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    rest:start(Host).

is_search_supported(_LServer) ->
    false.

get_vcard(LUser, LServer) ->
    Path = vcard_rest_path(LUser, LServer),
    case rest:with_retry(get, [LServer, Path], 2, 500) of
	{ok, 200, Body}  ->
	    case fxml_stream:parse_element(Body) of
		{error, _Reason} = Err ->
		    ?ERROR_MSG("got ~p when parsing vCard ~s", [Err, Body]),
		    error;
		VCard ->
		    [VCard]
	    end;
	Other ->
	    ?ERROR_MSG("Unexpected response for vCard get: ~p", [Other]),
	    error
    end.

set_vcard(LUser, LServer, VCARD, _VCardSearch) ->
    Path = vcard_rest_path(LUser, LServer),
    Body = fxml:element_to_binary(VCARD),
    case rest:with_retry(post, [LServer, Path, [], Body], 2, 500) of
	{ok, 200, _} ->
	    {atomic, ok};
	Other ->
	    ?ERROR_MSG("Unexpected response for vCard set: ~p", [Other]),
	    {error, rest_failed}
    end.

search(_LServer, _Data, _AllowReturnAll, _MaxMatch) ->
%	   case catch ejabberd_sql:sql_query(
%			LServer,
%			[<<"select username, fn, family, given, "
%			   "middle,        nickname, bday, ctry, "
%			   "locality,        email, orgname, orgunit "
%			   "from vcard_search ">>,
%			 MatchSpec, Limit, <<";">>]) of
%	       {selected,
%		[<<"username">>, <<"fn">>, <<"family">>, <<"given">>,
%		 <<"middle">>, <<"nickname">>, <<"bday">>, <<"ctry">>,
%		 <<"locality">>, <<"email">>, <<"orgname">>,
%		 <<"orgunit">>], Rs} when is_list(Rs) ->
%		   Rs;
%	       Error ->
%		   ?ERROR_MSG("~p", [Error]), []
%	   end
    [].

remove_user(LUser, LServer) ->
    Path = vcard_rest_path(LUser, LServer),
    case rest:with_retry(delete, [LServer, Path], 2, 500) of
	{ok, 200, _ } ->
	    {atomic, ok};
	Error ->
	    ?ERROR_MSG("Unexpected response for delete: ~p", [Error]),
	    {aborted, {error, rest_failed}}
    end.

import(_, _, _) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

vcard_rest_path(User, Server) ->
    Base = ejabberd_config:get_option({ext_api_path_vcard, Server},
                                      fun(X) -> iolist_to_binary(X) end,
                                      <<"/vcard">>),
    <<Base/binary, "/", User/binary>>.
vcard_rest_path(User, Server, Path) ->
    Base = vcard_rest_path(User, Server),
    <<Base/binary, "/", Path/binary>>.
