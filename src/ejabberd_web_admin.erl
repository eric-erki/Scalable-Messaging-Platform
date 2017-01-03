%%%----------------------------------------------------------------------
%%% File    : ejabberd_web_admin.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Administration web interface
%%% Created :  9 Apr 2004 by Alexey Shchepin <alexey@process-one.net>
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
%%%----------------------------------------------------------------------

%%%% definitions

-module(ejabberd_web_admin).

-behaviour(ejabberd_config).

-author('alexey@process-one.net').

-export([process/2, list_users/4,
	 list_users_in_diapason/4, pretty_print_xml/1,
	 term_to_id/1, opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("ejabberd_http.hrl").

-include("ejabberd_web_admin.hrl").

-define(INPUTATTRS(Type, Name, Value, Attrs),
	?XA(<<"input">>,
	    (Attrs ++
	       [{<<"type">>, Type}, {<<"name">>, Name},
		{<<"value">>, Value}]))).

%%%==================================
%%%% get_acl_access

%% @spec (Path::[string()], Method) -> {HostOfRule, [AccessRule]}
%% where Method = 'GET' | 'POST'

%% All accounts can access those URLs
get_acl_rule([], _) -> {<<"localhost">>, [all]};
get_acl_rule([<<"style.css">>], _) ->
    {<<"localhost">>, [all]};
get_acl_rule([<<"logo.png">>], _) ->
    {<<"localhost">>, [all]};
get_acl_rule([<<"logo-fill.png">>], _) ->
    {<<"localhost">>, [all]};
get_acl_rule([<<"favicon.ico">>], _) ->
    {<<"localhost">>, [all]};
get_acl_rule([<<"additions.js">>], _) ->
    {<<"localhost">>, [all]};
%% This page only displays vhosts that the user is admin:
get_acl_rule([<<"vhosts">>], _) ->
    {<<"localhost">>, [all]};
%% The pages of a vhost are only accesible if the user is admin of that vhost:
get_acl_rule([<<"server">>, VHost | _RPath], Method)
    when Method =:= 'GET' orelse Method =:= 'HEAD' ->
    AC = gen_mod:get_module_opt(VHost, ejabberd_web_admin,
				access, fun(A) -> A end, configure),
    ACR = gen_mod:get_module_opt(VHost, ejabberd_web_admin,
				 access_readonly, fun(A) -> A end, webadmin_view),
    {VHost, [AC, ACR]};
get_acl_rule([<<"server">>, VHost | _RPath], 'POST') ->
    AC = gen_mod:get_module_opt(VHost, ejabberd_web_admin,
				access, fun(A) -> A end, configure),
    {VHost, [AC]};
%% Default rule: only global admins can access any other random page
get_acl_rule(_RPath, Method)
    when Method =:= 'GET' orelse Method =:= 'HEAD' ->
    AC = gen_mod:get_module_opt(global, ejabberd_web_admin,
				access, fun(A) -> A end, configure),
    ACR = gen_mod:get_module_opt(global, ejabberd_web_admin,
				 access_readonly, fun(A) -> A end, webadmin_view),
    {global, [AC, ACR]};
get_acl_rule(_RPath, 'POST') ->
    AC = gen_mod:get_module_opt(global, ejabberd_web_admin,
				access, fun(A) -> A end, configure),
    {global, [AC]}.

%%%==================================
%%%% Menu Items Access

get_jid(Auth, HostHTTP, Method) ->
    case get_auth_admin(Auth, HostHTTP, [], Method) of
      {ok, {User, Server}} ->
	  jid:make(User, Server, <<"">>);
      {unauthorized, Error} ->
	  ?ERROR_MSG("Unauthorized ~p: ~p", [Auth, Error]),
	  throw({unauthorized, Auth})
    end.

get_menu_items(global, cluster, Lang, JID) ->
    {Base, _, Items} = make_server_menu([], [], Lang, JID),
    lists:map(fun ({URI, Name}) ->
		      {<<Base/binary, URI/binary, "/">>, Name};
		  ({URI, Name, _SubMenu}) ->
		      {<<Base/binary, URI/binary, "/">>, Name}
	      end,
	      Items);
get_menu_items(Host, cluster, Lang, JID) ->
    {Base, _, Items} = make_host_menu(Host, [], Lang, JID),
    lists:map(fun ({URI, Name}) ->
		      {<<Base/binary, URI/binary, "/">>, Name};
		  ({URI, Name, _SubMenu}) ->
		      {<<Base/binary, URI/binary, "/">>, Name}
	      end,
	      Items).

%% get_menu_items(Host, Node, Lang, JID) ->
%%     {Base, _, Items} = make_host_node_menu(Host, Node, Lang, JID),
%%     lists:map(
%% 	fun({URI, Name}) ->
%% 		{Base++URI++"/", Name};
%% 	   ({URI, Name, _SubMenu}) ->
%% 		{Base++URI++"/", Name}
%% 	end,
%% 	Items
%%     ).

is_allowed_path(BasePath, {Path, _}, JID) ->
    is_allowed_path(BasePath ++ [Path], JID);
is_allowed_path(BasePath, {Path, _, _}, JID) ->
    is_allowed_path(BasePath ++ [Path], JID).

is_allowed_path([<<"admin">> | Path], JID) ->
    is_allowed_path(Path, JID);
is_allowed_path(Path, JID) ->
    {HostOfRule, AccessRule} = get_acl_rule(Path, 'GET'),
    acl:any_rules_allowed(HostOfRule, AccessRule, JID).

%% @spec(Path) -> URL
%% where Path = [string()]
%%       URL = string()
%% Convert ["admin", "user", "tom"] -> "/admin/user/tom/"
%%path_to_url(Path) ->
%%    "/" ++ string:join(Path, "/") ++ "/".

%% @spec(URL) -> Path
%% where Path = [string()]
%%       URL = string()
%% Convert "admin/user/tom" -> ["admin", "user", "tom"]
url_to_path(URL) -> str:tokens(URL, <<"/">>).

%%%==================================
%%%% process/2

process([<<"doc">>, LocalFile], _Request) ->
    DocPath = case os:getenv("EJABBERD_DOC_PATH") of
		P when is_list(P) -> P;
		false -> <<"/share/doc/ejabberd/">>
	      end,
    FileName = filename:join(DocPath, LocalFile),
    case file:read_file(FileName) of
      {ok, FileContents} ->
	  ?DEBUG("Delivering content.", []),
	  {200, [{<<"Server">>, <<"ejabberd">>}], FileContents};
      {error, Error} ->
	  Help = <<" ", FileName/binary,
		   " - Try to specify the path to ejabberd "
		   "documentation with the environment variable "
		   "EJABBERD_DOC_PATH. Check the ejabberd "
		   "Guide for more information.">>,
	  ?INFO_MSG("Problem '~p' accessing the local Guide file ~s", [Error, Help]),
	  case Error of
	    eacces -> {403, [], <<"Forbidden", Help/binary>>};
	    enoent -> {307, [{<<"Location">>, <<"http://docs.ejabberd.im/admin/guide/configuration/">>}], <<"Not found", Help/binary>>};
	    _Else ->
		{404, [], <<(iolist_to_binary(atom_to_list(Error)))/binary, Help/binary>>}
	  end
    end;
process([<<"server">>, SHost | RPath] = Path,
	#request{auth = Auth, lang = Lang, host = HostHTTP,
		 method = Method} =
	    Request) ->
    Host = jid:nameprep(SHost),
    case lists:member(Host, ?MYHOSTS) of
      true ->
	  case get_auth_admin(Auth, HostHTTP, Path, Method) of
	    {ok, {User, Server}} ->
		AJID = get_jid(Auth, HostHTTP, Method),
		process_admin(Host,
			      Request#request{path = RPath,
					      auth = {auth_jid, Auth, AJID},
					      us = {User, Server}});
	    {unauthorized, <<"no-auth-provided">>} ->
		{401,
		 [{<<"WWW-Authenticate">>,
		   <<"basic realm=\"ejabberd\"">>}],
		 ejabberd_web:make_xhtml([?XCT(<<"h1">>,
					       <<"Unauthorized">>)])};
	    {unauthorized, Error} ->
		{BadUser, _BadPass} = Auth,
		{IPT, _Port} = Request#request.ip,
		IPS = ejabberd_config:may_hide_data(jlib:ip_to_list(IPT)),
		?WARNING_MSG("Access of ~p from ~p failed with error: ~p",
			     [BadUser, IPS, Error]),
		{401,
		 [{<<"WWW-Authenticate">>,
		   <<"basic realm=\"auth error, retry login "
		     "to ejabberd\"">>}],
		 ejabberd_web:make_xhtml([?XCT(<<"h1">>,
					       <<"Unauthorized">>)])}
	  end;
      false -> ejabberd_web:error(not_found)
    end;
process(RPath,
	#request{auth = Auth, lang = Lang, host = HostHTTP,
		 method = Method} =
	    Request) ->
    case get_auth_admin(Auth, HostHTTP, RPath, Method) of
      {ok, {User, Server}} ->
	  AJID = get_jid(Auth, HostHTTP, Method),
	  process_admin(global,
			Request#request{path = RPath,
					auth = {auth_jid, Auth, AJID},
					us = {User, Server}});
      {unauthorized, <<"no-auth-provided">>} ->
	  {401,
	   [{<<"WWW-Authenticate">>,
	     <<"basic realm=\"ejabberd\"">>}],
	   ejabberd_web:make_xhtml([?XCT(<<"h1">>,
					 <<"Unauthorized">>)])};
      {unauthorized, Error} ->
	  {BadUser, _BadPass} = Auth,
	  {IPT, _Port} = Request#request.ip,
	  IPS = ejabberd_config:may_hide_data(jlib:ip_to_list(IPT)),
	  ?WARNING_MSG("Access of ~p from ~p failed with error: ~p",
		       [BadUser, IPS, Error]),
	  {401,
	   [{<<"WWW-Authenticate">>,
	     <<"basic realm=\"auth error, retry login "
	       "to ejabberd\"">>}],
	   ejabberd_web:make_xhtml([?XCT(<<"h1">>,
					 <<"Unauthorized">>)])}
    end.

get_auth_admin(Auth, HostHTTP, RPath, Method) ->
    case Auth of
      {SJID, Pass} ->
	  {HostOfRule, AccessRule} = get_acl_rule(RPath, Method),
	  case jid:from_string(SJID) of
	    error -> {unauthorized, <<"badformed-jid">>};
	    #jid{user = <<"">>, server = User} ->
		get_auth_account(HostOfRule, AccessRule, User, HostHTTP,
				 Pass);
	    #jid{user = User, server = Server} ->
		get_auth_account(HostOfRule, AccessRule, User, Server,
				 Pass)
	  end;
      undefined -> {unauthorized, <<"no-auth-provided">>}
    end.

get_auth_account(HostOfRule, AccessRule, User, Server,
		 Pass) ->
    case ejabberd_auth:check_password(User, <<"">>, Server, Pass) of
      true ->
	  case acl:any_rules_allowed(HostOfRule, AccessRule,
			    jid:make(User, Server, <<"">>))
	      of
	    false -> {unauthorized, <<"unprivileged-account">>};
	    true -> {ok, {User, Server}}
	  end;
      false ->
	  case ejabberd_auth:is_user_exists(User, Server) of
	    true -> {unauthorized, <<"bad-password">>};
	    false -> {unauthorized, <<"inexistent-account">>}
	  end
    end.

%%%==================================
%%%% make_xhtml

make_xhtml(Els, Host, Lang, JID) ->
    make_xhtml(Els, Host, cluster, Lang, JID).

%% @spec (Els, Host, Node, Lang, JID) -> {200, [html], xmlelement()}
%% where Host = global | string()
%%       Node = cluster | atom()
%%       JID = jid()
make_xhtml(Els, Host, Node, Lang, JID) ->
    Base = get_base_path(Host, cluster),
    MenuItems = make_navigation(Host, Node, Lang, JID),
    {200, [html],
     #xmlel{name = <<"html">>,
	    attrs =
		[{<<"xmlns">>, <<"http://www.w3.org/1999/xhtml">>},
		 {<<"xml:lang">>, Lang}, {<<"lang">>, Lang}]++direction(Lang),
	    children =
		[#xmlel{name = <<"head">>, attrs = [],
			children =
			    [?XCT(<<"title">>, <<"ejabberd Web Admin">>),
			     #xmlel{name = <<"meta">>,
				    attrs =
					[{<<"http-equiv">>, <<"Content-Type">>},
					 {<<"content">>,
					  <<"text/html; charset=utf-8">>}],
				    children = []},
			     #xmlel{name = <<"script">>,
				    attrs =
					[{<<"src">>,
					  <<Base/binary, "/additions.js">>},
					 {<<"type">>, <<"text/javascript">>}],
				    children = [?C(<<" ">>)]},
			     #xmlel{name = <<"link">>,
				    attrs =
					[{<<"href">>,
					  <<Base/binary, "favicon.ico">>},
					 {<<"type">>, <<"image/x-icon">>},
					 {<<"rel">>, <<"shortcut icon">>}],
				    children = []},
			     #xmlel{name = <<"link">>,
				    attrs =
					[{<<"href">>,
					  <<Base/binary, "style.css">>},
					 {<<"type">>, <<"text/css">>},
					 {<<"rel">>, <<"stylesheet">>}],
				    children = []}]},
		 ?XE(<<"body">>,
		     [?XAE(<<"div">>, [{<<"id">>, <<"container">>}],
			   [?XAE(<<"div">>, [{<<"id">>, <<"header">>}],
				 [?XE(<<"h1">>,
				      [?ACT(<<"/admin/">>,
					    <<"ejabberd Web Admin">>)])]),
			    ?XAE(<<"div">>, [{<<"id">>, <<"navigation">>}],
				 [?XE(<<"ul">>, MenuItems)]),
			    ?XAE(<<"div">>, [{<<"id">>, <<"content">>}], Els),
			    ?XAE(<<"div">>, [{<<"id">>, <<"clearcopyright">>}],
				 [{xmlcdata, <<"">>}])]),
		      ?XAE(<<"div">>, [{<<"id">>, <<"copyrightouter">>}],
			   [?XAE(<<"div">>, [{<<"id">>, <<"copyright">>}],
				 [?XE(<<"p">>,
				  [?AC(<<"https://www.ejabberd.im/">>, <<"ejabberd">>),
				   ?C(<<" (c) 2002-2017 ">>),
				   ?AC(<<"https://www.process-one.net/">>, <<"ProcessOne, leader in messaging and push solutions">>)]
                                 )])])])]}}.

direction(ltr) -> [{<<"dir">>, <<"ltr">>}];
direction(<<"he">>) -> [{<<"dir">>, <<"rtl">>}];
direction(_) -> [].

get_base_path(global, cluster) -> <<"/admin/">>;
get_base_path(Host, cluster) ->
    <<"/admin/server/", Host/binary, "/">>;
get_base_path(global, Node) ->
    <<"/admin/node/",
      (iolist_to_binary(atom_to_list(Node)))/binary, "/">>;
get_base_path(Host, Node) ->
    <<"/admin/server/", Host/binary, "/node/",
      (iolist_to_binary(atom_to_list(Node)))/binary, "/">>.

