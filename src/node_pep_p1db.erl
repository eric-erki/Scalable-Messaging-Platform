%%%----------------------------------------------------------------------
%%% File    : node_pep_p1db.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Standard PubSub PEP plugin with P1DB backend
%%% Created : 15 Apr 2015 by Christophe Romain <christophe.romain@process-one.net>
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

%%% @doc The module <strong>{@module}</strong> is the pep PubSub plugin.
%%% <p>PubSub plugin nodes are using the {@link gen_pubsub_node} behaviour.</p>

-module(node_pep_p1db).
-behaviour(gen_pubsub_node).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").
-include("logger.hrl").

-export([init/3, terminate/2, options/0, features/0,
    create_node_permission/6, create_node/2, delete_node/1,
    purge_node/2, subscribe_node/8, unsubscribe_node/4,
    publish_item/6, delete_item/4, remove_extra_items/3,
    get_entity_affiliations/2, get_node_affiliations/1,
    get_affiliation/2, set_affiliation/3,
    get_entity_subscriptions/2, get_node_subscriptions/1,
    get_subscriptions/2, set_subscriptions/4,
    get_pending_nodes/2, get_states/1, get_state/2,
    set_state/1, get_items/7, get_items/3, get_item/7,
    get_item/2, set_item/1, get_item_name/3, node_to_path/1,
    path_to_node/1]).

init(Host, ServerHost, Opts) ->
    node_flat_p1db:init(Host, ServerHost, Opts),
    complain_if_modcaps_disabled(ServerHost),
    ok.

terminate(Host, ServerHost) ->
    node_flat_p1db:terminate(Host, ServerHost),
    ok.

options() ->
    node_pep:options().

features() ->
    node_pep:features().

create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access) ->
    node_pep:create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access).

create_node(Nidx, Owner) ->
    node_flat_p1db:create_node(Nidx, Owner),
    {result, {default, broadcast}}.

delete_node(Nodes) ->
    {result, {_, _, Result}} = node_flat_p1db:delete_node(Nodes),
    {result, {[], Result}}.

subscribe_node(Nidx, Sender, Subscriber, AccessModel,
	    SendLast, PresenceSubscription, RosterGroup, Options) ->
    node_flat_p1db:subscribe_node(Nidx, Sender, Subscriber, AccessModel, SendLast,
	PresenceSubscription, RosterGroup, Options).


unsubscribe_node(Nidx, Sender, Subscriber, SubId) ->
    case node_flat_p1db:unsubscribe_node(Nidx, Sender, Subscriber, SubId) of
	{error, Error} -> {error, Error};
	{result, _} -> {result, []}
    end.

publish_item(Nidx, Publisher, Model, MaxItems, ItemId, Payload) ->
    node_flat_p1db:publish_item(Nidx, Publisher, Model, MaxItems, ItemId, Payload).

remove_extra_items(Nidx, MaxItems, ItemIds) ->
    node_flat_p1db:remove_extra_items(Nidx, MaxItems, ItemIds).

delete_item(Nidx, Publisher, PublishModel, ItemId) ->
    node_flat_p1db:delete_item(Nidx, Publisher, PublishModel, ItemId).

purge_node(Nidx, Owner) ->
    node_flat_p1db:purge_node(Nidx, Owner).

get_entity_affiliations(Host, Owner) ->
    {_, D, _} = SubKey = jid:tolower(Owner),
    SubKey = jid:tolower(Owner),
    GenKey = jid:remove_resource(SubKey),
    States = node_flat_p1db:get_states_by_prefix(GenKey),
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (#pubsub_state{stateid = {_, N}, affiliation = A}, Acc) ->
		    case NodeTree:get_node(N) of
			#pubsub_node{nodeid = {{_, D, _}, _}} = Node -> [{Node, A} | Acc];
			_ -> Acc
		    end
	    end,
	    [], States),
    {result, Reply}.

