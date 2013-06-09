%%%-------------------------------------------------------------------
%%% @author Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2013, Evgeniy Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  2 Jun 2013 by Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(ejabberd_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
%%-include("jlib.hrl").
-include("ejabberd.hrl").
-include("xmpp_codec.hrl").

-define(STREAM_HEADER,
	<<"<?xml version='1.0'?><stream:stream "
	  "xmlns:stream='http://etherx.jabber.org/stream"
	  "s' xmlns='jabber:client' to='~s' version='1.0"
	  "'>">>).

-define(STREAM_TRAILER, <<"</stream:stream>">>).

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config) ->
    DataDir = proplists:get_value(data_dir, Config),
    PrivDir = proplists:get_value(priv_dir, Config),
    ConfigPath = filename:join([DataDir, "ejabberd.cfg"]),
    LogPath = filename:join([PrivDir, "ejabberd.log"]),
    SASLPath = filename:join([PrivDir, "sasl.log"]),
    MnesiaDir = filename:join([PrivDir, "mnesia"]),
    application:set_env(ejabberd, config, ConfigPath),
    application:set_env(ejabberd, log_path, LogPath),
    application:set_env(sasl, sasl_error_logger, {file, SASLPath}),
    application:set_env(mnesia, dir, MnesiaDir),
    [{server, <<"localhost">>},
     {port, 5222},
     {user, <<"test_suite">>},
     {password, <<"pass">>}
     |Config].

end_per_suite(_Config) ->
    ok.

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, _Config) ->
    ok.

init_per_testcase(start_ejabberd, Config) ->
    Config;
init_per_testcase(TestCase, OrigConfig) ->
    Resource = list_to_binary(atom_to_list(TestCase)),
    Config = [{resource, Resource}|OrigConfig],
    case TestCase of
        connect ->
            Config;
        auth ->
            connect(Config);
        bind ->
            auth(connect(Config));
        open_session ->
            bind(auth(connect(Config)));
        _ ->
            open_session(bind(auth(connect(Config))))
    end.

end_per_testcase(stop_ejabberd, _Config) ->
    ok;
end_per_testcase(_TestCase, Config) ->
    case ?config(socket, Config) of
        undefined ->
            ok;
        Socket ->
            ok = ejabberd_socket:send(Socket, ?STREAM_TRAILER)
    end.

groups() ->
    [].

%%all() -> [start_ejabberd, vcard].
    
all() -> 
    [start_ejabberd,
     connect,
     auth,
     bind,
     open_session,
     roster_get,
     presence_broadcast,
     ping,
     version,
     time,
     stats,
     disco,
     last,
     private,
     privacy,
     blocking,
     vcard,
     stop_ejabberd].

start_ejabberd(Config) ->
    ok = application:start(ejabberd),
    ok = re_register(Config),
    Config.

stop_ejabberd(Config) ->
    ok = application:stop(ejabberd),
    #stream_error{reason = 'system-shutdown'} = recv(),
    {xmlstreamend, <<"stream:stream">>} = recv(),
    Config.

