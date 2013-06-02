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
-include("jlib.hrl").
-include("ejabberd.hrl").

-define(STREAM_HEADER,
	<<"<?xml version='1.0'?><stream:stream "
	  "xmlns:stream='http://etherx.jabber.org/stream"
	  "s' xmlns='jabber:client' to='~s' version='1.0"
	  "'>">>).

-ifndef(NS_PING).
-define(NS_PING, <<"urn:xmpp:ping">>).
-endif.

-define(opt(Opt), proplists:get_value(Opt, Config)).

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config) ->
    DataDir = proplists:get_value(data_dir, Config),
    ConfigPath = filename:join([DataDir, "ejabberd.cfg"]),
    application:set_env(ejabberd, config, ConfigPath),
    application:start(ejabberd),
    [{server, <<"localhost">>},
     {port, 5222},
     {user, <<"test_suite">>},
     {password, <<"pass">>},
     {resource, <<"test">>}
     |Config].

end_per_suite(_Config) ->
    ok.

init_per_group(_GroupName, Config) ->
    Config.

end_per_group(_GroupName, _Config) ->
    ok.

init_per_testcase(connect, Config) ->
    ok = re_register(Config),
    Config;
init_per_testcase(auth, Config) ->
    connect(Config);
init_per_testcase(bind, Config) ->
    auth(connect(Config));
init_per_testcase(session, Config) ->
    bind(auth(connect(Config)));
init_per_testcase(_TestCase, Config) ->
    session(bind(auth(connect(Config)))).

end_per_testcase(_TestCase, _Config) ->
    ok.

groups() ->
    [].

all() -> 
    [connect, auth, bind, session, roster, broadcast,
     ping, version, time, vcard_get, vcard_set, stats].

connect(Config) ->
    {ok, Sock} = ejabberd_socket:connect(
                   binary_to_list(?opt(server)), ?opt(port),
                   [binary, {packet, 0}, {active, false}]),
    Config1 = [{socket, Sock}|Config],
    ok = send_text(Config1, io_lib:format(?STREAM_HEADER, [?opt(server)])),
    {xmlstreamstart, <<"stream:stream">>, Attrs} = recv(),
    <<"jabber:client">> = xml:get_attr_s(<<"xmlns">>, Attrs),
    <<"1.0">> = xml:get_attr_s(<<"version">>, Attrs),
    {xmlstreamelement,
     #xmlel{name = <<"stream:features">>, children = FEls}} = recv(),
    Mechs = lists:flatmap(
              fun(#xmlel{name = <<"mechanisms">>,
                         attrs = Attrs1,
                         children = Els1}) ->
                      ?NS_SASL = xml:get_attr_s(<<"xmlns">>, Attrs1),
                      lists:flatmap(
                        fun(#xmlel{name = <<"mechanism">>,
                                   children = Els2}) ->
                                [xml:get_cdata(Els2)];
                           (_) ->
                                []
                        end, Els1);
                 (_) ->
                      []
              end, FEls),                   
    [{mechs, Mechs}|Config1].

auth(Config) ->
    auth_SASL(Config).