%%%==================================
%%%% css & images

additions_js() ->
    <<"\nfunction selectAll() {\n  for(i=0;i<documen"
      "t.forms[0].elements.length;i++)\n  { "
      "var e = document.forms[0].elements[i];\n "
      "   if(e.type == 'checkbox')\n    { e.checked "
      "= true; }\n  }\n}\nfunction unSelectAll() "
      "{\n  for(i=0;i<document.forms[0].elements.len"
      "gth;i++)\n  { var e = document.forms[0].eleme"
      "nts[i];\n    if(e.type == 'checkbox')\n "
      "   { e.checked = false; }\n  }\n}\n">>.

css(Host) ->
    Base = get_base_path(Host, cluster),
    <<"html,body {\n"
    "  margin: 0;\n"
    "  padding: 0;\n"
    "  height: 100%;\n"
    "  background: #f9f9f9;\n"
    "  font-family: sans-serif;\n"
    "}\n"
    "body {\n"
    "  min-width: 990px;\n"
    "}\n"
    "a {\n"
    "  text-decoration: none;\n"
    "  color: #3eaffa;\n"
    "}\n"
    "a:hover,\n"
    "a:active {\n"
    "  text-decoration: underline;\n"
    "}\n"
    "#container {\n"
    "  position: relative;\n"
    "  padding: 0;\n"
    "  margin: 0 auto;\n"
    "  max-width: 1280px;\n"
    "  min-height: 100%;\n"
    "  height: 100%;\n"
    "  margin-bottom: -30px;\n"
    "  z-index: 1;\n"
    "}\n"
    "html>body #container {\n"
    "  height: auto;\n"
    "}\n"
    "#header h1 {\n"
    "  width: 100%;\n"
    "  height: 50px;\n"
    "  padding: 0;\n"
    "  margin: 0;\n"
    "  background-color: #49cbc1;\n"
    "}\n"
    "#header h1 a {\n"
    "  position: absolute;\n"
    "  top: 0;\n"
    "  left: 0;\n"
    "  width: 100%;\n"
    "  height: 50px;\n"
    "  padding: 0;\n"
    "  margin: 0;\n"
    "  background: url('",Base/binary,"logo.png') 10px center no-repeat transparent;\n"
    "  background-size: auto 25px;\n"
    "  display: block;\n"
    "  text-indent: -9999px;\n"
    "}\n"
    "#clearcopyright {\n"
    "  display: block;\n"
    "  width: 100%;\n"
    "  height: 30px;\n"
    "}\n"
    "#copyrightouter {\n"
    "  position: relative;\n"
    "  display: table;\n"
    "  width: 100%;\n"
    "  height: 30px;\n"
    "  z-index: 2;\n"
    "}\n"
    "#copyright {\n"
    "  display: table-cell;\n"
    "  vertical-align: bottom;\n"
    "  width: 100%;\n"
    "  height: 30px;\n"
    "}\n"
    "#copyright a {\n"
    "  font-weight: bold;\n"
    "  color: #fff;\n"
    "}\n"
    "#copyright p {\n"
    "  margin-left: 0;\n"
    "  margin-right: 0;\n"
    "  margin-top: 5px;\n"
    "  margin-bottom: 0;\n"
    "  padding-left: 0;\n"
    "  padding-right: 0;\n"
    "  padding-top: 5px;\n"
    "  padding-bottom: 5px;\n"
    "  width: 100%;\n"
    "  color: #fff;\n"
    "  background-color: #30353E;\n"
    "  font-size: 0.75em;\n"
    "  text-align: center;\n"
    "}\n"
    "#navigation {\n"
    "  display: inline-block;\n"
    "  vertical-align: top;\n"
    "  width: 30%;\n"
    "}\n"
    "#navigation ul {\n"
    "  padding: 0;\n"
    "  margin: 0;\n"
    "  width: 90%;\n"
    "  background: #fff;\n"
    "}\n"
    "#navigation ul li {\n"
    "  list-style: none;\n"
    "  margin: 0;\n"
    "\n"
    "  border-bottom: 1px solid #f9f9f9;\n"
    "  text-align: left;\n"
    "}\n"
    "#navigation ul li a {\n"
    "  margin: 0;\n"
    "  display: inline-block;\n"
    "  padding: 10px;\n"
    "  color: #333;\n"
    "}\n"
    "ul li #navhead a, ul li #navheadsub a, ul li #navheadsubsub a {\n"
    "  font-size: 1.5em;\n"
    "  color: inherit;\n"
    "}\n"
    "#navitemsub {\n"
    "  border-left: 0.5em solid #424a55;\n"
    "}\n"
    "#navitemsubsub {\n"
    "  border-left: 2em solid #424a55;\n"
    "}\n"
    "#navheadsub,\n"
    "#navheadsubsub {\n"
    "  padding-left: 0.5em;\n"
    "}\n"
    "#navhead,\n"
    "#navheadsub,\n"
    "#navheadsubsub {\n"
    "  border-top: 3px solid #49cbc1;\n"
    "  background: #424a55;\n"
    "  color: #fff;\n"
    "}\n"
    "#lastactivity li {\n"
    "  padding: 2px;\n"
    "  margin-bottom: -1px;\n"
    "}\n"
    "thead tr td {\n"
    "  background: #3eaffa;\n"
    "  color: #fff;\n"
    "}\n"
    "td.copy {\n"
    "  text-align: center;\n"
    "}\n"
    "tr.head {\n"
    "  color: #fff;\n"
    "  background-color: #3b547a;\n"
    "  text-align: center;\n"
    "}\n"
    "tr.oddraw {\n"
    "  color: #412c75;\n"
    "  background-color: #ccd4df;\n"
    "  text-align: center;\n"
    "}\n"
    "tr.evenraw {\n"
    "  color: #412c75;\n"
    "  background-color: #dbe0e8;\n"
    "  text-align: center;\n"
    "}\n"
    "td.leftheader {\n"
    "  color: #412c75;\n"
    "  background-color: #ccccc1;\n"
    "  padding-left: 5px;\n"
    "  padding-top: 2px;\n"
    "  padding-bottom: 2px;\n"
    "  margin-top: 0px;\n"
    "  margin-bottom: 0px;\n"
    "}\n"
    "td.leftcontent {\n"
    "  color: #000044;\n"
    "  background-color: #e6e6df;\n"
    "  padding-left: 5px;\n"
    "  padding-right: 5px;\n"
    "  padding-top: 2px;\n"
    "  padding-bottom: 2px;\n"
    "  margin-top: 0px;\n"
    "  margin-bottom: 0px;\n"
    "}\n"
    "td.rightcontent {\n"
    "  color: #000044;\n"
    "  text-align: justify;\n"
    "  padding-left: 10px;\n"
    "  padding-right: 10px;\n"
    "  padding-bottom: 5px;\n"
    "}\n"
    "\n"
    "h1 {\n"
    "  color: #000044;\n"
    "  padding-top: 2px;\n"
    "  padding-bottom: 2px;\n"
    "  margin-top: 0px;\n"
    "  margin-bottom: 0px;\n"
    "}\n"
    "h2 {\n"
    "  color: #000044;\n"
    "  text-align: center;\n"
    "  padding-top: 2px;\n"
    "  padding-bottom: 2px;\n"
    "  margin-top: 0px;\n"
    "  margin-bottom: 0px;\n"
    "}\n"
    "h3 {\n"
    "  color: #000044;\n"
    "  text-align: left;\n"
    "  padding-top: 20px;\n"
    "  padding-bottom: 2px;\n"
    "  margin-top: 0px;\n"
    "  margin-bottom: 0px;\n"
    "}\n"
    "#content ul {\n"
    "  padding-left: 1.1em;\n"
    "  margin-top: 1em;\n"
    "}\n"
    "#content ul li {\n"
    "  list-style-type: disc;\n"
    "  padding: 5px;\n"
    "}\n"
    "#content ul.nolistyle>li {\n"
    "  list-style-type: none;\n"
    "}\n"
    "#content {\n"
    "  display: inline-block;\n"
    "  vertical-align: top;\n"
    "  padding-top: 25px;\n"
    "  width: 70%;\n"
    "}\n"
    "div.guidelink,\n"
    "p[dir=ltr] {\n"
    "  display: inline-block;\n"
    "  float: right;\n"
    "\n"
    "  margin: 0;\n"
    "  margin-right: 1em;\n"
    "}\n"
    "div.guidelink a,\n"
    "p[dir=ltr] a {\n"
    "  display: inline-block;\n"
    "  border-radius: 3px;\n"
    "  padding: 3px;\n"
    "\n"
    "  background: #3eaffa;\n"
    "\n"
    "  text-transform: uppercase;\n"
    "  font-size: 0.75em;\n"
    "  color: #fff;\n"
    "}\n"
    "table {\n"
    "  margin-top: 1em;\n"
    "}\n"
    "table tr td {\n"
    "  padding: 0.5em;\n"
    "}\n"
    "table tr:nth-child(odd) {\n"
    "  background: #fff;\n"
    "}\n"
    "table.withtextareas>tbody>tr>td {\n"
    "  vertical-align: top;\n"
    "}\n"
    "textarea {\n"
    "  margin-bottom: 1em;\n"
    "}\n"
    "input,\n"
    "select {\n"
    "  font-size: 1em;\n"
    "}\n"
    "p.result {\n"
    "  border: 1px;\n"
    "  border-style: dashed;\n"
    "  border-color: #FE8A02;\n"
    "  padding: 1em;\n"
    "  margin-right: 1em;\n"
    "  background: #FFE3C9;\n"
    "}\n"
    "*.alignright {\n"
    "  text-align: right;\n"
    "}">>.

favicon() ->
    jlib:decode_base64(<<"AAABAAEAEBAAAAEAIAAoBQAAFgAAACgAAAAQAAAAIAAAAAEAIAAAAAAAAAUAAAAAAAAAAAAAAAAAAAAAAAAAAAA1AwMAQwAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAwMARQUEA+oFAwCOBAQAaAQEAGkEBABpBAQAaQQEAGoFAgBcBAAAOQAAAAoAAAAAAAAAAAAAAAAAAAAAAAAAAAMDAEIHBgX/BwYF/wcGBf8HBgX/BwYF/wcGBf8HBgX/BwYF/wUFA/wEBAHOBQICXgAAAAAAAAAAAAAAAAAAAAADAwBCBwYF/wcGBf8HBgX/BwYF/wcGBf8HBgX/BwYF/wcGBf8HBgX/BwYF/wcGBf8DAwCUAAAABwAAAAAAAAAAAwMAQgcGBf8HBgX/BwYF/wcGBf8FBQPMBAAAaAQAAD8DAwNOAwMDlgUFA/QHBgX/BwYF/wQEAHkAAAAAAAAAAAMDAEIHBgX/BwYF/wcGBf8EBAGeAAAACAAAAAAAAAASAAAABQAAAAAFBQGxBwYF/wcGBf8FBAPvAAAAKAAAAAADAwBCBwYF/wcGBf8EBAHPAAAADQAAACEFBQGuBQQD8AUEAeEFBQGuBQQB9QcGBf8HBgX/BwYF/wQEAH8AAAAAAwMAQgcGBf8HBgX/BgQAbwAAAAADAwOXBQQB3gUFAdgFBQHZBQQB3QUFAdYFBAHhBQUD/gcGBf8EBAK8AAAAAAMDAEIHBgX/BwYF/wQAAD0AAAAAAAAABQAAAAEAAAABAAAAAQAAAAEAAAAFAAAAEQUFArwKBgX/BQMDxQAAAAADAwBCBwYF/wcGBf8DAwBKAAAAAwYDAFAGAwBVBgMAVAYDAFQFAgJZAAAALwAAAAAFBQGuCgYF/wUDA8QAAAAAAAAAKwUEA/QHBgX/AwMDlgAAAAAFAwOIBwYF/wcGBf8HBgX/BQQB5wAAADMAAAAWBQUD5wcGBf8EBAGbAAAAAAAAAAYFBAG9BwYF/wUFA/EDAABAAAAAAAMDA1QDAwOYBQUAhQAAACQAAAAABAQBnQcGBf8HBgX/AwMATQAAAAAAAAAAAwAAQwUFA/oHBgX/BQQB5QYDA1UAAAAAAAAAAAAAAAAAAAAXAwMAlwcGBf8HBgX/BQUBtQAAAAcAAAAAAAAAAAAAAAAEBABzBQUD/gcGBf8HBgX/BQMDyQQEAZwGBAGqBQQB5AcGBf8HBgX/BAQB0QAAACEAAAAAAAAAAAAAAAAAAAAAAAAAAAUFAmQFBAHlBwYF/wcGBf8HBgX/BwYF/wcGBf8FBQP+BQUBsAAAACAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAHwUFA40FBAHrBwYF/wUFA/4FAwPGBgMAUgAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA==">>).

logo() ->
    jlib:decode_base64(<<"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">>).

logo_fill() ->
    jlib:decode_base64(<<"iVBORw0KGgoAAAANSUhEUgAAAAYAAAA3BAMAAADdxCZzA"
		    "AAAAXNSR0IArs4c6QAAAB5QTFRF1nYO/ooC/o4O/pIS/p"
		    "4q/q5K/rpq/sqM/tam/ubGzn/S/AAAAEFJREFUCNdlw0s"
		    "RwCAQBUE+gSRHLGABC1jAAhbWAhZwC+88XdXOXb4UlFAr"
		    "SmwN5ekdJY2BkudEec1QvrVQ/r3xOlK9HsTvertmAAAAA"
		    "ElFTkSuQmCC">>).

%%%==================================
%%%% process_admin

process_admin(global,
	      #request{path = [], auth = {_, _, AJID},
		       lang = Lang}) ->
    make_xhtml((?H1GL((?T(<<"Administration">>)), <<"">>,
		      <<"Contents">>))
		 ++
		 [?XE(<<"ul">>,
		      [?LI([?ACT(MIU, MIN)])
		       || {MIU, MIN}
			      <- get_menu_items(global, cluster, Lang, AJID)])],
	       global, Lang, AJID);
process_admin(Host,
	      #request{path = [], auth = {_, _Auth, AJID},
		       lang = Lang}) ->
    make_xhtml([?XCT(<<"h1">>, <<"Administration">>),
		?XE(<<"ul">>,
		    [?LI([?ACT(MIU, MIN)])
		     || {MIU, MIN}
			    <- get_menu_items(Host, cluster, Lang, AJID)])],
	       Host, Lang, AJID);
