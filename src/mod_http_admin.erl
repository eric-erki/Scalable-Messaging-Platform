%%%----------------------------------------------------------------------
%%% File    : mod_http_admin.erl
%%% Author  : Christophe romain <christophe.romain@process-one.net>
%%% Purpose : Provide admin REST API using JSON data
%%% Created : 15 Sep 2014 by Christophe Romain <christophe.romain@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2015   ProcessOne
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
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

%% Example config:
%%
%%  in ejabberd_http listener
%%    request_handlers:
%%      "api": mod_http_admin
%%
%%  in module section
%%    mod_http_admin:
%%      access: admin
%%
%% Then to perform an action, send a POST request to the following URL:
%% http://localhost:5280/api/<call_name>

-module(mod_http_admin).

-author('cromain@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, process/2]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("logger.hrl").
-include("ejabberd_http.hrl").

-define(CT_PLAIN,
        {<<"Content-Type">>, <<"text/plain">>}).

-define(CT_XML,
        {<<"Content-Type">>, <<"text/xml; charset=utf-8">>}).

-define(CT_JSON,
        {<<"Content-Type">>, <<"application/json">>}).

-define(AC_ALLOW_ORIGIN,
        {<<"Access-Control-Allow-Origin">>, <<"*">>}).

-define(AC_ALLOW_METHODS,
        {<<"Access-Control-Allow-Methods">>,
         <<"GET, POST, OPTIONS">>}).

-define(AC_ALLOW_HEADERS,
        {<<"Access-Control-Allow-Headers">>,
         <<"Content-Type">>}).

-define(AC_MAX_AGE,
        {<<"Access-Control-Max-Age">>, <<"86400">>}).

-define(OPTIONS_HEADER,
        [?CT_PLAIN, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_METHODS,
         ?AC_ALLOW_HEADERS, ?AC_MAX_AGE]).

-define(HEADER(CType),
        [CType, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_HEADERS]).

%% -------------------
%% Module control
%% -------------------

start(_Host, _Opts) ->
    ok.

stop(_Host) ->
    ok.


%% ----------
%% basic auth
%% ----------

%get_auth_admin(Auth) ->
%    case Auth of
%        {SJID, Pass} ->
%            AccessRule =
%                gen_mod:get_module_opt(
%                  ?MYNAME, ?MODULE, access,
%                  fun(A) when is_atom(A) -> A end, none),
%            case jlib:string_to_jid(SJID) of
%                error -> {unauthorized, <<"badformed-jid">>};
%                #jid{user = <<"">>, server = User} ->
%                    get_auth_account(?MYNAME, AccessRule, User, ?MYNAME, Pass);
%                #jid{user = User, server = Server} ->
%                    get_auth_account(?MYNAME, AccessRule, User, Server, Pass)
%            end;
%        undefined ->
%            {unauthorized, <<"no-auth-provided">>}
%    end.
%
%get_auth_account(HostOfRule, AccessRule, User, Server, Pass) ->
%    case ejabberd_auth:check_password(User, Server, Pass) of
%        true ->
%            case is_acl_match(HostOfRule, AccessRule,
%                              jlib:make_jid(User, Server, <<"">>)) of
%                false -> {unauthorized, <<"unprivileged-account">>};
%                true -> {ok, {User, Server}}
%            end;
%        false ->
%            case ejabberd_auth:is_user_exists(User, Server) of
%                true -> {unauthorized, <<"bad-password">>};
%                false -> {unauthorized, <<"inexistent-account">>}
%            end
%    end.
%
%is_acl_match(Host, Rule, JID) ->
%    allow == acl:match_rule(Host, Rule, JID).


%% ------------------
%% command processing
%% ------------------

process(_, #request{method = 'POST', data = <<>>}) ->
    ?DEBUG("Bad Request: no data", []),
    badrequest_response();
process([Call], #request{method = 'POST', data = Data, ip = IP}) ->
    try
        Args = case jiffy:decode(Data) of
            Raw when is_list(Raw) -> Raw;
            {Object} when is_list(Object) -> [Arg || {_, Arg} <- Object];
            Other -> [Other]
        end,
        log(Call, Args, IP),
        {Code, Result} = handle(Call, Args),
        json_response(Code, jiffy:encode(Result))
    catch Error ->
        ?DEBUG("Bad Request: ~p", [element(2, Error)]),
        badrequest_response()
    end;
process([Call], #request{method = 'GET', q = Data, ip = IP}) ->
    try
        Args = case Data of
            [{nokey, <<>>}] -> [];
            _ -> [Arg || {_, Arg} <- Data]
        end,
        log(Call, Args, IP),
        {Code, Result} = handle(Call, Args),
        json_response(Code, jiffy:encode(Result))
    catch Error ->
        ?DEBUG("Bad Request: ~p", [element(2, Error)]),
        badrequest_response()
    end;
process([], #request{method = 'OPTIONS', data = <<>>}) ->
    {200, ?OPTIONS_HEADER, []};
process(_Path, Request) ->
    ?DEBUG("Bad Request: no handler ~p", [Request]),
    badrequest_response().

%% ----------------
%% command handlers
%% ----------------

% ejabberd SaaS command update_roster
% this command is only available through REST API  (TODO: move to mod_admin_p1 ?)
%
% input:
%  {"username": "USER",
%   "domain": "DOMAIN",  % if ommited, we take the first configured vhost
%   "add": [{"jid": "CONTACT", "subscription": "both", "nick": "NICK"}, ...],
%   "delete": ["CONTACT", ...]}
% output:
%  The HTTP status code will be 200 if user exists, 401 if not, or 500 codes if there was server errors.
handle(<<"update_roster">>, {Args}) when is_list(Args) ->
    [User, Domain, Add, Del] = match(Args, [
                {<<"username">>, <<>>},
                {<<"domain">>, <<>>},
                {<<"add">>, []},
                {<<"delete">>, []}]),
    Server = case Domain of
        <<>> ->
            [Default|_] = ejabberd_config:get_myhosts(),
            Default;
        _ ->
            Domain
    end,
    case ejabberd_auth:is_user_exists(User, Server) of
        true ->
            AddFun = fun({Item}) ->
                    [Contact, Nick, Sub] = match(Item, [
                                {<<"username">>, <<>>},
                                {<<"nick">>, <<>>},
                                {<<"subscription">>, <<"both">>}]),
                    Jid = <<Contact/binary, "@", Server/binary>>,
                    mod_admin_p1:add_rosteritem(User, Server, Jid, <<>>, Nick, Sub)
            end,
            AddRes = [AddFun(I) || I <- Add],
            case lists:all(fun(X) -> X==0 end, AddRes) of
                true ->
                    DelFun = fun(Contact) ->
                            Jid = <<Contact/binary, "@", Server/binary>>,
                            mod_admin_p1:delete_rosteritem(User, Server, Jid)
                    end,
                    [DelFun(I) || I <- Del],
                    {200, <<"OK">>};
                false ->
                    %% try rollback if errors
                    DelFun = fun({Item}) ->
                            [Contact] = match(Item, [{<<"username">>, <<>>}]),
                            Jid = <<Contact/binary, "@", Server/binary>>,
                            mod_admin_p1:delete_rosteritem(User, Server, Jid)
                    end,
                    [DelFun(I) || I <- Add],
                    {500, <<"500 Internal server error">>}
            end;
        false ->
            {401, <<"Invalid User">>}
    end;

% generic ejabberd command handler
handle(Call, Args) when is_list(Args) ->
    Fun = binary_to_atom(Call, latin1),
    case ejabberd_command(Fun, Args, 400) of
        0 -> {200, <<"OK">>};
        1 -> {500, <<"500 Internal server error">>};
        400 -> {400, <<"400 Bad Request">>};
        Res -> {200, format_command_result(Fun, Res)}
    end.

%% ----------------
%% internal helpers
%% ----------------

match(Args, Spec) ->
    [proplists:get_value(Key, Args, Default) || {Key, Default} <- Spec].

ejabberd_command(Cmd, Args, Default) ->
    case catch ejabberd_commands:execute_command(Cmd, Args) of
        {'EXIT', _} -> Default;
        {error, _} -> Default;
        Result -> Result
    end.

format_command_result(Cmd, Result) ->
    {_, ResultFormat} = ejabberd_commands:get_command_format(Cmd),
    case format_result(Result, ResultFormat) of
        {res, Object} when is_list(Object) -> {Object};
        {res, Object} -> Object;
        Object when is_list(Object) -> {Object};
        Object -> Object
    end.

format_result(Atom, {Name, atom}) ->
    {Name, Atom};

format_result(Int, {Name, integer}) ->
    {Name, Int};

format_result(String, {Name, string}) ->
    {Name, String};

format_result(Code, {_Name, rescode}) ->
    Code;

format_result({Code, Text}, {_Name, restuple}) ->
    {Text, Code};

format_result(Els, {Name, {list, Def}}) ->
    {Name, {[format_result(El, Def) || El <- Els]}};

format_result({Key, Val}, {_Name, {tuple, [{_, atom}, {_, integer}]}})
        when is_atom(Key), is_integer(Val) ->
    {Key, Val};
format_result({Key, Val}, {_Name, {tuple, [{_, atom}, {_, string}]}})
        when is_atom(Key), is_binary(Val) ->
    {Key, Val};
format_result(Tuple, {Name, {tuple, Def}}) ->
    Els = lists:zip(tuple_to_list(Tuple), Def),
    {Name, [format_result(El, ElDef) || {El, ElDef} <- Els]};

format_result(404, {_Name, _}) ->
    "not_found".

badrequest_response() ->
    {400, ?HEADER(?CT_XML),
     #xmlel{name = <<"h1">>, attrs = [],
            children = [{xmlcdata, <<"400 Bad Request">>}]}}.
json_response(Code, Body) ->
    {Code, ?HEADER(?CT_JSON), Body}.

log(Call, Args, {Addr, Port}) ->
    AddrS = jlib:ip_to_list({Addr, Port}),
    ?INFO_MSG("Admin call ~s ~p from ~s:~p", [Call, Args, AddrS, Port]).
