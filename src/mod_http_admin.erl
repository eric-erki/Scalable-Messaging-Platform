%%%----------------------------------------------------------------------
%%% File    : mod_http_admin.erl
%%% Author  : Christophe romain <christophe.romain@process-one.net>
%%% Purpose : Provide admin REST API using JSON data
%%% Created : 15 Sep 2014 by Christophe Romain <christophe.romain@process-one.net>
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

%% Example config:
%%
%%  in access section
%%    http_admin:
%%      admin:
%%        - register
%%        - connected_users
%%        - status
%%      all:
%%        - status
%%
%%  in ejabberd_http listener
%%    request_handlers:
%%      "api": mod_http_admin
%%
%%  in module section
%%    mod_http_admin:
%%      access: http_admin
%%
%%
%% Then to perform an action, send a POST request to the following URL:
%% http://localhost:5280/api/<call_name>

-module(mod_http_admin).

-author('cromain@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, process/2, depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("logger.hrl").
-include("ejabberd_http.hrl").

-define(DEFAULT_API_VERSION, 0).

-define(CT_PLAIN,
	{<<"Content-Type">>, <<"text/plain">>}).

-define(CT_XML,
	{<<"Content-Type">>, <<"text/xml; charset=utf-8">>}).

-define(CT_JSON,
	{<<"Content-Type">>, <<"application/json">>}).

-define(AC_ALLOW_ORIGIN,
	{<<"Access-Control-Allow-Origin">>, <<"*">>}).

-define(AC_ALLOW_METHODS,
	{<<"Access-Control-Allow-Methods">>,
	 <<"GET, POST, OPTIONS">>}).

-define(AC_ALLOW_HEADERS,
	{<<"Access-Control-Allow-Headers">>,
	 <<"Content-Type">>}).

-define(AC_MAX_AGE,
	{<<"Access-Control-Max-Age">>, <<"86400">>}).

-define(OPTIONS_HEADER,
	[?CT_PLAIN, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_METHODS,
	 ?AC_ALLOW_HEADERS, ?AC_MAX_AGE]).

-define(HEADER(CType),
	[CType, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_HEADERS]).

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

check_permissions(#request{auth={SJID, Pass}}, Command) ->
    case jid:from_string(SJID) of
	#jid{user = User, server = Server} = JID ->
	    Access = gen_mod:get_module_opt(Server, ?MODULE, access,
						 fun(A) -> A end,
						 none),
	    case ejabberd_auth:check_password(User, <<"">>, Server, Pass) of
		true ->
		    Res = acl:match_rule(Server, Access, JID),
		    case Res of
			all ->
			    allowed;
			[all] ->
			    allowed;
			allow ->
			    allowed;
			Commands when is_list(Commands) ->
			    case lists:member(jlib:binary_to_atom(Command),
					      Commands) of
				true -> allowed;
				_ -> unauthorized_response()
			    end;
			_ ->
			unauthorized_response()
		    end;
		false ->
		    unauthorized_response()
	    end;
	_ -> unauthorized_response()
    end;
check_permissions(#request{ip={IP, _Port}}, Command) ->
    Access = gen_mod:get_module_opt(global, ?MODULE, access,
				    fun(A) -> A end,
				    none),
    Res = acl:match_rule(global, Access, IP),
    case Res of
	all ->
	    allowed;
	[all] ->
	    allowed;
	allow ->
	    allowed;
	Commands when is_list(Commands) ->
	    case lists:member(jlib:binary_to_atom(Command), Commands) of
		true -> allowed;
		_ -> unauthorized_response()
	    end;
	_ ->
	    unauthorized_response()
    end.

%% ------------------
%% command processing
%% ------------------

process(_, #request{method = 'POST', data = <<>>}) ->
    ?DEBUG("Bad Request: no data", []),
    badrequest_response(<<"Missing POST data">>);
process([Call], #request{method = 'POST', data = Data, ip = IP} = Req) ->
    Version = get_api_version(Req),
    try
	Args = case jiffy:decode(Data) of
	    List when is_list(List) -> List;
	    {List} when is_list(List) -> List;
	    Other -> [Other]
	end,
	log(Call, Args, IP),
	case check_permissions(Req, Call) of
	    allowed ->
		{Code, Result} = handle(Call, Args, Version),
		json_response(Code, jiffy:encode(Result));
	    ErrorResponse ->
		ErrorResponse
	end
    catch _:{error,{_,invalid_json}} = _Err ->
	    ?DEBUG("Bad Request: ~p", [_Err]),
	    badrequest_response(<<"Invalid JSON input">>);
	  _:_Err ->
	    ?DEBUG("Bad Request: ~p", [_Err]),
	    badrequest_response()
    end;
process([Call], #request{method = 'GET', q = Data, ip = IP} = Req) ->
    Version = get_api_version(Req),
    try
	Args = case Data of
	    [{nokey, <<>>}] -> [];
	    _ -> Data
	end,
	log(Call, Args, IP),
	case check_permissions(Req, Call) of
	    allowed ->
		{Code, Result} = handle(Call, Args, Version),
		json_response(Code, jiffy:encode(Result));
	    ErrorResponse ->
		ErrorResponse
	end
    catch _:Error ->
	?DEBUG("Bad Request: ~p", [Error]),
	badrequest_response()
    end;
process([], #request{method = 'OPTIONS', data = <<>>}) ->
    {200, ?OPTIONS_HEADER, []};
process(_Path, Request) ->
    ?DEBUG("Bad Request: no handler ~p", [Request]),
    badrequest_response().

% get API version N from last "vN" element in URL path
get_api_version(#request{path = Path}) ->
    get_api_version(lists:reverse(Path));
get_api_version([<<"v", String/binary>> | Tail]) ->
    case catch jlib:binary_to_integer(String) of
	N when is_integer(N) ->
	    N;
	_ ->
	    get_api_version(Tail)
    end;
get_api_version([_Head | Tail]) ->
    get_api_version(Tail);
get_api_version([]) ->
    ?DEFAULT_API_VERSION.

%% ----------------
%% command handlers
%% ----------------

get_json_prop(Name, JSON) ->
    case lists:keyfind(Name, 1, JSON) of
	{Name, Val} -> Val;
	false -> throw(<<"Can't find field ", Name/binary, " in struct">>)
    end.
get_json_prop(Name, JSON, Default) ->
    case lists:keyfind(Name, 1, JSON) of
	{Name, Val} -> Val;
	false -> Default
    end.

handle(<<"bulk-roster-update">>, Args, _Versions) ->
    Err1 = case lists:keyfind(<<"add">>, 1, Args) of
               {<<"add">>, List} ->
                   lists:filtermap(fun([{C1}, {C2}]) ->
                                           Jid1 = get_json_prop(<<"jid">>, C1),
                                           Nick1 = get_json_prop(<<"nick">>, C1, <<"">>),
                                           Group1 = get_json_prop(<<"group">>, C1, <<"">>),
                                           {U1, S1, _} = jid:tolower(jid:from_string(Jid1)),
                                           Jid2 = get_json_prop(<<"jid">>, C2),
                                           Nick2 = get_json_prop(<<"nick">>, C2, <<"">>),
                                           Group2 = get_json_prop(<<"group">>, C2, <<"">>),
                                           {U2, S2, _} = jid:tolower(jid:from_string(Jid2)),

                                           case {ejabberd_auth:is_user_exists(U1, S1),
                                                 ejabberd_auth:is_user_exists(U2, S2)}
                                           of
                                               {true, true} ->
                                                   case mod_admin_extra:add_rosteritem(U2, S2, U1, S1, Nick1, Group1, <<"both">>) of
                                                       ok -> case mod_admin_extra:add_rosteritem(U1, S1, U2, S2, Nick2, Group2, <<"both">>) of
                                                                ok -> false;
                                                                _ -> {true, {[{Jid1, <<"Modifing roster failed">>}]}}
                                                            end;
                                                       _ -> {true, {[{Jid2, <<"Modifing roster failed">>}]}}
                                                   end;
                                               {false, _} -> {true, {[{Jid1, <<"User doesn't exist">>}]}};
                                               {_, false} -> {true, {[{Jid2, <<"User doesn't exist">>}]}}
                                           end
                                   end, List);
               _ -> []
           end,
    Err2 = case lists:keyfind(<<"remove">>, 1, Args) of
               {<<"remove">>, ListR} ->
                   lists:filtermap(fun([JidR1, JidR2]) ->
                                           {UR1, SR1, _} = jid:tolower(jid:from_string(JidR1)),
                                           {UR2, SR2, _} = jid:tolower(jid:from_string(JidR2)),
                                           case mod_admin_extra:delete_rosteritem(UR1, SR1, UR2, SR2) of
                                               ok ->
                                                   case mod_admin_extra:delete_rosteritem(UR2, SR2, UR1, SR1) of
                                                       ok -> false;
                                                       _ -> {true, {[{JidR2, <<"Can't delete roster item">>}]}}
                                                   end;
                                               _ -> {true, {[{JidR1, <<"Can't delete roster item">>}]}}
                                           end
                                   end, ListR);
               _ ->
                   []
           end,
    Err = Err1 ++ Err2,
    case Err of
	[] ->
	    {200, {[{<<"result">>, <<"success">>}]}};
	_ ->
	    {500, {[{<<"result">>, <<"failure">>},{<<"errors">>, Err}]}}
    end;

% generic ejabberd command handler
handle(Call, Args, Version) when is_binary(Call), is_list(Args) ->
    case ejabberd_commands:get_command_format(jlib:binary_to_atom(Call), Version) of
	{ArgsSpec, _} when is_list(ArgsSpec) ->
	    Args2 = [{jlib:binary_to_atom(Key), Value} || {Key, Value} <- Args],
	    Spec = lists:foldr(
		    fun ({Key, binary}, Acc) ->
			    [{Key, <<>>}|Acc];
			({Key, string}, Acc) ->
			    [{Key, <<>>}|Acc];
			({Key, integer}, Acc) ->
			    [{Key, 0}|Acc];
			({Key, {list, _}}, Acc) ->
			    [{Key, []}|Acc];
			({Key, atom}, Acc) ->
			    [{Key, undefined}|Acc]
		    end, [], ArgsSpec),
	    try
		case Args2 of
		    [] -> handle3(Call, Args, Version);
		    _ -> handle2(Call, match(Args2, Spec), Version)
		end
	    catch throw:not_found ->
		    {404, <<"not_found">>};
		  throw:{not_found, Why} when is_atom(Why) ->
		    {404, jlib:atom_to_binary(Why)};
		  throw:{not_found, Msg} ->
		    {404, iolist_to_binary(Msg)};
		  throw:not_allowed ->
		    {401, <<"not_allowed">>};
		  throw:{not_allowed, Why} when is_atom(Why) ->
		    {401, jlib:atom_to_binary(Why)};
		  throw:{not_allowed, Msg} ->
		    {401, iolist_to_binary(Msg)};
		  throw:{invalid_parameter, Msg} ->
		    {400, iolist_to_binary(Msg)};
		  throw:{error, Why} when is_atom(Why) ->
		    {400, jlib:atom_to_binary(Why)};
		  throw:{error, Msg} ->
		    {400, iolist_to_binary(Msg)};
		  throw:Error when is_atom(Error) ->
		    {400, jlib:atom_to_binary(Error)};
		  throw:Msg when is_list(Msg); is_binary(Msg) ->
		    {400, iolist_to_binary(Msg)};
		  _Error ->
		    ?ERROR_MSG("REST API Error: ~p", [_Error]),
		    {500, <<"internal_error">>}
	    end;
	{error, Msg} ->
	    ?ERROR_MSG("REST API Error: ~p", [Msg]),
	    {400, Msg};
	_Error ->
	    ?ERROR_MSG("REST API Error: ~p", [_Error]),
	    {400, <<"Error">>}
    end.

handle2(Call, Args, Version) when is_binary(Call), is_list(Args) ->
    Fun = jlib:binary_to_atom(Call),
    {ArgsF, _ResultF} = ejabberd_commands:get_command_format(Fun, Version),
    ArgsFormatted = format_args(Args, ArgsF),
    case ejabberd_commands:execute_command(Fun, ArgsFormatted, Version) of
	{error, Error} ->
	    throw(Error);
	Res ->
	    format_command_result(Fun, Res, Version)
    end.

handle3(Call, Args, Version) when is_binary(Call), is_list(Args) ->
    Fun = jlib:binary_to_atom(Call),
    case ejabberd_commands:execute_command(Fun, Args, Version) of
        0 -> {200, <<"OK">>};
        1 -> {500, <<"500 Internal server error">>};
        400 -> {400, <<"400 Bad Request">>};
        Res -> format_command_result(Fun, Res, Version)
    end.

get_elem_delete(A, L) ->
    case proplists:get_all_values(A, L) of
      [Value] -> {Value, proplists:delete(A, L)};
      [_, _ | _] ->
	  %% Crash reporting the error
	  exit({duplicated_attribute, A, L});
      [] ->
	  %% Report the error and then force a crash
	  exit({attribute_not_found, A, L})
    end.

format_args(Args, ArgsFormat) ->
    {ArgsRemaining, R} = lists:foldl(fun ({ArgName,
					   ArgFormat},
					  {Args1, Res}) ->
					     {ArgValue, Args2} =
						 get_elem_delete(ArgName,
								 Args1),
					     Formatted = format_arg(ArgValue,
								    ArgFormat),
					     {Args2, Res ++ [Formatted]}
				     end,
				     {Args, []}, ArgsFormat),
    case ArgsRemaining of
      [] -> R;
      L when is_list(L) -> exit({additional_unused_args, L})
    end.

format_arg({array, Elements},
	   {list, {ElementDefName, ElementDefFormat}})
    when is_list(Elements) ->
    lists:map(fun ({struct, [{ElementName, ElementValue}]}) when
			ElementDefName == ElementName ->
		      format_arg(ElementValue, ElementDefFormat)
	      end,
	      Elements);
format_arg({array, [{struct, Elements}]},
	   {list, {ElementDefName, ElementDefFormat}})
    when is_list(Elements) ->
    lists:map(fun ({ElementName, ElementValue}) ->
		      true = ElementDefName == ElementName,
		      format_arg(ElementValue, ElementDefFormat)
	      end,
	      Elements);
format_arg({array, [{struct, Elements}]},
	   {tuple, ElementsDef})
    when is_list(Elements) ->
    FormattedList = format_args(Elements, ElementsDef),
    list_to_tuple(FormattedList);
format_arg({array, Elements}, {list, ElementsDef})
    when is_list(Elements) and is_atom(ElementsDef) ->
    [format_arg(Element, ElementsDef)
     || Element <- Elements];
format_arg(Arg, integer) when is_integer(Arg) -> Arg;
format_arg(Arg, binary) when is_list(Arg) -> process_unicode_codepoints(Arg);
format_arg(Arg, binary) when is_binary(Arg) -> Arg;
format_arg(Arg, string) when is_list(Arg) -> process_unicode_codepoints(Arg);
format_arg(Arg, string) when is_binary(Arg) -> Arg;
format_arg(undefined, binary) -> <<>>;
format_arg(undefined, string) -> <<>>;
format_arg(Arg, Format) ->
    ?ERROR_MSG("don't know how to format Arg ~p for format ~p", [Arg, Format]),
    throw({invalid_parameter,
	   io_lib:format("Arg ~p is not in format ~p",
			 [Arg, Format])}).

process_unicode_codepoints(Str) ->
    iolist_to_binary(lists:map(fun(X) when X > 255 -> unicode:characters_to_binary([X]);
				  (Y) -> Y
			       end, Str)).

%% ----------------
%% internal helpers
%% ----------------

match(Args, Spec) ->
    [{Key, proplists:get_value(Key, Args, Default)} || {Key, Default} <- Spec].

format_command_result(Cmd, Result, Version) ->
    {_, ResultFormat} = ejabberd_commands:get_command_format(Cmd, Version),
    case {ResultFormat, Result} of
	{{_, rescode}, V} when V == true; V == ok ->
	    {200, 0};
	{{_, rescode}, _} ->
	    {200, 1};
	{{_, restuple}, {V1, Text1}} when V1 == true; V1 == ok ->
	    {200, iolist_to_binary(Text1)};
	{{_, restuple}, {_, Text2}} ->
	    {500, iolist_to_binary(Text2)};
	{{_, {list, _}}, _V} ->
	    {_, L} = format_result(Result, ResultFormat),
	    {200, L};
	{{_, {tuple, _}}, _V} ->
	    {_, T} = format_result(Result, ResultFormat),
	    {200, T};
	_ ->
	    {200, {[format_result(Result, ResultFormat)]}}
    end.

format_result(Atom, {Name, atom}) ->
    {jlib:atom_to_binary(Name), jlib:atom_to_binary(Atom)};

format_result(Int, {Name, integer}) ->
    {jlib:atom_to_binary(Name), Int};

format_result(String, {Name, string}) ->
    {jlib:atom_to_binary(Name), iolist_to_binary(String)};

format_result(Code, {Name, rescode}) ->
    {jlib:atom_to_binary(Name), Code == true orelse Code == ok};

format_result({Code, Text}, {Name, restuple}) ->
    {jlib:atom_to_binary(Name),
     {[{<<"res">>, Code == true orelse Code == ok},
       {<<"text">>, iolist_to_binary(Text)}]}};

format_result(Els, {Name, {list, {_, {tuple, [{_, atom}, _]}} = Fmt}}) ->
    {jlib:atom_to_binary(Name), {[format_result(El, Fmt) || El <- Els]}};

format_result(Els, {Name, {list, Def}}) ->
    {jlib:atom_to_binary(Name), [element(2, format_result(El, Def)) || El <- Els]};

format_result(Tuple, {_Name, {tuple, [{_, atom}, ValFmt]}}) ->
    {Name2, Val} = Tuple,
    {_, Val2} = format_result(Val, ValFmt),
    {jlib:atom_to_binary(Name2), Val2};

format_result(Tuple, {Name, {tuple, Def}}) ->
    Els = lists:zip(tuple_to_list(Tuple), Def),
    {jlib:atom_to_binary(Name), {[format_result(El, ElDef) || {El, ElDef} <- Els]}};

format_result(404, {_Name, _}) ->
    "not_found".

unauthorized_response() ->
    unauthorized_response(<<"401 Unauthorized">>).
unauthorized_response(Body) ->
    json_response(401, jiffy:encode(Body)).

badrequest_response() ->
    badrequest_response(<<"400 Bad Request">>).
badrequest_response(Body) ->
    json_response(400, jiffy:encode(Body)).

json_response(Code, Body) when is_integer(Code) ->
    {Code, ?HEADER(?CT_JSON), Body}.

log(Call, Args, {Addr, Port}) ->
    AddrS = jlib:ip_to_list({Addr, Port}),
    ?INFO_MSG("Admin call ~s ~p from ~s:~p", [Call, Args, AddrS, Port]).

depends(_Host, _Opts) ->
    [].

mod_opt_type(access) -> fun acl:access_rules_validator/1;
mod_opt_type(_) -> [access].