process_admin(Host,
	      #request{path = [<<"style.css">>]}) ->
    {200,
     [{<<"Content-Type">>, <<"text/css">>}, last_modified(),
      cache_control_public()],
     css(Host)};
process_admin(_Host,
	      #request{path = [<<"favicon.ico">>]}) ->
    {200,
     [{<<"Content-Type">>, <<"image/x-icon">>},
      last_modified(), cache_control_public()],
     favicon()};
process_admin(_Host,
	      #request{path = [<<"logo.png">>]}) ->
    {200,
     [{<<"Content-Type">>, <<"image/png">>}, last_modified(),
      cache_control_public()],
     logo()};
process_admin(_Host,
	      #request{path = [<<"logo-fill.png">>]}) ->
    {200,
     [{<<"Content-Type">>, <<"image/png">>}, last_modified(),
      cache_control_public()],
     logo_fill()};
process_admin(_Host,
	      #request{path = [<<"additions.js">>]}) ->
    {200,
     [{<<"Content-Type">>, <<"text/javascript">>},
      last_modified(), cache_control_public()],
     additions_js()};
process_admin(Host,
	      #request{path = [<<"acls-raw">>], q = Query,
		       auth = {_, _Auth, AJID}, lang = Lang}) ->
    Res = case lists:keysearch(<<"acls">>, 1, Query) of
	    {value, {_, String}} ->
		case erl_scan:string(binary_to_list(String)) of
		  {ok, Tokens, _} ->
		      case erl_parse:parse_term(Tokens) of
			{ok, NewACLs} ->
                            acl:add_list(Host, NewACLs, true);
			_ -> error
		      end;
		  _ -> error
		end;
	    _ -> nothing
	  end,
    ACLs = lists:keysort(2,
			 ets:select(acl,
				    [{{acl, {'$1', Host}, '$2'}, [],
				      [{{acl, '$1', '$2'}}]}])),
    {NumLines, ACLsP} = term_to_paragraph(ACLs, 80),
    make_xhtml((?H1GL((?T(<<"Access Control Lists">>)),
		      <<"acldefinition">>, <<"ACL Definition">>))
		 ++
		 case Res of
		   ok -> [?XREST(<<"Submitted">>)];
		   error -> [?XREST(<<"Bad format">>)];
		   nothing -> []
		 end
		   ++
		   [?XAE(<<"form">>,
			 [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}]++direction(ltr),
			 [?TEXTAREA(<<"acls">>,
				    (iolist_to_binary(integer_to_list(lists:max([16,
										 NumLines])))),
				    <<"80">>, <<(iolist_to_binary(ACLsP))/binary, ".">>),
			  ?BR,
			  ?INPUTT(<<"submit">>, <<"submit">>, <<"Submit">>)])],
	       Host, Lang, AJID);
process_admin(Host,
	      #request{method = Method, path = [<<"acls">>],
		       auth = {_, _Auth, AJID}, q = Query, lang = Lang}) ->
    ?DEBUG("query: ~p", [Query]),
    Res = case Method of
	    'POST' ->
		case catch acl_parse_query(Host, Query) of
		  {'EXIT', _} -> error;
		  NewACLs ->
		      ?INFO_MSG("NewACLs at ~s: ~p", [Host, NewACLs]),
		      acl:add_list(Host, NewACLs, true)
		end;
	    _ -> nothing
	  end,
    ACLs = lists:keysort(2,
			 ets:select(acl,
				    [{{acl, {'$1', Host}, '$2'}, [],
				      [{{acl, '$1', '$2'}}]}])),
    make_xhtml((?H1GL((?T(<<"Access Control Lists">>)),
		      <<"acldefinition">>, <<"ACL Definition">>))
		 ++
		 case Res of
		   ok -> [?XREST(<<"Submitted">>)];
		   error -> [?XREST(<<"Bad format">>)];
		   nothing -> []
		 end
		   ++
		   [?XAE(<<"p">>, direction(ltr), [?ACT(<<"../acls-raw/">>, <<"Raw">>)])] ++
		     [?XAE(<<"form">>,
			   [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}]++direction(ltr),
			   [acls_to_xhtml(ACLs), ?BR,
			    ?INPUTT(<<"submit">>, <<"delete">>,
				    <<"Delete Selected">>),
			    ?C(<<" ">>),
			    ?INPUTT(<<"submit">>, <<"submit">>,
				    <<"Submit">>)])],
	       Host, Lang, AJID);
process_admin(Host,
	      #request{path = [<<"access-raw">>],
		       auth = {_, _Auth, AJID}, q = Query, lang = Lang}) ->
    SetAccess = fun (Rs) ->
			mnesia:transaction(fun () ->
						   Os = mnesia:select(access,
								      [{{access,
									 {'$1',
									  Host},
									 '$2'},
									[],
									['$_']}]),
						   lists:foreach(fun (O) ->
									 mnesia:delete_object(O)
								 end,
								 Os),
						   lists:foreach(fun ({access,
								       Name,
								       Rules}) ->
									 mnesia:write({access,
										       {Name,
											Host},
										       Rules})
								 end,
								 Rs)
					   end)
		end,
    Res = case lists:keysearch(<<"access">>, 1, Query) of
	    {value, {_, String}} ->
		case erl_scan:string(binary_to_list(String)) of
		  {ok, Tokens, _} ->
		      case erl_parse:parse_term(Tokens) of
			{ok, Rs} ->
			    case SetAccess(Rs) of
			      {atomic, _} -> ok;
			      _ -> error
			    end;
			_ -> error
		      end;
		  _ -> error
		end;
	    _ -> nothing
	  end,
    Access = ets:select(access,
			[{{access, {'$1', Host}, '$2'}, [],
			  [{{access, '$1', '$2'}}]}]),
    {NumLines, AccessP} = term_to_paragraph(lists:keysort(2,Access), 80),
    make_xhtml((?H1GL((?T(<<"Access Rules">>)),
		      <<"accessrights">>, <<"Access Rights">>))
		 ++
		 case Res of
		   ok -> [?XREST(<<"Submitted">>)];
		   error -> [?XREST(<<"Bad format">>)];
		   nothing -> []
		 end
		   ++
		   [?XAE(<<"form">>,
			 [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}]++direction(ltr),
			 [?TEXTAREA(<<"access">>,
				    (iolist_to_binary(integer_to_list(lists:max([16,
										 NumLines])))),
				    <<"80">>, <<(iolist_to_binary(AccessP))/binary, ".">>),
			  ?BR,
			  ?INPUTT(<<"submit">>, <<"submit">>, <<"Submit">>)])],
	       Host, Lang, AJID);
process_admin(Host,
	      #request{method = Method, path = [<<"access">>],
		       q = Query, auth = {_, _Auth, AJID}, lang = Lang}) ->
    ?DEBUG("query: ~p", [Query]),
    Res = case Method of
	    'POST' ->
		case catch access_parse_query(Host, Query) of
		  {'EXIT', _} -> error;
		  ok -> ok
		end;
	    _ -> nothing
	  end,
    AccessRules = ets:select(access,
			     [{{access, {'$1', Host}, '$2'}, [],
			       [{{access, '$1', '$2'}}]}]),
    make_xhtml((?H1GL((?T(<<"Access Rules">>)),
		      <<"accessrights">>, <<"Access Rights">>))
		 ++
		 case Res of
		   ok -> [?XREST(<<"Submitted">>)];
		   error -> [?XREST(<<"Bad format">>)];
		   nothing -> []
		 end
		   ++
		   [?XAE(<<"p">>, direction(ltr), [?ACT(<<"../access-raw/">>, <<"Raw">>)])]
		     ++
		     [?XAE(<<"form">>,
			   [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}]++direction(ltr),
			   [access_rules_to_xhtml(AccessRules, Lang), ?BR,
			    ?INPUTT(<<"submit">>, <<"delete">>,
				    <<"Delete Selected">>)])],
	       Host, Lang, AJID);
process_admin(Host,
	      #request{path = [<<"access">>, SName], q = Query,
		       auth = {_, _Auth, AJID}, lang = Lang}) ->
    ?DEBUG("query: ~p", [Query]),
    Name = jlib:binary_to_atom(SName),
    Res = case lists:keysearch(<<"rules">>, 1, Query) of
	    {value, {_, String}} ->
		case parse_access_rule(String) of
		  {ok, Rs} ->
		      ejabberd_config:add_option({access, Name, Host},
							Rs),
		      ok;
		  _ -> error
		end;
	    _ -> nothing
	  end,
    Rules = case ejabberd_config:get_option(
                   {access, Name, Host}, fun(V) -> V end)
		of
	      undefined -> [];
	      Rs1 -> Rs1
	    end,
    make_xhtml([?XC(<<"h1">>,
		    list_to_binary(io_lib:format(
                                     ?T(<<"~s access rule configuration">>),
                                     [SName])))]
		 ++
		 case Res of
		   ok -> [?XREST(<<"Submitted">>)];
		   error -> [?XREST(<<"Bad format">>)];
		   nothing -> []
		 end
		   ++
		   [?XAE(<<"form">>,
			 [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
			 [access_rule_to_xhtml(Rules), ?BR,
			  ?INPUTT(<<"submit">>, <<"submit">>, <<"Submit">>)])],
	       Host, Lang, AJID);
process_admin(global,
	      #request{path = [<<"vhosts">>], auth = {_, _Auth, AJID},
		       lang = Lang}) ->
    Res = list_vhosts(Lang, AJID),
    make_xhtml((?H1GL((?T(<<"Virtual Hosts">>)),
		      <<"virtualhosting">>, <<"Virtual Hosting">>))
		 ++ Res,
	       global, Lang, AJID);
process_admin(Host,
	      #request{path = [<<"users">>], q = Query,
		       auth = {_, _Auth, AJID}, lang = Lang})
    when is_binary(Host) ->
    Res = list_users(Host, Query, Lang, fun url_func/1),
    make_xhtml([?XCT(<<"h1">>, <<"Users">>)] ++ Res, Host,
	       Lang, AJID);
process_admin(Host,
	      #request{path = [<<"users">>, Diap],
		       auth = {_, _Auth, AJID}, lang = Lang})
    when is_binary(Host) ->
    Res = list_users_in_diapason(Host, Diap, Lang,
				 fun url_func/1),
    make_xhtml([?XCT(<<"h1">>, <<"Users">>)] ++ Res, Host,
	       Lang, AJID);
process_admin(Host,
	      #request{path = [<<"online-users">>],
		       auth = {_, _Auth, AJID}, lang = Lang})
    when is_binary(Host) ->
    Res = list_online_users(Host, Lang),
    make_xhtml([?XCT(<<"h1">>, <<"Online Users">>)] ++ Res,
	       Host, Lang, AJID);
process_admin(Host,
	      #request{path = [<<"last-activity">>],
		       auth = {_, _Auth, AJID}, q = Query, lang = Lang})
    when is_binary(Host) ->
    ?DEBUG("query: ~p", [Query]),
    Month = case lists:keysearch(<<"period">>, 1, Query) of
	      {value, {_, Val}} -> Val;
	      _ -> <<"month">>
	    end,
    Res = case lists:keysearch(<<"ordinary">>, 1, Query) of
	    {value, {_, _}} ->
		list_last_activity(Host, Lang, false, Month);
	    _ -> list_last_activity(Host, Lang, true, Month)
	  end,
    make_xhtml([?XCT(<<"h1">>, <<"Users Last Activity">>)]
		 ++
		 [?XAE(<<"form">>,
		       [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
		       [?CT(<<"Period: ">>),
			?XAE(<<"select">>, [{<<"name">>, <<"period">>}],
			     (lists:map(fun ({O, V}) ->
						Sel = if O == Month ->
							     [{<<"selected">>,
							       <<"selected">>}];
							 true -> []
						      end,
						?XAC(<<"option">>,
						     (Sel ++
							[{<<"value">>, O}]),
						     V)
					end,
					[{<<"month">>, ?T(<<"Last month">>)},
					 {<<"year">>, ?T(<<"Last year">>)},
					 {<<"all">>,
					  ?T(<<"All activity">>)}]))),
			?C(<<" ">>),
			?INPUTT(<<"submit">>, <<"ordinary">>,
				<<"Show Ordinary Table">>),
			?C(<<" ">>),
			?INPUTT(<<"submit">>, <<"integral">>,
				<<"Show Integral Table">>)])]
		   ++ Res,
	       Host, Lang, AJID);
process_admin(Host,
	      #request{path = [<<"stats">>], auth = {_, _Auth, AJID},
		       lang = Lang}) ->
    Res = get_stats(Host, Lang),
    make_xhtml([?XCT(<<"h1">>, <<"Statistics">>)] ++ Res,
	       Host, Lang, AJID);
process_admin(Host,
	      #request{path = [<<"user">>, U],
		       auth = {_, _Auth, AJID}, q = Query, lang = Lang}) ->
    case ejabberd_auth:is_user_exists(U, Host) of
      true ->
	  Res = user_info(U, Host, Query, Lang),
	  make_xhtml(Res, Host, Lang, AJID);
      false ->
	  make_xhtml([?XCT(<<"h1">>, <<"Not Found">>)], Host,
		     Lang, AJID)
    end;
process_admin(Host,
	      #request{path = [<<"nodes">>], auth = {_, _Auth, AJID},
		       lang = Lang}) ->
    Res = get_nodes(Lang),
    make_xhtml(Res, Host, Lang, AJID);
process_admin(Host,
	      #request{path = [<<"node">>, SNode | NPath],
		       auth = {_, _Auth, AJID}, q = Query, lang = Lang}) ->
    case search_running_node(SNode) of
      false ->
	  make_xhtml([?XCT(<<"h1">>, <<"Node not found">>)], Host,
		     Lang, AJID);
      Node ->
	  Res = get_node(Host, Node, NPath, Query, Lang),
	  make_xhtml(Res, Host, Node, Lang, AJID)
    end;
%%%==================================
%%%% process_admin default case
process_admin(Host,
	      #request{lang = Lang, auth = {_, _Auth, AJID}} =
		  Request) ->
    {Hook, Opts} = case Host of
		     global -> {webadmin_page_main, [Request]};
		     Host -> {webadmin_page_host, [Host, Request]}
		   end,
    case ejabberd_hooks:run_fold(Hook, Host, [], Opts) of
      [] ->
	  setelement(1,
		     make_xhtml([?XC(<<"h1">>, <<"Not Found">>)], Host, Lang,
				AJID),
		     404);
      Res -> make_xhtml(Res, Host, Lang, AJID)
    end.

%%%==================================
%%%% acl

acls_to_xhtml(ACLs) ->
    ?XAE(<<"table">>, [],
	 [?XE(<<"tbody">>,
	      (lists:map(fun ({acl, Name, Spec} = ACL) ->
				 SName = iolist_to_binary(atom_to_list(Name)),
				 ID = term_to_id(ACL),
				 ?XE(<<"tr">>,
				     ([?XE(<<"td">>,
					   [?INPUT(<<"checkbox">>,
						   <<"selected">>, ID)]),
				       ?XC(<<"td">>, SName)]
					++ acl_spec_to_xhtml(ID, Spec)))
			 end,
			 ACLs)
		 ++
		 [?XE(<<"tr">>,
		      ([?X(<<"td">>),
			?XE(<<"td">>,
			    [?INPUT(<<"text">>, <<"namenew">>, <<"">>)])]
			 ++ acl_spec_to_xhtml(<<"new">>, {user, <<"">>})))]))]).

acl_spec_to_text({user, {U, S}}) ->
    {user, <<U/binary, "@", S/binary>>};
acl_spec_to_text({user, U}) -> {user, U};
acl_spec_to_text({server, S}) -> {server, S};
acl_spec_to_text({user_regexp, {RU, S}}) ->
    {user_regexp, <<RU/binary, "@", S/binary>>};
acl_spec_to_text({user_regexp, RU}) ->
    {user_regexp, RU};
