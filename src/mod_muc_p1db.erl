%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 17 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_muc_p1db).

-behaviour(mod_muc).
-behaviour(mod_muc_room).

%% API
-export([init/2, import/3, store_room/5, restore_room/3, forget_room/3,
	 can_use_nick/4, get_rooms/2, get_nick/3, set_nick/4, get_subscribed_rooms/3]).
-export([set_affiliation/6, set_affiliations/4, get_affiliation/5,
	 get_affiliations/3, search_affiliation/4]).
-export([enc_key/1, dec_key/1, enc_aff/2, dec_aff/2, rh_prefix/2,
	 key2us/2, rhus2key/4, encode_opts/2, decode_opts/2]).

-include("jlib.hrl").
-include("mod_muc.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(muc_config,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, room]},
                               {vals, mod_muc_room:config_fields()},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:encode_opts/2},
                               {dec_val, fun ?MODULE:decode_opts/2}]}]),
    p1db:open_table(muc_affiliations,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, room, server, user]},
                               {vals, [affiliation, reason]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_aff/2},
                               {dec_val, fun ?MODULE:dec_aff/2}]}]),
    p1db:open_table(muc_nick,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, nick]},
                               {vals, [jid]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]),
    p1db:open_table(muc_user,
		    [{group, Group}, {nosync, true},
                     {schema, [{keys, [service, server, user]},
                               {vals, [nick]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1}]}]).

store_room(_LServer, Host, Name, Config, _) ->
    Opts = proplists:delete(affiliations, Config),
    RoomKey = rh2key(Name, Host),
    CfgVal = term_to_binary(Opts),
    case p1db:insert(muc_config, RoomKey, CfgVal) of
        ok ->
            {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end.

restore_room(_LServer, Host, Name) ->
    RoomKey = rh2key(Name, Host),
    case p1db:get(muc_config, RoomKey) of
        {ok, CfgVal, _VClock} ->
            Config = binary_to_term(CfgVal),
            [{affiliations, []}|Config];
        {error, _} ->
            error
    end.

forget_room(_LServer, Host, Name) ->
    RoomKey = rh2key(Name, Host),
    DelRes = p1db:delete(muc_config, RoomKey),
    if DelRes == ok; DelRes == {error, notfound} ->
            RHPrefix = rh_prefix(Name, Host),
            case p1db:get_by_prefix(muc_affiliations, RHPrefix) of
                {ok, L} ->
                    lists:foreach(
                      fun({Key, _, _}) ->
                              p1db:async_delete(muc_affiliations, Key)
                      end, L);
                {error, _} = Err ->
                    {aborted, Err}
            end;
       true ->
            {aborted, DelRes}
    end.

can_use_nick(_LServer, Host, JID, Nick) ->
    {LUser, LServer, _} = jid:tolower(JID),
    NHKey = nh2key(Nick, Host),
    case p1db:get(muc_nick, NHKey) of
        {ok, SJID, _VClock} ->
            case jid:from_string(SJID) of
                #jid{luser = LUser, lserver = LServer} ->
                    true;
                #jid{} ->
                    false;
                error ->
                    true
            end;
        {error, _} ->
            true
    end.

get_rooms(_LServer, Host) ->
    HPrefix = host_prefix(Host),
    case p1db:get_by_prefix(muc_config, HPrefix) of
        {ok, CfgList} ->
            lists:map(
              fun({Key, CfgVal, _VClock}) ->
                      Room = key2room(HPrefix, Key),
                      Cfg = binary_to_term(CfgVal),
                      Opts = [{affiliations, []}|Cfg],
                      #muc_room{name_host = {Room, Host},
                                opts = Opts}
              end, CfgList);
        {error, _} ->
            []
    end.

get_nick(_LServer, Host, From) ->
    {LUser, LServer, _} = jid:tolower(From),
    USHKey = ush2key(LUser, LServer, Host),
    case p1db:get(muc_user, USHKey) of
        {ok, Nick, _VClock} -> Nick;
        {error, _} -> error
    end.

