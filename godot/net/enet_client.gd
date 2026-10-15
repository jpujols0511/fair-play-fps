extends SceneTree
## Thin headless client on ENet with DTLS (decision 0001, stage 2).
##
## godot --headless --path godot --script res://net/enet_client.gd -- \
##     --port 47911 --player honest --role honest --token <hex> \
##     --cert /run/match/server_cert.crt --seconds 3 [--jitter hold2]
##
## Trusts only the server certificate, authenticates with HELLO, then lets
## Netfox synchronize its clock to the server. Each Netfox tick it sends one
## intent stamped with that tick, which is its estimate of the server's tick.
## It keeps the last server-confirmed state and never computes its own
## position.
##
## Role "attacker" is the same controlled test fixture as net/client.gd: a
## HELLO claiming "honest" with a wrong token first, oversized movement and
## fire every tick, and from its 32nd tick every 16 ticks a forged position,
## an intent claiming "honest" inside its own session, and a plaintext intent
## outside DTLS. --jitter hold2 holds every eighth intent two ticks.

const Kernel = preload("res://kernel/fairplay_kernel.gd")
const Protocol = preload("res://net/protocol.gd")
const TIMEOUT_MSEC := 30000
const SPOOF_OFFSET := 100000

var port := 47911
var player_id := "honest"
var role := "honest"
var token := ""
var jitter := "none"
var total_ticks := 192
var mp: SceneMultiplayer
var time_node: Node
var plaintext := PacketPeerUDP.new()
var first_tick := -1
var sent := 0
var forged := 0
var snapshots := 0
var confirmed := {}
var held: Array = []
var deadline := 0
var done := false


func _initialize() -> void:
	_begin.call_deferred()


func _begin() -> void:
	var args := {}
	var user_args := OS.get_cmdline_user_args()
	for i in range(0, user_args.size() - 1, 2):
		args[user_args[i].substr(2)] = user_args[i + 1]
	port = int(args.get("port", "47911"))
	player_id = args.get("player", "honest")
	role = args.get("role", "honest")
	token = args.get("token", "")
	jitter = args.get("jitter", "none")
	total_ticks = int(float(args.get("seconds", "3")) * Kernel.TICK_RATE)
	Engine.max_fps = 500
	deadline = Time.get_ticks_msec() + TIMEOUT_MSEC

	var cert := X509Certificate.new()
	if cert.load(args.get("cert", "")) != OK:
		_finish({"error": "cannot load server certificate"}, 1)
		return
	var peer := ENetMultiplayerPeer.new()
	if peer.create_client("127.0.0.1", port) != OK:
		_finish({"error": "cannot create client"}, 1)
		return
	if peer.host.dtls_client_setup(Protocol.SERVER_NAME, TLSOptions.client(cert)) != OK:
		_finish({"error": "DTLS setup failed"}, 1)
		return
	plaintext.connect_to_host("127.0.0.1", port)
	mp = get_multiplayer() as SceneMultiplayer
	# The server sends no auth data; the callback only enables the handshake.
	mp.auth_callback = func(_id: int, _data: PackedByteArray) -> void: pass
	mp.peer_authenticating.connect(_on_authenticating)
	mp.peer_packet.connect(_on_packet)
	mp.server_disconnected.connect(_report.bind(0))
	time_node = root.get_node("NetworkTime")
	time_node.on_tick.connect(_on_tick)
	# NetworkEvents starts NetworkTime once connected; it syncs to the server.
	mp.multiplayer_peer = peer


func _on_authenticating(peer_id: int) -> void:
	if role == "attacker":
		mp.send_auth(peer_id, Protocol.encode_hello("honest", "0".repeat(Protocol.TOKEN_LEN)))
		forged += 1
	mp.send_auth(peer_id, Protocol.encode_hello(player_id, token))
	mp.complete_auth(peer_id)


func _on_packet(_peer_id: int, packet: PackedByteArray) -> void:
	var snap := Protocol.decode_snapshot(packet)
	if not snap.is_empty():
		snapshots += 1
		confirmed = snap


func _on_tick(_delta: float, tick: int) -> void:
	if done:
		return
	if first_tick < 0:
		first_tick = tick
	var i := tick - first_tick
	if i >= total_ticks:
		_report(0)
		return
	var cmd: Dictionary
	if role == "attacker":
		cmd = Kernel.command(tick, 5000, -4000, 450000, true)
	else:
		var moving := (i / 32) % 2 == 0
		cmd = Kernel.command(tick, 1000 if moving else 0, 0, 90000, i % 12 == 0)
	var packet := Protocol.encode_intent(player_id, cmd)
	if jitter == "hold2" and i % 8 == 3:
		held.append(packet)
	else:
		_send(packet)
		if jitter == "hold2" and i % 8 == 5:
			for late in held:
				_send(late)
			held.clear()
	sent += 1
	if role == "attacker" and i >= 32 and i % 16 == 0:
		var teleport := Protocol.encode_intent(player_id, cmd)
		var claim := StreamPeerBuffer.new()
		claim.put_32(99999)
		claim.put_32(99999)
		teleport.append_array(claim.data_array)
		_send(teleport)
		var spoof := Protocol.encode_intent("honest", Kernel.command(tick + SPOOF_OFFSET, 1000, 0, 0, true))
		_send(spoof)
		plaintext.put_packet(spoof)
		forged += 3


## Ends after --seconds of ticks, or when the server closes the match.
func _report(code: int) -> void:
	if not done:
		_finish({"sent": sent, "forged": forged, "snapshots": snapshots, "first_tick": first_tick,
			"last_confirmed": confirmed}, code)


func _send(packet: PackedByteArray) -> void:
	mp.send_bytes(packet, 1, MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)


func _process(_delta: float) -> bool:
	if not done and Time.get_ticks_msec() > deadline:
		_finish({"error": "timed out", "sent": sent, "first_tick": first_tick,
			"status": mp.multiplayer_peer.get_connection_status() if mp else -1}, 1)
	return false


func _finish(report: Dictionary, code: int) -> void:
	done = true
	report["client"] = player_id
	report["role"] = role
	print(JSON.stringify(report, "", true))
	if mp and mp.multiplayer_peer:
		mp.multiplayer_peer.close()
	quit(code)
