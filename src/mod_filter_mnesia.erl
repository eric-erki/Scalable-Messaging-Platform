%%%-------------------------------------------------------------------
%%% File    : mod_filter_mnesia.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Mnesia backend for filter rules
%%% Created : 22 Jan 2018 by Christophe Romain <christophe.romain@process-one.net>
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

-module(mod_filter_mnesia).
-behaviour(mod_filter).

-author('christophe.romain@process-one.net').

-export([init/2, set_rule/4, del_rule/2, rules/1, filter/4]).

-include("jlib.hrl").
-include("mod_filter.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(_Host, _Opts) ->
    mnesia:create_table(filter_rule,
			[{disc_copies, [node()]},
			 {attributes, record_info(fields, filter_rule)}]).

set_rule(Host, Id, Exp, Type) ->
    {Ex, Re} = case binary:split(Exp, <<":">>) of
	[<<"from">>, Jid] -> {{from, Jid}, undefined};
	[<<"to">>, Jid] -> {{to, Jid}, undefined};
	_ ->
	    case re:compile(Exp, [caseless, dotall]) of
		{ok, Blob} -> {Exp, Blob};
		_ -> {undefined, undefined}
	    end
    end,
    case Ex of
	undefined ->
	    {error, {invalid, Exp}};
	_ ->
	    mnesia:dirty_write(#filter_rule{id = {Host, Id}, type = Type,
					    exp = Ex, re = Re})
    end.

del_rule(Host, Id) ->
    mnesia:dirty_delete(filter_rule, {Host, Id}).

rules(Host) ->
    mnesia:dirty_match_object(#filter_rule{id = {Host, '_'}, _ = '_'}).

filter(Host, From, To, Packet) ->
    match_rules(rules(Host), pass, From, To, Packet).

%%%===================================================================
%%% Internal functions
%%%===================================================================

match_rules([Rule|Tail], pass, From, To, Packet) ->
    Match = match(Rule, From, To, Packet),
    match_rules(Tail, Match, From, To, Packet);
match_rules([], Acc, _From, _To, _Packet) ->
    Acc;
match_rules(_, Acc, _From, _To, _Packet) ->
    Acc.

match(#filter_rule{re = undefined, exp = {from, Jid}, type = Type},
      From, _To, _Packet) ->
    case jid:to_string(From) of
	Jid -> Type;
	_ -> pass
    end;
match(#filter_rule{re = undefined, exp = {to, Jid}, type = Type},
      _From, To, _Packet) ->
    case jid:to_string(To) of
	Jid -> Type;
	_ -> pass
    end;
match(#filter_rule{re = Re, type = Type},
      _From, _To, Packet) ->
    case catch re:run(fxml:element_to_binary(Packet), Re) of
	{match, _} -> Type;
	_ -> pass
    end.