connect(Config) ->
    {ok, Sock} = ejabberd_socket:connect(
                   binary_to_list(?config(server, Config)),
                   ?config(port, Config),
                   [binary, {packet, 0}, {active, false}]),
    Config1 = [{socket, Sock}|Config],
    ok = send_text(Config1, io_lib:format(?STREAM_HEADER,
                                          [?config(server, Config1)])),
    {xmlstreamstart, <<"stream:stream">>, Attrs} = recv(),
    <<"jabber:client">> = xml:get_attr_s(<<"xmlns">>, Attrs),
    <<"1.0">> = xml:get_attr_s(<<"version">>, Attrs),
    #stream_features{sub_els = Fs} = recv(),
    Mechs = lists:flatmap(
              fun(#sasl_mechanisms{mechanism = Ms}) ->
                      Ms;
                 (_) ->
                      []
              end, Fs),
    [{mechs, Mechs}|Config1].

auth(Config) ->
    auth_SASL(Config).

bind(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{id = ID, type = set,
               sub_els = [#bind{resource = ?config(resource, Config)}]},
    ok = send_element(Config, IQ),
    #iq{type = result, id = ID, sub_els = [#bind{}]} = recv(),
    Config.

open_session(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = set, id = ID, sub_els = [#session{}]},
    ok = send_element(Config, IQ),
    #iq{type = result, id = ID, sub_els = SubEls} = recv(),
    case SubEls of
        [] ->
            ok;
        [#session{}] ->
            %% ejabberd work-around
            ok
    end,
    Config.

roster_get(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = get, id = ID, sub_els = [#roster{}]},
    ok = send_element(Config, IQ),
    #iq{type = result, id = ID,
          sub_els = [#roster{item = []}]} = recv(),
    Config.

presence_broadcast(Config) ->
    ok = send_element(Config, #presence{}),
    JID = my_jid(Config),
    #presence{from = JID, to = JID} = recv(),
    Config.

ping(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = get, id = ID, sub_els = [#ping{}],
               to = server_jid(Config)},
    ok = send_element(Config, IQ),
    #iq{type = result, id = ID, sub_els = []} = recv(),
    Config.

version(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = get, id = ID, sub_els = [#version{}],
               to = server_jid(Config)},
    ok = send_element(Config, IQ),
    #iq{type = result, id = ID, sub_els = [#version{}]} = recv(),
    Config.

time(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = get, id = ID, sub_els = [#time{}],
               to = server_jid(Config)},
    ok = send_element(Config, IQ),
    #iq{type = result, id = ID, sub_els = [#time{}]} = recv(),
    Config.

disco(Config) ->
    I1 = randoms:get_string(),
    ok = send_element(
           Config,
           #iq{type = get, id = I1, sub_els = [#disco_items{}],
                 to = server_jid(Config)}),
    #iq{type = result, id = I1, sub_els = [#disco_items{items = Items}]} = recv(),
    lists:foreach(
      fun(#disco_item{jid = JID, node = Node}) ->
              I = randoms:get_string(),
              ok = send_element(
                     Config,
                     #iq{type = get, id = I,
                           sub_els = [#disco_info{node = Node}],
                           to = JID}),
              #iq{type = result, id = I, sub_els = _} = recv()
      end, Items),
    Config.

private(Config) ->
    ID1 = randoms:get_string(),
    ok = send_element(
           Config,
           #iq{type = get, id = ID1, sub_els = [#private{}],
                 to = server_jid(Config)}),
    #iq{type = error, id = ID1} = recv(),
    ID2 = randoms:get_string(),
    Storage = #bookmark_storage{
      conference = [#bookmark_conference{
                       name = <<"Some name">>,
                       autojoin = true,
                       jid = jlib:make_jid(
                               <<"some">>,
                               ?config(server, Config),
                               <<>>)}]},
    IQSet = #iq{type = set, id = ID2,
                  sub_els = [#private{sub_els = [Storage]}]},
    ok = send_element(Config, IQSet),
    #iq{type = result, id = ID2, sub_els = []} = recv(),
    ID3 = randoms:get_string(),
    IQGet = #iq{type = get, id = ID3,
                  sub_els = [#private{sub_els = [#bookmark_storage{}]}]},
    ok = send_element(Config, IQGet),
    #iq{type = result, id = ID3,
          sub_els = [#private{sub_els = [Storage]}]} = recv(),
    Config.

last(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = get, id = ID, sub_els = [#last{}],
               to = server_jid(Config)},
    ok = send_element(Config, IQ),
    #iq{type = result, id = ID, sub_els = [#last{}]} = recv(),
    Config.

privacy(Config) ->
    I1 = randoms:get_string(),
    I2 = randoms:get_string(),
    I3 = randoms:get_string(),
    I4 = randoms:get_string(),
    I5 = randoms:get_string(),
    I6 = randoms:get_string(),
    I7 = randoms:get_string(),
    I8 = randoms:get_string(),
    ok = send_element(
           Config,
           #iq{type = get, id = I1, sub_els = [#privacy{}]}),
    #iq{type = result, id = I1, sub_els = [#privacy{}]} = recv(),
    JID = <<"tybalt@example.com">>,
    ok = send_element(
           Config,
           #iq{type = set, id = I2,
                 sub_els = [#privacy{
                               list = [#privacy_list{
                                          name = <<"public">>,
                                          privacy_item =
                                              [#privacy_item{
                                                  type = jid,
                                                  order = 3,
                                                  action = deny,
                                                  stanza = 'presence-in',
                                                  value = JID}]}]}]}),
    #iq{type = result, id = I2, sub_els = []} = recv(),
    _Push1 = #iq{type = set, id = PushI1,
                   sub_els = [#privacy{
                                 list = [#privacy_list{
                                            name = <<"public">>}]}]} = recv(),
    %% BUG: ejabberd replies on this result
    %% TODO: this should be fixed in ejabberd
    %% ok = send_element(Config, Push1#iq{type = result, sub_els = []}),
    ok = send_element(
           Config,
           #iq{type = set, id = I3,
                 sub_els = [#privacy{active = <<"public">>}]}),
    #iq{type = result, id = I3, sub_els = []} = recv(),
    ok = send_element(
           Config,
           #iq{type = set, id = I4,
                 sub_els = [#privacy{default = <<"public">>}]}),
    #iq{type = result, id = I4, sub_els = []} = recv(),
    ok = send_element(
           Config,
           #iq{type = get, id = I5,
                 sub_els = [#privacy{}]}),
    #iq{type = result, id = I5,
          sub_els = [#privacy{default = <<"public">>,
                              active = <<"public">>,
                              list = [#privacy_list{name = <<"public">>}]}]} = recv(),
    ok = send_element(
           Config,
           #iq{type = set, id = I6, sub_els = [#privacy{default = none}]}),
    #iq{type = result, id = I6, sub_els = []} = recv(),
    ok = send_element(
           Config,
           #iq{type = set, id = I7, sub_els = [#privacy{active = none}]}),
    #iq{type = result, id = I7, sub_els = []} = recv(),
    ok = send_element(
           Config,
           #iq{type = set, id = I8,
                 sub_els = [#privacy{list = [#privacy_list{name = <<"public">>}]}]}),
    #iq{type = result, id = I8, sub_els = []} = recv(),
    %% BUG: We should receive this:
    %% TODO: fix in ejabberd
    %% _Push2 = #iq{type = set, id = PushI2, sub_els = []} = recv(),
    _Push2 = #iq{type = set, id = PushI2,
                   sub_els = [#privacy{
                                 list = [#privacy_list{
                                            name = <<"public">>}]}]} = recv(),
    Config.

blocking(Config) ->
    I1 = randoms:get_string(),
    I2 = randoms:get_string(),
    I3 = randoms:get_string(),
    JID = jlib:make_jid(<<"romeo">>, <<"montague.net">>, <<>>),
    ok = send_element(
           Config,
           #iq{type = get, id = I1, sub_els = [#block_list{}]}),
    #iq{type = result, id = I1, sub_els = [#block_list{}]} = recv(),
    ok = send_element(
           Config,
           #iq{type = set, id = I2,
                 sub_els = [#block{block_item = [JID]}]}),
    #iq{type = result, id = I2, sub_els = []} = recv(),
    #iq{type = set, id = _,
          sub_els = [#privacy{list = [#privacy_list{}]}]} = recv(),
    #iq{type = set, id = _,
          sub_els = [#block{block_item = [JID]}]} = recv(),
    ok = send_element(
           Config,
           #iq{type = set, id = I3,
                 sub_els = [#unblock{block_item = [JID]}]}),
    #iq{type = result, id = I3, sub_els = []} = recv(),
    #iq{type = set, id = _,
          sub_els = [#privacy{list = [#privacy_list{}]}]} = recv(),
    #iq{type = set, id = _,
          sub_els = [#unblock{block_item = [JID]}]} = recv(),
    Config.

vcard(Config) ->
    I1 = randoms:get_string(),
    I2 = randoms:get_string(),
    VCard =
        #vcard{fn = <<"Peter Saint-Andre">>,
               n = #vcard_name{family = <<"Saint-Andre">>,
                               given = <<"Peter">>},
               nickname = <<"stpeter">>,
               bday = <<"1966-08-06">>,
               adr = [#vcard_adr{work = true,
                                 extadd = <<"Suite 600">>,
                                 street = <<"1899 Wynkoop Street">>,
                                 locality = <<"Denver">>,
                                 region = <<"CO">>,
                                 pcode = <<"80202">>,
                                 ctry = <<"USA">>},
                      #vcard_adr{home = true,
                                 locality = <<"Denver">>,
                                 region = <<"CO">>,
                                 pcode = <<"80209">>,
                                 ctry = <<"USA">>}],
               tel = [#vcard_tel{work = true,voice = true,
                                 number = <<"303-308-3282">>},
                      #vcard_tel{home = true,voice = true,
                                 number = <<"303-555-1212">>}],
               email = [#vcard_email{internet = true,pref = true,
                                     userid = <<"stpeter@jabber.org">>}],
               jabberid = <<"stpeter@jabber.org">>,
               title = <<"Executive Director">>,role = <<"Patron Saint">>,
               org = #vcard_org{name = <<"XMPP Standards Foundation">>},
               url = <<"http://www.xmpp.org/xsf/people/stpeter.shtml">>,
               desc = <<"More information about me is located on my "
                        "personal website: http://www.saint-andre.com/">>},
    ok = send_element(
           Config,
           #iq{type = set, id = I1, sub_els = [VCard]}),
    #iq{type = result, id = I1, sub_els = []} = recv(),
    ok = send_element(
           Config,
           #iq{type = get, id = I2, sub_els = [#vcard{}]}),
    %% TODO: check if VCard == VCard1.
    #iq{type = result, id = I2, sub_els = [_VCard1]} = recv(),
    Config.

stats(Config) ->
    ID = randoms:get_string(),
    ServerJID = server_jid(Config),
    StatsIQ = #iq{type = get, id = ID, sub_els = [#stats{}],
                    to = server_jid(Config)},
    ok = send_element(Config, StatsIQ),
    #iq{type = result, id = ID, sub_els = [#stats{stat = Stats}]} = recv(),
    lists:foreach(
      fun(#stat{name = Name} = Stat) ->
              I = randoms:get_string(),
              IQ = #iq{type = get, id = I,
                         sub_els = [#stats{stat = [Stat]}],
                    to = server_jid(Config)},
              ok = send_element(Config, IQ),
              #iq{type = result, id = I, sub_els = [_|_]} = recv()
      end, Stats),
    Config.

auth_SASL(Config) ->
    case lists:keytake(mechs, 1, Config) of
        {value, {mechs, [Mech|Mechs]}, Config1} ->
            case lists:member(Mech, [<<"DIGEST-MD5">>, <<"PLAIN">>]) of
                true ->
                    {Response, SASL} = sasl_new(Mech,
                                                ?config(user, Config),
                                                ?config(server, Config),
                                                ?config(password, Config)),
                    ok = send_element(
                           Config1,
                           #sasl_auth{mechanism = Mech,
                                      cdata = Response}),
                    wait_auth_SASL_result(
                      [{sasl, SASL}, {mechs, Mechs}|Config1]);
                false ->
                    auth_SASL([{mechs, Mechs}|Config1])
            end;
        {value, {mechs, []}, _} ->
            ct:fail(no_known_sasl_mechanisms_available)
    end.

wait_auth_SASL_result(Config) ->
    case recv() of
        #sasl_success{} ->
            ejabberd_socket:reset_stream(?config(socket, Config)),
            send_text(Config,
                      io_lib:format(?STREAM_HEADER,
                                    [?config(server, Config)])),
            {xmlstreamstart, <<"stream:stream">>, Attrs} = recv(),
            <<"jabber:client">> = xml:get_attr_s(<<"xmlns">>, Attrs),
            <<"1.0">> = xml:get_attr_s(<<"version">>, Attrs),
            #stream_features{} = recv(),
            Config;
        #sasl_challenge{cdata = ClientIn} ->
            {Response, SASL} = (?config(sasl, Config))(ClientIn),
            ok = send_element(
                   Config,
                   #sasl_response{cdata = Response}),
            Config1 = proplists:delete(sasl, Config),
            wait_auth_SASL_result([{sasl, SASL}|Config1]);
        #sasl_failure{} ->
            ct:fail(sasl_auth_failed)
    end.

%%%===================================================================
%%% Aux functions
%%%===================================================================
re_register(Config) ->
    User = ?config(user, Config),
    Server = ?config(server, Config),
    Pass = ?config(password, Config),
    {atomic, ok} = ejabberd_auth:try_register(User, Server, Pass),
    ok.

recv() ->
    receive
        {'$gen_event', {xmlstreamelement, El}} ->
            ct:pal("recv: ~p~n", [El]),
            Pkt = xmpp_codec:decode(El),
            %%ct:pal("in: ~p~n", [Pkt]),
            Pkt;
        {'$gen_event', Event} ->
            Event
    end.

send_text(Config, Text) ->
    ejabberd_socket:send(?config(socket, Config), Text).

send_element(State, Pkt) ->
    %%ct:pal("out: ~p~n", [Pkt]),
    El = xmpp_codec:encode(Pkt),
    ct:pal("sent: ~p~n", [El]),
    send_text(State, xml:element_to_binary(El)).

send_iq(State, IQ) ->
    send_text(State, xml:element_to_binary(jlib:iq_to_xml(IQ))).

send_iq(State, IQ, To) ->
    El = jlib:replace_from_to(my_jid(State), To, jlib:iq_to_xml(IQ)),
    send_text(State, xml:element_to_binary(El)).

sasl_new(<<"PLAIN">>, User, Server, Password) ->
    {<<User/binary, $@, Server/binary, 0, User/binary, 0, Password/binary>>,
     fun (_) -> {error, <<"Invalid SASL challenge">>} end};
sasl_new(<<"DIGEST-MD5">>, User, Server, Password) ->
    {<<"">>,
     fun (ServerIn) ->
	     case cyrsasl_digest:parse(ServerIn) of
	       bad -> {error, <<"Invalid SASL challenge">>};
	       KeyVals ->
		   Nonce = xml:get_attr_s(<<"nonce">>, KeyVals),
		   CNonce = randoms:get_string(),
		   DigestURI = <<"xmpp/", Server/binary>>,
		   Realm = Server,
		   NC = <<"00000001">>,
		   QOP = <<"auth">>,
		   AuthzId = <<"">>,
		   MyResponse = response(User, Password, Nonce, AuthzId,
					 Realm, CNonce, DigestURI, NC, QOP,
					 <<"AUTHENTICATE">>),
		   ServerResponse = response(User, Password, Nonce,
					     AuthzId, Realm, CNonce, DigestURI,
					     NC, QOP, <<"">>),
		   Resp = <<"username=\"", User/binary, "\",realm=\"",
			    Realm/binary, "\",nonce=\"", Nonce/binary,
			    "\",cnonce=\"", CNonce/binary, "\",nc=", NC/binary,
			    ",qop=", QOP/binary, ",digest-uri=\"",
			    DigestURI/binary, "\",response=\"",
			    MyResponse/binary, "\"">>,
		   {Resp,
		    fun (ServerIn2) ->
			    case cyrsasl_digest:parse(ServerIn2) of
			      bad -> {error, <<"Invalid SASL challenge">>};
			      KeyVals2 ->
				  RspAuth = xml:get_attr_s(<<"rspauth">>,
							   KeyVals2),
				  if RspAuth == ServerResponse ->
					 {<<"">>,
					  fun (_) ->
						  {error,
						   <<"Invalid SASL challenge">>}
					  end};
				     true ->
					 {error, <<"Invalid SASL challenge">>}
				  end
			    end
		    end}
	     end
     end}.

hex(S) ->
    sha:to_hexlist(S).

response(User, Passwd, Nonce, AuthzId, Realm, CNonce,
	 DigestURI, NC, QOP, A2Prefix) ->
    A1 = case AuthzId of
	   <<"">> ->
	       <<((crypto:md5(<<User/binary, ":", Realm/binary, ":",
				Passwd/binary>>)))/binary,
		 ":", Nonce/binary, ":", CNonce/binary>>;
	   _ ->
	       <<((crypto:md5(<<User/binary, ":", Realm/binary, ":",
				Passwd/binary>>)))/binary,
		 ":", Nonce/binary, ":", CNonce/binary, ":",
		 AuthzId/binary>>
	 end,
    A2 = case QOP of
	   <<"auth">> ->
	       <<A2Prefix/binary, ":", DigestURI/binary>>;
	   _ ->
	       <<A2Prefix/binary, ":", DigestURI/binary,
		 ":00000000000000000000000000000000">>
	 end,
    T = <<(hex((crypto:md5(A1))))/binary, ":", Nonce/binary,
	  ":", NC/binary, ":", CNonce/binary, ":", QOP/binary,
	  ":", (hex((crypto:md5(A2))))/binary>>,
    hex((crypto:md5(T))).

my_jid(Config) ->
    jlib:make_jid(?config(user, Config),
                  ?config(server, Config),
                  ?config(resource, Config)).

server_jid(Config) ->
    jlib:make_jid(<<>>, ?config(server, Config), <<>>).
