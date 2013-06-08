-module(xmpp_codec).

-compile([nowarn_unused_function]).

-export([decode/1, encode/1]).

decode({xmlel, _name, _attrs, _} = _el) ->
    case {_name, xml:get_attr_s(<<"xmlns">>, _attrs)} of
      {<<"stream:error">>, <<>>} ->
	  'decode_stream_error_stream:error'(_el);
      {<<"time">>, <<"urn:xmpp:time">>} ->
	  decode_time_time(_el);
      {<<"ping">>, <<"urn:xmpp:ping">>} ->
	  decode_ping_ping(_el);
      {<<"session">>,
       <<"urn:ietf:params:xml:ns:xmpp-session">>} ->
	  decode_session_session(_el);
      {<<"register">>,
       <<"http://jabber.org/features/iq-register">>} ->
	  decode_register_register(_el);
      {<<"c">>, <<"http://jabber.org/protocol/caps">>} ->
	  decode_caps_c(_el);
      {<<"ack">>, <<"p1:ack">>} -> decode_p1_ack_ack(_el);
      {<<"rebind">>, <<"p1:rebind">>} ->
	  decode_p1_rebind_rebind(_el);
      {<<"push">>, <<"p1:push">>} -> decode_p1_push_push(_el);
      {<<"stream:features">>, <<>>} ->
	  'decode_stream_features_stream:features'(_el);
      {<<"failure">>,
       <<"urn:ietf:params:xml:ns:xmpp-tls">>} ->
	  decode_starttls_failure_failure(_el);
      {<<"proceed">>,
       <<"urn:ietf:params:xml:ns:xmpp-tls">>} ->
	  decode_starttls_proceed_proceed(_el);
      {<<"starttls">>,
       <<"urn:ietf:params:xml:ns:xmpp-tls">>} ->
	  decode_starttls_starttls(_el);
      {<<"mechanisms">>,
       <<"urn:ietf:params:xml:ns:xmpp-sasl">>} ->
	  decode_sasl_mechanisms_mechanisms(_el);
      {<<"mechanism">>, <<>>} ->
	  decode_sasl_mechanism_mechanism(_el);
      {<<"failure">>,
       <<"urn:ietf:params:xml:ns:xmpp-sasl">>} ->
	  decode_sasl_failure_failure(_el);
      {<<"success">>,
       <<"urn:ietf:params:xml:ns:xmpp-sasl">>} ->
	  decode_sasl_success_success(_el);
      {<<"response">>,
       <<"urn:ietf:params:xml:ns:xmpp-sasl">>} ->
	  decode_sasl_response_response(_el);
      {<<"challenge">>,
       <<"urn:ietf:params:xml:ns:xmpp-sasl">>} ->
	  decode_sasl_challenge_challenge(_el);
      {<<"abort">>, <<"urn:ietf:params:xml:ns:xmpp-sasl">>} ->
	  decode_sasl_abort_abort(_el);
      {<<"auth">>, <<"urn:ietf:params:xml:ns:xmpp-sasl">>} ->
	  decode_sasl_auth_auth(_el);
      {<<"bind">>, <<"urn:ietf:params:xml:ns:xmpp-bind">>} ->
	  decode_bind_bind(_el);
      {<<"error">>, <<>>} -> decode_error_error(_el);
      {<<"presence">>, <<>>} -> decode_presence_presence(_el);
      {<<"message">>, <<>>} -> decode_message_message(_el);
      {<<"iq">>, <<>>} -> decode_iq_iq(_el);
      {<<"query">>, <<"http://jabber.org/protocol/stats">>} ->
	  decode_stats_query(_el);
      {<<"storage">>, <<"storage:bookmarks">>} ->
	  decode_storage_bookmarks_storage(_el);
      {<<"query">>, <<"jabber:iq:private">>} ->
	  decode_private_query(_el);
      {<<"query">>,
       <<"http://jabber.org/protocol/disco#items">>} ->
	  decode_disco_items_query(_el);
      {<<"query">>,
       <<"http://jabber.org/protocol/disco#info">>} ->
	  decode_disco_info_query(_el);
      {<<"blocklist">>, <<"urn:xmpp:blocking">>} ->
	  decode_block_list_blocklist(_el);
      {<<"unblock">>, <<"urn:xmpp:blocking">>} ->
	  decode_unblock_unblock(_el);
      {<<"block">>, <<"urn:xmpp:blocking">>} ->
	  decode_block_block(_el);
      {<<"item">>, <<>>} -> decode_block_item_item(_el);
      {<<"query">>, <<"jabber:iq:privacy">>} ->
	  decode_privacy_query(_el);
      {<<"item">>, <<>>} -> decode_privacy_item_item(_el);
      {<<"query">>, <<"jabber:iq:roster">>} ->
	  decode_roster_query(_el);
      {<<"query">>, <<"jabber:iq:version">>} ->
	  decode_version_query(_el);
      {<<"query">>, <<"jabber:iq:last">>} ->
	  decode_last_query(_el);
      {_name, _xmlns} ->
	  erlang:error({unknown_tag, _name, _xmlns})
    end.

encode({stream_error, _, _} = _r) ->
    hd('encode_stream_error_stream:error'(_r, []));
encode({time, _, _} = _r) ->
    hd(encode_time_time(_r, []));
encode({ping} = _r) -> hd(encode_ping_ping(_r, []));
encode({session} = _r) ->
    hd(encode_session_session(_r, []));
encode({register} = _r) ->
    hd(encode_register_register(_r, []));
encode({caps, _, _, _} = _r) ->
    hd(encode_caps_c(_r, []));
encode({p1_ack} = _r) -> hd(encode_p1_ack_ack(_r, []));
encode({p1_rebind} = _r) ->
    hd(encode_p1_rebind_rebind(_r, []));
encode({p1_push} = _r) ->
    hd(encode_p1_push_push(_r, []));
encode({stream_features, _} = _r) ->
    hd('encode_stream_features_stream:features'(_r, []));
encode({starttls_failure} = _r) ->
    hd(encode_starttls_failure_failure(_r, []));
encode({starttls_proceed} = _r) ->
    hd(encode_starttls_proceed_proceed(_r, []));
encode({starttls, _} = _r) ->
    hd(encode_starttls_starttls(_r, []));
encode({sasl_mechanisms, _} = _r) ->
    hd(encode_sasl_mechanisms_mechanisms(_r, []));
encode({sasl_failure, _, _} = _r) ->
    hd(encode_sasl_failure_failure(_r, []));
encode({sasl_success, _} = _r) ->
    hd(encode_sasl_success_success(_r, []));
encode({sasl_response, _} = _r) ->
    hd(encode_sasl_response_response(_r, []));
encode({sasl_challenge, _} = _r) ->
    hd(encode_sasl_challenge_challenge(_r, []));
encode({sasl_abort} = _r) ->
    hd(encode_sasl_abort_abort(_r, []));
encode({sasl_auth, _, _} = _r) ->
    hd(encode_sasl_auth_auth(_r, []));
encode({bind, _, _} = _r) ->
    hd(encode_bind_bind(_r, []));
encode({error, _, _, _, _} = _r) ->
    hd(encode_error_error(_r, []));
encode({'Presence', _, _, _, _, _, _, _, _, _, _} =
	   _r) ->
    hd(encode_presence_presence(_r, []));
encode({'Message', _, _, _, _, _, _, _, _, _, _} =
	   _r) ->
    hd(encode_message_message(_r, []));
encode({'Iq', _, _, _, _, _, _, _} = _r) ->
    hd(encode_iq_iq(_r, []));
encode({stats, _} = _r) ->
    hd(encode_stats_query(_r, []));
encode({bookmark_storage, _, _} = _r) ->
    hd(encode_storage_bookmarks_storage(_r, []));
encode({private, _} = _r) ->
    hd(encode_private_query(_r, []));
encode({disco_items, _, _} = _r) ->
    hd(encode_disco_items_query(_r, []));
encode({disco_info, _, _, _} = _r) ->
    hd(encode_disco_info_query(_r, []));
encode({block_list} = _r) ->
    hd(encode_block_list_blocklist(_r, []));
encode({unblock, _} = _r) ->
    hd(encode_unblock_unblock(_r, []));
encode({block, _} = _r) ->
    hd(encode_block_block(_r, []));
encode({privacy, _, _, _} = _r) ->
    hd(encode_privacy_query(_r, []));
encode({privacy_item, _, _, _, _, _} = _r) ->
    hd(encode_privacy_item_item(_r, []));
encode({roster, _, _} = _r) ->
    hd(encode_roster_query(_r, []));
encode({version, _, _, _} = _r) ->
    hd(encode_version_query(_r, []));
encode({last, _, _} = _r) ->
    hd(encode_last_query(_r, [])).

enc_bool(false) -> <<"false">>;
enc_bool(true) -> <<"true">>.

dec_bool(<<"false">>) -> false;
dec_bool(<<"true">>) -> true.

sign(N) when N < 0 -> <<"-">>;
sign(_) -> <<"+">>.

resourceprep(R) ->
    case jlib:resourceprep(R) of
      error -> erlang:error(badarg);
      R1 -> R1
    end.

enc_jid(J) -> jlib:jid_to_string(J).

dec_jid(Val) ->
    case jlib:string_to_jid(Val) of
      error -> erlang:error(badarg);
      J -> J
    end.

enc_utc(Val) -> jlib:now_to_utc_string(Val).

dec_utc(Val) ->
    {_, _, _} = jlib:datetime_string_to_timestamp(Val).

enc_tzo({Sign, {H, M}}) ->
    Sign = if H >= 0 -> <<>>;
	      true -> <<"-">>
	   end,
    list_to_binary([Sign,
		    io_lib:format("~2..0w:~2..0w", [H, M])]).

dec_tzo(Val) ->
    [H1, M1] = str:tokens(Val, <<":">>),
    H = erlang:binary_to_integer(H1),
    M = erlang:binary_to_integer(M1),
    if H >= -12, H =< 12, M >= 0, M < 60 -> {H, M} end.

decode_last_query({xmlel, _, _attrs, _els}) ->
    Seconds = decode_last_query_attrs(_attrs, <<>>),
    Text = decode_last_query_els(_els, <<>>),
    {last, Seconds, Text}.

decode_last_query_els([{xmlcdata, _data} | _els],
		      Text) ->
    decode_last_query_els(_els,
			  <<Text/binary, _data/binary>>);
decode_last_query_els([_ | _els], Text) ->
    decode_last_query_els(_els, Text);
decode_last_query_els([], Text) ->
    decode_last_query_cdata(Text).

decode_last_query_attrs([{<<"seconds">>, _val}
			 | _attrs],
			_Seconds) ->
    decode_last_query_attrs(_attrs, _val);
decode_last_query_attrs([_ | _attrs], Seconds) ->
    decode_last_query_attrs(_attrs, Seconds);
decode_last_query_attrs([], Seconds) ->
    decode_last_query_seconds(Seconds).

encode_last_query(undefined, _acc) -> _acc;
encode_last_query({last, Seconds, Text}, _acc) ->
    _els = encode_last_query_cdata(Text, []),
    _attrs = encode_last_query_seconds(Seconds,
				       [{<<"xmlns">>, <<"jabber:iq:last">>}]),
    [{xmlel, <<"query">>, _attrs, _els} | _acc].

decode_last_query_seconds(<<>>) -> undefined;
decode_last_query_seconds(_val) ->
    case catch xml_gen:dec_int(_val, 0, infinity) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"seconds">>,
			<<"query">>, <<"jabber:iq:last">>});
      _res -> _res
    end.

encode_last_query_seconds(undefined, _acc) -> _acc;
encode_last_query_seconds(_val, _acc) ->
    [{<<"seconds">>, xml_gen:enc_int(_val)} | _acc].

decode_last_query_cdata(<<>>) -> undefined;
decode_last_query_cdata(_val) -> _val.

encode_last_query_cdata(undefined, _acc) -> _acc;
encode_last_query_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_version_query({xmlel, _, _attrs, _els}) ->
    {Os, Version, Name} = decode_version_query_els(_els,
						   undefined, undefined,
						   undefined),
    {version, Name, Version, Os}.

decode_version_query_els([{xmlel, <<"os">>, _attrs, _} =
			      _el
			  | _els],
			 Os, Version, Name) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_version_query_els(_els,
				   decode_version_query_os(_el), Version, Name);
      _ -> decode_version_query_els(_els, Os, Version, Name)
    end;
decode_version_query_els([{xmlel, <<"version">>, _attrs,
			   _} =
			      _el
			  | _els],
			 Os, Version, Name) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_version_query_els(_els, Os,
				   decode_version_query_version(_el), Name);
      _ -> decode_version_query_els(_els, Os, Version, Name)
    end;
decode_version_query_els([{xmlel, <<"name">>, _attrs,
			   _} =
			      _el
			  | _els],
			 Os, Version, Name) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_version_query_els(_els, Os, Version,
				   decode_version_query_name(_el));
      _ -> decode_version_query_els(_els, Os, Version, Name)
    end;
decode_version_query_els([_ | _els], Os, Version,
			 Name) ->
    decode_version_query_els(_els, Os, Version, Name);
decode_version_query_els([], Os, Version, Name) ->
    {Os, Version, Name}.

encode_version_query(undefined, _acc) -> _acc;
encode_version_query({version, Name, Version, Os},
		     _acc) ->
    _els = encode_version_query_name(Name,
				     encode_version_query_version(Version,
								  encode_version_query_os(Os,
											  []))),
    _attrs = [{<<"xmlns">>, <<"jabber:iq:version">>}],
    [{xmlel, <<"query">>, _attrs, _els} | _acc].

decode_version_query_cdata(<<>>) -> undefined;
decode_version_query_cdata(_val) -> _val.

encode_version_query_cdata(undefined, _acc) -> _acc;
encode_version_query_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_version_query_os({xmlel, _, _attrs, _els}) ->
    Cdata = decode_version_query_os_els(_els, <<>>), Cdata.

decode_version_query_os_els([{xmlcdata, _data} | _els],
			    Cdata) ->
    decode_version_query_os_els(_els,
				<<Cdata/binary, _data/binary>>);
decode_version_query_os_els([_ | _els], Cdata) ->
    decode_version_query_os_els(_els, Cdata);
decode_version_query_os_els([], Cdata) ->
    decode_version_query_os_cdata(Cdata).

encode_version_query_os(undefined, _acc) -> _acc;
encode_version_query_os(Cdata, _acc) ->
    _els = encode_version_query_os_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"os">>, _attrs, _els} | _acc].

decode_version_query_os_cdata(<<>>) ->
    erlang:error({missing_cdata, <<>>, <<"os">>, <<>>});
decode_version_query_os_cdata(_val) -> _val.

encode_version_query_os_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_version_query_version({xmlel, _, _attrs,
			      _els}) ->
    Cdata = decode_version_query_version_els(_els, <<>>),
    Cdata.

decode_version_query_version_els([{xmlcdata, _data}
				  | _els],
				 Cdata) ->
    decode_version_query_version_els(_els,
				     <<Cdata/binary, _data/binary>>);
decode_version_query_version_els([_ | _els], Cdata) ->
    decode_version_query_version_els(_els, Cdata);
decode_version_query_version_els([], Cdata) ->
    decode_version_query_version_cdata(Cdata).

encode_version_query_version(undefined, _acc) -> _acc;
encode_version_query_version(Cdata, _acc) ->
    _els = encode_version_query_version_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"version">>, _attrs, _els} | _acc].

decode_version_query_version_cdata(<<>>) ->
    erlang:error({missing_cdata, <<>>, <<"version">>,
		  <<>>});
decode_version_query_version_cdata(_val) -> _val.

encode_version_query_version_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_version_query_name({xmlel, _, _attrs, _els}) ->
    Cdata = decode_version_query_name_els(_els, <<>>),
    Cdata.

decode_version_query_name_els([{xmlcdata, _data}
			       | _els],
			      Cdata) ->
    decode_version_query_name_els(_els,
				  <<Cdata/binary, _data/binary>>);
decode_version_query_name_els([_ | _els], Cdata) ->
    decode_version_query_name_els(_els, Cdata);
decode_version_query_name_els([], Cdata) ->
    decode_version_query_name_cdata(Cdata).

encode_version_query_name(undefined, _acc) -> _acc;
encode_version_query_name(Cdata, _acc) ->
    _els = encode_version_query_name_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"name">>, _attrs, _els} | _acc].

decode_version_query_name_cdata(<<>>) ->
    erlang:error({missing_cdata, <<>>, <<"name">>, <<>>});
decode_version_query_name_cdata(_val) -> _val.

encode_version_query_name_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_roster_query({xmlel, _, _attrs, _els}) ->
    Ver = decode_roster_query_attrs(_attrs, <<>>),
    Item = decode_roster_query_els(_els, []),
    {roster, Item, Ver}.

decode_roster_query_els([{xmlel, <<"item">>, _attrs,
			  _} =
			     _el
			 | _els],
			Item) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_roster_query_els(_els,
				  [decode_roster_query_item(_el) | Item]);
      _ -> decode_roster_query_els(_els, Item)
    end;
decode_roster_query_els([_ | _els], Item) ->
    decode_roster_query_els(_els, Item);
decode_roster_query_els([], Item) ->
    lists:reverse(Item).

decode_roster_query_attrs([{<<"ver">>, _val} | _attrs],
			  _Ver) ->
    decode_roster_query_attrs(_attrs, _val);
decode_roster_query_attrs([_ | _attrs], Ver) ->
    decode_roster_query_attrs(_attrs, Ver);
decode_roster_query_attrs([], Ver) ->
    decode_roster_query_ver(Ver).

encode_roster_query(undefined, _acc) -> _acc;
encode_roster_query({roster, Item, Ver}, _acc) ->
    _els = encode_roster_query_item(Item, []),
    _attrs = encode_roster_query_ver(Ver,
				     [{<<"xmlns">>, <<"jabber:iq:roster">>}]),
    [{xmlel, <<"query">>, _attrs, _els} | _acc].

decode_roster_query_ver(<<>>) -> undefined;
decode_roster_query_ver(_val) -> _val.

encode_roster_query_ver(undefined, _acc) -> _acc;
encode_roster_query_ver(_val, _acc) ->
    [{<<"ver">>, _val} | _acc].

decode_roster_query_cdata(<<>>) -> undefined;
decode_roster_query_cdata(_val) -> _val.

encode_roster_query_cdata(undefined, _acc) -> _acc;
encode_roster_query_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_roster_query_item({xmlel, _, _attrs, _els}) ->
    {Ask, Subscription, Name, Jid} =
	decode_roster_query_item_attrs(_attrs, <<>>, <<>>, <<>>,
				       <<>>),
    Groups = decode_roster_query_item_els(_els, []),
    {roster_item, Jid, Name, Groups, Subscription, Ask}.

decode_roster_query_item_els([{xmlel, <<"group">>,
			       _attrs, _} =
				  _el
			      | _els],
			     Groups) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_roster_query_item_els(_els,
				       [decode_roster_query_item_group(_el)
					| Groups]);
      _ -> decode_roster_query_item_els(_els, Groups)
    end;
decode_roster_query_item_els([_ | _els], Groups) ->
    decode_roster_query_item_els(_els, Groups);
decode_roster_query_item_els([], Groups) ->
    lists:reverse(Groups).

decode_roster_query_item_attrs([{<<"ask">>, _val}
				| _attrs],
			       _Ask, Subscription, Name, Jid) ->
    decode_roster_query_item_attrs(_attrs, _val,
				   Subscription, Name, Jid);
decode_roster_query_item_attrs([{<<"subscription">>,
				 _val}
				| _attrs],
			       Ask, _Subscription, Name, Jid) ->
    decode_roster_query_item_attrs(_attrs, Ask, _val, Name,
				   Jid);
decode_roster_query_item_attrs([{<<"name">>, _val}
				| _attrs],
			       Ask, Subscription, _Name, Jid) ->
    decode_roster_query_item_attrs(_attrs, Ask,
				   Subscription, _val, Jid);
decode_roster_query_item_attrs([{<<"jid">>, _val}
				| _attrs],
			       Ask, Subscription, Name, _Jid) ->
    decode_roster_query_item_attrs(_attrs, Ask,
				   Subscription, Name, _val);
decode_roster_query_item_attrs([_ | _attrs], Ask,
			       Subscription, Name, Jid) ->
    decode_roster_query_item_attrs(_attrs, Ask,
				   Subscription, Name, Jid);
decode_roster_query_item_attrs([], Ask, Subscription,
			       Name, Jid) ->
    {decode_roster_query_item_ask(Ask),
     decode_roster_query_item_subscription(Subscription),
     decode_roster_query_item_name(Name),
     decode_roster_query_item_jid(Jid)}.

encode_roster_query_item([], _acc) -> _acc;
encode_roster_query_item([{roster_item, Jid, Name,
			   Groups, Subscription, Ask}
			  | _tail],
			 _acc) ->
    _els = encode_roster_query_item_group(Groups, []),
    _attrs = encode_roster_query_item_jid(Jid,
					  encode_roster_query_item_name(Name,
									encode_roster_query_item_subscription(Subscription,
													      encode_roster_query_item_ask(Ask,
																	   [])))),
    encode_roster_query_item(_tail,
			     [{xmlel, <<"item">>, _attrs, _els} | _acc]).

decode_roster_query_item_jid(<<>>) ->
    erlang:error({missing_attr, <<"jid">>, <<"item">>,
		  <<>>});
decode_roster_query_item_jid(_val) -> _val.

encode_roster_query_item_jid(_val, _acc) ->
    [{<<"jid">>, _val} | _acc].

decode_roster_query_item_name(<<>>) -> undefined;
decode_roster_query_item_name(_val) -> _val.

encode_roster_query_item_name(undefined, _acc) -> _acc;
encode_roster_query_item_name(_val, _acc) ->
    [{<<"name">>, _val} | _acc].

decode_roster_query_item_subscription(<<>>) -> none;
decode_roster_query_item_subscription(_val) ->
    case catch xml_gen:dec_enum(_val,
				[none, to, from, both, remove])
	of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"subscription">>,
			<<"item">>, <<>>});
      _res -> _res
    end.

encode_roster_query_item_subscription(none, _acc) ->
    _acc;
encode_roster_query_item_subscription(_val, _acc) ->
    [{<<"subscription">>, xml_gen:enc_enum(_val)} | _acc].

decode_roster_query_item_ask(<<>>) -> undefined;
decode_roster_query_item_ask(_val) ->
    case catch xml_gen:dec_enum(_val, [subscribe]) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"ask">>, <<"item">>,
			<<>>});
      _res -> _res
    end.

encode_roster_query_item_ask(undefined, _acc) -> _acc;
encode_roster_query_item_ask(_val, _acc) ->
    [{<<"ask">>, xml_gen:enc_enum(_val)} | _acc].

decode_roster_query_item_cdata(<<>>) -> undefined;
decode_roster_query_item_cdata(_val) -> _val.

encode_roster_query_item_cdata(undefined, _acc) -> _acc;
encode_roster_query_item_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_roster_query_item_group({xmlel, _, _attrs,
				_els}) ->
    Cdata = decode_roster_query_item_group_els(_els, <<>>),
    Cdata.

decode_roster_query_item_group_els([{xmlcdata, _data}
				    | _els],
				   Cdata) ->
    decode_roster_query_item_group_els(_els,
				       <<Cdata/binary, _data/binary>>);
decode_roster_query_item_group_els([_ | _els], Cdata) ->
    decode_roster_query_item_group_els(_els, Cdata);
decode_roster_query_item_group_els([], Cdata) ->
    decode_roster_query_item_group_cdata(Cdata).

encode_roster_query_item_group([], _acc) -> _acc;
encode_roster_query_item_group([Cdata | _tail], _acc) ->
    _els = encode_roster_query_item_group_cdata(Cdata, []),
    _attrs = [],
    encode_roster_query_item_group(_tail,
				   [{xmlel, <<"group">>, _attrs, _els} | _acc]).

decode_roster_query_item_group_cdata(<<>>) ->
    erlang:error({missing_cdata, <<>>, <<"group">>, <<>>});
decode_roster_query_item_group_cdata(_val) -> _val.

