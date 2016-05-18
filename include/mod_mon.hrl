%%%----------------------------------------------------------------------
%%%
%%% ejabberd, Copyright (C) 2002-2016   ProcessOne
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

-define(MINUTE, 60000).
-define(HOUR, 3600000).
-define(DAY, 86400000).
-define(WEEK, 604800000).
-define(MONTH, 2592000000).

-define(HYPERLOGLOGS,
        [daily_active_users,
         weekly_active_users,
         monthly_active_users,
         period_active_users]).

-define(SUPPORTED_HOOKS,
        [offline_message_hook, resend_offline_messages_hook,
         sm_register_connection_hook, sm_remove_connection_hook,
         % remove_user, register_user,
         % roster_in_subscription, roster_out_subscription,
         user_available_hook, unset_presence_hook, set_presence_hook,
         user_send_packet, user_receive_packet, c2s_replaced,
         s2s_send_packet, s2s_receive_packet,
         privacy_iq_get, privacy_iq_set,
         api_call, backend_api_call, backend_api_response_time,
         backend_api_timeout, backend_api_error]).
        % TODO those need submodule register
         %muc_create, muc_destroy, muc_user_join, muc_user_leave, muc_rooms, muc_users, muc_message,
         %pubsub_create_node, pubsub_delete_node, pubsub_publish_item, pubsub_broadcast_stanza, pubsub_nodes, pubsub_users]).
%% other maybe interresting hooks
%%c2s_stream_features, s2s_connect_hook
%%disco_local_features, disco_local_identity, disco_local_items
%%disco_sm_features, disco_sm_identity, disco_sm_items
%%roster_get, roster_get_jid_info, roster_get_subscription_lists, roster_process_item

% By default all probes are type counter. The ones listed above use another type:
-define(NO_COUNTER_PROBES,
        [{muc_rooms, gauge},
         {muc_users, gauge},
         {pubsub_nodes, gauge},
         {pubsub_users, gauge},
         {jabs, gauge},
         {sessions, gauge},
         {memory, gauge},
         {processes, gauge},
         {backend_api_response_time, gauge},
         {message_queues, gauge},
         {iq_message_queues, gauge},
         {sm_message_queues, gauge},
         {c2s_message_queues, gauge},
         {sql_message_queues, gauge},
         {offline_message_queues, gauge},
         {iq_internal_queues, gauge},
         {sm_internal_queues, gauge},
         {c2s_internal_queues, gauge},
         {sql_internal_queues, gauge},
         {offline_internal_queues, gauge},
         {client_conn_time, gauge},
         {client_auth_time, gauge},
         {client_roster_time, gauge},
         {daily_active_users, gauge},
         {weekly_active_users, gauge},
         {monthly_active_users, gauge},
         {period_active_users, gauge}]).

% Average computed probes
-define(AVG_MONITORS,
        [backend_api_response_time]).

% Generic default monitors to aglomerate common values
-define(DEFAULT_MONITORS,
        [{c2s_receive, [message_receive_packet,chat_receive_packet,groupchat_receive_packet,
                        presence_receive_packet,error_receive_packet,result_receive_packet,
                        get_receive_packet,set_receive_packet]},
         {c2s_send, [message_send_packet,chat_send_packet,groupchat_send_packet,
                     presence_send_packet,error_send_packet,result_send_packet,
                     get_send_packet,set_send_packet]},
         {s2s_receive, [s2s_message_receive_packet,s2s_chat_receive_packet,s2s_groupchat_receive_packet,
                        s2s_presence_receive_packet,s2s_error_receive_packet,s2s_result_receive_packet,
                        s2s_get_receive_packet,s2s_set_receive_packet]},
         {s2s_send, [s2s_message_send_packet,s2s_chat_send_packet,s2s_groupchat_send_packet,
                     s2s_presence_send_packet,s2s_error_send_packet,s2s_result_send_packet,
                     s2s_get_send_packet,s2s_set_send_packet]},
         %{muc_rooms, [{'+', muc_create}, {'-', muc_destroy}]},
         %{muc_users, [{'+', muc_user_join}, {'-', muc_user_leave}]},
         %{pubsub_nodes, [{'+', pubsub_create_node}, {'-', pubsub_delete_node}]},
         {message_queues, process_queues, all},
         {iq_message_queues, process_queues, ejabberd_iq_sup},
         {sm_message_queues, process_queues, ejabberd_sm_sup},
         {c2s_message_queues, process_queues, ejabberd_c2s_sup},
         {sql_message_queues, process_queues, ejabberd_sql_sup},
         {offline_message_queues, process_queues, mod_offline_pool},
         {iq_internal_queues, internal_queues, ejabberd_iq_sup},
         {sm_internal_queues, internal_queues, ejabberd_sm_sup},
         {c2s_internal_queues, internal_queues, ejabberd_c2s_sup},
         {sql_internal_queues, internal_queues, ejabberd_sql_sup},
         {offline_internal_queues, internal_queues, mod_offline_pool},
         {jabs, jabs_count},
         {sessions, mnesia, table_info, [session, size]},
         {memory, erlang, memory, [total]},
         {processes, erlang, system_info, [process_count]},
         {health, health_check, all}
        ]).
