%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @doc
%%%   JID processing library
%%% @end
%%% Created : 24 Nov 2015 by Evgeny Khramtsov <ekhramtsov@process-one.net>
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
%%%-------------------------------------------------------------------
-module(jid).

-on_load(load_nif/0).

%% API
-export([load_nif/0,
	 make/1,
	 make/3,
	 split/1,
	 string_to_usr/1,
	 from_string/1,
	 to_string/1,
	 is_nodename/1,
	 nodeprep/1,
	 nameprep/1,
	 resourceprep/1,
	 tolower/1,
	 remove_resource/1,
	 replace_resource/2]).

-include("jlib.hrl").

-export_type([jid/0]).

%%%===================================================================
%%% API
%%%===================================================================
load_nif() ->
    load_nif(get_so_path()).

-spec make(binary(), binary(), binary()) -> jid() | error.

make(User, Server, Resource) ->
    case nodeprep(User) of
      error -> error;
      LUser ->
	  case nameprep(Server) of
	    error -> error;
	    LServer ->
		case resourceprep(Resource) of
		  error -> error;
		  LResource ->
		      #jid{user = User, server = Server, resource = Resource,
			   luser = LUser, lserver = LServer,
			   lresource = LResource}
		end
	  end
    end.

-spec make({binary(), binary(), binary()}) -> jid() | error.

make({User, Server, Resource}) ->
    make(User, Server, Resource).

-spec string_to_usr(binary()) -> {binary(), binary(), binary()} | error.

string_to_usr(_S) ->
    erlang:nif_error(nif_not_loaded).

%% This is the reverse of make_jid/1
-spec split(jid()) -> {binary(), binary(), binary()} | error.

split(#jid{user = U, server = S, resource = R}) ->
    {U, S, R};
split(_) ->
    error.

-spec from_string(binary()) -> jid() | error.

from_string(S) ->
    case string_to_usr(S) of
        error -> error;
        USR -> make(USR)
    end.

-spec to_string(jid() | ljid()) -> binary().

to_string(#jid{user = User, server = Server,
	       resource = Resource}) ->
    to_string({User, Server, Resource});
to_string({N, S, R}) ->
    Node = iolist_to_binary(N),
    Server = iolist_to_binary(S),
    Resource = iolist_to_binary(R),
    S1 = case Node of
	   <<"">> -> <<"">>;
	   _ -> <<Node/binary, "@">>
	 end,
    S2 = <<S1/binary, Server/binary>>,
    S3 = case Resource of
	   <<"">> -> S2;
	   _ -> <<S2/binary, "/", Resource/binary>>
	 end,
    S3.

-spec is_nodename(binary()) -> boolean().

is_nodename(Node) ->
    N = nodeprep(Node),
    (N /= error) and (N /= <<>>).

-spec nodeprep(binary()) -> binary() | error.

nodeprep("") -> <<>>;
nodeprep(S) when byte_size(S) < 1024 ->
    R = stringprep:nodeprep(S),
    if byte_size(R) < 1024 -> R;
       true -> error
    end;
nodeprep(_) -> error.

-spec nameprep(binary()) -> binary() | error.

nameprep(S) when byte_size(S) < 1024 ->
    R = stringprep:nameprep(S),
    if byte_size(R) < 1024 -> R;
       true -> error
    end;
nameprep(_) -> error.

-spec resourceprep(binary()) -> binary() | error.

resourceprep(S) when byte_size(S) < 1024 ->
    R = stringprep:resourceprep(S),
    if byte_size(R) < 1024 -> R;
       true -> error
    end;
resourceprep(_) -> error.

-spec tolower(jid() | ljid()) -> error | ljid().

tolower(#jid{luser = U, lserver = S,
	     lresource = R}) ->
    {U, S, R};
tolower({U, S, R}) ->
    case nodeprep(U) of
      error -> error;
      LUser ->
	  case nameprep(S) of
	    error -> error;
	    LServer ->
		case resourceprep(R) of
		  error -> error;
		  LResource -> {LUser, LServer, LResource}
		end
	  end
    end.

