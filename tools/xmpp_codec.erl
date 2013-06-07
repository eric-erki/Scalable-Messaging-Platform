-module(xmpp_codec).

-compile([nowarn_unused_function]).

-export([decode/1]).

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
      {<<"query">>,
       <<"http://jabber.org/protocol/disco#items">>} ->
	  decode_disco_items_query(_el);
      {<<"query">>,
       <<"http://jabber.org/protocol/disco#info">>} ->
	  decode_disco_info_query(_el);
      {<<"query">>, <<"jabber:iq:roster">>} ->
	  decode_roster_query(_el);
      {<<"query">>, <<"jabber:iq:version">>} ->
	  decode_version_query(_el);
      {<<"query">>, <<"jabber:iq:last">>} ->
	  decode_last_query(_el);
      {_name, _xmlns} ->
	  erlang:error({unknown_tag, _name, _xmlns})
    end.

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

decode_last_query_seconds(<<>>) -> undefined;
decode_last_query_seconds(_val) ->
    case catch xml_gen:dec_int(_val, 0, infinity) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"seconds">>,
			<<"query">>, <<"jabber:iq:last">>});
      _res -> _res
    end.

decode_last_query_cdata(<<>>) -> undefined;
decode_last_query_cdata(_val) -> _val.

decode_version_query({xmlel, _, _attrs, _els}) ->
    {Os, Version, Name} = decode_version_query_els(_els,
						   undefined, [], []),
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
				   [decode_version_query_version(_el)
				    | Version],
				   Name);
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
				   [decode_version_query_name(_el) | Name]);
      _ -> decode_version_query_els(_els, Os, Version, Name)
    end;
decode_version_query_els([_ | _els], Os, Version,
			 Name) ->
    decode_version_query_els(_els, Os, Version, Name);
decode_version_query_els([], Os, [Version], [Name]) ->
    {Os, Version, Name}.

decode_version_query_cdata(<<>>) -> undefined;
decode_version_query_cdata(_val) -> _val.

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

decode_version_query_os_cdata(<<>>) ->
    erlang:error({missing_cdata, <<>>, <<"os">>, <<>>});
decode_version_query_os_cdata(_val) -> _val.

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

decode_version_query_version_cdata(<<>>) ->
    erlang:error({missing_cdata, <<>>, <<"version">>,
		  <<>>});
decode_version_query_version_cdata(_val) -> _val.

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

decode_version_query_name_cdata(<<>>) ->
    erlang:error({missing_cdata, <<>>, <<"name">>, <<>>});
decode_version_query_name_cdata(_val) -> _val.

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

decode_roster_query_ver(<<>>) -> undefined;
decode_roster_query_ver(_val) -> _val.

decode_roster_query_cdata(<<>>) -> undefined;
decode_roster_query_cdata(_val) -> _val.

decode_roster_query_item({xmlel, _, _attrs, _els}) ->
    {Ask, Subscription, Name, Jid} =
	decode_roster_query_item_attrs(_attrs, <<>>, <<>>, <<>>,
				       <<>>),
    Groups = decode_roster_query_item_els(_els, []),
    {item, Jid, Name, Groups, Subscription, Ask}.

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

decode_roster_query_item_jid(<<>>) ->
    erlang:error({missing_attr, <<"jid">>, <<"item">>,
		  <<>>});
decode_roster_query_item_jid(_val) -> _val.

decode_roster_query_item_name(<<>>) -> undefined;
decode_roster_query_item_name(_val) -> _val.

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

decode_roster_query_item_ask(<<>>) -> undefined;
decode_roster_query_item_ask(_val) ->
    case catch xml_gen:dec_enum(_val, [subscribe]) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"ask">>, <<"item">>,
			<<>>});
      _res -> _res
    end.

decode_roster_query_item_cdata(<<>>) -> undefined;
decode_roster_query_item_cdata(_val) -> _val.

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

decode_roster_query_item_group_cdata(<<>>) ->
    erlang:error({missing_cdata, <<>>, <<"group">>, <<>>});
decode_roster_query_item_group_cdata(_val) -> _val.

