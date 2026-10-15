extends SceneTree
## Thin headless client.
##
## godot --headless --path godot --script res://net/client.gd -- \
##     --port 47911 --player honest --role honest --token <hex> \
##     --cert /run/match/server_cert.crt --seconds 3
##
## Opens a DTLS session that trusts only the server certificate, sends HELLO
## with its access token, then one intent per tick. It keeps the last
## server-confirmed state and never computes its own position.
##
## Role "attacker" is a controlled test fixture, not a cheat. It first sends a
## HELLO claiming "honest" with a wrong token, then authenticates as itself,
## sends oversized movement and fire every tick, and from tick 32 every 16
## ticks: a packet carrying a forged position, an intent claiming "honest"
## inside its own session, and a plaintext intent outside DTLS.

const Kernel = preload("res://kernel/fairplay_kernel.gd")
const Protocol = preload("res://net/protocol.gd")


func _initialize() -> void:
	var args := {}
	var user_args := OS.get_cmdline_user_args()
	for i in range(0, user_args.size() - 1, 2):
		args[user_args[i].substr(2)] = user_args[i + 1]
	var port: int = int(args.get("port", "47911"))
	var player_id: String = args.get("player", "honest")
	var role: String = args.get("role", "honest")
	var token: String = args.get("token", "")
	var tick_rate: int = int(args.get("tick-rate", str(Kernel.TICK_RATE)))
	if not Kernel.SUPPORTED_TICK_RATES.has(tick_rate):
		_finish({"client": player_id, "error": "tick rate must be 64 or 128"}, 1)
		return
	var total_ticks: int = int(float(args.get("seconds", "3")) * tick_rate)

	var cert := X509Certificate.new()
	if cert.load(args.get("cert", "")) != OK:
		_finish({"client": player_id, "error": "cannot load server certificate"}, 1)
		return
	var udp := PacketPeerUDP.new()
	udp.connect_to_host("127.0.0.1", port)
	var session := PacketPeerDTLS.new()
	session.connect_to_peer(udp, Protocol.SERVER_NAME, TLSOptions.client(cert))
	var handshake_deadline := Time.get_ticks_msec() + 10000
	while session.get_status() == PacketPeerDTLS.STATUS_HANDSHAKING and Time.get_ticks_msec() < handshake_deadline:
		session.poll()
		OS.delay_msec(5)
	if session.get_status() != PacketPeerDTLS.STATUS_CONNECTED:
		_finish({"client": player_id, "error": "DTLS handshake failed", "status": session.get_status()}, 1)
		return

	var forged := 0
	if role == "attacker":
		session.put_packet(Protocol.encode_hello("honest", "0".repeat(Protocol.TOKEN_LEN)))
		forged += 1
	session.put_packet(Protocol.encode_hello(player_id, token))

	var plaintext := PacketPeerUDP.new()
	plaintext.connect_to_host("127.0.0.1", port)
	var sent := 0
	var snapshots := 0
	var confirmed := {}
	var tick_usec: int = 1000000 / tick_rate
	var next_tick: int = Time.get_ticks_usec()

	for local_tick in total_ticks:
		next_tick += tick_usec
		while Time.get_ticks_usec() < next_tick:
			OS.delay_usec(200)
		session.poll()
		var cmd: Dictionary
		if role == "attacker":
			cmd = Kernel.command(local_tick, 5000, -4000, 450000, true)
		else:
			var moving := (local_tick / (tick_rate / 2)) % 2 == 0
			var fire_interval: int = 12 * tick_rate / Kernel.TICK_RATE
			cmd = Kernel.command(local_tick, 1000 if moving else 0, 0, 90000,
				local_tick % fire_interval == 0)
		session.put_packet(Protocol.encode_intent(player_id, cmd))
		sent += 1
		if role == "attacker" and local_tick >= tick_rate / 2 \
				and local_tick % (tick_rate / 4) == 0:
			var teleport := Protocol.encode_intent(player_id, cmd)
			var claim := StreamPeerBuffer.new()
			claim.put_32(99999)
			claim.put_32(99999)
			teleport.append_array(claim.data_array)
			session.put_packet(teleport)
			var spoof := Protocol.encode_intent("honest", Kernel.command(local_tick + 1000, 1000, 0, 0, true))
			session.put_packet(spoof)
			plaintext.put_packet(spoof)
			forged += 3
		while session.get_available_packet_count() > 0:
			var snap := Protocol.decode_snapshot(session.get_packet())
			if not snap.is_empty():
				snapshots += 1
				confirmed = snap

	_finish({"client": player_id, "role": role, "tick_rate": tick_rate,
		"sent": sent, "forged": forged,
		"snapshots": snapshots, "last_confirmed": confirmed}, 0)


func _finish(report: Dictionary, code: int) -> void:
	print(JSON.stringify(report, "", true))
	quit(code)
