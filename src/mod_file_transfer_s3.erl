%%%-------------------------------------------------------------------
%%% Created :  9 Feb 2015 by Jerome Sautret <jsautret@process-one.net>
%%% File    : mod_file_transfert_s3.erl
%%% Author  : Jerome Sautret <jsautret@process-one.net>
%%% Purpose : File transfer over AWS S3
%%%           Protocol is described on EJSAAS-81
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2017   ProcessOne
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
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------
-module(mod_file_transfer_s3).

-author('jsautret@process-one.net').

-behaviour(gen_mod).

-export([start/2, stop/1, process_iq/3,
	 depends/2, mod_opt_type/1]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-record(config, {
          s3_url = "https://s3.amazonaws.com"::string(),
          access_key_id::binary(),
          secret_access_key::binary(),
          bucket_access_type = virtual_hosted::bucket_access_type()
}).
-type bucket_access_type() :: virtual_hosted | path.
-type config() :: #config{}.

-define(NS_S3FT, <<"p1:s3filetransfer">>).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Module callbacks

start(Host, Opts) ->
    case get_config(Host) of
	error ->
	    ?ERROR_MSG("Module ~p is not correctly configured,"
		       " not started.", [?MODULE]),
	    stop;
	_ ->
	    IQDisc = gen_mod:get_opt(iqdisc, Opts,
				     fun gen_iq_handler:check_type/1,
				     one_queue),
	    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_S3FT,
					  ?MODULE, process_iq, IQDisc),
	    mod_disco:register_feature(Host, ?NS_S3FT),
	    ok
    end.

stop(Host) ->
    mod_disco:unregister_feature(Host, ?NS_S3FT),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_S3FT),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% IQ callbacks

process_iq(#jid{lserver = LServer} = From,
	   #jid{luser= <<>>, lserver = LServer} = To,
           #iq{sub_el = SubEl} = IQ) ->

    case lists:member(LServer, ?MYHOSTS) of
	true -> process_local_iq(From, To, IQ);
	_ -> IQ#iq{type = error,
		   sub_el = [SubEl, ?ERR_NOT_AUTHORIZED]}
    end;
process_iq(_From, _To, #iq{sub_el = SubEl} = IQ) ->
    IQ#iq{type = error,
	  sub_el = [SubEl, ?ERR_BAD_REQUEST]}.


% set iq (used by sender)
process_local_iq(_From,
	      #jid{lserver = Host},
	      #iq{type = set, sub_el = SubEl} = IQ) ->

    #xmlel{attrs = Attrs} = SubEl,
    case fxml:get_attr_s(<<"md5">>, Attrs) of
	MD5 when size(MD5) == 24 ->
	    % MD5 is Base64 encoded 128 bits binary MD5 sum
	    make_result(Host, IQ, SubEl, put, none,[{"content-md5", MD5}]);
	_BadMD5 ->
	    ?DEBUG("Received bad MD5 ~s of size ~p",
		   [_BadMD5, size(_BadMD5)]),
	    IQ#iq{type = error,
		  sub_el = [SubEl, ?ERR_BAD_REQUEST]}
    end;

% get iq (used by receiver)
process_local_iq(_From,
	      #jid{lserver = Host},
	      #iq{type = get, sub_el = SubEl} = IQ) ->

    #xmlel{attrs = Attrs} = SubEl,
    case fxml:get_attr_s(<<"fileid">>, Attrs) of
	FileID when size(FileID) == 36 ->
	    % FileID is an uuid v4
	    make_result(Host, IQ, SubEl, get, FileID, []);
	_BadFileID ->
	    ?DEBUG("Received bad FileID ~s of size ~p",
		   [_BadFileID, size(_BadFileID)]),
	    IQ#iq{type = error,
		  sub_el = [SubEl, ?ERR_BAD_REQUEST]}
    end.