set_nick(_LServer, Host, From, <<"">>) ->
    {LUser, LServer, _} = jid:tolower(From),
    USHKey = ush2key(LUser, LServer, Host),
    case p1db:get(muc_user, USHKey) of
        {ok, Nick, _VClock} ->
            NHKey = nh2key(Nick, Host),
            case p1db:delete(muc_nick, NHKey) of
                ok ->
                    case p1db:delete(muc_user, USHKey) of
                        ok -> {atomic, ok};
                        {error, notfound} -> {atomic, ok};
                        {error, _} = Err -> {aborted, Err}
                    end;
                {error, notfound} ->
                    {atomic, ok};
                {error, _} = Err ->
                    {aborted, Err}
            end;
	{error, notfound} ->
	    {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end;
set_nick(_LServer, Host, From, Nick) ->
    {LUser, LServer, _} = jid:tolower(From),
    NHKey = nh2key(Nick, Host),
    case can_use_nick(LServer, Host, From, Nick) of
        true ->
            case set_nick(LServer, Host, From, <<"">>) of
                {atomic, ok} ->
                    SJID = jid:to_string({LUser, LServer, <<"">>}),
                    case p1db:insert(muc_nick, NHKey, SJID) of
                        ok ->
                            USHKey = ush2key(LUser, LServer, Host),
                            case p1db:insert(muc_user, USHKey, Nick) of
                                ok ->
                                    {atomic, ok};
                                {error, _} = Err ->
                                    {aborted, Err}
                            end;
                        {error, _} = Err ->
                            {aborted, Err}
                    end;
                Aborted ->
                    Aborted
            end;
        false ->
            {atomic, false}
    end.

set_affiliation(_ServerHost, Room, Host, JID, Affiliation, Reason) ->
    {LUser, LServer, _} = jid:tolower(JID),
    AffKey = rhus2key(Room, Host, LUser, LServer),
    case Affiliation of
        none ->
            p1db:delete(muc_affiliations, AffKey);
        _ ->
            Val = term_to_binary([{affiliation, Affiliation},
                                  {reason, Reason}]),
            p1db:insert(muc_affiliations, AffKey, Val)
    end.

set_affiliations(_ServerHost, Room, Host, Affiliations) ->
    case clear_affiliations(Room, Host) of
        ok ->
	    try
		lists:foreach(
		  fun({_JID, {none, _Reason}}) ->
			  ok;
		     ({JID, {Affiliation, Reason}}) ->
			  {LUser, LServer, _} = jid:tolower(JID),
			  AffKey = rhus2key(Room, Host, LUser, LServer),
			  Val = term_to_binary([{affiliation, Affiliation},
						{reason, Reason}]),
			  ok = p1db:insert(muc_affiliations, AffKey, Val)
		  end, dict:to_list(Affiliations))
	    catch _:{badmatch, {error, _} = Err} ->
		    Err
	    end;
        {error, _} = Err ->
	    Err
    end.

get_affiliation(_ServerHost, Room, Host, LUser, LServer) ->
    AffKey = rhus2key(Room, Host, LUser, LServer),
    case p1db:get(muc_affiliations, AffKey) of
        {ok, Val, _VClock} ->
            PropList = binary_to_term(Val),
            {ok, proplists:get_value(affiliation, PropList, none)};
	{error, notfound} ->
	    ServAffKey = rhus2key(Room, Host, <<>>, LServer),
	    case p1db:get(muc_affiliations, ServAffKey) of
		{ok, Val, _VClock} ->
		    PropList = binary_to_term(Val),
		    {ok, proplists:get_value(affiliation, PropList, none)};
		{error, notfound} ->
		    {ok, none};
		{error, _} = Err ->
		    Err
	    end;
        {error, _} = Err ->
            Err
    end.

get_affiliations(_ServerHost, Room, Host) ->
    RHPrefix = rh_prefix(Room, Host),
    case p1db:get_by_prefix(muc_affiliations, RHPrefix) of
        {ok, L} ->
	    {ok,
	     dict:from_list(
	       lists:map(
		 fun({Key, Val, _VClock}) ->
			 PropList = binary_to_term(Val),
			 Reason = proplists:get_value(reason, PropList, <<>>),
			 Affiliation = proplists:get_value(
					 affiliation, PropList, none),
			 {LUser, LServer} = key2us(RHPrefix, Key),
			 {{LUser, LServer, <<"">>}, {Affiliation, Reason}}
		 end, L))};
        {error, _} = Err ->
	    Err
    end.

search_affiliation(_ServerHost, Room, Host, Affiliation) ->
    RHPrefix = rh_prefix(Room, Host),
    case p1db:get_by_prefix(muc_affiliations, RHPrefix) of
        {ok, L} ->
	    {ok,
	     lists:flatmap(
	       fun({Key, Val, _VClock}) ->
		       PropList = binary_to_term(Val),
		       Reason = proplists:get_value(reason, PropList, <<>>),
		       case proplists:get_value(affiliation, PropList, none) of
			   Affiliation ->
			       {LUser, LServer} = key2us(RHPrefix, Key),
			       [{{LUser, LServer, <<"">>},
				 {Affiliation, Reason}}];
			   _ ->
			       []
		       end
	       end, L)};
        {error, _} = Err ->
	    Err
    end.

import(_LServer, <<"muc_room">>,
       [Room, Host, SOpts, _TimeStamp]) ->
    Opts = mod_muc:opts_to_binary(ejabberd_sql:decode_term(SOpts)),
    {Affiliations, Config} = lists:partition(
                               fun({affiliations, _}) -> true;
                                  (_) -> false
                               end, Opts),
    RHKey = rh2key(Room, Host),
    p1db:async_insert(muc_config, RHKey, term_to_binary(Config)),
    lists:foreach(
      fun({affiliations, Affs}) ->
              lists:foreach(
                fun({JID, Aff}) ->
                        {Affiliation, Reason} = case Aff of
                                                    {A, R} -> {A, R};
                                                    A -> {A, <<"">>}
                                                end,
                        {LUser, LServer, _} = jid:tolower(JID),
                        RHUSKey = rhus2key(Room, Host, LUser, LServer),
                        Val = term_to_binary([{affiliation, Affiliation},
                                              {reason, Reason}]),
                        p1db:async_insert(muc_affiliations, RHUSKey, Val)
                end, Affs)
      end, Affiliations);
import(_LServer, <<"muc_registered">>,
       [J, Host, Nick, _TimeStamp]) ->
    #jid{user = U, server = S} = jid:from_string(J),
    NHKey = nh2key(Nick, Host),
    USHKey = ush2key(U, S, Host),
    SJID = jid:to_string({U, S, <<"">>}),
    p1db:async_insert(muc_nick, NHKey, SJID),
    p1db:async_insert(muc_user, USHKey, Nick).

%%%===================================================================
%%% Internal functions
%%%===================================================================
clear_affiliations(Room, Host) ->
    RHPrefix = rh_prefix(Room, Host),
    case p1db:get_by_prefix(muc_affiliations, RHPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _, _}) ->
                      p1db:async_delete(muc_affiliations, Key)
              end, L);
        {error, _} = Err ->
            Err
    end.