decode_disco_info_query({xmlel, _, _attrs, _els}) ->
    {Feature, Identity} = decode_disco_info_query_els(_els,
						      [], []),
    {disco_info, Identity, Feature}.

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

decode_disco_info_query_cdata(<<>>) -> undefined;
decode_disco_info_query_cdata(_val) -> _val.

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

decode_disco_info_query_feature_var(<<>>) ->
    erlang:error({missing_attr, <<"var">>, <<"feature">>,
		  <<>>});
decode_disco_info_query_feature_var(_val) -> _val.

decode_disco_info_query_feature_cdata(<<>>) ->
    undefined;
decode_disco_info_query_feature_cdata(_val) -> _val.

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

decode_disco_info_query_identity_category(<<>>) ->
    erlang:error({missing_attr, <<"category">>,
		  <<"identity">>, <<>>});
decode_disco_info_query_identity_category(_val) -> _val.

decode_disco_info_query_identity_type(<<>>) ->
    erlang:error({missing_attr, <<"type">>, <<"identity">>,
		  <<>>});
decode_disco_info_query_identity_type(_val) -> _val.

decode_disco_info_query_identity_name(<<>>) ->
    undefined;
decode_disco_info_query_identity_name(_val) -> _val.

decode_disco_info_query_identity_cdata(<<>>) ->
    undefined;
decode_disco_info_query_identity_cdata(_val) -> _val.

decode_disco_items_query({xmlel, _, _attrs, _els}) ->
    Node = decode_disco_items_query_attrs(_attrs, <<>>),
    Item = decode_disco_items_query_els(_els, []),
    {disco_items, Node, Item}.

decode_disco_items_query_els([{xmlel, <<"item">>,
			       _attrs, _} =
				  _el
			      | _els],
			     Item) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_disco_items_query_els(_els,
				       [decode_disco_items_query_item(_el)
					| Item]);
      _ -> decode_disco_items_query_els(_els, Item)
    end;
decode_disco_items_query_els([_ | _els], Item) ->
    decode_disco_items_query_els(_els, Item);
decode_disco_items_query_els([], Item) ->
    lists:reverse(Item).

decode_disco_items_query_attrs([{<<"node">>, _val}
				| _attrs],
			       _Node) ->
    decode_disco_items_query_attrs(_attrs, _val);
decode_disco_items_query_attrs([_ | _attrs], Node) ->
    decode_disco_items_query_attrs(_attrs, Node);
decode_disco_items_query_attrs([], Node) ->
    decode_disco_items_query_node(Node).

decode_disco_items_query_node(<<>>) -> undefined;
decode_disco_items_query_node(_val) -> _val.

decode_disco_items_query_cdata(<<>>) -> undefined;
decode_disco_items_query_cdata(_val) -> _val.

decode_disco_items_query_item({xmlel, _, _attrs,
			       _els}) ->
    {Node, Name, Jid} =
	decode_disco_items_query_item_attrs(_attrs, <<>>, <<>>,
					    <<>>),
    {Jid, Name, Node}.

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

decode_disco_items_query_item_name(<<>>) -> undefined;
decode_disco_items_query_item_name(_val) -> _val.

decode_disco_items_query_item_node(<<>>) -> undefined;
decode_disco_items_query_item_node(_val) -> _val.

decode_disco_items_query_item_cdata(<<>>) -> undefined;
decode_disco_items_query_item_cdata(_val) -> _val.

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

decode_stats_query_cdata(<<>>) -> undefined;
decode_stats_query_cdata(_val) -> _val.

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

decode_stats_query_stat_name(<<>>) ->
    erlang:error({missing_attr, <<"name">>, <<"stat">>,
		  <<>>});
decode_stats_query_stat_name(_val) -> _val.

decode_stats_query_stat_units(<<>>) -> undefined;
decode_stats_query_stat_units(_val) -> _val.

decode_stats_query_stat_value(<<>>) -> undefined;
decode_stats_query_stat_value(_val) -> _val.

decode_stats_query_stat_cdata(<<>>) -> undefined;
decode_stats_query_stat_cdata(_val) -> _val.

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

decode_stats_query_stat_error_cdata(<<>>) -> undefined;
decode_stats_query_stat_error_cdata(_val) -> _val.

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