-spec remove_resource(jid()) -> jid();
		     (ljid()) -> ljid().

remove_resource(#jid{} = JID) ->
    JID#jid{resource = <<"">>, lresource = <<"">>};
remove_resource({U, S, _R}) -> {U, S, <<"">>}.

-spec replace_resource(jid(), binary()) -> error | jid().

replace_resource(JID, Resource) ->
    case resourceprep(Resource) of
      error -> error;
      LResource ->
	  JID#jid{resource = Resource, lresource = LResource}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================
load_nif(LibDir) ->
    SOPath = filename:join(LibDir, "jid"),
    case catch erlang:load_nif(SOPath, 0) of
        ok ->
            ok;
        Err ->
            error_logger:warning_msg("unable to load jid NIF: ~p~n", [Err]),
            Err
    end.

get_so_path() ->
    case os:getenv("EJABBERD_SO_PATH") of
        false ->
            EbinDir = filename:dirname(code:which(?MODULE)),
            AppDir = filename:dirname(EbinDir),
            filename:join([AppDir, "priv", "lib"]);
        Path ->
            Path
    end.

%%%===================================================================
%%% Unit tests
%%%===================================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

permute(Xs) ->
    permute(Xs, []).

permute([X|Xs], Ys) ->
    [[X|T] || T <- permute(Xs ++ Ys, [])] ++ permute(Xs, [X|Ys]);
permute([], []) ->
    [[]];
permute([], _Ys) ->
    [].

start_test() ->
    ?assertEqual(ok, application:start(p1_stringprep)).

make_1_test() ->
    USR = {U, S, R} = {<<"user">>, <<"server">>, <<"resource">>},
    ?assertMatch(
       #jid{user = U, server = S, resource = R},
       jid:make(USR)).

make_3_test() ->
    {U, S, R} = {<<"user">>, <<"server">>, <<"resource">>},
    ?assertMatch(
       #jid{user = U, server = S, resource = R},
       jid:make(U, S, R)).

split_test() ->
    USR = {U, S, R} = {<<"user">>, <<"server">>, <<"resource">>},
    JID = #jid{user = U, luser = U, server = S, lserver = S,
	       resource = R, lresource = R},
    ?assertMatch(USR, jid:split(JID)).

from_string_test() ->
    SJID = <<"user@server/resource">>,
    {U, S, R} = {<<"user">>, <<"server">>, <<"resource">>},
    JID = #jid{user = U, luser = U, server = S, lserver = S,
	       resource = R, lresource = R},
    ?assertEqual(JID, jid:from_string(SJID)).

to_string_test() ->
    SJID = <<"user@server/resource">>,
    {U, S, R} = {<<"user">>, <<"server">>, <<"resource">>},
    JID = #jid{user = U, luser = U, server = S, lserver = S,
	       resource = R, lresource = R},
    ?assertEqual(SJID, jid:to_string(JID)).

to_lower_test() ->
    USR = {U, S, R} = {<<"user">>, <<"server">>, <<"resource">>},
    JID = #jid{user = U, luser = U, server = S, lserver = S,
	       resource = R, lresource = R},
    ?assertEqual(USR, jid:tolower(JID)).

remove_resource_jid_test() ->
    {U, S, R} = {<<"user">>, <<"server">>, <<"resource">>},
    JID = #jid{user = U, luser = U, server = S, lserver = S,
	       resource = R, lresource = R},
    RJID = JID#jid{resource = <<"">>, lresource = <<"">>},
    ?assertEqual(RJID, jid:remove_resource(JID)).

remove_resource_ljid_test() ->
    USR = {U, S, _} = {<<"user">>, <<"server">>, <<"resource">>},
    ?assertEqual({U, S, <<"">>}, jid:remove_resource(USR)).

replace_resource_test() ->
    {U, S, R} = {<<"user">>, <<"server">>, <<"resource">>},
    JID = #jid{user = U, luser = U, server = S, lserver = S,
	       resource = R, lresource = R},
    RJID = JID#jid{resource = <<"r">>, lresource = <<"r">>},
    ?assertEqual(RJID, jid:replace_resource(JID, <<"r">>)).

