#!/usr/bin/env escript
%% -*- erlang -*-

main(_) ->
    io:format("starting SSL application..."),
    ok = ssl:start(),
    io:format(" done~n"),
    {ok, Cwd} = file:get_cwd(),
    BootFile = filename:join([Cwd, "start_ssl"]),
    RelFile = filename:join([Cwd, BootFile ++ ".rel"]),
    OTPVersion = erlang:system_info(otp_release),
    ERTSVersion = erlang:system_info(version),
    Apps = [{Name, Ver} ||
	       {Name, _, Ver} <- application:which_applications()],
    RelData = {release,
	       {"OTP  APN 181 01", OTPVersion},
	       {erts, ERTSVersion},
	       Apps},
    io:format("writing release file ~s...", [RelFile]),
    ok = file:write_file(RelFile, io_lib:fwrite("~p.~n", [RelData])),
    io:format(" done~n"),
    io:format("generating boot file..."),
    {ok, _, _} = systools:make_script(BootFile, [silent]),
    io:format(" done~n"),
    io:format("removing release file ~s...", [RelFile]),
    ok = file:delete(RelFile),
    io:format(" done~n"),
    io:format("boot file successfully created~n"
	      "now start the emulator as follows:~n~n"
	      "$ erl -boot ~s~n~n", [BootFile]).