encode_roster_query_item_group_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_privacy_item_item({xmlel, _, _attrs, _els}) ->
    {Value, Type, Action, Order} =
	decode_privacy_item_item_attrs(_attrs, <<>>, <<>>, <<>>,
				       <<>>),
    Stanza = decode_privacy_item_item_els(_els, undefined),
    {privacy_item, Order, Action, Type, Value, Stanza}.

decode_privacy_item_item_els([{xmlel,
			       <<"presence-out">>, _attrs, _} =
				  _el
			      | _els],
			     Stanza) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_privacy_item_item_els(_els,
				       'decode_privacy_item_item_presence-out'(_el));
      _ -> decode_privacy_item_item_els(_els, Stanza)
    end;
decode_privacy_item_item_els([{xmlel, <<"presence-in">>,
			       _attrs, _} =
				  _el
			      | _els],
			     Stanza) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_privacy_item_item_els(_els,
				       'decode_privacy_item_item_presence-in'(_el));
      _ -> decode_privacy_item_item_els(_els, Stanza)
    end;
decode_privacy_item_item_els([{xmlel, <<"iq">>, _attrs,
			       _} =
				  _el
			      | _els],
			     Stanza) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_privacy_item_item_els(_els,
				       decode_privacy_item_item_iq(_el));
      _ -> decode_privacy_item_item_els(_els, Stanza)
    end;
decode_privacy_item_item_els([{xmlel, <<"message">>,
			       _attrs, _} =
				  _el
			      | _els],
			     Stanza) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_privacy_item_item_els(_els,
				       decode_privacy_item_item_message(_el));
      _ -> decode_privacy_item_item_els(_els, Stanza)
    end;
decode_privacy_item_item_els([_ | _els], Stanza) ->
    decode_privacy_item_item_els(_els, Stanza);
decode_privacy_item_item_els([], Stanza) -> Stanza.

decode_privacy_item_item_attrs([{<<"value">>, _val}
				| _attrs],
			       _Value, Type, Action, Order) ->
    decode_privacy_item_item_attrs(_attrs, _val, Type,
				   Action, Order);
decode_privacy_item_item_attrs([{<<"type">>, _val}
				| _attrs],
			       Value, _Type, Action, Order) ->
    decode_privacy_item_item_attrs(_attrs, Value, _val,
				   Action, Order);
decode_privacy_item_item_attrs([{<<"action">>, _val}
				| _attrs],
			       Value, Type, _Action, Order) ->
    decode_privacy_item_item_attrs(_attrs, Value, Type,
				   _val, Order);
decode_privacy_item_item_attrs([{<<"order">>, _val}
				| _attrs],
			       Value, Type, Action, _Order) ->
    decode_privacy_item_item_attrs(_attrs, Value, Type,
				   Action, _val);
decode_privacy_item_item_attrs([_ | _attrs], Value,
			       Type, Action, Order) ->
    decode_privacy_item_item_attrs(_attrs, Value, Type,
				   Action, Order);
decode_privacy_item_item_attrs([], Value, Type, Action,
			       Order) ->
    {decode_privacy_item_item_value(Value),
     decode_privacy_item_item_type(Type),
     decode_privacy_item_item_action(Action),
     decode_privacy_item_item_order(Order)}.

'encode_privacy_item_item_$stanza'(undefined, _acc) ->
    _acc;
'encode_privacy_item_item_$stanza'('presence-out' = _r,
				   _acc) ->
    'encode_privacy_item_item_presence-out'(_r, _acc);
'encode_privacy_item_item_$stanza'('presence-in' = _r,
				   _acc) ->
    'encode_privacy_item_item_presence-in'(_r, _acc);
'encode_privacy_item_item_$stanza'(iq = _r, _acc) ->
    encode_privacy_item_item_iq(_r, _acc);
'encode_privacy_item_item_$stanza'(message = _r,
				   _acc) ->
    encode_privacy_item_item_message(_r, _acc).

encode_privacy_item_item([], _acc) -> _acc;
encode_privacy_item_item([{privacy_item, Order, Action,
			   Type, Value, Stanza}
			  | _tail],
			 _acc) ->
    _els = 'encode_privacy_item_item_$stanza'(Stanza, []),
    _attrs = encode_privacy_item_item_order(Order,
					    encode_privacy_item_item_action(Action,
									    encode_privacy_item_item_type(Type,
													  encode_privacy_item_item_value(Value,
																	 [])))),
    encode_privacy_item_item(_tail,
			     [{xmlel, <<"item">>, _attrs, _els} | _acc]).

decode_privacy_item_item_action(<<>>) ->
    erlang:error({missing_attr, <<"action">>, <<"item">>,
		  <<>>});
decode_privacy_item_item_action(_val) ->
    case catch xml_gen:dec_enum(_val, [allow, deny]) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"action">>, <<"item">>,
			<<>>});
      _res -> _res
    end.

encode_privacy_item_item_action(_val, _acc) ->
    [{<<"action">>, xml_gen:enc_enum(_val)} | _acc].

decode_privacy_item_item_order(<<>>) ->
    erlang:error({missing_attr, <<"order">>, <<"item">>,
		  <<>>});
decode_privacy_item_item_order(_val) ->
    case catch xml_gen:dec_int(_val, 0, infinity) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"order">>, <<"item">>,
			<<>>});
      _res -> _res
    end.

encode_privacy_item_item_order(_val, _acc) ->
    [{<<"order">>, xml_gen:enc_int(_val)} | _acc].

decode_privacy_item_item_type(<<>>) -> undefined;
decode_privacy_item_item_type(_val) ->
    case catch xml_gen:dec_enum(_val,
				[group, jid, subscription])
	of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"type">>, <<"item">>,
			<<>>});
      _res -> _res
    end.

encode_privacy_item_item_type(undefined, _acc) -> _acc;
encode_privacy_item_item_type(_val, _acc) ->
    [{<<"type">>, xml_gen:enc_enum(_val)} | _acc].

decode_privacy_item_item_value(<<>>) -> undefined;
decode_privacy_item_item_value(_val) -> _val.

encode_privacy_item_item_value(undefined, _acc) -> _acc;
encode_privacy_item_item_value(_val, _acc) ->
    [{<<"value">>, _val} | _acc].

decode_privacy_item_item_cdata(<<>>) -> undefined;
decode_privacy_item_item_cdata(_val) -> _val.

encode_privacy_item_item_cdata(undefined, _acc) -> _acc;
encode_privacy_item_item_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_privacy_item_item_presence-out'({xmlel, _,
					 _attrs, _els}) ->
    'presence-out'.

'encode_privacy_item_item_presence-out'(undefined,
					_acc) ->
    _acc;
'encode_privacy_item_item_presence-out'('presence-out',
					_acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"presence-out">>, _attrs, _els} | _acc].

'decode_privacy_item_item_presence-out_cdata'(<<>>) ->
    undefined;
'decode_privacy_item_item_presence-out_cdata'(_val) ->
    _val.

'encode_privacy_item_item_presence-out_cdata'(undefined,
					      _acc) ->
    _acc;
'encode_privacy_item_item_presence-out_cdata'(_val,
					      _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_privacy_item_item_presence-in'({xmlel, _,
					_attrs, _els}) ->
    'presence-in'.

'encode_privacy_item_item_presence-in'(undefined,
				       _acc) ->
    _acc;
'encode_privacy_item_item_presence-in'('presence-in',
				       _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"presence-in">>, _attrs, _els} | _acc].

'decode_privacy_item_item_presence-in_cdata'(<<>>) ->
    undefined;
'decode_privacy_item_item_presence-in_cdata'(_val) ->
    _val.

'encode_privacy_item_item_presence-in_cdata'(undefined,
					     _acc) ->
    _acc;
'encode_privacy_item_item_presence-in_cdata'(_val,
					     _acc) ->
    [{xmlcdata, _val} | _acc].

decode_privacy_item_item_iq({xmlel, _, _attrs, _els}) ->
    iq.

encode_privacy_item_item_iq(undefined, _acc) -> _acc;
encode_privacy_item_item_iq(iq, _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"iq">>, _attrs, _els} | _acc].

decode_privacy_item_item_iq_cdata(<<>>) -> undefined;
decode_privacy_item_item_iq_cdata(_val) -> _val.

encode_privacy_item_item_iq_cdata(undefined, _acc) ->
    _acc;
encode_privacy_item_item_iq_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_privacy_item_item_message({xmlel, _, _attrs,
				  _els}) ->
    message.

encode_privacy_item_item_message(undefined, _acc) ->
    _acc;
encode_privacy_item_item_message(message, _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"message">>, _attrs, _els} | _acc].

decode_privacy_item_item_message_cdata(<<>>) ->
    undefined;
decode_privacy_item_item_message_cdata(_val) -> _val.

encode_privacy_item_item_message_cdata(undefined,
				       _acc) ->
    _acc;
encode_privacy_item_item_message_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_privacy_query({xmlel, _, _attrs, _els}) ->
    {Active, Default, List} = decode_privacy_query_els(_els,
						       undefined, undefined,
						       []),
    {privacy, List, Default, Active}.

decode_privacy_query_els([{xmlel, <<"active">>, _attrs,
			   _} =
			      _el
			  | _els],
			 Active, Default, List) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_privacy_query_els(_els,
				   decode_privacy_query_active(_el), Default,
				   List);
      _ ->
	  decode_privacy_query_els(_els, Active, Default, List)
    end;
decode_privacy_query_els([{xmlel, <<"default">>, _attrs,
			   _} =
			      _el
			  | _els],
			 Active, Default, List) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_privacy_query_els(_els, Active,
				   decode_privacy_query_default(_el), List);
      _ ->
	  decode_privacy_query_els(_els, Active, Default, List)
    end;
decode_privacy_query_els([{xmlel, <<"list">>, _attrs,
			   _} =
			      _el
			  | _els],
			 Active, Default, List) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_privacy_query_els(_els, Active, Default,
				   [decode_privacy_query_list(_el) | List]);
      _ ->
	  decode_privacy_query_els(_els, Active, Default, List)
    end;
decode_privacy_query_els([_ | _els], Active, Default,
			 List) ->
    decode_privacy_query_els(_els, Active, Default, List);
decode_privacy_query_els([], Active, Default, List) ->
    {Active, Default, lists:reverse(List)}.

encode_privacy_query(undefined, _acc) -> _acc;
encode_privacy_query({privacy, List, Default, Active},
		     _acc) ->
    _els = encode_privacy_query_list(List,
				     encode_privacy_query_default(Default,
								  encode_privacy_query_active(Active,
											      []))),
    _attrs = [{<<"xmlns">>, <<"jabber:iq:privacy">>}],
    [{xmlel, <<"query">>, _attrs, _els} | _acc].

decode_privacy_query_cdata(<<>>) -> undefined;
decode_privacy_query_cdata(_val) -> _val.

encode_privacy_query_cdata(undefined, _acc) -> _acc;
encode_privacy_query_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_privacy_query_active({xmlel, _, _attrs, _els}) ->
    Name = decode_privacy_query_active_attrs(_attrs, <<>>),
    Name.

decode_privacy_query_active_attrs([{<<"name">>, _val}
				   | _attrs],
				  _Name) ->
    decode_privacy_query_active_attrs(_attrs, _val);
decode_privacy_query_active_attrs([_ | _attrs], Name) ->
    decode_privacy_query_active_attrs(_attrs, Name);
decode_privacy_query_active_attrs([], Name) ->
    decode_privacy_query_active_name(Name).

encode_privacy_query_active(undefined, _acc) -> _acc;
encode_privacy_query_active(Name, _acc) ->
    _els = [],
    _attrs = encode_privacy_query_active_name(Name, []),
    [{xmlel, <<"active">>, _attrs, _els} | _acc].

decode_privacy_query_active_name(<<>>) -> none;
decode_privacy_query_active_name(_val) -> _val.

encode_privacy_query_active_name(none, _acc) -> _acc;
encode_privacy_query_active_name(_val, _acc) ->
    [{<<"name">>, _val} | _acc].

decode_privacy_query_active_cdata(<<>>) -> undefined;
decode_privacy_query_active_cdata(_val) -> _val.

encode_privacy_query_active_cdata(undefined, _acc) ->
    _acc;
encode_privacy_query_active_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_privacy_query_default({xmlel, _, _attrs,
			      _els}) ->
    Name = decode_privacy_query_default_attrs(_attrs, <<>>),
    Name.

decode_privacy_query_default_attrs([{<<"name">>, _val}
				    | _attrs],
				   _Name) ->
    decode_privacy_query_default_attrs(_attrs, _val);
decode_privacy_query_default_attrs([_ | _attrs],
				   Name) ->
    decode_privacy_query_default_attrs(_attrs, Name);
decode_privacy_query_default_attrs([], Name) ->
    decode_privacy_query_default_name(Name).

encode_privacy_query_default(undefined, _acc) -> _acc;
encode_privacy_query_default(Name, _acc) ->
    _els = [],
    _attrs = encode_privacy_query_default_name(Name, []),
    [{xmlel, <<"default">>, _attrs, _els} | _acc].

decode_privacy_query_default_name(<<>>) -> none;
decode_privacy_query_default_name(_val) -> _val.

encode_privacy_query_default_name(none, _acc) -> _acc;
encode_privacy_query_default_name(_val, _acc) ->
    [{<<"name">>, _val} | _acc].

decode_privacy_query_default_cdata(<<>>) -> undefined;
decode_privacy_query_default_cdata(_val) -> _val.

encode_privacy_query_default_cdata(undefined, _acc) ->
    _acc;
encode_privacy_query_default_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_privacy_query_list({xmlel, _, _attrs, _els}) ->
    Name = decode_privacy_query_list_attrs(_attrs, <<>>),
    Privacy_item = decode_privacy_query_list_els(_els, []),
    {privacy_list, Name, Privacy_item}.

decode_privacy_query_list_els([{xmlel, <<"item">>,
				_attrs, _} =
				   _el
			       | _els],
			      Privacy_item) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_privacy_query_list_els(_els,
					[decode_privacy_item_item(_el)
					 | Privacy_item]);
      _ -> decode_privacy_query_list_els(_els, Privacy_item)
    end;
decode_privacy_query_list_els([_ | _els],
			      Privacy_item) ->
    decode_privacy_query_list_els(_els, Privacy_item);
decode_privacy_query_list_els([], Privacy_item) ->
    lists:reverse(Privacy_item).

decode_privacy_query_list_attrs([{<<"name">>, _val}
				 | _attrs],
				_Name) ->
    decode_privacy_query_list_attrs(_attrs, _val);
decode_privacy_query_list_attrs([_ | _attrs], Name) ->
    decode_privacy_query_list_attrs(_attrs, Name);
decode_privacy_query_list_attrs([], Name) ->
    decode_privacy_query_list_name(Name).

encode_privacy_query_list([], _acc) -> _acc;
encode_privacy_query_list([{privacy_list, Name,
			    Privacy_item}
			   | _tail],
			  _acc) ->
    _els = encode_privacy_item_item(Privacy_item, []),
    _attrs = encode_privacy_query_list_name(Name, []),
    encode_privacy_query_list(_tail,
			      [{xmlel, <<"list">>, _attrs, _els} | _acc]).

decode_privacy_query_list_name(<<>>) ->
    erlang:error({missing_attr, <<"name">>, <<"list">>,
		  <<>>});
decode_privacy_query_list_name(_val) -> _val.

encode_privacy_query_list_name(_val, _acc) ->
    [{<<"name">>, _val} | _acc].

decode_privacy_query_list_cdata(<<>>) -> undefined;
decode_privacy_query_list_cdata(_val) -> _val.

encode_privacy_query_list_cdata(undefined, _acc) ->
    _acc;
encode_privacy_query_list_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_block_item_item({xmlel, _, _attrs, _els}) ->
    Jid = decode_block_item_item_attrs(_attrs, <<>>), Jid.

decode_block_item_item_attrs([{<<"jid">>, _val}
			      | _attrs],
			     _Jid) ->
    decode_block_item_item_attrs(_attrs, _val);
decode_block_item_item_attrs([_ | _attrs], Jid) ->
    decode_block_item_item_attrs(_attrs, Jid);
decode_block_item_item_attrs([], Jid) ->
    decode_block_item_item_jid(Jid).

encode_block_item_item([], _acc) -> _acc;
encode_block_item_item([Jid | _tail], _acc) ->
    _els = [],
    _attrs = encode_block_item_item_jid(Jid, []),
    encode_block_item_item(_tail,
			   [{xmlel, <<"item">>, _attrs, _els} | _acc]).

decode_block_item_item_jid(<<>>) ->
    erlang:error({missing_attr, <<"jid">>, <<"item">>,
		  <<>>});
decode_block_item_item_jid(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"jid">>, <<"item">>,
			<<>>});
      _res -> _res
    end.

encode_block_item_item_jid(_val, _acc) ->
    [{<<"jid">>, enc_jid(_val)} | _acc].

decode_block_item_item_cdata(<<>>) -> undefined;
decode_block_item_item_cdata(_val) -> _val.

encode_block_item_item_cdata(undefined, _acc) -> _acc;
encode_block_item_item_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_block_block({xmlel, _, _attrs, _els}) ->
    Block_item = decode_block_block_els(_els, []),
    {block, Block_item}.

decode_block_block_els([{xmlel, <<"item">>, _attrs, _} =
			    _el
			| _els],
		       Block_item) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_block_block_els(_els,
				 [decode_block_item_item(_el) | Block_item]);
      _ -> decode_block_block_els(_els, Block_item)
    end;
decode_block_block_els([_ | _els], Block_item) ->
    decode_block_block_els(_els, Block_item);
decode_block_block_els([], Block_item) ->
    lists:reverse(Block_item).

encode_block_block(undefined, _acc) -> _acc;
encode_block_block({block, Block_item}, _acc) ->
    _els = encode_block_item_item(Block_item, []),
    _attrs = [{<<"xmlns">>, <<"urn:xmpp:blocking">>}],
    [{xmlel, <<"block">>, _attrs, _els} | _acc].

decode_block_block_cdata(<<>>) -> undefined;
decode_block_block_cdata(_val) -> _val.

encode_block_block_cdata(undefined, _acc) -> _acc;
encode_block_block_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_unblock_unblock({xmlel, _, _attrs, _els}) ->
    Block_item = decode_unblock_unblock_els(_els, []),
    {unblock, Block_item}.

decode_unblock_unblock_els([{xmlel, <<"item">>, _attrs,
			     _} =
				_el
			    | _els],
			   Block_item) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_unblock_unblock_els(_els,
				     [decode_block_item_item(_el)
				      | Block_item]);
      _ -> decode_unblock_unblock_els(_els, Block_item)
    end;
decode_unblock_unblock_els([_ | _els], Block_item) ->
    decode_unblock_unblock_els(_els, Block_item);
decode_unblock_unblock_els([], Block_item) ->
    lists:reverse(Block_item).

encode_unblock_unblock(undefined, _acc) -> _acc;
encode_unblock_unblock({unblock, Block_item}, _acc) ->
    _els = encode_block_item_item(Block_item, []),
    _attrs = [{<<"xmlns">>, <<"urn:xmpp:blocking">>}],
    [{xmlel, <<"unblock">>, _attrs, _els} | _acc].

decode_unblock_unblock_cdata(<<>>) -> undefined;
decode_unblock_unblock_cdata(_val) -> _val.

encode_unblock_unblock_cdata(undefined, _acc) -> _acc;
encode_unblock_unblock_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_block_list_blocklist({xmlel, _, _attrs, _els}) ->
    {block_list}.

encode_block_list_blocklist(undefined, _acc) -> _acc;
encode_block_list_blocklist({block_list}, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>, <<"urn:xmpp:blocking">>}],
    [{xmlel, <<"blocklist">>, _attrs, _els} | _acc].

decode_block_list_blocklist_cdata(<<>>) -> undefined;
decode_block_list_blocklist_cdata(_val) -> _val.

encode_block_list_blocklist_cdata(undefined, _acc) ->
    _acc;
encode_block_list_blocklist_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_disco_info_query({xmlel, _, _attrs, _els}) ->
    Node = decode_disco_info_query_attrs(_attrs, <<>>),
    {Feature, Identity} = decode_disco_info_query_els(_els,
						      [], []),
    {disco_info, Node, Identity, Feature}.

decode_disco_info_query_els([{xmlel, <<"feature">>,
			      _attrs, _} =
				 _el
			     | _els],
			    Feature, Identity) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_disco_info_query_els(_els,
				      [decode_disco_info_query_feature(_el)
				       | Feature],
				      Identity);
      _ ->
	  decode_disco_info_query_els(_els, Feature, Identity)
    end;
decode_disco_info_query_els([{xmlel, <<"identity">>,
			      _attrs, _} =
				 _el
			     | _els],
			    Feature, Identity) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_disco_info_query_els(_els, Feature,
				      [decode_disco_info_query_identity(_el)
				       | Identity]);
      _ ->
	  decode_disco_info_query_els(_els, Feature, Identity)
    end;
decode_disco_info_query_els([_ | _els], Feature,
			    Identity) ->
    decode_disco_info_query_els(_els, Feature, Identity);
decode_disco_info_query_els([], Feature, Identity) ->
    {lists:reverse(Feature), lists:reverse(Identity)}.

decode_disco_info_query_attrs([{<<"node">>, _val}
			       | _attrs],
			      _Node) ->
    decode_disco_info_query_attrs(_attrs, _val);
decode_disco_info_query_attrs([_ | _attrs], Node) ->
    decode_disco_info_query_attrs(_attrs, Node);
decode_disco_info_query_attrs([], Node) ->
    decode_disco_info_query_node(Node).

encode_disco_info_query(undefined, _acc) -> _acc;
encode_disco_info_query({disco_info, Node, Identity,
			 Feature},
			_acc) ->
    _els = encode_disco_info_query_identity(Identity,
					    encode_disco_info_query_feature(Feature,
									    [])),
    _attrs = encode_disco_info_query_node(Node,
					  [{<<"xmlns">>,
					    <<"http://jabber.org/protocol/disco#info">>}]),
    [{xmlel, <<"query">>, _attrs, _els} | _acc].

decode_disco_info_query_node(<<>>) -> undefined;
decode_disco_info_query_node(_val) -> _val.

encode_disco_info_query_node(undefined, _acc) -> _acc;
encode_disco_info_query_node(_val, _acc) ->
    [{<<"node">>, _val} | _acc].

decode_disco_info_query_cdata(<<>>) -> undefined;
decode_disco_info_query_cdata(_val) -> _val.

encode_disco_info_query_cdata(undefined, _acc) -> _acc;
encode_disco_info_query_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_disco_info_query_feature({xmlel, _, _attrs,
				 _els}) ->
    Var = decode_disco_info_query_feature_attrs(_attrs,
						<<>>),
    Var.

decode_disco_info_query_feature_attrs([{<<"var">>, _val}
				       | _attrs],
				      _Var) ->
    decode_disco_info_query_feature_attrs(_attrs, _val);
decode_disco_info_query_feature_attrs([_ | _attrs],
				      Var) ->
    decode_disco_info_query_feature_attrs(_attrs, Var);
decode_disco_info_query_feature_attrs([], Var) ->
    decode_disco_info_query_feature_var(Var).

encode_disco_info_query_feature([], _acc) -> _acc;
encode_disco_info_query_feature([Var | _tail], _acc) ->
    _els = [],
    _attrs = encode_disco_info_query_feature_var(Var, []),
    encode_disco_info_query_feature(_tail,
				    [{xmlel, <<"feature">>, _attrs, _els}
				     | _acc]).

decode_disco_info_query_feature_var(<<>>) ->
    erlang:error({missing_attr, <<"var">>, <<"feature">>,
		  <<>>});
decode_disco_info_query_feature_var(_val) -> _val.

encode_disco_info_query_feature_var(_val, _acc) ->
    [{<<"var">>, _val} | _acc].

decode_disco_info_query_feature_cdata(<<>>) ->
    undefined;
decode_disco_info_query_feature_cdata(_val) -> _val.

encode_disco_info_query_feature_cdata(undefined,
				      _acc) ->
    _acc;
encode_disco_info_query_feature_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_disco_info_query_identity({xmlel, _, _attrs,
				  _els}) ->
    {Name, Type, Category} =
	decode_disco_info_query_identity_attrs(_attrs, <<>>,
					       <<>>, <<>>),
    {Category, Type, Name}.

