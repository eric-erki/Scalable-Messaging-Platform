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
-export([asciidoc/0, asciidoc/1]).

-include("translate.hrl").

%%%===================================================================
%%% API
%%%===================================================================
asciidoc() ->
    asciidoc(<<"en">>).

asciidoc(Lang) when is_list(Lang) ->
    asciidoc(list_to_binary(Lang));
asciidoc(Lang) ->
    ModDoc = lists:flatmap(
               fun(M) ->
                       case lists:prefix("mod_", atom_to_list(M)) orelse
                            lists:prefix("Elixir.Mod", atom_to_list(M)) of
                           true ->
                               try M:mod_doc() of
                                   {Title, DocOpts} ->
                                       [{M, Title, DocOpts}]
                               catch _:undef -> []
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
         "MODULES OPTIONS",
         "---------------",
         tr(Lang, ?T("This section describes options of all ejabberd modules.")),
         io_lib:nl()] ++
        lists:flatmap(
          fun({M, Title, DocOpts}) ->
                  [io_lib:nl(),
                   atom_to_list(M),
                   lists:duplicate(length(atom_to_list(M)), $~),
                   io_lib:nl()] ++
                      tr_multi(Lang, Title) ++ [io_lib:nl()] ++
                      opts_to_asciidoc(Lang, DocOpts)
          end, lists:keysort(1, ModDoc)),
    file:write_file(
      "/tmp/ejabberd.yml.5.txt",
      [[unicode:characters_to_binary(Line), io_lib:nl()]
       || Line <- man_header(Lang) ++ Options ++ [io_lib:nl()] ++ ModOptions ++ man_footer(Lang)]).

%%%===================================================================
%%% Internal functions
%%%===================================================================
opts_to_asciidoc(Lang, []) ->
    Text = tr(Lang, ?T("The module has no options")),
    [Text, lists:duplicate(length(Text), $^)];
opts_to_asciidoc(Lang, DocOpts) ->
    Text = tr(Lang, ?T("Available options")),
    [Text ++ ":", lists:duplicate(length(Text)+1, $^)|
     lists:flatmap(
       fun(Opt) -> opt_to_asciidoc(Lang, Opt, 1) end,
       lists:keysort(1, DocOpts))].

opt_to_asciidoc(Lang, {Option, Options}, _Level) ->
    [format_option(Lang, Option, Options)|format_desc(Lang, Options)] ++
        format_example(Options);
opt_to_asciidoc(Lang, {Option, Options, Children}, Level) ->
    [format_option(Lang, Option, Options)|format_desc(Lang, Options)] ++
        lists:append(
          [[H ++ ":"|T]
           || [H|T] <- lists:map(
                         fun(Opt) -> opt_to_asciidoc(Lang, Opt, Level+1) end,
                         lists:keysort(1, Children))]) ++
        [io_lib:nl()|format_example(Options)].

format_option(Lang, Option, #{value := Val}) ->
    "*" ++ atom_to_list(Option) ++ "*: 'pass:[" ++
        tr(Lang, Val) ++ "]'::";
format_option(_Lang, Option, #{}) ->
    "*" ++ atom_to_list(Option) ++ "*::".

format_desc(Lang, #{desc := Desc}) ->
    tr_multi(Lang, Desc).

format_example(#{example := Lines}) ->
    ["+",
     "*Example*",
     "+",
     "==========================",
     "[source,yaml]",
     "----"|Lines] ++
        ["----",
         "=========================="];
format_example(_) ->
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
     "Copyright (c) 2002-2019 https://www.process-one.net[ProcessOne]."].

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
