%%%----------------------------------------------------------------------
%%% File    : cyrsasl_pkix.erl
%%% Author  : Evgeniy Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : EXTERNAL PKIX Certificate mechanism (XEP-0178)
%%% Created : 18 May 2012 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2012   ProcessOne
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
%%%----------------------------------------------------------------------

-module(cyrsasl_pkix).
-author('alexey@process-one.net').

-protocol({xep, 178, '1.1'}).

-export([start/1, stop/0, mech_new/6, mech_step/2]).

-behaviour(cyrsasl).

-record(state, {certfile, is_user_exists}).

-include("jlib.hrl").
-include("XmppAddr.hrl").
-include_lib("public_key/include/public_key.hrl").
-define(PKIXEXPLICIT, 'OTP-PUB-KEY').
-define(PKIXIMPLICIT, 'OTP-PUB-KEY').

start(_Opts) ->
    cyrsasl:register_mechanism(<<"EXTERNAL">>, ?MODULE, plain),
    ok.

stop() ->
    ok.

mech_new(_Host, _GetPassword, _CheckPassword,
         _CheckPasswordDigest, IsUserExists, CertFile) ->
    {ok, #state{certfile = CertFile, is_user_exists = IsUserExists}}.

mech_step(State, ClientIn) ->
    {JID, Username} = case jid:from_string(ClientIn) of
                          #jid{user = User} = J ->
                              {J, User};
                          error ->
                              {error, <<"">>}
                      end,
    case State#state.certfile of
        undefined ->
            {error, <<"not-authorized">>, Username,
             <<"no certificate present or verification is disabled">>};
        {_Cert, ErrTxt} ->
            {error, <<"not-authorized">>, Username, ErrTxt};
        #'OTPCertificate'{} = Cert ->
            JIDs = get_jids(Cert),
            case find_jid_to_authenticate(JIDs, JID) of
                #jid{user = U, server = S} ->
		    case ejabberd_auth:try_register(
			   U, S, base64:encode(randoms:bytes(20))) of
			{atomic, Res} when Res == exists; Res == ok ->
                            {ok, [{username, U}, {authzid, U},
                                  {auth_module, ejabberd_auth_pkix}]};
			_ ->
                            {error, <<"not-authorized">>, U}
                    end;
                Err ->
                    Err
            end
    end.

find_jid_to_authenticate([JID], error) ->
    JID;
find_jid_to_authenticate(JIDs,
                         #jid{luser = LUser,
                              lserver = LServer,
                              user = User} = JID) ->
    case lists:member(
           {LUser, LServer, <<"">>},
           [jid:tolower(
              jid:remove_resource(J))
            || J <- JIDs]) of
        true ->
            JID;
        _ ->
            {error, <<"not-authorized">>, User,
             <<"JID from authzid is not found in the certificate">>}
    end;
find_jid_to_authenticate(_, error) ->
    {error, <<"invalid-authzid">>}.

get_jids(Cert) ->
    Extensions =
	(Cert#'OTPCertificate'.tbsCertificate)#'OTPTBSCertificate'.extensions,
    lists:flatmap(
      fun(#'Extension'{extnID = ?'id-ce-subjectAltName',
                       extnValue = SANs}) ->
	      lists:flatmap(
		fun({otherName,
		     #'AnotherName'{'type-id' = ?'id-on-xmppAddr',
				    value = XmppAddr
				   }}) ->
			case 'XmppAddr':decode(
			       'XmppAddr', XmppAddr) of
			    {ok, D} when is_binary(D) ->
				case jid:from_string(D) of
				    JID = #jid{} ->
					[JID];
				    _ ->
					[]
				end;
			    _ ->
				[]
			end;
		   (_) ->
			[]
		end, SANs);
         (_) ->
              []
      end, Extensions).
