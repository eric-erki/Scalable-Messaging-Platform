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

-define(MINUTE, 60000).
-define(HOUR, 3600000).
-define(DAY, 86400000).
-define(WEEK, 604800000).
-define(MONTH, 2592000000).

-define(SUPPORTED_HOOKS,
        [offline_message_hook, resend_offline_messages_hook,
         sm_register_connection_hook, sm_remove_connection_hook,
         sm_remove_migrated_connection_hook,
         % remove_user, register_user,
         % roster_in_subscription, roster_out_subscription,
         user_available_hook, unset_presence_hook, set_presence_hook,
         user_send_packet, user_receive_packet, c2s_replaced,
         s2s_send_packet, s2s_receive_packet,
         privacy_iq_get, privacy_iq_set,
         backend_api_call, backend_api_response_time,
         backend_api_timeout, backend_api_error, backend_api_badauth,
         badauth]).
        % TODO those need submodule register
         %muc_create, muc_destroy, muc_user_join, muc_user_leave, muc_rooms, muc_users, muc_message,
         %pubsub_create_node, pubsub_delete_node, pubsub_publish_item, pubsub_broadcast_stanza, pubsub_nodes, pubsub_users]).
%% other maybe interresting hooks
%%c2s_stream_features, s2s_connect_hook
%%disco_local_features, disco_local_identity, disco_local_items
%%disco_sm_features, disco_sm_identity, disco_sm_items
%%roster_get, roster_get_jid_info, roster_get_subscription_lists, roster_process_item

% By default all probes are type counter except these ones:
-define(AVG, [client_conn_time, client_auth_time, client_roster_time, backend_api_response_time]).
-define(GAUGE, [sessions, memory, cpu, processes, jabs, message_queues,
         iq_message_queues, sm_message_queues, c2s_message_queues, sql_message_queues, offline_message_queues,
         iq_internal_queues, sm_internal_queues, c2s_internal_queues, sql_internal_queues, offline_internal_queues]).

% Generic default monitors to aglomerate common values
-define(DEFAULT_MONITORS,
        [{c2s_receive, <<"+message_receive_packet+chat_receive_packet+groupchat_receive_packet+presence_receive_packet">>},
         {c2s_send, <<"+message_send_packet+chat_send_packet+groupchat_send_packet+presence_send_packet">>},
         {s2s_receive, <<"+s2s_message_receive_packet+s2s_chat_receive_packet+s2s_groupchat_receive_packet+s2s_presence_receive_packet">>},
         {s2s_send, <<"+s2s_message_send_packet+s2s_chat_send_packet+s2s_groupchat_send_packet+s2s_presence_send_packet">>},
         %{muc_rooms, <<"+muc_create-muc_destroy">>},
         %{muc_users, <<"+muc_user_join-muc_user_leave">>},
         %{pubsub_nodes, <<"+pubsub_create_node-pubsub_delete_node">>},
         {message_queues, process_queues, all},
         {listeners_queues, process_queues, ejabberd_listeners},
         {groupchat_queues, process_queues, ejabberd_mod_muc},
         {pubsub_queues, process_queues, ejabberd_mod_pubsub},
         {pubsub_send_pool_queues, process_queues, ejabberd_mod_pubsub_loop},
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
         {memory, <<"erlang:memory(total).">>},  %% supported notation
         {cpu, cpu_usage},
         {processes, <<"erlang:system_info process_count">>}, %% equivalent to erlang:system_info(process_count).
         {health, health_check}
        ]).
