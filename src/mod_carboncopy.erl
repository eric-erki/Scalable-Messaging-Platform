%%%----------------------------------------------------------------------
%%% File    : mod_carboncopy.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : Message Carbons XEP-0280 0.8
%%% Created : 5 May 2008 by Mickael Remond <mremond@process-one.net>
%%% Usage   : Add the following line in modules section of ejabberd.yml:
%%%              {mod_carboncopy, []}
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
-module (mod_carboncopy).
-author ('ecestari@process-one.net').

-behavior(gen_mod).

%% API:
-export([start/2,
         stop/1]).

%% Hooks:
-export([user_send_packet/4,
	 user_receive_packet/5,
         iq_handler2/3,
         iq_handler1/3,
         remove_connection/4,
	 enc_key/1,
	 dec_key/1,
         is_carbon_copy/1]).

-define(NS_CC_2, <<"urn:xmpp:carbons:2">>).
-define(NS_CC_1, <<"urn:xmpp:carbons:1">>).
-define(NS_FORWARD, <<"urn:xmpp:forward:0">>).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").
-define(PROCNAME, ?MODULE).

-type matchspec_atom() :: '_' | '$1' | '$2' | '$3'.
-record(carboncopy,{us :: {binary(), binary()} | matchspec_atom(),
		    resource :: binary() | matchspec_atom(),
		    version :: binary() | matchspec_atom()}).

is_carbon_copy(Packet) ->
	case xml:get_subtag(Packet, <<"sent">>) of
		#xmlel{name= <<"sent">>, attrs = AAttrs}  ->
	    	case xml:get_attr_s(<<"xmlns">>, AAttrs) of
				?NS_CC_2 -> true;
				?NS_CC_1 -> true;
				_ -> false
			end;
		_ -> false
	end.

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts,fun gen_iq_handler:check_type/1, one_queue),
    mod_disco:register_feature(Host, ?NS_CC_1),
    mod_disco:register_feature(Host, ?NS_CC_2),
    init_db(gen_mod:db_type(Opts), Host),
    ejabberd_hooks:add(unset_presence_hook,Host, ?MODULE, remove_connection, 10),
    %% why priority 89: to define clearly that we must run BEFORE mod_logdb hook (90)
    ejabberd_hooks:add(user_send_packet,Host, ?MODULE, user_send_packet, 89),
    ejabberd_hooks:add(user_receive_packet,Host, ?MODULE, user_receive_packet, 89),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_CC_2, ?MODULE, iq_handler2, IQDisc),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?NS_CC_1, ?MODULE, iq_handler1, IQDisc).

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_CC_1),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?NS_CC_2),
    mod_disco:unregister_feature(Host, ?NS_CC_2),
    mod_disco:unregister_feature(Host, ?NS_CC_1),
    %% why priority 89: to define clearly that we must run BEFORE mod_logdb hook (90)
    ejabberd_hooks:delete(user_send_packet,Host, ?MODULE, user_send_packet, 89),
    ejabberd_hooks:delete(user_receive_packet,Host, ?MODULE, user_receive_packet, 89),
    ejabberd_hooks:delete(unset_presence_hook,Host, ?MODULE, remove_connection, 10).

iq_handler2(From, To, IQ) ->
	iq_handler(From, To, IQ, ?NS_CC_2).
iq_handler1(From, To, IQ) ->
	iq_handler(From, To, IQ, ?NS_CC_1).

