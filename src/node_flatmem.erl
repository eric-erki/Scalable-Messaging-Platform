%%% ====================================================================
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
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
%%% ====================================================================

-module(node_flatmem).
-behaviour(gen_pubsub_node).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").

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
    path_to_node/1, storage_location/0]).

init(Host, ServerHost, Opts) ->
    node_flat:init(Host, ServerHost, Opts),
    [mnesia:clear_table(T) || T<-[pubsub_node, pubsub_state, pubsub_item]],
    mnesia:change_table_copy_type(pubsub_state, node(), ram_copies),
    ok.

terminate(Host, ServerHost) ->
    node_flat:terminate(Host, ServerHost).

options() ->
    [{deliver_payloads, true},
	{notify_config, false},
	{notify_delete, false},
	{notify_retract, false},
	{purge_offline, false},
	{persist_items, false},
	{max_items, 1},
	{subscribe, true},
	{access_model, open},
	{roster_groups_allowed, []},
	{publish_model, publishers},
	{notification_type, headline},
	{max_payload_size, ?MAX_PAYLOAD_SIZE},
	{send_last_published_item, on_sub_and_presence},
	{deliver_notifications, true},
	{presence_based_delivery, false}].

features() ->
    [<<"create-nodes">>,
	<<"auto-create">>,
	<<"access-authorize">>,
	<<"delete-nodes">>,
	<<"get-pending">>,
	<<"instant-nodes">>,
	<<"manage-subscriptions">>,
	<<"modify-affiliations">>,
	<<"outcast-affiliation">>,
	<<"publish">>,
	<<"publish-only-affiliation">>,
	<<"retrieve-affiliations">>, % TODO remove? can not fully work
	<<"retrieve-subscriptions">>, % TODO remove? can not fully work
	<<"subscribe">>,
	<<"subscription-notifications">>].

create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access) ->
    node_flat:create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access).

create_node(Nidx, Owner) ->
    node_flat:create_node(Nidx, Owner).

delete_node(Nodes) ->
    node_flat:delete_node(Nodes).

subscribe_node(Nidx, Sender, Subscriber, AccessModel,
	    SendLast, PresenceSubscription, RosterGroup, _Options) ->
    node_flat:subscribe_node(Nidx, Sender, Subscriber, AccessModel,
                             SendLast, PresenceSubscription, RosterGroup, []).

unsubscribe_node(Nidx, Sender, Subscriber, SubId) ->
    node_flat:unsubscribe_node(Nidx, Sender, Subscriber, SubId).

publish_item(Nidx, Publisher, PublishModel, _MaxItems, _ItemId, _Payload) ->
    SubKey = jid:tolower(Publisher),
    GenKey = jid:remove_resource(SubKey),
    GenState = get_state(Nidx, GenKey),
    SubState = case SubKey of
	GenKey -> GenState;
	_ -> get_state(Nidx, SubKey)
    end,
    Affiliation = GenState#pubsub_state.affiliation,
    Subscribed = case PublishModel of
	subscribers -> node_flat:is_subscribed(GenState#pubsub_state.subscriptions) orelse
		       node_flat:is_subscribed(SubState#pubsub_state.subscriptions);
	_ -> undefined
    end,
    if not ((PublishModel == open) or
		    (PublishModel == publishers) and
		    ((Affiliation == owner)
			or (Affiliation == publisher)
			or (Affiliation == publish_only))
		    or (Subscribed == true)) ->
	    {error, ?ERR_FORBIDDEN};
	true ->
            {result, {default, broadcast, []}}
    end.

remove_extra_items(_Nidx, _, ItemIds) ->
    {result, {ItemIds, []}}.

delete_item(_Nidx, _Publisher, _PublishModel, _ItemId) ->
    {error, ?ERR_FORBIDDEN}.

purge_node(_Nidx, _Owner) ->
    {error, ?ERR_FORBIDDEN}.

get_entity_affiliations(Host, Owner) ->
    node_flat:get_entity_affiliations(Host, Owner).

get_node_affiliations(Nidx) ->
    node_flat:get_node_affiliations(Nidx).

get_affiliation(Nidx, Owner) ->
    node_flat:get_affiliation(Nidx, Owner).

set_affiliation(Nidx, Owner, Affiliation) ->
    node_flat:set_affiliation(Nidx, Owner, Affiliation).

get_entity_subscriptions(Host, Owner) ->
    node_flat:get_entity_subscriptions(Host, Owner).

get_node_subscriptions(Nidx) ->
    node_flat:get_node_subscriptions(Nidx).

get_subscriptions(Nidx, Owner) ->
    node_flat:get_subscriptions(Nidx, Owner).

set_subscriptions(Nidx, Owner, Subscription, SubId) ->
    node_flat:set_subscriptions(Nidx, Owner, Subscription, SubId).

get_pending_nodes(Host, Owner) ->
    node_flat:get_pending_nodes(Host, Owner).

get_states(Nidx) ->
    node_flat:get_states(Nidx).

get_state(Nidx, USR) ->
    node_flat:get_state(Nidx, USR).

set_state(State) ->
    node_flat:set_state(State).

get_items(_Nidx, _From, _RSM) ->
    {result, {[], none}}.

get_items(_Nidx, _JID, _AccessModel, _PresenceSubscription, _RosterGroup, _SubId, _RSM) ->
    {result, {[], none}}.

get_item(_Nidx, _Id) ->
    {error, ?ERR_ITEM_NOT_FOUND}.

get_item(_Nidx, _ItemId, _JID, _AccessModel, _PresenceSubscription, _RosterGroup, _SubId) ->
    {error, ?ERR_ITEM_NOT_FOUND}.

set_item(Item) when is_record(Item, pubsub_item) ->
    ok.

get_item_name(_Host, _Node, Id) ->
    Id.

node_to_path(Node) ->
    node_flat:node_to_path(Node).

path_to_node(Path) ->
    node_flat:path_to_node(Path).

storage_location() -> local.
