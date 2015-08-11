%%%-------------------------------------------------------------------
%%% @author Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% @copyright (C) 2015, Evgeny Khramtsov
%%% @doc
%%%
%%% @end
%%% Created :  6 Jul 2015 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%-------------------------------------------------------------------
-module(ocsp_server).

%% API
-export([process/2]).
-include("OCSP.hrl").
-include_lib("public_key/include/public_key.hrl").
-include("ejabberd_http.hrl").

%%%===================================================================
%%% API
%%%===================================================================
process(_, #request{method = 'POST', data = Data}) ->
    {ok, Req} = 'OCSP':decode('OCSPRequest', Data),
    #'OCSPRequest'{
       tbsRequest =
	   #'TBSRequest'{
	      requestList = [#'Request'{
				reqCert = #'CertID'{
					     serialNumber = SN} = CertID}]}} = Req,
    Status = if SN == 1 ->
		     {good, 'NULL'};
		true ->
		     {revoked, #'RevokedInfo'{revocationTime = "20150811090000Z"}}
	     end,
    BasicResp = #'BasicOCSPResponse'{
		   signatureAlgorithm = #'AlgorithmIdentifier'{
					   algorithm = ?'sha1WithRSAEncryption'},
		   signature = <<>>,
		   tbsResponseData =
		       #'ResponseData'{
			  responderID = {byKey, <<"">>},
			  producedAt = "20150811090000Z",
			  responses = [#'SingleResponse'{
					  thisUpdate = "20150811090000Z",
					  nextUpdate = "20150811090000Z",
					  certID = CertID,
					  certStatus = Status}]}},
    {ok, RespBytes} = 'OCSP':encode('BasicOCSPResponse', BasicResp),
    Resp = #'OCSPResponse'{
	      responseStatus = successful,
	      responseBytes = #'ResponseBytes'{
				 responseType = ?'id-pkix-ocsp-basic',
				 response = RespBytes}},
    {ok, Bytes} = 'OCSP':encode('OCSPResponse', Resp),
    {200, [], iolist_to_binary(Bytes)};
process(_, _) ->
    {400, [], <<>>}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