decode_disco_info_query_identity_attrs([{<<"name">>,
					 _val}
					| _attrs],
				       _Name, Type, Category) ->
    decode_disco_info_query_identity_attrs(_attrs, _val,
					   Type, Category);
decode_disco_info_query_identity_attrs([{<<"type">>,
					 _val}
					| _attrs],
				       Name, _Type, Category) ->
    decode_disco_info_query_identity_attrs(_attrs, Name,
					   _val, Category);
decode_disco_info_query_identity_attrs([{<<"category">>,
					 _val}
					| _attrs],
				       Name, Type, _Category) ->
    decode_disco_info_query_identity_attrs(_attrs, Name,
					   Type, _val);
decode_disco_info_query_identity_attrs([_ | _attrs],
				       Name, Type, Category) ->
    decode_disco_info_query_identity_attrs(_attrs, Name,
					   Type, Category);
decode_disco_info_query_identity_attrs([], Name, Type,
				       Category) ->
    {decode_disco_info_query_identity_name(Name),
     decode_disco_info_query_identity_type(Type),
     decode_disco_info_query_identity_category(Category)}.

encode_disco_info_query_identity([], _acc) -> _acc;
encode_disco_info_query_identity([{Category, Type, Name}
				  | _tail],
				 _acc) ->
    _els = [],
    _attrs =
	encode_disco_info_query_identity_category(Category,
						  encode_disco_info_query_identity_type(Type,
											encode_disco_info_query_identity_name(Name,
															      []))),
    encode_disco_info_query_identity(_tail,
				     [{xmlel, <<"identity">>, _attrs, _els}
				      | _acc]).

decode_disco_info_query_identity_category(<<>>) ->
    erlang:error({missing_attr, <<"category">>,
		  <<"identity">>, <<>>});
decode_disco_info_query_identity_category(_val) -> _val.

encode_disco_info_query_identity_category(_val, _acc) ->
    [{<<"category">>, _val} | _acc].

decode_disco_info_query_identity_type(<<>>) ->
    erlang:error({missing_attr, <<"type">>, <<"identity">>,
		  <<>>});
decode_disco_info_query_identity_type(_val) -> _val.

encode_disco_info_query_identity_type(_val, _acc) ->
    [{<<"type">>, _val} | _acc].

decode_disco_info_query_identity_name(<<>>) ->
    undefined;
decode_disco_info_query_identity_name(_val) -> _val.

encode_disco_info_query_identity_name(undefined,
				      _acc) ->
    _acc;
encode_disco_info_query_identity_name(_val, _acc) ->
    [{<<"name">>, _val} | _acc].

decode_disco_info_query_identity_cdata(<<>>) ->
    undefined;
decode_disco_info_query_identity_cdata(_val) -> _val.

encode_disco_info_query_identity_cdata(undefined,
				       _acc) ->
    _acc;
encode_disco_info_query_identity_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_disco_items_query({xmlel, _, _attrs, _els}) ->
    Node = decode_disco_items_query_attrs(_attrs, <<>>),
    Items = decode_disco_items_query_els(_els, []),
    {disco_items, Node, Items}.

decode_disco_items_query_els([{xmlel, <<"item">>,
			       _attrs, _} =
				  _el
			      | _els],
			     Items) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_disco_items_query_els(_els,
				       [decode_disco_items_query_item(_el)
					| Items]);
      _ -> decode_disco_items_query_els(_els, Items)
    end;
decode_disco_items_query_els([_ | _els], Items) ->
    decode_disco_items_query_els(_els, Items);
decode_disco_items_query_els([], Items) ->
    lists:reverse(Items).

decode_disco_items_query_attrs([{<<"node">>, _val}
				| _attrs],
			       _Node) ->
    decode_disco_items_query_attrs(_attrs, _val);
decode_disco_items_query_attrs([_ | _attrs], Node) ->
    decode_disco_items_query_attrs(_attrs, Node);
decode_disco_items_query_attrs([], Node) ->
    decode_disco_items_query_node(Node).

encode_disco_items_query(undefined, _acc) -> _acc;
encode_disco_items_query({disco_items, Node, Items},
			 _acc) ->
    _els = encode_disco_items_query_item(Items, []),
    _attrs = encode_disco_items_query_node(Node,
					   [{<<"xmlns">>,
					     <<"http://jabber.org/protocol/disco#items">>}]),
    [{xmlel, <<"query">>, _attrs, _els} | _acc].

decode_disco_items_query_node(<<>>) -> undefined;
decode_disco_items_query_node(_val) -> _val.

encode_disco_items_query_node(undefined, _acc) -> _acc;
encode_disco_items_query_node(_val, _acc) ->
    [{<<"node">>, _val} | _acc].

decode_disco_items_query_cdata(<<>>) -> undefined;
decode_disco_items_query_cdata(_val) -> _val.

encode_disco_items_query_cdata(undefined, _acc) -> _acc;
encode_disco_items_query_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_disco_items_query_item({xmlel, _, _attrs,
			       _els}) ->
    {Node, Name, Jid} =
	decode_disco_items_query_item_attrs(_attrs, <<>>, <<>>,
					    <<>>),
    {disco_item, Jid, Name, Node}.

decode_disco_items_query_item_attrs([{<<"node">>, _val}
				     | _attrs],
				    _Node, Name, Jid) ->
    decode_disco_items_query_item_attrs(_attrs, _val, Name,
					Jid);
decode_disco_items_query_item_attrs([{<<"name">>, _val}
				     | _attrs],
				    Node, _Name, Jid) ->
    decode_disco_items_query_item_attrs(_attrs, Node, _val,
					Jid);
decode_disco_items_query_item_attrs([{<<"jid">>, _val}
				     | _attrs],
				    Node, Name, _Jid) ->
    decode_disco_items_query_item_attrs(_attrs, Node, Name,
					_val);
decode_disco_items_query_item_attrs([_ | _attrs], Node,
				    Name, Jid) ->
    decode_disco_items_query_item_attrs(_attrs, Node, Name,
					Jid);
decode_disco_items_query_item_attrs([], Node, Name,
				    Jid) ->
    {decode_disco_items_query_item_node(Node),
     decode_disco_items_query_item_name(Name),
     decode_disco_items_query_item_jid(Jid)}.

encode_disco_items_query_item([], _acc) -> _acc;
encode_disco_items_query_item([{disco_item, Jid, Name,
				Node}
			       | _tail],
			      _acc) ->
    _els = [],
    _attrs = encode_disco_items_query_item_jid(Jid,
					       encode_disco_items_query_item_name(Name,
										  encode_disco_items_query_item_node(Node,
														     []))),
    encode_disco_items_query_item(_tail,
				  [{xmlel, <<"item">>, _attrs, _els} | _acc]).

decode_disco_items_query_item_jid(<<>>) ->
    erlang:error({missing_attr, <<"jid">>, <<"item">>,
		  <<>>});
decode_disco_items_query_item_jid(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"jid">>, <<"item">>,
			<<>>});
      _res -> _res
    end.

encode_disco_items_query_item_jid(_val, _acc) ->
    [{<<"jid">>, enc_jid(_val)} | _acc].

decode_disco_items_query_item_name(<<>>) -> undefined;
decode_disco_items_query_item_name(_val) -> _val.

encode_disco_items_query_item_name(undefined, _acc) ->
    _acc;
encode_disco_items_query_item_name(_val, _acc) ->
    [{<<"name">>, _val} | _acc].

decode_disco_items_query_item_node(<<>>) -> undefined;
decode_disco_items_query_item_node(_val) -> _val.

encode_disco_items_query_item_node(undefined, _acc) ->
    _acc;
encode_disco_items_query_item_node(_val, _acc) ->
    [{<<"node">>, _val} | _acc].

decode_disco_items_query_item_cdata(<<>>) -> undefined;
decode_disco_items_query_item_cdata(_val) -> _val.

encode_disco_items_query_item_cdata(undefined, _acc) ->
    _acc;
encode_disco_items_query_item_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_private_query({xmlel, _, _attrs, _els}) ->
    __Els = decode_private_query_els(_els, []),
    {private, __Els}.

decode_private_query_els([{xmlel, _, _, _} = _el
			  | _els],
			 __Els) ->
    decode_private_query_els(_els, [decode(_el) | __Els]);
decode_private_query_els([_ | _els], __Els) ->
    decode_private_query_els(_els, __Els);
decode_private_query_els([], __Els) ->
    lists:reverse(__Els).

encode_private_query(undefined, _acc) -> _acc;
encode_private_query({private, __Els}, _acc) ->
    _els = [encode(_subel) || _subel <- __Els] ++ [],
    _attrs = [{<<"xmlns">>, <<"jabber:iq:private">>}],
    [{xmlel, <<"query">>, _attrs, _els} | _acc].

decode_private_query_cdata(<<>>) -> undefined;
decode_private_query_cdata(_val) -> _val.

encode_private_query_cdata(undefined, _acc) -> _acc;
encode_private_query_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_storage_bookmarks_storage({xmlel, _, _attrs,
				  _els}) ->
    {Url, Conference} =
	decode_storage_bookmarks_storage_els(_els, [], []),
    {bookmark_storage, Conference, Url}.

decode_storage_bookmarks_storage_els([{xmlel, <<"url">>,
				       _attrs, _} =
					  _el
				      | _els],
				     Url, Conference) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_storage_bookmarks_storage_els(_els,
					       [decode_storage_bookmarks_storage_url(_el)
						| Url],
					       Conference);
      _ ->
	  decode_storage_bookmarks_storage_els(_els, Url,
					       Conference)
    end;
decode_storage_bookmarks_storage_els([{xmlel,
				       <<"conference">>, _attrs, _} =
					  _el
				      | _els],
				     Url, Conference) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_storage_bookmarks_storage_els(_els, Url,
					       [decode_storage_bookmarks_storage_conference(_el)
						| Conference]);
      _ ->
	  decode_storage_bookmarks_storage_els(_els, Url,
					       Conference)
    end;
decode_storage_bookmarks_storage_els([_ | _els], Url,
				     Conference) ->
    decode_storage_bookmarks_storage_els(_els, Url,
					 Conference);
decode_storage_bookmarks_storage_els([], Url,
				     Conference) ->
    {lists:reverse(Url), lists:reverse(Conference)}.

encode_storage_bookmarks_storage(undefined, _acc) ->
    _acc;
encode_storage_bookmarks_storage({bookmark_storage,
				  Conference, Url},
				 _acc) ->
    _els =
	encode_storage_bookmarks_storage_conference(Conference,
						    encode_storage_bookmarks_storage_url(Url,
											 [])),
    _attrs = [{<<"xmlns">>, <<"storage:bookmarks">>}],
    [{xmlel, <<"storage">>, _attrs, _els} | _acc].

decode_storage_bookmarks_storage_cdata(<<>>) ->
    undefined;
decode_storage_bookmarks_storage_cdata(_val) -> _val.

encode_storage_bookmarks_storage_cdata(undefined,
				       _acc) ->
    _acc;
encode_storage_bookmarks_storage_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_storage_bookmarks_storage_url({xmlel, _, _attrs,
				      _els}) ->
    {Url, Name} =
	decode_storage_bookmarks_storage_url_attrs(_attrs, <<>>,
						   <<>>),
    {bookmark_url, Name, Url}.

decode_storage_bookmarks_storage_url_attrs([{<<"url">>,
					     _val}
					    | _attrs],
					   _Url, Name) ->
    decode_storage_bookmarks_storage_url_attrs(_attrs, _val,
					       Name);
decode_storage_bookmarks_storage_url_attrs([{<<"name">>,
					     _val}
					    | _attrs],
					   Url, _Name) ->
    decode_storage_bookmarks_storage_url_attrs(_attrs, Url,
					       _val);
decode_storage_bookmarks_storage_url_attrs([_ | _attrs],
					   Url, Name) ->
    decode_storage_bookmarks_storage_url_attrs(_attrs, Url,
					       Name);
decode_storage_bookmarks_storage_url_attrs([], Url,
					   Name) ->
    {decode_storage_bookmarks_storage_url_url(Url),
     decode_storage_bookmarks_storage_url_name(Name)}.

encode_storage_bookmarks_storage_url([], _acc) -> _acc;
encode_storage_bookmarks_storage_url([{bookmark_url,
				       Name, Url}
				      | _tail],
				     _acc) ->
    _els = [],
    _attrs = encode_storage_bookmarks_storage_url_name(Name,
						       encode_storage_bookmarks_storage_url_url(Url,
												[])),
    encode_storage_bookmarks_storage_url(_tail,
					 [{xmlel, <<"url">>, _attrs, _els}
					  | _acc]).

decode_storage_bookmarks_storage_url_name(<<>>) ->
    erlang:error({missing_attr, <<"name">>, <<"url">>,
		  <<>>});
decode_storage_bookmarks_storage_url_name(_val) -> _val.

encode_storage_bookmarks_storage_url_name(_val, _acc) ->
    [{<<"name">>, _val} | _acc].

decode_storage_bookmarks_storage_url_url(<<>>) ->
    erlang:error({missing_attr, <<"url">>, <<"url">>,
		  <<>>});
decode_storage_bookmarks_storage_url_url(_val) -> _val.

encode_storage_bookmarks_storage_url_url(_val, _acc) ->
    [{<<"url">>, _val} | _acc].

decode_storage_bookmarks_storage_url_cdata(<<>>) ->
    undefined;
decode_storage_bookmarks_storage_url_cdata(_val) ->
    _val.

encode_storage_bookmarks_storage_url_cdata(undefined,
					   _acc) ->
    _acc;
encode_storage_bookmarks_storage_url_cdata(_val,
					   _acc) ->
    [{xmlcdata, _val} | _acc].

decode_storage_bookmarks_storage_conference({xmlel, _,
					     _attrs, _els}) ->
    {Autojoin, Jid, Name} =
	decode_storage_bookmarks_storage_conference_attrs(_attrs,
							  <<>>, <<>>, <<>>),
    {Password, Nick} =
	decode_storage_bookmarks_storage_conference_els(_els,
							undefined, undefined),
    {bookmark_conference, Name, Jid, Autojoin, Nick,
     Password}.

decode_storage_bookmarks_storage_conference_els([{xmlel,
						  <<"password">>, _attrs, _} =
						     _el
						 | _els],
						Password, Nick) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_storage_bookmarks_storage_conference_els(_els,
							  decode_storage_bookmarks_storage_conference_password(_el),
							  Nick);
      _ ->
	  decode_storage_bookmarks_storage_conference_els(_els,
							  Password, Nick)
    end;
decode_storage_bookmarks_storage_conference_els([{xmlel,
						  <<"nick">>, _attrs, _} =
						     _el
						 | _els],
						Password, Nick) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_storage_bookmarks_storage_conference_els(_els,
							  Password,
							  decode_storage_bookmarks_storage_conference_nick(_el));
      _ ->
	  decode_storage_bookmarks_storage_conference_els(_els,
							  Password, Nick)
    end;
decode_storage_bookmarks_storage_conference_els([_
						 | _els],
						Password, Nick) ->
    decode_storage_bookmarks_storage_conference_els(_els,
						    Password, Nick);
decode_storage_bookmarks_storage_conference_els([],
						Password, Nick) ->
    {Password, Nick}.

decode_storage_bookmarks_storage_conference_attrs([{<<"autojoin">>,
						    _val}
						   | _attrs],
						  _Autojoin, Jid, Name) ->
    decode_storage_bookmarks_storage_conference_attrs(_attrs,
						      _val, Jid, Name);
decode_storage_bookmarks_storage_conference_attrs([{<<"jid">>,
						    _val}
						   | _attrs],
						  Autojoin, _Jid, Name) ->
    decode_storage_bookmarks_storage_conference_attrs(_attrs,
						      Autojoin, _val, Name);
decode_storage_bookmarks_storage_conference_attrs([{<<"name">>,
						    _val}
						   | _attrs],
						  Autojoin, Jid, _Name) ->
    decode_storage_bookmarks_storage_conference_attrs(_attrs,
						      Autojoin, Jid, _val);
decode_storage_bookmarks_storage_conference_attrs([_
						   | _attrs],
						  Autojoin, Jid, Name) ->
    decode_storage_bookmarks_storage_conference_attrs(_attrs,
						      Autojoin, Jid, Name);
decode_storage_bookmarks_storage_conference_attrs([],
						  Autojoin, Jid, Name) ->
    {decode_storage_bookmarks_storage_conference_autojoin(Autojoin),
     decode_storage_bookmarks_storage_conference_jid(Jid),
     decode_storage_bookmarks_storage_conference_name(Name)}.

encode_storage_bookmarks_storage_conference([], _acc) ->
    _acc;
encode_storage_bookmarks_storage_conference([{bookmark_conference,
					      Name, Jid, Autojoin, Nick,
					      Password}
					     | _tail],
					    _acc) ->
    _els =
	encode_storage_bookmarks_storage_conference_nick(Nick,
							 encode_storage_bookmarks_storage_conference_password(Password,
													      [])),
    _attrs =
	encode_storage_bookmarks_storage_conference_name(Name,
							 encode_storage_bookmarks_storage_conference_jid(Jid,
													 encode_storage_bookmarks_storage_conference_autojoin(Autojoin,
																			      []))),
    encode_storage_bookmarks_storage_conference(_tail,
						[{xmlel, <<"conference">>,
						  _attrs, _els}
						 | _acc]).

decode_storage_bookmarks_storage_conference_name(<<>>) ->
    erlang:error({missing_attr, <<"name">>,
		  <<"conference">>, <<>>});
decode_storage_bookmarks_storage_conference_name(_val) ->
    _val.

encode_storage_bookmarks_storage_conference_name(_val,
						 _acc) ->
    [{<<"name">>, _val} | _acc].

decode_storage_bookmarks_storage_conference_jid(<<>>) ->
    erlang:error({missing_attr, <<"jid">>, <<"conference">>,
		  <<>>});
decode_storage_bookmarks_storage_conference_jid(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"jid">>,
			<<"conference">>, <<>>});
      _res -> _res
    end.

encode_storage_bookmarks_storage_conference_jid(_val,
						_acc) ->
    [{<<"jid">>, enc_jid(_val)} | _acc].

decode_storage_bookmarks_storage_conference_autojoin(<<>>) ->
    false;
decode_storage_bookmarks_storage_conference_autojoin(_val) ->
    case catch dec_bool(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"autojoin">>,
			<<"conference">>, <<>>});
      _res -> _res
    end.

encode_storage_bookmarks_storage_conference_autojoin(false,
						     _acc) ->
    _acc;
encode_storage_bookmarks_storage_conference_autojoin(_val,
						     _acc) ->
    [{<<"autojoin">>, enc_bool(_val)} | _acc].

decode_storage_bookmarks_storage_conference_cdata(<<>>) ->
    undefined;
decode_storage_bookmarks_storage_conference_cdata(_val) ->
    _val.

encode_storage_bookmarks_storage_conference_cdata(undefined,
						  _acc) ->
    _acc;
encode_storage_bookmarks_storage_conference_cdata(_val,
						  _acc) ->
    [{xmlcdata, _val} | _acc].

decode_storage_bookmarks_storage_conference_password({xmlel,
						      _, _attrs, _els}) ->
    Cdata =
	decode_storage_bookmarks_storage_conference_password_els(_els,
								 <<>>),
    Cdata.

decode_storage_bookmarks_storage_conference_password_els([{xmlcdata,
							   _data}
							  | _els],
							 Cdata) ->
    decode_storage_bookmarks_storage_conference_password_els(_els,
							     <<Cdata/binary,
							       _data/binary>>);
decode_storage_bookmarks_storage_conference_password_els([_
							  | _els],
							 Cdata) ->
    decode_storage_bookmarks_storage_conference_password_els(_els,
							     Cdata);
decode_storage_bookmarks_storage_conference_password_els([],
							 Cdata) ->
    decode_storage_bookmarks_storage_conference_password_cdata(Cdata).

encode_storage_bookmarks_storage_conference_password(undefined,
						     _acc) ->
    _acc;
encode_storage_bookmarks_storage_conference_password(Cdata,
						     _acc) ->
    _els =
	encode_storage_bookmarks_storage_conference_password_cdata(Cdata,
								   []),
    _attrs = [],
    [{xmlel, <<"password">>, _attrs, _els} | _acc].

decode_storage_bookmarks_storage_conference_password_cdata(<<>>) ->
    undefined;
decode_storage_bookmarks_storage_conference_password_cdata(_val) ->
    _val.

encode_storage_bookmarks_storage_conference_password_cdata(undefined,
							   _acc) ->
    _acc;
encode_storage_bookmarks_storage_conference_password_cdata(_val,
							   _acc) ->
    [{xmlcdata, _val} | _acc].

decode_storage_bookmarks_storage_conference_nick({xmlel,
						  _, _attrs, _els}) ->
    Cdata =
	decode_storage_bookmarks_storage_conference_nick_els(_els,
							     <<>>),
    Cdata.

decode_storage_bookmarks_storage_conference_nick_els([{xmlcdata,
						       _data}
						      | _els],
						     Cdata) ->
    decode_storage_bookmarks_storage_conference_nick_els(_els,
							 <<Cdata/binary,
							   _data/binary>>);
decode_storage_bookmarks_storage_conference_nick_els([_
						      | _els],
						     Cdata) ->
    decode_storage_bookmarks_storage_conference_nick_els(_els,
							 Cdata);
decode_storage_bookmarks_storage_conference_nick_els([],
						     Cdata) ->
    decode_storage_bookmarks_storage_conference_nick_cdata(Cdata).

encode_storage_bookmarks_storage_conference_nick(undefined,
						 _acc) ->
    _acc;
encode_storage_bookmarks_storage_conference_nick(Cdata,
						 _acc) ->
    _els =
	encode_storage_bookmarks_storage_conference_nick_cdata(Cdata,
							       []),
    _attrs = [],
    [{xmlel, <<"nick">>, _attrs, _els} | _acc].

decode_storage_bookmarks_storage_conference_nick_cdata(<<>>) ->
    undefined;
decode_storage_bookmarks_storage_conference_nick_cdata(_val) ->
    _val.

encode_storage_bookmarks_storage_conference_nick_cdata(undefined,
						       _acc) ->
    _acc;
encode_storage_bookmarks_storage_conference_nick_cdata(_val,
						       _acc) ->
    [{xmlcdata, _val} | _acc].

decode_stats_query({xmlel, _, _attrs, _els}) ->
    Stat = decode_stats_query_els(_els, []), {stats, Stat}.

decode_stats_query_els([{xmlel, <<"stat">>, _attrs, _} =
			    _el
			| _els],
		       Stat) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_stats_query_els(_els,
				 [decode_stats_query_stat(_el) | Stat]);
      _ -> decode_stats_query_els(_els, Stat)
    end;
decode_stats_query_els([_ | _els], Stat) ->
    decode_stats_query_els(_els, Stat);
decode_stats_query_els([], Stat) -> lists:reverse(Stat).

encode_stats_query(undefined, _acc) -> _acc;
encode_stats_query({stats, Stat}, _acc) ->
    _els = encode_stats_query_stat(Stat, []),
    _attrs = [{<<"xmlns">>,
	       <<"http://jabber.org/protocol/stats">>}],
    [{xmlel, <<"query">>, _attrs, _els} | _acc].

decode_stats_query_cdata(<<>>) -> undefined;
decode_stats_query_cdata(_val) -> _val.

encode_stats_query_cdata(undefined, _acc) -> _acc;
encode_stats_query_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_stats_query_stat({xmlel, _, _attrs, _els}) ->
    {Value, Units, Name} =
	decode_stats_query_stat_attrs(_attrs, <<>>, <<>>, <<>>),
    Error = decode_stats_query_stat_els(_els, []),
    {stat, Name, Units, Value, Error}.

decode_stats_query_stat_els([{xmlel, <<"error">>,
			      _attrs, _} =
				 _el
			     | _els],
			    Error) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_stats_query_stat_els(_els,
				      [decode_stats_query_stat_error(_el)
				       | Error]);
      _ -> decode_stats_query_stat_els(_els, Error)
    end;
decode_stats_query_stat_els([_ | _els], Error) ->
    decode_stats_query_stat_els(_els, Error);
decode_stats_query_stat_els([], Error) ->
    lists:reverse(Error).

