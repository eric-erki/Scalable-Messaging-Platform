%%%----------------------------------------------------------------------
%%% File    : nodetree_tree_p1db.erl
%%% Author  : Christophe Romain <christophe.romain@process-one.net>
%%% Purpose : Standard node tree plugin with P1DB backend
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

%%% @doc The module <strong>{@module}</strong> is the default PubSub node tree plugin.
%%% <p>It is used as a default for all unknown PubSub node type.  It can serve
%%% as a developer basis and reference to build its own custom pubsub node tree
%%% types.</p>
%%% <p>PubSub node tree plugins are using the {@link gen_nodetree} behaviour.</p>
%%% <p><strong>The API isn't stabilized yet</strong>. The pubsub plugin
%%% development is still a work in progress. However, the system is already
%%% useable and useful as is. Please, send us comments, feedback and
%%% improvements.</p>

-module(nodetree_tree_p1db).

-behaviour(ejabberd_config).
-behaviour(gen_pubsub_nodetree).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").

-export([init/3, terminate/2, options/0, set_node/1,
    get_node/3, get_node/2, get_node/1, get_nodes/2,
    get_nodes/1, get_parentnodes/3, get_parentnodes_tree/3,
    get_subnodes/3, get_subnodes_tree/3, create_node/6,
    delete_node/2]).

-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2,
	 mod_opt_type/1, opt_type/1]).

init(_Host, ServerHost, Opts) ->
    Group = gen_mod:get_opt(p1db_group, Opts, fun(G) when is_atom(G) -> G end, 
			ejabberd_config:get_option(
			    {p1db_group, ServerHost}, fun(G) when is_atom(G) -> G end)),
    [Key|Values] = record_info(fields, pubsub_node),
    p1db:open_table(pubsub_node,
			[{group, Group}, {nosync, true},
			 {schema, [{keys, [Key]},
				   {vals, Values},
				   {enc_key, fun ?MODULE:enc_key/1},
				   {dec_key, fun ?MODULE:dec_key/1},
				   {enc_val, fun ?MODULE:enc_val/2},
				   {dec_val, fun ?MODULE:dec_val/2}]}]),
    ok.

terminate(_Host, _ServerHost) ->
    ok.

options() ->
    nodetree_tree:options().

