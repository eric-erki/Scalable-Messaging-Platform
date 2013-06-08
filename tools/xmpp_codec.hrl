-record(last, {seconds, text}).

-record(version, {name, version, os}).

-record(roster, {item = [], ver}).

-record(roster_item,
	{jid, name, groups = [], subscription = none, ask}).

-record(privacy_item,
	{order, action, type, value, stanza}).

-record(privacy, {list = [], default, active}).

-record(privacy_list, {name, privacy_item = []}).

-record(block, {block_item = []}).

-record(unblock, {block_item = []}).

-record(block_list, {}).

-record(disco_info,
	{node, identity = [], feature = []}).

-record(disco_items, {node, items = []}).

-record(disco_item, {jid, name, node}).

-record(private, {sub_els = []}).

-record(bookmark_storage, {conference = [], url = []}).

-record(bookmark_url, {name, url}).

-record(bookmark_conference,
	{name, jid, autojoin = false, nick, password}).

-record(stats, {stat = []}).

-record(stat, {name, units, value, error = []}).

-record('Iq',
	{id, type, lang, from, to, error, sub_els = []}).

-record('Message',
	{id, type = normal, lang, from, to, subject = [],
	 body = [], thread, error, sub_els = []}).

-record('Presence',
	{id, type, lang, from, to, show, status = [], priority,
	 error, sub_els = []}).

-record(error, {error_type, by, reason, text}).

-record(redirect, {cdata}).

-record(gone, {cdata}).

-record(bind, {jid, resource}).

-record(sasl_auth, {mechanism, cdata}).

-record(sasl_abort, {}).

-record(sasl_challenge, {cdata}).

-record(sasl_response, {cdata}).

-record(sasl_success, {cdata}).

-record(sasl_failure, {reason, text}).

-record(sasl_mechanisms, {mechanism = []}).

-record(starttls, {required = false}).

-record(starttls_proceed, {}).

-record(starttls_failure, {}).

-record(stream_features, {sub_els = []}).

-record(p1_push, {}).

-record(p1_rebind, {}).

-record(p1_ack, {}).

-record(caps, {hash, node, ver}).

-record(register, {}).

-record(session, {}).

-record(ping, {}).

-record(time, {tzo, utc}).

-record(stream_error, {reason, text}).

-record('see-other-host', {cdata}).