acl_spec_to_text({server_regexp, RS}) ->
    {server_regexp, RS};
acl_spec_to_text({node_regexp, {RU, RS}}) ->
    {node_regexp, <<RU/binary, "@", RS/binary>>};
acl_spec_to_text({user_glob, {RU, S}}) ->
    {user_glob, <<RU/binary, "@", S/binary>>};
acl_spec_to_text({user_glob, RU}) -> {user_glob, RU};
acl_spec_to_text({server_glob, RS}) ->
    {server_glob, RS};
acl_spec_to_text({node_glob, {RU, RS}}) ->
    {node_glob, <<RU/binary, "@", RS/binary>>};
acl_spec_to_text(all) -> {all, <<"">>};
acl_spec_to_text(Spec) -> {raw, term_to_string(Spec)}.

acl_spec_to_xhtml(ID, Spec) ->
    {Type, Str} = acl_spec_to_text(Spec),
    [acl_spec_select(ID, Type), ?ACLINPUT(Str)].

acl_spec_select(ID, Opt) ->
    ?XE(<<"td">>,
	[?XAE(<<"select">>,
	      [{<<"name">>, <<"type", ID/binary>>}],
	      (lists:map(fun (O) ->
				 Sel = if O == Opt ->
					      [{<<"selected">>,
						<<"selected">>}];
					  true -> []
				       end,
				 ?XAC(<<"option">>,
				      (Sel ++
					 [{<<"value">>,
					   iolist_to_binary(atom_to_list(O))}]),
				      (iolist_to_binary(atom_to_list(O))))
			 end,
			 [user, server, user_regexp, server_regexp, node_regexp,
			  user_glob, server_glob, node_glob, all, raw])))]).

%% @spec (T::any()) -> StringLine::string()
term_to_string(T) ->
    StringParagraph =
	iolist_to_binary(io_lib:format("~1000000p", [T])),
    ejabberd_regexp:greplace(StringParagraph, <<"\\n ">>,
			     <<"">>).

%% @spec (T::any(), Cols::integer()) -> {NumLines::integer(), Paragraph::string()}
term_to_paragraph(T, Cols) ->
    P1 = erl_syntax:abstract(T),
    P2 = erl_prettypr:format(P1, [{paper, Cols}]),
    P3 = pretty_binaries(P2),
    Paragraph = list_to_binary(P3),
    FieldList = ejabberd_regexp:split(Paragraph, <<"\n">>),
    NumLines = length(FieldList),
    {NumLines, Paragraph}.

%% Convert a string like this:
%%   "[{acl, admin,\n  {user, <<98, 97, 100, 108, 111, 112>>,
%% into something like this:
%%   "[{acl,admin,{user,<<"badlop">>,
pretty_binaries(String) ->
    pretty_sentence(String, "").

pretty_sentence("", R) ->
    lists:reverse(R);
pretty_sentence([$<, $< | A], R) ->
    {A2, Binary} = pretty_binary(A, ""),
    pretty_sentence(A2, Binary ++ R);
pretty_sentence([Char | A], R) ->
    pretty_sentence(A, [Char | R]).

pretty_binary([$>, $> | A], "") ->
    {A, "\"\""};
pretty_binary([$>, $> | A], R) ->
    {A, io_lib:format("~p", [lists:reverse(R)])};
pretty_binary([$, | A], R) ->
    pretty_binary(A, R);
pretty_binary([32 | A], R) ->
    pretty_binary(A, R);
pretty_binary([$\n | A], R) ->
    pretty_binary(A, R);
pretty_binary([$\t | A], R) ->
    pretty_binary(A, R);
pretty_binary([Digit1, Digit2, Other | A], R) when (Other == $>) or (Other == $,) ->
    Integer = list_to_integer([Digit1, Digit2]),
    pretty_binary([Other | A], [Integer | R]);
pretty_binary([Digit1, Digit2, Digit3, Other | A], R) when (Other == $>) or (Other == $,) ->
    Integer = list_to_integer([Digit1, Digit2, Digit3]),
    pretty_binary([Other | A], [Integer | R]).

term_to_id(T) -> jlib:encode_base64((term_to_binary(T))).

acl_parse_query(Host, Query) ->
    ACLs = ets:select(acl,
		      [{{acl, {'$1', Host}, '$2'}, [],
			[{{acl, '$1', '$2'}}]}]),
    case lists:keysearch(<<"submit">>, 1, Query) of
      {value, _} -> acl_parse_submit(ACLs, Query);
      _ ->
	  case lists:keysearch(<<"delete">>, 1, Query) of
	    {value, _} -> acl_parse_delete(ACLs, Query)
	  end
    end.

acl_parse_submit(ACLs, Query) ->
    NewACLs = lists:map(fun ({acl, Name, Spec} = ACL) ->
				ID = term_to_id(ACL),
				case {lists:keysearch(<<"type", ID/binary>>, 1,
						      Query),
				      lists:keysearch(<<"value", ID/binary>>, 1,
						      Query)}
				    of
				  {{value, {_, T}}, {value, {_, V}}} ->
				      {Type, Str} = acl_spec_to_text(Spec),
				      case
					{iolist_to_binary(atom_to_list(Type)),
					 Str}
					  of
					{T, V} -> ACL;
					_ ->
					    NewSpec = string_to_spec(T, V),
					    {acl, Name, NewSpec}
				      end;
				  _ -> ACL
				end
			end,
			ACLs),
    NewACL = case {lists:keysearch(<<"namenew">>, 1, Query),
		   lists:keysearch(<<"typenew">>, 1, Query),
		   lists:keysearch(<<"valuenew">>, 1, Query)}
		 of
	       {{value, {_, <<"">>}}, _, _} -> [];
	       {{value, {_, N}}, {value, {_, T}}, {value, {_, V}}} ->
		   NewName = jlib:binary_to_atom(N),
		   NewSpec = string_to_spec(T, V),
		   [{acl, NewName, NewSpec}];
	       _ -> []
	     end,
    NewACLs ++ NewACL.

string_to_spec(<<"user">>, Val) ->
    string_to_spec2(user, Val);
string_to_spec(<<"server">>, Val) -> {server, Val};
string_to_spec(<<"user_regexp">>, Val) ->
    string_to_spec2(user_regexp, Val);
string_to_spec(<<"server_regexp">>, Val) ->
    {server_regexp, Val};
string_to_spec(<<"node_regexp">>, Val) ->
    #jid{luser = U, lserver = S, resource = <<"">>} =
	jid:from_string(Val),
    {node_regexp, U, S};
string_to_spec(<<"user_glob">>, Val) ->
    string_to_spec2(user_glob, Val);
string_to_spec(<<"server_glob">>, Val) ->
    {server_glob, Val};
string_to_spec(<<"node_glob">>, Val) ->
    #jid{luser = U, lserver = S, resource = <<"">>} =
	jid:from_string(Val),
    {node_glob, U, S};
string_to_spec(<<"all">>, _) -> all;
string_to_spec(<<"raw">>, Val) ->
    {ok, Tokens, _} = erl_scan:string(binary_to_list(<<Val/binary, ".">>)),
    {ok, NewSpec} = erl_parse:parse_term(Tokens),
    NewSpec.

string_to_spec2(ACLName, Val) ->
    #jid{luser = U, lserver = S, resource = <<"">>} =
	jid:from_string(Val),
    case U of
      <<"">> -> {ACLName, S};
      _ -> {ACLName, U, S}
    end.

acl_parse_delete(ACLs, Query) ->
    NewACLs = lists:filter(fun ({acl, _Name, _Spec} =
				    ACL) ->
				   ID = term_to_id(ACL),
				   not lists:member({<<"selected">>, ID}, Query)
			   end,
			   ACLs),
    NewACLs.

access_rules_to_xhtml(AccessRules, Lang) ->
    ?XAE(<<"table">>, [],
	 [?XE(<<"tbody">>,
	      (lists:map(fun ({access, Name, Rules} = Access) ->
				 SName = iolist_to_binary(atom_to_list(Name)),
				 ID = term_to_id(Access),
				 ?XE(<<"tr">>,
				     [?XE(<<"td">>,
					  [?INPUT(<<"checkbox">>,
						  <<"selected">>, ID)]),
				      ?XE(<<"td">>,
					  [?AC(<<SName/binary, "/">>, SName)]),
				      ?XC(<<"td">>, (term_to_string(Rules)))])
			 end,
			 lists:keysort(2,AccessRules))
		 ++
		 [?XE(<<"tr">>,
		      [?X(<<"td">>),
		       ?XE(<<"td">>,
			   [?INPUT(<<"text">>, <<"namenew">>, <<"">>)]),
		       ?XE(<<"td">>,
			   [?INPUTT(<<"submit">>, <<"addnew">>,
				    <<"Add New">>)])])]))]).

access_parse_query(Host, Query) ->
    AccessRules = ets:select(access,
			     [{{access, {'$1', Host}, '$2'}, [],
			       [{{access, '$1', '$2'}}]}]),
    case lists:keysearch(<<"addnew">>, 1, Query) of
      {value, _} ->
	  access_parse_addnew(AccessRules, Host, Query);
      _ ->
	  case lists:keysearch(<<"delete">>, 1, Query) of
	    {value, _} ->
		access_parse_delete(AccessRules, Host, Query)
	  end
    end.

access_parse_addnew(_AccessRules, Host, Query) ->
    case lists:keysearch(<<"namenew">>, 1, Query) of
      {value, {_, String}} when String /= <<"">> ->
	  Name = jlib:binary_to_atom(String),
	  ejabberd_config:add_option({access, Name, Host},
					    []),
	  ok
    end.

access_parse_delete(AccessRules, Host, Query) ->
    lists:foreach(fun ({access, Name, _Rules} =
			   AccessRule) ->
			  ID = term_to_id(AccessRule),
			  case lists:member({<<"selected">>, ID}, Query) of
			    true ->
				mnesia:transaction(fun () ->
							   mnesia:delete({access,
									  {Name,
									   Host}})
						   end);
			    _ -> ok
			  end
		  end,
		  AccessRules),
    ok.

access_rule_to_xhtml(Rules) ->
    Text = lists:flatmap(fun ({Access, ACL} = _Rule) ->
				 SAccess = element_to_list(Access),
				 SACL = atom_to_list(ACL),
				 [SAccess, " \t", SACL, "\n"]
			 end,
			 Rules),
    ?XAC(<<"textarea">>,
	 [{<<"name">>, <<"rules">>}, {<<"rows">>, <<"16">>},
	  {<<"cols">>, <<"80">>}],
	 list_to_binary(Text)).

parse_access_rule(Text) ->
    Strings = str:tokens(Text, <<"\r\n">>),
    case catch lists:flatmap(fun (String) ->
				     case str:tokens(String, <<" \t">>) of
				       [Access, ACL] ->
					   [{list_to_element(Access),
					     jlib:binary_to_atom(ACL)}];
				       [] -> []
				     end
			     end,
			     Strings)
	of
      {'EXIT', _Reason} -> error;
      Rs -> {ok, Rs}
    end.

%%%==================================
%%%% list_vhosts

list_vhosts(Lang, JID) ->
    Hosts = (?MYHOSTS),
    HostsAllowed = lists:filter(fun (Host) ->
					acl:any_rules_allowed(Host,
						     [configure, webadmin_view],
						     JID)
				end,
				Hosts),
    list_vhosts2(Lang, HostsAllowed).

list_vhosts2(Lang, Hosts) ->
    SHosts = lists:sort(Hosts),
    [?XE(<<"table">>,
	 [?XE(<<"thead">>,
	      [?XE(<<"tr">>,
		   [?XCT(<<"td">>, <<"Host">>),
		    ?XCT(<<"td">>, <<"Registered Users">>),
		    ?XCT(<<"td">>, <<"Online Users">>)])]),
	  ?XE(<<"tbody">>,
	      (lists:map(fun (Host) ->
				 OnlineUsers =
				     length(ejabberd_sm:get_vh_session_list(Host)),
				 RegisteredUsers =
				     ejabberd_auth:get_vh_registered_users_number(Host),
				 ?XE(<<"tr">>,
				     [?XE(<<"td">>,
					  [?AC(<<"../server/", Host/binary,
						 "/">>,
					       Host)]),
				      ?XC(<<"td">>,
					  (pretty_string_int(RegisteredUsers))),
				      ?XC(<<"td">>,
					  (pretty_string_int(OnlineUsers)))])
			 end,
			 SHosts)))])].

%%%==================================
%%%% list_users

list_users(Host, Query, Lang, URLFunc) ->
    Res = list_users_parse_query(Query, Host),
    Users = ejabberd_auth:get_vh_registered_users(Host),
    SUsers = lists:sort([{S, U} || {U, S} <- Users]),
    FUsers = case length(SUsers) of
	       N when N =< 100 ->
		   [list_given_users(Host, SUsers, <<"../">>, Lang,
				     URLFunc)];
	       N ->
		   NParts = trunc(math:sqrt(N * 6.17999999999999993783e-1))
			      + 1,
		   M = trunc(N / NParts) + 1,
		   lists:flatmap(fun (K) ->
					 L = K + M - 1,
					 Last = if L < N ->
						       su_to_list(lists:nth(L,
									    SUsers));
						   true ->
						       su_to_list(lists:last(SUsers))
						end,
					 Name = <<(su_to_list(lists:nth(K,
									SUsers)))/binary,
						  $\s, 226, 128, 148, $\s,
						  Last/binary>>,
					 [?AC((URLFunc({user_diapason, K, L})),
					      Name),
					  ?BR]
				 end,
				 lists:seq(1, N, M))
	     end,
    case Res of