decode_stats_query_stat_attrs([{<<"value">>, _val}
			       | _attrs],
			      _Value, Units, Name) ->
    decode_stats_query_stat_attrs(_attrs, _val, Units,
				  Name);
decode_stats_query_stat_attrs([{<<"units">>, _val}
			       | _attrs],
			      Value, _Units, Name) ->
    decode_stats_query_stat_attrs(_attrs, Value, _val,
				  Name);
decode_stats_query_stat_attrs([{<<"name">>, _val}
			       | _attrs],
			      Value, Units, _Name) ->
    decode_stats_query_stat_attrs(_attrs, Value, Units,
				  _val);
decode_stats_query_stat_attrs([_ | _attrs], Value,
			      Units, Name) ->
    decode_stats_query_stat_attrs(_attrs, Value, Units,
				  Name);
decode_stats_query_stat_attrs([], Value, Units, Name) ->
    {decode_stats_query_stat_value(Value),
     decode_stats_query_stat_units(Units),
     decode_stats_query_stat_name(Name)}.

encode_stats_query_stat([], _acc) -> _acc;
encode_stats_query_stat([{stat, Name, Units, Value,
			  Error}
			 | _tail],
			_acc) ->
    _els = encode_stats_query_stat_error(Error, []),
    _attrs = encode_stats_query_stat_name(Name,
					  encode_stats_query_stat_units(Units,
									encode_stats_query_stat_value(Value,
												      []))),
    encode_stats_query_stat(_tail,
			    [{xmlel, <<"stat">>, _attrs, _els} | _acc]).

decode_stats_query_stat_name(<<>>) ->
    erlang:error({missing_attr, <<"name">>, <<"stat">>,
		  <<>>});
decode_stats_query_stat_name(_val) -> _val.

encode_stats_query_stat_name(_val, _acc) ->
    [{<<"name">>, _val} | _acc].

decode_stats_query_stat_units(<<>>) -> undefined;
decode_stats_query_stat_units(_val) -> _val.

encode_stats_query_stat_units(undefined, _acc) -> _acc;
encode_stats_query_stat_units(_val, _acc) ->
    [{<<"units">>, _val} | _acc].

decode_stats_query_stat_value(<<>>) -> undefined;
decode_stats_query_stat_value(_val) -> _val.

encode_stats_query_stat_value(undefined, _acc) -> _acc;
encode_stats_query_stat_value(_val, _acc) ->
    [{<<"value">>, _val} | _acc].

decode_stats_query_stat_cdata(<<>>) -> undefined;
decode_stats_query_stat_cdata(_val) -> _val.

encode_stats_query_stat_cdata(undefined, _acc) -> _acc;
encode_stats_query_stat_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_stats_query_stat_error({xmlel, _, _attrs,
			       _els}) ->
    Code = decode_stats_query_stat_error_attrs(_attrs,
					       <<>>),
    Cdata = decode_stats_query_stat_error_els(_els, <<>>),
    {Code, Cdata}.

decode_stats_query_stat_error_els([{xmlcdata, _data}
				   | _els],
				  Cdata) ->
    decode_stats_query_stat_error_els(_els,
				      <<Cdata/binary, _data/binary>>);
decode_stats_query_stat_error_els([_ | _els], Cdata) ->
    decode_stats_query_stat_error_els(_els, Cdata);
decode_stats_query_stat_error_els([], Cdata) ->
    decode_stats_query_stat_error_cdata(Cdata).

decode_stats_query_stat_error_attrs([{<<"code">>, _val}
				     | _attrs],
				    _Code) ->
    decode_stats_query_stat_error_attrs(_attrs, _val);
decode_stats_query_stat_error_attrs([_ | _attrs],
				    Code) ->
    decode_stats_query_stat_error_attrs(_attrs, Code);
decode_stats_query_stat_error_attrs([], Code) ->
    decode_stats_query_stat_error_code(Code).

encode_stats_query_stat_error([], _acc) -> _acc;
encode_stats_query_stat_error([{Code, Cdata} | _tail],
			      _acc) ->
    _els = encode_stats_query_stat_error_cdata(Cdata, []),
    _attrs = encode_stats_query_stat_error_code(Code, []),
    encode_stats_query_stat_error(_tail,
				  [{xmlel, <<"error">>, _attrs, _els} | _acc]).

decode_stats_query_stat_error_code(<<>>) ->
    erlang:error({missing_attr, <<"code">>, <<"error">>,
		  <<>>});
decode_stats_query_stat_error_code(_val) ->
    case catch xml_gen:dec_int(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"code">>, <<"error">>,
			<<>>});
      _res -> _res
    end.

encode_stats_query_stat_error_code(_val, _acc) ->
    [{<<"code">>, xml_gen:enc_int(_val)} | _acc].

decode_stats_query_stat_error_cdata(<<>>) -> undefined;
decode_stats_query_stat_error_cdata(_val) -> _val.

encode_stats_query_stat_error_cdata(undefined, _acc) ->
    _acc;
encode_stats_query_stat_error_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_iq_iq({xmlel, _, _attrs, _els}) ->
    {To, From, Lang, Type, Id} = decode_iq_iq_attrs(_attrs,
						    <<>>, <<>>, <<>>, <<>>,
						    <<>>),
    {__Els, Error} = decode_iq_iq_els(_els, [], undefined),
    {'Iq', Id, Type, Lang, From, To, Error, __Els}.

decode_iq_iq_els([{xmlel, <<"error">>, _attrs, _} = _el
		  | _els],
		 __Els, Error) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_iq_iq_els(_els, __Els, decode_error_error(_el));
      _ ->
	  decode_iq_iq_els(_els, [decode(_el) | __Els], Error)
    end;
decode_iq_iq_els([{xmlel, _, _, _} = _el | _els], __Els,
		 Error) ->
    decode_iq_iq_els(_els, [decode(_el) | __Els], Error);
decode_iq_iq_els([_ | _els], __Els, Error) ->
    decode_iq_iq_els(_els, __Els, Error);
decode_iq_iq_els([], __Els, Error) ->
    {lists:reverse(__Els), Error}.

decode_iq_iq_attrs([{<<"to">>, _val} | _attrs], _To,
		   From, Lang, Type, Id) ->
    decode_iq_iq_attrs(_attrs, _val, From, Lang, Type, Id);
decode_iq_iq_attrs([{<<"from">>, _val} | _attrs], To,
		   _From, Lang, Type, Id) ->
    decode_iq_iq_attrs(_attrs, To, _val, Lang, Type, Id);
decode_iq_iq_attrs([{<<"xml:lang">>, _val} | _attrs],
		   To, From, _Lang, Type, Id) ->
    decode_iq_iq_attrs(_attrs, To, From, _val, Type, Id);
decode_iq_iq_attrs([{<<"type">>, _val} | _attrs], To,
		   From, Lang, _Type, Id) ->
    decode_iq_iq_attrs(_attrs, To, From, Lang, _val, Id);
decode_iq_iq_attrs([{<<"id">>, _val} | _attrs], To,
		   From, Lang, Type, _Id) ->
    decode_iq_iq_attrs(_attrs, To, From, Lang, Type, _val);
decode_iq_iq_attrs([_ | _attrs], To, From, Lang, Type,
		   Id) ->
    decode_iq_iq_attrs(_attrs, To, From, Lang, Type, Id);
decode_iq_iq_attrs([], To, From, Lang, Type, Id) ->
    {decode_iq_iq_to(To), decode_iq_iq_from(From),
     'decode_iq_iq_xml:lang'(Lang), decode_iq_iq_type(Type),
     decode_iq_iq_id(Id)}.

encode_iq_iq(undefined, _acc) -> _acc;
encode_iq_iq({'Iq', Id, Type, Lang, From, To, Error,
	      __Els},
	     _acc) ->
    _els = encode_error_error(Error,
			      [encode(_subel) || _subel <- __Els] ++ []),
    _attrs = encode_iq_iq_id(Id,
			     encode_iq_iq_type(Type,
					       'encode_iq_iq_xml:lang'(Lang,
								       encode_iq_iq_from(From,
											 encode_iq_iq_to(To,
													 []))))),
    [{xmlel, <<"iq">>, _attrs, _els} | _acc].

decode_iq_iq_id(<<>>) ->
    erlang:error({missing_attr, <<"id">>, <<"iq">>, <<>>});
decode_iq_iq_id(_val) -> _val.

encode_iq_iq_id(_val, _acc) ->
    [{<<"id">>, _val} | _acc].

decode_iq_iq_type(<<>>) ->
    erlang:error({missing_attr, <<"type">>, <<"iq">>,
		  <<>>});
decode_iq_iq_type(_val) ->
    case catch xml_gen:dec_enum(_val,
				[get, set, result, error])
	of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"type">>, <<"iq">>,
			<<>>});
      _res -> _res
    end.

encode_iq_iq_type(_val, _acc) ->
    [{<<"type">>, xml_gen:enc_enum(_val)} | _acc].

decode_iq_iq_from(<<>>) -> undefined;
decode_iq_iq_from(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"from">>, <<"iq">>,
			<<>>});
      _res -> _res
    end.

encode_iq_iq_from(undefined, _acc) -> _acc;
encode_iq_iq_from(_val, _acc) ->
    [{<<"from">>, enc_jid(_val)} | _acc].

decode_iq_iq_to(<<>>) -> undefined;
decode_iq_iq_to(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"to">>, <<"iq">>,
			<<>>});
      _res -> _res
    end.

encode_iq_iq_to(undefined, _acc) -> _acc;
encode_iq_iq_to(_val, _acc) ->
    [{<<"to">>, enc_jid(_val)} | _acc].

'decode_iq_iq_xml:lang'(<<>>) -> undefined;
'decode_iq_iq_xml:lang'(_val) -> _val.

'encode_iq_iq_xml:lang'(undefined, _acc) -> _acc;
'encode_iq_iq_xml:lang'(_val, _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

decode_iq_iq_cdata(<<>>) -> undefined;
decode_iq_iq_cdata(_val) -> _val.

encode_iq_iq_cdata(undefined, _acc) -> _acc;
encode_iq_iq_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_message_message({xmlel, _, _attrs, _els}) ->
    {To, From, Lang, Type, Id} =
	decode_message_message_attrs(_attrs, <<>>, <<>>, <<>>,
				     <<>>, <<>>),
    {__Els, Error, Thread, Body, Subject} =
	decode_message_message_els(_els, [], undefined,
				   undefined, [], []),
    {'Message', Id, Type, Lang, From, To, Subject, Body,
     Thread, Error, __Els}.

decode_message_message_els([{xmlel, <<"error">>, _attrs,
			     _} =
				_el
			    | _els],
			   __Els, Error, Thread, Body, Subject) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_message_message_els(_els, __Els,
				     decode_error_error(_el), Thread, Body,
				     Subject);
      _ ->
	  decode_message_message_els(_els, [decode(_el) | __Els],
				     Error, Thread, Body, Subject)
    end;
decode_message_message_els([{xmlel, <<"thread">>,
			     _attrs, _} =
				_el
			    | _els],
			   __Els, Error, Thread, Body, Subject) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_message_message_els(_els, __Els, Error,
				     decode_message_message_thread(_el), Body,
				     Subject);
      _ ->
	  decode_message_message_els(_els, [decode(_el) | __Els],
				     Error, Thread, Body, Subject)
    end;
decode_message_message_els([{xmlel, <<"body">>, _attrs,
			     _} =
				_el
			    | _els],
			   __Els, Error, Thread, Body, Subject) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_message_message_els(_els, __Els, Error, Thread,
				     [decode_message_message_body(_el) | Body],
				     Subject);
      _ ->
	  decode_message_message_els(_els, [decode(_el) | __Els],
				     Error, Thread, Body, Subject)
    end;
decode_message_message_els([{xmlel, <<"subject">>,
			     _attrs, _} =
				_el
			    | _els],
			   __Els, Error, Thread, Body, Subject) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_message_message_els(_els, __Els, Error, Thread,
				     Body,
				     [decode_message_message_subject(_el)
				      | Subject]);
      _ ->
	  decode_message_message_els(_els, [decode(_el) | __Els],
				     Error, Thread, Body, Subject)
    end;
decode_message_message_els([{xmlel, _, _, _} = _el
			    | _els],
			   __Els, Error, Thread, Body, Subject) ->
    decode_message_message_els(_els, [decode(_el) | __Els],
			       Error, Thread, Body, Subject);
decode_message_message_els([_ | _els], __Els, Error,
			   Thread, Body, Subject) ->
    decode_message_message_els(_els, __Els, Error, Thread,
			       Body, Subject);
decode_message_message_els([], __Els, Error, Thread,
			   Body, Subject) ->
    {lists:reverse(__Els), Error, Thread,
     lists:reverse(Body), lists:reverse(Subject)}.

decode_message_message_attrs([{<<"to">>, _val}
			      | _attrs],
			     _To, From, Lang, Type, Id) ->
    decode_message_message_attrs(_attrs, _val, From, Lang,
				 Type, Id);
decode_message_message_attrs([{<<"from">>, _val}
			      | _attrs],
			     To, _From, Lang, Type, Id) ->
    decode_message_message_attrs(_attrs, To, _val, Lang,
				 Type, Id);
decode_message_message_attrs([{<<"xml:lang">>, _val}
			      | _attrs],
			     To, From, _Lang, Type, Id) ->
    decode_message_message_attrs(_attrs, To, From, _val,
				 Type, Id);
decode_message_message_attrs([{<<"type">>, _val}
			      | _attrs],
			     To, From, Lang, _Type, Id) ->
    decode_message_message_attrs(_attrs, To, From, Lang,
				 _val, Id);
decode_message_message_attrs([{<<"id">>, _val}
			      | _attrs],
			     To, From, Lang, Type, _Id) ->
    decode_message_message_attrs(_attrs, To, From, Lang,
				 Type, _val);
decode_message_message_attrs([_ | _attrs], To, From,
			     Lang, Type, Id) ->
    decode_message_message_attrs(_attrs, To, From, Lang,
				 Type, Id);
decode_message_message_attrs([], To, From, Lang, Type,
			     Id) ->
    {decode_message_message_to(To),
     decode_message_message_from(From),
     'decode_message_message_xml:lang'(Lang),
     decode_message_message_type(Type),
     decode_message_message_id(Id)}.

encode_message_message(undefined, _acc) -> _acc;
encode_message_message({'Message', Id, Type, Lang, From,
			To, Subject, Body, Thread, Error, __Els},
		       _acc) ->
    _els = encode_message_message_subject(Subject,
					  encode_message_message_body(Body,
								      encode_message_message_thread(Thread,
												    encode_error_error(Error,
														       [encode(_subel)
															|| _subel
															       <- __Els]
															 ++
															 [])))),
    _attrs = encode_message_message_id(Id,
				       encode_message_message_type(Type,
								   'encode_message_message_xml:lang'(Lang,
												     encode_message_message_from(From,
																 encode_message_message_to(To,
																			   []))))),
    [{xmlel, <<"message">>, _attrs, _els} | _acc].

decode_message_message_id(<<>>) -> undefined;
decode_message_message_id(_val) -> _val.

encode_message_message_id(undefined, _acc) -> _acc;
encode_message_message_id(_val, _acc) ->
    [{<<"id">>, _val} | _acc].

decode_message_message_type(<<>>) -> normal;
decode_message_message_type(_val) ->
    case catch xml_gen:dec_enum(_val,
				[chat, normal, groupchat, headline, error])
	of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"type">>, <<"message">>,
			<<>>});
      _res -> _res
    end.

encode_message_message_type(normal, _acc) -> _acc;
encode_message_message_type(_val, _acc) ->
    [{<<"type">>, xml_gen:enc_enum(_val)} | _acc].

decode_message_message_from(<<>>) -> undefined;
decode_message_message_from(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"from">>, <<"message">>,
			<<>>});
      _res -> _res
    end.

encode_message_message_from(undefined, _acc) -> _acc;
encode_message_message_from(_val, _acc) ->
    [{<<"from">>, enc_jid(_val)} | _acc].

decode_message_message_to(<<>>) -> undefined;
decode_message_message_to(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"to">>, <<"message">>,
			<<>>});
      _res -> _res
    end.

encode_message_message_to(undefined, _acc) -> _acc;
encode_message_message_to(_val, _acc) ->
    [{<<"to">>, enc_jid(_val)} | _acc].

'decode_message_message_xml:lang'(<<>>) -> undefined;
'decode_message_message_xml:lang'(_val) -> _val.

'encode_message_message_xml:lang'(undefined, _acc) ->
    _acc;
'encode_message_message_xml:lang'(_val, _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

decode_message_message_cdata(<<>>) -> undefined;
decode_message_message_cdata(_val) -> _val.

encode_message_message_cdata(undefined, _acc) -> _acc;
encode_message_message_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_message_message_thread({xmlel, _, _attrs,
			       _els}) ->
    Cdata = decode_message_message_thread_els(_els, <<>>),
    Cdata.

decode_message_message_thread_els([{xmlcdata, _data}
				   | _els],
				  Cdata) ->
    decode_message_message_thread_els(_els,
				      <<Cdata/binary, _data/binary>>);
decode_message_message_thread_els([_ | _els], Cdata) ->
    decode_message_message_thread_els(_els, Cdata);
decode_message_message_thread_els([], Cdata) ->
    decode_message_message_thread_cdata(Cdata).

encode_message_message_thread(undefined, _acc) -> _acc;
encode_message_message_thread(Cdata, _acc) ->
    _els = encode_message_message_thread_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"thread">>, _attrs, _els} | _acc].

decode_message_message_thread_cdata(<<>>) -> undefined;
decode_message_message_thread_cdata(_val) -> _val.

encode_message_message_thread_cdata(undefined, _acc) ->
    _acc;
encode_message_message_thread_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_message_message_body({xmlel, _, _attrs, _els}) ->
    Body_lang = decode_message_message_body_attrs(_attrs,
						  <<>>),
    Cdata = decode_message_message_body_els(_els, <<>>),
    {Body_lang, Cdata}.

decode_message_message_body_els([{xmlcdata, _data}
				 | _els],
				Cdata) ->
    decode_message_message_body_els(_els,
				    <<Cdata/binary, _data/binary>>);
decode_message_message_body_els([_ | _els], Cdata) ->
    decode_message_message_body_els(_els, Cdata);
decode_message_message_body_els([], Cdata) ->
    decode_message_message_body_cdata(Cdata).

decode_message_message_body_attrs([{<<"xml:lang">>,
				    _val}
				   | _attrs],
				  _Body_lang) ->
    decode_message_message_body_attrs(_attrs, _val);
decode_message_message_body_attrs([_ | _attrs],
				  Body_lang) ->
    decode_message_message_body_attrs(_attrs, Body_lang);
decode_message_message_body_attrs([], Body_lang) ->
    'decode_message_message_body_xml:lang'(Body_lang).

encode_message_message_body([], _acc) -> _acc;
encode_message_message_body([{Body_lang, Cdata}
			     | _tail],
			    _acc) ->
    _els = encode_message_message_body_cdata(Cdata, []),
    _attrs =
	'encode_message_message_body_xml:lang'(Body_lang, []),
    encode_message_message_body(_tail,
				[{xmlel, <<"body">>, _attrs, _els} | _acc]).

'decode_message_message_body_xml:lang'(<<>>) ->
    undefined;
'decode_message_message_body_xml:lang'(_val) -> _val.

'encode_message_message_body_xml:lang'(undefined,
				       _acc) ->
    _acc;
'encode_message_message_body_xml:lang'(_val, _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

decode_message_message_body_cdata(<<>>) -> undefined;
decode_message_message_body_cdata(_val) -> _val.

encode_message_message_body_cdata(undefined, _acc) ->
    _acc;
encode_message_message_body_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_message_message_subject({xmlel, _, _attrs,
				_els}) ->
    Subject_lang =
	decode_message_message_subject_attrs(_attrs, <<>>),
    Cdata = decode_message_message_subject_els(_els, <<>>),
    {Subject_lang, Cdata}.

decode_message_message_subject_els([{xmlcdata, _data}
				    | _els],
				   Cdata) ->
    decode_message_message_subject_els(_els,
				       <<Cdata/binary, _data/binary>>);
decode_message_message_subject_els([_ | _els], Cdata) ->
    decode_message_message_subject_els(_els, Cdata);
decode_message_message_subject_els([], Cdata) ->
    decode_message_message_subject_cdata(Cdata).

decode_message_message_subject_attrs([{<<"xml:lang">>,
				       _val}
				      | _attrs],
				     _Subject_lang) ->
    decode_message_message_subject_attrs(_attrs, _val);
decode_message_message_subject_attrs([_ | _attrs],
				     Subject_lang) ->
    decode_message_message_subject_attrs(_attrs,
					 Subject_lang);
decode_message_message_subject_attrs([],
				     Subject_lang) ->
    'decode_message_message_subject_xml:lang'(Subject_lang).

encode_message_message_subject([], _acc) -> _acc;
encode_message_message_subject([{Subject_lang, Cdata}
				| _tail],
			       _acc) ->
    _els = encode_message_message_subject_cdata(Cdata, []),
    _attrs =
	'encode_message_message_subject_xml:lang'(Subject_lang,
						  []),
    encode_message_message_subject(_tail,
				   [{xmlel, <<"subject">>, _attrs, _els}
				    | _acc]).

'decode_message_message_subject_xml:lang'(<<>>) ->
    undefined;
'decode_message_message_subject_xml:lang'(_val) -> _val.

'encode_message_message_subject_xml:lang'(undefined,
					  _acc) ->
    _acc;
'encode_message_message_subject_xml:lang'(_val, _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

decode_message_message_subject_cdata(<<>>) -> undefined;
decode_message_message_subject_cdata(_val) -> _val.

encode_message_message_subject_cdata(undefined, _acc) ->
    _acc;
encode_message_message_subject_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_presence_presence({xmlel, _, _attrs, _els}) ->
    {To, From, Lang, Type, Id} =
	decode_presence_presence_attrs(_attrs, <<>>, <<>>, <<>>,
				       <<>>, <<>>),
    {__Els, Error, Priority, Status, Show} =
	decode_presence_presence_els(_els, [], undefined,
				     undefined, [], undefined),
    {'Presence', Id, Type, Lang, From, To, Show, Status,
     Priority, Error, __Els}.

decode_presence_presence_els([{xmlel, <<"error">>,
			       _attrs, _} =
				  _el
			      | _els],
			     __Els, Error, Priority, Status, Show) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_presence_presence_els(_els, __Els,
				       decode_error_error(_el), Priority,
				       Status, Show);
      _ ->
	  decode_presence_presence_els(_els,
				       [decode(_el) | __Els], Error, Priority,
				       Status, Show)
    end;
decode_presence_presence_els([{xmlel, <<"priority">>,
			       _attrs, _} =
				  _el
			      | _els],
			     __Els, Error, Priority, Status, Show) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_presence_presence_els(_els, __Els, Error,
				       decode_presence_presence_priority(_el),
				       Status, Show);
      _ ->
	  decode_presence_presence_els(_els,
				       [decode(_el) | __Els], Error, Priority,
				       Status, Show)
    end;
decode_presence_presence_els([{xmlel, <<"status">>,
			       _attrs, _} =
				  _el
			      | _els],
			     __Els, Error, Priority, Status, Show) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_presence_presence_els(_els, __Els, Error,
				       Priority,
				       [decode_presence_presence_status(_el)
					| Status],
				       Show);
      _ ->
	  decode_presence_presence_els(_els,
				       [decode(_el) | __Els], Error, Priority,
				       Status, Show)
    end;
decode_presence_presence_els([{xmlel, <<"show">>,
			       _attrs, _} =
				  _el
			      | _els],
			     __Els, Error, Priority, Status, Show) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_presence_presence_els(_els, __Els, Error,
				       Priority, Status,
				       decode_presence_presence_show(_el));
      _ ->
	  decode_presence_presence_els(_els,
				       [decode(_el) | __Els], Error, Priority,
				       Status, Show)
    end;
decode_presence_presence_els([{xmlel, _, _, _} = _el
			      | _els],
			     __Els, Error, Priority, Status, Show) ->
    decode_presence_presence_els(_els,
				 [decode(_el) | __Els], Error, Priority, Status,
				 Show);
decode_presence_presence_els([_ | _els], __Els, Error,
			     Priority, Status, Show) ->
    decode_presence_presence_els(_els, __Els, Error,
				 Priority, Status, Show);
decode_presence_presence_els([], __Els, Error, Priority,
			     Status, Show) ->
    {lists:reverse(__Els), Error, Priority,
     lists:reverse(Status), Show}.

decode_presence_presence_attrs([{<<"to">>, _val}
				| _attrs],
			       _To, From, Lang, Type, Id) ->
    decode_presence_presence_attrs(_attrs, _val, From, Lang,
				   Type, Id);
decode_presence_presence_attrs([{<<"from">>, _val}
				| _attrs],
			       To, _From, Lang, Type, Id) ->
    decode_presence_presence_attrs(_attrs, To, _val, Lang,
				   Type, Id);
decode_presence_presence_attrs([{<<"xml:lang">>, _val}
				| _attrs],
			       To, From, _Lang, Type, Id) ->
    decode_presence_presence_attrs(_attrs, To, From, _val,
				   Type, Id);
decode_presence_presence_attrs([{<<"type">>, _val}
				| _attrs],
			       To, From, Lang, _Type, Id) ->
    decode_presence_presence_attrs(_attrs, To, From, Lang,
				   _val, Id);
decode_presence_presence_attrs([{<<"id">>, _val}
				| _attrs],
			       To, From, Lang, Type, _Id) ->
    decode_presence_presence_attrs(_attrs, To, From, Lang,
				   Type, _val);
decode_presence_presence_attrs([_ | _attrs], To, From,
			       Lang, Type, Id) ->
    decode_presence_presence_attrs(_attrs, To, From, Lang,
				   Type, Id);
decode_presence_presence_attrs([], To, From, Lang, Type,
			       Id) ->
    {decode_presence_presence_to(To),
     decode_presence_presence_from(From),
     'decode_presence_presence_xml:lang'(Lang),
     decode_presence_presence_type(Type),
     decode_presence_presence_id(Id)}.

encode_presence_presence(undefined, _acc) -> _acc;
encode_presence_presence({'Presence', Id, Type, Lang,
			  From, To, Show, Status, Priority, Error, __Els},
			 _acc) ->
    _els = encode_presence_presence_show(Show,
					 encode_presence_presence_status(Status,
									 encode_presence_presence_priority(Priority,
													   encode_error_error(Error,
															      [encode(_subel)
															       || _subel
																      <- __Els]
																++
																[])))),
    _attrs = encode_presence_presence_id(Id,
					 encode_presence_presence_type(Type,
								       'encode_presence_presence_xml:lang'(Lang,
													   encode_presence_presence_from(From,
																	 encode_presence_presence_to(To,
																				     []))))),
    [{xmlel, <<"presence">>, _attrs, _els} | _acc].

decode_presence_presence_id(<<>>) -> undefined;
decode_presence_presence_id(_val) -> _val.

encode_presence_presence_id(undefined, _acc) -> _acc;
encode_presence_presence_id(_val, _acc) ->
    [{<<"id">>, _val} | _acc].

decode_presence_presence_type(<<>>) -> undefined;
decode_presence_presence_type(_val) ->
    case catch xml_gen:dec_enum(_val,
				[unavailable, subscribe, subscribed,
				 unsubscribe, unsubscribed, probe, error])
	of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"type">>,
			<<"presence">>, <<>>});
      _res -> _res
    end.

