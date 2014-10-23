%%%----------------------------------------------------------------------
%%% File    : mod_roster.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Roster management
%%% Created : 11 Dec 2002 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2014   ProcessOne
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

%%% @doc Roster management (Mnesia storage).
%%%
%%% Includes support for XEP-0237: Roster Versioning.
%%% The roster versioning follows an all-or-nothing strategy:
%%%  - If the version supplied by the client is the latest, return an empty response.
%%%  - If not, return the entire new roster (with updated version string).
%%% Roster version is a hash digest of the entire roster.
%%% No additional data is stored in DB.

-module(mod_roster).

-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, process_iq/3, export/1, import_info/0,
	 process_local_iq/3, get_user_roster/2, import/5,
	 get_subscription_lists/3, get_roster/2, import_start/2,
	 get_in_pending_subscriptions/3, in_subscription/6,
	 out_subscription/4, set_items/3, remove_user/2,
	 get_jid_info/4, item_to_xml/1, webadmin_page/3,
	 webadmin_user/4, get_versioning_feature/2,
	 roster_versioning_enabled/1, roster_version/2,
	 enc_key/1, enc_val/2, dec_val/2,
	 dec_roster_key/1, dec_roster_version_key/1,
         record_to_string/1, groups_to_string/1, import_stop/2]).

%% For benchmarking
-export([create_rosters/4]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-include("mod_roster.hrl").

-include("ejabberd_http.hrl").

-include("ejabberd_web_admin.hrl").

-export_type([subscription/0]).

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, fun gen_iq_handler:check_type/1,
                             one_queue),
    init_db(gen_mod:db_type(Opts), Host),
    ejabberd_hooks:add(roster_get, Host, ?MODULE,
		       get_user_roster, 50),
    ejabberd_hooks:add(roster_in_subscription, Host,
		       ?MODULE, in_subscription, 50),
    ejabberd_hooks:add(roster_out_subscription, Host,
		       ?MODULE, out_subscription, 50),
    ejabberd_hooks:add(roster_get_subscription_lists, Host,
		       ?MODULE, get_subscription_lists, 50),
    ejabberd_hooks:add(roster_get_jid_info, Host, ?MODULE,
		       get_jid_info, 50),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    ejabberd_hooks:add(anonymous_purge_hook, Host, ?MODULE,
		       remove_user, 50),
    ejabberd_hooks:add(resend_subscription_requests_hook,
		       Host, ?MODULE, get_in_pending_subscriptions, 50),
    ejabberd_hooks:add(roster_get_versioning_feature, Host,
		       ?MODULE, get_versioning_feature, 50),
    ejabberd_hooks:add(webadmin_page_host, Host, ?MODULE,
		       webadmin_page, 50),
    ejabberd_hooks:add(webadmin_user, Host, ?MODULE,
		       webadmin_user, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_ROSTER, ?MODULE, process_iq, IQDisc).

init_db(mnesia, _Host) ->
    mnesia:create_table(roster,
                        [{disc_copies, [node()]},
                         {attributes, record_info(fields, roster)}]),
    mnesia:create_table(roster_version,
                        [{disc_copies, [node()]},
                         {attributes,
                          record_info(fields, roster_version)}]),
    update_tables(),
    mnesia:add_table_index(roster, us),
    mnesia:add_table_index(roster_version, us);