rh2key(Room, Host) ->
    <<Host/binary, 0, Room/binary>>.

nh2key(Nick, Host) ->
    <<Host/binary, 0, Nick/binary>>.

ush2key(LUser, LServer, Host) ->
    <<Host/binary, 0, LServer/binary, 0, LUser/binary>>.

host_prefix(Host) ->
    <<Host/binary, 0>>.

rh_prefix(Room, Host) ->
    <<Host/binary, 0, Room/binary, 0>>.

rhus2key(Room, Host, LUser, LServer) ->
    <<Host/binary, 0, Room/binary, 0, LServer/binary, 0, LUser/binary>>.

key2us(RHPrefix, Key) ->
    Size = size(RHPrefix),
    <<_:Size/binary, SKey/binary>> = Key,
    SLen = str:chr(SKey, 0) - 1,
    <<Server:SLen/binary, 0, User/binary>> = SKey,
    {User, Server}.

key2room(HPrefix, Key) ->
    Size = size(HPrefix),
    <<_:Size/binary, Room/binary>> = Key,
    Room.

enc_key([Host]) ->
    <<Host/binary>>;
enc_key([Host, Val]) ->
    <<Host/binary, 0, Val/binary>>;
enc_key([Host, Server, User]) ->
    <<Host/binary, 0, Server/binary, 0, User/binary>>;
enc_key([Host, Room, Server, User]) ->
    <<Host/binary, 0, Room/binary, 0, Server/binary, 0, User/binary>>.

dec_key(Key) ->
    binary:split(Key, <<0>>, [global]).

enc_aff(_, [Affiliation, Reason]) ->
    term_to_binary([{affiliation, jlib:binary_to_atom(Affiliation)},
                    {reason, Reason}]).

dec_aff(_, Bin) ->
    PropList = binary_to_term(Bin),
    Affiliation = proplists:get_value(affiliation, PropList, none),
    Reason = proplists:get_value(reason, PropList, <<>>),
    [jlib:atom_to_binary(Affiliation), Reason].

decode_opts(_, Bin) ->
    CompactOpts = binary_to_term(Bin),
    Opts = mod_muc_room:expand_opts(CompactOpts),
    lists:map(
      fun({_Key, Val}) ->
              if is_atom(Val) ->
                      jlib:atom_to_binary(Val);
                 is_integer(Val) ->
                      Val;
                 is_binary(Val) ->
                      Val;
                 true ->
                      jlib:term_to_expr(Val)
              end
      end, Opts).

encode_opts(_, Vals) ->
    Opts = lists:map(
             fun({Key, BinVal}) ->
                     Val = case Key of
                               subject -> BinVal;
                               subject_author -> BinVal;
                               title -> BinVal;
                               description -> BinVal;
                               password -> BinVal;
                               voice_request_min_interval ->
                                   BinVal;
                               max_users when BinVal == <<"none">> ->
                                   none;
                               max_users ->
                                   BinVal;
			       vcard ->
				   BinVal;
			       hibernate_time ->
				   BinVal;
                               captcha_whitelist ->
                                   jlib:expr_to_term(BinVal);
                               _ ->
                                   jlib:binary_to_atom(BinVal)
                           end,
                     {Key, Val}
             end, lists:zip(mod_muc_room:config_fields(), Vals)),
    term_to_binary(Opts).

get_subscribed_rooms(_, _, _) ->
    not_implemented.
