%%%----------------------------------------------------------------------
%%% File    : ejabberd_sets.erl
%%% Author  : Pablo Polvorin <pablo.polvorin@process-one.net>
%%% Purpose : Use a custom set module, reuse structs when possible
%%% Created : 9 Nov 2012 by Pablo Polvorin <pablo.polvorin@process-one.net>
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

-module(ejabberd_sets).

-include("ejabberd.hrl").

%%SET interface, same than gb_sets
-export([
		new/0,
		from_list/1,
		to_list/1,
		is_element/2,
		add_element/2,
		del_element/2,
		fold/3,
		size/1]).

-type ej_set() :: ?TGB_TREE.
-export_type([ej_set/0]).


%% Asumptions:
%% 		It is common that roster items are of type "both", present in both pres_a and pres_f sets.
%% 		There are relatively few different domains in the roster.
%% 		There are common "resource" used by users (ie, "home", "psi", "android", ..etc).
%%
%% Strategy:
%% 		map of domains, pointing to map of resources,  poiting to set of usernames in that domain and with that resource.
%%
%% Goals:	Reduce memory usage. 
%% 			- Sharing is explicit and evolves better than "pack()" on changes on pres_*.
%% 			- Message passing in erlang doesn't preserve implicit sharing. With this explicit sharing, state to transfer on migrations is smaller.
%% 			- Hopefully, less memory overhead due to pointers (storing only usernames rather than tuples of three elements.) 
%% 			- no need to pack()
%%
%% 
%% gb_tree(
%% 	{<<"jabber.ru">>,  
%% 			gb_tree({<<"psi">>,  set(<<"user1">>, <<"user2>>, ..)},
%% 				{<<"resourceN">>, set(<<"someUser">>)})}
%% 	{<<"jabber.org">>,
%% 			gb_tree(<<"psi">>, set(<<"userA">>, <<"UserB">>))}
%% 	...
%%]



new() ->
	gb_trees:empty().
from_list(L) ->
	lists:foldl(fun add_element/2, new(), L).

to_list(S) -> 
	fold(fun(JID, Acc) -> [JID | Acc] end, [], S).

is_element({N,D,R}, S) -> 
	case gb_trees:lookup(D, S) of
		none -> false;
		{value, JIDs} ->
			case gb_trees:lookup(R, JIDs) of
				none ->
					false;
				{value, Nodes} ->
					gb_sets:is_element(N, Nodes)
			end
	end.


add_element({N,D,R}, S) ->
	case gb_trees:lookup(D, S) of
		none ->
			JIDs = gb_trees:insert(R, gb_sets:from_list([N]), gb_trees:empty()),
			gb_trees:insert(D, JIDs, S);
		{value, JIDs} ->
			NewJIDs = case gb_trees:lookup(R, JIDs) of
				none ->
					gb_trees:insert(R, gb_sets:from_list([N]), JIDs);
				{value, Nodes} ->
					gb_trees:update(R, gb_sets:add_element(N, Nodes), JIDs)
			end,
			gb_trees:update(D, NewJIDs, S)
		end.


size(S) ->
	gb_tree_fold(fun(_Domain, JIDs, Acc) ->
				gb_tree_fold(fun(_Resource, Nodes, Acc2) ->
							gb_sets:size(Nodes) + Acc2
					end, Acc, JIDs)
		end,0, S).

fold(Fun, Init, S) ->
	gb_tree_fold(fun(D,JIDs, Acc) ->
		gb_tree_fold(fun(R, Nodes, Acc2) ->
				gb_sets:fold(fun(Node, Acc3) ->
					Fun({Node,D,R}, Acc3)
				end, Acc2, Nodes)
			end, Acc, JIDs)
		end, Init, S).

del_element({N,D,R}, S) ->
	case gb_trees:lookup(D, S) of
		none ->
			S;
		{value, JIDs} ->
			case gb_trees:lookup(R, JIDs) of
				none ->
					S;
				{value, Nodes} ->
					NewNodes = gb_sets:del_element(N, Nodes),
					case gb_sets:is_empty(NewNodes) of  
						true -> %%No more users in this domain with this resource
							NewJIDs = gb_trees:delete(R, JIDs),
							case gb_trees:is_empty(NewJIDs) of  %% No more user/resources in this domain
								true ->
									gb_trees:delete(D, S);
								false ->  %%still other resources in this domain
									gb_trees:update(D, NewJIDs, S)
							end;
						false ->
							NewJIDs = gb_trees:update(R, NewNodes, JIDs),
							gb_trees:update(D, NewJIDs, S)
					end
			end
	end.

% ------- Utils
%
gb_tree_fold(F, Initial, Tree) ->
    gb_tree_fold1(F, Initial, gb_trees:iterator(Tree)).
gb_tree_fold1(F, Accum, Iterator) ->
    case gb_trees:next(Iterator) of
        {Key, Value, Iter2} ->
            Accum2 = F(Key, Value, Accum),
            gb_tree_fold1(F, Accum2, Iter2);
        none ->
            Accum
    end.

