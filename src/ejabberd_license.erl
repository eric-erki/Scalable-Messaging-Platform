-module(ejabberd_license).

-export([info/0]).

-define(PRODUCT, "Ejabberd Business Edition").

info() ->
    case catch ejabberd:signature() of
        {'EXIT', _} -> ?PRODUCT ++ " code is too old: can not retreive license";
        {"", _, _} -> ?PRODUCT ++ " must be running to check license";
        {Vsn, _, Secs} -> info(Vsn, binary_to_term(Secs))
    end.
info(Vsn, Secs) ->
    {Today, _} = calendar:local_time(),
    {Until, _} = calendar:universal_time_to_local_time(calendar:gregorian_seconds_to_datetime(Secs)),
    Days = calendar:date_to_gregorian_days(Until) - calendar:date_to_gregorian_days(Today),
    ?PRODUCT++ " " ++ Vsn ++ " " ++ string(Until, Days).

string(_, Days) when Days < 0 ->
    "license has expired";
string(_, 0) ->
    "license is valid until today (expires tomorrow)";
string({2128, _, _}, _) ->
    "license is valid and will never expire";
string({Y,M,D}, Days) ->
    lists:flatten(io_lib:format("license is valid until ~B/~B/~B (expires in ~B days)", [Y,M,D,Days+1])).
