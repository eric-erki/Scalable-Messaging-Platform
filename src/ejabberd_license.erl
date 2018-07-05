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
    lists:flatten(io_lib:format("~s ~s license is ~s", [?PRODUCT, Vsn, string(Until, Days)])).

string(_, Days) when Days < 1 ->
    "expired. Please uninstall or upgrade.";
string(_, Days) when Days < 36 ->
    io_lib:format("expired. Ejabberd will stop working in ~B days!", [Days]);
string(_, Days) when Days > 3650 ->
    "valid.";
string({Y,M,D}, Days) when Days < 96 ->
    % 3.2.x installers have all from 1 to 3 months of extra margin
    io_lib:format("about to expire. Ejabberd will stop working after ~4.10.0B-~2.10.0B-~2.10.0B.",
                  [Y, M, D]);
string({Y,M,D}, _) ->
    io_lib:format("valid. Ejabberd will stop working after ~4.10.0B-~2.10.0B-~2.10.0B.",
                  [Y, M, D]).