get_node_affiliations(Nidx) ->
    node_flat_p1db:get_node_affiliations(Nidx).

get_affiliation(Nidx, Owner) ->
    node_flat_p1db:get_affiliation(Nidx, Owner).

set_affiliation(Nidx, Owner, Affiliation) ->
    node_flat_p1db:set_affiliation(Nidx, Owner, Affiliation).

get_entity_subscriptions(Host, Owner) ->
    {U, D, _} = SubKey = jid:tolower(Owner),
    GenKey = jid:remove_resource(SubKey),
    States = case SubKey of
	GenKey ->
	    node_flat_p1db:get_states_by_prefix({U, D, '_'});
	_ ->
	    node_flat_p1db:get_states_by_prefix(GenKey)
	    ++
	    node_flat_p1db:get_states_by_prefix(SubKey)
    end,
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (#pubsub_state{stateid = {J, N}, subscriptions = Ss}, Acc) ->
		    case NodeTree:get_node(N) of
			#pubsub_node{nodeid = {{_, D, _}, _}} = Node ->
			    lists:foldl(fun
				    ({subscribed, SubId}, Acc2) ->
					[{Node, subscribed, SubId, J} | Acc2];
				    ({pending, _SubId}, Acc2) ->
					[{Node, pending, J} | Acc2];
				    (S, Acc2) ->
					[{Node, S, J} | Acc2]
				end,
				Acc, Ss);
			_ ->
			    Acc
		    end
	    end,
	    [], States),
    {result, Reply}.

get_node_subscriptions(Nidx) ->
    node_flat_p1db:get_node_subscriptions(Nidx).

get_subscriptions(Nidx, Owner) ->
    node_flat_p1db:get_subscriptions(Nidx, Owner).

set_subscriptions(Nidx, Owner, Subscription, SubId) ->
    node_flat_p1db:set_subscriptions(Nidx, Owner, Subscription, SubId).

get_pending_nodes(Host, Owner) ->
    node_flat_p1db:get_pending_nodes(Host, Owner).

get_states(Nidx) ->
    node_flat_p1db:get_states(Nidx).

get_state(Nidx, JID) ->
    node_flat_p1db:get_state(Nidx, JID).

set_state(State) ->
    node_flat_p1db:set_state(State).

get_items(Nidx, From, RSM) ->
    node_flat_p1db:get_items(Nidx, From, RSM).

get_items(Nidx, JID, AccessModel, PresenceSubscription, RosterGroup, SubId, RSM) ->
    node_flat_p1db:get_items(Nidx, JID, AccessModel,
	PresenceSubscription, RosterGroup, SubId, RSM).

get_item(Nidx, ItemId) ->
    node_flat_p1db:get_item(Nidx, ItemId).

get_item(Nidx, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, SubId) ->
    node_flat_p1db:get_item(Nidx, ItemId, JID, AccessModel,
	PresenceSubscription, RosterGroup, SubId).

set_item(Item) ->
    node_flat_p1db:set_item(Item).

get_item_name(Host, Node, Id) ->
    node_flat_p1db:get_item_name(Host, Node, Id).

node_to_path(Node) ->
    node_flat_p1db:node_to_path(Node).

path_to_node(Path) ->
    node_flat_p1db:path_to_node(Path).

%%%
%%% Internal
%%%

%% @doc Check mod_caps is enabled, otherwise show warning.
%% The PEP plugin for mod_pubsub requires mod_caps to be enabled in the host.
%% Check that the mod_caps module is enabled in that Jabber Host
%% If not, show a warning message in the ejabberd log file.
complain_if_modcaps_disabled(ServerHost) ->
    case gen_mod:is_loaded(ServerHost, mod_caps) of
	false ->
	    ?WARNING_MSG("The PEP plugin is enabled in mod_pubsub "
		"of host ~p. This plugin requires mod_caps "
		"to be enabled, but it isn't.",
		[ServerHost]);
	true -> ok
    end.