decode_iq_iq_id(<<>>) ->
    erlang:error({missing_attr, <<"id">>, <<"iq">>, <<>>});
decode_iq_iq_id(_val) -> _val.

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

decode_iq_iq_from(<<>>) -> undefined;
decode_iq_iq_from(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"from">>, <<"iq">>,
			<<>>});
      _res -> _res
    end.

decode_iq_iq_to(<<>>) -> undefined;
decode_iq_iq_to(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"to">>, <<"iq">>,
			<<>>});
      _res -> _res
    end.

'decode_iq_iq_xml:lang'(<<>>) -> undefined;
'decode_iq_iq_xml:lang'(_val) -> _val.

decode_iq_iq_cdata(<<>>) -> undefined;
decode_iq_iq_cdata(_val) -> _val.

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

decode_message_message_id(<<>>) -> undefined;
decode_message_message_id(_val) -> _val.

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

decode_message_message_from(<<>>) -> undefined;
decode_message_message_from(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"from">>, <<"message">>,
			<<>>});
      _res -> _res
    end.

decode_message_message_to(<<>>) -> undefined;
decode_message_message_to(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"to">>, <<"message">>,
			<<>>});
      _res -> _res
    end.

'decode_message_message_xml:lang'(<<>>) -> undefined;
'decode_message_message_xml:lang'(_val) -> _val.

decode_message_message_cdata(<<>>) -> undefined;
decode_message_message_cdata(_val) -> _val.

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

decode_message_message_thread_cdata(<<>>) -> undefined;
decode_message_message_thread_cdata(_val) -> _val.

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

'decode_message_message_body_xml:lang'(<<>>) ->
    undefined;
'decode_message_message_body_xml:lang'(_val) -> _val.

decode_message_message_body_cdata(<<>>) -> undefined;
decode_message_message_body_cdata(_val) -> _val.

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

'decode_message_message_subject_xml:lang'(<<>>) ->
    undefined;
'decode_message_message_subject_xml:lang'(_val) -> _val.

decode_message_message_subject_cdata(<<>>) -> undefined;
decode_message_message_subject_cdata(_val) -> _val.

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

decode_presence_presence_id(<<>>) -> undefined;
decode_presence_presence_id(_val) -> _val.

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

decode_presence_presence_from(<<>>) -> undefined;
decode_presence_presence_from(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"from">>,
			<<"presence">>, <<>>});
      _res -> _res
    end.

decode_presence_presence_to(<<>>) -> undefined;
decode_presence_presence_to(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"to">>, <<"presence">>,
			<<>>});
      _res -> _res
    end.

'decode_presence_presence_xml:lang'(<<>>) -> undefined;
'decode_presence_presence_xml:lang'(_val) -> _val.

decode_presence_presence_cdata(<<>>) -> undefined;
decode_presence_presence_cdata(_val) -> _val.

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

decode_presence_presence_priority_cdata(<<>>) ->
    undefined;
decode_presence_presence_priority_cdata(_val) ->
    case catch xml_gen:dec_int(_val, -128, 127) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"priority">>,
			<<>>});
      _res -> _res
    end.

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

'decode_presence_presence_status_xml:lang'(<<>>) ->
    undefined;
'decode_presence_presence_status_xml:lang'(_val) ->
    _val.

decode_presence_presence_status_cdata(<<>>) ->
    undefined;
decode_presence_presence_status_cdata(_val) -> _val.

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

decode_presence_presence_show_cdata(<<>>) -> undefined;
decode_presence_presence_show_cdata(_val) ->
    case catch xml_gen:dec_enum(_val, [away, chat, dnd, xa])
	of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"show">>, <<>>});
      _res -> _res
    end.

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

decode_error_error_by(<<>>) -> undefined;
decode_error_error_by(_val) -> _val.

decode_error_error_cdata(<<>>) -> undefined;
decode_error_error_cdata(_val) -> _val.

'decode_error_error_unexpected-request'({xmlel, _,
					 _attrs, _els}) ->
    'unexpected-request'.

'decode_error_error_unexpected-request_cdata'(<<>>) ->
    undefined;
'decode_error_error_unexpected-request_cdata'(_val) ->
    _val.