init_db(p1db, Host) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(roster,
		    [{group, Group},
                     {schema, [{keys, [server, user, jid]},
                               {vals, [name, subscription,
                                       ask, groups, askmessage,
                                       xs]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_roster_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]),
    p1db:open_table(roster_version,
		    [{group, Group},
                     {schema, [{keys, [server, user]},
                               {vals, [version]},
                               {dec_key, fun ?MODULE:dec_roster_version_key/1},
                               {enc_key, fun ?MODULE:enc_key/1}]}]);
init_db(odbc, Host) ->
    case use_cache(Host) of
        true ->
            MaxSize = gen_mod:get_module_opt(
                        Host, ?MODULE, cache_size,
                        fun(I) when is_integer(I), I>0 -> I end,
                        1000),
            LifeTime = gen_mod:get_module_opt(
                         Host, ?MODULE, cache_life_time,
                         fun(I) when is_integer(I), I>0 -> I end,
                         timer:seconds(5) div 1000),
            cache_tab:new(roster, [{max_size, MaxSize},
                                   {lru, false},
                                   {life_time, LifeTime}]);
        false ->
            ok
    end;
init_db(_, _) ->
    ok.

stop(Host) ->
    ejabberd_hooks:delete(roster_get, Host, ?MODULE,
			  get_user_roster, 50),
    ejabberd_hooks:delete(roster_in_subscription, Host,
			  ?MODULE, in_subscription, 50),
    ejabberd_hooks:delete(roster_out_subscription, Host,
			  ?MODULE, out_subscription, 50),
    ejabberd_hooks:delete(roster_get_subscription_lists,
			  Host, ?MODULE, get_subscription_lists, 50),
    ejabberd_hooks:delete(roster_get_jid_info, Host,
			  ?MODULE, get_jid_info, 50),
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    ejabberd_hooks:delete(anonymous_purge_hook, Host,
			  ?MODULE, remove_user, 50),
    ejabberd_hooks:delete(resend_subscription_requests_hook,
			  Host, ?MODULE, get_in_pending_subscriptions, 50),
    ejabberd_hooks:delete(roster_get_versioning_feature,
			  Host, ?MODULE, get_versioning_feature, 50),
    ejabberd_hooks:delete(webadmin_page_host, Host, ?MODULE,
			  webadmin_page, 50),
    ejabberd_hooks:delete(webadmin_user, Host, ?MODULE,
			  webadmin_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host,
				     ?NS_ROSTER).

process_iq(From, To, IQ) when ((From#jid.luser == <<"">>) andalso (From#jid.resource == <<"">>)) ->
    process_iq_manager(From, To, IQ);

process_iq(From, To, IQ) ->
    #iq{sub_el = SubEl} = IQ,
    #jid{lserver = LServer} = From,
    case lists:member(LServer, ?MYHOSTS) of
      true -> process_local_iq(From, To, IQ);
      _ ->
	  IQ#iq{type = error,
		sub_el = [SubEl, ?ERR_ITEM_NOT_FOUND]}
    end.

process_local_iq(From, To, #iq{type = Type} = IQ) ->
    case Type of
      set -> try_process_iq_set(From, To, IQ);
      get -> process_iq_get(From, To, IQ)
    end.

roster_hash(Items) ->
    p1_sha:sha(term_to_binary(lists:sort([R#roster{groups =
						    lists:sort(Grs)}
				       || R = #roster{groups = Grs}
					      <- Items]))).

roster_versioning_enabled(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, versioning,
                           fun(B) when is_boolean(B) -> B end,
			   false).

roster_version_on_db(Host) ->
    gen_mod:get_module_opt(Host, ?MODULE, store_current_id,
                           fun(B) when is_boolean(B) -> B end,
			   false).

get_versioning_feature(Acc, Host) ->
    case roster_versioning_enabled(Host) of
      true ->
	  Feature = #xmlel{name = <<"ver">>,
			   attrs = [{<<"xmlns">>, ?NS_ROSTER_VER}],
			   children = []},
	  [Feature | Acc];
      false -> []
    end.

roster_version(LServer, LUser) ->
    US = {LUser, LServer},
    case roster_version_on_db(LServer) of
      true ->
	  case read_roster_version(LUser, LServer) of
	    error -> not_found;
	    V -> V
	  end;
      false ->
	  roster_hash(ejabberd_hooks:run_fold(roster_get, LServer,
					      [], [US]))
    end.

read_roster_version(LUser, LServer) ->
    read_roster_version(LUser, LServer,
			gen_mod:db_type(LServer, ?MODULE)).

read_roster_version(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    case mnesia:dirty_read(roster_version, US) of
      [#roster_version{version = V}] -> V;
      [] -> error
    end;
read_roster_version(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case odbc_queries:get_roster_version(LServer, Username)
	of
      {selected, [<<"version">>], [[Version]]} -> Version;
      {selected, [<<"version">>], []} -> error
    end;
read_roster_version(LUser, LServer, p1db) ->
    US = us2key(LUser, LServer),
    case p1db:get(roster_version, US) of
        {ok, Version, _VClock} -> Version;
        {error, _} -> error
    end;
read_roster_version(LUser, LServer, riak) ->
    case ejabberd_riak:get(roster_version, roster_version_schema(),
			   {LUser, LServer}) of
        {ok, #roster_version{version = V}} -> V;
        _Err -> error
    end;
read_roster_version(_LUser, _LServer, rest) ->
    error.

write_roster_version(LUser, LServer) ->
    write_roster_version(LUser, LServer, false).

write_roster_version_t(LUser, LServer) ->
    write_roster_version(LUser, LServer, true).

write_roster_version(LUser, LServer, InTransaction) ->
    Ver = p1_sha:sha(term_to_binary(now())),
    write_roster_version(LUser, LServer, InTransaction, Ver,
			 gen_mod:db_type(LServer, ?MODULE)),
    Ver.

write_roster_version(LUser, LServer, InTransaction, Ver,
		     mnesia) ->
    US = {LUser, LServer},
    if InTransaction ->
	   mnesia:write(#roster_version{us = US, version = Ver});
       true ->
	   mnesia:dirty_write(#roster_version{us = US,
					      version = Ver})
    end;
write_roster_version(LUser, LServer, InTransaction, Ver,
		     odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    EVer = ejabberd_odbc:escape(Ver),
    if InTransaction ->
	   odbc_queries:set_roster_version(Username, EVer);
       true ->
	   odbc_queries:sql_transaction(LServer,
					fun () ->
						odbc_queries:set_roster_version(Username,
										EVer)
					end)
    end;
write_roster_version(LUser, LServer, _InTransaction, Ver, p1db) ->
    US = us2key(LUser, LServer),
    p1db:insert(roster_version, US, Ver);
write_roster_version(LUser, LServer, _InTransaction, Ver,
		     riak) ->
    US = {LUser, LServer},
    ejabberd_riak:put(#roster_version{us = US, version = Ver},
		      roster_version_schema());
write_roster_version(_LUser, _LServer, _InTransaction, _Ver, rest) ->
    error.

process_iq_get(From, To, #iq{sub_el = SubEl} = IQ) ->
    LUser = From#jid.luser,
    LServer = From#jid.lserver,
    US = {LUser, LServer},
    try {ItemsToSend, VersionToSend} = case
					 {xml:get_tag_attr(<<"ver">>, SubEl),
					  roster_versioning_enabled(LServer),
					  roster_version_on_db(LServer)}
					   of
					 {{value, RequestedVersion}, true,
					  true} ->
					     case read_roster_version(LUser,
								      LServer)
						 of
					       error ->
						   RosterVersion =
						       write_roster_version(LUser,
									    LServer),
						   {lists:map(fun item_to_xml/1,
							      ejabberd_hooks:run_fold(roster_get,
										      To#jid.lserver,
										      [],
										      [US])),
						    RosterVersion};
					       RequestedVersion ->
						   {false, false};
					       NewVersion ->
						   {lists:map(fun item_to_xml/1,
							      ejabberd_hooks:run_fold(roster_get,
										      To#jid.lserver,
										      [],
										      [US])),
						    NewVersion}
					     end;
					 {{value, RequestedVersion}, true,
					  false} ->
					     RosterItems =
						 ejabberd_hooks:run_fold(roster_get,
									 To#jid.lserver,
									 [],
									 [US]),
					     case roster_hash(RosterItems) of
					       RequestedVersion ->
						   {false, false};
					       New ->
						   {lists:map(fun item_to_xml/1,
							      RosterItems),
						    New}
					     end;
					 _ ->
					     {lists:map(fun item_to_xml/1,
							ejabberd_hooks:run_fold(roster_get,
										To#jid.lserver,
										[],
										[US])),
					      false}
				       end,
	IQ#iq{type = result,
	      sub_el =
		  case {ItemsToSend, VersionToSend} of
		    {false, false} -> [];
		    {Items, false} ->
			[#xmlel{name = <<"query">>,
				attrs = [{<<"xmlns">>, ?NS_ROSTER}],
				children = Items}];
		    {Items, Version} ->
			[#xmlel{name = <<"query">>,
				attrs =
				    [{<<"xmlns">>, ?NS_ROSTER},
				     {<<"ver">>, Version}],
				children = Items}]
		  end}
    catch
      _:_ ->
	  IQ#iq{type = error,
		sub_el = [SubEl, ?ERR_INTERNAL_SERVER_ERROR]}
    end.

get_user_roster(Acc, {LUser, LServer}) ->
    Items = get_roster(LUser, LServer),
    lists:filter(fun (#roster{subscription = none,
			      ask = in}) ->
			 false;
		     (_) -> true
		 end,
		 Items)
      ++ Acc.

get_roster(LUser, LServer) ->
    get_roster(LUser, LServer,
	       gen_mod:db_type(LServer, ?MODULE)).

get_roster(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    case catch mnesia:dirty_index_read(roster, US,
				       #roster.us)
	of
      Items  when is_list(Items)-> Items;
      _ -> []
    end;
get_roster(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(roster, USPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, Val, _VClock}) ->
                      LJID = key2jid(USPrefix, Key),
                      USJ = {LUser, LServer, LJID},
                      p1db_to_item(USJ, Val)
              end, L);
        {error, _} ->
            []
    end;
get_roster(LUser, LServer, riak) ->
    case ejabberd_riak:get_by_index(roster, roster_schema(),
				    <<"us">>, {LUser, LServer}) of
        {ok, Items} -> Items;
        _Err -> []
    end;
get_roster(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    Items = get_roster_odbc(LUser, LServer),
    JIDGroups = case catch odbc_queries:get_roster_jid_groups(
                             LServer, Username) of
                    {selected, [<<"jid">>, <<"grp">>], JGrps}
                      when is_list(JGrps) ->
                        JGrps;
                    _ -> []
                end,
    GroupsDict = lists:foldl(fun([J, G], Acc) ->
                                     dict:append(J, G, Acc)
                             end,
                             dict:new(), JIDGroups),
    RItems = lists:flatmap(
               fun (R) ->
                       SJID = jlib:jid_to_string(R#roster.jid),
                       Groups = case dict:find(SJID, GroupsDict) of
                                    {ok, Gs} -> Gs;
                                    error -> []
                                end,
                       [R#roster{groups = Groups}]
               end, Items),
    RItems;
get_roster(LUser, LServer, rest) ->
    case roster_rest:get_user_roster(LServer, LUser) of
            {ok, Items} -> Items;
            _ -> []
    end.

get_roster_odbc(LUser, LServer) ->
    Res = case use_cache(LServer) of
              true ->
                  cache_tab:dirty_lookup(
                    roster, {LUser, LServer},
                    fun() -> get_roster_odbc_query(LUser, LServer) end);
              false ->
                  get_roster_odbc_query(LUser, LServer)
          end,
    case Res of
        {ok, Items} -> Items;
        error -> []
    end.

get_roster_odbc_query(LUser, LServer) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch odbc_queries:get_roster(LServer, Username) of
        {selected,
         [<<"username">>, <<"jid">>, <<"nick">>,
          <<"subscription">>, <<"ask">>, <<"askmessage">>,
          <<"server">>, <<"subscribe">>, <<"type">>],
         Items} when is_list(Items) ->
            {ok, lists:flatmap(
                   fun(I) ->
                           case raw_to_record(LServer, I) of
                               %% Bad JID in database:
                               error -> [];
                               R -> [R]
                           end
                   end, Items)};
        _ ->
            error
    end.

del_roster_cache(LUser, LServer) ->
    case use_cache(LServer) of
        true ->
            cache_tab:dirty_delete(
              roster, {LUser, LServer}, fun() -> ok end);
        false ->
            ok
    end.

item_to_xml(Item) ->
    Attrs1 = [{<<"jid">>,
	       jlib:jid_to_string(Item#roster.jid)}],
    Attrs2 = case Item#roster.name of
	       <<"">> -> Attrs1;
	       Name -> [{<<"name">>, Name} | Attrs1]
	     end,
    Attrs3 = case Item#roster.subscription of
	       none -> [{<<"subscription">>, <<"none">>} | Attrs2];
	       from -> [{<<"subscription">>, <<"from">>} | Attrs2];
	       to -> [{<<"subscription">>, <<"to">>} | Attrs2];
	       both -> [{<<"subscription">>, <<"both">>} | Attrs2];
	       remove -> [{<<"subscription">>, <<"remove">>} | Attrs2]
	     end,
    Attrs4 = case ask_to_pending(Item#roster.ask) of
	       out -> [{<<"ask">>, <<"subscribe">>} | Attrs3];
	       both -> [{<<"ask">>, <<"subscribe">>} | Attrs3];
	       _ -> Attrs3
	     end,
    SubEls1 = lists:map(fun (G) ->
				#xmlel{name = <<"group">>, attrs = [],
				       children = [{xmlcdata, G}]}
			end,
			Item#roster.groups),
    SubEls = SubEls1 ++ Item#roster.xs,
    #xmlel{name = <<"item">>, attrs = Attrs4,
	   children = SubEls}.

get_roster_by_jid_t(LUser, LServer, LJID) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    get_roster_by_jid_t(LUser, LServer, LJID, DBType).

get_roster_by_jid_t(LUser, LServer, LJID, rest) ->
     case roster_rest:get_jid_info(LServer, LUser, LJID) of
             {ok, Item} -> Item;
             not_found -> 
            #roster{usj = {LUser, LServer, LJID},   %%No idea why,  but on the other backends if is not found it returns this
                    us = {LUser, LServer}, jid = LJID}
     end;

get_roster_by_jid_t(LUser, LServer, LJID, mnesia) ->
    case mnesia:read({roster, {LUser, LServer, LJID}}) of
      [] ->
	  #roster{usj = {LUser, LServer, LJID},
		  us = {LUser, LServer}, jid = LJID};
      [I] ->
	  I#roster{jid = LJID, name = <<"">>, groups = [],
		   xs = []}
    end;
get_roster_by_jid_t(LUser, LServer, LJID, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    {selected,
     [<<"username">>, <<"jid">>, <<"nick">>,
      <<"subscription">>, <<"ask">>, <<"askmessage">>,
      <<"server">>, <<"subscribe">>, <<"type">>],
     Res} =
	odbc_queries:get_roster_by_jid(LServer, Username, SJID),
    case Res of
      [] ->
	  #roster{usj = {LUser, LServer, LJID},
		  us = {LUser, LServer}, jid = LJID};
      [I] ->
	  R = raw_to_record(LServer, I),
	  case R of
	    %% Bad JID in database:
	    error ->
		#roster{usj = {LUser, LServer, LJID},
			us = {LUser, LServer}, jid = LJID};
	    _ ->
		R#roster{usj = {LUser, LServer, LJID},
			 us = {LUser, LServer}, jid = LJID, name = <<"">>}
	  end
    end;
get_roster_by_jid_t(LUser, LServer, LJID, p1db) ->
    USJKey = usj2key(LUser, LServer, LJID),
    case p1db:get(roster, USJKey) of
        {ok, Val, _VClock} ->
            I = p1db_to_item({LUser, LServer, LJID}, Val),
            I#roster{jid = LJID, name = <<"">>, groups = [], xs = []};
        {error, notfound} ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer}, jid = LJID};
        {error, _} = Err ->
            exit(Err)
    end;
get_roster_by_jid_t(LUser, LServer, LJID, riak) ->
    case ejabberd_riak:get(roster, roster_schema(), {LUser, LServer, LJID}) of
        {ok, I} ->
            I#roster{jid = LJID, name = <<"">>, groups = [],
                     xs = []};
        {error, notfound} ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer}, jid = LJID};
        Err ->
            exit(Err)
    end.

try_process_iq_set(From, To, #iq{sub_el = SubEl} = IQ) ->
    #jid{server = Server} = From,
    Access = gen_mod:get_module_opt(Server, ?MODULE, access, fun(A) when is_atom(A) -> A end, all),
    case acl:match_rule(Server, Access, From) of
	deny ->
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_NOT_ALLOWED]};
	allow ->
	    process_iq_set(From, To, IQ)
    end.

