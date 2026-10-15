extends SceneTree
## Headless authoritative server on ENet with DTLS (decision 0001, stage 2).
##
## godot --headless --path godot --script res://net/enet_server.gd -- \
##     --port 47911 --ticks 64 --tokens /run/tokens.json --out /run/match \
##     [--jitter-ticks 3] [--bind 127.0.0.1]
##
## Same rules as net/server.gd, on Netfox's transport and clock:
## - ENet with DTLS (invariant 2). A self-signed certificate per match is
##   written to <out>/server_cert.crt. Plain UDP never completes a session.
## - Authentication through SceneMultiplayer: a peer's first message must be
##   HELLO with its access token. Packets and RPCs from a peer are ignored
##   until the token matches; the identity is then bound to that peer.
## - Netfox NetworkTime drives the 64 Hz tick and synchronizes each client's
##   clock to this server, so clients stamp each intent with the server tick
##   it is meant for. Netfox carries timing only; nothing it sends reaches the
##   kernel.
## - Intents go through the shared jitter buffer (decision 0002). The kernel
##   decides every outcome (invariant 1); every submit is written to the demo
##   log (invariant 5).

const Kernel = preload("res://kernel/fairplay_kernel.gd")
const Protocol = preload("res://net/protocol.gd")
const InputBuffer = preload("res://net/input_buffer.gd")
const START_TIMEOUT_MSEC := 20000
const PRIME_TIMEOUT_MSEC := 2000

var tokens := {}
var expected: Array = []
var bound := {}   # player_id -> peer id
var peers := {}   # peer id -> player_id
var stats := {"packets": 0, "malformed": 0, "auth_failed": 0, "identity_mismatch": 0,
	"unbound_packet": 0, "pre_start_discarded": 0, "post_match_discarded": 0}
var arrival := {} # player_id -> [server tick at arrival - intent sequence]
var kernel
var buffers
var demo: Array = []
var ticks := 64
var start_tick := -1
var synced_at := -1
var deadline := 0
var finished := false
var out_dir := ""
var mp: SceneMultiplayer
var time_node: Node


func _initialize() -> void:
	_begin.call_deferred()


func _begin() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	var port: int = int(args.get("port", "47911"))
	ticks = int(args.get("ticks", "64"))
	out_dir = args.get("out", "user://run")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(args.get("tokens", "")))
	if not parsed is Dictionary or parsed.is_empty():
		_fail("no access tokens", 2)
		return
	tokens = parsed
	expected = tokens.keys()
	expected.sort()
	Engine.max_fps = 500

	var crypto := Crypto.new()
	var key := crypto.generate_rsa(2048)
	var cert := crypto.generate_self_signed_certificate(key,
		"CN=%s,O=Fair Play FPS,C=US" % Protocol.SERVER_NAME)
	var peer := ENetMultiplayerPeer.new()
	peer.set_bind_ip(args.get("bind", "127.0.0.1"))
	if peer.create_server(port, 32) != OK:
		_fail("listen failed on port %d" % port, 2)
		return
	if peer.host.dtls_server_setup(TLSOptions.server(key, cert)) != OK:
		_fail("DTLS setup failed", 2)
		return
	cert.save(out_dir + "/server_cert.crt")

	kernel = Kernel.new(expected)
	buffers = InputBuffer.new(expected, int(args.get("jitter-ticks", "3")))
	for player_id in expected:
		arrival[player_id] = []
	mp = get_multiplayer() as SceneMultiplayer
	mp.auth_callback = _on_auth
	mp.auth_timeout = 5.0
	mp.peer_packet.connect(_on_packet)
	time_node = root.get_node("NetworkTime")
	time_node.on_tick.connect(_on_tick)
	deadline = Time.get_ticks_msec() + START_TIMEOUT_MSEC
	# NetworkEvents starts NetworkTime once the peer is set.
	mp.multiplayer_peer = peer


