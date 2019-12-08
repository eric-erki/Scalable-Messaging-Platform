%%%----------------------------------------------------------------------
%%% File    : ejabberd_doc.erl
%%% Purpose : Options documentation generator
%%%
%%% ejabberd, Copyright (C) 2002-2019   ProcessOne
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
-module(ejabberd_doc).

%% API
-export([man/0, man/1, have_a2x/0]).

-include("translate.hrl").

%%%===================================================================
%%% API
%%%===================================================================
man() ->
    man(<<"en">>).

man(Lang) when is_list(Lang) ->
    man(list_to_binary(Lang));
man(Lang) ->
    ModDoc = lists:flatmap(
               fun(M) ->
                       case lists:prefix("mod_", atom_to_list(M)) orelse
                            lists:prefix("Elixir.Mod", atom_to_list(M)) of
                           true ->
                               try M:mod_doc() of
                                   #{desc := Descr} = Map ->
                                       DocOpts = maps:get(opts, Map, []),
                                       Example = maps:get(example, Map, []),
                                       [{M, Descr, DocOpts, #{example => Example}}]
                               catch _:undef ->
                                       case erlang:function_exported(
                                              M, mod_options, 1) of
                                           true ->
                                               warn("module ~s is not documented", [M]);
                                           false ->
                                               ok
                                       end,
                                       []
                               end;
                           false ->
                               []
                       end
               end, ejabberd_config:beams(all)),
    Doc = lists:flatmap(
            fun(M) ->
                    try M:doc()
                    catch _:undef -> []
                    end
            end, ejabberd_config:callback_modules(all)),
    Options =
        ["TOP-LEVEL OPTIONS",
         "-----------------",
         tr(Lang, ?T("This section describes top level options of ejabberd.")),
         io_lib:nl()] ++
        lists:flatmap(
          fun(Opt) ->
                  opt_to_asciidoc(Lang, Opt, 1)
          end, lists:keysort(1, Doc)),
    ModOptions =
        [io_lib:nl(),
         "MODULES",
         "-------",
         tr(Lang, ?T("This section describes options of all ejabberd modules.")),
         io_lib:nl()] ++
        lists:flatmap(
          fun({M, Descr, DocOpts, Example}) ->
                  [io_lib:nl(),
                   atom_to_list(M),
                   lists:duplicate(length(atom_to_list(M)), $~),
                   io_lib:nl()] ++
                      tr_multi(Lang, Descr) ++ [io_lib:nl()] ++
                      opts_to_asciidoc(Lang, DocOpts) ++ [io_lib:nl()] ++
                      format_example(0, Example)
          end, lists:keysort(1, ModDoc)),
    AsciiData =
         [[unicode:characters_to_binary(Line), io_lib:nl()]
          || Line <- man_header(Lang) ++ Options ++ [io_lib:nl()]
                 ++ ModOptions ++ man_footer(Lang)],
    warn_undocumented_modules(ModDoc),
    warn_undocumented_options(Doc),
    write_man(AsciiData).

%%%===================================================================
%%% Internal functions
%%%===================================================================
opts_to_asciidoc(Lang, []) ->
    Text = tr(Lang, ?T("The module has no options.")),
    [Text];
opts_to_asciidoc(Lang, DocOpts) ->
    Text = tr(Lang, ?T("Available options")),
    [Text ++ ":", lists:duplicate(length(Text)+1, $^)|
     lists:flatmap(
       fun(Opt) -> opt_to_asciidoc(Lang, Opt, 1) end,
       lists:keysort(1, DocOpts))].

opt_to_asciidoc(Lang, {Option, Options}, Level) ->
    [format_option(Lang, Option, Options)|format_desc(Lang, Options)] ++
        format_example(Level, Options);
opt_to_asciidoc(Lang, {Option, Options, Children}, Level) ->
    [format_option(Lang, Option, Options)|format_desc(Lang, Options)] ++
        lists:append(
          [[H ++ ":"|T]
           || [H|T] <- lists:map(
                         fun(Opt) -> opt_to_asciidoc(Lang, Opt, Level+1) end,
                         lists:keysort(1, Children))]) ++
        [io_lib:nl()|format_example(Level, Options)].

format_option(Lang, Option, #{value := Val}) ->
    "*" ++ atom_to_list(Option) ++ "*: 'pass:[" ++
        tr(Lang, Val) ++ "]'::";
format_option(_Lang, Option, #{}) ->
    "*" ++ atom_to_list(Option) ++ "*::".

format_desc(Lang, #{desc := Desc}) ->
    tr_multi(Lang, Desc).

format_example(Level, #{example := [_|_] = Lines}) ->
    if Level == 0 ->
            ["*Example*",
             "^^^^^^^^^"];
       true ->
            ["+",
             "*Example*",
             "+"]
    end ++
        ["==========================",
         "[source,yaml]",
         "----"|Lines] ++
        ["----",
         "=========================="];
format_example(_, _) ->
    [].

man_header(Lang) ->
    ["ejabberd.yml(5)",
     "===============",
     ":doctype: manpage",
     ":version: " ++ binary_to_list(ejabberd_config:version()),
     io_lib:nl(),
     "NAME",
     "----",
     "ejabberd.yml - " ++ tr(Lang, ?T("main configuration file for ejabberd.")),
     io_lib:nl(),
     "SYNOPSIS",
     "--------",
     "ejabberd.yml",
     io_lib:nl(),
     "DESCRIPTION",
     "-----------",
     tr(Lang, ?T("The configuration file is written in "
                 "https://en.wikipedia.org/wiki/YAML[YAML] language.")),
     io_lib:nl(),
     tr(Lang, ?T("WARNING: YAML is indentation sensitive, so make sure you respect "
                 "indentation, or otherwise you will get pretty cryptic "
                 "configuration errors.")),
     io_lib:nl()].

man_footer(Lang) ->
    {Year, _, _} = date(),
    [io_lib:nl(),
     "AUTHOR",
     "------",
     "https://www.process-one.net[ProcessOne].",
     io_lib:nl(),
     "VERSION",
     "-------",
     str:format(
       tr(Lang, ?T("This document describes the configuration file of ejabberd ~ts. "
                   "Configuration options of other ejabberd versions "
                   "may differ significantly.")),
       [ejabberd_config:version()]),
     io_lib:nl(),
     "REPORTING BUGS",
     "--------------",
     tr(Lang, ?T("Report bugs to <https://github.com/processone/ejabberd/issues>")),
     io_lib:nl(),
     "SEE ALSO",
     "---------",
     tr(Lang, ?T("Default configuration file")) ++
         ": <https://github.com/processone/ejabberd/blob/" ++
         binary_to_list(binary:part(ejabberd_config:version(), {0,5})) ++
         "/ejabberd.yml.example>",
     io_lib:nl(),
     tr(Lang, ?T("Main site")) ++ ": <https://ejabberd.im>",
     io_lib:nl(),
     tr(Lang, ?T("Documentation")) ++ ": <https://docs.ejabberd.im>",
     io_lib:nl(),
     tr(Lang, ?T("Configuration Guide")) ++ ": <https://docs.ejabberd.im/admin/configuration>",
     io_lib:nl(),
     tr(Lang, ?T("Source code")) ++ ": <https://github.com/processone/ejabberd>",
     io_lib:nl(),
     "COPYING",
     "-------",
     "Copyright (c) 2002-" ++ integer_to_list(Year) ++
         " https://www.process-one.net[ProcessOne]."].

tr(Lang, {Format, Args}) ->
    unicode:characters_to_list(
      str:format(
        translate:translate(Lang, iolist_to_binary(Format)),
        Args));
tr(Lang, Txt) ->
    unicode:characters_to_list(translate:translate(Lang, iolist_to_binary(Txt))).

tr_multi(Lang, Txt) when is_binary(Txt) ->
    tr_multi(Lang, [Txt]);
tr_multi(Lang, {Format, Args}) ->
    tr_multi(Lang, [{Format, Args}]);
tr_multi(Lang, Lines) when is_list(Lines) ->
    [tr(Lang, Txt) || Txt <- Lines].

write_man(AsciiData) ->
    case file:get_cwd() of
        {ok, Cwd} ->
            AsciiDocFile = filename:join(Cwd, "ejabberd.yml.5.txt"),
            ManPage = filename:join(Cwd, "ejabberd.yml.5"),
            case file:write_file(AsciiDocFile, AsciiData) of
                ok ->
                    Ret = run_a2x(Cwd, AsciiDocFile),
                    %%file:delete(AsciiDocFile),
                    case Ret of
                        ok ->
                            {ok, lists:flatten(
                                   io_lib:format(
                                     "The manpage saved as ~ts", [ManPage]))};
                        {error, Error} ->
                            {error, lists:flatten(
                                      io_lib:format(
                                        "Failed to generate manpage: ~ts", [Error]))}
                    end;
                {error, Reason} ->
                    {error, lists:flatten(
                              io_lib:format(
                                "Failed to write to ~ts: ~s",
                                [AsciiDocFile, file:format_error(Reason)]))}
            end;
        {error, Reason} ->
            {error, lists:flatten(
                      io_lib:format("Failed to get current directory: ~s",
                                    [file:format_error(Reason)]))}
    end.

have_a2x() ->
    case os:find_executable("a2x") of
        false -> false;
        Path -> {true, Path}
    end.

run_a2x(Cwd, AsciiDocFile) ->
    case have_a2x() of
        false ->
            {error, "a2x was not found: do you have 'asciidoc' installed?"};
        {true, Path} ->
            Cmd = lists:flatten(
                    io_lib:format("~ts -f manpage ~ts -D ~ts",
                                  [Path, AsciiDocFile, Cwd])),
            case os:cmd(Cmd) of
                "" -> ok;
                Ret -> {error, Ret}
            end
    end.

warn_undocumented_modules(Docs) ->
    lists:foreach(
      fun({M, _, DocOpts, _}) ->
              try M:mod_options(ejabberd_config:get_myname()) of
                  Defaults ->
                      lists:foreach(
                        fun(OptDefault) ->
                                Opt = case OptDefault of
                                          O when is_atom(O) -> O;
                                          {O, _} -> O
                                      end,
                                case lists:keymember(Opt, 1, DocOpts) of
                                    false ->
                                        warn("~s: option ~s is not documented",
                                             [M, Opt]);
                                    true ->
                                        ok
                                end
                        end, Defaults)
              catch _:undef ->
                      ok
              end
      end, Docs).

warn_undocumented_options(Docs) ->
    Opts = lists:flatmap(
             fun(M) ->
                     try M:options() of
                         Defaults ->
                             lists:map(
                               fun({O, _}) -> O;
                                  (O) when is_atom(O) -> O
                               end, Defaults)
                     catch _:undef ->
                             []
                     end
             end, ejabberd_config:callback_modules(all)),
    lists:foreach(
      fun(Opt) ->
              case lists:keymember(Opt, 1, Docs) of
                  false ->
                      warn("option ~s is not documented", [Opt]);
                  true ->
                      ok
              end
      end, Opts).

warn(Format, Args) ->
    io:format(standard_error, "Warning: " ++ Format ++ "~n", Args).