iq_handler(From, _To,  #iq{type=set, sub_el = #xmlel{name = Operation, children = []}} = IQ, CC)->
    ?INFO_MSG("carbons IQ received: ~p", [IQ]),
    {U, S, R} = jlib:jid_tolower(From),
    Result = case Operation of
        <<"enable">>->
	    ?INFO_MSG("carbons enabled for user ~s@~s/~s", [U,S,R]),
            enable(S,U,R,CC);
        <<"disable">>->
	    ?INFO_MSG("carbons disabled for user ~s@~s/~s", [U,S,R]),
            disable(S, U, R);
        _ ->
            {error, bad_request}
    end,
    case Result of
        ok ->
	    ?INFO_MSG("carbons IQ result: ok", []),
            IQ#iq{type=result, sub_el=[]};
	{error,_Error} ->
	    ?INFO_MSG("Error enabling / disabling carbons: ~p", [Result]),
            IQ#iq{type=error,sub_el = [?ERR_BAD_REQUEST]}
    end;

iq_handler(_From, _To, IQ, _CC)->
    IQ#iq{type=error, sub_el = [?ERR_NOT_ALLOWED]}.

user_send_packet(Packet, _C2SState, From, _To) ->
    check_and_forward(From, Packet, sent),
    Packet.

%% Only make carbon copies if the original destination was not a bare jid.
%% If the original destination was a bare jid, the message is going to be delivered to all
%% connected resources anyway. Avoid duplicate delivery. "XEP-0280 : 3.5 Receiving Messages"
user_receive_packet(Packet, _C2SState, JID, _From, #jid{resource=Resource} = _To) when Resource /= <<>> ->
    check_and_forward(JID, Packet, received),
    Packet;
user_receive_packet(Packet, _C2SState, _JID, _From, _To) ->
    Packet.

% verifier si le trafic est local
% Modified from original version:
%    - registered to the user_send_packet hook, to be called only once even for multicast
%    - do not support "private" message mode, and do not modify the original packet in any way
%    - we also replicate "read" notifications
check_and_forward(JID, #xmlel{name = <<"message">>, attrs = Attrs} = Packet, Direction)->
    case xml:get_attr_s(<<"type">>, Attrs) of
      <<"chat">> ->
	case xml:get_subtag(Packet, <<"private">>) of
	    false ->
		case xml:get_subtag(Packet,<<"received">>) of
		    false ->
                        case xml:get_path_s(Packet, [{elem, <<"received">>},
                                                     {elem, <<"forwarded">>}]) of
                            <<"">> ->
                                case xml:get_path_s(Packet, [{elem, <<"sent">>},
                                                             {elem, <<"forwarded">>}]) of
                                    <<"">> ->
                                        send_copies(JID, Packet, Direction);
                                    _ ->
                                        stop
                                end;
                            _ ->
                                stop
                        end;
		    _ ->
			%% stop the hook chain, we don't want mod_logdb to register this message (duplicate)
			stop
		end;
	    _ ->
		ok
	end;
    _ ->
	ok
    end;

check_and_forward(_JID, _Packet, _)-> ok.

remove_connection(User, Server, Resource, _Status)->
    disable(Server, User, Resource),
    ok.


%%% Internal
%% Direction = received | sent <received xmlns='urn:xmpp:carbons:1'/>
send_copies(JID, Packet, Direction)->
    {U, S, R} = jlib:jid_tolower(JID),

    %% list of JIDs that should receive a carbon copy of this message (excluding the
    %% receiver of the original message
    TargetJIDs = [ {jlib:make_jid({U, S, CCRes}), CC_Version} || {CCRes, CC_Version} <- list(U, S), CCRes /= R ],
    %TargetJIDs = lists:delete(JID, [ jlib:make_jid({U, S, CCRes}) || CCRes <- list(U, S) ]),


    lists:map(fun({Dest,Version}) ->
		    {_, _, Resource} = jlib:jid_tolower(Dest),
		    ?DEBUG("Sending:  ~p =/= ~p", [R, Resource]),
		    Sender = jlib:make_jid({U, S, <<>>}),
		    %{xmlelement, N, A, C} = Packet,
		    New = build_forward_packet(JID, Packet, Sender, Dest, Direction, Version),
		    ejabberd_router:route(Sender, Dest, New)
	      end, TargetJIDs),
    ok.

build_forward_packet(JID, Packet, Sender, Dest, Direction, ?NS_CC_2) ->
    #xmlel{name = <<"message">>,
	   attrs = [{<<"xmlns">>, <<"jabber:client">>},
		    {<<"type">>, <<"chat">>},
		    {<<"from">>, jlib:jid_to_string(Sender)},
		    {<<"to">>, jlib:jid_to_string(Dest)}],
	   children = [
		#xmlel{name = list_to_binary(atom_to_list(Direction)),
		       attrs = [{<<"xmlns">>, ?NS_CC_2}],
		       children = [
			#xmlel{name = <<"forwarded">>,
			       attrs = [{<<"xmlns">>, ?NS_FORWARD}],
			       children = [
				complete_packet(JID, Packet, Direction)]}
		]}
	   ]};
build_forward_packet(JID, Packet, Sender, Dest, Direction, ?NS_CC_1) ->
    #xmlel{name = <<"message">>,
	   attrs = [{<<"xmlns">>, <<"jabber:client">>},
		    {<<"type">>, <<"chat">>},
		    {<<"from">>, jlib:jid_to_string(Sender)},
		    {<<"to">>, jlib:jid_to_string(Dest)}],
	   children = [
		#xmlel{name = list_to_binary(atom_to_list(Direction)),
			attrs = [{<<"xmlns">>, ?NS_CC_1}]},
		#xmlel{name = <<"forwarded">>,
		       attrs = [{<<"xmlns">>, ?NS_FORWARD}],
		       children = [complete_packet(JID, Packet, Direction)]}
		]}.