% return the result iq
make_result(Host, IQ, SubEl, Method, FileID, Headers) ->
    case get_config(Host) of
	{S3Config, Bucket, Lifetime} ->
	    Filename = case FileID of
			   none -> uuidv4_list();
			   _ -> FileID
		       end,
	    URL = s3_url(Method, Bucket, Filename, Lifetime,
			 Headers, S3Config),
	    IQ#iq{type = result,
		  sub_el = [SubEl#xmlel{
			      attrs = result_attributes(Method, URL,
							Filename)
			     }
		  ]};
	_ ->
	    ?ERROR_MSG("~p is not properly configured.",
		       [?MODULE]),
	    IQ#iq{type = error,
		  sub_el = [SubEl,
			    ?ERR_FEATURE_NOT_IMPLEMENTED]}
    end.

result_attributes(put, URL, Filename) ->
    [{<<"xmlns">>, ?NS_S3FT},
     {<<"upload">>, URL}, {<<"fileid">>, iolist_to_binary(Filename)}];
result_attributes(get, URL, _Filename) ->
    [{<<"xmlns">>, ?NS_S3FT}, {<<"download">>, URL}].

get_config(Host) ->
    case
	{gen_mod:get_module_opt(Host, ?MODULE,
				access_key_id,
				fun iolist_to_binary/1, <<>>),
	 gen_mod:get_module_opt(Host, ?MODULE,
				secret_access_key,
				fun iolist_to_binary/1, <<>>),
	 gen_mod:get_module_opt(Host, ?MODULE, bucket_name,
				fun iolist_to_binary/1, <<>>)
	} of
	{AccessKeyID, SecretAccessKey, Bucket} when
	size(AccessKeyID) == 20 andalso
	size(SecretAccessKey) == 40 andalso
	size(Bucket) > 0 ->
	    S3Config = s3config(AccessKeyID, SecretAccessKey),
	    Lifetime = gen_mod:get_module_opt(
			 Host, ?MODULE, url_lifetime,
			 fun(I) when is_integer(I), I>0 -> I end,
			 10*60), % default to 10 minutes.
	    {S3Config, Bucket, Lifetime};
	_ ->
	    error
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% S3 helpers
%
% This code is a modified version of mini_s3
% https://github.com/chef/mini_s3
%
% Modifications includes removing unused features, use of binary
% string and iolist when possible, support for virtual hosted bucket
% type URL and removing duplicated code already in ejabberd.
%
% Initial code Copyright 2011-2012 Opscode, Inc. All Rights Reserved.
%
% Licensed under the Apache License, Version 2.0 (the "License"); you
% may not use this file except in compliance with the License. You may
% obtain a copy of the License at
%
% http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS,
% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
% implied. See the License for the specific language governing
% permissions and limitations under the License.

s3config(AccessKeyID, SecretAccessKey) ->
    #config{access_key_id=AccessKeyID,
	    secret_access_key=SecretAccessKey}.

%% @doc Generate an S3 URL using Query String Request Authentication
%% (see
%% http://docs.amazonwebservices.com/AmazonS3/latest/dev/RESTAuthentication.html#RESTAuthenticationQueryStringAuth
%% for details).

-spec s3_url(atom(),
	     string() | binary(),
	     string() | binary() | iolist(),
	     integer() | {integer(), integer()},
             proplists:proplist(),
	     config()) -> binary().

s3_url(Method, BucketName, Key, Lifetime, RawHeaders,
       Config = #config{access_key_id=AccessKey,
                        secret_access_key=SecretKey})
  when (is_list(BucketName) orelse is_binary(BucketName)) andalso
       (is_list(Key) orelse is_binary(Key)) ->

    Expires = erlang:integer_to_list(expiration_time(Lifetime)),

    Path = iolist_to_binary([$/, BucketName, $/ , Key]),
    CanonicalizedResource = ejabberd_http:url_encode(Path),

    {_StringToSign, Signature} =
	make_signed_url_authorization(SecretKey, Method,
				      CanonicalizedResource,
				      Expires, RawHeaders),

    ?DEBUG("StringToSign =~n~s", [_StringToSign]),

    RequestURI = iolist_to_binary([
                                   format_s3_uri(Config, BucketName),
				   $/ , Key,
                                   $?, "AWSAccessKeyId=", AccessKey,
                                   $&, "Expires=", Expires,
                                   $&, "Signature=",
				   ejabberd_http:url_encode(Signature)
                                  ]),
    RequestURI.

