%%%----------------------------------------------------------------------
%%% File    : pubsub_cleanup.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Cleanup old db entries or garbare
%%% Created :  9 May 2016 by Christophe Romain <christophe.romain@process-one.net>
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

-module(pubsub_cleanup).

-export([remove_old_subscriptions/1]).

-include("pubsub.hrl").

remove_old_subscriptions(ServerHost) ->
    Host = mod_pubsub:host(ServerHost),
    clear_sub_opts(ServerHost, gen_mod:db_type(ServerHost, mod_pubsub)),
    lists:foreach(fun(#pubsub_node{id=Nidx,type=Type}) ->
                lists:foreach(fun(#pubsub_state{subscriptions=Subs}=State) ->
                            case Subs of
                                [] -> ok;
                                [_Sub] -> ok;
                                [Sub|_] ->
                                    set_state(Host, Type,
                                              State#pubsub_state{subscriptions = Sub})
                            end
                    end, get_states(Host, Type, Nidx))
        end, get_nodes(Host)).

clear_sub_opts(_ServerHost, mnesia) ->
    mnesia:clear_table(pubsub_subscription);
clear_sub_opts(ServerHost, odbc) ->
    clear_sub_opts_sql(ServerHost);
clear_sub_opts(ServerHost, sql) ->
    clear_sub_opts_sql(ServerHost);
clear_sub_opts(_ServerHost, p1db) ->
    p1db:clear(pubsub_subscription).

clear_sub_opts_sql(ServerHost) ->
    ejabberd_sql:sql_query(ServerHost, [<<"delete from pubsub_subscription_opt">>]).

get_nodes(Host) ->
    mod_pubsub:tree_action(Host, get_nodes, [Host]).

get_states(Host, Type, Nidx) ->
    case mod_pubsub:node_action(Host, Type, get_states, [Nidx]) of
        {result, List} -> List;
        _ -> []
    end.

set_state(Host, Type, State) ->
    mod_pubsub:node_action(Host, Type, set_state, [State]).

