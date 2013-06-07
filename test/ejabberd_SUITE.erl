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

end_per_testcase(_TestCase, Config) ->
    case ?config(socket) of
        undefined ->
            ok;
        _Socket ->
            ok = ejabberd_socket:send_text(Config, ?STREAM_TRAILER)
    end.

groups() ->
    [].

all() -> 
    [start_ejabberd,
     connect,
     auth,
     bind,
     open_session,
     roster_get,
     presence_broadcast,
     ping,
     version_get,
     time_get,
     stats_get,
     %% vcard_get,
     %% vcard_set,
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
    #stream_features{features = Fs} = recv(),
    Mechs = lists:flatmap(
              fun(#sasl_mechanisms{mechanisms = Ms}) ->
                      Ms;
                 (_) ->
                      []
              end, Fs),
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
                                           ?config(resource, Config)}]}]}]},
    ok = send_iq(Config, IQ),
    #'Iq'{type = result, id = ID, sub_els = [#bind{}]} = recv(),
    Config.

open_session(Config) ->
    ID = randoms:get_string(),
    IQ = #iq{type = set, xmlns = ?NS_SESSION, id = ID,
             sub_el =
                 [#xmlel{name = <<"session">>,
                         attrs = [{<<"xmlns">>, ?NS_SESSION}],
                         children = []}]},
    ok = send_iq(Config, IQ),
    #'Iq'{type = result, id = ID, sub_els = SubEls} = recv(),
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
    RosterIQ = #iq{type = get, xmlns = ?NS_ROSTER, id = ID,
                   sub_el =
                       [#xmlel{name = <<"query">>,
                               attrs = [{<<"xmlns">>, ?NS_ROSTER}],
                               children = []}]},
    ok = send_iq(Config, RosterIQ),
    #'Iq'{type = result, id = ID, sub_els = [#roster{items = []}]} = recv(),
    Config.

presence_broadcast(Config) ->
    ok = send_element(Config, #xmlel{name = <<"presence">>}),
    JID = myjid(Config),
    #'Presence'{from = JID, to = JID} = recv(),
    Config.

ping(Config) ->
    ID = randoms:get_string(),
    PingIQ = #iq{type = get, xmlns = ?NS_PING, id = ID,
                 sub_el = [#xmlel{name = <<"ping">>,
                                  attrs = [{<<"xmlns">>, ?NS_PING}]}]},
    ok = send_iq(Config, PingIQ),
    #'Iq'{type = result, id = ID, sub_els = []} = recv(),
    Config.

version_get(Config) ->
    ID = randoms:get_string(),
    VerIQ = #iq{type = get, xmlns = ?NS_VERSION, id = ID,
                 sub_el = [#xmlel{name = <<"query">>,
                                  attrs = [{<<"xmlns">>, ?NS_VERSION}]}]},
    ok = send_iq(Config, VerIQ, jlib:make_jid(<<>>, ?config(server, Config), <<>>)),
    #'Iq'{type = result, id = ID, sub_els = [#version{}]} = recv(),
    Config.

time_get(Config) ->
    ID = randoms:get_string(),
    TimeIQ = #iq{type = get, xmlns = ?NS_TIME, id = ID,
                 sub_el = [#xmlel{name = <<"query">>,
                                  attrs = [{<<"xmlns">>, ?NS_TIME}]}]},
    ok = send_iq(Config, TimeIQ, jlib:make_jid(<<>>, ?config(server, Config), <<>>)),
    #'Iq'{type = result, id = ID, sub_els = [#time{}]} = recv(),
    Config.

vcard_get(Config) ->
    ID = randoms:get_string(),
    VCardIQ = #iq{type = get, xmlns = ?NS_VCARD, id = ID,
                  sub_el = [#xmlel{name = <<"query">>,
                                   attrs = [{<<"xmlns">>, ?NS_VCARD}]}]},
    ok = send_iq(Config, VCardIQ, jlib:make_jid(<<>>, ?config(server, Config), <<>>)),
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

stats_get(Config) ->
    ID = randoms:get_string(),
    ServerJID = jlib:make_jid(<<>>, ?config(server, Config), <<>>),
    StatsIQ = #iq{type = get, xmlns = ?NS_STATS, id = ID,
                  sub_el = [#xmlel{name = <<"query">>,
                                   attrs = [{<<"xmlns">>, ?NS_STATS}]}]},
    ok = send_iq(Config, StatsIQ, ServerJID),
    #'Iq'{type = result, id = ID, sub_els = [#stats{stat = Stats}]} = recv(),
    lists:foreach(
      fun(#stat{name = Name}) ->
              I = randoms:get_string(),
              StatEl = #xmlel{name = <<"stat">>,
                              attrs = [{<<"name">>, Name}]},
              IQ = #iq{type = get, xmlns = ?NS_STATS, id = I,
                       sub_el = [#xmlel{name = <<"query">>,
                                        attrs = [{<<"xmlns">>, ?NS_STATS}],
                                        children = [StatEl]}]},
              ok = send_iq(Config, IQ, ServerJID),
              #'Iq'{type = result, id = I, sub_els = [_|_]} = recv()
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
    El = recv(),
    case El of
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
        #sasl_challenge{text = ClientIn} ->
            {Response, SASL} = (?config(sasl, Config))(ClientIn),
            send_element(Config,
                         #xmlel{name = <<"response">>,
                                attrs = [{<<"xmlns">>, ?NS_SASL}],
                                children =
                                    [{xmlcdata,
                                      jlib:encode_base64(Response)}]}),
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
            xmpp_codec:decode(El);
        {'$gen_event', Event} ->
            Event
    end.

send_text(Config, Text) ->
    ejabberd_socket:send(?config(socket, Config), Text).

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
    jlib:make_jid(?config(user, Config),
                  ?config(server, Config),
                  ?config(resource, Config)).
