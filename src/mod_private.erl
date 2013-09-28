%%%----------------------------------------------------------------------
%%% File    : mod_private.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Support for private storage.
%%% Created : 16 Jan 2003 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2013   ProcessOne
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

-module(mod_private).

-author('alexey@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, process_sm_iq/3, import_info/0,
	 remove_user/2, get_data/2, export/1, import/5]).

-include("ejabberd.hrl").
-include("logger.hrl").

-include("jlib.hrl").

-record(private_storage,
        {usns = {<<"">>, <<"">>, <<"">>} :: {binary(), binary(), binary() |
                                             '$1' | '_'},
         xml = #xmlel{} :: xmlel() | '_' | '$1'}).

-define(Xmlel_Query(Attrs, Children),
	#xmlel{name = <<"query">>, attrs = Attrs,
	       children = Children}).

start(Host, Opts) ->
    IQDisc = gen_mod:get_opt(iqdisc, Opts, fun gen_iq_handler:check_type/1,
                             one_queue),
    init_db(gen_mod:db_type(Opts)),
    ejabberd_hooks:add(remove_user, Host, ?MODULE,
		       remove_user, 50),
    gen_iq_handler:add_iq_handler(ejabberd_sm, Host,
				  ?NS_PRIVATE, ?MODULE, process_sm_iq, IQDisc).

init_db(mnesia) ->
    mnesia:create_table(private_storage,
                        [{disc_only_copies, [node()]},
                         {attributes,
                          record_info(fields, private_storage)}]),
    update_table();
init_db(p1db) ->
    p1db:open_table(private_storage,
                    [{mapsize, 1024*1024*100},
                     {schema, [{keys, [server, user, xmlns]},
                               {vals, [xml]},
                               {enc_key, fun enc_key/1},
                               {dec_key, fun dec_key/1}]}]);
init_db(_) ->
    ok.

stop(Host) ->
    ejabberd_hooks:delete(remove_user, Host, ?MODULE,
			  remove_user, 50),
    gen_iq_handler:remove_iq_handler(ejabberd_sm, Host,
				     ?NS_PRIVATE).

process_sm_iq(#jid{luser = LUser, lserver = LServer},
	      #jid{luser = LUser, lserver = LServer}, IQ)
    when IQ#iq.type == set ->
    case IQ#iq.sub_el of
      #xmlel{name = <<"query">>, children = Xmlels} ->
	  case filter_xmlels(Xmlels) of
	    [] ->
		IQ#iq{type = error,
		      sub_el = [IQ#iq.sub_el, ?ERR_NOT_ACCEPTABLE]};
	    Data ->
		DBType = gen_mod:db_type(LServer, ?MODULE),
		F = fun () ->
			    lists:foreach(fun (Datum) ->
						  set_data(LUser, LServer,
							   Datum, DBType)
					  end,
					  Data)
		    end,
		case DBType of
		  odbc -> ejabberd_odbc:sql_transaction(LServer, F);
		  mnesia -> mnesia:transaction(F);
                  p1db -> F();
		  riak -> F()
		end,
		IQ#iq{type = result, sub_el = []}
	  end;
      _ ->
	  IQ#iq{type = error,
		sub_el = [IQ#iq.sub_el, ?ERR_NOT_ACCEPTABLE]}
    end;
%%
process_sm_iq(#jid{luser = LUser, lserver = LServer},
	      #jid{luser = LUser, lserver = LServer}, IQ)
    when IQ#iq.type == get ->
    case IQ#iq.sub_el of
      #xmlel{name = <<"query">>, attrs = Attrs,
	     children = Xmlels} ->
	  case filter_xmlels(Xmlels) of
	    [] ->
		IQ#iq{type = error,
		      sub_el = [IQ#iq.sub_el, ?ERR_BAD_FORMAT]};
	    Data ->
		case catch get_data(LUser, LServer, Data) of
		  {'EXIT', _Reason} ->
		      IQ#iq{type = error,
			    sub_el =
				[IQ#iq.sub_el, ?ERR_INTERNAL_SERVER_ERROR]};
		  Storage_Xmlels ->
		      IQ#iq{type = result,
			    sub_el = [?Xmlel_Query(Attrs, Storage_Xmlels)]}
		end
	  end;
      _ ->
	  IQ#iq{type = error,
		sub_el = [IQ#iq.sub_el, ?ERR_BAD_FORMAT]}
    end;
%%
process_sm_iq(_From, _To, IQ) ->
    IQ#iq{type = error,
	  sub_el = [IQ#iq.sub_el, ?ERR_FORBIDDEN]}.

filter_xmlels(Xmlels) -> filter_xmlels(Xmlels, []).

filter_xmlels([], Data) -> lists:reverse(Data);
filter_xmlels([#xmlel{attrs = Attrs} = Xmlel | Xmlels],
	      Data) ->
    case xml:get_attr_s(<<"xmlns">>, Attrs) of
      <<"">> -> [];
      XmlNS -> filter_xmlels(Xmlels, [{XmlNS, Xmlel} | Data])
    end;
filter_xmlels([_ | Xmlels], Data) ->
    filter_xmlels(Xmlels, Data).

set_data(LUser, LServer, {XmlNS, Xmlel}, mnesia) ->
    mnesia:write(#private_storage{usns =
				      {LUser, LServer, XmlNS},
				  xml = Xmlel});
set_data(LUser, LServer, {XMLNS, El}, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    LXMLNS = ejabberd_odbc:escape(XMLNS),
    SData = ejabberd_odbc:escape(xml:element_to_binary(El)),
    odbc_queries:set_private_data(LServer, Username, LXMLNS,
				  SData);
set_data(LUser, LServer, {XMLNS, El}, p1db) ->
    USNKey = usn2key(LUser, LServer, XMLNS),
    Val = xml:element_to_binary(El),
    p1db:insert(private_storage, USNKey, Val);
set_data(LUser, LServer, {XMLNS, El}, riak) ->
    ejabberd_riak:put(#private_storage{usns = {LUser, LServer, XMLNS},
                                       xml = El},
                      [{'2i', [{<<"us">>, {LUser, LServer}}]}]).

get_data(LUser, LServer, Data) ->
    get_data(LUser, LServer,
	     gen_mod:db_type(LServer, ?MODULE), Data, []).

get_data(_LUser, _LServer, _DBType, [],
	 Storage_Xmlels) ->
    lists:reverse(Storage_Xmlels);
get_data(LUser, LServer, mnesia,
	 [{XmlNS, Xmlel} | Data], Storage_Xmlels) ->
    case mnesia:dirty_read(private_storage,
			   {LUser, LServer, XmlNS})
	of
      [#private_storage{xml = Storage_Xmlel}] ->
	  get_data(LUser, LServer, mnesia, Data,
		   [Storage_Xmlel | Storage_Xmlels]);
      _ ->
	  get_data(LUser, LServer, mnesia, Data,
		   [Xmlel | Storage_Xmlels])
    end;
get_data(LUser, LServer, odbc, [{XMLNS, El} | Els],
	 Res) ->
    Username = ejabberd_odbc:escape(LUser),
    LXMLNS = ejabberd_odbc:escape(XMLNS),
    case catch odbc_queries:get_private_data(LServer,
					     Username, LXMLNS)
	of
      {selected, [<<"data">>], [[SData]]} ->
	  case xml_stream:parse_element(SData) of
	    Data when is_record(Data, xmlel) ->
		get_data(LUser, LServer, odbc, Els, [Data | Res])
	  end;
      _ -> get_data(LUser, LServer, odbc, Els, [El | Res])
    end;
get_data(LUser, LServer, p1db, [{XMLNS, El} | Els], Res) ->
    USNKey = usn2key(LUser, LServer, XMLNS),
    case p1db:get(private_storage, USNKey) of
        {ok, XML, _VClock} ->
            case xml_stream:parse_element(XML) of
                {error, _} ->
                    get_data(LUser, LServer, p1db, Els, [El | Res]);
                NewEl ->
                    get_data(LUser, LServer, p1db, Els, [NewEl | Res])
            end;
        {error, _} ->
            get_data(LUser, LServer, p1db, Els, [El | Res])
    end;
get_data(LUser, LServer, riak, [{XMLNS, El} | Els],
	 Res) ->
    case ejabberd_riak:get(private_storage, {LUser, LServer, XMLNS}) of
        {ok, #private_storage{xml = NewEl}} ->
            get_data(LUser, LServer, riak, Els, [NewEl|Res]);
        _ ->
            get_data(LUser, LServer, riak, Els, [El|Res])
    end.

get_data(LUser, LServer) ->
    get_all_data(LUser, LServer,
                 gen_mod:db_type(LServer, ?MODULE)).

get_all_data(LUser, LServer, mnesia) ->
    lists:flatten(
      mnesia:dirty_select(private_storage,
                          [{#private_storage{usns = {LUser, LServer, '_'},
                                             xml = '$1'},
                            [], ['$1']}]));
get_all_data(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    case catch odbc_queries:get_private_data(LServer, Username) of
        {selected, [<<"namespace">>, <<"data">>], Res} ->
            lists:flatmap(
              fun([_, SData]) ->
                      case xml_stream:parse_element(SData) of
                          #xmlel{} = El ->
                              [El];
                          _ ->
                              []
                      end
              end, Res);
        _ ->
            []
    end;
get_all_data(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(private_storage, USPrefix) of
        {ok, L} ->
            lists:flatmap(
              fun({_Key, Val, _VClock}) ->
                      case xml_stream:parse_element(Val) of
                          #xmlel{} = El -> [El];
                          _ -> []
                      end
              end, L);
        {error, _} ->
            []
    end;
get_all_data(LUser, LServer, riak) ->
    case ejabberd_riak:get_by_index(
           private_storage, <<"us">>, {LUser, LServer}) of
        {ok, Res} ->
            [El || #private_storage{xml = El} <- Res];
        _ ->
            []
    end.

usn2key(LUser, LServer, XMLNS) ->
    USPrefix = us_prefix(LUser, LServer),
    <<USPrefix/binary, XMLNS/binary>>.

us_prefix(LUser, LServer) ->
    <<LServer/binary, 0, LUser/binary, 0>>.

%% P1DB schema
enc_key([Server]) ->
    <<Server/binary>>;
enc_key([Server, User]) ->
    <<Server/binary, 0, User/binary>>;
enc_key([Server, User, XMLNS]) ->
    <<Server/binary, 0, User/binary, 0, XMLNS/binary>>.

dec_key(Key) ->
    SLen = str:chr(Key, 0) - 1,
    <<Server:SLen/binary, 0, UKey/binary>> = Key,
    ULen = str:chr(UKey, 0) - 1,
    <<User:ULen/binary, 0, XMLNS/binary>> = UKey,
    [Server, User, XMLNS].

remove_user(User, Server) ->
    LUser = jlib:nodeprep(User),
    LServer = jlib:nameprep(Server),
    remove_user(LUser, LServer,
		gen_mod:db_type(Server, ?MODULE)).

remove_user(LUser, LServer, mnesia) ->
    F = fun () ->
		Namespaces = mnesia:select(private_storage,
					   [{#private_storage{usns =
								  {LUser,
								   LServer,
								   '$1'},
							      _ = '_'},
					     [], ['$$']}]),
		lists:foreach(fun ([Namespace]) ->
				      mnesia:delete({private_storage,
						     {LUser, LServer,
						      Namespace}})
			      end,
			      Namespaces)
	end,
    mnesia:transaction(F);
remove_user(LUser, LServer, odbc) ->
    Username = ejabberd_odbc:escape(LUser),
    odbc_queries:del_user_private_storage(LServer,
					  Username);
remove_user(LUser, LServer, p1db) ->
    USPrefix = us_prefix(LUser, LServer),
    case p1db:get_by_prefix(private_storage, USPrefix) of
        {ok, L} ->
            lists:foreach(
              fun({Key, _Val, VClock}) ->
                      p1db:async_delete(private_storage, Key, VClock)
              end, L),
            {atomic, ok};
        {error, _} = Err ->
            {aborted, Err}
    end;
remove_user(LUser, LServer, riak) ->
    {atomic, ejabberd_riak:delete_by_index(private_storage,
                                           <<"us">>, {LUser, LServer})}.

update_table() ->
    Fields = record_info(fields, private_storage),
    case mnesia:table_info(private_storage, attributes) of
      Fields ->
          ejabberd_config:convert_table_to_binary(
            private_storage, Fields, set,
            fun(#private_storage{usns = {U, _, _}}) -> U end,
            fun(#private_storage{usns = {U, S, NS}, xml = El} = R) ->
                    R#private_storage{usns = {iolist_to_binary(U),
                                              iolist_to_binary(S),
                                              iolist_to_binary(NS)},
                                      xml = xml:to_xmlel(El)}
            end);
      _ ->
	  ?INFO_MSG("Recreating private_storage table", []),
	  mnesia:transform_table(private_storage, ignore, Fields)
    end.

export(_Server) ->
    [{private_storage,
      fun(Host, #private_storage{usns = {LUser, LServer, XMLNS},
                                 xml = Data})
            when LServer == Host ->
              Username = ejabberd_odbc:escape(LUser),
              LXMLNS = ejabberd_odbc:escape(XMLNS),
              SData =
                  ejabberd_odbc:escape(xml:element_to_binary(Data)),
              odbc_queries:set_private_data_sql(Username, LXMLNS,
                                                SData);
         (_Host, _R) ->
              []
      end}].

import_info() ->
    [{<<"private_storage">>, 4}].

import(LServer, {odbc, _}, mnesia, <<"private_storage">>,
       [LUser, XMLNS, XML, _TimeStamp]) ->
    El = #xmlel{} = xml_stream:parse_element(XML),
    PS = #private_storage{usns = {LUser, LServer, XMLNS}, xml = El},
    mnesia:dirty_write(PS);
import(LServer, {odbc, _}, riak, <<"private_storage">>,
       [LUser, XMLNS, XML, _TimeStamp]) ->
    El = #xmlel{} = xml_stream:parse_element(XML),
    PS = #private_storage{usns = {LUser, LServer, XMLNS}, xml = El},
    ejabberd_riak:put(PS, [{'2i', [{<<"us">>, {LUser, LServer}}]}]);
import(LServer, {odbc, _}, p1db, <<"private_storage">>,
       [LUser, XMLNS, XML, _TimeStamp]) ->
    USNKey = usn2key(LUser, LServer, XMLNS),
    p1db:async_insert(private_storage, USNKey, XML);
import(_LServer, {odbc, _}, odbc, <<"private_storage">>, _) ->
    ok.
