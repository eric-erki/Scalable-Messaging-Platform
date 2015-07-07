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
					     serialNumber = SN}}]}} = Req,
    Resp = if SN == 1 ->
		   error_logger:info_msg("request ~p is successful", [Req]),
		   #'OCSPResponse'{responseStatus = successful};
	      true ->
		   error_logger:info_msg("request ~p is unauthorized", [Req]),
		   #'OCSPResponse'{responseStatus = unauthorized}
	   end,
    {ok, Bytes} = 'OCSP':encode('OCSPResponse', Resp),
    {200, [], iolist_to_binary(Bytes)};
process(_, _) ->
    {400, [], <<>>}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