'decode_error_error_undefined-condition'({xmlel, _,
					  _attrs, _els}) ->
    'undefined-condition'.

'decode_error_error_undefined-condition_cdata'(<<>>) ->
    undefined;
'decode_error_error_undefined-condition_cdata'(_val) ->
    _val.

'decode_error_error_subscription-required'({xmlel, _,
					    _attrs, _els}) ->
    'subscription-required'.

'decode_error_error_subscription-required_cdata'(<<>>) ->
    undefined;
'decode_error_error_subscription-required_cdata'(_val) ->
    _val.

'decode_error_error_service-unavailable'({xmlel, _,
					  _attrs, _els}) ->
    'service-unavailable'.

'decode_error_error_service-unavailable_cdata'(<<>>) ->
    undefined;
'decode_error_error_service-unavailable_cdata'(_val) ->
    _val.

'decode_error_error_resource-constraint'({xmlel, _,
					  _attrs, _els}) ->
    'resource-constraint'.

'decode_error_error_resource-constraint_cdata'(<<>>) ->
    undefined;
'decode_error_error_resource-constraint_cdata'(_val) ->
    _val.

'decode_error_error_remote-server-timeout'({xmlel, _,
					    _attrs, _els}) ->
    'remote-server-timeout'.

'decode_error_error_remote-server-timeout_cdata'(<<>>) ->
    undefined;
'decode_error_error_remote-server-timeout_cdata'(_val) ->
    _val.

'decode_error_error_remote-server-not-found'({xmlel, _,
					      _attrs, _els}) ->
    'remote-server-not-found'.

'decode_error_error_remote-server-not-found_cdata'(<<>>) ->
    undefined;
'decode_error_error_remote-server-not-found_cdata'(_val) ->
    _val.

'decode_error_error_registration-required'({xmlel, _,
					    _attrs, _els}) ->
    'registration-required'.

'decode_error_error_registration-required_cdata'(<<>>) ->
    undefined;
'decode_error_error_registration-required_cdata'(_val) ->
    _val.

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

decode_error_error_redirect_cdata(<<>>) -> undefined;
decode_error_error_redirect_cdata(_val) -> _val.

'decode_error_error_recipient-unavailable'({xmlel, _,
					    _attrs, _els}) ->
    'recipient-unavailable'.

'decode_error_error_recipient-unavailable_cdata'(<<>>) ->
    undefined;
'decode_error_error_recipient-unavailable_cdata'(_val) ->
    _val.

'decode_error_error_policy-violation'({xmlel, _, _attrs,
				       _els}) ->
    'policy-violation'.

'decode_error_error_policy-violation_cdata'(<<>>) ->
    undefined;
'decode_error_error_policy-violation_cdata'(_val) ->
    _val.

'decode_error_error_not-authorized'({xmlel, _, _attrs,
				     _els}) ->
    'not-authorized'.

'decode_error_error_not-authorized_cdata'(<<>>) ->
    undefined;
'decode_error_error_not-authorized_cdata'(_val) -> _val.

'decode_error_error_not-allowed'({xmlel, _, _attrs,
				  _els}) ->
    'not-allowed'.

'decode_error_error_not-allowed_cdata'(<<>>) ->
    undefined;
'decode_error_error_not-allowed_cdata'(_val) -> _val.

'decode_error_error_not-acceptable'({xmlel, _, _attrs,
				     _els}) ->
    'not-acceptable'.

'decode_error_error_not-acceptable_cdata'(<<>>) ->
    undefined;
'decode_error_error_not-acceptable_cdata'(_val) -> _val.

'decode_error_error_jid-malformed'({xmlel, _, _attrs,
				    _els}) ->
    'jid-malformed'.

'decode_error_error_jid-malformed_cdata'(<<>>) ->
    undefined;
'decode_error_error_jid-malformed_cdata'(_val) -> _val.

'decode_error_error_item-not-found'({xmlel, _, _attrs,
				     _els}) ->
    'item-not-found'.

'decode_error_error_item-not-found_cdata'(<<>>) ->
    undefined;
'decode_error_error_item-not-found_cdata'(_val) -> _val.

