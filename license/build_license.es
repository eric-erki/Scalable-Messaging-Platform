#!/usr/bin/env escript
%%! -pa ebin -pa deps/lager/ebin

compile_opts({Y,M,D,N}, Acc) ->
    Secs = calendar:datetime_to_gregorian_seconds({{Y,M,D},{23,59,00}})-62167219200,
    Val = (N bsl 14) + ((Secs div 1000000) bsl 1) + ((Secs rem 1000000) bsr 19),
    [{d, 'VALIDITY', Val} | Acc].

compile(SrcDir, Mod, Options) ->
    File = filename:join(SrcDir, atom_to_list(Mod)++".erl"),
    io:format("Compiling ~s...~n", [File]),
    case compile:file(File, Options) of
        {ok, _} -> ok;
        {ok, _, _} -> ok;
        {ok, _, _, _} -> ok;
        error -> {compilation_failed, File};
        Error -> Error
    end.

strip(EbinDir, Mod) ->
    File = filename:join(EbinDir, atom_to_list(Mod)++".beam"),
    case beam_lib:strip(File) of
        {ok, {Mod, Beam}} -> file:read_file(Beam);
        _ -> {strip_failed, File}
    end.

license([Y1,Y2,Y3,Y4,M1,M2,D1,D2,N1] = Key) ->
    try
        Y = binary_to_integer(<<Y1,Y2,Y3,Y4>>),
        M = binary_to_integer(<<M1,M2>>),
        D = binary_to_integer(<<D1,D2>>),
        N = binary_to_integer(<<N1>>),
        Month = lists:nth(M, ["January", "February", "March", "April", "May",
                              "June", "July", "August", "September",
                              "October", "November", "December"]),
        LimitStr = io_lib:format("New license expires on ~b ~s ~b", [D, Month, Y]),
        Desc = case N of
            0 -> LimitStr;
            1 -> LimitStr++", without cluster support";
            _ -> LimitStr++", up to "++integer_to_list(N)++" cluster nodes"
        end,
        {ok, {Y,M,D,N}, lists:flatten(Desc)}
    catch _:_ ->
        {error, {invalid_license, Key}}
    end;
license([Y1,Y2,Y3,Y4,M1,M2,D1,D2]) ->
    license([Y1,Y2,Y3,Y4,M1,M2,D1,D2,$0]);
license(Other) ->
    {error, {invalid_license, Other}}.

build_license(_Src, _Ebin, _Options, [], Acc) ->
    {ok, Acc};
build_license(Src, Ebin, Options, [Mod|Tail], Acc) ->
    Build = case compile(Src, Mod, Options) of
        ok -> strip(Ebin, Mod);
        Other -> Other
    end,
    case Build of
        {ok, Beam} -> build_license(Src, Ebin, Options, Tail, [{Mod, Beam}|Acc]);
        Error -> {error, Error}
    end.

main([Vsn, LicenseKey]) ->
    Dir = os:getenv("PWD"),
    Inc = filename:join(Dir, "include"),
    Src = filename:join(Dir, "src"),
    Ebin = filename:join(Dir, "ebin"),
    Xml = filename:join([Dir, "deps", "fast_xml", "include"]),
    case license(LicenseKey) of
        {ok, License, LicenseStr} ->
            BaseOpts = [{outdir, Ebin}, {i, Inc}, {i, Xml}, {d, 'NO_EXT_LIB'}],
            Options = compile_opts(License, BaseOpts),
            Files = [ejabberd, ejabberd_license, ejabberd_c2s, ejabberd_listener, ejabberd_router, ejabberd_cluster, ejabberd_sm],
            case build_license(Src, Ebin, Options, Files, []) of
                {ok, Beams} ->
                    Hrl = io_lib:format("-define(ARGS, ~p).", [[Vsn, LicenseStr, Beams]]),
                    file:write_file("ejabberd_patch.hrl", Hrl);
                Error ->
                    io:format("Error: can not build license ~p~n", [Error])
            end;
        _ ->
            io:format("Error: invalid licence ~p~n", [LicenseKey])
    end;
main(_) ->
    io:format("Usage: Vsn LicenseKey~n", []).
