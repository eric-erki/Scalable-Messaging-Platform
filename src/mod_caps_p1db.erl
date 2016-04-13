%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2016, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created : 16 Apr 2016 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_caps_p1db).

-behaviour(mod_caps).

%% API
-export([init/2, caps_read/2, caps_write/3, import/3]).
-export([enc_key/1, dec_key/1, enc_val/2, dec_val/2]).

-include("mod_caps.hrl").
-include("logger.hrl").

%%%===================================================================
%%% API
%%%===================================================================
init(Host, _Opts) ->
    Group = gen_mod:get_module_opt(
	      Host, ?MODULE, p1db_group, fun(G) when is_atom(G) -> G end,
	      ejabberd_config:get_option(
		{p1db_group, Host}, fun(G) when is_atom(G) -> G end)),
    p1db:open_table(caps_features,
                    [{group, Group}, {nosync, true},
                     {schema, [{keys, [node, ver, feature]},
                               {vals, [timestamp]},
                               {enc_key, fun ?MODULE:enc_key/1},
                               {dec_key, fun ?MODULE:dec_key/1},
                               {enc_val, fun ?MODULE:enc_val/2},
                               {dec_val, fun ?MODULE:dec_val/2}]}]).

caps_read(_LServer, Node) ->
    NVPrefix = nv_prefix(Node),
    case p1db:get_by_prefix(caps_features, NVPrefix) of
	{ok, []} ->
	    error;
	{ok, L} ->
	    NullFeature = null_feature(Node),
	    case lists:map(
		   fun({Key, <<T:32>>, _}) ->
			   case key2feature(NVPrefix, Key) of
			       NullFeature -> T;
			       Feature -> Feature
			   end
		   end, L) of
		[TS|_] when is_integer(TS) ->
		    {ok, TS};
		Features ->
		    {ok, Features}
	    end;
	{error, _} ->
	    error
    end.

caps_write(_LServer, Node, Features) ->
    if is_list(Features) ->
	    p1db:delete(caps_features, null_feature(Node)),
	    lists:foreach(
	      fun(Feature) ->
		      NVFKey = nvf2key(Node, Feature),
		      p1db:insert(caps_features,
				  NVFKey, <<(now_ts()):32>>)
	      end, Features);
       true ->
	    NVFKey = null_feature(Node),
	    p1db:insert(caps_features, NVFKey, <<Features:32>>)
    end.

import(_LServer, NodePair, [I]) when is_integer(I) ->
    NVFKey = null_feature(NodePair),
    p1db:async_insert(caps_features, NVFKey, <<I:32>>);
import(_LServer, NodePair, Features) ->
    lists:foreach(
      fun(Feature) ->
	      NVFKey = nvf2key(NodePair, Feature),
	      p1db:async_insert(caps_features,
				NVFKey, <<(now_ts()):32>>)
      end, Features).

%%%===================================================================
%%% Internal functions
%%%===================================================================
now_ts() ->
    p1_time_compat:system_time(seconds).

nvf2key({Node, Ver}, Feature) ->
    <<Node/binary, 0, Ver/binary, 0, Feature/binary>>.

nv_prefix({Node, Ver}) ->
    <<Node/binary, 0, Ver/binary, 0>>.

null_feature({Node, Ver}) ->
    <<Node/binary, 0, Ver/binary, 0, 0>>.

key2feature(Prefix, Key) ->
    Size = size(Prefix),
    <<_:Size/binary, Feature/binary>> = Key,
    Feature.

enc_key([Node]) ->
    <<Node/binary>>;
enc_key([Node, Ver]) ->
    <<Node/binary, 0, Ver/binary>>;
enc_key([Node, Ver, null]) ->
    <<Node/binary, 0, Ver/binary, 0, 0>>;
enc_key([Node, Ver, Feature]) ->
    <<Node/binary, 0, Ver/binary, 0, Feature/binary>>.

dec_key(Key) ->
    NLen = str:chr(Key, 0) - 1,
    <<Node:NLen/binary, 0, VKey/binary>> = Key,
    VLen = str:chr(VKey, 0) - 1,
    <<Ver:VLen/binary, 0, Feature/binary>> = VKey,
    case Feature of
        <<0>> -> [Node, Ver, null];
        _ -> [Node, Ver, Feature]
    end.

enc_val(_, [I]) ->
    <<I:32>>.

dec_val(_, <<I:32>>) ->
    [I].