'decode_error_error_internal-server-error'({xmlel, _,
					    _attrs, _els}) ->
    'internal-server-error'.

'decode_error_error_internal-server-error_cdata'(<<>>) ->
    undefined;
'decode_error_error_internal-server-error_cdata'(_val) ->
    _val.

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

decode_error_error_gone_cdata(<<>>) -> undefined;
decode_error_error_gone_cdata(_val) -> _val.

decode_error_error_forbidden({xmlel, _, _attrs,
			      _els}) ->
    forbidden.

decode_error_error_forbidden_cdata(<<>>) -> undefined;
decode_error_error_forbidden_cdata(_val) -> _val.

'decode_error_error_feature-not-implemented'({xmlel, _,
					      _attrs, _els}) ->
    'feature-not-implemented'.

'decode_error_error_feature-not-implemented_cdata'(<<>>) ->
    undefined;
'decode_error_error_feature-not-implemented_cdata'(_val) ->
    _val.

decode_error_error_conflict({xmlel, _, _attrs, _els}) ->
    conflict.

decode_error_error_conflict_cdata(<<>>) -> undefined;
decode_error_error_conflict_cdata(_val) -> _val.

'decode_error_error_bad-request'({xmlel, _, _attrs,
				  _els}) ->
    'bad-request'.

'decode_error_error_bad-request_cdata'(<<>>) ->
    undefined;
'decode_error_error_bad-request_cdata'(_val) -> _val.

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

'decode_error_error_text_xml:lang'(<<>>) -> undefined;
'decode_error_error_text_xml:lang'(_val) -> _val.

decode_error_error_text_cdata(<<>>) -> undefined;
decode_error_error_text_cdata(_val) -> _val.

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

decode_bind_bind_cdata(<<>>) -> undefined;
decode_bind_bind_cdata(_val) -> _val.

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

decode_bind_bind_resource_cdata(<<>>) -> undefined;
decode_bind_bind_resource_cdata(_val) ->
    case catch resourceprep(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"resource">>,
			<<>>});
      _res -> _res
    end.

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

decode_bind_bind_jid_cdata(<<>>) -> undefined;
decode_bind_bind_jid_cdata(_val) ->
    case catch dec_jid(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"jid">>, <<>>});
      _res -> _res
    end.

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

decode_sasl_auth_auth_mechanism(<<>>) ->
    erlang:error({missing_attr, <<"mechanism">>, <<"auth">>,
		  <<"urn:ietf:params:xml:ns:xmpp-sasl">>});
decode_sasl_auth_auth_mechanism(_val) -> _val.

decode_sasl_auth_auth_cdata(<<>>) -> undefined;
decode_sasl_auth_auth_cdata(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"auth">>,
			<<"urn:ietf:params:xml:ns:xmpp-sasl">>});
      _res -> _res
    end.

decode_sasl_abort_abort({xmlel, _, _attrs, _els}) ->
    {sasl_abort}.

decode_sasl_abort_abort_cdata(<<>>) -> undefined;
decode_sasl_abort_abort_cdata(_val) -> _val.

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

decode_sasl_challenge_challenge_cdata(<<>>) ->
    undefined;
decode_sasl_challenge_challenge_cdata(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"challenge">>,
			<<"urn:ietf:params:xml:ns:xmpp-sasl">>});
      _res -> _res
    end.

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

decode_sasl_response_response_cdata(<<>>) -> undefined;
decode_sasl_response_response_cdata(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"response">>,
			<<"urn:ietf:params:xml:ns:xmpp-sasl">>});
      _res -> _res
    end.

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

decode_sasl_success_success_cdata(<<>>) -> undefined;
decode_sasl_success_success_cdata(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"success">>,
			<<"urn:ietf:params:xml:ns:xmpp-sasl">>});
      _res -> _res
    end.

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

decode_sasl_failure_failure_cdata(<<>>) -> undefined;
decode_sasl_failure_failure_cdata(_val) -> _val.

'decode_sasl_failure_failure_temporary-auth-failure'({xmlel,
						      _, _attrs, _els}) ->
    'temporary-auth-failure'.

'decode_sasl_failure_failure_temporary-auth-failure_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_temporary-auth-failure_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_not-authorized'({xmlel, _,
					      _attrs, _els}) ->
    'not-authorized'.