encode_presence_presence_type(undefined, _acc) -> _acc;
encode_presence_presence_type(_val, _acc) ->
    [{<<"type">>, xml_gen:enc_enum(_val)} | _acc].

decode_presence_presence_from(<<>>) -> undefined;
decode_presence_presence_from(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"from">>,
			<<"presence">>, <<>>});
      _res -> _res
    end.

encode_presence_presence_from(undefined, _acc) -> _acc;
encode_presence_presence_from(_val, _acc) ->
    [{<<"from">>, enc_jid(_val)} | _acc].

decode_presence_presence_to(<<>>) -> undefined;
decode_presence_presence_to(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"to">>, <<"presence">>,
			<<>>});
      _res -> _res
    end.

encode_presence_presence_to(undefined, _acc) -> _acc;
encode_presence_presence_to(_val, _acc) ->
    [{<<"to">>, enc_jid(_val)} | _acc].

'decode_presence_presence_xml:lang'(<<>>) -> undefined;
'decode_presence_presence_xml:lang'(_val) -> _val.

'encode_presence_presence_xml:lang'(undefined, _acc) ->
    _acc;
'encode_presence_presence_xml:lang'(_val, _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

decode_presence_presence_cdata(<<>>) -> undefined;
decode_presence_presence_cdata(_val) -> _val.

encode_presence_presence_cdata(undefined, _acc) -> _acc;
encode_presence_presence_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_presence_presence_priority({xmlel, _, _attrs,
				   _els}) ->
    Cdata = decode_presence_presence_priority_els(_els,
						  <<>>),
    Cdata.

decode_presence_presence_priority_els([{xmlcdata, _data}
				       | _els],
				      Cdata) ->
    decode_presence_presence_priority_els(_els,
					  <<Cdata/binary, _data/binary>>);
decode_presence_presence_priority_els([_ | _els],
				      Cdata) ->
    decode_presence_presence_priority_els(_els, Cdata);
decode_presence_presence_priority_els([], Cdata) ->
    decode_presence_presence_priority_cdata(Cdata).

encode_presence_presence_priority(undefined, _acc) ->
    _acc;
encode_presence_presence_priority(Cdata, _acc) ->
    _els = encode_presence_presence_priority_cdata(Cdata,
						   []),
    _attrs = [],
    [{xmlel, <<"priority">>, _attrs, _els} | _acc].

decode_presence_presence_priority_cdata(<<>>) ->
    undefined;
decode_presence_presence_priority_cdata(_val) ->
    case catch xml_gen:dec_int(_val, -128, 127) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"priority">>,
			<<>>});
      _res -> _res
    end.

encode_presence_presence_priority_cdata(undefined,
					_acc) ->
    _acc;
encode_presence_presence_priority_cdata(_val, _acc) ->
    [{xmlcdata, xml_gen:enc_int(_val)} | _acc].

decode_presence_presence_status({xmlel, _, _attrs,
				 _els}) ->
    Status_lang =
	decode_presence_presence_status_attrs(_attrs, <<>>),
    Cdata = decode_presence_presence_status_els(_els, <<>>),
    {Status_lang, Cdata}.

decode_presence_presence_status_els([{xmlcdata, _data}
				     | _els],
				    Cdata) ->
    decode_presence_presence_status_els(_els,
					<<Cdata/binary, _data/binary>>);
decode_presence_presence_status_els([_ | _els],
				    Cdata) ->
    decode_presence_presence_status_els(_els, Cdata);
decode_presence_presence_status_els([], Cdata) ->
    decode_presence_presence_status_cdata(Cdata).

decode_presence_presence_status_attrs([{<<"xml:lang">>,
					_val}
				       | _attrs],
				      _Status_lang) ->
    decode_presence_presence_status_attrs(_attrs, _val);
decode_presence_presence_status_attrs([_ | _attrs],
				      Status_lang) ->
    decode_presence_presence_status_attrs(_attrs,
					  Status_lang);
decode_presence_presence_status_attrs([],
				      Status_lang) ->
    'decode_presence_presence_status_xml:lang'(Status_lang).

encode_presence_presence_status([], _acc) -> _acc;
encode_presence_presence_status([{Status_lang, Cdata}
				 | _tail],
				_acc) ->
    _els = encode_presence_presence_status_cdata(Cdata, []),
    _attrs =
	'encode_presence_presence_status_xml:lang'(Status_lang,
						   []),
    encode_presence_presence_status(_tail,
				    [{xmlel, <<"status">>, _attrs, _els}
				     | _acc]).

'decode_presence_presence_status_xml:lang'(<<>>) ->
    undefined;
'decode_presence_presence_status_xml:lang'(_val) ->
    _val.

'encode_presence_presence_status_xml:lang'(undefined,
					   _acc) ->
    _acc;
'encode_presence_presence_status_xml:lang'(_val,
					   _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

decode_presence_presence_status_cdata(<<>>) ->
    undefined;
decode_presence_presence_status_cdata(_val) -> _val.

encode_presence_presence_status_cdata(undefined,
				      _acc) ->
    _acc;
encode_presence_presence_status_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_presence_presence_show({xmlel, _, _attrs,
			       _els}) ->
    Cdata = decode_presence_presence_show_els(_els, <<>>),
    Cdata.

decode_presence_presence_show_els([{xmlcdata, _data}
				   | _els],
				  Cdata) ->
    decode_presence_presence_show_els(_els,
				      <<Cdata/binary, _data/binary>>);
decode_presence_presence_show_els([_ | _els], Cdata) ->
    decode_presence_presence_show_els(_els, Cdata);
decode_presence_presence_show_els([], Cdata) ->
    decode_presence_presence_show_cdata(Cdata).

encode_presence_presence_show(undefined, _acc) -> _acc;
encode_presence_presence_show(Cdata, _acc) ->
    _els = encode_presence_presence_show_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"show">>, _attrs, _els} | _acc].

decode_presence_presence_show_cdata(<<>>) -> undefined;
decode_presence_presence_show_cdata(_val) ->
    case catch xml_gen:dec_enum(_val, [away, chat, dnd, xa])
	of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"show">>, <<>>});
      _res -> _res
    end.

encode_presence_presence_show_cdata(undefined, _acc) ->
    _acc;
encode_presence_presence_show_cdata(_val, _acc) ->
    [{xmlcdata, xml_gen:enc_enum(_val)} | _acc].

decode_error_error({xmlel, _, _attrs, _els}) ->
    {By, Error_type} = decode_error_error_attrs(_attrs,
						<<>>, <<>>),
    {Text, Reason} = decode_error_error_els(_els, undefined,
					    undefined),
    {error, Error_type, By, Reason, Text}.

decode_error_error_els([{xmlel, <<"text">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els,
				 decode_error_error_text(_el), Reason);
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"unexpected-request">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_unexpected-request'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"undefined-condition">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_undefined-condition'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"subscription-required">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_subscription-required'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"service-unavailable">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_service-unavailable'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"resource-constraint">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_resource-constraint'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"remote-server-timeout">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_remote-server-timeout'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"remote-server-not-found">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_remote-server-not-found'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"registration-required">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_registration-required'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"redirect">>, _attrs,
			 _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 decode_error_error_redirect(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"recipient-unavailable">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_recipient-unavailable'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"policy-violation">>,
			 _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_policy-violation'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"not-authorized">>,
			 _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_not-authorized'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"not-allowed">>,
			 _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_not-allowed'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"not-acceptable">>,
			 _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_not-acceptable'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"jid-malformed">>,
			 _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_jid-malformed'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"item-not-found">>,
			 _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_item-not-found'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"internal-server-error">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_internal-server-error'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"gone">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 decode_error_error_gone(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"forbidden">>, _attrs,
			 _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 decode_error_error_forbidden(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel,
			 <<"feature-not-implemented">>, _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_feature-not-implemented'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"conflict">>, _attrs,
			 _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 decode_error_error_conflict(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([{xmlel, <<"bad-request">>,
			 _attrs, _} =
			    _el
			| _els],
		       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-stanzas">> ->
	  decode_error_error_els(_els, Text,
				 'decode_error_error_bad-request'(_el));
      _ -> decode_error_error_els(_els, Text, Reason)
    end;
decode_error_error_els([_ | _els], Text, Reason) ->
    decode_error_error_els(_els, Text, Reason);
decode_error_error_els([], Text, Reason) ->
    {Text, Reason}.

decode_error_error_attrs([{<<"by">>, _val} | _attrs],
			 _By, Error_type) ->
    decode_error_error_attrs(_attrs, _val, Error_type);
decode_error_error_attrs([{<<"type">>, _val} | _attrs],
			 By, _Error_type) ->
    decode_error_error_attrs(_attrs, By, _val);
decode_error_error_attrs([_ | _attrs], By,
			 Error_type) ->
    decode_error_error_attrs(_attrs, By, Error_type);
decode_error_error_attrs([], By, Error_type) ->
    {decode_error_error_by(By),
     decode_error_error_type(Error_type)}.

'encode_error_error_$reason'(undefined, _acc) -> _acc;
'encode_error_error_$reason'('unexpected-request' = _r,
			     _acc) ->
    'encode_error_error_unexpected-request'(_r, _acc);
'encode_error_error_$reason'('undefined-condition' = _r,
			     _acc) ->
    'encode_error_error_undefined-condition'(_r, _acc);
'encode_error_error_$reason'('subscription-required' =
				 _r,
			     _acc) ->
    'encode_error_error_subscription-required'(_r, _acc);
'encode_error_error_$reason'('service-unavailable' = _r,
			     _acc) ->
    'encode_error_error_service-unavailable'(_r, _acc);
'encode_error_error_$reason'('resource-constraint' = _r,
			     _acc) ->
    'encode_error_error_resource-constraint'(_r, _acc);
'encode_error_error_$reason'('remote-server-timeout' =
				 _r,
			     _acc) ->
    'encode_error_error_remote-server-timeout'(_r, _acc);
'encode_error_error_$reason'('remote-server-not-found' =
				 _r,
			     _acc) ->
    'encode_error_error_remote-server-not-found'(_r, _acc);
'encode_error_error_$reason'('registration-required' =
				 _r,
			     _acc) ->
    'encode_error_error_registration-required'(_r, _acc);
'encode_error_error_$reason'({redirect, _} = _r,
			     _acc) ->
    encode_error_error_redirect(_r, _acc);
'encode_error_error_$reason'('recipient-unavailable' =
				 _r,
			     _acc) ->
    'encode_error_error_recipient-unavailable'(_r, _acc);
'encode_error_error_$reason'('policy-violation' = _r,
			     _acc) ->
    'encode_error_error_policy-violation'(_r, _acc);
'encode_error_error_$reason'('not-authorized' = _r,
			     _acc) ->
    'encode_error_error_not-authorized'(_r, _acc);
'encode_error_error_$reason'('not-allowed' = _r,
			     _acc) ->
    'encode_error_error_not-allowed'(_r, _acc);
'encode_error_error_$reason'('not-acceptable' = _r,
			     _acc) ->
    'encode_error_error_not-acceptable'(_r, _acc);
'encode_error_error_$reason'('jid-malformed' = _r,
			     _acc) ->
    'encode_error_error_jid-malformed'(_r, _acc);
'encode_error_error_$reason'('item-not-found' = _r,
			     _acc) ->
    'encode_error_error_item-not-found'(_r, _acc);
'encode_error_error_$reason'('internal-server-error' =
				 _r,
			     _acc) ->
    'encode_error_error_internal-server-error'(_r, _acc);
'encode_error_error_$reason'({gone, _} = _r, _acc) ->
    encode_error_error_gone(_r, _acc);
'encode_error_error_$reason'(forbidden = _r, _acc) ->
    encode_error_error_forbidden(_r, _acc);
'encode_error_error_$reason'('feature-not-implemented' =
				 _r,
			     _acc) ->
    'encode_error_error_feature-not-implemented'(_r, _acc);
'encode_error_error_$reason'(conflict = _r, _acc) ->
    encode_error_error_conflict(_r, _acc);
'encode_error_error_$reason'('bad-request' = _r,
			     _acc) ->
    'encode_error_error_bad-request'(_r, _acc).

encode_error_error(undefined, _acc) -> _acc;
encode_error_error({error, Error_type, By, Reason,
		    Text},
		   _acc) ->
    _els = 'encode_error_error_$reason'(Reason,
					encode_error_error_text(Text, [])),
    _attrs = encode_error_error_type(Error_type,
				     encode_error_error_by(By, [])),
    [{xmlel, <<"error">>, _attrs, _els} | _acc].

decode_error_error_type(<<>>) ->
    erlang:error({missing_attr, <<"type">>, <<"error">>,
		  <<>>});
decode_error_error_type(_val) ->
    case catch xml_gen:dec_enum(_val,
				[auth, cancel, continue, modify, wait])
	of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"type">>, <<"error">>,
			<<>>});
      _res -> _res
    end.

encode_error_error_type(_val, _acc) ->
    [{<<"type">>, xml_gen:enc_enum(_val)} | _acc].

decode_error_error_by(<<>>) -> undefined;
decode_error_error_by(_val) -> _val.

encode_error_error_by(undefined, _acc) -> _acc;
encode_error_error_by(_val, _acc) ->
    [{<<"by">>, _val} | _acc].

decode_error_error_cdata(<<>>) -> undefined;
decode_error_error_cdata(_val) -> _val.

encode_error_error_cdata(undefined, _acc) -> _acc;
encode_error_error_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_unexpected-request'({xmlel, _,
					 _attrs, _els}) ->
    'unexpected-request'.

'encode_error_error_unexpected-request'(undefined,
					_acc) ->
    _acc;
'encode_error_error_unexpected-request'('unexpected-request',
					_acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"unexpected-request">>, _attrs, _els}
     | _acc].

'decode_error_error_unexpected-request_cdata'(<<>>) ->
    undefined;
'decode_error_error_unexpected-request_cdata'(_val) ->
    _val.

'encode_error_error_unexpected-request_cdata'(undefined,
					      _acc) ->
    _acc;
'encode_error_error_unexpected-request_cdata'(_val,
					      _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_undefined-condition'({xmlel, _,
					  _attrs, _els}) ->
    'undefined-condition'.

'encode_error_error_undefined-condition'(undefined,
					 _acc) ->
    _acc;
'encode_error_error_undefined-condition'('undefined-condition',
					 _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"undefined-condition">>, _attrs, _els}
     | _acc].

'decode_error_error_undefined-condition_cdata'(<<>>) ->
    undefined;
'decode_error_error_undefined-condition_cdata'(_val) ->
    _val.

'encode_error_error_undefined-condition_cdata'(undefined,
					       _acc) ->
    _acc;
'encode_error_error_undefined-condition_cdata'(_val,
					       _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_subscription-required'({xmlel, _,
					    _attrs, _els}) ->
    'subscription-required'.

'encode_error_error_subscription-required'(undefined,
					   _acc) ->
    _acc;
'encode_error_error_subscription-required'('subscription-required',
					   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"subscription-required">>, _attrs, _els}
     | _acc].

'decode_error_error_subscription-required_cdata'(<<>>) ->
    undefined;
'decode_error_error_subscription-required_cdata'(_val) ->
    _val.

'encode_error_error_subscription-required_cdata'(undefined,
						 _acc) ->
    _acc;
'encode_error_error_subscription-required_cdata'(_val,
						 _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_service-unavailable'({xmlel, _,
					  _attrs, _els}) ->
    'service-unavailable'.

'encode_error_error_service-unavailable'(undefined,
					 _acc) ->
    _acc;
'encode_error_error_service-unavailable'('service-unavailable',
					 _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"service-unavailable">>, _attrs, _els}
     | _acc].

'decode_error_error_service-unavailable_cdata'(<<>>) ->
    undefined;
'decode_error_error_service-unavailable_cdata'(_val) ->
    _val.

'encode_error_error_service-unavailable_cdata'(undefined,
					       _acc) ->
    _acc;
'encode_error_error_service-unavailable_cdata'(_val,
					       _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_resource-constraint'({xmlel, _,
					  _attrs, _els}) ->
    'resource-constraint'.

'encode_error_error_resource-constraint'(undefined,
					 _acc) ->
    _acc;
'encode_error_error_resource-constraint'('resource-constraint',
					 _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"resource-constraint">>, _attrs, _els}
     | _acc].

'decode_error_error_resource-constraint_cdata'(<<>>) ->
    undefined;
'decode_error_error_resource-constraint_cdata'(_val) ->
    _val.

'encode_error_error_resource-constraint_cdata'(undefined,
					       _acc) ->
    _acc;
'encode_error_error_resource-constraint_cdata'(_val,
					       _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_remote-server-timeout'({xmlel, _,
					    _attrs, _els}) ->
    'remote-server-timeout'.

'encode_error_error_remote-server-timeout'(undefined,
					   _acc) ->
    _acc;
'encode_error_error_remote-server-timeout'('remote-server-timeout',
					   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"remote-server-timeout">>, _attrs, _els}
     | _acc].

'decode_error_error_remote-server-timeout_cdata'(<<>>) ->
    undefined;
'decode_error_error_remote-server-timeout_cdata'(_val) ->
    _val.

'encode_error_error_remote-server-timeout_cdata'(undefined,
						 _acc) ->
    _acc;
'encode_error_error_remote-server-timeout_cdata'(_val,
						 _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_remote-server-not-found'({xmlel, _,
					      _attrs, _els}) ->
    'remote-server-not-found'.

'encode_error_error_remote-server-not-found'(undefined,
					     _acc) ->
    _acc;
'encode_error_error_remote-server-not-found'('remote-server-not-found',
					     _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"remote-server-not-found">>, _attrs, _els}
     | _acc].

'decode_error_error_remote-server-not-found_cdata'(<<>>) ->
    undefined;
'decode_error_error_remote-server-not-found_cdata'(_val) ->
    _val.

'encode_error_error_remote-server-not-found_cdata'(undefined,
						   _acc) ->
    _acc;
'encode_error_error_remote-server-not-found_cdata'(_val,
						   _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_registration-required'({xmlel, _,
					    _attrs, _els}) ->
    'registration-required'.

'encode_error_error_registration-required'(undefined,
					   _acc) ->
    _acc;
'encode_error_error_registration-required'('registration-required',
					   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"registration-required">>, _attrs, _els}
     | _acc].

'decode_error_error_registration-required_cdata'(<<>>) ->
    undefined;
'decode_error_error_registration-required_cdata'(_val) ->
    _val.

'encode_error_error_registration-required_cdata'(undefined,
						 _acc) ->
    _acc;
'encode_error_error_registration-required_cdata'(_val,
						 _acc) ->
    [{xmlcdata, _val} | _acc].

decode_error_error_redirect({xmlel, _, _attrs, _els}) ->
    Cdata = decode_error_error_redirect_els(_els, <<>>),
    {redirect, Cdata}.

decode_error_error_redirect_els([{xmlcdata, _data}
				 | _els],
				Cdata) ->
    decode_error_error_redirect_els(_els,
				    <<Cdata/binary, _data/binary>>);
decode_error_error_redirect_els([_ | _els], Cdata) ->
    decode_error_error_redirect_els(_els, Cdata);
decode_error_error_redirect_els([], Cdata) ->
    decode_error_error_redirect_cdata(Cdata).

encode_error_error_redirect(undefined, _acc) -> _acc;
encode_error_error_redirect({redirect, Cdata}, _acc) ->
    _els = encode_error_error_redirect_cdata(Cdata, []),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"redirect">>, _attrs, _els} | _acc].

decode_error_error_redirect_cdata(<<>>) -> undefined;
decode_error_error_redirect_cdata(_val) -> _val.

encode_error_error_redirect_cdata(undefined, _acc) ->
    _acc;
encode_error_error_redirect_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_recipient-unavailable'({xmlel, _,
					    _attrs, _els}) ->
    'recipient-unavailable'.

'encode_error_error_recipient-unavailable'(undefined,
					   _acc) ->
    _acc;
'encode_error_error_recipient-unavailable'('recipient-unavailable',
					   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"recipient-unavailable">>, _attrs, _els}
     | _acc].

'decode_error_error_recipient-unavailable_cdata'(<<>>) ->
    undefined;
'decode_error_error_recipient-unavailable_cdata'(_val) ->
    _val.

'encode_error_error_recipient-unavailable_cdata'(undefined,
						 _acc) ->
    _acc;
'encode_error_error_recipient-unavailable_cdata'(_val,
						 _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_policy-violation'({xmlel, _, _attrs,
				       _els}) ->
    'policy-violation'.

'encode_error_error_policy-violation'(undefined,
				      _acc) ->
    _acc;
'encode_error_error_policy-violation'('policy-violation',
				      _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"policy-violation">>, _attrs, _els} | _acc].

'decode_error_error_policy-violation_cdata'(<<>>) ->
    undefined;
'decode_error_error_policy-violation_cdata'(_val) ->
    _val.

'encode_error_error_policy-violation_cdata'(undefined,
					    _acc) ->
    _acc;
