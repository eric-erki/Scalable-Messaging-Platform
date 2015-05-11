%%%-------------------------------------------------------------------
%%% @author Jerome Sautret <jsautret@process-one.net>
%%% @copyright (C) 2015, ProcessOne
%%% @doc
%%% Send a JSON payload to a HTTP API
%%% Protocol documentation:
%%% https://support.process-one.net/doc/display/EBE/Send+data+via+XMPP+on+HTTP+API
%%% @end
%%% Created :  4 Mar 2015 by Jerome Sautret <jsautret@process-one.net>
%%%-------------------------------------------------------------------
-module(mod_iq_http).

-author('jsautret@process-one.net').

-behaviour(gen_mod).
% module functions
-export([start/2, stop/1]).

% iq handler
-export([process_iq/3]).

-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-define(NS_IQ_HTTP, <<"p1:iq:http">>).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Module callbacks

start(Host, Opts) ->
    case get_url(Host) of
	error ->
	    ?ERROR_MSG("Module ~p is not correctly configured,"
		       " not started.", [?MODULE]),
	    stop;
	_ ->
	    rest:start(Host),
	    IQDisc = gen_mod:get_opt(iqdisc, Opts,
				     fun gen_iq_handler:check_type/1,
				     one_queue),
	    gen_iq_handler:add_iq_handler(ejabberd_local, Host,
					  ?NS_IQ_HTTP,
					  ?MODULE, process_iq, IQDisc),
	    mod_disco:register_feature(Host, ?NS_IQ_HTTP),
	    ok
    end.

stop(Host) ->
    mod_disco:unregister_feature(Host, ?NS_IQ_HTTP),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_IQ_HTTP),
    ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% IQ callbacks

process_iq(#jid{lserver = LServer} = From,
	   #jid{luser= <<>>, lserver = LServer},
           #iq{type = set,
	       sub_el = #xmlel{name= <<"payload">>,
			       children= Payload} = SubEl} = IQ)
  when length(Payload) > 0 ->

    case lists:member(LServer, ?MYHOSTS) of
	true -> process_local_iq(From, IQ);
	_ -> IQ#iq{type = error,
		   sub_el = [SubEl, ?ERR_NOT_AUTHORIZED]}
    end;
process_iq(_From, _To, #iq{sub_el = SubEl} = IQ) ->
    IQ#iq{type = error,
	  sub_el = [SubEl, ?ERR_BAD_REQUEST]}.



process_local_iq(#jid{lserver = Host} = From,
		 #iq{sub_el = #xmlel{children= Payload} = SubEl} = IQ) ->
    URL = get_url(Host),
    Params = [{<<"from">>, jlib:jid_to_string(From)}],
    case catch jiffy:decode(xml:get_cdata(Payload))
	of
	{error, _Reason} ->
	    ?ERROR_MSG("Payload is not valid JSON: ~p~nJiffy error: ~p",
		       [Payload, _Reason]),
	    IQ#iq{type = error,
		  sub_el = [SubEl, ?ERR_NOT_ACCEPTABLE]};
	Data ->
	    ?DEBUG("Received JSON payload from ~p: ~p", [From, Data]),
	    case rest:post(Host, URL, Params, Data) of
		{ok, 200, _Body} ->
		    IQ#iq{type = result, sub_el = [SubEl]};
		{ok, _Code, _Body} ->
		    ?ERROR_MSG("Webservice returned code ~p: ~s",
			       [_Code, _Body]),
		    IQ#iq{type = error,
			  sub_el = [SubEl, ?ERR_RECIPIENT_UNAVAILABLE]};
		{error, _Error} ->
		    ?ERROR_MSG("Webservice error: ~p", [_Error]),
		    IQ#iq{type = error,
			  sub_el = [SubEl, ?ERR_RECIPIENT_UNAVAILABLE]}
	    end
    end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Helpers

get_url(Host) ->
    case
	gen_mod:get_module_opt(Host, ?MODULE, url,
			       fun iolist_to_binary/1, <<>>) of
	URL when size(URL) > 5 ->
	    URL;
	_ -> error
    end.