%% Parse user creation query and try register:
      ok -> [?XREST(<<"Submitted">>)];
      error -> [?XREST(<<"Bad format">>)];
      nothing -> []
    end
      ++
      [?XAE(<<"form">>,
	    [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	    ([?XE(<<"table">>,
		  [?XE(<<"tr">>,
		       [?XC(<<"td">>, <<(?T(<<"User">>))/binary, ":">>),
			?XE(<<"td">>,
			    [?INPUT(<<"text">>, <<"newusername">>, <<"">>)]),
			?XE(<<"td">>, [?C(<<" @ ", Host/binary>>)])]),
		   ?XE(<<"tr">>,
		       [?XC(<<"td">>, <<(?T(<<"Password">>))/binary, ":">>),
			?XE(<<"td">>,
			    [?INPUT(<<"password">>, <<"newuserpassword">>,
				    <<"">>)]),
			?X(<<"td">>)]),
		   ?XE(<<"tr">>,
		       [?X(<<"td">>),
			?XAE(<<"td">>, [{<<"class">>, <<"alignright">>}],
			     [?INPUTT(<<"submit">>, <<"addnewuser">>,
				      <<"Add User">>)]),
			?X(<<"td">>)])]),
	      ?P]
	       ++ FUsers))].

list_users_parse_query(Query, Host) ->
    case lists:keysearch(<<"addnewuser">>, 1, Query) of
      {value, _} ->
	  {value, {_, Username}} =
	      lists:keysearch(<<"newusername">>, 1, Query),
	  {value, {_, Password}} =
	      lists:keysearch(<<"newuserpassword">>, 1, Query),
	  case jid:from_string(<<Username/binary, "@",
				    Host/binary>>)
	      of
	    error -> error;
	    #jid{user = User, server = Server} ->
		case ejabberd_auth:try_register(User, Server, Password)
		    of
		  {error, _Reason} -> error;
		  _ -> ok
		end
	  end;
      false -> nothing
    end.

list_users_in_diapason(Host, Diap, Lang, URLFunc) ->
    Users = ejabberd_auth:get_vh_registered_users(Host),
    SUsers = lists:sort([{S, U} || {U, S} <- Users]),
    [S1, S2] = ejabberd_regexp:split(Diap, <<"-">>),
    N1 = jlib:binary_to_integer(S1),
    N2 = jlib:binary_to_integer(S2),
    Sub = lists:sublist(SUsers, N1, N2 - N1 + 1),
    [list_given_users(Host, Sub, <<"../../">>, Lang,
		      URLFunc)].

list_given_users(Host, Users, Prefix, Lang, URLFunc) ->
    ModOffline = get_offlinemsg_module(Host),
    ?XE(<<"table">>,
	[?XE(<<"thead">>,
	     [?XE(<<"tr">>,
		  [?XCT(<<"td">>, <<"User">>),
		   ?XCT(<<"td">>, <<"Offline Messages">>),
		   ?XCT(<<"td">>, <<"Last Activity">>)])]),
	 ?XE(<<"tbody">>,
	     (lists:map(fun (_SU = {Server, User}) ->
				US = {User, Server},
				QueueLenStr = get_offlinemsg_length(ModOffline,
								    User,
								    Server),
				FQueueLen = [?AC((URLFunc({users_queue, Prefix,
							   User, Server})),
						 QueueLenStr)],
				FLast = case
					  ejabberd_sm:get_user_resources(User,
									 Server)
					    of
					  [] ->
					      case mod_last:get_last_info(User,
									  Server)
						  of
						not_found -> ?T(<<"Never">>);
						{ok, Shift, _Status} ->
						    TimeStamp = {Shift div
								   1000000,
								 Shift rem
								   1000000,
								 0},
						    {{Year, Month, Day},
						     {Hour, Minute, Second}} =
							calendar:now_to_local_time(TimeStamp),
						    iolist_to_binary(io_lib:format("~w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w",
										   [Year,
										    Month,
										    Day,
										    Hour,
										    Minute,
										    Second]))
					      end;
					  _ -> ?T(<<"Online">>)
					end,
				?XE(<<"tr">>,
				    [?XE(<<"td">>,
					 [?AC((URLFunc({user, Prefix,
							ejabberd_http:url_encode(User),
							Server})),
					      (us_to_list(US)))]),
				     ?XE(<<"td">>, FQueueLen),
				     ?XC(<<"td">>, FLast)])
			end,
			Users)))]).

get_offlinemsg_length(ModOffline, User, Server) ->
    case ModOffline of
      none -> <<"disabled">>;
      _ ->
	  pretty_string_int(ModOffline:count_offline_messages(User,Server))
    end.

get_offlinemsg_module(Server) ->
    case gen_mod:is_loaded(Server, mod_offline) of
      true -> mod_offline;
      false -> none
    end.

get_lastactivity_menuitem_list(Server) ->
    case gen_mod:db_type(Server, mod_last) of
      mnesia -> [{<<"last-activity">>, <<"Last Activity">>}];
      _ -> []
    end.

us_to_list({User, Server}) ->
    jid:to_string({User, Server, <<"">>}).

su_to_list({Server, User}) ->
    jid:to_string({User, Server, <<"">>}).

%%%==================================
%%%% get_stats

get_stats(global, Lang) ->
    OnlineUsers = mnesia:table_info(session, size),
    RegisteredUsers = lists:foldl(fun (Host, Total) ->
					  ejabberd_auth:get_vh_registered_users_number(Host)
					    + Total
				  end,
				  0, ?MYHOSTS),
    OutS2SNumber = ejabberd_s2s:outgoing_s2s_number(),
    InS2SNumber = ejabberd_s2s:incoming_s2s_number(),
    [?XAE(<<"table">>, [],
	  [?XE(<<"tbody">>,
	       [?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Registered Users:">>),
		     ?XC(<<"td">>, (pretty_string_int(RegisteredUsers)))]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Online Users:">>),
		     ?XC(<<"td">>, (pretty_string_int(OnlineUsers)))]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Outgoing s2s Connections:">>),
		     ?XC(<<"td">>, (pretty_string_int(OutS2SNumber)))]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Incoming s2s Connections:">>),
		     ?XC(<<"td">>, (pretty_string_int(InS2SNumber)))])])])];
get_stats(Host, Lang) ->
    OnlineUsers =
	length(ejabberd_sm:get_vh_session_list(Host)),
    RegisteredUsers =
	ejabberd_auth:get_vh_registered_users_number(Host),
    [?XAE(<<"table">>, [],
	  [?XE(<<"tbody">>,
	       [?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Registered Users:">>),
		     ?XC(<<"td">>, (pretty_string_int(RegisteredUsers)))]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Online Users:">>),
		     ?XC(<<"td">>, (pretty_string_int(OnlineUsers)))])])])].

list_online_users(Host, _Lang) ->
    Users = [{S, U}
	     || {U, S, _R} <- ejabberd_sm:get_vh_session_list(Host)],
    SUsers = lists:usort(Users),
    lists:flatmap(fun ({_S, U} = SU) ->
			  [?AC(<<"../user/",
				 (ejabberd_http:url_encode(U))/binary, "/">>,
			       (su_to_list(SU))),
			   ?BR]
		  end,
		  SUsers).

user_info(User, Server, Query, Lang) ->
    LServer = jid:nameprep(Server),
    US = {jid:nodeprep(User), LServer},
    Res = user_parse_query(User, Server, Query),
    Resources = ejabberd_sm:get_user_resources(User,
					       Server),
    FResources =
        case Resources of
            [] -> [?CT(<<"None">>)];
            _ ->
                [?XE(<<"ul">>,
                     (lists:map(
                        fun (R) ->
                                FIP = case
                                          ejabberd_sm:get_user_info(User,
                                                                    Server,
                                                                    R)
                                      of
                                          offline -> <<"">>;
                                          Info
                                            when
                                                is_list(Info) ->
                                              Node =
                                                  proplists:get_value(node,
                                                                      Info),
                                              Conn =
                                                  proplists:get_value(conn,
                                                                      Info),
                                              {IP, Port} =
                                                  proplists:get_value(ip,
                                                                      Info),
                                              ConnS = case Conn of
                                                          c2s ->
                                                              <<"plain">>;
                                                          c2s_tls ->
                                                              <<"tls">>;
                                                          c2s_compressed ->
                                                              <<"zlib">>;
                                                          c2s_compressed_tls ->
                                                              <<"tls+zlib">>;
                                                          http_bind ->
                                                              <<"http-bind">>;
                                                          http_ws ->
                                                              <<"websocket">>;
                                                          _ ->
                                                              <<"unknown">>
                                                      end,
                                              <<ConnS/binary,
                                                "://",
                                                (jlib:ip_to_list(IP))/binary,
                                                ":",
                                                (jlib:integer_to_binary(Port))/binary,
                                                "#",
                                                (jlib:atom_to_binary(Node))/binary>>
                                      end,
                                case direction(Lang) of
				    [{_, <<"rtl">>}] -> ?LI([?C((<<FIP/binary, " - ", R/binary>>))]);
				    _ -> ?LI([?C((<<R/binary, " - ", FIP/binary>>))])
                                end
                        end,
                        lists:sort(Resources))))]
        end,
    FPassword = [?INPUT(<<"text">>, <<"password">>, <<"">>),
		 ?C(<<" ">>),
		 ?INPUTT(<<"submit">>, <<"chpassword">>,
			 <<"Change Password">>)],
    UserItems = ejabberd_hooks:run_fold(webadmin_user,
					LServer, [], [User, Server, Lang]),
    LastActivity = case ejabberd_sm:get_user_resources(User,
						       Server)
		       of
		     [] ->
			 case mod_last:get_last_info(User, Server) of
			   not_found -> ?T(<<"Never">>);
			   {ok, Shift, _Status} ->
			       TimeStamp = {Shift div 1000000,
					    Shift rem 1000000, 0},
			       {{Year, Month, Day}, {Hour, Minute, Second}} =
				   calendar:now_to_local_time(TimeStamp),
			       iolist_to_binary(io_lib:format("~w-~.2.0w-~.2.0w ~.2.0w:~.2.0w:~.2.0w",
							      [Year, Month, Day,
							       Hour, Minute,
							       Second]))
			 end;
		     _ -> ?T(<<"Online">>)
		   end,
    [?XC(<<"h1">>, list_to_binary(io_lib:format(?T(<<"User ~s">>),
                                                [us_to_list(US)])))]
      ++
      case Res of
	ok -> [?XREST(<<"Submitted">>)];
	error -> [?XREST(<<"Bad format">>)];
	nothing -> []
      end
	++
	[?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      ([?XCT(<<"h3">>, <<"Connected Resources:">>)] ++
		 FResources ++
		   [?XCT(<<"h3">>, <<"Password:">>)] ++
		     FPassword ++
		       [?XCT(<<"h3">>, <<"Last Activity">>)] ++
			 [?C(LastActivity)] ++
			   UserItems ++
			     [?P,
			      ?INPUTT(<<"submit">>, <<"removeuser">>,
				      <<"Remove User">>)]))].

user_parse_query(User, Server, Query) ->
    lists:foldl(fun ({Action, _Value}, Acc)
			when Acc == nothing ->
			user_parse_query1(Action, User, Server, Query);
		    ({_Action, _Value}, Acc) -> Acc
		end,
		nothing, Query).

user_parse_query1(<<"password">>, _User, _Server,
		  _Query) ->
    nothing;
user_parse_query1(<<"chpassword">>, User, Server,
		  Query) ->
    case lists:keysearch(<<"password">>, 1, Query) of
      {value, {_, Password}} ->
	  ejabberd_auth:set_password(User, Server, Password), ok;
      _ -> error
    end;
user_parse_query1(<<"removeuser">>, User, Server,
		  _Query) ->
    ejabberd_auth:remove_user(User, Server), ok;
user_parse_query1(Action, User, Server, Query) ->
    case ejabberd_hooks:run_fold(webadmin_user_parse_query,
				 Server, [], [Action, User, Server, Query])
	of
      [] -> nothing;
      Res -> Res
    end.

list_last_activity(Host, Lang, Integral, Period) ->
    TimeStamp = p1_time_compat:system_time(seconds),
    case Period of
      <<"all">> -> TS = 0, Days = infinity;
      <<"year">> -> TS = TimeStamp - 366 * 86400, Days = 366;
      _ -> TS = TimeStamp - 31 * 86400, Days = 31
    end,
    case catch mnesia:dirty_select(last_activity,
				   [{{last_activity, {'_', Host}, '$1', '_'},
				     [{'>', '$1', TS}],
				     [{trunc,
				       {'/', {'-', TimeStamp, '$1'}, 86400}}]}])
	of
      {'EXIT', _Reason} -> [];
      Vals ->
	  Hist = histogram(Vals, Integral),
	  if Hist == [] -> [?CT(<<"No Data">>)];
	     true ->
		 Left = if Days == infinity -> 0;
			   true -> Days - length(Hist)
			end,
		 Tail = if Integral ->
			       lists:duplicate(Left, lists:last(Hist));
			   true -> lists:duplicate(Left, 0)
			end,
		 Max = lists:max(Hist),
		 [?XAE(<<"ol">>,
		       [{<<"id">>, <<"lastactivity">>},
			{<<"start">>, <<"0">>}],
		       [?XAE(<<"li">>,
			     [{<<"style">>,
			       <<"width:",
				 (iolist_to_binary(integer_to_list(trunc(90 * V
									   /
									   Max))))/binary,
				 "%;">>}],
			     [{xmlcdata, pretty_string_int(V)}])
			|| V <- Hist ++ Tail])]
	  end
    end.

histogram(Values, Integral) ->
    histogram(lists:sort(Values), Integral, 0, 0, []).

histogram([H | T], Integral, Current, Count, Hist)
    when Current == H ->
    histogram(T, Integral, Current, Count + 1, Hist);
histogram([H | _] = Values, Integral, Current, Count,
	  Hist)
    when Current < H ->
    if Integral ->
	   histogram(Values, Integral, Current + 1, Count,
		     [Count | Hist]);
       true ->
	   histogram(Values, Integral, Current + 1, 0,
		     [Count | Hist])
    end;
histogram([], _Integral, _Current, Count, Hist) ->
    if Count > 0 -> lists:reverse([Count | Hist]);
       true -> lists:reverse(Hist)
    end.

%%%==================================
%%%% get_nodes

get_nodes(Lang) ->
    RunningNodes = ejabberd_cluster:get_nodes(),
    StoppedNodes = ejabberd_clustet:get_known_nodes()
		     -- RunningNodes,
    FRN = if RunningNodes == [] -> ?CT(<<"None">>);
	     true ->
		 ?XE(<<"ul">>,
		     (lists:map(fun (N) ->
					S = iolist_to_binary(atom_to_list(N)),
					?LI([?AC(<<"../node/", S/binary, "/">>,
						 S)])
				end,
				lists:sort(RunningNodes))))
	  end,
    FSN = if StoppedNodes == [] -> ?CT(<<"None">>);
	     true ->
		 ?XE(<<"ul">>,
		     (lists:map(fun (N) ->
					S = iolist_to_binary(atom_to_list(N)),
					?LI([?C(S)])
				end,
				lists:sort(StoppedNodes))))
	  end,
    [?XCT(<<"h1">>, <<"Nodes">>),
     ?XCT(<<"h3">>, <<"Running Nodes">>), FRN,
     ?XCT(<<"h3">>, <<"Stopped Nodes">>), FSN].

search_running_node(SNode) ->
    RunningNodes = ejabberd_cluster:get_nodes(),
    search_running_node(SNode, RunningNodes).

search_running_node(_, []) -> false;
search_running_node(SNode, [Node | Nodes]) ->
    case iolist_to_binary(atom_to_list(Node)) of
      SNode -> Node;
      _ -> search_running_node(SNode, Nodes)
    end.

get_node(global, Node, [], Query, Lang) ->
    Res = node_parse_query(Node, Query),
    Base = get_base_path(global, Node),
    MenuItems2 = make_menu_items(global, Node, Base, Lang),
    [?XC(<<"h1">>,
	 list_to_binary(io_lib:format(?T(<<"Node ~p">>), [Node])))]
      ++
      case Res of
	ok -> [?XREST(<<"Submitted">>)];
	error -> [?XREST(<<"Bad format">>)];
	nothing -> []
      end
	++
	[?XE(<<"ul">>,
	     ([?LI([?ACT(<<Base/binary, "db/">>, <<"Database">>)]),
	       ?LI([?ACT(<<Base/binary, "backup/">>, <<"Backup">>)]),
	       ?LI([?ACT(<<Base/binary, "ports/">>,
			 <<"Listened Ports">>)]),
	       ?LI([?ACT(<<Base/binary, "stats/">>,
			 <<"Statistics">>)]),
	       ?LI([?ACT(<<Base/binary, "update/">>, <<"Update">>)])]
		++ MenuItems2)),
	 ?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      [?INPUTT(<<"submit">>, <<"restart">>, <<"Restart">>),
	       ?C(<<" ">>),
	       ?INPUTT(<<"submit">>, <<"stop">>, <<"Stop">>)])];