'decode_sasl_failure_failure_not-authorized_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_not-authorized_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_mechanism-too-weak'({xmlel,
						  _, _attrs, _els}) ->
    'mechanism-too-weak'.

'decode_sasl_failure_failure_mechanism-too-weak_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_mechanism-too-weak_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_malformed-request'({xmlel,
						 _, _attrs, _els}) ->
    'malformed-request'.

'decode_sasl_failure_failure_malformed-request_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_malformed-request_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_invalid-mechanism'({xmlel,
						 _, _attrs, _els}) ->
    'invalid-mechanism'.

'decode_sasl_failure_failure_invalid-mechanism_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_invalid-mechanism_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_invalid-authzid'({xmlel, _,
					       _attrs, _els}) ->
    'invalid-authzid'.

'decode_sasl_failure_failure_invalid-authzid_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_invalid-authzid_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_incorrect-encoding'({xmlel,
						  _, _attrs, _els}) ->
    'incorrect-encoding'.

'decode_sasl_failure_failure_incorrect-encoding_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_incorrect-encoding_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_encryption-required'({xmlel,
						   _, _attrs, _els}) ->
    'encryption-required'.

'decode_sasl_failure_failure_encryption-required_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_encryption-required_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_credentials-expired'({xmlel,
						   _, _attrs, _els}) ->
    'credentials-expired'.

'decode_sasl_failure_failure_credentials-expired_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_credentials-expired_cdata'(_val) ->
    _val.

'decode_sasl_failure_failure_account-disabled'({xmlel,
						_, _attrs, _els}) ->
    'account-disabled'.

'decode_sasl_failure_failure_account-disabled_cdata'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_account-disabled_cdata'(_val) ->
    _val.

decode_sasl_failure_failure_aborted({xmlel, _, _attrs,
				     _els}) ->
    aborted.

decode_sasl_failure_failure_aborted_cdata(<<>>) ->
    undefined;
decode_sasl_failure_failure_aborted_cdata(_val) -> _val.

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

'decode_sasl_failure_failure_text_xml:lang'(<<>>) ->
    undefined;
'decode_sasl_failure_failure_text_xml:lang'(_val) ->
    _val.

decode_sasl_failure_failure_text_cdata(<<>>) ->
    undefined;
decode_sasl_failure_failure_text_cdata(_val) -> _val.

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

decode_sasl_mechanism_mechanism_cdata(<<>>) ->
    undefined;
decode_sasl_mechanism_mechanism_cdata(_val) -> _val.

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

decode_sasl_mechanisms_mechanisms_cdata(<<>>) ->
    undefined;
decode_sasl_mechanisms_mechanisms_cdata(_val) -> _val.

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

decode_starttls_starttls_cdata(<<>>) -> undefined;
decode_starttls_starttls_cdata(_val) -> _val.

decode_starttls_starttls_required({xmlel, _, _attrs,
				   _els}) ->
    true.

decode_starttls_starttls_required_cdata(<<>>) ->
    undefined;
decode_starttls_starttls_required_cdata(_val) -> _val.

decode_starttls_proceed_proceed({xmlel, _, _attrs,
				 _els}) ->
    {starttls_proceed}.

decode_starttls_proceed_proceed_cdata(<<>>) ->
    undefined;
decode_starttls_proceed_proceed_cdata(_val) -> _val.

decode_starttls_failure_failure({xmlel, _, _attrs,
				 _els}) ->
    {starttls_failure}.

decode_starttls_failure_failure_cdata(<<>>) ->
    undefined;
decode_starttls_failure_failure_cdata(_val) -> _val.

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

'decode_stream_features_stream:features_cdata'(<<>>) ->
    undefined;
'decode_stream_features_stream:features_cdata'(_val) ->
    _val.

decode_p1_push_push({xmlel, _, _attrs, _els}) ->
    {p1_push}.

decode_p1_push_push_cdata(<<>>) -> undefined;
decode_p1_push_push_cdata(_val) -> _val.

decode_p1_rebind_rebind({xmlel, _, _attrs, _els}) ->
    {p1_rebind}.