bind(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = set, xmlns = ?NS_BIND, id = ID,
             sub_el =
                 [#xmlel{name = <<"bind">>,
                         attrs = [{<<"xmlns">>, ?NS_BIND}],
                         children =
                             [#xmlel{name = <<"resource">>,
                                     attrs = [],
                                     children =
                                         [{xmlcdata,
                                           ?opt(resource)}]}]}]},
    ok = send_iq(Config, IQ),
    {xmlstreamelement, El} = recv(),
    #iq{type = result, id = ID, xmlns = ?NS_BIND,
        sub_el = [#xmlel{name = <<"bind">>}]}
        = jlib:iq_query_or_response_info(El),
    Config.

session(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = set, xmlns = ?NS_SESSION, id = ID,
             sub_el =
                 [#xmlel{name = <<"session">>,
                         attrs = [{<<"xmlns">>, ?NS_SESSION}],
                         children = []}]},
    ok = send_iq(Config, IQ),
    {xmlstreamelement, El} = recv(),
    #iq{type = result, id = ID, xmlns = ?NS_SESSION,
        sub_el = [#xmlel{name = <<"session">>}]}
        = jlib:iq_query_or_response_info(El),
    Config.

roster(Config) ->
    ID = randoms:get_string(),
    RosterIQ = #iq{type = get, xmlns = ?NS_ROSTER, id = ID,
                   sub_el =
                       [#xmlel{name = <<"query">>,
                               attrs = [{<<"xmlns">>, ?NS_ROSTER}],
                               children = []}]},
    ok = send_iq(Config, RosterIQ),
    {xmlstreamelement, #xmlel{name = <<"iq">>} = El} = recv(),
    #iq{type = result, xmlns = ?NS_ROSTER, id = ID,
        sub_el = [#xmlel{name = <<"query">>, children = []}]}
        = jlib:iq_query_or_response_info(El),
    Config.

broadcast(Config) ->
    ok = send_element(Config, #xmlel{name = <<"presence">>}),
    JID = myjid(Config),
    {xmlstreamelement, #xmlel{name = <<"presence">>, attrs = Attrs}} = recv(),
    JID = jlib:string_to_jid(xml:get_attr_s(<<"from">>, Attrs)),
    JID = jlib:string_to_jid(xml:get_attr_s(<<"to">>, Attrs)),
    Config.

ping(Config) ->
    ID = randoms:get_string(),
    PingIQ = #iq{type = get, xmlns = ?NS_PING, id = ID,
                 sub_el = [#xmlel{name = <<"ping">>,
                                  attrs = [{<<"xmlns">>, ?NS_PING}]}]},
    ok = send_iq(Config, PingIQ),
    {xmlstreamelement, #xmlel{name = <<"iq">>} = El} = recv(),
    #iq{type = result, id = ID, sub_el = []} = jlib:iq_query_or_response_info(El),
    Config.

version(Config) ->
    ID = randoms:get_string(),
    VerIQ = #iq{type = get, xmlns = ?NS_VERSION, id = ID,
                 sub_el = [#xmlel{name = <<"query">>,
                                  attrs = [{<<"xmlns">>, ?NS_VERSION}]}]},
    ok = send_iq(Config, VerIQ, jlib:make_jid(<<>>, ?opt(server), <<>>)),
    {xmlstreamelement, #xmlel{name = <<"iq">>} = El} = recv(),
    #iq{type = result, id = ID, xmlns = ?NS_VERSION, sub_el = [_|_]}
        = jlib:iq_query_or_response_info(El),
    Config.

time(Config) ->
    ID = randoms:get_string(),
    TimeIQ = #iq{type = get, xmlns = ?NS_TIME, id = ID,
                 sub_el = [#xmlel{name = <<"query">>,
                                  attrs = [{<<"xmlns">>, ?NS_TIME}]}]},
    ok = send_iq(Config, TimeIQ, jlib:make_jid(<<>>, ?opt(server), <<>>)),
    {xmlstreamelement, #xmlel{name = <<"iq">>} = El} = recv(),
    #iq{type = result, id = ID, xmlns = ?NS_TIME, sub_el = [_|_]}
        = jlib:iq_query_or_response_info(El),
    Config.

vcard_get(Config) ->
    ID = randoms:get_string(),
    VCardIQ = #iq{type = get, xmlns = ?NS_VCARD, id = ID,
                  sub_el = [#xmlel{name = <<"query">>,
                                   attrs = [{<<"xmlns">>, ?NS_VCARD}]}]},
    ok = send_iq(Config, VCardIQ, jlib:make_jid(<<>>, ?opt(server), <<>>)),
    {xmlstreamelement, #xmlel{name = <<"iq">>} = El} = recv(),
    #iq{type = result, id = ID, xmlns = ?NS_VCARD, sub_el = [_|_]}
        = jlib:iq_query_or_response_info(El),
    Config.

vcard_set(Config) ->
    ID1 = randoms:get_string(),
    BlankPNG = <<"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAACklEQVR4nGMA"
                 "AQAABQABDQottAAAAABJRU5ErkJggg==">>,
    VCard =
        #xmlel{name = <<"vCard">>,
               attrs = [{<<"xmlns">>, ?NS_VCARD}],
               children =
                   [#xmlel{name = <<"BDAY">>,
                           children = [{xmlcdata, <<"1476-06-09">>}]},
                    #xmlel{name = <<"ADR">>,
                           children =
                               [#xmlel{name = <<"CTRY">>,
                                       children =
                                           [{xmlcdata, <<"Italy">>}]},
                                #xmlel{name = <<"LOCALITY">>,
                                       children =
                                           [{xmlcdata, <<"Verona">>}]},
                                #xmlel{name = <<"HOME">>}]},
                    #xmlel{name = <<"NICKNAME">>},
                    #xmlel{name = <<"N">>,
                           children =
                               [#xmlel{name = <<"GIVEN">>,
                                       children =
                                           [{xmlcdata, <<"Juliet">>}]},
                                #xmlel{name = <<"FAMILY">>,
                                       children =
                                           [{xmlcdata, <<"Capulet">>}]}]},
                    #xmlel{name = <<"EMAIL">>,
                           children =
                               [{xmlcdata, <<"jcapulet@shakespeare.lit">>}]},
                    #xmlel{name = <<"PHOTO">>,
                           children =
                               [#xmlel{name = <<"TYPE">>,
                                       children =
                                           [{xmlcdata, <<"image/png">>}]},
                                #xmlel{name = <<"BINVAL">>,
                                       children =
                                           [{xmlcdata, BlankPNG}]}]}]},
    VCardIQSet = #iq{type = set, xmlns = ?NS_VCARD, id = ID1, sub_el = [VCard]},
    ok = send_iq(Config, VCardIQSet),
    {xmlstreamelement, #xmlel{name = <<"iq">>} = El1} = recv(),
    #iq{type = result, id = ID1, sub_el = []}
        = jlib:iq_query_or_response_info(El1),
    ID2 = randoms:get_string(),
    VCardIQGet = #iq{type = get, xmlns = ?NS_VCARD, id = ID2,
                     sub_el = [#xmlel{name = <<"vCard">>,
                                      attrs = [{<<"xmlns">>, ?NS_VCARD}]}]},
    ok = send_iq(Config, VCardIQGet),
    {xmlstreamelement, #xmlel{name = <<"iq">>} = El2} = recv(),
    #iq{type = result, id = ID2, xmlns = ?NS_VCARD, sub_el = [VCard]}
        = jlib:iq_query_or_response_info(El2),
    Config.

stats(Config) ->
    ID = randoms:get_string(),
    ServerJID = jlib:make_jid(<<>>, ?opt(server), <<>>),
    StatsIQ = #iq{type = get, xmlns = ?NS_STATS, id = ID,
                  sub_el = [#xmlel{name = <<"query">>,
                                   attrs = [{<<"xmlns">>, ?NS_STATS}]}]},
    ok = send_iq(Config, StatsIQ, ServerJID),
    {xmlstreamelement, #xmlel{name = <<"iq">>} = El} = recv(),
    #iq{type = result, id = ID, xmlns = ?NS_STATS,
        sub_el = [#xmlel{name = <<"query">>, children = StatsEls}]}
        = jlib:iq_query_or_response_info(El),
    lists:foreach(
      fun(StatsEl) ->
              I = randoms:get_string(),
              IQ = #iq{type = get, xmlns = ?NS_STATS, id = I,
                       sub_el = [#xmlel{name = <<"query">>,
                                        attrs = [{<<"xmlns">>, ?NS_STATS}],
                                        children = [StatsEl]}]},
              ok = send_iq(Config, IQ, ServerJID),
              {xmlstreamelement, #xmlel{name = <<"iq">>} = ResEl} = recv(),
              #iq{type = result, id = I, xmlns = ?NS_STATS,
                  sub_el = [#xmlel{name = <<"query">>, children = [_|_]}]}
                  = jlib:iq_query_or_response_info(ResEl)
      end, StatsEls),
    Config.

auth_SASL(Config) ->
    case lists:keytake(mechs, 1, Config) of
        {value, {mechs, [Mech|Mechs]}, Config1} ->
            case lists:member(Mech, [<<"DIGEST-MD5">>, <<"PLAIN">>]) of
                true ->
                    {Response, SASL} = sasl_new(Mech,
                                                ?opt(user),
                                                ?opt(server),
                                                ?opt(password)),
                    ok = send_element(
                           Config1,
                           #xmlel{name = <<"auth">>,
                                  attrs =
                                      [{<<"xmlns">>, ?NS_SASL},
                                       {<<"mechanism">>, Mech}],
                                  children =
                                      [{xmlcdata,
                                        jlib:encode_base64(Response)}]}),
                    wait_auth_SASL_result(
                      [{sasl, SASL}, {mechs, Mechs}|Config1]);
                false ->
                    auth_SASL([{mechs, Mechs}|Config1])
            end;
        {value, {mechs, []}, _} ->
            ct:fail(no_known_sasl_mechanisms_available)
    end.

wait_auth_SASL_result(Config) ->
    {xmlstreamelement, El} = recv(),
    ?NS_SASL = xml:get_tag_attr_s(<<"xmlns">>, El),
    case El of
        #xmlel{name = <<"success">>} ->
            ejabberd_socket:reset_stream(?opt(socket)),
            send_text(Config,
                      io_lib:format(?STREAM_HEADER,
                                    [?opt(server)])),
            {xmlstreamstart, <<"stream:stream">>, Attrs} = recv(),
            <<"jabber:client">> = xml:get_attr_s(<<"xmlns">>, Attrs),
            <<"1.0">> = xml:get_attr_s(<<"version">>, Attrs),
            {xmlstreamelement, #xmlel{name = <<"stream:features">>}} = recv(),
            Config;
        #xmlel{name = <<"challenge">>} ->
            ClientIn = jlib:decode_base64(xml:get_tag_cdata(El)),
            {Response, SASL} = (?opt(sasl))(ClientIn),
            send_element(Config,
                         #xmlel{name = <<"response">>,
                                attrs = [{<<"xmlns">>, ?NS_SASL}],
                                children =
                                    [{xmlcdata,
                                      jlib:encode_base64(Response)}]}),
            Config1 = proplists:delete(sasl, Config),
            wait_auth_SASL_result([{sasl, SASL}|Config1]);
        #xmlel{name = <<"failure">>} ->
            ct:fail(sasl_auth_failed)
    end.

%%%===================================================================
%%% Aux functions
%%%===================================================================
re_register(Config) ->
    User = ?opt(user),
    Server = ?opt(server),
    Pass = ?opt(password),
    {atomic, ok} = ejabberd_auth:try_register(User, Server, Pass),
    ok.

recv() ->
    receive
        {'$gen_event', Event} ->
            Event
    end.

send_text(Config, Text) ->
    ejabberd_socket:send(?opt(socket), Text).

send_element(State, El) ->
    send_text(State, xml:element_to_binary(El)).

send_iq(State, IQ) ->
    send_element(State, jlib:iq_to_xml(IQ)).

send_iq(State, IQ, To) ->
    El = jlib:replace_from_to(myjid(State), To, jlib:iq_to_xml(IQ)),
    send_element(State, El).

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

myjid(Config) ->
    jlib:make_jid(?opt(user), ?opt(server), ?opt(resource)).