## HELLO is checked before the peer can send anything else. A wrong token is
## counted and ignored; the peer may retry until the auth timeout.
func _on_auth(peer_id: int, data: PackedByteArray) -> void:
	var hello := Protocol.decode_hello(data)
	if hello.is_empty():
		stats["malformed"] += 1
		return
	var player_id: String = hello["player_id"]
	if not tokens.has(player_id) or bound.has(player_id) or peers.has(peer_id) \
			or not Protocol.tokens_equal(tokens[player_id], hello["token"]):
		stats["auth_failed"] += 1
		return
	bound[player_id] = peer_id
	peers[peer_id] = player_id
	mp.complete_auth(peer_id)


func _on_packet(peer_id: int, packet: PackedByteArray) -> void:
	stats["packets"] += 1
	if not peers.has(peer_id):
		stats["unbound_packet"] += 1
		return
	var decoded := Protocol.decode_intent(packet)
	if decoded.is_empty():
		stats["malformed"] += 1
		return
	var player_id: String = peers[peer_id]
	if decoded["player_id"] != player_id:
		stats["identity_mismatch"] += 1
		return
	if finished:
		stats["post_match_discarded"] += 1
		return
	var cmd: Dictionary = decoded["command"]
	if start_tick >= 0:
		arrival[player_id].append(time_node.tick - cmd["sequence"])
	buffers.add(player_id, cmd)


func _on_tick(_delta: float, tick: int) -> void:
	if finished:
		return
	if start_tick < 0:
		# Hold only the newest intents until everyone is ready, so a player who
		# connected early does not start the match with extra latency.
		stats["pre_start_discarded"] += buffers.keep_newest(buffers.target + 1)
		if not _ready_to_start():
			if Time.get_ticks_msec() > deadline:
				_fail("players missing or not synced", 3)
			return
		start_tick = tick
	var submits: Array = buffers.release(kernel)
	kernel.step()
	demo.append(submits)
	for player_id in bound:
		mp.send_bytes(Protocol.encode_snapshot(kernel.tick, kernel.players[player_id]),
			bound[player_id], MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	if kernel.tick >= ticks:
		finished = true
		_finish.call_deferred()


## Every player authenticated and on the server clock, and every buffer
## filled (or the fill timed out).
func _ready_to_start() -> bool:
	if bound.size() < expected.size():
		return false
	for player_id in expected:
		if not time_node.is_client_synced(bound[player_id]):
			return false
	if synced_at < 0:
		synced_at = Time.get_ticks_msec()
	return buffers.primed() or Time.get_ticks_msec() > synced_at + PRIME_TIMEOUT_MSEC


func _finish() -> void:
	# Let the last snapshots flush before closing.
	await create_timer(0.3).timeout
	var summary := {
		"ok": true, "engine": Engine.get_version_info()["string"], "transport": "ENet+DTLS",
		"clock": {"driver": "netfox NetworkTime", "tickrate": time_node.tickrate, "start_tick": start_tick},
		"jitter_ticks": buffers.target,
		"kernel_sha256": FileAccess.get_sha256("res://kernel/fairplay_kernel.gd"),
		"ticks": kernel.tick, "digest": kernel.digest(), "stats": stats, "buffer": buffers.counters,
		"arrival": {}, "players": kernel.players, "evidence_counts": {},
	}
	for player_id in expected:
		summary["evidence_counts"][player_id] = kernel.evidence_counts(player_id)
		summary["arrival"][player_id] = _summarize(arrival[player_id])
	_write(out_dir + "/demo.json", demo)
	_write(out_dir + "/result.json", summary)
	print(JSON.stringify({"server": "done", "digest": summary["digest"], "stats": stats}))
	mp.multiplayer_peer.close()
	quit(0)


## Ticks between the tick an intent was stamped for and the server tick it
## arrived on. Near zero means the client clock follows the server's.
static func _summarize(values: Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0}
	var sorted := values.duplicate()
	sorted.sort()
	return {"count": sorted.size(), "min": sorted[0], "median": sorted[sorted.size() / 2],
		"max": sorted[-1]}


func _fail(error: String, code: int) -> void:
	finished = true
	if out_dir != "":
		_write(out_dir + "/result.json", {"ok": false, "error": error, "bound": bound.keys(), "stats": stats})
	push_error(error)
	quit(code)


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
