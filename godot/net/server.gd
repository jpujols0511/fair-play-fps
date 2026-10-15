extends SceneTree
## Headless authoritative server.
##
## godot --headless --path godot --script res://net/server.gd -- \
##     --port 47911 --ticks 64 --tokens /run/tokens.json --out /run/match \
##     [--jitter-ticks 3]
##
## Transport is DTLS (invariant 2). The server creates its key and a
## self-signed certificate at start and writes the certificate to
## <out>/server_cert.crt for clients to trust. Each client must open a DTLS
## session and send HELLO with the access token issued for its player id; the
## identity is then bound to that session. Plain UDP never reaches the kernel.
##
## Match: fixed 64 or 128 Hz tick; release buffered intents to the kernel, step, send
## each client its server-confirmed state. Every submit is written to a demo
## log for offline replay and detection (invariant 5). The result records a
## hash of the kernel source so players can check what the server ran.
##
## Jitter buffer (invariant 6): intents wait in a per-player buffer and are
## released one per tick in sequence order, after an initial fill of
## --jitter-ticks. Jitter and reordering smaller than that never leave a tick
## without the player's own input, and a later gap costs one neutral tick, not
## the input (decision 0002). Release never depends on send rate: one command
## per player per tick, so sending faster buys nothing (invariant 1).

const Kernel = preload("res://kernel/fairplay_kernel.gd")
const Protocol = preload("res://net/protocol.gd")
const MAX_BUFFER := 64
const PRIME_TIMEOUT_MSEC := 2000


func _initialize() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	var port: int = int(args.get("port", "47911"))
	var ticks: int = int(args.get("ticks", "64"))
	var tick_rate: int = int(args.get("tick-rate", str(Kernel.TICK_RATE)))
	if not Kernel.SUPPORTED_TICK_RATES.has(tick_rate):
		push_error("tick rate must be 64 or 128")
		quit(2)
		return
	var out_dir: String = args.get("out", "user://run")
	var jitter_ticks: int = clampi(int(args.get("jitter-ticks", "3")), 0, MAX_BUFFER / 2)
	DirAccess.make_dir_recursive_absolute(out_dir)
	var tokens: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(args.get("tokens", "")))
	if tokens == null or tokens.is_empty():
		push_error("no access tokens")
		quit(2)
		return
	var expected: Array = tokens.keys()
	expected.sort()

	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var cert := crypto.generate_self_signed_certificate(key,
		"CN=%s,O=Fair Play FPS,C=US" % Protocol.SERVER_NAME)
	var udp_server := UDPServer.new()
	if udp_server.listen(port, "127.0.0.1") != OK:
		push_error("listen failed on port %d" % port)
		quit(2)
		return
	var dtls := DTLSServer.new()
	if dtls.setup(TLSOptions.server(key, cert)) != OK:
		push_error("DTLS setup failed")
		quit(2)
		return
	cert.save(out_dir + "/server_cert.crt")

	var conns: Array = []
	var bound := {}
	var stats := {"packets": 0, "malformed": 0, "auth_failed": 0, "identity_mismatch": 0,
		"handshake_failed": 0, "pre_start_discarded": 0, "post_match_discarded": 0, "buffer": {}}

	var deadline := Time.get_ticks_msec() + 15000
	while bound.size() < expected.size() and Time.get_ticks_msec() < deadline:
		_service(udp_server, dtls, conns, tokens, bound, stats, null, "pre_start_discarded")
		OS.delay_msec(2)
	if bound.size() < expected.size():
		_write(out_dir + "/result.json", {"ok": false, "error": "players missing", "bound": bound.keys(), "stats": stats})
		quit(3)
		return

	var kernel = Kernel.new(expected, tick_rate)
	var buffers := {}
	for player_id in expected:
		buffers[player_id] = {}
		stats["buffer"][player_id] = {"underruns": 0, "late": 0, "trimmed": 0, "duplicate": 0, "overflow": 0, "max_depth": 0}
	# Fill every buffer before the first tick, so steady state has slack.
	var prime_deadline := Time.get_ticks_msec() + PRIME_TIMEOUT_MSEC
	while Time.get_ticks_msec() < prime_deadline \
			and buffers.values().any(func(pending): return pending.size() < jitter_ticks):
		_service(udp_server, dtls, conns, tokens, bound, stats, buffers, "")
		OS.delay_msec(1)
	var demo: Array = []
	var tick_usec: int = 1000000 / tick_rate
	var next_tick: int = Time.get_ticks_usec()
	for _t in ticks:
		next_tick += tick_usec
		while Time.get_ticks_usec() < next_tick:
			OS.delay_usec(200)
		_service(udp_server, dtls, conns, tokens, bound, stats, buffers, "")
		var submits := _release(kernel, buffers, stats, jitter_ticks)
		kernel.step()
		demo.append(submits)
		for player_id in bound:
			bound[player_id]["dtls"].put_packet(Protocol.encode_snapshot(kernel.tick, kernel.players[player_id]))
	# Keep servicing briefly so late handshakes and the last snapshots flush.
	var flush_until := Time.get_ticks_msec() + 300
	while Time.get_ticks_msec() < flush_until:
		_service(udp_server, dtls, conns, tokens, bound, stats, null, "post_match_discarded")
		OS.delay_msec(5)

	var summary := {
		"ok": true, "engine": Engine.get_version_info()["string"], "transport": "DTLS",
		"jitter_ticks": jitter_ticks,
		"kernel_sha256": FileAccess.get_sha256("res://kernel/fairplay_kernel.gd"),
		"tick_rate": tick_rate, "ticks": kernel.tick, "digest": kernel.digest(), "stats": stats,
		"players": kernel.players, "evidence_counts": {},
	}
	for player_id in expected:
		summary["evidence_counts"][player_id] = kernel.evidence_counts(player_id)
	_write(out_dir + "/demo.json", demo)
	_write(out_dir + "/result.json", summary)
	print(JSON.stringify({"server": "done", "digest": summary["digest"], "stats": stats}))
	quit(0)