decode_p1_rebind_rebind_cdata(<<>>) -> undefined;
decode_p1_rebind_rebind_cdata(_val) -> _val.

decode_p1_ack_ack({xmlel, _, _attrs, _els}) -> {p1_ack}.

decode_p1_ack_ack_cdata(<<>>) -> undefined;
decode_p1_ack_ack_cdata(_val) -> _val.

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

decode_caps_c_hash(<<>>) -> undefined;
decode_caps_c_hash(_val) -> _val.

decode_caps_c_node(<<>>) -> undefined;
decode_caps_c_node(_val) -> _val.

decode_caps_c_ver(<<>>) -> undefined;
decode_caps_c_ver(_val) ->
    case catch base64:decode(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_attr_value, <<"ver">>, <<"c">>,
			<<"http://jabber.org/protocol/caps">>});
      _res -> _res
    end.

decode_caps_c_cdata(<<>>) -> undefined;
decode_caps_c_cdata(_val) -> _val.

decode_register_register({xmlel, _, _attrs, _els}) ->
    {register}.

decode_register_register_cdata(<<>>) -> undefined;
decode_register_register_cdata(_val) -> _val.

decode_session_session({xmlel, _, _attrs, _els}) ->
    {session}.

decode_session_session_cdata(<<>>) -> undefined;
decode_session_session_cdata(_val) -> _val.

decode_ping_ping({xmlel, _, _attrs, _els}) -> {ping}.

decode_ping_ping_cdata(<<>>) -> undefined;
decode_ping_ping_cdata(_val) -> _val.

decode_time_time({xmlel, _, _attrs, _els}) ->
    {Utc, Tzo} = decode_time_time_els(_els, [], []),
    {time, Tzo, Utc}.

decode_time_time_els([{xmlel, <<"utc">>, _attrs, _} =
			  _el
		      | _els],
		     Utc, Tzo) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_time_time_els(_els,
			       [decode_time_time_utc(_el) | Utc], Tzo);
      _ -> decode_time_time_els(_els, Utc, Tzo)
    end;
decode_time_time_els([{xmlel, <<"tzo">>, _attrs, _} =
			  _el
		      | _els],
		     Utc, Tzo) ->
    case xml:get_attr_s(<<"xmlns">>, _attrs) of
      <<>> ->
	  decode_time_time_els(_els, Utc,
			       [decode_time_time_tzo(_el) | Tzo]);
      _ -> decode_time_time_els(_els, Utc, Tzo)
    end;
decode_time_time_els([_ | _els], Utc, Tzo) ->
    decode_time_time_els(_els, Utc, Tzo);
decode_time_time_els([], [Utc], [Tzo]) -> {Utc, Tzo}.

decode_time_time_cdata(<<>>) -> undefined;
decode_time_time_cdata(_val) -> _val.

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

decode_time_time_utc_cdata(<<>>) -> undefined;
decode_time_time_utc_cdata(_val) ->
    case catch dec_utc(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"utc">>, <<>>});
      _res -> _res
    end.

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

decode_time_time_tzo_cdata(<<>>) -> undefined;
decode_time_time_tzo_cdata(_val) ->
    case catch dec_tzo(_val) of
      {'EXIT', _} ->
	  erlang:error({bad_cdata_value, <<>>, <<"tzo">>, <<>>});
      _res -> _res
    end.

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

'decode_stream_error_stream:error_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_cdata'(_val) -> _val.

'decode_stream_error_stream:error_unsupported-version'({xmlel,
							_, _attrs, _els}) ->
    'unsupported-version'.

'decode_stream_error_stream:error_unsupported-version_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_unsupported-version_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_unsupported-stanza-type'({xmlel,
							    _, _attrs, _els}) ->
    'unsupported-stanza-type'.

'decode_stream_error_stream:error_unsupported-stanza-type_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_unsupported-stanza-type_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_unsupported-encoding'({xmlel,
							 _, _attrs, _els}) ->
    'unsupported-encoding'.

'decode_stream_error_stream:error_unsupported-encoding_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_unsupported-encoding_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_undefined-condition'({xmlel,
							_, _attrs, _els}) ->
    'undefined-condition'.