get_node(Host, Node, [], _Query, Lang) ->
    Base = get_base_path(Host, Node),
    MenuItems2 = make_menu_items(Host, Node, Base, Lang),
    [?XC(<<"h1">>, list_to_binary(io_lib:format(?T(<<"Node ~p">>), [Node]))),
     ?XE(<<"ul">>,
	 ([?LI([?ACT(<<Base/binary, "modules/">>,
		     <<"Modules">>)])]
	    ++ MenuItems2))];
get_node(global, Node, [<<"db">>], Query, Lang) ->
    case ejabberd_cluster:call(Node, mnesia, system_info, [tables]) of
      {badrpc, _Reason} ->
	  [?XCT(<<"h1">>, <<"RPC Call Error">>)];
      Tables ->
	  ResS = case node_db_parse_query(Node, Tables, Query) of
		   nothing -> [];
		   ok -> [?XREST(<<"Submitted">>)]
		 end,
	  STables = lists:sort(Tables),
	  Rows = lists:map(fun (Table) ->
				   STable =
				       iolist_to_binary(atom_to_list(Table)),
				   TInfo = case ejabberd_cluster:call(Node, mnesia,
							 table_info,
							 [Table, all])
					       of
					     {badrpc, _} -> [];
					     I -> I
					   end,
				   {Type, Size, Memory} = case
							    {lists:keysearch(storage_type,
									     1,
									     TInfo),
							     lists:keysearch(size,
									     1,
									     TInfo),
							     lists:keysearch(memory,
									     1,
									     TInfo)}
							      of
							    {{value,
							      {storage_type,
							       T}},
							     {value, {size, S}},
							     {value,
							      {memory, M}}} ->
								{T, S, M};
							    _ -> {unknown, 0, 0}
							  end,
				   ?XE(<<"tr">>,
				       [?XC(<<"td">>, STable),
					?XE(<<"td">>,
					    [db_storage_select(STable, Type,
							       Lang)]),
					?XAC(<<"td">>,
					     [{<<"class">>, <<"alignright">>}],
					     (pretty_string_int(Size))),
					?XAC(<<"td">>,
					     [{<<"class">>, <<"alignright">>}],
					     (pretty_string_int(Memory)))])
			   end,
			   STables),
	  [?XC(<<"h1">>,
	       list_to_binary(io_lib:format(?T(<<"Database Tables at ~p">>),
                                            [Node]))
	  )]
	    ++
	    ResS ++
	      [?XAE(<<"form">>,
		    [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
		    [?XAE(<<"table">>, [],
			  [?XE(<<"thead">>,
			       [?XE(<<"tr">>,
				    [?XCT(<<"td">>, <<"Name">>),
				     ?XCT(<<"td">>, <<"Storage Type">>),
				     ?XCT(<<"td">>, <<"Elements">>),
				     ?XCT(<<"td">>, <<"Memory">>)])]),
			   ?XE(<<"tbody">>,
			       (Rows ++
				  [?XE(<<"tr">>,
				       [?XAE(<<"td">>,
					     [{<<"colspan">>, <<"4">>},
					      {<<"class">>, <<"alignright">>}],
					     [?INPUTT(<<"submit">>,
						      <<"submit">>,
						      <<"Submit">>)])])]))])])]
    end;
get_node(global, Node, [<<"backup">>], Query, Lang) ->
    HomeDirRaw = case {os:getenv("HOME"), os:type()} of
		   {EnvHome, _} when is_list(EnvHome) -> list_to_binary(EnvHome);
		   {false, {win32, _Osname}} -> <<"C:/">>;
		   {false, _} -> <<"/tmp/">>
		 end,
    HomeDir = filename:nativename(HomeDirRaw),
    ResS = case node_backup_parse_query(Node, Query) of
	     nothing -> [];
	     ok -> [?XREST(<<"Submitted">>)];
	     {error, Error} ->
		 [?XRES(<<(?T(<<"Error">>))/binary, ": ",
			  (list_to_binary(io_lib:format("~p", [Error])))/binary>>)]
	   end,
    [?XC(<<"h1">>, list_to_binary(io_lib:format(?T(<<"Backup of ~p">>), [Node])))]
      ++
      ResS ++
	[?XCT(<<"p">>,
	      <<"Please note that these options will "
		"only backup the builtin Mnesia database. "
		"If you are using the ODBC module, you "
		"also need to backup your SQL database "
		"separately.">>),
	 ?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      [?XAE(<<"table">>, [],
		    [?XE(<<"tbody">>,
			 [?XE(<<"tr">>,
			      [?XCT(<<"td">>, <<"Store binary backup:">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>, <<"storepath">>,
					   (filename:join(HomeDir,
							  "ejabberd.backup")))]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>, <<"store">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XCT(<<"td">>,
				    <<"Restore binary backup immediately:">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>, <<"restorepath">>,
					   (filename:join(HomeDir,
							  "ejabberd.backup")))]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>, <<"restore">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XCT(<<"td">>,
				    <<"Restore binary backup after next ejabberd "
				      "restart (requires less memory):">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>, <<"fallbackpath">>,
					   (filename:join(HomeDir,
							  "ejabberd.backup")))]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>, <<"fallback">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XCT(<<"td">>, <<"Store plain text backup:">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>, <<"dumppath">>,
					   (filename:join(HomeDir,
							  "ejabberd.dump")))]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>, <<"dump">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XCT(<<"td">>,
				    <<"Restore plain text backup immediately:">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>, <<"loadpath">>,
					   (filename:join(HomeDir,
							  "ejabberd.dump")))]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>, <<"load">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XCT(<<"td">>,
				    <<"Import users data from a PIEFXIS file "
				      "(XEP-0227):">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>,
					   <<"import_piefxis_filepath">>,
					   (filename:join(HomeDir,
							  "users.xml")))]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>,
					    <<"import_piefxis_file">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XCT(<<"td">>,
				    <<"Export data of all users in the server "
				      "to PIEFXIS files (XEP-0227):">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>,
					   <<"export_piefxis_dirpath">>,
					   HomeDir)]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>,
					    <<"export_piefxis_dir">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XE(<<"td">>,
				   [?CT(<<"Export data of users in a host to PIEFXIS "
					  "files (XEP-0227):">>),
				    ?C(<<" ">>),
				    ?INPUT(<<"text">>,
					   <<"export_piefxis_host_dirhost">>,
					   (?MYNAME))]),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>,
					   <<"export_piefxis_host_dirpath">>,
					   HomeDir)]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>,
					    <<"export_piefxis_host_dir">>,
					    <<"OK">>)])]),
                          ?XE(<<"tr">>,
                              [?XE(<<"td">>,
                                   [?CT(<<"Export all tables as SQL queries "
                                          "to a file:">>),
                                    ?C(<<" ">>),
                                    ?INPUT(<<"text">>,
                                           <<"export_sql_filehost">>,
                                           (?MYNAME))]),
                               ?XE(<<"td">>,
				   [?INPUT(<<"text">>,
                                           <<"export_sql_filepath">>,
					   (filename:join(HomeDir,
							  "db.sql")))]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>, <<"export_sql_file">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XCT(<<"td">>,
				    <<"Import user data from jabberd14 spool "
				      "file:">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>, <<"import_filepath">>,
					   (filename:join(HomeDir,
							  "user1.xml")))]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>, <<"import_file">>,
					    <<"OK">>)])]),
			  ?XE(<<"tr">>,
			      [?XCT(<<"td">>,
				    <<"Import users data from jabberd14 spool "
				      "directory:">>),
			       ?XE(<<"td">>,
				   [?INPUT(<<"text">>, <<"import_dirpath">>,
					   <<"/var/spool/jabber/">>)]),
			       ?XE(<<"td">>,
				   [?INPUTT(<<"submit">>, <<"import_dir">>,
					    <<"OK">>)])])])])])];
get_node(global, Node, [<<"ports">>], Query, Lang) ->
    Ports = ejabberd_cluster:call(Node, ejabberd_config,
		     get_local_option, [listen,
                                        {ejabberd_listener, validate_cfg},
                                        []]),
    Res = case catch node_ports_parse_query(Node, Ports,
					    Query)
	      of
	    submitted -> ok;
	    {'EXIT', _Reason} -> error;
	    {is_added, ok} -> ok;
	    {is_added, {error, Reason}} ->
		{error, iolist_to_binary(io_lib:format("~p", [Reason]))};
	    _ -> nothing
	  end,
    NewPorts = lists:sort(ejabberd_cluster:call(Node, ejabberd_config,
				   get_local_option,
                                   [listen,
                                    {ejabberd_listener, validate_cfg},
                                    []])),
    H1String = <<(?T(<<"Listened Ports at ">>))/binary,
		 (iolist_to_binary(atom_to_list(Node)))/binary>>,
    (?H1GL(H1String, <<"listeningports">>, <<"Listening Ports">>))
      ++
      case Res of
	ok -> [?XREST(<<"Submitted">>)];
	error -> [?XREST(<<"Bad format">>)];
	{error, ReasonT} ->
	    [?XRES(<<(?T(<<"Error">>))/binary, ": ",
		     ReasonT/binary>>)];
	nothing -> []
      end
	++
	[?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      [node_ports_to_xhtml(NewPorts, Lang)])];
get_node(Host, Node, [<<"modules">>], Query, Lang)
    when is_binary(Host) ->
    Modules = ejabberd_cluster:call(Node, gen_mod,
		       loaded_modules_with_opts, [Host]),
    Res = case catch node_modules_parse_query(Host, Node,
					      Modules, Query)
	      of
	    submitted -> ok;
	    {'EXIT', Reason} -> ?INFO_MSG("~p~n", [Reason]), error;
	    _ -> nothing
	  end,
    NewModules = lists:sort(ejabberd_cluster:call(Node, gen_mod,
				     loaded_modules_with_opts, [Host])),
    H1String = list_to_binary(io_lib:format(?T(<<"Modules at ~p">>), [Node])),
    (?H1GL(H1String, <<"modulesoverview">>,
	   <<"Modules Overview">>))
      ++
      case Res of
	ok -> [?XREST(<<"Submitted">>)];
	error -> [?XREST(<<"Bad format">>)];
	nothing -> []
      end
	++
	[?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      [node_modules_to_xhtml(NewModules, Lang)])];
get_node(global, Node, [<<"stats">>], _Query, Lang) ->
    UpTime = ejabberd_cluster:call(Node, erlang, statistics,
		      [wall_clock]),
    UpTimeS = list_to_binary(io_lib:format("~.3f",
                                           [element(1, UpTime) / 1000])),
    CPUTime = ejabberd_cluster:call(Node, erlang, statistics, [runtime]),
    CPUTimeS = list_to_binary(io_lib:format("~.3f",
                                            [element(1, CPUTime) / 1000])),
    OnlineUsers = mnesia:table_info(session, size),
    TransactionsCommitted = ejabberd_cluster:call(Node, mnesia,
				     system_info, [transaction_commits]),
    TransactionsAborted = ejabberd_cluster:call(Node, mnesia,
				   system_info, [transaction_failures]),
    TransactionsRestarted = ejabberd_cluster:call(Node, mnesia,
				     system_info, [transaction_restarts]),
    TransactionsLogged = ejabberd_cluster:call(Node, mnesia, system_info,
				  [transaction_log_writes]),
    [?XC(<<"h1">>,
	 list_to_binary(io_lib:format(?T(<<"Statistics of ~p">>), [Node]))),
     ?XAE(<<"table">>, [],
	  [?XE(<<"tbody">>,
	       [?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Uptime:">>),
		     ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
			  UpTimeS)]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"CPU Time:">>),
		     ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
			  CPUTimeS)]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Online Users:">>),
		     ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
			  (pretty_string_int(OnlineUsers)))]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Transactions Committed:">>),
		     ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
			  (pretty_string_int(TransactionsCommitted)))]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Transactions Aborted:">>),
		     ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
			  (pretty_string_int(TransactionsAborted)))]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Transactions Restarted:">>),
		     ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
			  (pretty_string_int(TransactionsRestarted)))]),
		?XE(<<"tr">>,
		    [?XCT(<<"td">>, <<"Transactions Logged:">>),
		     ?XAC(<<"td">>, [{<<"class">>, <<"alignright">>}],
			  (pretty_string_int(TransactionsLogged)))])])])];
get_node(global, Node, [<<"update">>], Query, Lang) ->
    ejabberd_cluster:call(Node, code, purge, [ejabberd_update]),
    Res = node_update_parse_query(Node, Query),
    ejabberd_cluster:call(Node, code, load_file, [ejabberd_update]),
    {ok, _Dir, UpdatedBeams, Script, LowLevelScript,
     Check} =
	ejabberd_cluster:call(Node, ejabberd_update, update_info, []),
    Mods = case UpdatedBeams of
	     [] -> ?CT(<<"None">>);
	     _ ->
		 BeamsLis = lists:map(fun (Beam) ->
					      BeamString =
						  iolist_to_binary(atom_to_list(Beam)),
					      ?LI([?INPUT(<<"checkbox">>,
							  <<"selected">>,
							  BeamString),
						   ?C(BeamString)])
				      end,
				      UpdatedBeams),
		 SelectButtons = [?BR,
				  ?INPUTATTRS(<<"button">>, <<"selectall">>,
					      <<"Select All">>,
					      [{<<"onClick">>,
						<<"selectAll()">>}]),
				  ?C(<<" ">>),
				  ?INPUTATTRS(<<"button">>, <<"unselectall">>,
					      <<"Unselect All">>,
					      [{<<"onClick">>,
						<<"unSelectAll()">>}])],
		 ?XAE(<<"ul">>, [{<<"class">>, <<"nolistyle">>}],
		      (BeamsLis ++ SelectButtons))
	   end,
    FmtScript = (?XC(<<"pre">>,
		     list_to_binary(io_lib:format("~p", [Script])))),
    FmtLowLevelScript = (?XC(<<"pre">>,
			     list_to_binary(io_lib:format("~p", [LowLevelScript])))),
    [?XC(<<"h1">>,
	 list_to_binary(io_lib:format(?T(<<"Update ~p">>), [Node])))]
      ++
      case Res of
	ok -> [?XREST(<<"Submitted">>)];
	{error, ErrorText} ->
	    [?XREST(<<"Error: ", ErrorText/binary>>)];
	nothing -> []
      end
	++
	[?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      [?XCT(<<"h2">>, <<"Update plan">>),
	       ?XCT(<<"h3">>, <<"Modified modules">>), Mods,
	       ?XCT(<<"h3">>, <<"Update script">>), FmtScript,
	       ?XCT(<<"h3">>, <<"Low level update script">>),
	       FmtLowLevelScript, ?XCT(<<"h3">>, <<"Script check">>),
	       ?XC(<<"pre">>, (jlib:atom_to_binary(Check))),
	       ?BR,
	       ?INPUTT(<<"submit">>, <<"update">>, <<"Update">>)])];
