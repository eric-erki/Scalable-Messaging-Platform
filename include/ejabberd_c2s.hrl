%%%----------------------------------------------------------------------
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
%%%----------------------------------------------------------------------

-ifndef(mod_privacy_hrl).

-include("ejabberd.hrl").
-include("mod_privacy.hrl").

-endif.

%-define(SETS, gb_sets).
-define(SETS, ejabberd_sets).

-define(DICT, dict).

-record(state,
	{socket,
         sockmod = ejabberd_socket :: ejabberd_socket | ejabberd_frontend_socket,
         socket_monitor = make_ref() :: reference(),
         xml_socket = false :: boolean(),
         streamid = <<"">> :: binary(),
	 sasl_state :: any(),
         access :: atom(),
         shaper = none :: shaper:shaper(),
         zlib = false :: boolean(),
         tls = false :: boolean(),
	 tls_required = false :: boolean(),
         tls_enabled = false :: boolean(),
	 tls_options = [] :: list(),
         authenticated = false :: boolean() | replaced | rebinded,
         jid = #jid{} :: jid(),
	 user = <<"">> :: binary(),
         server = <<"">> :: binary(),
         resource = <<"">> :: binary(),
         sid = {now(), self()} :: ejabberd_sm:sid(),
	 pres_t = (?SETS):new() :: ?SETS:ej_set() | {pres_t, non_neg_integer()},
         pres_f = (?SETS):new() :: ?SETS:ej_set() | {pres_f, non_neg_integer()},
	 pres_a = (?SETS):new() :: ?SETS:ej_set() | {pres_a, non_neg_integer()},
	 pres_last :: xmlel(),
         pres_timestamp :: erlang:timestamp(),
	 privacy_list = #userlist{} :: userlist(),
         conn = unknown :: atom(),
	 auth_module = unknown :: atom(),
         ip :: {inet:ip_address(), inet:port_number()},
         redirect = false :: boolean(),
	 aux_fields = [] :: [{atom(), any()}],
         fsm_limit_opts = [] :: [{atom(), any()}],
         csi_state = active,
         csi_queue = [], % remove after 3.2.15
         mgmt_state = disabled :: mgmt_state(),
         mgmt_xmlns = <<"">> :: binary(),
         mgmt_queue :: ?TQUEUE,
         mgmt_max_queue = 500 :: pos_integer() | exceeded | infinity,
         mgmt_pending_since :: erlang:timestamp(),
         mgmt_timeout = 0 :: non_neg_integer(),
	 mgmt_max_timeout = 0 :: non_neg_integer(),
         mgmt_resend = false :: boolean(),
         mgmt_stanzas_in = 0 :: non_neg_integer(),
         mgmt_stanzas_out = 0 :: non_neg_integer(),
         lang = ?MYLANG :: binary(),
         debug = false :: boolean(),
	 ocsp_poll_interval :: pos_integer(),
	 ocsp_fallback_uri_list = [] :: [binary()],
         flash_hack = false :: boolean(),
	 flash_connection = false :: boolean(),
         reception = true :: boolean(),
	 standby = false :: boolean(),
         queue = queue:new() :: ?TQUEUE,
         queue_len = 0 :: integer(),
	 pres_queue = gb_trees:empty() :: ?TGB_TREE,
         keepalive_timer :: reference(),
	 keepalive_timeout :: timeout(),
         oor_timeout :: timeout(),
         oor_status = <<"">> :: binary(),
	 oor_show = <<"">> :: binary(),
         oor_notification :: xmlel(),
	 oor_send_body = all :: first_per_user | first | all | none,
         oor_send_groupchat = false :: boolean(),
	 oor_send_from = jid :: jid | username | name | none,
         oor_appid = <<"">> :: binary(),
         oor_unread = 0 :: integer(),
	 oor_unread_users = (?SETS):new() :: ?SETS:ej_set(),
         oor_unread_client = 0 :: integer(),
	 oor_offline = false :: boolean(),
	 ask_offline = true :: boolean(),
         ack_enabled = false :: boolean(),
	 ack_counter = 0 :: integer(),
         ack_queue = queue:new() :: ?TQUEUE,
         ack_timer :: reference()}).

-type c2s_state() :: #state{}.

-type mgmt_state() :: disabled | inactive | active | pending | resumed.

-define(C2S_P1_ACK_TIMEOUT, 10000).
-define(MAX_OOR_TIMEOUT, 1440).
-define(MAX_OOR_MESSAGES, 1000).
