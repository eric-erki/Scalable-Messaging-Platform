
-define(MINUTE, 60000).
-define(HOUR, 3600000).
-define(DAY, 86400000).
-define(WEEK, 604800000).
-define(MONTH, 2592000000).

-define(HYPERLOGLOGS,
        [daily_active_users, weekly_active_users, monthly_active_users]).

-define(SUPPORTED_HOOKS,
        [offline_message_hook, resend_offline_messages_hook,
         sm_register_connection_hook, sm_remove_connection_hook,
         remove_user, register_user,
         roster_in_subscription, roster_out_subscription,
         user_available_hook, unset_presence_hook, set_presence_hook,
         user_send_packet, user_receive_packet,
         s2s_send_packet, s2s_receive_packet]).
        % TODO those need submodule register
         %muc_create, muc_destroy, muc_user_join, muc_user_leave, muc_message,
         %pubsub_publish_item, pubsub_create_node, pubsub_delete_node, pubsub_broadcast_stanza]).
-define(GENERATED_HOOKS,
        [presence_receive_packet, presence_send_packet,
         subscribe_receive_packet, subscribe_send_packet,
         subscribed_receive_packet, subscribed_send_packet,
         unsubscribe_receive_packet, unsubscribe_send_packet,
         unsubscribed_receive_packet, unsubscribed_send_packet,
         message_receive_packet, message_send_packet,
         chat_receive_packet, chat_send_packet,
         groupchat_receive_packet, groupchat_send_packet,
         error_receive_packet, error_send_packet,
         headline_receive_packet, headline_send_packet,
         result_receive_packet, result_send_packet,
         iq_receive_packet, iq_send_packet,
         broadcast_receive_packet, broadcast_send_packet,
         s2s_presence_receive_packet, s2s_presence_send_packet,
         s2s_subscribe_receive_packet, s2s_subscribe_send_packet,
         s2s_subscribed_receive_packet, s2s_subscribed_send_packet,
         s2s_unsubscribe_receive_packet, s2s_unsubscribe_send_packet,
         s2s_unsubscribed_receive_packet, s2s_unsubscribed_send_packet,
         s2s_message_receive_packet, s2s_message_send_packet,
         s2s_chat_receive_packet, s2s_chat_send_packet,
         s2s_groupchat_receive_packet, s2s_groupchat_send_packet,
         s2s_error_receive_packet, s2s_error_send_packet,
         s2s_headline_receive_packet, s2s_headline_send_packet,
         s2s_result_receive_packet, s2s_result_send_packet,
         s2s_iq_receive_packet, s2s_iq_send_packet,
         s2s_broadcast_receive_packet, s2s_broadcast_send_packet,
         sm_register_connection_c2s, sm_register_connection_c2s_tls,
         sm_register_connection_c2s_compressed,
         sm_register_connection_http_poll, sm_register_connection_http_bind,
         sm_register_connection_http_ws, sm_register_connection,
         sm_remove_connection_c2s, sm_remove_connection_c2s_tls,
         sm_remove_connection_c2s_compressed,
         sm_remove_connection_http_poll, sm_remove_connection_http_bind,
         sm_remove_connection_http_ws, sm_remove_connection,
         pubsub_nodes, pubsub_users, muc_rooms, muc_users,
         muc_message_size, message_send_size, message_receive_size]).

% By default all probes are type counter. The ones listed above use another type:
-define(NO_COUNTER_PROBES,
        [{muc_rooms,gauge},
         {muc_users,gauge},
         {pubsub_nodes,gauge},
         {pubsub_users,gauge},
         {daily_active_users,gauge},
         {weekly_active_users,gauge},
         {monthly_active_users,gauge} ]).

%% other available hooks
%%adhoc_local_commands
%%adhoc_local_items
%%adhoc_sm_commands
%%adhoc_sm_items
%%c2s_stream_features
%%c2s_unauthenticated_iq
%%s2s_loop_debug
%%s2s_connect_hook
%%disco_local_features
%%disco_local_identity
%%disco_local_items
%%disco_sm_features
%%disco_sm_identity
%%disco_sm_items
%%ejabberd_ctl_process
%%local_send_to_resource_hook
%%resend_subscription_requests_hook
%%roster_get
%%roster_get_jid_info
%%roster_get_subscription_lists
%%roster_process_item

% Unit to mesure JABS counter
-define(JABS, [
 {'XPS', 1},        % Sending an XMPP Packet, cost of 6k payload (XMPP Packet Send)
 {'LOG', 10},       % Sending an authentication packet (Login)
 {'ROST50', 2},     % Receiving a roster of less than 50 contacts
 {'ROST100', 3},    % Receiving a roster of 50-100 contacts
 {'ROST200', 4},    % Receiving a roster of 100-200 contacts
 {'ROST1000', 7},   % Receiving a roster of 200-1000 contacts
 {'OFF', 4},        % Offline message
 {'EXT', 4},        % Receiving an external packet (S2S or component)
 {'MJN', 3},        % MUC join
 {'MJP10', 2},      % MUC presence broadcast up to to 10 users
 {'MJP100', 4},     % MUC presence broadcast to 10-100 users
 {'MJP200', 8},     % MUC presence broadcast to 100-200 users
 {'MJM10', 3},      % MUC message broadcast to 10 users
 {'MJM100', 6},     % MUC message broadcast to 10-100 users
 {'MJM200', 10},    % MUC message broadcast to 100-200 users
 {'PSB10', 3},      % Pubsub broadcast up to 10 users
 {'PSB100', 4},     % Pubsub broadcast to 10-100 users
 {'PSB500', 5},     % Pubsub broadcast to 100-500 users
 {'PSB2000', 6},    % Pubsub broadcast to 500-2000 users
 {'PSB2000+', 10}   % Pubsub broadcast to 2000+ users 10 jabs
]).
