%%%----------------------------------------------------------------------
%%% File    : pubsub_utils.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Provide helpers to debug pubsub server and migrate databases
%%% Created : 16 Sep 2010 by Christophe Romain <christophe.romain@process-one.net>
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

-module(pubsub_utils).

-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").
-include("logger.hrl").

-compile(export_all).

-spec nodeid
    (
	Host :: mod_pubsub:host(),
	Node :: mod_pubsub:nodeId())
    -> mod_pubsub:nodeIdx() | 0.
nodeid(Host, Node) ->
    case mnesia:dirty_read({pubsub_node, {Host, Node}}) of
	[N] -> nodeid(N);
	_ -> 0
    end.

nodeid(N) -> N#pubsub_node.id.

-spec nodeids() -> [0 | mod_pubsub:nodeIdx()].

nodeids() ->
    [nodeid(Host, Node)
	|| {Host, Node} <- mnesia:dirty_all_keys(pubsub_node)].

-spec nodeids_by_type
    (
	Type :: binary())
    -> [0 | mod_pubsub:nodeIdx()].
nodeids_by_type(Type) ->
    [nodeid(N)
	|| N
	    <- mnesia:dirty_match_object(#pubsub_node{type = Type, _ = '_'})].

nodeids_by_option(Key, Value) ->
    [nodeid(N)
	|| N
	    <- mnesia:dirty_match_object(#pubsub_node{_ = '_'}),
	    lists:member({Key, Value}, N#pubsub_node.options)].

nodeids_by_owner(JID) ->
    [nodeid(N)
	|| N
	    <- mnesia:dirty_match_object(#pubsub_node{_ = '_'}),
	    lists:member(JID, N#pubsub_node.owners)].

nodes_by_id(I) ->
    mnesia:dirty_match_object(#pubsub_node{id = I, _ = '_'}).

nodes() ->
    [element(2, element(2, N))
	|| N
	    <- mnesia:dirty_match_object(#pubsub_node{_ = '_'})].

state(JID, NodeId) ->
    case mnesia:dirty_read({pubsub_state, {JID, NodeId}}) of
	[S] -> S;
	_ -> undefined
    end.

states(NodeId) ->
    mnesia:dirty_index_read(pubsub_state, NodeId, #pubsub_state.nodeidx).

stateid(S) -> element(1, S#pubsub_state.stateid).

stateids(NodeId) -> [stateid(S) || S <- states(NodeId)].

states_by_jid(JID) ->
    mnesia:dirty_match_object(#pubsub_state{stateid = {JID, '_'}, _ = '_'}).

item(ItemId, NodeId) ->
    case mnesia:dirty_read({pubsub_item, {ItemId, NodeId}}) of
	[I] -> I;
	_ -> undefined
    end.

items(NodeId) ->
    mnesia:dirty_index_read(pubsub_item, NodeId,
	#pubsub_item.nodeidx).

itemid(I) -> element(1, I#pubsub_item.itemid).

itemids(NodeId) -> [itemid(I) || I <- items(NodeId)].

items_by_id(ItemId) ->
    mnesia:dirty_match_object(#pubsub_item{itemid = {ItemId, '_'}, _ = '_'}).

affiliated(NodeId) ->
    [stateid(S)
	|| S <- states(NodeId),
	    S#pubsub_state.affiliation =/= none].

subscribed(NodeId) ->
    [stateid(S)
	|| S <- states(NodeId),
	    S#pubsub_state.subscriptions =/= []].

offline_subscribers(NodeId) ->
    lists:filter(fun
	    ({U, S, <<"">>}) -> ejabberd_sm:get_user_resources(U, S) == [];
	    ({U, S, R}) -> not lists:member(R, ejabberd_sm:get_user_resources(U, S))
	end,
	subscribed(NodeId)).


owners(NodeId) ->
    [stateid(S)
	|| S <- states(NodeId),
	    S#pubsub_state.affiliation == owner].

orphan_items(NodeId) ->
    itemids(NodeId) --
    lists:foldl(fun (S, A) -> A ++ S#pubsub_state.items end,
	[], states(NodeId)).

newer_items(NodeId, Seconds) ->
    Now = calendar:universal_time(),
    Oldest = calendar:seconds_to_daystime(Seconds),
    [itemid(I)
	|| I <- items(NodeId),
	    calendar:time_difference(calendar:now_to_universal_time(element(1, I#pubsub_item.modification)), Now)
	    < Oldest].

older_items(NodeId, Seconds) ->
    Now = calendar:universal_time(),
    Oldest = calendar:seconds_to_daystime(Seconds),
    [itemid(I)
	|| I <- items(NodeId),
	    calendar:time_difference(calendar:now_to_universal_time(element(1, I#pubsub_item.modification)), Now)
	    > Oldest].

orphan_nodes() ->
    [I || I <- nodeids(), owners(I) == []].

duplicated_nodes() ->
    L = nodeids(),
    lists:usort(L -- lists:seq(1, lists:max(L))).

node_options(NodeId) ->
    [N] = mnesia:dirty_match_object(#pubsub_node{id = NodeId, _ = '_'}),
    N#pubsub_node.options.

update_node_options(Key, Value, NodeId) ->
    [N] = mnesia:dirty_match_object(#pubsub_node{id = NodeId, _ = '_'}),
    NewOptions = lists:keyreplace(Key, 1, N#pubsub_node.options, {Key, Value}),
    mnesia:dirty_write(N#pubsub_node{options = NewOptions}).

check() ->
    mnesia:transaction(fun () ->
		case mnesia:read({pubsub_index, node}) of
		    [Idx] ->
			Free = Idx#pubsub_index.free,
			Last = Idx#pubsub_index.last,
			Allocated = lists:seq(1, Last) -- Free,
			NodeIds = mnesia:foldl(fun (N, A) ->
					[nodeid(N) | A]
				end,
				[], pubsub_node),
			StateIds = lists:usort(mnesia:foldl(fun (S, A) ->
					    [element(2, S#pubsub_state.stateid) | A]
				    end,
				    [], pubsub_state)),
			ItemIds = lists:usort(mnesia:foldl(fun (I, A) ->
					    [element(2, I#pubsub_item.itemid) | A]
				    end,
				    [], pubsub_item)),
			BadNodeIds = NodeIds -- Allocated,
			BadStateIds = StateIds -- NodeIds,
			BadItemIds = ItemIds -- NodeIds,
			Lost = Allocated -- NodeIds,
			[{bad_nodes,
				[N#pubsub_node.nodeid
				    || N <- lists:flatten([mnesia:match_object(#pubsub_node{id = I, _ = '_'})
						|| I <- BadNodeIds])]},
			    {bad_states,
				lists:foldl(fun (N, A) ->
					    A ++ [{I, N} || I <- stateids(N)]
				    end,
				    [], BadStateIds)},
			    {bad_items,
				lists:foldl(fun (N, A) ->
					    A ++ [{I, N} || I <- itemids(N)]
				    end,
				    [], BadItemIds)},
			    {lost_idx, Lost},
			    {orphaned,
				[I || I <- NodeIds, owners(I) == []]},
			    {duplicated,
				lists:usort(NodeIds -- lists:seq(1, lists:max(NodeIds)))}];
		    _ ->
			no_index
		end
	end).

rebuild_index() ->
    mnesia:transaction(fun () ->
		NodeIds = mnesia:foldl(fun (N, A) ->
				[nodeid(N) | A]
			end,
			[], pubsub_node),
		Last = lists:max(NodeIds),
		Free = lists:seq(1, Last) -- NodeIds,
		mnesia:write(#pubsub_index{index = node, last = Last, free = Free})
	end).

pep_subscriptions(LUser, LServer, LResource) ->
    case ejabberd_sm:get_session_pid(LUser, LServer, LResource) of
	C2SPid when is_pid(C2SPid) ->
	    case catch ejabberd_c2s:get_subscribed(C2SPid) of
		Contacts when is_list(Contacts) ->
		    lists:map(fun ({U, S, _}) ->
				io_lib:format("~s@~s", [U, S])
			end,
			Contacts);
		_ ->
		    []
	    end;
	_ ->
	    []
    end.

purge_offline_subscriptions() ->
    lists:foreach(fun (K) ->
		[N] = mnesia:dirty_read({pubsub_node, K}),
		I = element(3, N),
		lists:foreach(fun (JID) ->
			    case mnesia:dirty_read({pubsub_state, {JID, I}}) of
				[{pubsub_state, K, _, _, _, [{subscribed, S}]}] ->
				    mnesia:dirty_delete({pubsub_subscription, S});
				_ ->
				    ok
			    end,
			    mnesia:dirty_delete({pubsub_state, {JID, I}})
		    end,
		    offline_subscribers(I))
	end,
	mnesia:dirty_all_keys(pubsub_node)).

%%
%% database migration helpers
%%

mnesia_to(DbType, Host, ServerHost) ->
    % in case the table was created using a 'ejabberdctl load', extra
    % index may be missing
    mnesia:add_table_index(pubsub_item, nodeidx),

    update_node_database(Host, ServerHost),
    update_state_database(Host, ServerHost),
    update_lastitem_database(Host, ServerHost),
    update_item_database(Host, ServerHost),

    Method = list_to_atom("write_" ++ atom_to_list(DbType)),
    F = fun (Node, Acc) ->
		Nidx = Node#pubsub_node.id,
		?DEBUG("Nidx ~p", [Nidx]),
		{result, States} = node_flat:get_states(Nidx),
		?DEBUG("States ~p", [States]),
		{result, {Items, _}} = node_flat:get_items(Nidx, undefined, none),
		?DEBUG("Items ~p", [Items]),
		Res = ?MODULE:Method(Node, States, Items),
		?DEBUG("Res ~p", [Res]),
		[Res | Acc]
	end,

    {atomic, Result} = mnesia:transaction(fun mnesia:foldl/3, [F, [], pubsub_node]),
    Result.

write_p1db(Node, States, Items) ->
    nodetree_tree_p1db:set_node(Node),
    Nidx = nodetree_tree_p1db:enc_key(Node#pubsub_node.nodeid),
    [node_flat_p1db:set_state(state_to_p1db(Nidx, State)) || State <- States],
    [node_flat_p1db:set_item(item_to_p1db(Nidx, Item)) || Item <- Items],
    ok. 

state_to_p1db(Nidx, State) ->
    {ID, _} = State#pubsub_state.stateid,
    State#pubsub_state{stateid = {ID, Nidx}, nodeidx=Nidx}.
item_to_p1db(Nidx, Item) ->
    {ID, _} = Item#pubsub_item.itemid,
    Item#pubsub_item{itemid = {ID, Nidx}, nodeidx=Nidx}.

write_sql(Node, States, Items) ->
    nodetree_tree_sql:set_node(Node),
    [node_flat_sql:set_state(State) || State <- States],
    [node_flat_sql:set_item(Item) || Item <- Items],
    ok.


rename_default_nodeplugin() ->
    lists:foreach(fun (Node) ->
		mnesia:dirty_write(Node#pubsub_node{type = <<"hometree">>})
	end,
	mnesia:dirty_match_object(#pubsub_node{type = <<"default">>, _ = '_'})).


update_node_database_binary() ->
    F = fun () ->
	    case catch mnesia:read({pubsub_node, mnesia:first(pubsub_node)}) of
		[First] when is_list(First#pubsub_node.type) ->
		    ?INFO_MSG("Binarization of pubsub nodes table...", []),
		    lists:foreach(fun ({H, N}) ->
				[Node] = mnesia:read({pubsub_node, {H, N}}),

				Type = iolist_to_binary(Node#pubsub_node.type),
				BN = case N of
				    Binary when is_binary(Binary) ->
					N;
				    _ ->
					{result, BN1} = mod_pubsub:node_call(H, Type, path_to_node, [N]),
					BN1
				end,
				BP = case [case P of
					    Binary2 when is_binary(Binary2) -> P;
					    _ -> element(2, mod_pubsub:node_call(H, Type, path_to_node, [P]))
					end
					|| P <- Node#pubsub_node.parents] of
				    [<<>>] -> [];
				    Parents -> Parents
				end,

				BH = case H of
				    {U, S, R} -> binarize_ljid({U, S, R});
				    String -> iolist_to_binary(String)
				end,

				Owners = [binarize_ljid(USR) || USR <- Node#pubsub_node.owners],

				ok = mnesia:delete({pubsub_node, {H, N}}),
				ok = mnesia:write(Node#pubsub_node{nodeid = {BH, BN},
					    parents = BP,
					    type = Type,
					    owners = Owners});
			    (_) -> ok
			end,
			mnesia:all_keys(pubsub_node));
		_-> no_need
	    end
    end,
    case mnesia:transaction(F) of
	{aborted, Reason} ->
	    ?ERROR_MSG("Failed to binarize pubsub node table: ~p", [Reason]);
	{atomic, no_need} ->
	    ok;
	{atomic, Result} ->
	    ?INFO_MSG("Pubsub nodes table has been binarized: ~p", [Result])
    end.

update_node_database(Host, ServerHost) ->
    mnesia:del_table_index(pubsub_node, type),
    mnesia:del_table_index(pubsub_node, parentid),
    case catch mnesia:table_info(pubsub_node, attributes) of
	[host_node, host_parent, info] ->
	    ?INFO_MSG("Upgrading pubsub nodes table...", []),
	    F = fun () ->
		    {Result, LastIdx} = lists:foldl(fun
				({pubsub_node, NodeId, ParentId, {nodeinfo, Items, Options, Entities}},
					    {RecList, NodeIdx}) ->
				    ItemsList =
					lists:foldl(fun
						({item, IID, Publisher, Payload}, Acc) ->
						    C = {unknown, Publisher},
						    M = {p1_time_compat:timestamp(), Publisher},
						    mnesia:write(#pubsub_item{
							    itemid = {IID, NodeIdx},
							    creation = C,
							    modification = M,
							    payload = Payload}),
						    [{Publisher, IID} | Acc]
					    end,
					    [], Items),
				    Owners =
					dict:fold(fun
						(JID, {entity, Aff, Sub}, Acc) ->
						    UsrItems = lists:foldl(fun
								({P, I}, IAcc) ->
								    case P of
									JID -> [I | IAcc];
									_ -> IAcc
								    end
							    end,
							    [], ItemsList),
						    mnesia:write({pubsub_state, {JID, NodeIdx}, UsrItems, Aff, Sub}),
						    case Aff of
							owner -> [JID | Acc];
							_ -> Acc
						    end
					    end,
					    [], Entities),
				    mnesia:delete({pubsub_node, NodeId}),
				    {[#pubsub_node{nodeid = NodeId,
						id = NodeIdx,
						parents = [element(2, ParentId)],
						owners = Owners,
						options = Options}
					    | RecList], NodeIdx + 1}
			    end,
			    {[], 1},
			    mnesia:match_object({pubsub_node, {Host, '_'}, '_', '_'})),
		    mnesia:write(#pubsub_index{index = node, last = LastIdx, free = []}),
		    Result
	    end,
	    {atomic, NewRecords} = mnesia:transaction(F),
	    {atomic, ok} = mnesia:delete_table(pubsub_node),
	    {atomic, ok} = mnesia:create_table(pubsub_node,
		    [{disc_copies, [node()]},
			{attributes, record_info(fields, pubsub_node)}]),
	    FNew = fun () -> [mnesia:write(Rec) || Rec <- NewRecords] end,
	    case mnesia:transaction(FNew) of
		{atomic, Result} ->
		    ?INFO_MSG("Pubsub node tables upgraded: ~p", [Result]);
		{aborted, Reason} ->
		    ?ERROR_MSG("Problem upgrading Pubsub node tables:~n~p", [Reason])
	    end;
	[nodeid, parentid, type, owners, options] ->
	    F = fun ({pubsub_node, NodeId, {_, Parent}, Type, Owners, Options}) ->
		    #pubsub_node{nodeid = NodeId, id = 0,
			parents = [Parent], type = Type,
			owners = Owners, options = Options}
	    end,
	    mnesia:transform_table(pubsub_node, F, [nodeid, id, parents, type, owners, options]),
	    FNew = fun () ->
		    LastIdx = lists:foldl(fun (#pubsub_node{nodeid = NodeId} = PubsubNode, NodeIdx) ->
				    mnesia:write(PubsubNode#pubsub_node{id = NodeIdx}),
				    lists:foreach(fun
					    (#pubsub_state{stateid = StateId} = State) ->
						{JID, _} = StateId,
						mnesia:delete({pubsub_state, StateId}),
						mnesia:write(State#pubsub_state{stateid = {JID, NodeIdx}})
					end,
					mnesia:match_object(#pubsub_state{stateid = {'_', NodeId}, _ = '_'})),
				    lists:foreach(fun
					    (#pubsub_item{itemid = ItemId} = Item) ->
						{IID, _} = ItemId,
						{M1, M2} = Item#pubsub_item.modification,
						{C1, C2} = Item#pubsub_item.creation,
						mnesia:delete({pubsub_item, ItemId}),
						mnesia:write(Item#pubsub_item{itemid = {IID, NodeIdx},
							modification = {M2, M1},
							creation = {C2, C1}})
					end,
					mnesia:match_object(#pubsub_item{itemid = {'_', NodeId}, _ = '_'})),
				    NodeIdx + 1
			    end,
			    1, mnesia:match_object({pubsub_node, {Host, '_'}, '_', '_', '_', '_', '_'})
			    ++
			    mnesia:match_object({pubsub_node, {{'_', ServerHost, '_'}, '_'}, '_', '_', '_', '_', '_'})),
		    mnesia:write(#pubsub_index{index = node, last = LastIdx, free = []})
	    end,
	    case mnesia:transaction(FNew) of
		{atomic, Result} ->
		    rename_default_nodeplugin(),
		    ?INFO_MSG("Pubsub node tables upgraded: ~p", [Result]);
		{aborted, Reason} ->
		    ?ERROR_MSG("Problem upgrading Pubsub node tables:~n~p", [Reason])
	    end;
	[nodeid, id, parent, type, owners, options] ->
	    F = fun ({pubsub_node, NodeId, Id, Parent, Type, Owners, Options}) ->
		    #pubsub_node{nodeid = NodeId, id = Id,
			parents = [Parent], type = Type,
			owners = Owners, options = Options}
	    end,
	    mnesia:transform_table(pubsub_node, F, [nodeid, id, parents, type, owners, options]),
	    rename_default_nodeplugin();
	_ -> ok
    end,
    update_node_database_binary().


update_state_database_binary() ->
    F = fun () ->
		case catch mnesia:read({pubsub_state, mnesia:first(pubsub_state)}) of
		    [First] when is_list(element(2, element(1, First#pubsub_state.stateid))) ->
			?INFO_MSG("Binarization of pubsub state table...", []),
			lists:foreach(fun (Id) ->
					      [State] = mnesia:read({pubsub_state, Id}),
					      {{A, B, C}, N} = State#pubsub_state.stateid,
					      ok = mnesia:delete({pubsub_state, Id}),
					      ok = mnesia:write(State#pubsub_state{stateid={binarize_ljid({A, B, C}), N}})
				      end,
				      mnesia:all_keys(pubsub_state));
		    _-> no_need
		end
	end,
    case mnesia:transaction(F) of
	{aborted, Reason} ->
	    ?ERROR_MSG("Failed to binarize pubsub state table: ~p", [Reason]);
	{atomic, no_need} ->
	    ok;
	{atomic, Result} ->
	    ?INFO_MSG("Pubsub state table has been binarized: ~p", [Result])
    end.

update_state_database(_Host, _ServerHost) ->
    case catch mnesia:table_info(pubsub_state, attributes)
    of
	[stateid, nodeidx, items, affiliation, subscription] ->
	    ?INFO_MSG("Upgrading pubsub states table...", []),
	    F = fun ({pubsub_state, {{U,S,R}, NodeId}, _NodeIdx, Items, Aff, Sub}, Acc) ->
		    JID = binarize_ljid({U, S, R}),
		    Subs = case Sub of
			none ->
			    [];
			[] ->
			    [];
			_ ->
			    {result, SubID} = pubsub_subscription:subscribe_node(JID, NodeId, []),
			    [{Sub, SubID}]
		    end,
		    NewState = #pubsub_state{stateid = {JID, NodeId},
			    items = Items, affiliation = Aff,
			    subscriptions = Subs},
		    [NewState | Acc]
	    end,
	    {atomic, NewRecs} = mnesia:transaction(fun mnesia:foldl/3, [F, [], pubsub_state]),
	    {atomic, ok} = mnesia:delete_table(pubsub_state),
	    {atomic, ok} = mnesia:create_table(pubsub_state,
		    [{disc_copies, [node()]},
			{type, ordered_set},
			{attributes, record_info(fields, pubsub_state)}]),
	    FNew = fun () -> [mnesia:write(Rec) || Rec <- NewRecs] end,
	    case mnesia:transaction(FNew) of
		{atomic, Result} ->
		    ?INFO_MSG("Pubsub states table upgraded: ~p", [Result]);
		{aborted, Reason} ->
		    ?ERROR_MSG("Problem upgrading Pubsub state tables:~n~p", [Reason])
	    end;
	[stateid, items, affiliation, subscriptions] ->
	    ?INFO_MSG("upgrade state pubsub table", []),
	    F = fun ({pubsub_state, {JID, Nidx}, Items, Aff, Subs}, Acc) ->
		    NewState = #pubsub_state{stateid = {JID, Nidx},
			    nodeidx = Nidx, items = Items,
			    affiliation = Aff,
			    subscriptions = Subs},
		    [NewState | Acc]
	    end,
	    {atomic, NewRecs} = mnesia:transaction(fun mnesia:foldl/3, [F, [], pubsub_state]),
	    {atomic, ok} = mnesia:delete_table(pubsub_state),
	    {atomic, ok} = mnesia:create_table(pubsub_state,
		    [{disc_copies, [node()]},
			{type, ordered_set},
			{attributes, record_info(fields, pubsub_state)}]),
	    FNew = fun () -> [mnesia:write(Rec) || Rec <- NewRecs] end,
	    case mnesia:transaction(FNew) of
		{atomic, Res1} ->
		    ?INFO_MSG("Pubsub states table upgraded: ~p", [Res1]);
		{aborted, Rea1} ->
		    ?ERROR_MSG("Problem updating Pubsub state table:~n~p", [Rea1])
	    end,
	    ?INFO_MSG("upgrade item pubsub table", []),
	    F = fun ({pubsub_item, {ItemId, Nidx}, C, M, P}, Acc) ->
		    NewItem = #pubsub_item{itemid = {ItemId, Nidx},
			    nodeidx = Nidx, creation = C,
			    modification = M, payload = P},
		    [NewItem | Acc]
	    end,
	    {atomic, NewRecs} = mnesia:transaction(fun mnesia:foldl/3, [F, [], pubsub_item]),
	    {atomic, ok} = mnesia:delete_table(pubsub_item),
	    {atomic, ok} = mnesia:create_table(pubsub_item,
		    [{disc_copies, [node()]},
			{attributes, record_info(fields, pubsub_item)}]),
	    FNew = fun () -> [mnesia:write(Rec) || Rec <- NewRecs] end,
	    case mnesia:transaction(FNew) of
		{atomic, Res2} ->
		    ?INFO_MSG("Pubsub items table upgraded: ~p", [Res2]);
		{aborted, Rea2} ->
		    ?ERROR_MSG("Problem upgrading Pubsub item table:~n~p", [Rea2])
	    end;
	_ ->
	    ok
    end,
    mnesia:add_table_index(pubsub_state, nodeidx),
    mnesia:add_table_index(pubsub_item, nodeidx),
    update_state_database_binary().

update_lastitem_database(_Host, _ServerHost) ->
    F = fun () ->
	    case catch mnesia:read({pubsub_last_item, mnesia:first(pubsub_last_item)}) of
		[First] when is_list(First#pubsub_last_item.itemid) ->
		    ?INFO_MSG("Binarization of pubsub items table...", []),
		    lists:foreach(fun (Id) ->
				[Node] = mnesia:read({pubsub_last_item, Id}),
				ItemId = iolist_to_binary(Node#pubsub_last_item.itemid),
				ok = mnesia:delete({pubsub_last_item, Id}),
				ok = mnesia:write(Node#pubsub_last_item{itemid=ItemId})
			end,
			mnesia:all_keys(pubsub_last_item));
		_-> no_need
	    end
    end,
    case mnesia:transaction(F) of
	{aborted, Reason} ->
	    ?ERROR_MSG("Failed to binarize pubsub lastitems table: ~p", [Reason]);
	{atomic, no_need} ->
	    ok;
	{atomic, Result} ->
	    ?INFO_MSG("Pubsub lastitems table has been binarized: ~p", [Result])
    end.

update_item_database(_Host, _ServerHost) ->
    F = fun() ->
		case catch mnesia:read({pubsub_item, mnesia:first(pubsub_item)}) of
		    [First] when is_list(element(1, First#pubsub_item.itemid)) ->
			?INFO_MSG("Migration of old pubsub items...", []),
			lists:foreach(fun (Key) ->
					      [Item] = mnesia:read({pubsub_item, Key}),
					      {ItemId, NodeIdx} = Item#pubsub_item.itemid,
					      {CreationTS, CreationJID} = Item#pubsub_item.creation,
					      {ModifTS, ModifJID} = Item#pubsub_item.modification,
					      Payload = [xmlelement_to_xmlel(El) || El <- Item#pubsub_item.payload],
					      ok = mnesia:delete({pubsub_item, {ItemId, NodeIdx}}),
					      ok = mnesia:write(Item#pubsub_item{itemid = {iolist_to_binary(ItemId), NodeIdx}, 
										 creation = {CreationTS, binarize_ljid(CreationJID)},
										 modification = {ModifTS, binarize_ljid(ModifJID)},
										 payload = Payload})
				      end,
				      mnesia:all_keys(pubsub_item));
		    _ -> no_need
		end
	end,
    case mnesia:transaction(F) of
	{aborted, Reason} ->
	    ?ERROR_MSG("Failed to migrate old pubsub items to xmlel: ~p", [Reason]);
	{atomic, Result} ->
	    ?INFO_MSG("Pubsub items has been migrated: ~p", [Result])
    end.

binarize_ljid({U, S, R}) ->
    {iolist_to_binary(U), iolist_to_binary(S), iolist_to_binary(R)}.
    

xmlelement_to_xmlel(El) when is_record(El, xmlel)->
    El;
xmlelement_to_xmlel({xmlelement, Name, Attrs, Children}) ->
    {xmlel, iolist_to_binary(Name), binarize_attributes(Attrs),
     [xmlelement_to_xmlel(El) || El <- Children]};
xmlelement_to_xmlel({xmlcdata, Data}) ->
    {xmlcdata, iolist_to_binary(Data)}.

binarize_attributes([{Name, Value} | Tail]) ->
    [{iolist_to_binary(Name), iolist_to_binary(Value)} | binarize_attributes(Tail)];
binarize_attributes([]) ->
    [].


%% REVIEW:
%% * this code takes NODEID from Itemid2, and forgets about Nodeidx
%% * this code assumes Payload only contains one xmlelement()
%% * PUBLISHER is taken from Creation
export(_Server) ->
    [{pubsub_item,
	    fun(_Host, #pubsub_item{itemid = {Itemid1, Itemid2},
				nodeidx = _Nodeidx,
				creation = {{C1, C2, C3}, Cusr},
				modification = {{M1, M2, M3}, _Musr},
				payload = Payload}) ->
		    ITEMID = ejabberd_sql:escape(Itemid1),
		    NODEID = integer_to_list(Itemid2),
		    CREATION = ejabberd_sql:escape(
			    iolist_to_binary(string:join([string:right(integer_to_list(I),6,$0)||I<-[C1,C2,C3]],":"))),
		    MODIFICATION = ejabberd_sql:escape(
			    iolist_to_binary(string:join([string:right(integer_to_list(I),6,$0)||I<-[M1,M2,M3]],":"))),
		    PUBLISHER = ejabberd_sql:escape(jid:to_string(Cusr)),
		    [PayloadEl] = [{xmlel,A,B,C} || {xmlelement,A,B,C} <- Payload],
		    PAYLOAD = ejabberd_sql:escape(fxml:element_to_binary(PayloadEl)),
		    ["delete from pubsub_item where itemid='", ITEMID, "';\n"
			"insert into pubsub_item(itemid,nodeid,creation,modification,publisher,payload) \n"
			" values ('", ITEMID, "', ", NODEID, ", '", CREATION, "', '",
			MODIFICATION, "', '", PUBLISHER, "', '", PAYLOAD, "');\n"];
		(_Host, _R) ->
		    []
	    end},
	%% REVIEW:
	%% * From the mnesia table, the #pubsub_state.items is not used in ODBC
	%% * Right now AFFILIATION is the first letter of Affiliation
	%% * Right now SUBSCRIPTIONS expects only one Subscription
	%% * Right now SUBSCRIPTIONS letter is the first letter of Subscription
	{pubsub_state,
	    fun(_Host, #pubsub_state{stateid = {Jid, Stateid},
				nodeidx = Nodeidx,
				items = _Items,
				affiliation = Affiliation,
				subscriptions = Subscriptions}) ->
		    STATEID = integer_to_list(Stateid),
		    JID = ejabberd_sql:escape(jid:to_string(Jid)),
		    NODEID = integer_to_list(Nodeidx),
		    AFFILIATION = string:substr(atom_to_list(Affiliation),1,1),
		    SUBSCRIPTIONS = parse_subscriptions(Subscriptions),
		    ["delete from pubsub_state where stateid='", STATEID, "';\n"
			"insert into pubsub_state(stateid,jid,nodeid,affiliation,subscriptions) \n"
			" values (", STATEID, ", '", JID, "', ", NODEID, ", '",
			AFFILIATION, "', '", SUBSCRIPTIONS, "');\n"];
		(_Host, _R) ->
		    []
	    end},

	%% REVIEW:
	%% * Parents is not migrated to PARENTs
	%% * Probably some option VALs are not correctly represented in mysql
	{pubsub_node,
	    fun(_Host, #pubsub_node{nodeid = {Hostid, Nodeid},
				id = Id,
				parents = _Parents,
				type = Type,
				owners = Owners,
				options = Options}) ->
		    HOST = case Hostid of
			{U,S,R} -> ejabberd_sql:escape(jid:to_string({U,S,R}));
			_ -> ejabberd_sql:escape(Hostid)
		    end,
		    NODE = ejabberd_sql:escape(Nodeid),
		    NODEID = integer_to_list(Id),
		    PARENT = "",
		    TYPE = ejabberd_sql:escape(<<Type/binary, "_sql">>),
		    ["delete from pubsub_node where nodeid='", NODEID, "';\n"
			"insert into pubsub_node(host,node,nodeid,parent,type) \n"
			" values ('", HOST, "', '", NODE, "', ", NODEID, ", '", PARENT, "', '", TYPE, "');\n"
			"delete from pubsub_node_option where nodeid='", NODEID, "';\n",
			[["insert into pubsub_node_option(nodeid,name,val)\n"
				" values (", NODEID, ", '", atom_to_list(Name), "', '",
				io_lib:format("~p", [Val]), "');\n"] || {Name,Val} <- Options],
			"delete from pubsub_node_owner where nodeid='", NODEID, "';\n",
			[["insert into pubsub_node_owner(nodeid,owner)\n"
				" values (", NODEID, ", '", jid:to_string(Usr), "');\n"] || Usr <- Owners],"\n"];
		(_Host, _R) ->
		    []
	    end}].

parse_subscriptions([]) ->
    "";
parse_subscriptions([{State, Item}]) ->
    STATE = case State of
	subscribed -> "s"
    end,
    string:join([STATE, Item],":").