get_node(Host, Node, NPath, Query, Lang) ->
    {Hook, Opts} = case Host of
		     global ->
			 {webadmin_page_node, [Node, NPath, Query, Lang]};
		     Host ->
			 {webadmin_page_hostnode,
			  [Host, Node, NPath, Query, Lang]}
		   end,
    case ejabberd_hooks:run_fold(Hook, Host, [], Opts) of
      [] -> [?XC(<<"h1">>, <<"Not Found">>)];
      Res -> Res
    end.

%%%==================================
%%%% node parse

node_parse_query(Node, Query) ->
    case lists:keysearch(<<"restart">>, 1, Query) of
      {value, _} ->
	  case ejabberd_cluster:call(Node, init, restart, []) of
	    {badrpc, _Reason} -> error;
	    _ -> ok
	  end;
      _ ->
	  case lists:keysearch(<<"stop">>, 1, Query) of
	    {value, _} ->
		case ejabberd_cluster:call(Node, init, stop, []) of
		  {badrpc, _Reason} -> error;
		  _ -> ok
		end;
	    _ -> nothing
	  end
    end.

db_storage_select(ID, Opt, Lang) ->
    ?XAE(<<"select">>,
	 [{<<"name">>, <<"table", ID/binary>>}],
	 (lists:map(fun ({O, Desc}) ->
			    Sel = if O == Opt ->
					 [{<<"selected">>, <<"selected">>}];
				     true -> []
				  end,
			    ?XACT(<<"option">>,
				  (Sel ++
				     [{<<"value">>,
				       iolist_to_binary(atom_to_list(O))}]),
				  Desc)
		    end,
		    [{ram_copies, <<"RAM copy">>},
		     {disc_copies, <<"RAM and disc copy">>},
		     {disc_only_copies, <<"Disc only copy">>},
		     {unknown, <<"Remote copy">>},
		     {delete_content, <<"Delete content">>},
		     {delete_table, <<"Delete table">>}]))).

node_db_parse_query(_Node, _Tables, [{nokey, <<>>}]) ->
    nothing;
node_db_parse_query(Node, Tables, Query) ->
    lists:foreach(fun (Table) ->
			  STable = iolist_to_binary(atom_to_list(Table)),
			  case lists:keysearch(<<"table", STable/binary>>, 1,
					       Query)
			      of
			    {value, {_, SType}} ->
				Type = case SType of
					 <<"unknown">> -> unknown;
					 <<"ram_copies">> -> ram_copies;
					 <<"disc_copies">> -> disc_copies;
					 <<"disc_only_copies">> ->
					     disc_only_copies;
					 <<"delete_content">> -> delete_content;
					 <<"delete_table">> -> delete_table;
					 _ -> false
				       end,
				if Type == false -> ok;
				   Type == delete_content ->
				       mnesia:clear_table(Table);
				   Type == delete_table ->
				       mnesia:delete_table(Table);
				   Type == unknown ->
				       mnesia:del_table_copy(Table, Node);
				   true ->
				       case mnesia:add_table_copy(Table, Node,
								  Type)
					   of
					 {aborted, _} ->
					     mnesia:change_table_copy_type(Table,
									   Node,
									   Type);
					 _ -> ok
				       end
				end;
			    _ -> ok
			  end
		  end,
		  Tables),
    ok.

node_backup_parse_query(_Node, [{nokey, <<>>}]) ->
    nothing;
node_backup_parse_query(Node, Query) ->
    lists:foldl(fun (Action, nothing) ->
			case lists:keysearch(Action, 1, Query) of
			  {value, _} ->
			      case lists:keysearch(<<Action/binary, "path">>, 1,
						   Query)
				  of
				{value, {_, Path}} ->
				    Res = case Action of
					    <<"store">> ->
						ejabberd_cluster:call(Node, mnesia, backup,
							 [binary_to_list(Path)]);
					    <<"restore">> ->
						ejabberd_cluster:call(Node, ejabberd_admin,
							 restore, [Path]);
					    <<"fallback">> ->
						ejabberd_cluster:call(Node, mnesia,
							 install_fallback,
							 [binary_to_list(Path)]);
					    <<"dump">> ->
						ejabberd_cluster:call(Node, ejabberd_admin,
							 dump_to_textfile,
							 [Path]);
					    <<"load">> ->
						ejabberd_cluster:call(Node, mnesia,
							 load_textfile,
                                                         [binary_to_list(Path)]);
					    <<"import_piefxis_file">> ->
						ejabberd_cluster:call(Node, ejabberd_piefxis,
							 import_file, [Path]);
					    <<"export_piefxis_dir">> ->
						ejabberd_cluster:call(Node, ejabberd_piefxis,
							 export_server, [Path]);
					    <<"export_piefxis_host_dir">> ->
						{value, {_, Host}} =
						    lists:keysearch(<<Action/binary,
								      "host">>,
								    1, Query),
						ejabberd_cluster:call(Node, ejabberd_piefxis,
							 export_host,
							 [Path, Host]);
                                            <<"export_sql_file">> ->
                                                {value, {_, Host}} =
                                                    lists:keysearch(<<Action/binary,
                                                                      "host">>,
                                                                    1, Query),
                                                ejabberd_cluster:call(Node, ejd2sql,
                                                         export, [Host, Path]);
					    <<"import_file">> ->
						ejabberd_cluster:call(Node, ejabberd_admin,
							 import_file, [Path]);
					    <<"import_dir">> ->
						ejabberd_cluster:call(Node, ejabberd_admin,
							 import_dir, [Path])
					  end,
				    case Res of
				      {error, Reason} -> {error, Reason};
				      {badrpc, Reason} -> {badrpc, Reason};
				      _ -> ok
				    end;
				OtherError -> {error, OtherError}
			      end;
			  _ -> nothing
			end;
		    (_Action, Res) -> Res
		end,
		nothing,
		[<<"store">>, <<"restore">>, <<"fallback">>, <<"dump">>,
		 <<"load">>, <<"import_file">>, <<"import_dir">>,
		 <<"import_piefxis_file">>, <<"export_piefxis_dir">>,
		 <<"export_piefxis_host_dir">>, <<"export_sql_file">>]).

node_ports_to_xhtml(Ports, Lang) ->
    ?XAE(<<"table">>, [{<<"class">>, <<"withtextareas">>}],
	 [?XE(<<"thead">>,
	      [?XE(<<"tr">>,
		   [?XCT(<<"td">>, <<"Port">>), ?XCT(<<"td">>, <<"IP">>),
		    ?XCT(<<"td">>, <<"Protocol">>),
		    ?XCT(<<"td">>, <<"Module">>),
		    ?XCT(<<"td">>, <<"Options">>)])]),
	  ?XE(<<"tbody">>,
	      (lists:map(fun ({PortIP, Module, Opts} = _E) ->
				 {_Port, SPort, _TIP, SIP, SSPort, NetProt,
				  OptsClean} =
				     get_port_data(PortIP, Opts),
				 SModule =
				     iolist_to_binary(atom_to_list(Module)),
				 {NumLines, SOptsClean} =
				     term_to_paragraph(OptsClean, 40),
				 ?XE(<<"tr">>,
				     [?XAE(<<"td">>, [{<<"size">>, <<"6">>}],
					   [?C(SPort)]),
				      ?XAE(<<"td">>, [{<<"size">>, <<"15">>}],
					   [?C(SIP)]),
				      ?XAE(<<"td">>, [{<<"size">>, <<"4">>}],
					   [?C((iolist_to_binary(atom_to_list(NetProt))))]),
				      ?XE(<<"td">>,
					  [?INPUTS(<<"text">>,
						   <<"module", SSPort/binary>>,
						   SModule, <<"15">>)]),
				      ?XAE(<<"td">>, direction(ltr),
					  [?TEXTAREA(<<"opts", SSPort/binary>>,
						     (iolist_to_binary(integer_to_list(NumLines))),
						     <<"35">>, SOptsClean)]),
				      ?XE(<<"td">>,
					  [?INPUTT(<<"submit">>,
						   <<"add", SSPort/binary>>,
						   <<"Restart">>)]),
				      ?XE(<<"td">>,
					  [?INPUTT(<<"submit">>,
						   <<"delete", SSPort/binary>>,
						   <<"Stop">>)])])
			 end,
			 Ports)
		 ++
		 [?XE(<<"tr">>,
		      [?XE(<<"td">>,
			   [?INPUTS(<<"text">>, <<"portnew">>, <<"">>,
				    <<"6">>)]),
		       ?XE(<<"td">>,
			   [?INPUTS(<<"text">>, <<"ipnew">>, <<"0.0.0.0">>,
				    <<"15">>)]),
		       ?XE(<<"td">>, [make_netprot_html(<<"tcp">>)]),
		       ?XE(<<"td">>,
			   [?INPUTS(<<"text">>, <<"modulenew">>, <<"">>,
				    <<"15">>)]),
		       ?XAE(<<"td">>, direction(ltr),
			   [?TEXTAREA(<<"optsnew">>, <<"2">>, <<"35">>,
				      <<"[]">>)]),
		       ?XAE(<<"td">>, [{<<"colspan">>, <<"2">>}],
			    [?INPUTT(<<"submit">>, <<"addnew">>,
				     <<"Start">>)])])]))]).

make_netprot_html(NetProt) ->
    ?XAE(<<"select">>, [{<<"name">>, <<"netprotnew">>}],
	 (lists:map(fun (O) ->
			    Sel = if O == NetProt ->
					 [{<<"selected">>, <<"selected">>}];
				     true -> []
				  end,
			    ?XAC(<<"option">>, (Sel ++ [{<<"value">>, O}]), O)
		    end,
		    [<<"tcp">>, <<"udp">>]))).

get_port_data(PortIP, Opts) ->
    {Port, IPT, IPS, _IPV, NetProt, OptsClean} =
	ejabberd_listener:parse_listener_portip(PortIP, Opts),
    SPort = jlib:integer_to_binary(Port),
    SSPort = list_to_binary(
               lists:map(fun (N) ->
                                 io_lib:format("~.16b", [N])
                         end,
                         binary_to_list(
                           erlang:md5(
                             [SPort, IPS, atom_to_list(NetProt)])))),
    {Port, SPort, IPT, IPS, SSPort, NetProt, OptsClean}.

node_ports_parse_query(Node, Ports, Query) ->
    lists:foreach(fun ({PortIpNetp, Module1, Opts1}) ->
			  {Port, _SPort, TIP, _SIP, SSPort, NetProt,
			   _OptsClean} =
			      get_port_data(PortIpNetp, Opts1),
			  case lists:keysearch(<<"add", SSPort/binary>>, 1,
					       Query)
			      of
			    {value, _} ->
				PortIpNetp2 = {Port, TIP, NetProt},
				{{value, {_, SModule}}, {value, {_, SOpts}}} =
				    {lists:keysearch(<<"module",
						       SSPort/binary>>,
						     1, Query),
				     lists:keysearch(<<"opts", SSPort/binary>>,
						     1, Query)},
				Module = jlib:binary_to_atom(SModule),
				{ok, Tokens, _} =
				    erl_scan:string(binary_to_list(SOpts) ++ "."),
				{ok, Opts} = erl_parse:parse_term(Tokens),
				ejabberd_cluster:call(Node, ejabberd_listener,
					 delete_listener,
					 [PortIpNetp2, Module1]),
				R = ejabberd_cluster:call(Node, ejabberd_listener,
					     add_listener,
					     [PortIpNetp2, Module, Opts]),
				throw({is_added, R});
			    _ ->
				case lists:keysearch(<<"delete",
						       SSPort/binary>>,
						     1, Query)
				    of
				  {value, _} ->
				      ejabberd_cluster:call(Node, ejabberd_listener,
					       delete_listener,
					       [PortIpNetp, Module1]),
				      throw(submitted);
				  _ -> ok
				end
			  end
		  end,
		  Ports),
    case lists:keysearch(<<"addnew">>, 1, Query) of
      {value, _} ->
	  {{value, {_, SPort}}, {value, {_, STIP}},
	   {value, {_, SNetProt}}, {value, {_, SModule}},
	   {value, {_, SOpts}}} =
	      {lists:keysearch(<<"portnew">>, 1, Query),
	       lists:keysearch(<<"ipnew">>, 1, Query),
	       lists:keysearch(<<"netprotnew">>, 1, Query),
	       lists:keysearch(<<"modulenew">>, 1, Query),
	       lists:keysearch(<<"optsnew">>, 1, Query)},
	  {ok, Toks, _} = erl_scan:string(binary_to_list(<<SPort/binary, ".">>)),
	  {ok, Port2} = erl_parse:parse_term(Toks),
	  {ok, ToksIP, _} = erl_scan:string(binary_to_list(<<STIP/binary, ".">>)),
	  STIP2 = case erl_parse:parse_term(ToksIP) of
		    {ok, IPTParsed} -> IPTParsed;
		    {error, _} -> STIP
		  end,
	  Module = jlib:binary_to_atom(SModule),
	  NetProt2 = jlib:binary_to_atom(SNetProt),
	  {ok, Tokens, _} = erl_scan:string(binary_to_list(<<SOpts/binary, ".">>)),
	  {ok, Opts} = erl_parse:parse_term(Tokens),
	  {Port2, _SPort, IP2, _SIP, _SSPort, NetProt2,
	   OptsClean} =
	      get_port_data({Port2, STIP2, NetProt2}, Opts),
	  R = ejabberd_cluster:call(Node, ejabberd_listener, add_listener,
		       [{Port2, IP2, NetProt2}, Module, OptsClean]),
	  throw({is_added, R});
      _ -> ok
    end.

node_modules_to_xhtml(Modules, Lang) ->
    ?XAE(<<"table">>, [{<<"class">>, <<"withtextareas">>}],
	 [?XE(<<"thead">>,
	      [?XE(<<"tr">>,
		   [?XCT(<<"td">>, <<"Module">>),
		    ?XCT(<<"td">>, <<"Options">>)])]),
	  ?XE(<<"tbody">>,
	      (lists:map(fun ({Module, Opts} = _E) ->
				 SModule =
				     iolist_to_binary(atom_to_list(Module)),
				 {NumLines, SOpts} = term_to_paragraph(Opts,
								       40),
				 ?XE(<<"tr">>,
				     [?XC(<<"td">>, SModule),
				      ?XAE(<<"td">>, direction(ltr),
					  [?TEXTAREA(<<"opts", SModule/binary>>,
						     (iolist_to_binary(integer_to_list(NumLines))),
						     <<"40">>, SOpts)]),
				      ?XE(<<"td">>,
					  [?INPUTT(<<"submit">>,
						   <<"restart",
						     SModule/binary>>,
						   <<"Restart">>)]),
				      ?XE(<<"td">>,
					  [?INPUTT(<<"submit">>,
						   <<"stop", SModule/binary>>,
						   <<"Stop">>)])])
			 end,
			 Modules)
		 ++
		 [?XE(<<"tr">>,
		      [?XE(<<"td">>,
			   [?INPUT(<<"text">>, <<"modulenew">>, <<"">>)]),
		       ?XAE(<<"td">>, direction(ltr),
			   [?TEXTAREA(<<"optsnew">>, <<"2">>, <<"40">>,
				      <<"[]">>)]),
		       ?XAE(<<"td">>, [{<<"colspan">>, <<"2">>}],
			    [?INPUTT(<<"submit">>, <<"start">>,
				     <<"Start">>)])])]))]).