## Accepts new DTLS sessions, authenticates HELLO, and (during the match)
## buffers intents whose player id matches the session's bound identity.
## Outside the match, buffers is null and intents are counted under discard.
func _service(udp_server: UDPServer, dtls: DTLSServer, conns: Array, tokens: Dictionary,
		bound: Dictionary, stats: Dictionary, buffers, discard: String) -> void:
	udp_server.poll()
	while udp_server.is_connection_available():
		var peer := udp_server.take_connection()
		var session := dtls.take_connection(peer)
		if session.get_status() == PacketPeerDTLS.STATUS_HANDSHAKING:
			conns.append({"dtls": session, "player_id": "", "failed": false})
		else:
			stats["handshake_failed"] += 1
	for conn in conns:
		if conn["failed"]:
			continue
		var session: PacketPeerDTLS = conn["dtls"]
		session.poll()
		var status := session.get_status()
		if status == PacketPeerDTLS.STATUS_ERROR or status == PacketPeerDTLS.STATUS_ERROR_HOSTNAME_MISMATCH:
			conn["failed"] = true
			stats["handshake_failed"] += 1
			continue
		if status != PacketPeerDTLS.STATUS_CONNECTED:
			continue
		while session.get_available_packet_count() > 0:
			var packet := session.get_packet()
			stats["packets"] += 1
			if conn["player_id"] == "":
				var hello := Protocol.decode_hello(packet)
				if hello.is_empty():
					stats["malformed"] += 1
					continue
				var player_id: String = hello["player_id"]
				if not tokens.has(player_id) or bound.has(player_id) \
						or not Protocol.tokens_equal(tokens[player_id], hello["token"]):
					stats["auth_failed"] += 1
					continue
				conn["player_id"] = player_id
				bound[player_id] = conn
				continue
			var decoded := Protocol.decode_intent(packet)
			if decoded.is_empty():
				stats["malformed"] += 1
				continue
			if decoded["player_id"] != conn["player_id"]:
				stats["identity_mismatch"] += 1
				continue
			if buffers == null:
				stats[discard] += 1
				continue
			var pending: Dictionary = buffers[conn["player_id"]]
			var counters: Dictionary = stats["buffer"][conn["player_id"]]
			var cmd: Dictionary = decoded["command"]
			if pending.has(cmd["sequence"]):
				counters["duplicate"] += 1
			elif pending.size() >= MAX_BUFFER:
				counters["overflow"] += 1
			else:
				pending[cmd["sequence"]] = cmd
				counters["max_depth"] = maxi(counters["max_depth"], pending.size())


## For each player in sorted order:
## 1. If the buffer is far behind (more than 2 * jitter_ticks + 4), drop the
##    oldest intents so that player's latency stays bounded.
## 2. Submit intents the kernel has already passed. They are recorded as
##    stale_input, which never counts toward suspicion.
## 3. Submit the next intent if it is next in sequence, or if the buffer is
##    deeper than jitter_ticks (a gap that waiting will not fill).
## Otherwise it is an underrun: the kernel applies a neutral tick and consumes
## no sequence number, so the late intent still counts when it arrives.
## Returns the submits in order for the demo log.
func _release(kernel, buffers: Dictionary, stats: Dictionary, jitter_ticks: int) -> Array:
	var submits: Array = []
	var ids: Array = buffers.keys()
	ids.sort()
	for player_id in ids:
		var pending: Dictionary = buffers[player_id]
		var counters: Dictionary = stats["buffer"][player_id]
		var last: int = kernel.players[player_id]["last_sequence"]
		var sequences: Array = pending.keys()
		sequences.sort()
		while sequences.size() > 2 * jitter_ticks + 4:
			pending.erase(sequences.pop_front())
			counters["trimmed"] += 1
		while not sequences.is_empty() and sequences[0] <= last:
			var stale: Dictionary = pending[sequences[0]]
			pending.erase(sequences.pop_front())
			kernel.submit(player_id, stale)
			submits.append([player_id, stale])
			counters["late"] += 1
		if not sequences.is_empty() and (sequences[0] == last + 1 or sequences.size() > jitter_ticks):
			var cmd: Dictionary = pending[sequences[0]]
			pending.erase(sequences[0])
			kernel.submit(player_id, cmd)
			submits.append([player_id, cmd])
		else:
			counters["underruns"] += 1
	return submits


func _parse(user_args: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < user_args.size() - 1:
		if user_args[i].begins_with("--"):
			out[user_args[i].substr(2)] = user_args[i + 1]
			i += 2
		else:
			i += 1
	return out


func _write(path: String, data) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  ", true))
	f.close()