set_node(Node) when is_record(Node, pubsub_node) ->
    Key = enc_key(Node#pubsub_node.nodeid),
    Val = node_to_p1db(Node),
    p1db:insert(pubsub_node, Key, Val).

get_node(Host, Node, _From) ->
    get_node(Host, Node).

get_node(Host, Node) ->
    Key = enc_key({Host, Node}),
    case p1db:get(pubsub_node, Key) of
	{ok, Val, _VClock} -> p1db_to_node({Host, Node}, Val);
	_ -> {error, ?ERR_ITEM_NOT_FOUND}
    end.

get_node(Nidx) ->
    {Host, Node} = nidx_to_nodeid(Nidx),
    get_node(Host, Node).

get_nodes(Host, _From) ->
    get_nodes(Host).

get_nodes(Host) ->
    case p1db:get_by_prefix(pubsub_node, enc_key(Host)) of
	{ok, L} -> [p1db_to_node(Key, Val) || {Key, Val, _} <- L];
	_ -> []
    end.

get_parentnodes(_Host, _Node, _From) ->
    [].

%% @doc <p>Default node tree does not handle parents, return a list
%% containing just this node.</p>
get_parentnodes_tree(Host, Node, _From) ->
    case get_node(Host, Node) of
	{error, _} -> [];
	Record -> [{0, [Record]}]
    end.

get_subnodes(Host, Node, _From) ->
    get_subnodes(Host, Node).

get_subnodes(Host, <<>>) ->
    [N || #pubsub_node{parents = P} = N <- get_nodes(Host),
	  P == []];
get_subnodes(Host, Node) ->
    [N || #pubsub_node{parents = P} = N <- get_nodes(Host),
	  lists:member(Node, P)].

get_subnodes_tree(Host, Node, _From) ->
    get_subnodes_tree(Host, Node).

get_subnodes_tree(Host, Node) ->
    case get_node(Host, Node) of
	{error, _} ->
	    [];
	Rec ->
	    BasePath = node_path(Rec#pubsub_node.type, Node),
	    [N || #pubsub_node{nodeid={_,I},type=T} = N <- get_nodes(Host),
		  lists:prefix(BasePath, node_path(T,I))]
    end.

create_node(Host, Node, Type, Owner, Options, Parents) ->
    BJID = jid:tolower(jid:remove_resource(Owner)),
    Key = enc_key({Host, Node}),
    case p1db:get(pubsub_node, Key) of
	{ok, _Val, _VClock} ->
	    {error, ?ERR_CONFLICT};
	_ ->
	    ParentExists = case Host of
		{_U, _S, _R} ->
		    %% This is special case for PEP handling
		    %% PEP does not uses hierarchy
		    true;
		_ ->
		    case Parents of
			[] ->
			    true;
			[Parent | _] ->
			    case p1db:get(pubsub_node, enc_key({Host, Parent})) of
				{ok, PVal, _VClock} ->
				    I = p1db_to_node({Host, Parent}, PVal),
				    case I#pubsub_node.owners of
					[{[], Host, []}] -> true;
					Owners -> lists:member(BJID, Owners)
				    end;
				_ ->
				    false
			    end;
			_ ->
			    false
		    end
	    end,
	    case ParentExists of
		true ->
		    Nidx = nodeid_to_nidx({Host, Node}),
		    Val = node_to_p1db(#pubsub_node{nodeid = {Host, Node},
			    id = Nidx, parents = Parents,
			    type = Type, owners = [BJID],
			    options = Options}),
		    p1db:insert(pubsub_node, Key, Val),
		    {ok, Nidx};
		false ->
		    {error, ?ERR_FORBIDDEN}
	    end
    end.

delete_node(Host, Node) ->
    Removed = get_subnodes_tree(Host, Node),
    [p1db:delete(pubsub_node, enc_key({Host, SubNode}))
	|| #pubsub_node{nodeid = {_, SubNode}} <- Removed],
    Removed.

node_path(Type, NodeId) ->
    Plugin = jlib:binary_to_atom(<<"node_", (Type)/binary>>),
    Plugin:node_to_path(NodeId).

% p1db helpers

node_to_p1db(#pubsub_node{}=N) ->
    term_to_binary(
	[{parents, N#pubsub_node.parents},
	 {type, N#pubsub_node.type},
	 {owners, N#pubsub_node.owners},
	 {options, N#pubsub_node.options}]).
p1db_to_node(Key, Val) when is_binary(Key) ->
    p1db_to_node(dec_key(Key), Val);
p1db_to_node(NodeId, Val) ->
    Nidx = nodeid_to_nidx(NodeId),
    lists:foldl(fun({parents, P}, N) -> N#pubsub_node{parents=P};
		   ({type, T}, N) -> N#pubsub_node{type=T};
		   ({owners, O}, N) -> N#pubsub_node{owners=O};
		   ({options, O}, N) -> N#pubsub_node{options=O};
		   (_, N) -> N
    end, #pubsub_node{nodeid=NodeId,id=Nidx}, binary_to_term(Val)).

nodeid_to_nidx(NodeId) -> enc_key(NodeId).
nidx_to_nodeid(Nidx) -> dec_key(Nidx).

enc_key({{U,S,R}, Node}) ->
    <<(jid:to_string({U,S,R}))/binary, 0, Node/binary>>;
enc_key({Host, Node}) ->
    <<Host/binary, 0, Node/binary>>;
enc_key({U,S,R}) ->
    <<(jid:to_string({U,S,R}))/binary, 0>>;
enc_key(Host) ->
    <<Host/binary, 0>>.
dec_key(Key) ->
    case str:chr(Key, 0) of
	0 -> {Key, <<>>};
	N ->
	    SLen = N - 1,
	    <<Head:SLen/binary, 0, Node/binary>> = Key,
	    case jid:string_to_usr(Head) of
		{<<>>, Host, <<>>} -> {Host, Node};
		USR -> {USR, Node}
	    end
    end.
enc_val(_, [Parents,Type,Owners,Options]) ->
    node_to_p1db(#pubsub_node{
	    parents=Parents,
	    type=Type,
	    owners=Owners,
	    options=Options}).
dec_val(Key, Bin) ->
    N = p1db_to_node(Key, Bin),
    [N#pubsub_node.parents,
     N#pubsub_node.type,
     N#pubsub_node.owners,
     N#pubsub_node.options].


mod_opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
mod_opt_type(_) -> [p1db_group].

opt_type(p1db_group) ->
    fun (G) when is_atom(G) -> G end;
opt_type(_) -> [p1db_group].