complete_packet(From, #xmlel{name = <<"message">>, attrs = OrigAttrs} = Packet, sent) ->
    %% if this is a packet sent by user on this host, then Packet doesn't
    %% include the 'from' attribute. We must add it.
    Attrs = lists:keystore(<<"xmlns">>, 1, OrigAttrs, {<<"xmlns">>, <<"jabber:client">>}),
    case proplists:get_value(<<"from">>, Attrs) of
	undefined ->
		Packet#xmlel{attrs = [{<<"from">>, jlib:jid_to_string(From)}|Attrs]};
	_ ->
		Packet#xmlel{attrs = Attrs}
    end;
complete_packet(_From, #xmlel{name = <<"message">>, attrs=OrigAttrs} = Packet, received) ->
    Attrs = lists:keystore(<<"xmlns">>, 1, OrigAttrs, {<<"xmlns">>, <<"jabber:client">>}),
    Packet#xmlel{attrs = Attrs}.

enable(Host, U, R, CC)->
    enable(gen_mod:db_type(Host, ?MODULE), Host, U, R, CC).

enable(mnesia, Host, U, R, CC) ->
    ?DEBUG("enabling for ~p", [U]),
     try mnesia:dirty_write(#carboncopy{us = {U, Host}, resource=R, version = CC}) of
	ok -> ok
     catch _:Error -> {error, Error}
     end;
enable(p1db, Host, U, R, CC) ->
    p1db:insert(carboncopy, enc_key(Host, U, R), CC);
enable(odbc, Host, U, R, CC) ->
    case ejabberd_odbc:sql_transaction(Host,
                                       [[<<"DELETE FROM carboncopy WHERE Server='">>,
                                         ejabberd_odbc:escape(Host), <<"' AND User='">>, ejabberd_odbc:escape(U),
                                         <<"' AND Resource='">>, ejabberd_odbc:escape(R), <<"'">>],
                                        [<<"INSERT INTO carboncopy (Server,User,Resource,Version) VALUES ('">>,
                                         ejabberd_odbc:escape(Host), <<"', '">>, ejabberd_odbc:escape(U), <<"', '">>,
                                         ejabberd_odbc:escape(R), <<"', '">>, ejabberd_odbc:escape(CC), <<"')">>]]) of
        {atomic, _} ->
            ok;
        _ ->
                {error, <<"Transaction aborted">>}
    end.


disable(Host, U, R) ->
    disable(gen_mod:db_type(Host, ?MODULE), Host, U, R).

disable(mnesia, Host, U, R) ->
    ?DEBUG("disabling for ~p", [U]),
    ToDelete = mnesia:dirty_match_object(carboncopy, #carboncopy{us = {U, Host}, resource = R, version = '_'}),
    try lists:foreach(fun mnesia:dirty_delete_object/1, ToDelete) of
	ok -> ok
    catch _:Error -> {error, Error}
    end;
disable(p1db, Host, U, R) ->
    p1db:delete(carboncopy, enc_key(Host, U, R));
disable(odbc, Host, U, R) ->
    case ejabberd_odbc:sql_query(Host, [<<"DELETE FROM carboncopy WHERE Server='">>,
                                        ejabberd_odbc:escape(Host), <<"' AND User='">>, ejabberd_odbc:escape(U),
                                        <<"' AND Resource='">>, ejabberd_odbc:escape(R), <<"'">>]) of
        {updated, _} ->
            ok;
        {error, Err} ->
            {error, Err}
    end.

%% list {resource, cc_version} with carbons enabled for given user and host
list(User, Server) ->
    list(gen_mod:db_type(Server, ?MODULE), User, Server).

list(mnesia, User, Server) ->
    mnesia:dirty_select(carboncopy, [{#carboncopy{us = {User, Server}, resource = '$2', version = '$3'}, [], [{{'$2','$3'}}]}]);
list(p1db, User, Server) ->
    case p1db:get_by_prefix(carboncopy, enc_key(Server, User)) of
        {ok, L} ->
            [{dec_key(Key2, 3), Version} || {Key2, Version, _VClock} <- L];
        {error, _} ->
            []
    end;
list(odbc, User, Server) ->
    case ejabberd_odbc:sql_query(Server, [<<"SELECT Resource, Version FROM carboncopy WHERE Server='">>,
                                        ejabberd_odbc:escape(Server), <<"' AND User='">>,
                                        ejabberd_odbc:escape(User), <<"'">>]) of
        {selected, _, Values} ->
            [{R, V} || [R, V] <- Values];
        _ ->
            []
    end.

init_db(mnesia, _Host) ->
    Fields = record_info(fields, carboncopy),
    try mnesia:table_info(carboncopy, attributes) of
	Fields -> ok;
	_ -> mnesia:delete_table(carboncopy)  %% recreate..
    catch _:_Error -> ok  %%probably table don't exist
    end,
    mnesia:create_table(carboncopy,
	[{ram_copies, [node()]},
	 {attributes, record_info(fields, carboncopy)},
	 {type, bag}]),
    mnesia:add_table_copy(carboncopy, node(), ram_copies);

init_db(p1db, Host) ->
    Group = gen_mod:get_module_opt(
              Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
              ejabberd_config:get_option(
                {p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(carboncopy,
                    [{group, Group},
                     {schema, [{keys, [server, user, resource]},
                               {vals, [version]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]);
init_db(odbc, _Host) ->
    ok.

enc_key(Server, User, Resource) ->
    <<Server/binary, 0, User/binary, 0, Resource/binary>>.
enc_key(Server, User) ->
    <<Server/binary, 0, User/binary, 0>>.
enc_key(Server) ->
    <<Server/binary, 0>>.

dec_key(Key) ->
    binary:split(Key, <<0>>, [global]).
dec_key(Key, Part) ->
    lists:nth(Part, dec_key(Key)).
