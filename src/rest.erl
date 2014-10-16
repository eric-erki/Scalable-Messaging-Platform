-module(rest).

-export([start/0, stop/0, get/2, get/3, post/4, request/6]).

-include("logger.hrl").

-define(HTTP_TIMEOUT, 7000).
-define(CONNECT_TIMEOUT, 5000).

start() ->
    http_p1:start().

stop() ->
    ok.

get(Server, Path) ->
    request(Server, get, Path, [], "application/json", <<>>).
get(Server, Path, Params) ->
    request(Server, get, Path, Params, "application/json", <<>>).

post(Server, Path, Params, Content) ->
    Data = case catch jiffy:encode(Content) of
        {'EXIT', Reason} ->
            ?ERROR_MSG("HTTP content encodage failed:~n"
                       "** Content = ~p~n"
                       "** Err = ~p",
                       [Content, Reason]),
            <<>>;
        Encoded ->
            Encoded
    end,
    request(Server, post, Path, Params, "application/json", Data).

request(Server, Method, Path, Params, Mime, Data) ->
    URI = url(Server, Path, Params),
    Opts = [{connect_timeout, ?CONNECT_TIMEOUT},
            {timeout, ?HTTP_TIMEOUT}],
    Hdrs = [{"connection", "keep-alive"},
            {"content-type", Mime},
            {"User-Agent", "ejabberd"}],
    case catch http_p1:request(Method, URI, Hdrs, Data, Opts) of
        {ok, Code, _, <<>>} ->
            {ok, Code, []};
        {ok, Code, _, <<" ">>} ->
            {ok, Code, []};
        {ok, Code, _, Body} ->
            try jiffy:decode(Body) of
                JSon ->
                    {ok, Code, JSon}
            catch
                _:Error ->
                    ?ERROR_MSG("HTTP response decode failed:~n"
                               "** URI = ~s~n"
                               "** Body = ~p~n"
                               "** Err = ~p",
                               [URI, Body, Error]),
                    {error, {invalid_json, Body}}
            end;
        {error, Reason} ->
            ?ERROR_MSG("HTTP request failed:~n"
                       "** URI = ~s~n"
                       "** Err = ~p",
                       [URI, Reason]),
            {error, {http_error, {error, Reason}}};
        {'EXIT', Reason} ->
            ?ERROR_MSG("HTTP request failed:~n"
                       "** URI = ~s~n"
                       "** Err = ~p",
                       [URI, Reason]),
            {error, {http_error, {error, Reason}}}
    end.

%%%----------------------------------------------------------------------
%%% HTTP helpers
%%%----------------------------------------------------------------------

base_url(Server, Path) ->
    Base = ejabberd_config:get_option({ext_api_url, Server},
                                      fun(X) -> iolist_to_binary(X) end,
                                      <<"http://localhost/api">>),
    <<Base/binary, (iolist_to_binary(Path))/binary>>.

url(Server, Path, []) ->
    binary_to_list(base_url(Server, Path));
url(Server, Path, Params) ->
    Base = base_url(Server, Path),
    [<<$&, ParHead/binary>> | ParTail] =
        [<<"&", (iolist_to_binary(Key))/binary, "=", (ejabberd_http:url_encode(Value))/binary>>
            || {Key, Value} <- Params],
    Tail = iolist_to_binary([ParHead | ParTail]),
    binary_to_list(<<Base/binary, $?, Tail/binary>>).