'decode_stream_error_stream:error_undefined-condition_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_undefined-condition_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_system-shutdown'({xmlel,
						    _, _attrs, _els}) ->
    'system-shutdown'.

'decode_stream_error_stream:error_system-shutdown_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_system-shutdown_cdata'(_val) ->
    _val.

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

'decode_stream_error_stream:error_see-other-host_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_see-other-host_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_restricted-xml'({xmlel,
						   _, _attrs, _els}) ->
    'restricted-xml'.

'decode_stream_error_stream:error_restricted-xml_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_restricted-xml_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_resource-constraint'({xmlel,
							_, _attrs, _els}) ->
    'resource-constraint'.

'decode_stream_error_stream:error_resource-constraint_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_resource-constraint_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_reset'({xmlel, _,
					  _attrs, _els}) ->
    reset.

'decode_stream_error_stream:error_reset_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_reset_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_remote-connection-failed'({xmlel,
							     _, _attrs,
							     _els}) ->
    'remote-connection-failed'.

'decode_stream_error_stream:error_remote-connection-failed_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_remote-connection-failed_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_policy-violation'({xmlel,
						     _, _attrs, _els}) ->
    'policy-violation'.

'decode_stream_error_stream:error_policy-violation_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_policy-violation_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_not-well-formed'({xmlel,
						    _, _attrs, _els}) ->
    'not-well-formed'.

'decode_stream_error_stream:error_not-well-formed_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_not-well-formed_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_not-authorized'({xmlel,
						   _, _attrs, _els}) ->
    'not-authorized'.

'decode_stream_error_stream:error_not-authorized_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_not-authorized_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_invalid-xml'({xmlel,
						_, _attrs, _els}) ->
    'invalid-xml'.

'decode_stream_error_stream:error_invalid-xml_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_invalid-xml_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_invalid-namespace'({xmlel,
						      _, _attrs, _els}) ->
    'invalid-namespace'.

'decode_stream_error_stream:error_invalid-namespace_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_invalid-namespace_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_invalid-id'({xmlel, _,
					       _attrs, _els}) ->
    'invalid-id'.

'decode_stream_error_stream:error_invalid-id_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_invalid-id_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_invalid-from'({xmlel,
						 _, _attrs, _els}) ->
    'invalid-from'.

'decode_stream_error_stream:error_invalid-from_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_invalid-from_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_internal-server-error'({xmlel,
							  _, _attrs, _els}) ->
    'internal-server-error'.

'decode_stream_error_stream:error_internal-server-error_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_internal-server-error_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_improper-addressing'({xmlel,
							_, _attrs, _els}) ->
    'improper-addressing'.

'decode_stream_error_stream:error_improper-addressing_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_improper-addressing_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_host-unknown'({xmlel,
						 _, _attrs, _els}) ->
    'host-unknown'.

'decode_stream_error_stream:error_host-unknown_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_host-unknown_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_host-gone'({xmlel, _,
					      _attrs, _els}) ->
    'host-gone'.

'decode_stream_error_stream:error_host-gone_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_host-gone_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_connection-timeout'({xmlel,
						       _, _attrs, _els}) ->
    'connection-timeout'.

'decode_stream_error_stream:error_connection-timeout_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_connection-timeout_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_conflict'({xmlel, _,
					     _attrs, _els}) ->
    conflict.

'decode_stream_error_stream:error_conflict_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_conflict_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_bad-namespace-prefix'({xmlel,
							 _, _attrs, _els}) ->
    'bad-namespace-prefix'.

'decode_stream_error_stream:error_bad-namespace-prefix_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_bad-namespace-prefix_cdata'(_val) ->
    _val.

'decode_stream_error_stream:error_bad-format'({xmlel, _,
					       _attrs, _els}) ->
    'bad-format'.

'decode_stream_error_stream:error_bad-format_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_bad-format_cdata'(_val) ->
    _val.

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

'decode_stream_error_stream:error_text_xml:lang'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_text_xml:lang'(_val) ->
    _val.

'decode_stream_error_stream:error_text_cdata'(<<>>) ->
    undefined;
'decode_stream_error_stream:error_text_cdata'(_val) ->
    _val.