make_signed_url_authorization(SecretKey, Method, CanonicalizedResource,
                              Expires, RawHeaders) ->
    Headers = canonicalize_headers(RawHeaders),

    HttpMethod = string:to_upper(atom_to_list(Method)),

    ContentType = retrieve_header_value("content-type", Headers),
    ContentMD5 = retrieve_header_value("content-md5", Headers),

    % We don't currently use this, but I'm adding a placeholder for
    % future enhancements See the URL in the docstring for details
    CanonicalizedAMZHeaders = "",


    StringToSign = [HttpMethod, $\n,
		    ContentMD5, $\n,
		    ContentType, $\n,
		    Expires, $\n,
		    CanonicalizedAMZHeaders,
		    % IMPORTANT: No newline here!!
		    CanonicalizedResource
		   ],

    Signature = base64:encode(crypto:hmac(sha, SecretKey, StringToSign)),
    {StringToSign, Signature}.


-spec format_s3_uri(config(), iolist()) -> iolist().
format_s3_uri(#config{s3_url=S3Url, bucket_access_type=BAccessType},
	      Host) ->
    {ok,{Protocol,UserInfo,Domain,Port,_Uri,_QueryString}} =
        http_uri:parse(S3Url, [{ipv6_host_with_brackets, true}]),
    case BAccessType of
        virtual_hosted ->
            [erlang:atom_to_list(Protocol), "://",
	     if_not_empty(UserInfo, [UserInfo, "@"]),
	     if_not_empty(Host, [Host, $.]),
	     Domain, ":", erlang:integer_to_list(Port)];
        path ->
            [erlang:atom_to_list(Protocol), "://",
	     if_not_empty(UserInfo, [UserInfo, "@"]),
	     Domain, ":", erlang:integer_to_list(Port),
	     if_not_empty(Host, [$/, Host])]
    end.


%% @doc Canonicalizes a proplist of {"Header", "Value"} pairs by
%% lower-casing all the Headers.
-spec canonicalize_headers([{string() | binary() | atom(),
			     Value::string()}]) ->
    [{LowerCaseHeader::string(), Value::string()}].
canonicalize_headers(Headers) ->
    [{string:to_lower(to_string(H)), V} || {H, V} <- Headers ].

-spec to_string(atom() | binary() | string()) -> string().
to_string(A) when is_atom(A)   -> erlang:atom_to_list(A);
to_string(B) when is_binary(B) -> erlang:binary_to_list(B);
to_string(S) when is_list(S)   -> S.

%% @doc Retrieves a value from a set of canonicalized headers.  The
%% given header should already be canonicalized (i.e., lower-cased).
%% Returns the value or the empty string if no such value was found.
-spec retrieve_header_value(Header::string(),
                            AllHeaders::[{Header::string(),
					  Value::string()}]) ->
                                   string().
retrieve_header_value(Header, AllHeaders) ->
    proplists:get_value(Header, AllHeaders, "").


%% calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}).
-define(EPOCH, 62167219200).
-define(DAY, 86400).

%% @doc Number of seconds since the Epoch that a request can be valid
%% for, specified by TimeToLive, which is the number of seconds from
%% "right now" that a request should be valid. If the argument
%% provided is a tuple, we use the interval logic that will only
%% result in Interval / 86400 unique expiration times per day
-spec expiration_time(TimeToLive :: non_neg_integer() |
		      {non_neg_integer(), non_neg_integer()}) ->
    Expires::non_neg_integer().