process_iq_set(From, To, #iq{sub_el = SubEl, id = Id} = IQ) ->
    #xmlel{children = Els} = SubEl,
    Managed = is_managed_from_id(Id),
    lists:foreach(fun (El) -> process_item_set(From, To, El, Managed)
		  end,
		  Els),
    IQ#iq{type = result, sub_el = []}.

process_item_set(From, To,
		 #xmlel{attrs = Attrs, children = Els}, Managed) ->
    JID1 = jlib:string_to_jid(xml:get_attr_s(<<"jid">>,
					     Attrs)),
    #jid{user = User, luser = LUser, lserver = LServer} =
	From,
    case JID1 of
      error -> ok;
      _ ->
	  LJID = jlib:jid_tolower(JID1),
	  F = fun () ->
		      Item = get_roster_by_jid_t(LUser, LServer, LJID),
		      Item1 = process_item_attrs_managed(Item, Attrs, Managed),
		      Item2 = process_item_els(Item1, Els),
		      case Item2#roster.subscription of
			remove -> del_roster_t(LUser, LServer, LJID);
			_ -> update_roster_t(LUser, LServer, LJID, Item2)
		      end,
                      send_itemset_to_managers(From, Item2, Managed),
		      Item3 = ejabberd_hooks:run_fold(roster_process_item,
						      LServer, Item2,
						      [LServer]),
		      case roster_version_on_db(LServer) of
			true -> write_roster_version_t(LUser, LServer);
			false -> ok
		      end,
		      {Item, Item3}
	      end,
	  case transaction(LServer, F) of
	    {atomic, {OldItem, Item}} ->
		push_item(User, LServer, To, Item),
		case Item#roster.subscription of
		  remove ->
		      send_unsubscribing_presence(From, OldItem), ok;
		  _ -> ok
		end;
	    E ->
		?DEBUG("ROSTER: roster item set error: ~p~n", [E]), ok
	  end
    end;
process_item_set(_From, _To, _, _Managed) -> ok.

process_item_attrs(Item, [{Attr, Val} | Attrs]) ->
    case Attr of
      <<"jid">> ->
	  case jlib:string_to_jid(Val) of
	    error -> process_item_attrs(Item, Attrs);
	    JID1 ->
		JID = {JID1#jid.luser, JID1#jid.lserver,
		       JID1#jid.lresource},
		process_item_attrs(Item#roster{jid = JID}, Attrs)
	  end;
      <<"name">> ->
	  process_item_attrs(Item#roster{name = Val}, Attrs);
      <<"subscription">> ->
	  case Val of
	    <<"remove">> ->
		process_item_attrs(Item#roster{subscription = remove},
				   Attrs);
	    _ -> process_item_attrs(Item, Attrs)
	  end;
      <<"ask">> -> process_item_attrs(Item, Attrs);
      _ -> process_item_attrs(Item, Attrs)
    end;
process_item_attrs(Item, []) -> Item.

process_item_els(Item,
		 [#xmlel{name = Name, attrs = Attrs, children = SEls}
		  | Els]) ->
    case Name of
      <<"group">> ->
	  Groups = [xml:get_cdata(SEls) | Item#roster.groups],
	  process_item_els(Item#roster{groups = Groups}, Els);
      _ ->
	  case xml:get_attr_s(<<"xmlns">>, Attrs) of
	    <<"">> -> process_item_els(Item, Els);
	    _ ->
		XEls = [#xmlel{name = Name, attrs = Attrs,
			       children = SEls}
			| Item#roster.xs],
		process_item_els(Item#roster{xs = XEls}, Els)
	  end
    end;
process_item_els(Item, [{xmlcdata, _} | Els]) ->
    process_item_els(Item, Els);
process_item_els(Item, []) -> Item.

push_item(User, Server, From, Item) ->
    ejabberd_sm:route(jlib:make_jid(<<"">>, <<"">>, <<"">>),
		      jlib:make_jid(User, Server, <<"">>),
                      {broadcast, {item, Item#roster.jid,
				   Item#roster.subscription}}),
    case roster_versioning_enabled(Server) of
      true ->
	  push_item_version(Server, User, From, Item,
			    roster_version(Server, User));
      false ->
	  lists:foreach(fun (Resource) ->
				push_item(User, Server, Resource, From, Item)
			end,
			ejabberd_sm:get_user_resources(User, Server))
    end.

push_item(User, Server, Resource, From, Item) ->
    push_item(User, Server, Resource, From, Item,
	      not_found).

push_item(User, Server, Resource, From, Item,
	  RosterVersion) ->
    ExtraAttrs = case RosterVersion of
		   not_found -> [];
		   _ -> [{<<"ver">>, RosterVersion}]
		 end,
    ResIQ = #iq{type = set, xmlns = ?NS_ROSTER,
		id = <<"push", (randoms:get_string())/binary>>,
		sub_el =
		    [#xmlel{name = <<"query">>,
			    attrs = [{<<"xmlns">>, ?NS_ROSTER} | ExtraAttrs],
			    children = [item_to_xml(Item)]}]},
    ejabberd_router:route(From,
			  jlib:make_jid(User, Server, Resource),
			  jlib:iq_to_xml(ResIQ)).

push_item_version(Server, User, From, Item,
		  RosterVersion) ->
    lists:foreach(fun (Resource) ->
			  push_item(User, Server, Resource, From, Item,
				    RosterVersion)
		  end,
		  ejabberd_sm:get_user_resources(User, Server)).

get_subscription_lists(Acc, User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    DBType = gen_mod:db_type(LServer, ?MODULE),
    Items = get_subscription_lists(Acc, LUser, LServer,
				   DBType),
    fill_subscription_lists(LServer, Items, [], [], []).

get_subscription_lists(_, LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    case mnesia:dirty_index_read(roster, US, #roster.us) of
      Items when is_list(Items) -> Items;
      _ -> []
    end;
get_subscription_lists(_, LUser, LServer, odbc) ->
    get_roster_odbc(LUser, LServer);
get_subscription_lists(_, LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(roster, USPrefix) of
        {ok, L} ->
            lists:map(
              fun({Key, Val, _VClock}) ->
                      LJID = key2jid(USPrefix, Key),
                      USJ = {LUser, LServer, LJID},
                      p1db_to_item(USJ, Val)
              end, L);
        {error, _} ->
            []
    end;
get_subscription_lists(_, LUser, LServer, riak) ->
    case ejabberd_riak:get_by_index(roster, roster_schema(),
				    <<"us">>, {LUser, LServer}) of
        {ok, Items} -> Items;
        _Err -> []
    end;
get_subscription_lists(_, LUser, LServer, rest) ->
        get_roster(LUser, LServer, rest).

fill_subscription_lists(LServer, [#roster{} = I | Is],
			F, T, B) ->
    J = element(3, I#roster.usj),
    case I#roster.subscription of
      both ->
	  fill_subscription_lists(LServer, Is, F,  T, [J|B]);
      from ->
	  fill_subscription_lists(LServer, Is, [J | F], T, B);
      to -> fill_subscription_lists(LServer, Is, F, [J | T], B);
      _ -> fill_subscription_lists(LServer, Is, F, T, B)
    end;
fill_subscription_lists(LServer, [RawI | Is], F, T, B) ->
    I = raw_to_record(LServer, RawI),
    case I of
      %% Bad JID in database:
      error -> fill_subscription_lists(LServer, Is, F, T, B);
      _ -> fill_subscription_lists(LServer, [I | Is], F, T, B)
    end;
fill_subscription_lists(_LServer, [], F, T, B) -> {F, T, B}.

ask_to_pending(subscribe) -> out;
ask_to_pending(unsubscribe) -> none;
ask_to_pending(Ask) -> Ask.

roster_subscribe_t(LUser, LServer, LJID, Item) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    roster_subscribe_t(LUser, LServer, LJID, Item, DBType).

roster_subscribe_t(_LUser, _LServer, _LJID, Item,
		   mnesia) ->
    mnesia:write(Item);
roster_subscribe_t(LUser, LServer, LJID, Item, odbc) ->
    ItemVals = record_to_string(Item),
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    del_roster_cache(LUser, LServer),
    odbc_queries:roster_subscribe(LServer, Username, SJID,
				  ItemVals);
roster_subscribe_t(LUser, LServer, LJID, Item, p1db) ->
    USJKey = usj2key(LUser, LServer, LJID),
    Val = item_to_p1db(Item),
    p1db:insert(roster, USJKey, Val);
roster_subscribe_t(LUser, LServer, _LJID, Item, riak) ->
    ejabberd_riak:put(Item, roster_schema(),
                      [{'2i', [{<<"us">>, {LUser, LServer}}]}]);
roster_subscribe_t(_LUser, _LServer, _LJID, _Item, rest) ->
        error.

transaction(LServer, F) ->
    case gen_mod:db_type(LServer, ?MODULE) of
      mnesia -> mnesia:transaction(F);
      odbc -> ejabberd_odbc:sql_transaction(LServer, F);
      p1db -> {atomic, F()};
      riak -> {atomic, F()};
      rest -> {atomic, F()}  %%transaction?
    end.

in_subscription(_, User, Server, JID, Type, Reason) ->
    process_subscription(in, User, Server, JID, Type,
			 Reason).

out_subscription(User, Server, JID, Type) ->
    process_subscription(out, User, Server, JID, Type, <<"">>).

get_roster_by_jid_with_groups_t(LUser, LServer, LJID) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    get_roster_by_jid_with_groups_t(LUser, LServer, LJID,
				    DBType).

get_roster_by_jid_with_groups_t(LUser, LServer, LJID,
				mnesia) ->
    case mnesia:read({roster, {LUser, LServer, LJID}}) of
      [] ->
	  #roster{usj = {LUser, LServer, LJID},
		  us = {LUser, LServer}, jid = LJID};
      [I] -> I
    end;
get_roster_by_jid_with_groups_t(LUser, LServer, LJID,
				odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    case odbc_queries:get_roster_by_jid(LServer, Username,
					SJID)
	of
      {selected,
       [<<"username">>, <<"jid">>, <<"nick">>,
	<<"subscription">>, <<"ask">>, <<"askmessage">>,
	<<"server">>, <<"subscribe">>, <<"type">>],
       [I]} ->
	  R = raw_to_record(LServer, I),
	  Groups = case odbc_queries:get_roster_groups(LServer,
						       Username, SJID)
		       of
		     {selected, [<<"grp">>], JGrps} when is_list(JGrps) ->
			 [JGrp || [JGrp] <- JGrps];
		     _ -> []
		   end,
	  R#roster{groups = Groups};
      {selected,
       [<<"username">>, <<"jid">>, <<"nick">>,
	<<"subscription">>, <<"ask">>, <<"askmessage">>,
	<<"server">>, <<"subscribe">>, <<"type">>],
       []} ->
	  #roster{usj = {LUser, LServer, LJID},
		  us = {LUser, LServer}, jid = LJID}
    end;
get_roster_by_jid_with_groups_t(LUser, LServer, LJID, p1db) ->
    USJKey = usj2key(LUser, LServer, LJID),
    case p1db:get(roster, USJKey) of
        {ok, Val, _VClock} ->
            p1db_to_item({LUser, LServer, LJID}, Val);
        {error, notfound} ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer}, jid = LJID};
        {error, _} = Err ->
            exit(Err)
    end;
get_roster_by_jid_with_groups_t(LUser, LServer, LJID, riak) ->
    case ejabberd_riak:get(roster, roster_schema(), {LUser, LServer, LJID}) of
        {ok, I} ->
            I;
        {error, notfound} ->
            #roster{usj = {LUser, LServer, LJID},
                    us = {LUser, LServer}, jid = LJID};
        Err ->
            exit(Err)
    end;
get_roster_by_jid_with_groups_t(LUser, LServer, LJID, rest) ->
    get_roster_by_jid_t(LUser, LServer, LJID, rest).   %%what is the difference?

process_subscription(Direction, User, Server, JID1,
		     Type, Reason) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    LJID = jlib:jid_tolower(JID1),
    F = fun () ->
		Item = get_roster_by_jid_with_groups_t(LUser, LServer,
						       LJID),
		NewState = case Direction of
			     out ->
				 out_state_change(Item#roster.subscription,
						  Item#roster.ask, Type);
			     in ->
				 in_state_change(Item#roster.subscription,
						 Item#roster.ask, Type)
			   end,
		AutoReply = case Direction of
			      out -> none;
			      in ->
				  in_auto_reply(Item#roster.subscription,
						Item#roster.ask, Type)
			    end,
		AskMessage = case NewState of
			       {_, both} -> Reason;
			       {_, in} -> Reason;
			       _ -> <<"">>
			     end,
		case NewState of
		  none -> {none, AutoReply};
		  {none, none}
		      when Item#roster.subscription == none,
			   Item#roster.ask == in ->
		      del_roster_t(LUser, LServer, LJID), {none, AutoReply};
		  {Subscription, Pending} ->
		      NewItem = Item#roster{subscription = Subscription,
					    ask = Pending,
					    askmessage =
						iolist_to_binary(AskMessage)},
		      roster_subscribe_t(LUser, LServer, LJID, NewItem),
		      case roster_version_on_db(LServer) of
			true -> write_roster_version_t(LUser, LServer);
			false -> ok
		      end,
		      {{push, NewItem}, AutoReply}
		end
	end,
    case transaction(LServer, F) of
      {atomic, {Push, AutoReply}} ->
	  case AutoReply of
	    none -> ok;
	    _ ->
		T = case AutoReply of
		      subscribed -> <<"subscribed">>;
		      unsubscribed -> <<"unsubscribed">>
		    end,
		ejabberd_router:route(jlib:make_jid(User, Server,
						    <<"">>),
				      JID1,
				      #xmlel{name = <<"presence">>,
					     attrs = [{<<"type">>, T}],
					     children = []})
	  end,
	  case Push of
	    {push, Item} ->
		if Item#roster.subscription == none,
		   Item#roster.ask == in ->
		       ok;
		   true ->
		       push_item(User, Server,
				 jlib:make_jid(User, Server, <<"">>), Item)
		end,
		true;
	    none -> false
	  end;
      _ -> false
    end.

%% in_state_change(Subscription, Pending, Type) -> NewState
%% NewState = none | {NewSubscription, NewPending}
-ifdef(ROSTER_GATEWAY_WORKAROUND).

-define(NNSD, {to, none}).

-define(NISD, {to, in}).

-else.

-define(NNSD, none).

-define(NISD, none).

-endif.

in_state_change(none, none, subscribe) -> {none, in};
in_state_change(none, none, subscribed) -> ?NNSD;
in_state_change(none, none, unsubscribe) -> none;
in_state_change(none, none, unsubscribed) -> none;
in_state_change(none, out, subscribe) -> {none, both};
in_state_change(none, out, subscribed) -> {to, none};
in_state_change(none, out, unsubscribe) -> none;
in_state_change(none, out, unsubscribed) ->
    {none, none};
in_state_change(none, in, subscribe) -> none;
in_state_change(none, in, subscribed) -> ?NISD;
in_state_change(none, in, unsubscribe) -> {none, none};
in_state_change(none, in, unsubscribed) -> none;
in_state_change(none, both, subscribe) -> none;
in_state_change(none, both, subscribed) -> {to, in};
in_state_change(none, both, unsubscribe) -> {none, out};
in_state_change(none, both, unsubscribed) -> {none, in};
in_state_change(to, none, subscribe) -> {to, in};
in_state_change(to, none, subscribed) -> none;
in_state_change(to, none, unsubscribe) -> none;
in_state_change(to, none, unsubscribed) -> {none, none};
in_state_change(to, in, subscribe) -> none;
in_state_change(to, in, subscribed) -> none;
in_state_change(to, in, unsubscribe) -> {to, none};
in_state_change(to, in, unsubscribed) -> {none, in};
in_state_change(from, none, subscribe) -> none;
in_state_change(from, none, subscribed) -> {both, none};
in_state_change(from, none, unsubscribe) ->
    {none, none};
in_state_change(from, none, unsubscribed) -> none;
in_state_change(from, out, subscribe) -> none;
in_state_change(from, out, subscribed) -> {both, none};
in_state_change(from, out, unsubscribe) -> {none, out};
in_state_change(from, out, unsubscribed) ->
    {from, none};
in_state_change(both, none, subscribe) -> none;
in_state_change(both, none, subscribed) -> none;
in_state_change(both, none, unsubscribe) -> {to, none};
in_state_change(both, none, unsubscribed) ->
    {from, none}.

out_state_change(none, none, subscribe) -> {none, out};
out_state_change(none, none, subscribed) -> none;
out_state_change(none, none, unsubscribe) -> none;
out_state_change(none, none, unsubscribed) -> none;
out_state_change(none, out, subscribe) ->
    {none,
     out}; %% We need to resend query (RFC3921, section 9.2)
out_state_change(none, out, subscribed) -> none;
out_state_change(none, out, unsubscribe) ->
    {none, none};
out_state_change(none, out, unsubscribed) -> none;
out_state_change(none, in, subscribe) -> {none, both};
out_state_change(none, in, subscribed) -> {from, none};
out_state_change(none, in, unsubscribe) -> none;
out_state_change(none, in, unsubscribed) ->
    {none, none};
out_state_change(none, both, subscribe) -> none;
out_state_change(none, both, subscribed) -> {from, out};
out_state_change(none, both, unsubscribe) -> {none, in};
out_state_change(none, both, unsubscribed) ->
    {none, out};
out_state_change(to, none, subscribe) -> none;
out_state_change(to, none, subscribed) -> {both, none};
out_state_change(to, none, unsubscribe) -> {none, none};
out_state_change(to, none, unsubscribed) -> none;
out_state_change(to, in, subscribe) -> none;
out_state_change(to, in, subscribed) -> {both, none};
out_state_change(to, in, unsubscribe) -> {none, in};
out_state_change(to, in, unsubscribed) -> {to, none};
out_state_change(from, none, subscribe) -> {from, out};
out_state_change(from, none, subscribed) -> none;
out_state_change(from, none, unsubscribe) -> none;
out_state_change(from, none, unsubscribed) ->
    {none, none};
out_state_change(from, out, subscribe) -> none;
out_state_change(from, out, subscribed) -> none;
out_state_change(from, out, unsubscribe) ->
    {from, none};
out_state_change(from, out, unsubscribed) ->
    {none, out};
out_state_change(both, none, subscribe) -> none;
out_state_change(both, none, subscribed) -> none;
out_state_change(both, none, unsubscribe) ->
    {from, none};
out_state_change(both, none, unsubscribed) ->
    {to, none}.

in_auto_reply(from, none, subscribe) -> subscribed;
in_auto_reply(from, out, subscribe) -> subscribed;
in_auto_reply(both, none, subscribe) -> subscribed;
in_auto_reply(none, in, unsubscribe) -> unsubscribed;
in_auto_reply(none, both, unsubscribe) -> unsubscribed;
in_auto_reply(to, in, unsubscribe) -> unsubscribed;
in_auto_reply(from, none, unsubscribe) -> unsubscribed;
in_auto_reply(from, out, unsubscribe) -> unsubscribed;
in_auto_reply(both, none, unsubscribe) -> unsubscribed;
in_auto_reply(_, _, _) -> none.

remove_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    send_unsubscription_to_rosteritems(LUser, LServer),
    remove_user(LUser, LServer,
		gen_mod:db_type(LServer, ?MODULE)).

remove_user(LUser, LServer, mnesia) ->
    US = {LUser, LServer},
    F = fun () ->
		lists:foreach(fun (R) -> mnesia:delete_object(R) end,
			      mnesia:index_read(roster, US, #roster.us))
	end,
    mnesia:transaction(F);
remove_user(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    del_roster_cache(LUser, LServer),
    odbc_queries:del_user_roster_t(LServer, Username),
    ok;
remove_user(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(roster, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _Val, VClock}) ->
                      p1db:delete(roster, Key,
                                  p1db:incr_vclock(VClock))
              end, L),
            {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end;
remove_user(LUser, LServer, riak) ->
    {atomic, ejabberd_riak:delete_by_index(roster, <<"us">>, {LUser, LServer})};
remove_user(_LUser, _LServer, rest) ->
    error.

send_unsubscription_to_rosteritems(LUser, LServer) ->
    RosterItems = get_user_roster([], {LUser, LServer}),
    From = jlib:make_jid({LUser, LServer, <<"">>}),
    lists:foreach(fun (RosterItem) ->
			  send_unsubscribing_presence(From, RosterItem)
		  end,
		  RosterItems).

send_unsubscribing_presence(From, Item) ->
    IsTo = case Item#roster.subscription of
	     both -> true;
	     to -> true;
	     _ -> false
	   end,
    IsFrom = case Item#roster.subscription of
	       both -> true;
	       from -> true;
	       _ -> false
	     end,
    if IsTo ->
	   send_presence_type(jlib:jid_remove_resource(From),
			      jlib:make_jid(Item#roster.jid),
			      <<"unsubscribe">>);
       true -> ok
    end,
    if IsFrom ->
	   send_presence_type(jlib:jid_remove_resource(From),
			      jlib:make_jid(Item#roster.jid),
			      <<"unsubscribed">>);
       true -> ok
    end,
    ok.

send_presence_type(From, To, Type) ->
    ejabberd_router:route(From, To,
			  #xmlel{name = <<"presence">>,
				 attrs = [{<<"type">>, Type}], children = []}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

set_items(User, Server, SubEl) ->
    #xmlel{children = Els} = SubEl,
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    F = fun () ->
		lists:foreach(fun (El) ->
				      process_item_set_t(LUser, LServer, El)
			      end,
			      Els)
	end,
    transaction(LServer, F).

update_roster_t(LUser, LServer, LJID, Item) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    update_roster_t(LUser, LServer, LJID, Item, DBType).

update_roster_t(_LUser, _LServer, _LJID, Item,
		mnesia) ->
    mnesia:write(Item);
update_roster_t(LUser, LServer, LJID, Item, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    ItemVals = record_to_string(Item),
    ItemGroups = groups_to_string(Item),
    del_roster_cache(LUser, LServer),
    odbc_queries:update_roster(LServer, Username, SJID, ItemVals,
                               ItemGroups);
update_roster_t(LUser, LServer, LJID, Item, p1db) ->
    USJKey = usj2key(LUser, LServer, LJID),
    p1db:insert(roster, USJKey, item_to_p1db(Item));
update_roster_t(LUser, LServer, _LJID, Item, riak) ->
    ejabberd_riak:put(Item, roster_schema(),
                      [{'2i', [{<<"us">>, {LUser, LServer}}]}]);
update_roster_t(_LUser, _LServer, _LJID, _Item, rest) ->
    error.

del_roster_t(LUser, LServer, LJID) ->
    DBType = gen_mod:db_type(LServer, ?MODULE),
    del_roster_t(LUser, LServer, LJID, DBType).

del_roster_t(LUser, LServer, LJID, mnesia) ->
    mnesia:delete({roster, {LUser, LServer, LJID}});
del_roster_t(LUser, LServer, LJID, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    del_roster_cache(LUser, LServer),
    odbc_queries:del_roster(LServer, Username, SJID);
del_roster_t(LUser, LServer, LJID, p1db) ->
    USJKey = usj2key(LUser, LServer, LJID),
    p1db:delete(roster, USJKey);
del_roster_t(LUser, LServer, LJID, riak) ->
    ejabberd_riak:delete(roster, {LUser, LServer, LJID});
del_roster_t(_LUser, _LServer, _LJID, rest) ->
    error.

process_item_set_t(LUser, LServer,
		   #xmlel{attrs = Attrs, children = Els}) ->
    JID1 = jlib:string_to_jid(xml:get_attr_s(<<"jid">>,
					     Attrs)),
    case JID1 of
      error -> ok;
      _ ->
	  JID = {JID1#jid.user, JID1#jid.server,
		 JID1#jid.resource},
	  LJID = {JID1#jid.luser, JID1#jid.lserver,
		  JID1#jid.lresource},
	  Item = #roster{usj = {LUser, LServer, LJID},
			 us = {LUser, LServer}, jid = JID},
	  Item1 = process_item_attrs_ws(Item, Attrs),
	  Item2 = process_item_els(Item1, Els),
	  case Item2#roster.subscription of
	    remove -> del_roster_t(LUser, LServer, LJID);
	    _ -> update_roster_t(LUser, LServer, LJID, Item2)
	  end
    end;
process_item_set_t(_LUser, _LServer, _) -> ok.

process_item_attrs_ws(Item, [{Attr, Val} | Attrs]) ->
    case Attr of
      <<"jid">> ->
	  case jlib:string_to_jid(Val) of
	    error -> process_item_attrs_ws(Item, Attrs);
	    JID1 ->
		JID = {JID1#jid.luser, JID1#jid.lserver,
		       JID1#jid.lresource},
		process_item_attrs_ws(Item#roster{jid = JID}, Attrs)
	  end;
      <<"name">> ->
	  process_item_attrs_ws(Item#roster{name = Val}, Attrs);
      <<"subscription">> ->
	  case Val of
	    <<"remove">> ->
		process_item_attrs_ws(Item#roster{subscription =
						      remove},
				      Attrs);
	    <<"none">> ->
		process_item_attrs_ws(Item#roster{subscription = none},
				      Attrs);
	    <<"both">> ->
		process_item_attrs_ws(Item#roster{subscription = both},
				      Attrs);
	    <<"from">> ->
		process_item_attrs_ws(Item#roster{subscription = from},
				      Attrs);
	    <<"to">> ->
		process_item_attrs_ws(Item#roster{subscription = to},
				      Attrs);
	    _ -> process_item_attrs_ws(Item, Attrs)
	  end;
      <<"ask">> -> process_item_attrs_ws(Item, Attrs);
      _ -> process_item_attrs_ws(Item, Attrs)
    end;
process_item_attrs_ws(Item, []) -> Item.

get_in_pending_subscriptions(Ls, User, Server) ->
    LServer = jlib:nameprep(Server),
    get_in_pending_subscriptions(Ls, User, Server,
				 gen_mod:db_type(LServer, ?MODULE)).

get_in_pending_subscriptions(Ls, User, Server, DBType)
  when DBType == mnesia; DBType == riak; DBType == p1db ->
    JID = jlib:make_jid(User, Server, <<"">>),
    Result = get_roster(JID#jid.luser, JID#jid.lserver, DBType),
    Ls ++ lists:map(fun (R) ->
                            Message = R#roster.askmessage,
                            Status = if is_binary(Message) -> (Message);
                                        true -> <<"">>
                                     end,
                            #xmlel{name = <<"presence">>,
                                   attrs =
                                       [{<<"from">>,
                                         jlib:jid_to_string(R#roster.jid)},
                                        {<<"to">>, jlib:jid_to_string(JID)},
                                        {<<"type">>, <<"subscribe">>}],
                                   children =
                                       [#xmlel{name = <<"status">>,
                                               attrs = [],
                                               children =
                                                   [{xmlcdata, Status}]}]}
                    end,
                    lists:filter(fun (R) ->
                                         case R#roster.ask of
                                             in -> true;
                                             both -> true;
                                             _ -> false
                                         end
                                 end,
                                 Result));
get_in_pending_subscriptions(Ls, User, Server, odbc) ->
    JID = jlib:make_jid(User, Server, <<"">>),
    LUser = JID#jid.luser,
    LServer = JID#jid.lserver,
    Items = get_roster_odbc(LUser, LServer),
    Ls ++ lists:map(
            fun(R) ->
                    Message = R#roster.askmessage,
                    #xmlel{name = <<"presence">>,
                           attrs = [{<<"from">>, jlib:jid_to_string(R#roster.jid)},
                                    {<<"to">>, jlib:jid_to_string(JID)},
                                    {<<"type">>, <<"subscribe">>}],
                           children = [#xmlel{name = <<"status">>,
                                              attrs = [],
                                              children = [{xmlcdata, Message}]}]}
            end,
            lists:filter(
              fun(R) ->
                      case R#roster.ask of
                          in -> true;
                          both -> true;
                          _ -> false
                      end
              end, Items));
get_in_pending_subscriptions(_Ls, _User, _Server, rest) ->
        [].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

read_subscription_and_groups(User, Server, LJID) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    read_subscription_and_groups(LUser, LServer, LJID,
				 gen_mod:db_type(LServer, ?MODULE)).

read_subscription_and_groups(LUser, LServer, LJID,
			     mnesia) ->
    case catch mnesia:dirty_read(roster,
				 {LUser, LServer, LJID})
	of
      [#roster{subscription = Subscription,
	       groups = Groups}] ->
	  {Subscription, Groups};
      _ -> error
    end;
read_subscription_and_groups(LUser, LServer, LJID,
			     odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
    case catch odbc_queries:get_subscription(LServer,
					     Username, SJID)
	of
      {selected, [<<"subscription">>], [[SSubscription]]} ->
	  Subscription = case SSubscription of
			   <<"B">> -> both;
			   <<"T">> -> to;
			   <<"F">> -> from;
			   _ -> none
			 end,
	  Groups = case catch
			  odbc_queries:get_rostergroup_by_jid(LServer, Username,
							      SJID)
		       of
		     {selected, [<<"grp">>], JGrps} when is_list(JGrps) ->
			 [JGrp || [JGrp] <- JGrps];
		     _ -> []
		   end,
	  {Subscription, Groups};
      _ -> error
    end;
read_subscription_and_groups(LUser, LServer, LJID, p1db) ->
    USJKey = usj2key(LUser, LServer, LJID),
    case p1db:get(roster, USJKey) of
        {ok, Val, _VClock} ->
            #roster{subscription = Subscription,
                    groups = Groups}
                = p1db_to_item({LUser, LServer, LJID}, Val),
            {Subscription, Groups};
        {error, _} ->
            error
    end;
read_subscription_and_groups(LUser, LServer, LJID,
			     riak) ->
    case ejabberd_riak:get(roster, roster_schema(), {LUser, LServer, LJID}) of
        {ok, #roster{subscription = Subscription,
                     groups = Groups}} ->
            {Subscription, Groups};
        _ ->
            error
    end;
read_subscription_and_groups(LUser, LServer, LJID,
			     rest) ->
      case get_roster_by_jid_with_groups_t(LUser, LServer, LJID, rest) of
        #roster{subscription = Subscription,
	       groups = Groups} ->
                {Subscription, Groups};
        _ ->
                error
      end.

get_jid_info(_, User, Server, JID) ->
    LJID = jlib:jid_tolower(JID),
    case read_subscription_and_groups(User, Server, LJID) of
      {Subscription, Groups} -> {Subscription, Groups};
      error ->
	  LRJID = jlib:jid_tolower(jlib:jid_remove_resource(JID)),
	  if LRJID == LJID -> {none, []};
	     true ->
		 case read_subscription_and_groups(User, Server, LRJID)
		     of
		   {Subscription, Groups} -> {Subscription, Groups};
		   error -> {none, []}
		 end
	  end
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

raw_to_record(LServer,
	      [User, SJID, Nick, SSubscription, SAsk, SAskMessage,
	       _SServer, _SSubscribe, _SType]) ->
    case jlib:string_to_jid(SJID) of
      error -> error;
      JID ->
	  LJID = jlib:jid_tolower(JID),
	  Subscription = case SSubscription of
			   <<"B">> -> both;
			   <<"T">> -> to;
			   <<"F">> -> from;
			   _ -> none
			 end,
	  Ask = case SAsk of
		  <<"S">> -> subscribe;
		  <<"U">> -> unsubscribe;
		  <<"B">> -> both;
		  <<"O">> -> out;
		  <<"I">> -> in;
		  _ -> none
		end,
	  #roster{usj = {User, LServer, LJID},
		  us = {User, LServer}, jid = LJID, name = Nick,
		  subscription = Subscription, ask = Ask,
		  askmessage = SAskMessage}
    end.

record_to_string(#roster{us = {User, _Server},
			 jid = JID, name = Name, subscription = Subscription,
			 ask = Ask, askmessage = AskMessage}) ->
    Username = ejabberd_odbc:escape(User),
    SJID =
	ejabberd_odbc:escape(jlib:jid_to_string(jlib:jid_tolower(JID))),
    Nick = ejabberd_odbc:escape(Name),
    SSubscription = case Subscription of
		      both -> <<"B">>;
		      to -> <<"T">>;
		      from -> <<"F">>;
		      none -> <<"N">>
		    end,
    SAsk = case Ask of
	     subscribe -> <<"S">>;
	     unsubscribe -> <<"U">>;
	     both -> <<"B">>;
	     out -> <<"O">>;
	     in -> <<"I">>;
	     none -> <<"N">>
	   end,
    SAskMessage = ejabberd_odbc:escape(AskMessage),
    [Username, SJID, Nick, SSubscription, SAsk, SAskMessage,
     <<"N">>, <<"">>, <<"item">>].

groups_to_string(#roster{us = {User, _Server},
			 jid = JID, groups = Groups}) ->
    Username = ejabberd_odbc:escape(User),
    SJID =
	ejabberd_odbc:escape(jlib:jid_to_string(jlib:jid_tolower(JID))),
    lists:foldl(fun (<<"">>, Acc) -> Acc;
		    (Group, Acc) ->
			G = ejabberd_odbc:escape(Group),
			[[Username, SJID, G] | Acc]
		end,
		[], Groups).

use_cache(LServer) ->
    gen_mod:get_module_opt(LServer, ?MODULE, use_cache,
                           fun(B) when is_boolean(B) -> B end,
                           false).

update_tables() ->
    update_roster_table(),
    update_roster_version_table().

update_roster_table() ->
    Fields = record_info(fields, roster),
    case mnesia:table_info(roster, attributes) of
      Fields ->
          ejabberd_config:convert_table_to_binary(
            roster, Fields, set,
            fun(#roster{usj = {U, _, _}}) -> U end,
            fun(#roster{usj = {U, S, {LU, LS, LR}},
                        us = {U1, S1},
                        jid = {U2, S2, R2},
                        name = Name,
                        groups = Gs,
                        askmessage = Ask,
                        xs = Xs} = R) ->
                    R#roster{usj = {iolist_to_binary(U),
                                    iolist_to_binary(S),
                                    {iolist_to_binary(LU),
                                     iolist_to_binary(LS),
                                     iolist_to_binary(LR)}},
                             us = {iolist_to_binary(U1),
                                   iolist_to_binary(S1)},
                             jid = {iolist_to_binary(U2),
                                    iolist_to_binary(S2),
                                    iolist_to_binary(R2)},
                             name = iolist_to_binary(Name),
                             groups = [iolist_to_binary(G) || G <- Gs],
                             askmessage = try iolist_to_binary(Ask)
					  catch _:_ -> <<"">> end,
                             xs = [xml:to_xmlel(X) || X <- Xs]}
            end);
      _ ->
	  ?INFO_MSG("Recreating roster table", []),
	  mnesia:transform_table(roster, ignore, Fields)
    end.

update_roster_version_table() ->
    Fields = record_info(fields, roster_version),
    case mnesia:table_info(roster_version, attributes) of
        Fields ->
            ejabberd_config:convert_table_to_binary(
              roster_version, Fields, set,
              fun(#roster_version{us = {U, _}}) -> U end,
              fun(#roster_version{us = {U, S}, version = Ver} = R) ->
                      R#roster_version{us = {iolist_to_binary(U),
                                             iolist_to_binary(S)},
                                       version = iolist_to_binary(Ver)}
              end);
        _ ->
            ?INFO_MSG("Recreating roster_version table", []),
            mnesia:transform_table(roster_version, ignore, Fields)
    end.

webadmin_page(_, Host,
	      #request{us = _US, path = [<<"user">>, U, <<"roster">>],
		       q = Query, lang = Lang} =
		  _Request) ->
    Res = user_roster(U, Host, Query, Lang), {stop, Res};
webadmin_page(Acc, _, _) -> Acc.

user_roster(User, Server, Query, Lang) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    US = {LUser, LServer},
    Items1 = get_roster(LUser, LServer),
    Res = user_roster_parse_query(User, Server, Items1,
				  Query),
    Items = get_roster(LUser, LServer),
    SItems = lists:sort(Items),
    FItems = case SItems of
	       [] -> [?CT(<<"None">>)];
	       _ ->
		   [?XE(<<"table">>,
			[?XE(<<"thead">>,
			     [?XE(<<"tr">>,
				  [?XCT(<<"td">>, <<"Jabber ID">>),
				   ?XCT(<<"td">>, <<"Nickname">>),
				   ?XCT(<<"td">>, <<"Subscription">>),
				   ?XCT(<<"td">>, <<"Pending">>),
				   ?XCT(<<"td">>, <<"Groups">>)])]),
			 ?XE(<<"tbody">>,
			     (lists:map(fun (R) ->
						Groups = lists:flatmap(fun
									 (Group) ->
									     [?C(Group),
									      ?BR]
								       end,
								       R#roster.groups),
						Pending =
						    ask_to_pending(R#roster.ask),
						TDJID =
						    build_contact_jid_td(R#roster.jid),
						?XE(<<"tr">>,
						    [TDJID,
						     ?XAC(<<"td">>,
							  [{<<"class">>,
							    <<"valign">>}],
							  (R#roster.name)),
						     ?XAC(<<"td">>,
							  [{<<"class">>,
							    <<"valign">>}],
							  (iolist_to_binary(atom_to_list(R#roster.subscription)))),
						     ?XAC(<<"td">>,
							  [{<<"class">>,
							    <<"valign">>}],
							  (iolist_to_binary(atom_to_list(Pending)))),
						     ?XAE(<<"td">>,
							  [{<<"class">>,
							    <<"valign">>}],
							  Groups),
						     if Pending == in ->
							    ?XAE(<<"td">>,
								 [{<<"class">>,
								   <<"valign">>}],
								 [?INPUTT(<<"submit">>,
									  <<"validate",
									    (ejabberd_web_admin:term_to_id(R#roster.jid))/binary>>,
									  <<"Validate">>)]);
							true -> ?X(<<"td">>)
						     end,
						     ?XAE(<<"td">>,
							  [{<<"class">>,
							    <<"valign">>}],
							  [?INPUTT(<<"submit">>,
								   <<"remove",
								     (ejabberd_web_admin:term_to_id(R#roster.jid))/binary>>,
								   <<"Remove">>)])])
					end,
					SItems)))])]
	     end,
    [?XC(<<"h1">>,
	 (<<(?T(<<"Roster of ">>))/binary, (us_to_list(US))/binary>>))]
      ++
      case Res of
	ok -> [?XREST(<<"Submitted">>)];
	error -> [?XREST(<<"Bad format">>)];
	nothing -> []
      end
	++
	[?XAE(<<"form">>,
	      [{<<"action">>, <<"">>}, {<<"method">>, <<"post">>}],
	      (FItems ++
		 [?P, ?INPUT(<<"text">>, <<"newjid">>, <<"">>),
		  ?C(<<" ">>),
		  ?INPUTT(<<"submit">>, <<"addjid">>,
			  <<"Add Jabber ID">>)]))].

build_contact_jid_td(RosterJID) ->
    ContactJID = jlib:make_jid(RosterJID),
    JIDURI = case {ContactJID#jid.luser,
		   ContactJID#jid.lserver}
		 of
	       {<<"">>, _} -> <<"">>;
	       {CUser, CServer} ->
		   case lists:member(CServer, ?MYHOSTS) of
		     false -> <<"">>;
		     true ->
			 <<"/admin/server/", CServer/binary, "/user/",
			   CUser/binary, "/">>
		   end
	     end,
    case JIDURI of
      <<>> ->
	  ?XAC(<<"td">>, [{<<"class">>, <<"valign">>}],
	       (jlib:jid_to_string(RosterJID)));
      URI when is_binary(URI) ->
	  ?XAE(<<"td">>, [{<<"class">>, <<"valign">>}],
	       [?AC(JIDURI, (jlib:jid_to_string(RosterJID)))])
    end.

user_roster_parse_query(User, Server, Items, Query) ->
    case lists:keysearch(<<"addjid">>, 1, Query) of
      {value, _} ->
	  case lists:keysearch(<<"newjid">>, 1, Query) of
	    {value, {_, SJID}} ->
		case jlib:string_to_jid(SJID) of
		  JID when is_record(JID, jid) ->
		      user_roster_subscribe_jid(User, Server, JID), ok;
		  error -> error
		end;
	    false -> error
	  end;
      false ->
	  case catch user_roster_item_parse_query(User, Server,
						  Items, Query)
	      of
	    submitted -> ok;
	    {'EXIT', _Reason} -> error;
	    _ -> nothing
	  end
    end.

user_roster_subscribe_jid(User, Server, JID) ->
    out_subscription(User, Server, JID, subscribe),
    UJID = jlib:make_jid(User, Server, <<"">>),
    ejabberd_router:route(UJID, JID,
			  #xmlel{name = <<"presence">>,
				 attrs = [{<<"type">>, <<"subscribe">>}],
				 children = []}).

user_roster_item_parse_query(User, Server, Items,
			     Query) ->
    lists:foreach(fun (R) ->
			  JID = R#roster.jid,
			  case lists:keysearch(<<"validate",
						 (ejabberd_web_admin:term_to_id(JID))/binary>>,
					       1, Query)
			      of
			    {value, _} ->
				JID1 = jlib:make_jid(JID),
				out_subscription(User, Server, JID1,
						 subscribed),
				UJID = jlib:make_jid(User, Server, <<"">>),
				ejabberd_router:route(UJID, JID1,
						      #xmlel{name =
								 <<"presence">>,
							     attrs =
								 [{<<"type">>,
								   <<"subscribed">>}],
							     children = []}),
				throw(submitted);
			    false ->
				case lists:keysearch(<<"remove",
						       (ejabberd_web_admin:term_to_id(JID))/binary>>,
						     1, Query)
				    of
				  {value, _} ->
				      UJID = jlib:make_jid(User, Server,
							   <<"">>),
				      process_iq_set(UJID, UJID,
						 #iq{type = set,
						     sub_el =
							 #xmlel{name =
								    <<"query">>,
								attrs =
								    [{<<"xmlns">>,
								      ?NS_ROSTER}],
								children =
								    [#xmlel{name
										=
										<<"item">>,
									    attrs
										=
										[{<<"jid">>,
										  jlib:jid_to_string(JID)},
										 {<<"subscription">>,
										  <<"remove">>}],
									    children
										=
										[]}]}}),
				      throw(submitted);
				  false -> ok
				end
			  end
		  end,
		  Items),
    nothing.

us_to_list({User, Server}) ->
    jlib:jid_to_string({User, Server, <<"">>}).

webadmin_user(Acc, _User, _Server, Lang) ->
    Acc ++
      [?XE(<<"h3">>, [?ACT(<<"roster/">>, <<"Roster">>)])].

us2key(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary>>.

usj2key(User, Server, JID) ->
    USKey = us2key(User, Server),
    SJID = jlib:jid_to_string(JID),
    <<USKey/binary, 0, SJID/binary>>.

key2jid(USPrefix, Key) ->
    Size = size(USPrefix),
    <<_:Size/binary, SJID/binary>> = Key,
    jlib:jid_tolower(jlib:string_to_jid(SJID)).

us_prefix(User, Server) ->
    USKey = us2key(User, Server),
    <<USKey/binary, 0>>.

item_to_p1db(Roster) ->
    Keys = record_info(fields, roster),
    DefRoster = #roster{us = Roster#roster.us,
                        usj = Roster#roster.usj,
                        jid = Roster#roster.jid},
    {_, PropList} = 
        lists:foldl(
          fun(Key, {Pos, L}) ->
                  Val = element(Pos, Roster),
                  DefVal = element(Pos, DefRoster),
                  if Val == DefVal ->
                          {Pos+1, L};
                     true ->
                          {Pos+1, [{Key, Val}|L]}
                  end
          end, {2, []}, Keys),
    term_to_binary(PropList).

p1db_to_item({LUser, LServer, LJID}, Val) ->
    Item = #roster{usj = {LUser, LServer, LJID},
                   us = {LUser, LServer},
                   jid = LJID},
    lists:foldl(
      fun({name, Name}, I) -> I#roster{name = Name};
         ({subscription, S}, I) -> I#roster{subscription = S};
         ({ask, Ask}, I) -> I#roster{ask = Ask};
         ({groups, Groups}, I) -> I#roster{groups = Groups};
         ({askmessage, AskMsg}, I) -> I#roster{askmessage = AskMsg};
         ({xs, Xs}, I) -> I#roster{xs = Xs};
         (_, I) -> I
      end, Item, binary_to_term(Val)).

%% P1DB/SQL schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, JID]) ->
    <<Server/binary, 0, User/binary, 0, JID/binary>>.

dec_roster_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, JID/binary>> = UKey,
    [Server, User, JID].

dec_roster_version_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, User/binary>> = Key,
    [Server, User].

enc_val(_, [Name, SSubscription, SAsk, SGroups, AskMsg, SXs]) ->
    Item = #roster{name = Name,
                   subscription = jlib:binary_to_atom(SSubscription),
                   ask = jlib:binary_to_atom(SAsk),
                   groups = jlib:expr_to_term(SGroups),
                   askmessage = AskMsg,
                   xs = jlib:expr_to_term(SXs)},
    item_to_p1db(Item).

dec_val([Server, User, SJID], Bin) ->
    LJID = jlib:jid_tolower(jlib:string_to_jid(SJID)),
    #roster{name = Name,
            subscription = Subscription,
            ask = Ask,
            groups = Groups,
            askmessage = AskMsg,
            xs = Xs} = p1db_to_item({User, Server, LJID}, Bin),
    [Name,
     jlib:atom_to_binary(Subscription),
     jlib:atom_to_binary(Ask),
     jlib:term_to_expr(Groups),
     AskMsg,
     jlib:term_to_expr(Xs)].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Implement XEP-0321 Remote Roster Management

process_iq_manager(From, To, IQ) ->
    %% Check what access is allowed for From to To
    MatchDomain = From#jid.lserver,
    case is_domain_managed(MatchDomain, To#jid.lserver) of
	true ->
	    process_iq_manager2(MatchDomain, To, IQ);
	false ->
	    #iq{sub_el = SubEl} = IQ,
	    IQ#iq{type = error, sub_el = [SubEl, ?ERR_BAD_REQUEST]}
    end.

process_iq_manager2(MatchDomain, To, IQ) ->
    %% If IQ is SET, filter the input IQ
    IQFiltered = maybe_filter_request(MatchDomain, IQ),
    %% Call the standard function with reversed JIDs
    IdInitial = IQFiltered#iq.id,
    ResIQ = process_iq(To, To, IQFiltered#iq{id = <<"roster-remotely-managed">>}),
    %% Filter the output IQ
    filter_stanza(MatchDomain, ResIQ#iq{id = IdInitial}).

is_domain_managed(ContactHost, UserHost) ->
    Managers = gen_mod:get_module_opt(UserHost, ?MODULE, managers,
						fun(B) when is_list(B) -> B end,
						[]),
    lists:member(ContactHost, Managers).

maybe_filter_request(MatchDomain, IQ) when IQ#iq.type == set ->
    filter_stanza(MatchDomain, IQ);
maybe_filter_request(_MatchDomain, IQ) ->
    IQ.

filter_stanza(_MatchDomain, #iq{sub_el = []} = IQ) ->
    IQ;
filter_stanza(MatchDomain, #iq{sub_el = [SubEl | _]} = IQ) ->
    #iq{sub_el = SubElFiltered} = IQRes =
	filter_stanza(MatchDomain, IQ#iq{sub_el = SubEl}),
    IQRes#iq{sub_el = [SubElFiltered]};
filter_stanza(MatchDomain, #iq{sub_el = SubEl} = IQ) ->
    #xmlel{name = Type, attrs = Attrs, children = Items} = SubEl,
    ItemsFiltered = lists:filter(
		      fun(Item) ->
			      is_item_of_domain(MatchDomain, Item) end, Items),
    SubElFiltered = #xmlel{name=Type, attrs = Attrs, children = ItemsFiltered},
    IQ#iq{sub_el = SubElFiltered}.

is_item_of_domain(MatchDomain, #xmlel{} = El) ->
    lists:any(fun(Attr) -> is_jid_of_domain(MatchDomain, Attr) end, El#xmlel.attrs);
is_item_of_domain(_MatchDomain, {xmlcdata, _}) ->
    false.

is_jid_of_domain(MatchDomain, {<<"jid">>, JIDString}) ->
    case jlib:string_to_jid(JIDString) of
	JID when JID#jid.lserver == MatchDomain -> true;
	_ -> false
    end;
is_jid_of_domain(_, _) ->
    false.

process_item_attrs_managed(Item, Attrs, true) ->
    process_item_attrs_ws(Item, Attrs);
process_item_attrs_managed(Item, _Attrs, false) ->
    process_item_attrs(Item, _Attrs).

send_itemset_to_managers(_From, _Item, true) ->
    ok;
send_itemset_to_managers(From, Item, false) ->
    {_, UserHost} = Item#roster.us,
    {_ContactUser, ContactHost, _ContactResource} = Item#roster.jid,
    %% Check if the component is an allowed manager
    IsManager = is_domain_managed(ContactHost, UserHost),
    case IsManager of
	true -> push_item(<<"">>, ContactHost, <<"">>, From, Item);
	false -> ok
    end.

is_managed_from_id(<<"roster-remotely-managed">>) ->
    true;
is_managed_from_id(_Id) ->
    false.

roster_schema() ->
    {record_info(fields, roster), #roster{}}.

roster_version_schema() ->
    {record_info(fields, roster_version), #roster_version{}}.

export(_Server) ->
    [{roster,
      fun(Host, #roster{usj = {LUser, LServer, LJID}} = R)
            when LServer == Host ->
              Username = ejabberd_odbc:escape(LUser),
              SJID = ejabberd_odbc:escape(jlib:jid_to_string(LJID)),
              ItemVals = record_to_string(R),
              ItemGroups = groups_to_string(R),
              odbc_queries:update_roster_sql(Username, SJID,
                                             ItemVals, ItemGroups);
        (_Host, _R) ->
              []
      end},
     {roster_version,
      fun(Host, #roster_version{us = {LUser, LServer}, version = Ver})
            when LServer == Host ->
              Username = ejabberd_odbc:escape(LUser),
              SVer = ejabberd_odbc:escape(Ver),
              [[<<"delete from roster_version where username='">>,
                Username, <<"';">>],
               [<<"insert into roster_version(username, version) values('">>,
                Username, <<"', '">>, SVer, <<"');">>]];
         (_Host, _R) ->
              []
      end}].

import_info() ->
    [{<<"roster_version">>, 2},
     {<<"rostergroups">>, 3},
     {<<"rosterusers">>, 10}].

import_start(_LServer, odbc) ->
    ok;
import_start(LServer, DBType) ->
    ets:new(rostergroups_tmp, [private, named_table, bag]),
    init_db(DBType, LServer),
    ok.

import_stop(_LServer, odbc) ->
    ok;
import_stop(_LServer, _DBType) ->
    ets:delete(rostergroups_tmp),
    ok.

import(LServer, {odbc, _}, DBType, <<"rostergroups">>, [LUser, SJID, Group])
  when DBType == riak; DBType == mnesia; DBType == p1db ->
    LJID = jlib:jid_tolower(jlib:string_to_jid(SJID)),
    ets:insert(rostergroups_tmp, {{LUser, LServer, LJID}, Group}),
    ok;
import(LServer, {odbc, _}, DBType, <<"rosterusers">>, Row) ->
    I = raw_to_record(LServer, lists:sublist(Row, 9)),
    {LUser, _LServer, LJID} = I#roster.usj,
    Groups = [G || {_, G} <- ets:lookup(rostergroups_tmp, I#roster.usj)],
    RosterItem = I#roster{groups = Groups},
    case DBType of
        mnesia ->
            mnesia:dirty_write(RosterItem);
        riak ->
            ejabberd_riak:put(RosterItem, roster_schema(),
                              [{'2i', [{<<"us">>, {LUser, LServer}}]}]);
        p1db ->
            USJKey = usj2key(LUser, LServer, LJID),
            Val = item_to_p1db(RosterItem),
            p1db:async_insert(roster, USJKey, Val);
        odbc ->
            ok
    end;
import(LServer, {odbc, _}, mnesia, <<"roster_version">>, [LUser, Ver]) ->
    RV = #roster_version{us = {LUser, LServer}, version = Ver},
    mnesia:dirty_write(RV);
import(LServer, {odbc, _}, riak, <<"roster_version">>, [LUser, Ver]) ->
    RV = #roster_version{us = {LUser, LServer}, version = Ver},
    ejabberd_riak:put(RV, roster_version_schema());
import(LServer, {odbc, _}, p1db, <<"roster_version">>, [LUser, Ver]) ->
    USKey = us2key(LUser, LServer),
    p1db:async_insert(roster_version, USKey, Ver);
import(_LServer, {odbc, _}, odbc, _Tab, _) ->
    ok.

%% For benchmarks
make_roster_range(I, Total) ->
    lists:foldl(
      fun(K, Range) ->
              Next = if I+K > Total -> I+K-Total;
                        true -> I+K
                     end,
              Prev = if I-K =< 0 -> Total+I-K;
                        true -> I-K
                     end,
              [Next, Prev | Range]
      end, [], lists:seq(1, 9)).

-spec create_rosters(binary(), binary(), pos_integer(), gen_mod:db_type()) -> any().

create_rosters(UserPattern, Server, Total, DBType) ->
    lists:foreach(
      fun(I) ->
              LUser = jlib:nodeprep(
                        iolist_to_binary([UserPattern, integer_to_list(I)])),
              LServer = jlib:nameprep(Server),
              Range = make_roster_range(I, Total),
              lists:foreach(
                fun(R) ->
                        Contact = jlib:nodeprep(
                                    iolist_to_binary(
                                      [UserPattern, integer_to_list(R)])),
                        LJID = {Contact, LServer, <<"">>},
                        RItem = #roster{subscription = both,
                                        us = {LUser, LServer},
                                        usj = {LUser, LServer, LJID},
                                        jid = LJID},
                        case DBType of
                            riak ->
                                ejabberd_riak:put(
                                  RItem, roster_schema(),
                                  [{'2i', [{<<"us">>, {LUser, LServer}}]}]);
                            p1db ->
                                USJKey = usj2key(LUser, LServer, LJID),
                                Val = item_to_p1db(RItem),
                                VClock = p1db:new_vclock(node()),
                                p1db:async_insert(roster, USJKey, Val, VClock);
                            mnesia ->
                                mnesia:dirty_write(RItem);
                            odbc ->
                                erlang:error(odbc_not_supported)
                        end
                end, Range)
      end, lists:seq(1, Total)).
