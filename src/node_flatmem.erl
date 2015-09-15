%%% ====================================================================
%%% @author Christophe Romain <christophe.romain@process-one.net>
%%%   [http://www.process-one.net/]
%%% @version {@vsn}, {@date} {@time}
%%% @end
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2015   ProcessOne
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
    ets:new(pubsub_states_by_nidx, [named_table, public]),
    ets:new(pubsub_states_by_usr, [named_table, public]),
    node_flat:init(Host, ServerHost, Opts).

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
	<<"multi-subscribe">>,
	<<"outcast-affiliation">>,
	<<"publish">>,
	<<"publish-only-affiliation">>,
	<<"retrieve-affiliations">>, % TODO remove, can not fully work
	<<"retrieve-subscriptions">>, % TODO remove, can not fully work
	<<"subscribe">>,
	<<"subscription-notifications">>].

create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access) ->
    node_flat:create_node_permission(Host, ServerHost, Node, ParentNode, Owner, Access).

create_node(Nidx, Owner) ->
    OwnerKey = jlib:jid_tolower(jlib:jid_remove_resource(Owner)),
    set_state(#pubsub_state{stateid = {OwnerKey, Nidx},
	    nodeidx = Nidx, affiliation = owner}),
    {result, {default, broadcast}}.

delete_node(Nodes) ->
    Tr = fun (#pubsub_state{stateid = {J, _}, subscriptions = Ss}) ->
	    lists:map(fun (S) -> {J, S} end, Ss)
    end,
    Reply = lists:map(fun (#pubsub_node{id = Nidx} = PubsubNode) ->
		    States = del_states(Nidx),
		    {PubsubNode, lists:flatmap(Tr, States)}
	    end, Nodes),
    {result, {default, broadcast, Reply}}.

subscribe_node(Nidx, Sender, Subscriber, AccessModel,
	    SendLast, PresenceSubscription, RosterGroup, _Options) ->
    SubKey = jlib:jid_tolower(Subscriber),
    GenKey = jlib:jid_remove_resource(SubKey),
    Authorized = jlib:jid_tolower(jlib:jid_remove_resource(Sender)) == GenKey,
    GenState = get_state(Nidx, GenKey),
    SubState = case SubKey of
	GenKey -> GenState;
	_ -> get_state(Nidx, SubKey)
    end,
    Affiliation = GenState#pubsub_state.affiliation,
    Subscriptions = SubState#pubsub_state.subscriptions,
    Whitelisted = lists:member(Affiliation, [member, publisher, owner]),
    PendingSubscription = lists:any(fun
		({pending, _}) -> true;
		(_) -> false
	    end,
	    Subscriptions),
    if not Authorized ->
	    {error,
		?ERR_EXTENDED((?ERR_BAD_REQUEST), <<"invalid-jid">>)};
	(Affiliation == outcast) or (Affiliation == publish_only) ->
	    {error, ?ERR_FORBIDDEN};
	PendingSubscription ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_AUTHORIZED), <<"pending-subscription">>)};
	(AccessModel == presence) and not PresenceSubscription ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_AUTHORIZED), <<"presence-subscription-required">>)};
	(AccessModel == roster) and not RosterGroup ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_AUTHORIZED), <<"not-in-roster-group">>)};
	(AccessModel == whitelist) and not Whitelisted ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_ALLOWED), <<"closed-node">>)};
	%%MustPay ->
	%%        % Payment is required for a subscription
	%%        {error, ?ERR_PAYMENT_REQUIRED};
	%%ForbiddenAnonymous ->
	%%        % Requesting entity is anonymous
	%%        {error, ?ERR_FORBIDDEN};
	true ->
	    SubId = make_subid(),
	    NewSub = case AccessModel of
		authorize -> pending;
		_ -> subscribed
	    end,
	    set_state(SubState#pubsub_state{subscriptions =
		    [{NewSub, SubId} | Subscriptions]}),
	    case {NewSub, SendLast} of
		{subscribed, never} ->
		    {result, {default, subscribed, SubId}};
		{subscribed, _} ->
		    {result, {default, subscribed, SubId, send_last}};
		{_, _} ->
		    {result, {default, pending, SubId}}
	    end
    end.

