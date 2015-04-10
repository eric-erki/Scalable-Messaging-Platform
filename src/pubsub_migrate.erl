%%%----------------------------------------------------------------------
%%% File    : pubsub_migrate.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Migration/Upgrade code put out of mod_pubsub
%%% Created : 26 Jul 2014 by Christophe Romain <christophe.romain@process-one.net>
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
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(pubsub_migrate).

-include("pubsub.hrl").
-include("logger.hrl").

-export([update_node_database/2, update_state_database/2, update_lastitem_database/2]).
-export([export/1]).

rename_default_nodeplugin() ->
    lists:foreach(fun (Node) ->
		mnesia:dirty_write(Node#pubsub_node{type = <<"hometree">>})
	end,
	mnesia:dirty_match_object(#pubsub_node{type = <<"default">>, _ = '_'})).


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
						    M = {now(), Publisher},
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
				    {U, S, R} -> {iolist_to_binary(U), iolist_to_binary(S), iolist_to_binary(R)};
				    String -> iolist_to_binary(String)
				end,

				Owners = [{iolist_to_binary(U), iolist_to_binary(S), iolist_to_binary(R)} ||
					{U, S, R} <- Node#pubsub_node.owners],

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

update_state_database(_Host, _ServerHost) ->
    case catch mnesia:table_info(pubsub_state, attributes)
    of
	[stateid, nodeidx, items, affiliation, subscription] ->
	    ?INFO_MSG("Upgrading pubsub states table...", []),
	    F = fun ({pubsub_state, {{U,S,R}, NodeId}, _NodeIdx, Items, Aff, Sub}, Acc) ->
		    JID = {iolist_to_binary(U), iolist_to_binary(S), iolist_to_binary(R)},
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
		    ?INFO_MSG("Pubsub state tables updated correctly: ~p", [Res1]);
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
		    ?INFO_MSG("Pubsub item tables upgraded correctly: ~p", [Res2]);
		{aborted, Rea2} ->
		    ?ERROR_MSG("Problem upgrading Pubsub item table:~n~p", [Rea2])
	    end;
	_ ->
	    ok
    end,
    mnesia:add_table_index(pubsub_state, nodeidx),
    mnesia:add_table_index(pubsub_item, nodeidx).

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
		    ITEMID = ejabberd_odbc:escape(Itemid1),
		    NODEID = integer_to_list(Itemid2),
		    CREATION = ejabberd_odbc:escape(
			    iolist_to_binary(string:join([string:right(integer_to_list(I),6,$0)||I<-[C1,C2,C3]],":"))),
		    MODIFICATION = ejabberd_odbc:escape(
			    iolist_to_binary(string:join([string:right(integer_to_list(I),6,$0)||I<-[M1,M2,M3]],":"))),
		    PUBLISHER = ejabberd_odbc:escape(jlib:jid_to_string(Cusr)),
		    [PayloadEl] = [{xmlel,A,B,C} || {xmlelement,A,B,C} <- Payload],
		    PAYLOAD = ejabberd_odbc:escape(xml:element_to_binary(PayloadEl)),
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
		    JID = ejabberd_odbc:escape(jlib:jid_to_string(Jid)),
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
			{U,S,R} -> ejabberd_odbc:escape(jlib:jid_to_string({U,S,R}));
			_ -> ejabberd_odbc:escape(Hostid)
		    end,
		    NODE = ejabberd_odbc:escape(Nodeid),
		    NODEID = integer_to_list(Id),
		    PARENT = "",
		    TYPE = ejabberd_odbc:escape(<<Type/binary, "_odbc">>),
		    ["delete from pubsub_node where nodeid='", NODEID, "';\n"
			"insert into pubsub_node(host,node,nodeid,parent,type) \n"
			" values ('", HOST, "', '", NODE, "', ", NODEID, ", '", PARENT, "', '", TYPE, "');\n"
			"delete from pubsub_node_option where nodeid='", NODEID, "';\n",
			[["insert into pubsub_node_option(nodeid,name,val)\n"
				" values (", NODEID, ", '", atom_to_list(Name), "', '",
				io_lib:format("~p", [Val]), "');\n"] || {Name,Val} <- Options],
			"delete from pubsub_node_owner where nodeid='", NODEID, "';\n",
			[["insert into pubsub_node_owner(nodeid,owner)\n"
				" values (", NODEID, ", '", jlib:jid_to_string(Usr), "');\n"] || Usr <- Owners],"\n"];
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