'encode_error_error_policy-violation_cdata'(_val,
					    _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_not-authorized'({xmlel, _, _attrs,
				     _els}) ->
    'not-authorized'.

'encode_error_error_not-authorized'(undefined, _acc) ->
    _acc;
'encode_error_error_not-authorized'('not-authorized',
				    _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"not-authorized">>, _attrs, _els} | _acc].

'decode_error_error_not-authorized_cdata'(<<>>) ->
    undefined;
'decode_error_error_not-authorized_cdata'(_val) -> _val.

'encode_error_error_not-authorized_cdata'(undefined,
					  _acc) ->
    _acc;
'encode_error_error_not-authorized_cdata'(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_not-allowed'({xmlel, _, _attrs,
				  _els}) ->
    'not-allowed'.

'encode_error_error_not-allowed'(undefined, _acc) ->
    _acc;
'encode_error_error_not-allowed'('not-allowed', _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"not-allowed">>, _attrs, _els} | _acc].

'decode_error_error_not-allowed_cdata'(<<>>) ->
    undefined;
'decode_error_error_not-allowed_cdata'(_val) -> _val.

'encode_error_error_not-allowed_cdata'(undefined,
				       _acc) ->
    _acc;
'encode_error_error_not-allowed_cdata'(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_not-acceptable'({xmlel, _, _attrs,
				     _els}) ->
    'not-acceptable'.

'encode_error_error_not-acceptable'(undefined, _acc) ->
    _acc;
'encode_error_error_not-acceptable'('not-acceptable',
				    _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"not-acceptable">>, _attrs, _els} | _acc].

'decode_error_error_not-acceptable_cdata'(<<>>) ->
    undefined;
'decode_error_error_not-acceptable_cdata'(_val) -> _val.

'encode_error_error_not-acceptable_cdata'(undefined,
					  _acc) ->
    _acc;
'encode_error_error_not-acceptable_cdata'(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_jid-malformed'({xmlel, _, _attrs,
				    _els}) ->
    'jid-malformed'.

'encode_error_error_jid-malformed'(undefined, _acc) ->
    _acc;
'encode_error_error_jid-malformed'('jid-malformed',
				   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"jid-malformed">>, _attrs, _els} | _acc].

'decode_error_error_jid-malformed_cdata'(<<>>) ->
    undefined;
'decode_error_error_jid-malformed_cdata'(_val) -> _val.

'encode_error_error_jid-malformed_cdata'(undefined,
					 _acc) ->
    _acc;
'encode_error_error_jid-malformed_cdata'(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_item-not-found'({xmlel, _, _attrs,
				     _els}) ->
    'item-not-found'.

'encode_error_error_item-not-found'(undefined, _acc) ->
    _acc;
'encode_error_error_item-not-found'('item-not-found',
				    _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"item-not-found">>, _attrs, _els} | _acc].

'decode_error_error_item-not-found_cdata'(<<>>) ->
    undefined;
'decode_error_error_item-not-found_cdata'(_val) -> _val.

'encode_error_error_item-not-found_cdata'(undefined,
					  _acc) ->
    _acc;
'encode_error_error_item-not-found_cdata'(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_internal-server-error'({xmlel, _,
					    _attrs, _els}) ->
    'internal-server-error'.

'encode_error_error_internal-server-error'(undefined,
					   _acc) ->
    _acc;
'encode_error_error_internal-server-error'('internal-server-error',
					   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"internal-server-error">>, _attrs, _els}
     | _acc].

'decode_error_error_internal-server-error_cdata'(<<>>) ->
    undefined;
'decode_error_error_internal-server-error_cdata'(_val) ->
    _val.

'encode_error_error_internal-server-error_cdata'(undefined,
						 _acc) ->
    _acc;
'encode_error_error_internal-server-error_cdata'(_val,
						 _acc) ->
    [{xmlcdata, _val} | _acc].

decode_error_error_gone({xmlel, _, _attrs, _els}) ->
    Cdata = decode_error_error_gone_els(_els, <<>>),
    {gone, Cdata}.

decode_error_error_gone_els([{xmlcdata, _data} | _els],
			    Cdata) ->
    decode_error_error_gone_els(_els,
				<<Cdata/binary, _data/binary>>);
decode_error_error_gone_els([_ | _els], Cdata) ->
    decode_error_error_gone_els(_els, Cdata);
decode_error_error_gone_els([], Cdata) ->
    decode_error_error_gone_cdata(Cdata).

encode_error_error_gone(undefined, _acc) -> _acc;
encode_error_error_gone({gone, Cdata}, _acc) ->
    _els = encode_error_error_gone_cdata(Cdata, []),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"gone">>, _attrs, _els} | _acc].

decode_error_error_gone_cdata(<<>>) -> undefined;
decode_error_error_gone_cdata(_val) -> _val.

encode_error_error_gone_cdata(undefined, _acc) -> _acc;
encode_error_error_gone_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_error_error_forbidden({xmlel, _, _attrs,
			      _els}) ->
    forbidden.

encode_error_error_forbidden(undefined, _acc) -> _acc;
encode_error_error_forbidden(forbidden, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"forbidden">>, _attrs, _els} | _acc].

decode_error_error_forbidden_cdata(<<>>) -> undefined;
decode_error_error_forbidden_cdata(_val) -> _val.

encode_error_error_forbidden_cdata(undefined, _acc) ->
    _acc;
encode_error_error_forbidden_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_feature-not-implemented'({xmlel, _,
					      _attrs, _els}) ->
    'feature-not-implemented'.

'encode_error_error_feature-not-implemented'(undefined,
					     _acc) ->
    _acc;
'encode_error_error_feature-not-implemented'('feature-not-implemented',
					     _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"feature-not-implemented">>, _attrs, _els}
     | _acc].

'decode_error_error_feature-not-implemented_cdata'(<<>>) ->
    undefined;
'decode_error_error_feature-not-implemented_cdata'(_val) ->
    _val.

'encode_error_error_feature-not-implemented_cdata'(undefined,
						   _acc) ->
    _acc;
'encode_error_error_feature-not-implemented_cdata'(_val,
						   _acc) ->
    [{xmlcdata, _val} | _acc].

decode_error_error_conflict({xmlel, _, _attrs, _els}) ->
    conflict.

encode_error_error_conflict(undefined, _acc) -> _acc;
encode_error_error_conflict(conflict, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"conflict">>, _attrs, _els} | _acc].

decode_error_error_conflict_cdata(<<>>) -> undefined;
decode_error_error_conflict_cdata(_val) -> _val.

encode_error_error_conflict_cdata(undefined, _acc) ->
    _acc;
encode_error_error_conflict_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_error_error_bad-request'({xmlel, _, _attrs,
				  _els}) ->
    'bad-request'.

'encode_error_error_bad-request'(undefined, _acc) ->
    _acc;
'encode_error_error_bad-request'('bad-request', _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}],
    [{xmlel, <<"bad-request">>, _attrs, _els} | _acc].

'decode_error_error_bad-request_cdata'(<<>>) ->
    undefined;
'decode_error_error_bad-request_cdata'(_val) -> _val.

'encode_error_error_bad-request_cdata'(undefined,
				       _acc) ->
    _acc;
'encode_error_error_bad-request_cdata'(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_error_error_text({xmlel, _, _attrs, _els}) ->
    Text_lang = decode_error_error_text_attrs(_attrs, <<>>),
    Cdata = decode_error_error_text_els(_els, <<>>),
    {Text_lang, Cdata}.

decode_error_error_text_els([{xmlcdata, _data} | _els],
			    Cdata) ->
    decode_error_error_text_els(_els,
				<<Cdata/binary, _data/binary>>);
decode_error_error_text_els([_ | _els], Cdata) ->
    decode_error_error_text_els(_els, Cdata);
decode_error_error_text_els([], Cdata) ->
    decode_error_error_text_cdata(Cdata).

decode_error_error_text_attrs([{<<"xml:lang">>, _val}
			       | _attrs],
			      _Text_lang) ->
    decode_error_error_text_attrs(_attrs, _val);
decode_error_error_text_attrs([_ | _attrs],
			      Text_lang) ->
    decode_error_error_text_attrs(_attrs, Text_lang);
decode_error_error_text_attrs([], Text_lang) ->
    'decode_error_error_text_xml:lang'(Text_lang).

encode_error_error_text(undefined, _acc) -> _acc;
encode_error_error_text({Text_lang, Cdata}, _acc) ->
    _els = encode_error_error_text_cdata(Cdata, []),
    _attrs = 'encode_error_error_text_xml:lang'(Text_lang,
						[{<<"xmlns">>,
						  <<"urn:ietf:params:xml:ns:xmpp-stanzas">>}]),
    [{xmlel, <<"text">>, _attrs, _els} | _acc].

'decode_error_error_text_xml:lang'(<<>>) -> undefined;
'decode_error_error_text_xml:lang'(_val) -> _val.

'encode_error_error_text_xml:lang'(undefined, _acc) ->
    _acc;
'encode_error_error_text_xml:lang'(_val, _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

decode_error_error_text_cdata(<<>>) -> undefined;
decode_error_error_text_cdata(_val) -> _val.

encode_error_error_text_cdata(undefined, _acc) -> _acc;
encode_error_error_text_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_bind_bind({xmlel, _, _attrs, _els}) ->
    {Resource, Jid} = decode_bind_bind_els(_els, undefined,
					   undefined),
    {bind, Jid, Resource}.

decode_bind_bind_els([{xmlel, <<"resource">>, _attrs,
		       _} =
			  _el
		      | _els],
		     Resource, Jid) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_bind_bind_els(_els,
			       decode_bind_bind_resource(_el), Jid);
      _ -> decode_bind_bind_els(_els, Resource, Jid)
    end;
decode_bind_bind_els([{xmlel, <<"jid">>, _attrs, _} =
			  _el
		      | _els],
		     Resource, Jid) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_bind_bind_els(_els, Resource,
			       decode_bind_bind_jid(_el));
      _ -> decode_bind_bind_els(_els, Resource, Jid)
    end;
decode_bind_bind_els([_ | _els], Resource, Jid) ->
    decode_bind_bind_els(_els, Resource, Jid);
decode_bind_bind_els([], Resource, Jid) ->
    {Resource, Jid}.

encode_bind_bind(undefined, _acc) -> _acc;
encode_bind_bind({bind, Jid, Resource}, _acc) ->
    _els = encode_bind_bind_jid(Jid,
				encode_bind_bind_resource(Resource, [])),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-bind">>}],
    [{xmlel, <<"bind">>, _attrs, _els} | _acc].

decode_bind_bind_cdata(<<>>) -> undefined;
decode_bind_bind_cdata(_val) -> _val.

encode_bind_bind_cdata(undefined, _acc) -> _acc;
encode_bind_bind_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_bind_bind_resource({xmlel, _, _attrs, _els}) ->
    Cdata = decode_bind_bind_resource_els(_els, <<>>),
    Cdata.

decode_bind_bind_resource_els([{xmlcdata, _data}
			       | _els],
			      Cdata) ->
    decode_bind_bind_resource_els(_els,
				  <<Cdata/binary, _data/binary>>);
decode_bind_bind_resource_els([_ | _els], Cdata) ->
    decode_bind_bind_resource_els(_els, Cdata);
decode_bind_bind_resource_els([], Cdata) ->
    decode_bind_bind_resource_cdata(Cdata).

encode_bind_bind_resource(undefined, _acc) -> _acc;
encode_bind_bind_resource(Cdata, _acc) ->
    _els = encode_bind_bind_resource_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"resource">>, _attrs, _els} | _acc].

decode_bind_bind_resource_cdata(<<>>) -> undefined;
decode_bind_bind_resource_cdata(_val) ->
    case catch resourceprep(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"resource">>,
			<<>>});
      _res -> _res
    end.

encode_bind_bind_resource_cdata(undefined, _acc) ->
    _acc;
encode_bind_bind_resource_cdata(_val, _acc) ->
    [{xmlcdata, resourceprep(_val)} | _acc].

decode_bind_bind_jid({xmlel, _, _attrs, _els}) ->
    Cdata = decode_bind_bind_jid_els(_els, <<>>), Cdata.

decode_bind_bind_jid_els([{xmlcdata, _data} | _els],
			 Cdata) ->
    decode_bind_bind_jid_els(_els,
			     <<Cdata/binary, _data/binary>>);
decode_bind_bind_jid_els([_ | _els], Cdata) ->
    decode_bind_bind_jid_els(_els, Cdata);
decode_bind_bind_jid_els([], Cdata) ->
    decode_bind_bind_jid_cdata(Cdata).

encode_bind_bind_jid(undefined, _acc) -> _acc;
encode_bind_bind_jid(Cdata, _acc) ->
    _els = encode_bind_bind_jid_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"jid">>, _attrs, _els} | _acc].

decode_bind_bind_jid_cdata(<<>>) -> undefined;
decode_bind_bind_jid_cdata(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"jid">>, <<>>});
      _res -> _res
    end.

encode_bind_bind_jid_cdata(undefined, _acc) -> _acc;
encode_bind_bind_jid_cdata(_val, _acc) ->
    [{xmlcdata, enc_jid(_val)} | _acc].

decode_sasl_auth_auth({xmlel, _, _attrs, _els}) ->
    Mechanism = decode_sasl_auth_auth_attrs(_attrs, <<>>),
    Cdata = decode_sasl_auth_auth_els(_els, <<>>),
    {sasl_auth, Mechanism, Cdata}.

decode_sasl_auth_auth_els([{xmlcdata, _data} | _els],
			  Cdata) ->
    decode_sasl_auth_auth_els(_els,
			      <<Cdata/binary, _data/binary>>);
decode_sasl_auth_auth_els([_ | _els], Cdata) ->
    decode_sasl_auth_auth_els(_els, Cdata);
decode_sasl_auth_auth_els([], Cdata) ->
    decode_sasl_auth_auth_cdata(Cdata).

decode_sasl_auth_auth_attrs([{<<"mechanism">>, _val}
			     | _attrs],
			    _Mechanism) ->
    decode_sasl_auth_auth_attrs(_attrs, _val);
decode_sasl_auth_auth_attrs([_ | _attrs], Mechanism) ->
    decode_sasl_auth_auth_attrs(_attrs, Mechanism);
decode_sasl_auth_auth_attrs([], Mechanism) ->
    decode_sasl_auth_auth_mechanism(Mechanism).

encode_sasl_auth_auth(undefined, _acc) -> _acc;
encode_sasl_auth_auth({sasl_auth, Mechanism, Cdata},
		      _acc) ->
    _els = encode_sasl_auth_auth_cdata(Cdata, []),
    _attrs = encode_sasl_auth_auth_mechanism(Mechanism,
					     [{<<"xmlns">>,
					       <<"urn:ietf:params:xml:ns:xmpp-sasl">>}]),
    [{xmlel, <<"auth">>, _attrs, _els} | _acc].

decode_sasl_auth_auth_mechanism(<<>>) ->
    erlang:error({missing_attr, <<"mechanism">>, <<"auth">>,
		  <<"urn:ietf:params:xml:ns:xmpp-sasl">>});
decode_sasl_auth_auth_mechanism(_val) -> _val.

encode_sasl_auth_auth_mechanism(_val, _acc) ->
    [{<<"mechanism">>, _val} | _acc].

decode_sasl_auth_auth_cdata(<<>>) -> undefined;
decode_sasl_auth_auth_cdata(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"auth">>,
			<<"urn:ietf:params:xml:ns:xmpp-sasl">>});
      _res -> _res
    end.

encode_sasl_auth_auth_cdata(undefined, _acc) -> _acc;
encode_sasl_auth_auth_cdata(_val, _acc) ->
    [{xmlcdata, base64:encode(_val)} | _acc].

decode_sasl_abort_abort({xmlel, _, _attrs, _els}) ->
    {sasl_abort}.

encode_sasl_abort_abort(undefined, _acc) -> _acc;
encode_sasl_abort_abort({sasl_abort}, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-sasl">>}],
    [{xmlel, <<"abort">>, _attrs, _els} | _acc].

decode_sasl_abort_abort_cdata(<<>>) -> undefined;
decode_sasl_abort_abort_cdata(_val) -> _val.

encode_sasl_abort_abort_cdata(undefined, _acc) -> _acc;
encode_sasl_abort_abort_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_sasl_challenge_challenge({xmlel, _, _attrs,
				 _els}) ->
    Cdata = decode_sasl_challenge_challenge_els(_els, <<>>),
    {sasl_challenge, Cdata}.

decode_sasl_challenge_challenge_els([{xmlcdata, _data}
				     | _els],
				    Cdata) ->
    decode_sasl_challenge_challenge_els(_els,
					<<Cdata/binary, _data/binary>>);
decode_sasl_challenge_challenge_els([_ | _els],
				    Cdata) ->
    decode_sasl_challenge_challenge_els(_els, Cdata);
decode_sasl_challenge_challenge_els([], Cdata) ->
    decode_sasl_challenge_challenge_cdata(Cdata).

encode_sasl_challenge_challenge(undefined, _acc) ->
    _acc;
encode_sasl_challenge_challenge({sasl_challenge, Cdata},
				_acc) ->
    _els = encode_sasl_challenge_challenge_cdata(Cdata, []),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-sasl">>}],
    [{xmlel, <<"challenge">>, _attrs, _els} | _acc].

decode_sasl_challenge_challenge_cdata(<<>>) ->
    undefined;
decode_sasl_challenge_challenge_cdata(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"challenge">>,
			<<"urn:ietf:params:xml:ns:xmpp-sasl">>});
      _res -> _res
    end.

encode_sasl_challenge_challenge_cdata(undefined,
				      _acc) ->
    _acc;
encode_sasl_challenge_challenge_cdata(_val, _acc) ->
    [{xmlcdata, base64:encode(_val)} | _acc].

decode_sasl_response_response({xmlel, _, _attrs,
			       _els}) ->
    Cdata = decode_sasl_response_response_els(_els, <<>>),
    {sasl_response, Cdata}.

decode_sasl_response_response_els([{xmlcdata, _data}
				   | _els],
				  Cdata) ->
    decode_sasl_response_response_els(_els,
				      <<Cdata/binary, _data/binary>>);
decode_sasl_response_response_els([_ | _els], Cdata) ->
    decode_sasl_response_response_els(_els, Cdata);
decode_sasl_response_response_els([], Cdata) ->
    decode_sasl_response_response_cdata(Cdata).

encode_sasl_response_response(undefined, _acc) -> _acc;
encode_sasl_response_response({sasl_response, Cdata},
			      _acc) ->
    _els = encode_sasl_response_response_cdata(Cdata, []),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-sasl">>}],
    [{xmlel, <<"response">>, _attrs, _els} | _acc].

decode_sasl_response_response_cdata(<<>>) -> undefined;
decode_sasl_response_response_cdata(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"response">>,
			<<"urn:ietf:params:xml:ns:xmpp-sasl">>});
      _res -> _res
    end.

encode_sasl_response_response_cdata(undefined, _acc) ->
    _acc;
encode_sasl_response_response_cdata(_val, _acc) ->
    [{xmlcdata, base64:encode(_val)} | _acc].

decode_sasl_success_success({xmlel, _, _attrs, _els}) ->
    Cdata = decode_sasl_success_success_els(_els, <<>>),
    {sasl_success, Cdata}.

decode_sasl_success_success_els([{xmlcdata, _data}
				 | _els],
				Cdata) ->
    decode_sasl_success_success_els(_els,
				    <<Cdata/binary, _data/binary>>);
decode_sasl_success_success_els([_ | _els], Cdata) ->
    decode_sasl_success_success_els(_els, Cdata);
decode_sasl_success_success_els([], Cdata) ->
    decode_sasl_success_success_cdata(Cdata).

encode_sasl_success_success(undefined, _acc) -> _acc;
encode_sasl_success_success({sasl_success, Cdata},
			    _acc) ->
    _els = encode_sasl_success_success_cdata(Cdata, []),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-sasl">>}],
    [{xmlel, <<"success">>, _attrs, _els} | _acc].

decode_sasl_success_success_cdata(<<>>) -> undefined;
decode_sasl_success_success_cdata(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"success">>,
			<<"urn:ietf:params:xml:ns:xmpp-sasl">>});
      _res -> _res
    end.

encode_sasl_success_success_cdata(undefined, _acc) ->
    _acc;
encode_sasl_success_success_cdata(_val, _acc) ->
    [{xmlcdata, base64:encode(_val)} | _acc].

decode_sasl_failure_failure({xmlel, _, _attrs, _els}) ->
    {Text, Reason} = decode_sasl_failure_failure_els(_els,
						     undefined, undefined),
    {sasl_failure, Reason, Text}.

decode_sasl_failure_failure_els([{xmlel, <<"text">>,
				  _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els,
					  decode_sasl_failure_failure_text(_el),
					  Reason);
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"temporary-auth-failure">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_temporary-auth-failure'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"not-authorized">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_not-authorized'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"mechanism-too-weak">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_mechanism-too-weak'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"malformed-request">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_malformed-request'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"invalid-mechanism">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_invalid-mechanism'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"invalid-authzid">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_invalid-authzid'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"incorrect-encoding">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_incorrect-encoding'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"encryption-required">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_encryption-required'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"credentials-expired">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_credentials-expired'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel,
				  <<"account-disabled">>, _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  'decode_sasl_failure_failure_account-disabled'(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([{xmlel, <<"aborted">>,
				  _attrs, _} =
				     _el
				 | _els],
				Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_failure_failure_els(_els, Text,
					  decode_sasl_failure_failure_aborted(_el));
      _ -> decode_sasl_failure_failure_els(_els, Text, Reason)
    end;
decode_sasl_failure_failure_els([_ | _els], Text,
				Reason) ->
    decode_sasl_failure_failure_els(_els, Text, Reason);
decode_sasl_failure_failure_els([], Text, Reason) ->
    {Text, Reason}.

'encode_sasl_failure_failure_$reason'(undefined,
				      _acc) ->
    _acc;
'encode_sasl_failure_failure_$reason'('temporary-auth-failure' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_temporary-auth-failure'(_r,
							 _acc);
'encode_sasl_failure_failure_$reason'('not-authorized' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_not-authorized'(_r, _acc);
'encode_sasl_failure_failure_$reason'('mechanism-too-weak' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_mechanism-too-weak'(_r,
						     _acc);
'encode_sasl_failure_failure_$reason'('malformed-request' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_malformed-request'(_r,
						    _acc);
'encode_sasl_failure_failure_$reason'('invalid-mechanism' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_invalid-mechanism'(_r,
						    _acc);
'encode_sasl_failure_failure_$reason'('invalid-authzid' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_invalid-authzid'(_r, _acc);
'encode_sasl_failure_failure_$reason'('incorrect-encoding' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_incorrect-encoding'(_r,
						     _acc);
'encode_sasl_failure_failure_$reason'('encryption-required' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_encryption-required'(_r,
						      _acc);
'encode_sasl_failure_failure_$reason'('credentials-expired' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_credentials-expired'(_r,
						      _acc);
'encode_sasl_failure_failure_$reason'('account-disabled' =
					  _r,
				      _acc) ->
    'encode_sasl_failure_failure_account-disabled'(_r,
						   _acc);
'encode_sasl_failure_failure_$reason'(aborted = _r,
				      _acc) ->
    encode_sasl_failure_failure_aborted(_r, _acc).

encode_sasl_failure_failure(undefined, _acc) -> _acc;
encode_sasl_failure_failure({sasl_failure, Reason,
			     Text},
			    _acc) ->
    _els = 'encode_sasl_failure_failure_$reason'(Reason,
						 encode_sasl_failure_failure_text(Text,
										  [])),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-sasl">>}],
    [{xmlel, <<"failure">>, _attrs, _els} | _acc].

decode_sasl_failure_failure_cdata(<<>>) -> undefined;
decode_sasl_failure_failure_cdata(_val) -> _val.

encode_sasl_failure_failure_cdata(undefined, _acc) ->
    _acc;
encode_sasl_failure_failure_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_temporary-auth-failure'({xmlel,
						      _, _attrs, _els}) ->
    'temporary-auth-failure'.

'encode_sasl_failure_failure_temporary-auth-failure'(undefined,
						     _acc) ->
    _acc;
'encode_sasl_failure_failure_temporary-auth-failure'('temporary-auth-failure',
						     _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"temporary-auth-failure">>, _attrs, _els}
     | _acc].

'decode_sasl_failure_failure_temporary-auth-failure_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_temporary-auth-failure_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_temporary-auth-failure_cdata'(undefined,
							   _acc) ->
    _acc;
'encode_sasl_failure_failure_temporary-auth-failure_cdata'(_val,
							   _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_not-authorized'({xmlel, _,
					      _attrs, _els}) ->
    'not-authorized'.

'encode_sasl_failure_failure_not-authorized'(undefined,
					     _acc) ->
    _acc;
'encode_sasl_failure_failure_not-authorized'('not-authorized',
					     _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"not-authorized">>, _attrs, _els} | _acc].

'decode_sasl_failure_failure_not-authorized_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_not-authorized_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_not-authorized_cdata'(undefined,
						   _acc) ->
    _acc;
'encode_sasl_failure_failure_not-authorized_cdata'(_val,
						   _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_mechanism-too-weak'({xmlel,
						  _, _attrs, _els}) ->
    'mechanism-too-weak'.

