%%%----------------------------------------------------------------------
%%% File    : mod_carboncopy.erl
%%% Author  : Eric Cestari <ecestari@process-one.net>
%%% Purpose : Download blacklists from ProcessOne
%%% Created : 5 May 2008 by Mickael Remond <mremond@process-one.net>
%%% Usage   : Add the following line in modules section of ejabberd.cfg:
%%%              {mod_ip_blacklist, []}
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
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
-compile(export_all).
%% API:
-export([start/2,
         stop/1]).

%% Hooks:
-export([user_send_packet/4,
	 user_receive_packet/5,
         iq_handler/3,
         remove_connection/4,
         is_carbon_copy/1]).

-define(CC_NS, "urn:xmpp:carbons:1").
-define(FORWARD_NS, "urn:xmpp:forward:0").

-include("ejabberd.hrl").
-include("jlib.hrl").
-define(PROCNAME, ?MODULE).
-define(TABLE, carboncopy).
-record(carboncopy,{host, user, resource}).

is_carbon_copy(Packet) ->
	case xml:get_subtag(Packet, "sent") of
		{xmlelement, "sent", AAttrs, _} ->
	    	case xml:get_attr_s("xmlns", AAttrs) of
				?CC_NS -> true;
				_ -> false
			end;
		_ -> false
	end.

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, one_queue),
    mod_disco:register_feature(Host, ?CC_NS),
    mnesia:create_table(?TABLE,
            [{attributes, record_info(fields, ?TABLE)}, {type, bag}]),
    ejabberd_hooks:add(unset_presence_hook,Host, ?MODULE, remove_connection, 10),
    %% why priority 89: to define clearly that we must run BEFORE mod_logdb hook (90)
    ejabberd_hooks:add(user_send_packet,Host, ?MODULE, user_send_packet, 89),
    ejabberd_hooks:add(user_receive_packet,Host, ?MODULE, user_receive_packet, 89),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host, ?CC_NS, ?MODULE, iq_handler, IQDisc).

stop(Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host, ?CC_NS),
    mod_disco:unregister_feature(Host, ?CC_NS),
    %% why priority 89: to define clearly that we must run BEFORE mod_logdb hook (90)
    ejabberd_hooks:delete(user_send_packet,Host, ?MODULE, user_send_packet, 89),
    ejabberd_hooks:delete(user_receive_packet,Host, ?MODULE, user_receive_packet, 89),
    ejabberd_hooks:delete(unset_presence_hook,Host, ?MODULE, remove_connection, 10).

iq_handler(From, _To,  #iq{type=set, sub_el = {xmlelement, Operation, _Attrs, []}} = IQ)->
    ?INFO_MSG("carbons IQ received: ~p", [IQ]),
    {U, S, R} = jlib:jid_tolower(From),
    Result = case Operation of
        "enable"->
	    ?INFO_MSG("carbons enabled for user ~s@~s/~s", [U,S,R]),
            enable(S,U,R);
        "disable"->
	    ?INFO_MSG("carbons disabled for user ~s@~s/~s", [U,S,R]),
            disable(S, U, R)
    end,
    case Result of 
        {atomic, ok} ->
	    ?INFO_MSG("carbons IQ result: ok", []),
            IQ#iq{type=result, sub_el=[]};
        {error,_} ->
	    ?INFO_MSG("Error enabling / disabling carbons: ~p", [Result]),
            IQ#iq{type=error,sub_el = [?ERR_BAD_REQUEST]}
    end;

iq_handler(_From, _To, IQ)->
    IQ#iq{type=error, sub_el = [?ERR_NOT_ALLOWED]}.

user_send_packet(_Debug, From, _To, Packet) ->
    check_and_forward(From, Packet, sent).

%% Only make carbon copies if the original destination was not a bare jid. 
%% If the original destination was a bare jid, the message is going to be delivered to all
%% connected resources anyway. Avoid duplicate delivery. "XEP-0280 : 3.5 Receiving Messages"
user_receive_packet(_Debug, JID, _From, #jid{resource=Resource} = _To, Packet) when Resource /= "" ->
    check_and_forward(JID, Packet, received);
user_receive_packet(_Debug, _JID, _From, _To, _Packet) ->
	ok.
    
% verifier si le trafic est local
% Modified from original version: 
%    - registered to the user_send_packet hook, to be called only once even for multicast
%    - do not support "private" message mode, and do not modify the original packet in any way
%    - we also replicate "read" notifications
check_and_forward(JID, {xmlelement, "message", Attrs, _} = Packet, Direction)->
    case lists:keyfind("type", 1, Attrs) of 
    {"type", "chat"} ->
	case xml:get_subtag(Packet, "private") of
	    false ->
		case xml:get_subtag(Packet,"forwarded") of
		    false ->
			send_copies(JID, Packet, Direction);
		    _ ->
			%% stop the hook chain, we don't want mod_logdb to register this message (duplicate)
			stop
		end;
	    true ->
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
    TargetJIDs = lists:delete(JID, [ jlib:make_jid({U, S, CCRes}) || CCRes <- list(U, S) ]),


    lists:map(fun(Dest) ->
		    {_, _, Resource} = jlib:jid_tolower(Dest),
		    ?DEBUG("Sending:  ~p =/= ~p", [R, Resource]),
		    Sender = jlib:make_jid({U, S, ""}),
		    %{xmlelement, N, A, C} = Packet,
		    New = {xmlelement, "message", [ {"xmlns", "jabber:client"},
						    {"type", "chat"}, 
						    {"from", jlib:jid_to_string(Sender)}, 
						    {"to", jlib:jid_to_string(Dest)}],
			   [{xmlelement, atom_to_list(Direction), [{"xmlns", ?CC_NS}],[]},
			    {xmlelement, "forwarded", [{"xmlns", ?FORWARD_NS}],
			        [complete_packet(JID, Packet, Direction)]}
			   ]},
		    ejabberd_router:route(Sender, Dest, New)
	      end, TargetJIDs),
    ok.

enable(Host, U, R)->
    ?DEBUG("enabling for ~p", [U]),
    mnesia:transaction(fun()->
        mnesia:write(#carboncopy{host=Host, user=U, resource=R})
    end).
disable(Host, U, R)->
    ?DEBUG("disabling for ~p", [U]),
    mnesia:transaction(fun()->
        mnesia:delete_object(#carboncopy{host=Host, user=U, resource=R})
    end).

complete_packet(From, {xmlelement, "message", OrigAttrs, ChildElements} = _Packet, sent) ->
    %% if this is a packet sent by user on this host, then Packet doesn't
    %% include the 'from' attribute. We must add it.
    Attrs = lists:keystore("xmlns", 1, OrigAttrs, {"xmlns", "jabber:client"}),
    case proplists:get_value("from", Attrs) of
	undefined ->
	    {xmlelement, "message", [{"from", jlib:jid_to_string(From)}|Attrs], ChildElements};
	_ ->
  	    {xmlelement, "message", Attrs, ChildElements}
    end;
complete_packet(_From, {xmlelement, "message", OrigAttrs, ChildElements} = _Packet, received) ->
    Attrs = lists:keystore("xmlns", 1, OrigAttrs, {"xmlns", "jabber:client"}),
    {xmlelement, "message", Attrs, ChildElements}.

%% list resources with carbons enabled for given user and host
list(User, Server)->
    mnesia:dirty_select(
      ?TABLE,
      [{#?TABLE{host = '$1', user = '$2', resource = '$3'},
	[{'==', '$1', Server}, {'==', '$2', User}],
	['$3']}]).

