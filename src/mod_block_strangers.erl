%%%-------------------------------------------------------------------
%%% File    : mod_block_strangers.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Block packets from non-subscribers
%%% Created : 25 Dec 2016 by Alexey Shchepin <alexey@process-one.net>
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
-module(mod_block_strangers).

-author('alexey@process-one.net').

-behaviour(gen_mod).

%% API
-export([start/2, stop/1,
         depends/2, mod_opt_type/1]).

-export([filter_packet/5]).

-include("jlib.hrl").
-include("ejabberd.hrl").
-include("logger.hrl").
-include("ejabberd_c2s.hrl").

start(Host, _Opts) ->
    ejabberd_hooks:add(c2s_filter_incoming_packet, Host,
                       ?MODULE, filter_packet, 50),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(c2s_filter_incoming_packet, Host,
                          ?MODULE, filter_packet, 50),
    ok.

filter_packet(deny = Acc, _StateData, _From, _To, _Packet) ->
    Acc;
filter_packet(Acc, StateData, From, To, Packet) ->
    LFrom = jid:tolower(From),
    LBFrom = jid:remove_resource(LFrom),
    NoBody = fxml:get_subtag(Packet, <<"body">>) == false,
    NoSubject = fxml:get_subtag(Packet, <<"subject">>) == false,
    AllowLocalUsers =
        gen_mod:get_module_opt(LServer, ?MODULE, allow_local_users, true),
    case (NoBody andalso NoSubject)
        orelse (AllowLocalUsers andalso
                ejabberd_router:is_my_route(From#jid.lserver))
        orelse (?SETS):is_element(LFrom, StateData#state.pres_a)
	orelse (?SETS):is_element(LBFrom, StateData#state.pres_a)
        orelse sets_bare_member(LBFrom, StateData#state.pres_a) of
	true ->
	    Acc;
	false ->
            Host = StateData#state.server,
            Drop =
                gen_mod:get_module_opt(Host, ?MODULE, drop,
                                       fun(B) when is_boolean(B) -> B end,
                                       true),
            Log =
                gen_mod:get_module_opt(Host, ?MODULE, log,
                                       fun(B) when is_boolean(B) -> B end,
                                       false),
            if
                Log ->
                    ?INFO_MSG("Drop packet~nFrom: ~s~nTo: ~s~nPacket: ~s",
                              [jid:to_string(From),
                               jid:to_string(To),
                               fxml:element_to_binary(Packet)]);
                true ->
                    ok
            end,
            if
                Drop ->
                    deny;
                true ->
                    Acc
            end
    end.


sets_bare_member({U, S, _}, Set) ->
    case gb_trees:lookup(S, Set) of
        none -> false;
        {value, JIDs} ->
            gb_tree_any(
              fun(_, Users) ->
                      gb_sets:is_element(U, Users)
              end, JIDs)
    end.


gb_tree_any(F, Tree) ->
    gb_tree_any1(F, gb_trees:iterator(Tree)).
gb_tree_any1(F, Iterator) ->
    case gb_trees:next(Iterator) of
        {Key, Value, Iter2} ->
            case F(Key, Value) of
                true ->
                    true;
                false ->
                    gb_tree_any1(F, Iter2)
            end;
        none ->
            false
    end.


depends(_Host, _Opts) ->
    [].

mod_opt_type(drop) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(log) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(allow_local_users) ->
    fun (B) when is_boolean(B) -> B end;
mod_opt_type(_) -> [drop, log, allow_local_users].