'encode_sasl_failure_failure_mechanism-too-weak'(undefined,
						 _acc) ->
    _acc;
'encode_sasl_failure_failure_mechanism-too-weak'('mechanism-too-weak',
						 _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"mechanism-too-weak">>, _attrs, _els}
     | _acc].

'decode_sasl_failure_failure_mechanism-too-weak_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_mechanism-too-weak_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_mechanism-too-weak_cdata'(undefined,
						       _acc) ->
    _acc;
'encode_sasl_failure_failure_mechanism-too-weak_cdata'(_val,
						       _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_malformed-request'({xmlel,
						 _, _attrs, _els}) ->
    'malformed-request'.

'encode_sasl_failure_failure_malformed-request'(undefined,
						_acc) ->
    _acc;
'encode_sasl_failure_failure_malformed-request'('malformed-request',
						_acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"malformed-request">>, _attrs, _els} | _acc].

'decode_sasl_failure_failure_malformed-request_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_malformed-request_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_malformed-request_cdata'(undefined,
						      _acc) ->
    _acc;
'encode_sasl_failure_failure_malformed-request_cdata'(_val,
						      _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_invalid-mechanism'({xmlel,
						 _, _attrs, _els}) ->
    'invalid-mechanism'.

'encode_sasl_failure_failure_invalid-mechanism'(undefined,
						_acc) ->
    _acc;
'encode_sasl_failure_failure_invalid-mechanism'('invalid-mechanism',
						_acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"invalid-mechanism">>, _attrs, _els} | _acc].

'decode_sasl_failure_failure_invalid-mechanism_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_invalid-mechanism_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_invalid-mechanism_cdata'(undefined,
						      _acc) ->
    _acc;
'encode_sasl_failure_failure_invalid-mechanism_cdata'(_val,
						      _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_invalid-authzid'({xmlel, _,
					       _attrs, _els}) ->
    'invalid-authzid'.

'encode_sasl_failure_failure_invalid-authzid'(undefined,
					      _acc) ->
    _acc;
'encode_sasl_failure_failure_invalid-authzid'('invalid-authzid',
					      _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"invalid-authzid">>, _attrs, _els} | _acc].

'decode_sasl_failure_failure_invalid-authzid_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_invalid-authzid_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_invalid-authzid_cdata'(undefined,
						    _acc) ->
    _acc;
'encode_sasl_failure_failure_invalid-authzid_cdata'(_val,
						    _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_incorrect-encoding'({xmlel,
						  _, _attrs, _els}) ->
    'incorrect-encoding'.

'encode_sasl_failure_failure_incorrect-encoding'(undefined,
						 _acc) ->
    _acc;
'encode_sasl_failure_failure_incorrect-encoding'('incorrect-encoding',
						 _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"incorrect-encoding">>, _attrs, _els}
     | _acc].

'decode_sasl_failure_failure_incorrect-encoding_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_incorrect-encoding_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_incorrect-encoding_cdata'(undefined,
						       _acc) ->
    _acc;
'encode_sasl_failure_failure_incorrect-encoding_cdata'(_val,
						       _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_encryption-required'({xmlel,
						   _, _attrs, _els}) ->
    'encryption-required'.

'encode_sasl_failure_failure_encryption-required'(undefined,
						  _acc) ->
    _acc;
'encode_sasl_failure_failure_encryption-required'('encryption-required',
						  _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"encryption-required">>, _attrs, _els}
     | _acc].

'decode_sasl_failure_failure_encryption-required_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_encryption-required_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_encryption-required_cdata'(undefined,
							_acc) ->
    _acc;
'encode_sasl_failure_failure_encryption-required_cdata'(_val,
							_acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_credentials-expired'({xmlel,
						   _, _attrs, _els}) ->
    'credentials-expired'.

'encode_sasl_failure_failure_credentials-expired'(undefined,
						  _acc) ->
    _acc;
'encode_sasl_failure_failure_credentials-expired'('credentials-expired',
						  _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"credentials-expired">>, _attrs, _els}
     | _acc].

'decode_sasl_failure_failure_credentials-expired_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_credentials-expired_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_credentials-expired_cdata'(undefined,
							_acc) ->
    _acc;
'encode_sasl_failure_failure_credentials-expired_cdata'(_val,
							_acc) ->
    [{xmlcdata, _val} | _acc].

'decode_sasl_failure_failure_account-disabled'({xmlel,
						_, _attrs, _els}) ->
    'account-disabled'.

'encode_sasl_failure_failure_account-disabled'(undefined,
					       _acc) ->
    _acc;
'encode_sasl_failure_failure_account-disabled'('account-disabled',
					       _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"account-disabled">>, _attrs, _els} | _acc].

'decode_sasl_failure_failure_account-disabled_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_account-disabled_cdata'(_val) ->
    _val.

'encode_sasl_failure_failure_account-disabled_cdata'(undefined,
						     _acc) ->
    _acc;
'encode_sasl_failure_failure_account-disabled_cdata'(_val,
						     _acc) ->
    [{xmlcdata, _val} | _acc].

decode_sasl_failure_failure_aborted({xmlel, _, _attrs,
				     _els}) ->
    aborted.

encode_sasl_failure_failure_aborted(undefined, _acc) ->
    _acc;
encode_sasl_failure_failure_aborted(aborted, _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"aborted">>, _attrs, _els} | _acc].

decode_sasl_failure_failure_aborted_cdata(<<>>) ->
    undefined;
decode_sasl_failure_failure_aborted_cdata(_val) -> _val.

encode_sasl_failure_failure_aborted_cdata(undefined,
					  _acc) ->
    _acc;
encode_sasl_failure_failure_aborted_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_sasl_failure_failure_text({xmlel, _, _attrs,
				  _els}) ->
    Text_lang =
	decode_sasl_failure_failure_text_attrs(_attrs, <<>>),
    Cdata = decode_sasl_failure_failure_text_els(_els,
						 <<>>),
    {Text_lang, Cdata}.

decode_sasl_failure_failure_text_els([{xmlcdata, _data}
				      | _els],
				     Cdata) ->
    decode_sasl_failure_failure_text_els(_els,
					 <<Cdata/binary, _data/binary>>);
decode_sasl_failure_failure_text_els([_ | _els],
				     Cdata) ->
    decode_sasl_failure_failure_text_els(_els, Cdata);
decode_sasl_failure_failure_text_els([], Cdata) ->
    decode_sasl_failure_failure_text_cdata(Cdata).

decode_sasl_failure_failure_text_attrs([{<<"xml:lang">>,
					 _val}
					| _attrs],
				       _Text_lang) ->
    decode_sasl_failure_failure_text_attrs(_attrs, _val);
decode_sasl_failure_failure_text_attrs([_ | _attrs],
				       Text_lang) ->
    decode_sasl_failure_failure_text_attrs(_attrs,
					   Text_lang);
decode_sasl_failure_failure_text_attrs([], Text_lang) ->
    'decode_sasl_failure_failure_text_xml:lang'(Text_lang).

encode_sasl_failure_failure_text(undefined, _acc) ->
    _acc;
encode_sasl_failure_failure_text({Text_lang, Cdata},
				 _acc) ->
    _els = encode_sasl_failure_failure_text_cdata(Cdata,
						  []),
    _attrs =
	'encode_sasl_failure_failure_text_xml:lang'(Text_lang,
						    []),
    [{xmlel, <<"text">>, _attrs, _els} | _acc].

'decode_sasl_failure_failure_text_xml:lang'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_text_xml:lang'(_val) ->
    _val.

'encode_sasl_failure_failure_text_xml:lang'(undefined,
					    _acc) ->
    _acc;
'encode_sasl_failure_failure_text_xml:lang'(_val,
					    _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

decode_sasl_failure_failure_text_cdata(<<>>) ->
    undefined;
decode_sasl_failure_failure_text_cdata(_val) -> _val.

encode_sasl_failure_failure_text_cdata(undefined,
				       _acc) ->
    _acc;
encode_sasl_failure_failure_text_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_sasl_mechanism_mechanism({xmlel, _, _attrs,
				 _els}) ->
    Cdata = decode_sasl_mechanism_mechanism_els(_els, <<>>),
    Cdata.

decode_sasl_mechanism_mechanism_els([{xmlcdata, _data}
				     | _els],
				    Cdata) ->
    decode_sasl_mechanism_mechanism_els(_els,
					<<Cdata/binary, _data/binary>>);
decode_sasl_mechanism_mechanism_els([_ | _els],
				    Cdata) ->
    decode_sasl_mechanism_mechanism_els(_els, Cdata);
decode_sasl_mechanism_mechanism_els([], Cdata) ->
    decode_sasl_mechanism_mechanism_cdata(Cdata).

encode_sasl_mechanism_mechanism([], _acc) -> _acc;
encode_sasl_mechanism_mechanism([Cdata | _tail],
				_acc) ->
    _els = encode_sasl_mechanism_mechanism_cdata(Cdata, []),
    _attrs = [],
    encode_sasl_mechanism_mechanism(_tail,
				    [{xmlel, <<"mechanism">>, _attrs, _els}
				     | _acc]).

decode_sasl_mechanism_mechanism_cdata(<<>>) ->
    undefined;
decode_sasl_mechanism_mechanism_cdata(_val) -> _val.

encode_sasl_mechanism_mechanism_cdata(undefined,
				      _acc) ->
    _acc;
encode_sasl_mechanism_mechanism_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_sasl_mechanisms_mechanisms({xmlel, _, _attrs,
				   _els}) ->
    Mechanism = decode_sasl_mechanisms_mechanisms_els(_els,
						      []),
    {sasl_mechanisms, Mechanism}.

decode_sasl_mechanisms_mechanisms_els([{xmlel,
					<<"mechanism">>, _attrs, _} =
					   _el
				       | _els],
				      Mechanism) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_sasl_mechanisms_mechanisms_els(_els,
						[decode_sasl_mechanism_mechanism(_el)
						 | Mechanism]);
      _ ->
	  decode_sasl_mechanisms_mechanisms_els(_els, Mechanism)
    end;
decode_sasl_mechanisms_mechanisms_els([_ | _els],
				      Mechanism) ->
    decode_sasl_mechanisms_mechanisms_els(_els, Mechanism);
decode_sasl_mechanisms_mechanisms_els([], Mechanism) ->
    xml_gen:reverse(Mechanism, 1, infinity).

encode_sasl_mechanisms_mechanisms(undefined, _acc) ->
    _acc;
encode_sasl_mechanisms_mechanisms({sasl_mechanisms,
				   Mechanism},
				  _acc) ->
    _els = encode_sasl_mechanism_mechanism(Mechanism, []),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-sasl">>}],
    [{xmlel, <<"mechanisms">>, _attrs, _els} | _acc].

decode_sasl_mechanisms_mechanisms_cdata(<<>>) ->
    undefined;
decode_sasl_mechanisms_mechanisms_cdata(_val) -> _val.

encode_sasl_mechanisms_mechanisms_cdata(undefined,
					_acc) ->
    _acc;
encode_sasl_mechanisms_mechanisms_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_starttls_starttls({xmlel, _, _attrs, _els}) ->
    Required = decode_starttls_starttls_els(_els, false),
    {starttls, Required}.

decode_starttls_starttls_els([{xmlel, <<"required">>,
			       _attrs, _} =
				  _el
			      | _els],
			     Required) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_starttls_starttls_els(_els,
				       decode_starttls_starttls_required(_el));
      _ -> decode_starttls_starttls_els(_els, Required)
    end;
decode_starttls_starttls_els([_ | _els], Required) ->
    decode_starttls_starttls_els(_els, Required);
decode_starttls_starttls_els([], Required) -> Required.

encode_starttls_starttls(undefined, _acc) -> _acc;
encode_starttls_starttls({starttls, Required}, _acc) ->
    _els = encode_starttls_starttls_required(Required, []),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-tls">>}],
    [{xmlel, <<"starttls">>, _attrs, _els} | _acc].

decode_starttls_starttls_cdata(<<>>) -> undefined;
decode_starttls_starttls_cdata(_val) -> _val.

encode_starttls_starttls_cdata(undefined, _acc) -> _acc;
encode_starttls_starttls_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_starttls_starttls_required({xmlel, _, _attrs,
				   _els}) ->
    true.

encode_starttls_starttls_required(false, _acc) -> _acc;
encode_starttls_starttls_required(true, _acc) ->
    _els = [],
    _attrs = [],
    [{xmlel, <<"required">>, _attrs, _els} | _acc].

decode_starttls_starttls_required_cdata(<<>>) ->
    undefined;
decode_starttls_starttls_required_cdata(_val) -> _val.

encode_starttls_starttls_required_cdata(undefined,
					_acc) ->
    _acc;
encode_starttls_starttls_required_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_starttls_proceed_proceed({xmlel, _, _attrs,
				 _els}) ->
    {starttls_proceed}.

encode_starttls_proceed_proceed(undefined, _acc) ->
    _acc;
encode_starttls_proceed_proceed({starttls_proceed},
				_acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-tls">>}],
    [{xmlel, <<"proceed">>, _attrs, _els} | _acc].

decode_starttls_proceed_proceed_cdata(<<>>) ->
    undefined;
decode_starttls_proceed_proceed_cdata(_val) -> _val.

encode_starttls_proceed_proceed_cdata(undefined,
				      _acc) ->
    _acc;
encode_starttls_proceed_proceed_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_starttls_failure_failure({xmlel, _, _attrs,
				 _els}) ->
    {starttls_failure}.

encode_starttls_failure_failure(undefined, _acc) ->
    _acc;
encode_starttls_failure_failure({starttls_failure},
				_acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-tls">>}],
    [{xmlel, <<"failure">>, _attrs, _els} | _acc].

decode_starttls_failure_failure_cdata(<<>>) ->
    undefined;
decode_starttls_failure_failure_cdata(_val) -> _val.

encode_starttls_failure_failure_cdata(undefined,
				      _acc) ->
    _acc;
encode_starttls_failure_failure_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_features_stream:features'({xmlel, _,
					  _attrs, _els}) ->
    __Els =
	'decode_stream_features_stream:features_els'(_els, []),
    {stream_features, __Els}.

'decode_stream_features_stream:features_els'([{xmlel, _,
					       _, _} =
						  _el
					      | _els],
					     __Els) ->
    'decode_stream_features_stream:features_els'(_els,
						 [decode(_el) | __Els]);
'decode_stream_features_stream:features_els'([_ | _els],
					     __Els) ->
    'decode_stream_features_stream:features_els'(_els,
						 __Els);
'decode_stream_features_stream:features_els'([],
					     __Els) ->
    lists:reverse(__Els).

'encode_stream_features_stream:features'(undefined,
					 _acc) ->
    _acc;
'encode_stream_features_stream:features'({stream_features,
					  __Els},
					 _acc) ->
    _els = [encode(_subel) || _subel <- __Els] ++ [],
    _attrs = [],
    [{xmlel, <<"stream:features">>, _attrs, _els} | _acc].

'decode_stream_features_stream:features_cdata'(<<>>) ->
    undefined;
'decode_stream_features_stream:features_cdata'(_val) ->
    _val.

'encode_stream_features_stream:features_cdata'(undefined,
					       _acc) ->
    _acc;
'encode_stream_features_stream:features_cdata'(_val,
					       _acc) ->
    [{xmlcdata, _val} | _acc].

decode_p1_push_push({xmlel, _, _attrs, _els}) ->
    {p1_push}.

encode_p1_push_push(undefined, _acc) -> _acc;
encode_p1_push_push({p1_push}, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>, <<"p1:push">>}],
    [{xmlel, <<"push">>, _attrs, _els} | _acc].

decode_p1_push_push_cdata(<<>>) -> undefined;
decode_p1_push_push_cdata(_val) -> _val.

encode_p1_push_push_cdata(undefined, _acc) -> _acc;
encode_p1_push_push_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_p1_rebind_rebind({xmlel, _, _attrs, _els}) ->
    {p1_rebind}.

encode_p1_rebind_rebind(undefined, _acc) -> _acc;
encode_p1_rebind_rebind({p1_rebind}, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>, <<"p1:rebind">>}],
    [{xmlel, <<"rebind">>, _attrs, _els} | _acc].

decode_p1_rebind_rebind_cdata(<<>>) -> undefined;
decode_p1_rebind_rebind_cdata(_val) -> _val.

encode_p1_rebind_rebind_cdata(undefined, _acc) -> _acc;
encode_p1_rebind_rebind_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_p1_ack_ack({xmlel, _, _attrs, _els}) -> {p1_ack}.

encode_p1_ack_ack(undefined, _acc) -> _acc;
encode_p1_ack_ack({p1_ack}, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>, <<"p1:ack">>}],
    [{xmlel, <<"ack">>, _attrs, _els} | _acc].

decode_p1_ack_ack_cdata(<<>>) -> undefined;
decode_p1_ack_ack_cdata(_val) -> _val.

encode_p1_ack_ack_cdata(undefined, _acc) -> _acc;
encode_p1_ack_ack_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_caps_c({xmlel, _, _attrs, _els}) ->
    {Ver, Node, Hash} = decode_caps_c_attrs(_attrs, <<>>,
					    <<>>, <<>>),
    {caps, Hash, Node, Ver}.

decode_caps_c_attrs([{<<"ver">>, _val} | _attrs], _Ver,
		    Node, Hash) ->
    decode_caps_c_attrs(_attrs, _val, Node, Hash);
decode_caps_c_attrs([{<<"node">>, _val} | _attrs], Ver,
		    _Node, Hash) ->
    decode_caps_c_attrs(_attrs, Ver, _val, Hash);
decode_caps_c_attrs([{<<"hash">>, _val} | _attrs], Ver,
		    Node, _Hash) ->
    decode_caps_c_attrs(_attrs, Ver, Node, _val);
decode_caps_c_attrs([_ | _attrs], Ver, Node, Hash) ->
    decode_caps_c_attrs(_attrs, Ver, Node, Hash);
decode_caps_c_attrs([], Ver, Node, Hash) ->
    {decode_caps_c_ver(Ver), decode_caps_c_node(Node),
     decode_caps_c_hash(Hash)}.

encode_caps_c(undefined, _acc) -> _acc;
encode_caps_c({caps, Hash, Node, Ver}, _acc) ->
    _els = [],
    _attrs = encode_caps_c_hash(Hash,
				encode_caps_c_node(Node,
						   encode_caps_c_ver(Ver,
								     [{<<"xmlns">>,
								       <<"http://jabber.org/protocol/caps">>}]))),
    [{xmlel, <<"c">>, _attrs, _els} | _acc].

decode_caps_c_hash(<<>>) -> undefined;
decode_caps_c_hash(_val) -> _val.

encode_caps_c_hash(undefined, _acc) -> _acc;
encode_caps_c_hash(_val, _acc) ->
    [{<<"hash">>, _val} | _acc].

decode_caps_c_node(<<>>) -> undefined;
decode_caps_c_node(_val) -> _val.

encode_caps_c_node(undefined, _acc) -> _acc;
encode_caps_c_node(_val, _acc) ->
    [{<<"node">>, _val} | _acc].

decode_caps_c_ver(<<>>) -> undefined;
decode_caps_c_ver(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"ver">>, <<"c">>,
			<<"http://jabber.org/protocol/caps">>});
      _res -> _res
    end.

encode_caps_c_ver(undefined, _acc) -> _acc;
encode_caps_c_ver(_val, _acc) ->
    [{<<"ver">>, base64:encode(_val)} | _acc].

decode_caps_c_cdata(<<>>) -> undefined;
decode_caps_c_cdata(_val) -> _val.

encode_caps_c_cdata(undefined, _acc) -> _acc;
encode_caps_c_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_register_register({xmlel, _, _attrs, _els}) ->
    {register}.

encode_register_register(undefined, _acc) -> _acc;
encode_register_register({register}, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"http://jabber.org/features/iq-register">>}],
    [{xmlel, <<"register">>, _attrs, _els} | _acc].

decode_register_register_cdata(<<>>) -> undefined;
decode_register_register_cdata(_val) -> _val.

encode_register_register_cdata(undefined, _acc) -> _acc;
encode_register_register_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_session_session({xmlel, _, _attrs, _els}) ->
    {session}.

encode_session_session(undefined, _acc) -> _acc;
encode_session_session({session}, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-session">>}],
    [{xmlel, <<"session">>, _attrs, _els} | _acc].

decode_session_session_cdata(<<>>) -> undefined;
decode_session_session_cdata(_val) -> _val.

encode_session_session_cdata(undefined, _acc) -> _acc;
encode_session_session_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_ping_ping({xmlel, _, _attrs, _els}) -> {ping}.

encode_ping_ping(undefined, _acc) -> _acc;
encode_ping_ping({ping}, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>, <<"urn:xmpp:ping">>}],
    [{xmlel, <<"ping">>, _attrs, _els} | _acc].

decode_ping_ping_cdata(<<>>) -> undefined;
decode_ping_ping_cdata(_val) -> _val.

encode_ping_ping_cdata(undefined, _acc) -> _acc;
encode_ping_ping_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_time_time({xmlel, _, _attrs, _els}) ->
    {Utc, Tzo} = decode_time_time_els(_els, undefined,
				      undefined),
    {time, Tzo, Utc}.

decode_time_time_els([{xmlel, <<"utc">>, _attrs, _} =
			  _el
		      | _els],
		     Utc, Tzo) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_time_time_els(_els, decode_time_time_utc(_el),
			       Tzo);
      _ -> decode_time_time_els(_els, Utc, Tzo)
    end;
decode_time_time_els([{xmlel, <<"tzo">>, _attrs, _} =
			  _el
		      | _els],
		     Utc, Tzo) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_time_time_els(_els, Utc,
			       decode_time_time_tzo(_el));
      _ -> decode_time_time_els(_els, Utc, Tzo)
    end;
decode_time_time_els([_ | _els], Utc, Tzo) ->
    decode_time_time_els(_els, Utc, Tzo);
decode_time_time_els([], Utc, Tzo) -> {Utc, Tzo}.

encode_time_time(undefined, _acc) -> _acc;
encode_time_time({time, Tzo, Utc}, _acc) ->
    _els = encode_time_time_tzo(Tzo,
				encode_time_time_utc(Utc, [])),
    _attrs = [{<<"xmlns">>, <<"urn:xmpp:time">>}],
    [{xmlel, <<"time">>, _attrs, _els} | _acc].

decode_time_time_cdata(<<>>) -> undefined;
decode_time_time_cdata(_val) -> _val.

encode_time_time_cdata(undefined, _acc) -> _acc;
encode_time_time_cdata(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

decode_time_time_utc({xmlel, _, _attrs, _els}) ->
    Cdata = decode_time_time_utc_els(_els, <<>>), Cdata.

decode_time_time_utc_els([{xmlcdata, _data} | _els],
			 Cdata) ->
    decode_time_time_utc_els(_els,
			     <<Cdata/binary, _data/binary>>);
decode_time_time_utc_els([_ | _els], Cdata) ->
    decode_time_time_utc_els(_els, Cdata);
decode_time_time_utc_els([], Cdata) ->
    decode_time_time_utc_cdata(Cdata).

encode_time_time_utc(undefined, _acc) -> _acc;
encode_time_time_utc(Cdata, _acc) ->
    _els = encode_time_time_utc_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"utc">>, _attrs, _els} | _acc].