expiration_time({TimeToLive, Interval}) ->
    {{NowY, NowMo, NowD},{_,_,_}} = Now = universaltime(),
    NowSecs = calendar:datetime_to_gregorian_seconds(Now),
    MidnightSecs = calendar:datetime_to_gregorian_seconds(
		     {{NowY, NowMo, NowD},{0,0,0}}),
    %% How many seconds are we into today?
    TodayOffset = NowSecs - MidnightSecs,
    Buffer = case (TodayOffset + Interval) >= ?DAY of
        %% true if we're in the day's last interval, don't let it
        %% spill into tomorrow
		 true ->
		     ?DAY - TodayOffset;
                 %% false means this interval is bounded by today
		 _ ->
		     Interval - (TodayOffset rem Interval)
	     end,
    NowSecs + Buffer - ?EPOCH + TimeToLive;
expiration_time(TimeToLive) ->
    Now = calendar:datetime_to_gregorian_seconds(universaltime()),
    (Now - ?EPOCH) + TimeToLive.

%% Abstraction of universaltime, so it can be mocked via meck
-spec universaltime() -> calendar:datetime().
universaltime() ->
    erlang:universaltime().

-spec if_not_empty(string()|binary(), iolist()) -> iolist().
if_not_empty("", _V)   -> "";
if_not_empty(<<>>, _V) -> <<>>;
if_not_empty(_, Value) -> Value.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% UUID helpers
%
% This code is based on erlang-uuid
% https://github.com/travis/erlang-uuid
%
% Initial code Copyright (c) 2008, Travis Vachon
% All rights reserved.
%
% Redistribution and use in source and binary forms, with or without
% modification, are permitted provided that the following conditions are
% met:
%
%     * Redistributions of source code must retain the above copyright
%       notice, this list of conditions and the following disclaimer.
%
%     * Redistributions in binary form must reproduce the above copyright
%       notice, this list of conditions and the following disclaimer in the
%       documentation and/or other materials provided with the distribution.
%
%     * Neither the name of the author nor the names of its contributors
%       may be used to endorse or promote products derived from this
%       software without specific prior written permission.
%
% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
% "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
% LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
% A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
% OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
% TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
% PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
% LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

% @doc Returns a list representation of a random binary UUID v4.
uuidv4_list() ->
    U = uuidv4(),
    io_lib:format("~8.16.0b-~4.16.0b-~4.16.0b-"
		  "~2.16.0b~2.16.0b-~12.16.0b",
		  get_parts(U)).

% @doc Generates a random binary UUID.
uuidv4() ->
    uuidv4(crypto:rand_uniform(1, round(math:pow(2, 48))) - 1,
	   crypto:rand_uniform(1, round(math:pow(2, 12))) - 1,
	   crypto:rand_uniform(1, round(math:pow(2, 32))) - 1,
	   crypto:rand_uniform(1, round(math:pow(2, 30))) - 1).

% @doc Generates a random binary UUID.
uuidv4(R1, R2, R3, R4) ->
    <<R1:48, 4:4, R2:12, 2:2, R3:32, R4: 30>>.

% @doc Returns the 32, 16, 16, 8, 8, 48 parts of a binary UUID.
get_parts(<<TL:32, TM:16, THV:16, CSR:8, CSL:8, N:48>>) ->
    [TL, TM, THV, CSR, CSL, N].

depends(_Host, _Opts) ->
    [].

mod_opt_type(access_key_id) -> fun iolist_to_binary/1;
mod_opt_type(bucket_name) -> fun iolist_to_binary/1;
mod_opt_type(iqdisc) -> fun gen_iq_handler:check_type/1;
mod_opt_type(secret_access_key) ->
    fun iolist_to_binary/1;
mod_opt_type(url_lifetime) ->
    fun (I) when is_integer(I), I > 0 -> I end;
mod_opt_type(_) ->
    [access_key_id, bucket_name, iqdisc, secret_access_key,
     url_lifetime].