unsubscribe_node(Nidx, Sender, Subscriber, SubId) ->
    SubKey = jlib:jid_tolower(Subscriber),
    GenKey = jlib:jid_remove_resource(SubKey),
    Authorized = jlib:jid_tolower(jlib:jid_remove_resource(Sender)) == GenKey,
    GenState = get_state(Nidx, GenKey),
    SubState = case SubKey of
	GenKey -> GenState;
	_ -> get_state(Nidx, SubKey)
    end,
    Subscriptions = lists:filter(fun
		({_Sub, _SubId}) -> true;
		(_SubId) -> false
	    end,
	    SubState#pubsub_state.subscriptions),
    SubIdExists = case SubId of
	<<>> -> false;
	Binary when is_binary(Binary) -> true;
	_ -> false
    end,
    if
	%% Requesting entity is prohibited from unsubscribing entity
	not Authorized ->
	    {error, ?ERR_FORBIDDEN};
	%% Entity did not specify SubId
	%%SubId == "", ?? ->
	%%        {error, ?ERR_EXTENDED(?ERR_BAD_REQUEST, "subid-required")};
	%% Invalid subscription identifier
	%%InvalidSubId ->
	%%        {error, ?ERR_EXTENDED(?ERR_NOT_ACCEPTABLE, "invalid-subid")};
	%% Requesting entity is not a subscriber
	Subscriptions == [] ->
	    {error,
		?ERR_EXTENDED((?ERR_UNEXPECTED_REQUEST_CANCEL), <<"not-subscribed">>)};
	%% Subid supplied, so use that.
	SubIdExists ->
	    Sub = first_in_list(fun
			({_, S}) when S == SubId -> true;
			(_) -> false
		    end,
		    SubState#pubsub_state.subscriptions),
	    case Sub of
		{value, S} ->
		    delete_subscriptions(SubKey, Nidx, [S], SubState),
		    {result, default};
		false ->
		    {error,
			?ERR_EXTENDED((?ERR_UNEXPECTED_REQUEST_CANCEL), <<"not-subscribed">>)}
	    end;
	%% Asking to remove all subscriptions to the given node
	SubId == all ->
	    delete_subscriptions(SubKey, Nidx, Subscriptions, SubState),
	    {result, default};
	%% No subid supplied, but there's only one matching subscription
	length(Subscriptions) == 1 ->
	    delete_subscriptions(SubKey, Nidx, Subscriptions, SubState),
	    {result, default};
	%% No subid and more than one possible subscription match.
	true ->
	    {error,
		?ERR_EXTENDED((?ERR_BAD_REQUEST), <<"subid-required">>)}
    end.

publish_item(Nidx, Publisher, PublishModel, _MaxItems, _ItemId, _Payload) ->
    SubKey = jlib:jid_tolower(Publisher),
    GenKey = jlib:jid_remove_resource(SubKey),
    GenState = get_state(Nidx, GenKey),
    SubState = case SubKey of
	GenKey -> GenState;
	_ -> get_state(Nidx, SubKey)
    end,
    Affiliation = GenState#pubsub_state.affiliation,
    Subscribed = case PublishModel of
	subscribers -> is_subscribed(GenState#pubsub_state.subscriptions) orelse
		       is_subscribed(SubState#pubsub_state.subscriptions);
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
    SubKey = jlib:jid_tolower(Owner),
    GenKey = jlib:jid_remove_resource(SubKey),
    States = get_states_by_usr(GenKey),
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (#pubsub_state{stateid = {_, N}, affiliation = A}, Acc) ->
		    case NodeTree:get_node(N) of
			#pubsub_node{nodeid = {Host, _}} = Node -> [{Node, A} | Acc];
			_ -> Acc
		    end
	    end,
	    [], States),
    {result, Reply}.

get_node_affiliations(Nidx) ->
    States = get_states(Nidx),
    Tr = fun (#pubsub_state{stateid = {J, _}, affiliation = A}) -> {J, A} end,
    {result, lists:map(Tr, States)}.

get_affiliation(Nidx, Owner) ->
    SubKey = jlib:jid_tolower(Owner),
    GenKey = jlib:jid_remove_resource(SubKey),
    #pubsub_state{affiliation = Affiliation} = get_state(Nidx, GenKey),
    {result, Affiliation}.

set_affiliation(Nidx, Owner, Affiliation) ->
    SubKey = jlib:jid_tolower(Owner),
    GenKey = jlib:jid_remove_resource(SubKey),
    GenState = get_state(Nidx, GenKey),
    case {Affiliation, GenState#pubsub_state.subscriptions} of
	{none, []} -> del_state(Nidx, GenKey);
	_ -> set_state(GenState#pubsub_state{affiliation = Affiliation})
    end.

get_entity_subscriptions(Host, Owner) ->
    SubKey = jlib:jid_tolower(Owner),
    GenKey = jlib:jid_remove_resource(SubKey),
    States = case SubKey of
	GenKey ->
	    get_states_by_usr(GenKey);
	_ ->
	    get_states_by_usr(GenKey)
	    ++
	    get_states_by_usr(SubKey)
    end,
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (#pubsub_state{stateid = {J, N}, subscriptions = Ss}, Acc) ->
		    case NodeTree:get_node(N) of
			#pubsub_node{nodeid = {Host, _}} = Node ->
			    lists:foldl(fun ({Sub, SubId}, Acc2) ->
					[{Node, Sub, SubId, J} | Acc2]
				end,
				Acc, Ss);
			_ ->
			    Acc
		    end
	    end,
	    [], States),
    {result, Reply}.

get_node_subscriptions(Nidx) ->
    States = get_states(Nidx),
    Tr = fun (#pubsub_state{stateid = {J, _}, subscriptions = Subscriptions}) ->
	    case Subscriptions of
		[_ | _] ->
		    lists:foldl(fun ({S, SubId}, Acc) ->
				[{J, S, SubId} | Acc]
			end,
			[], Subscriptions);
		[] ->
		    [];
		_ ->
		    [{J, none}]
	    end
    end,
    {result, lists:flatmap(Tr, States)}.

get_subscriptions(Nidx, Owner) ->
    SubKey = jlib:jid_tolower(Owner),
    SubState = get_state(Nidx, SubKey),
    {result, SubState#pubsub_state.subscriptions}.

set_subscriptions(Nidx, Owner, Subscription, SubId) ->
    SubKey = jlib:jid_tolower(Owner),
    SubState = get_state(Nidx, SubKey),
    case {SubId, SubState#pubsub_state.subscriptions} of
	{_, []} ->
	    case Subscription of
		none ->
		    {error,
			?ERR_EXTENDED((?ERR_BAD_REQUEST), <<"not-subscribed">>)};
		_ ->
		    new_subscription(Nidx, Owner, Subscription, SubState)
	    end;
	{<<>>, [{_, SID}]} ->
	    case Subscription of
		none -> unsub_with_subid(Nidx, SID, SubState);
		_ -> replace_subscription({Subscription, SID}, SubState)
	    end;
	{<<>>, [_ | _]} ->
	    {error,
		?ERR_EXTENDED((?ERR_BAD_REQUEST), <<"subid-required">>)};
	_ ->
	    case Subscription of
		none -> unsub_with_subid(Nidx, SubId, SubState);
		_ -> replace_subscription({Subscription, SubId}, SubState)
	    end
    end.

replace_subscription(NewSub, SubState) ->
    NewSubs = replace_subscription(NewSub, SubState#pubsub_state.subscriptions, []),
    set_state(SubState#pubsub_state{subscriptions = NewSubs}).

replace_subscription(_, [], Acc) -> Acc;
replace_subscription({Sub, SubId}, [{_, SubId} | T], Acc) ->
    replace_subscription({Sub, SubId}, T, [{Sub, SubId} | Acc]).

new_subscription(_Nidx, _Owner, Sub, SubState) ->
    SubId = make_subid(),
    Subs = SubState#pubsub_state.subscriptions,
    set_state(SubState#pubsub_state{subscriptions = [{Sub, SubId} | Subs]}),
    {Sub, SubId}.

delete_subscriptions(SubKey, Nidx, Subscriptions, SubState) ->
    NewSubs = lists:foldl(fun ({Subscription, SubId}, Acc) ->
		    Acc -- [{Subscription, SubId}]
	    end, SubState#pubsub_state.subscriptions, Subscriptions),
    case {SubState#pubsub_state.affiliation, NewSubs} of
	{none, []} -> del_state(Nidx, SubKey);
	_          -> set_state(SubState#pubsub_state{subscriptions = NewSubs})
    end.

unsub_with_subid(Nidx, SubId, #pubsub_state{stateid = {Entity, _}} = SubState) ->
    NewSubs = [{S, Sid}
	    || {S, Sid} <- SubState#pubsub_state.subscriptions,
		SubId =/= Sid],
    case {NewSubs, SubState#pubsub_state.affiliation} of
	{[], none} -> del_state(Nidx, Entity);
	_ -> set_state(SubState#pubsub_state{subscriptions = NewSubs})
    end.

get_pending_nodes(Host, Owner) ->
    GenKey = jlib:jid_remove_resource(jlib:jid_tolower(Owner)),
    NodeIdxs = [Nidx || #pubsub_state{stateid={_,Nidx}, affiliation=Aff}
			<- get_states_by_usr(GenKey),
			Aff==owner],
    NodeTree = mod_pubsub:tree(Host),
    Reply = lists:foldl(fun (Nidx, Acc) ->
		    States = get_states(Nidx),
		    acc_pending(States, NodeTree, Acc)
	    end,
	    [], NodeIdxs),
    {result, Reply}.

acc_pending([], _, Acc) -> Acc;
acc_pending([#pubsub_state{stateid = {_, Nidx}, subscriptions = Subs}|Tail], NodeTree, Acc) ->
    HasPending = fun
	({pending, _}) -> true;
	(pending) -> true;
	(_) -> false
    end,
    case lists:any(HasPending, Subs) of
	true ->
	    case NodeTree:get_node(Nidx) of
		#pubsub_node{nodeid = {_, Node}} -> acc_pending(Tail, NodeTree, [Node|Acc]);
		_ -> acc_pending(Tail, NodeTree, Acc)
	    end;
	false ->
	    acc_pending(Tail, NodeTree, Acc)
    end.

get_states(Nidx) ->
    get_states_by_nidx(Nidx).
get_states_by_nidx(Nidx) ->
    case ets:lookup(pubsub_states_by_nidx, Nidx) of
	[{_, Dict}] ->
	    dict:fold(fun(USR, {Aff, Subs}, Acc) ->
			State = #pubsub_state{
				stateid = {USR, Nidx},
				nodeidx = Nidx,
				affiliation = Aff,
				subscriptions = Subs},
			[State|Acc]
		end, [], Dict);
	_ ->
	    []
    end.
get_states_by_usr(USR) ->
    case ets:lookup(pubsub_states_by_usr, USR) of
	[{_, Dict}] ->
	    dict:fold(fun(Nidx, {Aff, Subs}, Acc) ->
			State = #pubsub_state{
				stateid = {USR, Nidx},
				nodeidx = Nidx,
				affiliation = Aff,
				subscriptions = Subs},
			[State|Acc]
		end, [], Dict);
	_ ->
	    []
    end.

get_state(Nidx, USR) ->
    State = #pubsub_state{stateid = {USR, Nidx}, nodeidx = Nidx},
    case ets:lookup(pubsub_states_by_nidx, Nidx) of
	[{_, Dict}] ->
	    case dict:find(USR, Dict) of
		{ok, {Aff, Subs}} ->
		    State#pubsub_state{
			affiliation = Aff,
			subscriptions = Subs};
		error ->
		    State
	    end;
	_ ->
	    State
    end.

set_state(State) when is_record(State, pubsub_state) ->
    {USR, Nidx} = State#pubsub_state.stateid,
    Value = {State#pubsub_state.affiliation, State#pubsub_state.subscriptions},
    set_state_entry(pubsub_states_by_nidx, Nidx, USR, Value),
    set_state_entry(pubsub_states_by_usr, USR, Nidx, Value),
    ok.

del_states(Nidx) ->
    case ets:lookup(pubsub_states_by_nidx, Nidx) of
	[{_, Dict}] ->
	    States = dict:fold(fun(USR, {Aff, Subs}, Acc) ->
			del_state_entry(pubsub_states_by_usr, USR, Nidx),
			State = #pubsub_state{
				stateid = {USR, Nidx},
				nodeidx = Nidx,
				affiliation = Aff,
				subscriptions = Subs},
			[State|Acc]
		end, [], Dict),
	    ets:delete(pubsub_states_by_nidx, Nidx),
	    States;
	_ ->
	    []
    end.
del_state(Nidx, USR) ->
    del_state_entry(pubsub_states_by_nidx, Nidx, USR),
    del_state_entry(pubsub_states_by_usr, USR, Nidx).

set_state_entry(Table, Key, Entry, Value) ->
    New = case ets:lookup(Table, Key) of
	[{_, Dict}] -> dict:store(Entry, Value, Dict);
	_ -> dict:store(Entry, Value, dict:new())
    end,
    ets:insert(Table, {Key, New}).

del_state_entry(Table, Key, Entry) ->
    case ets:lookup(Table, Key) of
	[{_, Dict}] ->
	    New = dict:erase(Entry, Dict),
	    case dict:size(New) of
		0 -> ets:delete(Table, Key);
		_ -> ets:insert(Table, {Key, New})
	    end;
	_ ->
	    ok
    end.

get_items(_Nidx, _From, _RSM) ->
    {result, {[], none}}.

get_items(Nidx, JID, AccessModel, PresenceSubscription, RosterGroup, _SubId, RSM) ->
    SubKey = jlib:jid_tolower(JID),
    GenKey = jlib:jid_remove_resource(SubKey),
    GenState = get_state(Nidx, GenKey),
    SubState = get_state(Nidx, SubKey),
    Affiliation = GenState#pubsub_state.affiliation,
    BareSubscriptions = GenState#pubsub_state.subscriptions,
    FullSubscriptions = SubState#pubsub_state.subscriptions,
    Whitelisted = can_fetch_item(Affiliation, BareSubscriptions) orelse
		  can_fetch_item(Affiliation, FullSubscriptions),
    if %%SubId == "", ?? ->
	%% Entity has multiple subscriptions to the node but does not specify a subscription ID
	%{error, ?ERR_EXTENDED(?ERR_BAD_REQUEST, "subid-required")};
	%%InvalidSubId ->
	%% Entity is subscribed but specifies an invalid subscription ID
	%{error, ?ERR_EXTENDED(?ERR_NOT_ACCEPTABLE, "invalid-subid")};
	(Affiliation == outcast) or (Affiliation == publish_only) ->
	    {error, ?ERR_FORBIDDEN};
	(AccessModel == presence) and not PresenceSubscription ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_AUTHORIZED), <<"presence-subscription-required">>)};
	(AccessModel == roster) and not RosterGroup ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_AUTHORIZED), <<"not-in-roster-group">>)};
	(AccessModel == whitelist) and not Whitelisted ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_ALLOWED), <<"closed-node">>)};
	(AccessModel == authorize) and not Whitelisted ->
	    {error, ?ERR_FORBIDDEN};
	%%MustPay ->
	%%        % Payment is required for a subscription
	%%        {error, ?ERR_PAYMENT_REQUIRED};
	true ->
	    get_items(Nidx, JID, RSM)
    end.

get_item(_Nidx, _Id) ->
    {error, ?ERR_ITEM_NOT_FOUND}.

get_item(Nidx, ItemId, JID, AccessModel, PresenceSubscription, RosterGroup, _SubId) ->
    SubKey = jlib:jid_tolower(JID),
    GenKey = jlib:jid_remove_resource(SubKey),
    GenState = get_state(Nidx, GenKey),
    Affiliation = GenState#pubsub_state.affiliation,
    Subscriptions = GenState#pubsub_state.subscriptions,
    Whitelisted = can_fetch_item(Affiliation, Subscriptions),
    if %%SubId == "", ?? ->
	%% Entity has multiple subscriptions to the node but does not specify a subscription ID
	%{error, ?ERR_EXTENDED(?ERR_BAD_REQUEST, "subid-required")};
	%%InvalidSubId ->
	%% Entity is subscribed but specifies an invalid subscription ID
	%{error, ?ERR_EXTENDED(?ERR_NOT_ACCEPTABLE, "invalid-subid")};
	(Affiliation == outcast) or (Affiliation == publish_only) ->
	    {error, ?ERR_FORBIDDEN};
	(AccessModel == presence) and not PresenceSubscription ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_AUTHORIZED), <<"presence-subscription-required">>)};
	(AccessModel == roster) and not RosterGroup ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_AUTHORIZED), <<"not-in-roster-group">>)};
	(AccessModel == whitelist) and not Whitelisted ->
	    {error,
		?ERR_EXTENDED((?ERR_NOT_ALLOWED), <<"closed-node">>)};
	(AccessModel == authorize) and not Whitelisted ->
	    {error, ?ERR_FORBIDDEN};
	%%MustPay ->
	%%        % Payment is required for a subscription
	%%        {error, ?ERR_PAYMENT_REQUIRED};
	true ->
	    get_item(Nidx, ItemId)
    end.

set_item(Item) when is_record(Item, pubsub_item) ->
    ok.

get_item_name(_Host, _Node, Id) ->
    Id.

node_to_path(Node) ->
    node_flat:node_to_path(Node).

path_to_node(Path) ->
    node_flat:path_to_node(Path).

storage_location() -> local.

can_fetch_item(owner, _) -> true;
can_fetch_item(member, _) -> true;
can_fetch_item(publisher, _) -> true;
can_fetch_item(publish_only, _) -> false;
can_fetch_item(outcast, _) -> false;
can_fetch_item(none, Subscriptions) -> is_subscribed(Subscriptions).
%can_fetch_item(_Affiliation, _Subscription) -> false.

is_subscribed(Subscriptions) ->
    lists:any(fun
	    ({subscribed, _SubId}) -> true;
	    (_) -> false
	end,
	Subscriptions).

first_in_list(_Pred, []) ->
    false;
first_in_list(Pred, [H | T]) ->
    case Pred(H) of
	true -> {value, H};
	_ -> first_in_list(Pred, T)
    end.

make_subid() ->
    {T1, T2, T3} = os:timestamp(),
    iolist_to_binary(io_lib:fwrite("~.36B~.36B~.36B", [T1, T2, T3])).