decode_time_time_utc_cdata(<<>>) -> undefined;
decode_time_time_utc_cdata(_val) ->
    case catch dec_utc(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"utc">>, <<>>});
      _res -> _res
    end.

encode_time_time_utc_cdata(undefined, _acc) -> _acc;
encode_time_time_utc_cdata(_val, _acc) ->
    [{xmlcdata, enc_utc(_val)} | _acc].

decode_time_time_tzo({xmlel, _, _attrs, _els}) ->
    Cdata = decode_time_time_tzo_els(_els, <<>>), Cdata.

decode_time_time_tzo_els([{xmlcdata, _data} | _els],
			 Cdata) ->
    decode_time_time_tzo_els(_els,
			     <<Cdata/binary, _data/binary>>);
decode_time_time_tzo_els([_ | _els], Cdata) ->
    decode_time_time_tzo_els(_els, Cdata);
decode_time_time_tzo_els([], Cdata) ->
    decode_time_time_tzo_cdata(Cdata).

encode_time_time_tzo(undefined, _acc) -> _acc;
encode_time_time_tzo(Cdata, _acc) ->
    _els = encode_time_time_tzo_cdata(Cdata, []),
    _attrs = [],
    [{xmlel, <<"tzo">>, _attrs, _els} | _acc].

decode_time_time_tzo_cdata(<<>>) -> undefined;
decode_time_time_tzo_cdata(_val) ->
    case catch dec_tzo(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"tzo">>, <<>>});
      _res -> _res
    end.

encode_time_time_tzo_cdata(undefined, _acc) -> _acc;
encode_time_time_tzo_cdata(_val, _acc) ->
    [{xmlcdata, enc_tzo(_val)} | _acc].

'decode_stream_error_stream:error'({xmlel, _, _attrs,
				    _els}) ->
    {Text, Reason} =
	'decode_stream_error_stream:error_els'(_els, undefined,
					       undefined),
    {stream_error, Reason, Text}.

'decode_stream_error_stream:error_els'([{xmlel,
					 <<"text">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els,
						 'decode_stream_error_stream:error_text'(_el),
						 Reason);
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"unsupported-version">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_unsupported-version'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"unsupported-stanza-type">>, _attrs,
					 _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_unsupported-stanza-type'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"unsupported-encoding">>, _attrs,
					 _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_unsupported-encoding'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"undefined-condition">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_undefined-condition'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"system-shutdown">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_system-shutdown'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"see-other-host">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_see-other-host'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"restricted-xml">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_restricted-xml'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"resource-constraint">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_resource-constraint'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"reset">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_reset'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"remote-connection-failed">>, _attrs,
					 _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_remote-connection-failed'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"policy-violation">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_policy-violation'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"not-well-formed">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_not-well-formed'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"not-authorized">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_not-authorized'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"invalid-xml">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_invalid-xml'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"invalid-namespace">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_invalid-namespace'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"invalid-id">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_invalid-id'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"invalid-from">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_invalid-from'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"internal-server-error">>, _attrs,
					 _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_internal-server-error'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"improper-addressing">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_improper-addressing'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"host-unknown">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_host-unknown'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"host-gone">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_host-gone'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"connection-timeout">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_connection-timeout'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"conflict">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_conflict'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"bad-namespace-prefix">>, _attrs,
					 _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_bad-namespace-prefix'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([{xmlel,
					 <<"bad-format">>, _attrs, _} =
					    _el
					| _els],
				       Text, Reason) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<"urn:ietf:params:xml:ns:xmpp-streams">> ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 'decode_stream_error_stream:error_bad-format'(_el));
      _ ->
	  'decode_stream_error_stream:error_els'(_els, Text,
						 Reason)
    end;
'decode_stream_error_stream:error_els'([_ | _els], Text,
				       Reason) ->
    'decode_stream_error_stream:error_els'(_els, Text,
					   Reason);
'decode_stream_error_stream:error_els'([], Text,
				       Reason) ->
    {Text, Reason}.

'encode_stream_error_stream:error_$reason'(undefined,
					   _acc) ->
    _acc;
'encode_stream_error_stream:error_$reason'('unsupported-version' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_unsupported-version'(_r,
							   _acc);
'encode_stream_error_stream:error_$reason'('unsupported-stanza-type' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_unsupported-stanza-type'(_r,
							       _acc);
'encode_stream_error_stream:error_$reason'('unsupported-encoding' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_unsupported-encoding'(_r,
							    _acc);
'encode_stream_error_stream:error_$reason'('undefined-condition' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_undefined-condition'(_r,
							   _acc);
'encode_stream_error_stream:error_$reason'('system-shutdown' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_system-shutdown'(_r,
						       _acc);
'encode_stream_error_stream:error_$reason'({'see-other-host',
					    _} =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_see-other-host'(_r,
						      _acc);
'encode_stream_error_stream:error_$reason'('restricted-xml' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_restricted-xml'(_r,
						      _acc);
'encode_stream_error_stream:error_$reason'('resource-constraint' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_resource-constraint'(_r,
							   _acc);
'encode_stream_error_stream:error_$reason'(reset = _r,
					   _acc) ->
    'encode_stream_error_stream:error_reset'(_r, _acc);
'encode_stream_error_stream:error_$reason'('remote-connection-failed' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_remote-connection-failed'(_r,
								_acc);
'encode_stream_error_stream:error_$reason'('policy-violation' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_policy-violation'(_r,
							_acc);
'encode_stream_error_stream:error_$reason'('not-well-formed' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_not-well-formed'(_r,
						       _acc);
'encode_stream_error_stream:error_$reason'('not-authorized' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_not-authorized'(_r,
						      _acc);
'encode_stream_error_stream:error_$reason'('invalid-xml' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_invalid-xml'(_r,
						   _acc);
'encode_stream_error_stream:error_$reason'('invalid-namespace' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_invalid-namespace'(_r,
							 _acc);
'encode_stream_error_stream:error_$reason'('invalid-id' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_invalid-id'(_r, _acc);
'encode_stream_error_stream:error_$reason'('invalid-from' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_invalid-from'(_r,
						    _acc);
'encode_stream_error_stream:error_$reason'('internal-server-error' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_internal-server-error'(_r,
							     _acc);
'encode_stream_error_stream:error_$reason'('improper-addressing' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_improper-addressing'(_r,
							   _acc);
'encode_stream_error_stream:error_$reason'('host-unknown' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_host-unknown'(_r,
						    _acc);
'encode_stream_error_stream:error_$reason'('host-gone' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_host-gone'(_r, _acc);
'encode_stream_error_stream:error_$reason'('connection-timeout' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_connection-timeout'(_r,
							  _acc);
'encode_stream_error_stream:error_$reason'(conflict =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_conflict'(_r, _acc);
'encode_stream_error_stream:error_$reason'('bad-namespace-prefix' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_bad-namespace-prefix'(_r,
							    _acc);
'encode_stream_error_stream:error_$reason'('bad-format' =
					       _r,
					   _acc) ->
    'encode_stream_error_stream:error_bad-format'(_r, _acc).

'encode_stream_error_stream:error'(undefined, _acc) ->
    _acc;
'encode_stream_error_stream:error'({stream_error,
				    Reason, Text},
				   _acc) ->
    _els =
	'encode_stream_error_stream:error_$reason'(Reason,
						   'encode_stream_error_stream:error_text'(Text,
											   [])),
    _attrs = [],
    [{xmlel, <<"stream:error">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_cdata'(_val) -> _val.

'encode_stream_error_stream:error_cdata'(undefined,
					 _acc) ->
    _acc;
'encode_stream_error_stream:error_cdata'(_val, _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_unsupported-version'({xmlel,
							_, _attrs, _els}) ->
    'unsupported-version'.

'encode_stream_error_stream:error_unsupported-version'(undefined,
						       _acc) ->
    _acc;
'encode_stream_error_stream:error_unsupported-version'('unsupported-version',
						       _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"unsupported-version">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_unsupported-version_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_unsupported-version_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_unsupported-version_cdata'(undefined,
							     _acc) ->
    _acc;
'encode_stream_error_stream:error_unsupported-version_cdata'(_val,
							     _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_unsupported-stanza-type'({xmlel,
							    _, _attrs, _els}) ->
    'unsupported-stanza-type'.

'encode_stream_error_stream:error_unsupported-stanza-type'(undefined,
							   _acc) ->
    _acc;
'encode_stream_error_stream:error_unsupported-stanza-type'('unsupported-stanza-type',
							   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"unsupported-stanza-type">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_unsupported-stanza-type_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_unsupported-stanza-type_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_unsupported-stanza-type_cdata'(undefined,
								 _acc) ->
    _acc;
'encode_stream_error_stream:error_unsupported-stanza-type_cdata'(_val,
								 _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_unsupported-encoding'({xmlel,
							 _, _attrs, _els}) ->
    'unsupported-encoding'.

'encode_stream_error_stream:error_unsupported-encoding'(undefined,
							_acc) ->
    _acc;
'encode_stream_error_stream:error_unsupported-encoding'('unsupported-encoding',
							_acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"unsupported-encoding">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_unsupported-encoding_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_unsupported-encoding_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_unsupported-encoding_cdata'(undefined,
							      _acc) ->
    _acc;
'encode_stream_error_stream:error_unsupported-encoding_cdata'(_val,
							      _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_undefined-condition'({xmlel,
							_, _attrs, _els}) ->
    'undefined-condition'.

'encode_stream_error_stream:error_undefined-condition'(undefined,
						       _acc) ->
    _acc;
'encode_stream_error_stream:error_undefined-condition'('undefined-condition',
						       _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"undefined-condition">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_undefined-condition_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_undefined-condition_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_undefined-condition_cdata'(undefined,
							     _acc) ->
    _acc;
'encode_stream_error_stream:error_undefined-condition_cdata'(_val,
							     _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_system-shutdown'({xmlel,
						    _, _attrs, _els}) ->
    'system-shutdown'.

'encode_stream_error_stream:error_system-shutdown'(undefined,
						   _acc) ->
    _acc;
'encode_stream_error_stream:error_system-shutdown'('system-shutdown',
						   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"system-shutdown">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_system-shutdown_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_system-shutdown_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_system-shutdown_cdata'(undefined,
							 _acc) ->
    _acc;
'encode_stream_error_stream:error_system-shutdown_cdata'(_val,
							 _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_see-other-host'({xmlel,
						   _, _attrs, _els}) ->
    Cdata =
	'decode_stream_error_stream:error_see-other-host_els'(_els,
							      <<>>),
    {'see-other-host', Cdata}.

'decode_stream_error_stream:error_see-other-host_els'([{xmlcdata,
							_data}
						       | _els],
						      Cdata) ->
    'decode_stream_error_stream:error_see-other-host_els'(_els,
							  <<Cdata/binary,
							    _data/binary>>);
'decode_stream_error_stream:error_see-other-host_els'([_
						       | _els],
						      Cdata) ->
    'decode_stream_error_stream:error_see-other-host_els'(_els,
							  Cdata);
'decode_stream_error_stream:error_see-other-host_els'([],
						      Cdata) ->
    'decode_stream_error_stream:error_see-other-host_cdata'(Cdata).

'encode_stream_error_stream:error_see-other-host'(undefined,
						  _acc) ->
    _acc;
'encode_stream_error_stream:error_see-other-host'({'see-other-host',
						   Cdata},
						  _acc) ->
    _els =
	'encode_stream_error_stream:error_see-other-host_cdata'(Cdata,
								[]),
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"see-other-host">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_see-other-host_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_see-other-host_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_see-other-host_cdata'(undefined,
							_acc) ->
    _acc;
'encode_stream_error_stream:error_see-other-host_cdata'(_val,
							_acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_restricted-xml'({xmlel,
						   _, _attrs, _els}) ->
    'restricted-xml'.

'encode_stream_error_stream:error_restricted-xml'(undefined,
						  _acc) ->
    _acc;
'encode_stream_error_stream:error_restricted-xml'('restricted-xml',
						  _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"restricted-xml">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_restricted-xml_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_restricted-xml_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_restricted-xml_cdata'(undefined,
							_acc) ->
    _acc;
'encode_stream_error_stream:error_restricted-xml_cdata'(_val,
							_acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_resource-constraint'({xmlel,
							_, _attrs, _els}) ->
    'resource-constraint'.

'encode_stream_error_stream:error_resource-constraint'(undefined,
						       _acc) ->
    _acc;
'encode_stream_error_stream:error_resource-constraint'('resource-constraint',
						       _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"resource-constraint">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_resource-constraint_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_resource-constraint_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_resource-constraint_cdata'(undefined,
							     _acc) ->
    _acc;
'encode_stream_error_stream:error_resource-constraint_cdata'(_val,
							     _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_reset'({xmlel, _,
					  _attrs, _els}) ->
    reset.

'encode_stream_error_stream:error_reset'(undefined,
					 _acc) ->
    _acc;
'encode_stream_error_stream:error_reset'(reset, _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"reset">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_reset_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_reset_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_reset_cdata'(undefined,
					       _acc) ->
    _acc;
'encode_stream_error_stream:error_reset_cdata'(_val,
					       _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_remote-connection-failed'({xmlel,
							     _, _attrs,
							     _els}) ->
    'remote-connection-failed'.

'encode_stream_error_stream:error_remote-connection-failed'(undefined,
							    _acc) ->
    _acc;
'encode_stream_error_stream:error_remote-connection-failed'('remote-connection-failed',
							    _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"remote-connection-failed">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_remote-connection-failed_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_remote-connection-failed_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_remote-connection-failed_cdata'(undefined,
								  _acc) ->
    _acc;
'encode_stream_error_stream:error_remote-connection-failed_cdata'(_val,
								  _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_policy-violation'({xmlel,
						     _, _attrs, _els}) ->
    'policy-violation'.

'encode_stream_error_stream:error_policy-violation'(undefined,
						    _acc) ->
    _acc;
'encode_stream_error_stream:error_policy-violation'('policy-violation',
						    _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"policy-violation">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_policy-violation_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_policy-violation_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_policy-violation_cdata'(undefined,
							  _acc) ->
    _acc;
'encode_stream_error_stream:error_policy-violation_cdata'(_val,
							  _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_not-well-formed'({xmlel,
						    _, _attrs, _els}) ->
    'not-well-formed'.

'encode_stream_error_stream:error_not-well-formed'(undefined,
						   _acc) ->
    _acc;
'encode_stream_error_stream:error_not-well-formed'('not-well-formed',
						   _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"not-well-formed">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_not-well-formed_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_not-well-formed_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_not-well-formed_cdata'(undefined,
							 _acc) ->
    _acc;
'encode_stream_error_stream:error_not-well-formed_cdata'(_val,
							 _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_not-authorized'({xmlel,
						   _, _attrs, _els}) ->
    'not-authorized'.

'encode_stream_error_stream:error_not-authorized'(undefined,
						  _acc) ->
    _acc;
'encode_stream_error_stream:error_not-authorized'('not-authorized',
						  _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"not-authorized">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_not-authorized_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_not-authorized_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_not-authorized_cdata'(undefined,
							_acc) ->
    _acc;
'encode_stream_error_stream:error_not-authorized_cdata'(_val,
							_acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_invalid-xml'({xmlel,
						_, _attrs, _els}) ->
    'invalid-xml'.

'encode_stream_error_stream:error_invalid-xml'(undefined,
					       _acc) ->
    _acc;
'encode_stream_error_stream:error_invalid-xml'('invalid-xml',
					       _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"invalid-xml">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_invalid-xml_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_invalid-xml_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_invalid-xml_cdata'(undefined,
						     _acc) ->
    _acc;
'encode_stream_error_stream:error_invalid-xml_cdata'(_val,
						     _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_invalid-namespace'({xmlel,
						      _, _attrs, _els}) ->
    'invalid-namespace'.

'encode_stream_error_stream:error_invalid-namespace'(undefined,
						     _acc) ->
    _acc;
'encode_stream_error_stream:error_invalid-namespace'('invalid-namespace',
						     _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"invalid-namespace">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_invalid-namespace_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_invalid-namespace_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_invalid-namespace_cdata'(undefined,
							   _acc) ->
    _acc;
'encode_stream_error_stream:error_invalid-namespace_cdata'(_val,
							   _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_invalid-id'({xmlel, _,
					       _attrs, _els}) ->
    'invalid-id'.

'encode_stream_error_stream:error_invalid-id'(undefined,
					      _acc) ->
    _acc;
'encode_stream_error_stream:error_invalid-id'('invalid-id',
					      _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"invalid-id">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_invalid-id_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_invalid-id_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_invalid-id_cdata'(undefined,
						    _acc) ->
    _acc;
'encode_stream_error_stream:error_invalid-id_cdata'(_val,
						    _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_invalid-from'({xmlel,
						 _, _attrs, _els}) ->
    'invalid-from'.

'encode_stream_error_stream:error_invalid-from'(undefined,
						_acc) ->
    _acc;
'encode_stream_error_stream:error_invalid-from'('invalid-from',
						_acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"invalid-from">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_invalid-from_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_invalid-from_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_invalid-from_cdata'(undefined,
						      _acc) ->
    _acc;
'encode_stream_error_stream:error_invalid-from_cdata'(_val,
						      _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_internal-server-error'({xmlel,
							  _, _attrs, _els}) ->
    'internal-server-error'.

'encode_stream_error_stream:error_internal-server-error'(undefined,
							 _acc) ->
    _acc;
'encode_stream_error_stream:error_internal-server-error'('internal-server-error',
							 _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"internal-server-error">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_internal-server-error_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_internal-server-error_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_internal-server-error_cdata'(undefined,
							       _acc) ->
    _acc;
'encode_stream_error_stream:error_internal-server-error_cdata'(_val,
							       _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_improper-addressing'({xmlel,
							_, _attrs, _els}) ->
    'improper-addressing'.

'encode_stream_error_stream:error_improper-addressing'(undefined,
						       _acc) ->
    _acc;
'encode_stream_error_stream:error_improper-addressing'('improper-addressing',
						       _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"improper-addressing">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_improper-addressing_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_improper-addressing_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_improper-addressing_cdata'(undefined,
							     _acc) ->
    _acc;
'encode_stream_error_stream:error_improper-addressing_cdata'(_val,
							     _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_host-unknown'({xmlel,
						 _, _attrs, _els}) ->
    'host-unknown'.

'encode_stream_error_stream:error_host-unknown'(undefined,
						_acc) ->
    _acc;
'encode_stream_error_stream:error_host-unknown'('host-unknown',
						_acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"host-unknown">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_host-unknown_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_host-unknown_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_host-unknown_cdata'(undefined,
						      _acc) ->
    _acc;
'encode_stream_error_stream:error_host-unknown_cdata'(_val,
						      _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_host-gone'({xmlel, _,
					      _attrs, _els}) ->
    'host-gone'.

'encode_stream_error_stream:error_host-gone'(undefined,
					     _acc) ->
    _acc;
'encode_stream_error_stream:error_host-gone'('host-gone',
					     _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"host-gone">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_host-gone_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_host-gone_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_host-gone_cdata'(undefined,
						   _acc) ->
    _acc;
'encode_stream_error_stream:error_host-gone_cdata'(_val,
						   _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_connection-timeout'({xmlel,
						       _, _attrs, _els}) ->
    'connection-timeout'.

'encode_stream_error_stream:error_connection-timeout'(undefined,
						      _acc) ->
    _acc;
'encode_stream_error_stream:error_connection-timeout'('connection-timeout',
						      _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"connection-timeout">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_connection-timeout_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_connection-timeout_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_connection-timeout_cdata'(undefined,
							    _acc) ->
    _acc;
'encode_stream_error_stream:error_connection-timeout_cdata'(_val,
							    _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_conflict'({xmlel, _,
					     _attrs, _els}) ->
    conflict.

'encode_stream_error_stream:error_conflict'(undefined,
					    _acc) ->
    _acc;
'encode_stream_error_stream:error_conflict'(conflict,
					    _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"conflict">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_conflict_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_conflict_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_conflict_cdata'(undefined,
						  _acc) ->
    _acc;
'encode_stream_error_stream:error_conflict_cdata'(_val,
						  _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_bad-namespace-prefix'({xmlel,
							 _, _attrs, _els}) ->
    'bad-namespace-prefix'.

'encode_stream_error_stream:error_bad-namespace-prefix'(undefined,
							_acc) ->
    _acc;
'encode_stream_error_stream:error_bad-namespace-prefix'('bad-namespace-prefix',
							_acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"bad-namespace-prefix">>, _attrs, _els}
     | _acc].

'decode_stream_error_stream:error_bad-namespace-prefix_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_bad-namespace-prefix_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_bad-namespace-prefix_cdata'(undefined,
							      _acc) ->
    _acc;
'encode_stream_error_stream:error_bad-namespace-prefix_cdata'(_val,
							      _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_bad-format'({xmlel, _,
					       _attrs, _els}) ->
    'bad-format'.

'encode_stream_error_stream:error_bad-format'(undefined,
					      _acc) ->
    _acc;
'encode_stream_error_stream:error_bad-format'('bad-format',
					      _acc) ->
    _els = [],
    _attrs = [{<<"xmlns">>,
	       <<"urn:ietf:params:xml:ns:xmpp-streams">>}],
    [{xmlel, <<"bad-format">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_bad-format_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_bad-format_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_bad-format_cdata'(undefined,
						    _acc) ->
    _acc;
'encode_stream_error_stream:error_bad-format_cdata'(_val,
						    _acc) ->
    [{xmlcdata, _val} | _acc].

'decode_stream_error_stream:error_text'({xmlel, _,
					 _attrs, _els}) ->
    Text_lang =
	'decode_stream_error_stream:error_text_attrs'(_attrs,
						      <<>>),
    Cdata =
	'decode_stream_error_stream:error_text_els'(_els, <<>>),
    {Text_lang, Cdata}.

'decode_stream_error_stream:error_text_els'([{xmlcdata,
					      _data}
					     | _els],
					    Cdata) ->
    'decode_stream_error_stream:error_text_els'(_els,
						<<Cdata/binary, _data/binary>>);
'decode_stream_error_stream:error_text_els'([_ | _els],
					    Cdata) ->
    'decode_stream_error_stream:error_text_els'(_els,
						Cdata);
'decode_stream_error_stream:error_text_els'([],
					    Cdata) ->
    'decode_stream_error_stream:error_text_cdata'(Cdata).

'decode_stream_error_stream:error_text_attrs'([{<<"xml:lang">>,
						_val}
					       | _attrs],
					      _Text_lang) ->
    'decode_stream_error_stream:error_text_attrs'(_attrs,
						  _val);
'decode_stream_error_stream:error_text_attrs'([_
					       | _attrs],
					      Text_lang) ->
    'decode_stream_error_stream:error_text_attrs'(_attrs,
						  Text_lang);
'decode_stream_error_stream:error_text_attrs'([],
					      Text_lang) ->
    'decode_stream_error_stream:error_text_xml:lang'(Text_lang).

'encode_stream_error_stream:error_text'(undefined,
					_acc) ->
    _acc;
'encode_stream_error_stream:error_text'({Text_lang,
					 Cdata},
					_acc) ->
    _els =
	'encode_stream_error_stream:error_text_cdata'(Cdata,
						      []),
    _attrs =
	'encode_stream_error_stream:error_text_xml:lang'(Text_lang,
							 [{<<"xmlns">>,
							   <<"urn:ietf:params:xml:ns:xmpp-streams">>}]),
    [{xmlel, <<"text">>, _attrs, _els} | _acc].

'decode_stream_error_stream:error_text_xml:lang'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_text_xml:lang'(_val) ->
    _val.

'encode_stream_error_stream:error_text_xml:lang'(undefined,
						 _acc) ->
    _acc;
'encode_stream_error_stream:error_text_xml:lang'(_val,
						 _acc) ->
    [{<<"xml:lang">>, _val} | _acc].

'decode_stream_error_stream:error_text_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_text_cdata'(_val) ->
    _val.

'encode_stream_error_stream:error_text_cdata'(undefined,
					      _acc) ->
    _acc;
'encode_stream_error_stream:error_text_cdata'(_val,
					      _acc) ->
    [{xmlcdata, _val} | _acc].