node_modules_parse_query(Host, Node, Modules, Query) ->
    lists:foreach(fun ({Module, _Opts1}) ->
			  SModule = iolist_to_binary(atom_to_list(Module)),
			  case lists:keysearch(<<"restart", SModule/binary>>, 1,
					       Query)
			      of
			    {value, _} ->
				{value, {_, SOpts}} = lists:keysearch(<<"opts",
									SModule/binary>>,
								      1, Query),
				{ok, Tokens, _} =
				    erl_scan:string(binary_to_list(<<SOpts/binary, ".">>)),
				{ok, Opts} = erl_parse:parse_term(Tokens),
				ejabberd_cluster:call(Node, gen_mod, stop_module,
					 [Host, Module]),
				ejabberd_cluster:call(Node, gen_mod, start_module,
					 [Host, Module, Opts]),
				throw(submitted);
			    _ ->
				case lists:keysearch(<<"stop", SModule/binary>>,
						     1, Query)
				    of
				  {value, _} ->
				      ejabberd_cluster:call(Node, gen_mod, stop_module,
					       [Host, Module]),
				      throw(submitted);
				  _ -> ok
				end
			  end
		  end,
		  Modules),
    case lists:keysearch(<<"start">>, 1, Query) of
      {value, _} ->
	  {{value, {_, SModule}}, {value, {_, SOpts}}} =
	      {lists:keysearch(<<"modulenew">>, 1, Query),
	       lists:keysearch(<<"optsnew">>, 1, Query)},
	  Module = jlib:binary_to_atom(SModule),
	  {ok, Tokens, _} = erl_scan:string(binary_to_list(<<SOpts/binary, ".">>)),
	  {ok, Opts} = erl_parse:parse_term(Tokens),
	  ejabberd_cluster:call(Node, gen_mod, start_module,
		   [Host, Module, Opts]),
	  throw(submitted);
      _ -> ok
    end.

node_update_parse_query(Node, Query) ->
    case lists:keysearch(<<"update">>, 1, Query) of
      {value, _} ->
	  ModulesToUpdateStrings =
	      proplists:get_all_values(<<"selected">>, Query),
	  ModulesToUpdate = [jlib:binary_to_atom(M)
			     || M <- ModulesToUpdateStrings],
	  case ejabberd_cluster:call(Node, ejabberd_update, update,
			[ModulesToUpdate])
	      of
	    {ok, _} -> ok;
	    {error, Error} ->
		?ERROR_MSG("~p~n", [Error]),
		{error, iolist_to_binary(io_lib:format("~p", [Error]))};
	    {badrpc, Error} ->
		?ERROR_MSG("Bad RPC: ~p~n", [Error]),
		{error,
		 <<"Bad RPC: ", (iolist_to_binary(io_lib:format("~p", [Error])))/binary>>}
	  end;
      _ -> nothing
    end.

pretty_print_xml(El) ->
    list_to_binary(pretty_print_xml(El, <<"">>)).

pretty_print_xml({xmlcdata, CData}, Prefix) ->
    IsBlankCData = lists:all(
                     fun($\f) -> true;
                        ($\r) -> true;
                        ($\n) -> true;
                        ($\t) -> true;
                        ($\v) -> true;
                        ($ ) -> true;
                        (_) -> false
                     end, binary_to_list(CData)),
    if IsBlankCData ->
            [];
       true ->
            [Prefix, CData, $\n]
    end;
pretty_print_xml(#xmlel{name = Name, attrs = Attrs,
			children = Els},
		 Prefix) ->
    [Prefix, $<, Name,
     case Attrs of
       [] -> [];
       [{Attr, Val} | RestAttrs] ->
	   AttrPrefix = [Prefix,
			 str:copies(<<" ">>, byte_size(Name) + 2)],
	   [$\s, Attr, $=, $', fxml:crypt(Val) | [$',
                                                 lists:map(fun ({Attr1,
                                                                 Val1}) ->
                                                                   [$\n,
                                                                    AttrPrefix,
                                                                    Attr1, $=,
                                                                    $',
                                                                    fxml:crypt(Val1),
                                                                    $']
                                                           end,
                                                           RestAttrs)]]
     end,
     if Els == [] -> <<"/>\n">>;
	true ->
	    OnlyCData = lists:all(fun ({xmlcdata, _}) -> true;
				      (#xmlel{}) -> false
				  end,
				  Els),
	    if OnlyCData ->
		   [$>, fxml:get_cdata(Els), $<, $/, Name, $>, $\n];
	       true ->
		   [$>, $\n,
		    lists:map(fun (E) ->
				      pretty_print_xml(E, [Prefix, <<"  ">>])
			      end,
			      Els),
		    Prefix, $<, $/, Name, $>, $\n]
	    end
     end].

element_to_list(X) when is_atom(X) ->
    iolist_to_binary(atom_to_list(X));
element_to_list(X) when is_integer(X) ->
    iolist_to_binary(integer_to_list(X)).

list_to_element(Bin) ->
    {ok, Tokens, _} = erl_scan:string(binary_to_list(Bin)),
    [{_, _, Element}] = Tokens,
    Element.

url_func({user_diapason, From, To}) ->
    <<(iolist_to_binary(integer_to_list(From)))/binary, "-",
      (iolist_to_binary(integer_to_list(To)))/binary, "/">>;
url_func({users_queue, Prefix, User, _Server}) ->
    <<Prefix/binary, "user/", User/binary, "/queue/">>;
url_func({user, Prefix, User, _Server}) ->
    <<Prefix/binary, "user/", User/binary, "/">>.

last_modified() ->
    {<<"Last-Modified">>,
     <<"Mon, 25 Feb 2008 13:23:30 GMT">>}.

cache_control_public() ->
    {<<"Cache-Control">>, <<"public">>}.

%% Transform 1234567890 into "1,234,567,890"
pretty_string_int(Integer) when is_integer(Integer) ->
    pretty_string_int(iolist_to_binary(integer_to_list(Integer)));
pretty_string_int(String) when is_binary(String) ->
    {_, Result} = lists:foldl(fun (NewNumber, {3, Result}) ->
				      {1, <<NewNumber, $,, Result/binary>>};
				  (NewNumber, {CountAcc, Result}) ->
				      {CountAcc + 1, <<NewNumber, Result/binary>>}
			      end,
			      {0, <<"">>}, lists:reverse(binary_to_list(String))),
    Result.

%%%==================================
%%%% navigation menu

%% @spec (Host, Node, Lang, JID::jid()) -> [LI]
make_navigation(Host, Node, Lang, JID) ->
    Menu = make_navigation_menu(Host, Node, Lang, JID),
    make_menu_items(Lang, Menu).

%% @spec (Host, Node, Lang, JID::jid()) -> Menu
%% where Host = global | string()
%%       Node = cluster | string()
%%       Lang = string()
%%       Menu = {URL, Title} | {URL, Title, [Menu]}
%%       URL = string()
%%       Title = string()
make_navigation_menu(Host, Node, Lang, JID) ->
    HostNodeMenu = make_host_node_menu(Host, Node, Lang,
				       JID),
    HostMenu = make_host_menu(Host, HostNodeMenu, Lang,
			      JID),
    NodeMenu = make_node_menu(Host, Node, Lang),
    make_server_menu(HostMenu, NodeMenu, Lang, JID).

%% @spec (Host, Node, Base, Lang) -> [LI]
make_menu_items(global, cluster, Base, Lang) ->
    HookItems = get_menu_items_hook(server, Lang),
    make_menu_items(Lang, {Base, <<"">>, HookItems});
make_menu_items(global, Node, Base, Lang) ->
    HookItems = get_menu_items_hook({node, Node}, Lang),
    make_menu_items(Lang, {Base, <<"">>, HookItems});
make_menu_items(Host, cluster, Base, Lang) ->
    HookItems = get_menu_items_hook({host, Host}, Lang),
    make_menu_items(Lang, {Base, <<"">>, HookItems});
make_menu_items(Host, Node, Base, Lang) ->
    HookItems = get_menu_items_hook({hostnode, Host, Node},
				    Lang),
    make_menu_items(Lang, {Base, <<"">>, HookItems}).

make_host_node_menu(global, _, _Lang, _JID) ->
    {<<"">>, <<"">>, []};
make_host_node_menu(_, cluster, _Lang, _JID) ->
    {<<"">>, <<"">>, []};
make_host_node_menu(Host, Node, Lang, JID) ->
    HostNodeBase = get_base_path(Host, Node),
    HostNodeFixed = [{<<"modules/">>, <<"Modules">>}] ++
		      get_menu_items_hook({hostnode, Host, Node}, Lang),
    HostNodeBasePath = url_to_path(HostNodeBase),
    HostNodeFixed2 = [Tuple
		      || Tuple <- HostNodeFixed,
			 is_allowed_path(HostNodeBasePath, Tuple, JID)],
    {HostNodeBase, iolist_to_binary(atom_to_list(Node)),
     HostNodeFixed2}.

make_host_menu(global, _HostNodeMenu, _Lang, _JID) ->
    {<<"">>, <<"">>, []};
make_host_menu(Host, HostNodeMenu, Lang, JID) ->
    HostBase = get_base_path(Host, cluster),
    HostFixed = [{<<"acls">>, <<"Access Control Lists">>},
		 {<<"access">>, <<"Access Rules">>},
		 {<<"users">>, <<"Users">>},
		 {<<"online-users">>, <<"Online Users">>}]
		  ++
		  get_lastactivity_menuitem_list(Host) ++
		    [{<<"nodes">>, <<"Nodes">>, HostNodeMenu},
		     {<<"stats">>, <<"Statistics">>}]
		      ++ get_menu_items_hook({host, Host}, Lang),
    HostBasePath = url_to_path(HostBase),
    HostFixed2 = [Tuple
		  || Tuple <- HostFixed,
		     is_allowed_path(HostBasePath, Tuple, JID)],
    {HostBase, Host, HostFixed2}.

make_node_menu(_Host, cluster, _Lang) ->
    {<<"">>, <<"">>, []};
make_node_menu(global, Node, Lang) ->
    NodeBase = get_base_path(global, Node),
    NodeFixed = [{<<"db/">>, <<"Database">>},
		 {<<"backup/">>, <<"Backup">>},
		 {<<"ports/">>, <<"Listened Ports">>},
		 {<<"stats/">>, <<"Statistics">>},
		 {<<"update/">>, <<"Update">>}]
		  ++ get_menu_items_hook({node, Node}, Lang),
    {NodeBase, iolist_to_binary(atom_to_list(Node)),
     NodeFixed};
make_node_menu(_Host, _Node, _Lang) ->
    {<<"">>, <<"">>, []}.

make_server_menu(HostMenu, NodeMenu, Lang, JID) ->
    Base = get_base_path(global, cluster),
    Fixed = [{<<"acls">>, <<"Access Control Lists">>},
	     {<<"access">>, <<"Access Rules">>},
	     {<<"vhosts">>, <<"Virtual Hosts">>, HostMenu},
	     {<<"nodes">>, <<"Nodes">>, NodeMenu},
	     {<<"stats">>, <<"Statistics">>}]
	      ++ get_menu_items_hook(server, Lang),
    BasePath = url_to_path(Base),
    Fixed2 = [Tuple
	      || Tuple <- Fixed,
		 is_allowed_path(BasePath, Tuple, JID)],
    {Base, <<"">>, Fixed2}.

get_menu_items_hook({hostnode, Host, Node}, Lang) ->
    ejabberd_hooks:run_fold(webadmin_menu_hostnode, Host,
			    [], [Host, Node, Lang]);
get_menu_items_hook({host, Host}, Lang) ->
    ejabberd_hooks:run_fold(webadmin_menu_host, Host, [],
			    [Host, Lang]);
get_menu_items_hook({node, Node}, Lang) ->
    ejabberd_hooks:run_fold(webadmin_menu_node, [],
			    [Node, Lang]);
get_menu_items_hook(server, Lang) ->
    ejabberd_hooks:run_fold(webadmin_menu_main, [], [Lang]).

%% @spec (Lang::string(), Menu) -> [LI]
%% where Menu = {MURI::string(), MName::string(), Items::[Item]}
%%       Item = {IURI::string(), IName::string()} | {IURI::string(), IName::string(), Menu}
make_menu_items(Lang, Menu) ->
    lists:reverse(make_menu_items2(Lang, 1, Menu)).

make_menu_items2(Lang, Deep, {MURI, MName, _} = Menu) ->
    Res = case MName of
	    <<"">> -> [];
	    _ -> [make_menu_item(header, Deep, MURI, MName, Lang)]
	  end,
    make_menu_items2(Lang, Deep, Menu, Res).

make_menu_items2(_, _Deep, {_, _, []}, Res) -> Res;
make_menu_items2(Lang, Deep,
		 {MURI, MName, [Item | Items]}, Res) ->
    Res2 = case Item of
	     {IURI, IName} ->
		 [make_menu_item(item, Deep,
				 <<MURI/binary, IURI/binary, "/">>, IName, Lang)
		  | Res];
	     {IURI, IName, SubMenu} ->
		 ResTemp = [make_menu_item(item, Deep,
					   <<MURI/binary, IURI/binary, "/">>,
					   IName, Lang)
			    | Res],
		 ResSubMenu = make_menu_items2(Lang, Deep + 1, SubMenu),
		 ResSubMenu ++ ResTemp
	   end,
    make_menu_items2(Lang, Deep, {MURI, MName, Items},
		     Res2).

make_menu_item(header, 1, URI, Name, _Lang) ->
    ?LI([?XAE(<<"div">>, [{<<"id">>, <<"navhead">>}],
	      [?AC(URI, Name)])]);
make_menu_item(header, 2, URI, Name, _Lang) ->
    ?LI([?XAE(<<"div">>, [{<<"id">>, <<"navheadsub">>}],
	      [?AC(URI, Name)])]);
make_menu_item(header, 3, URI, Name, _Lang) ->
    ?LI([?XAE(<<"div">>, [{<<"id">>, <<"navheadsubsub">>}],
	      [?AC(URI, Name)])]);
make_menu_item(item, 1, URI, Name, Lang) ->
    ?LI([?XAE(<<"div">>, [{<<"id">>, <<"navitem">>}],
	      [?ACT(URI, Name)])]);
make_menu_item(item, 2, URI, Name, Lang) ->
    ?LI([?XAE(<<"div">>, [{<<"id">>, <<"navitemsub">>}],
	      [?ACT(URI, Name)])]);
make_menu_item(item, 3, URI, Name, Lang) ->
    ?LI([?XAE(<<"div">>, [{<<"id">>, <<"navitemsubsub">>}],
	      [?ACT(URI, Name)])]).

%%%==================================


opt_type(access) -> fun acl:access_rules_validator/1;
opt_type(access_readonly) -> fun acl:access_rules_validator/1;
opt_type(_) -> [access, access_readonly].

%%% vim: set foldmethod=marker foldmarker=%%%%,%%%=:
