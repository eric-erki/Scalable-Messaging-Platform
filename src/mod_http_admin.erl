%%%----------------------------------------------------------------------
%%% File    : mod_http_admin.erl
%%% Author  : Christophe romain <cromain@process-one.net>
%%% Purpose : Provide admin REST API using JSON data
%%% Created : 15 Sep 2014 by Christophe Romain <cromain@process-one.net>
%%%----------------------------------------------------------------------

%% Example config:
%%
%%  {5280, ejabberd_http, [{request_handlers,
%%                          [{["api"], mod_http_admin}]}, ...
%%
%%  {mod_http_admin, [{access, admin}]},
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
    {400, [],
     #xmlel{name = <<"h1">>, attrs = [],
            children = [{xmlcdata, <<"400 Bad Request">>}]}};
process([Call], #request{method = 'POST', data = Data, ip = IP}) ->
    ?DEBUG("Admin call ~s from ~p with data: ~s", [Call, IP, Data]),
    try
        {Code, Result} = handle(Call, jiffy:decode(Data)),
        Reply = jiffy:encode(Result),
        {Code, [],
         #xmlel{name = <<"h1">>, attrs = [],
                children = [{xmlcdata, Reply}]}}
    catch Error ->
        ?DEBUG("Bad Request: ~p", [element(2, Error)]),
        {400, [],
         #xmlel{name = <<"h1">>, attrs = [],
                children = [{xmlcdata, <<"400 Bad Request">>}]}}
    end;
process(_Path, Request) ->
    ?DEBUG("Bad Request: no handler ~p", [Request]),
    {400, [],
     #xmlel{name = <<"h1">>, attrs = [],
            children = [{xmlcdata, <<"400 Bad Request">>}]}}.

%% ----------------
%% command handlers
%% ----------------

% update_roster
% input:
%  {"jid": "USER", "add": [{"jid": "CONTACT", "subscription": "both", "nick": "NICK"}, ...], "delete": ["CONTACT", ...]}
% output:
%  The HTTP status code will be 200 if user exists, 401 if not, or 500 codes if there was server errors.
handle(<<"update_roster">>, {Args}) when is_list(Args) ->
    [UserJid, Add, Del] = match(Args, [
                {<<"jid">>, <<>>},
                {<<"add">>, []},
                {<<"delete">>, []}]),
    {User, Server, _} = jlib:jid_tolower(jlib:string_to_jid(UserJid)),
    case ejabberd_auth:is_user_exists(User, Server) of
        true ->
            AddFun = fun({Item}) ->
                    [Jid, Nick, Sub] = match(Item, [
                                {<<"jid">>, <<>>},
                                {<<"nick">>, <<>>},
                                {<<"subscription">>, <<"both">>}]),
                    mod_admin_p1:add_rosteritem(User, Server, Jid, <<>>, Nick, Sub)
            end,
            AddRes = [AddFun(I) || I <- Add],
            case lists:all(fun(X) -> X==0 end, AddRes) of
                true ->
                    [mod_admin_p1:delete_rosteritem(User, Server, Jid) || Jid <- Del],
                    {200, <<"OK">>};
                false ->
                    %% try rollback if errors
                    DelFun = fun({Item}) ->
                            [Jid] = match(Item, [{<<"jid">>, <<>>}]),
                            mod_admin_p1:delete_rosteritem(User, Server, Jid)
                    end,
                    [DelFun(I) || I <- Add],
                    {500, <<"500 Internal server error">>}
            end;
        false ->
            {401, <<"Invalid User">>}
    end;

handle(Call, Args) ->
    Fun = binary_to_atom(Call, latin1),
    case erlang:function_exported(mod_admin_p1, Fun, length(Args)) of
        true ->
            case apply(mod_admin_p1, Fun, Args) of
                0 -> {200, <<"OK">>};
                1 -> {500, <<"500 Internal server error">>};
                Other -> {200, Other}
            end;
        false ->
            {400, <<"400 Bad Request">>}
    end.

%% -----------------
%% parameter matcher
%% -----------------
match(Args, Spec) ->
    [proplists:get_value(Key, Args, Default) || {Key, Default} <- Spec].