is_nodename_empty_test() ->
    ?assertEqual(false, jid:is_nodename(<<"">>)).

is_nodename_test() ->
    ?assertEqual(true, jid:is_nodename(<<"user">>)).

nodeprep_long_string_test() ->
    S = list_to_binary(lists:duplicate(1024, $u)),
    ?assertEqual(error, jid:nodeprep(S)).

nodeprep_test() ->
    ?assertEqual(<<"user">>, jid:nodeprep(<<"user">>)).

nameprep_long_string_test() ->
    S = list_to_binary(lists:duplicate(1024, $s)),
    ?assertEqual(error, jid:nameprep(S)).

nameprep_test() ->
    ?assertEqual(<<"server">>, jid:nameprep(<<"server">>)).

resourceprep_long_string_test() ->
    S = list_to_binary(lists:duplicate(1024, $r)),
    ?assertEqual(error, jid:resourceprep(S)).

resourceprep_test() ->
    ?assertEqual(<<"resource">>, jid:resourceprep(<<"resource">>)).

string_to_usr_empty_test() ->
    ?assertEqual(error, jid:string_to_usr(<<"">>)).

string_to_usr_server_test() ->
    ?assertEqual({<<"">>, <<"server">>, <<"">>},
                 jid:string_to_usr(<<"server">>)).

string_to_usr_amp_test() ->
    ?assertEqual(error, jid:string_to_usr(<<"@">>)),
    ?assertEqual(error, jid:string_to_usr(<<"@server">>)),
    ?assertEqual(error, jid:string_to_usr(<<"user@">>)),
    ?assertEqual({<<"user">>, <<"server">>, <<"">>},
                 jid:string_to_usr(<<"user@server">>)).

string_to_usr_slash_test() ->
    ?assertEqual(error, jid:string_to_usr(<<"/">>)),
    ?assertEqual(error, jid:string_to_usr(<<"/resource">>)),
    ?assertEqual(error, jid:string_to_usr(<<"server/">>)),
    ?assertEqual({<<"">>, <<"server">>, <<"resource">>},
                 jid:string_to_usr(<<"server/resource">>)).

string_to_usr_amp_slash_test() ->
    ?assertEqual(error, jid:string_to_usr(<<"@/">>)),
    ?assertEqual(error, jid:string_to_usr(<<"@/resource">>)),
    ?assertEqual(error, jid:string_to_usr(<<"@server/">>)),
    ?assertEqual(error, jid:string_to_usr(<<"@server/resource">>)),
    ?assertEqual(error, jid:string_to_usr(<<"user@/">>)),
    ?assertEqual(error, jid:string_to_usr(<<"user@server/">>)),
    ?assertEqual(error, jid:string_to_usr(<<"user@/resource">>)),
    ?assertEqual({<<"user">>, <<"server">>, <<"resource">>},
                 jid:string_to_usr(<<"user@server/resource">>)).

string_to_usr_double_amp_test() ->
    ?assertEqual(error, jid:string_to_usr(<<"@@">>)),
    ?assertEqual(error, jid:string_to_usr(<<"@@resource">>)),
    ?assertEqual(error, jid:string_to_usr(<<"@server@">>)),
    ?assertEqual(error, jid:string_to_usr(<<"@server@resource">>)),
    ?assertEqual(error, jid:string_to_usr(<<"user@@">>)),
    ?assertEqual(error, jid:string_to_usr(<<"user@server@">>)),
    ?assertEqual(error, jid:string_to_usr(<<"user@@resource">>)),
    ?assertEqual(error, jid:string_to_usr(<<"user@server@resource">>)).

string_to_usr_resource_test() ->
    lists:foreach(
      fun(R) ->
              ?assertEqual({<<"">>, <<"server">>, R},
                           jid:string_to_usr(<<"server/", R/binary>>)),
              ?assertEqual({<<"user">>, <<"server">>, R},
                           jid:string_to_usr(<<"user@server/", R/binary>>))
      end,
      [list_to_binary(X) || X <- permute([$@, $/, $x, $y, $z])]).

-endif.
