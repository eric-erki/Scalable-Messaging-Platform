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

-module(nodetree_flatmem).
-behaviour(gen_pubsub_nodetree).
-author('christophe.romain@process-one.net').

-include("pubsub.hrl").
-include("jlib.hrl").

-export([init/3, terminate/2, options/0, set_node/1,
    get_node/3, get_node/2, get_node/1, get_nodes/2,
    get_nodes/1, get_parentnodes/3, get_parentnodes_tree/3,
    get_subnodes/3, get_subnodes_tree/3, create_node/6,
    delete_node/2]).

init(_Host, _ServerHost, _Opts) ->
    ok.

terminate(_Host, _ServerHost) ->
    ok.

options() ->
    [{virtual_tree, true}].

set_node(_Node) ->
    ok.

get_node(Host, Node, _From) ->
    get_node(Host, Node).

get_node(Host, Node) ->
    Nidx = nodeidx(Host, Node),
    % TODO same memory by coding only Node in 8 bits binary instead of 6
    % ideally can be phash2(<<Host/binary, 0, Node/binary>>
    % and we maintain in ets list of hash->{Host, Node}
    #pubsub_node{nodeid = {Host, Node}, id = Nidx,
                 type = <<"flatmem">>,
                 owners = [{<<"">>, Host, <<"">>}],
                 options = node_flatmem:options()}.


get_node(Nidx) ->
    % TODO cope with lack of Host
    {Host, Node} = nodeid(Nidx),
    #pubsub_node{nodeid = {Host, Node}, id = Nidx,
                 type = <<"flatmem">>,
                 owners = [{<<"">>, Host, <<"">>}],
                 options = node_flatmem:options()}.

get_nodes(Host, _From) ->
    get_nodes(Host).

get_nodes(_Host) ->
    [].

get_parentnodes(_Host, _Node, _From) ->
    [].

get_parentnodes_tree(Host, Node, From) ->
    case get_node(Host, Node, From) of
	Node when is_record(Node, pubsub_node) -> [{0, [Node]}];
	_Error -> []
    end.

get_subnodes(Host, Node, _From) ->
    get_subnodes(Host, Node).

get_subnodes(_Host, _Node) ->
    [].

get_subnodes_tree(Host, Node, _From) ->
    get_subnodes_tree(Host, Node).

get_subnodes_tree(_Host, _Node) ->
    [].

create_node(Host, Node, _Type, _Owner, _Options, _Parents) ->
    {error, {virtual, nodeidx(Host, Node)}}.

delete_node(Host, Node) ->
    [get_node(Host, Node)].

%% internal helper

nodeidx(Host, Node) -> term_to_binary({Host, Node}).
nodeid(Nidx) -> binary_to_term(Nidx).
