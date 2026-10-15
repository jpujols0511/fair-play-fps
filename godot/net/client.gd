extends SceneTree
## Thin headless client for the loopback spike.
##
## godot --headless --path godot --script res://net/client.gd -- \
##     --port 47911 --player honest --role honest --seconds 3
##
## Sends one intent per tick and keeps the last server-confirmed state; it never
## computes its own position. Role "attacker" is a controlled test fixture: it
## sends oversized movement and fire on every tick, and from tick 32 every 16
## ticks it also sends a forged packet carrying a position, and an intent that
## claims to be "honest" from its own address. No real cheat code.

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
	var total_ticks: int = int(float(args.get("seconds", "3")) * Kernel.TICK_RATE)

	var udp := PacketPeerUDP.new()
	udp.connect_to_host("127.0.0.1", port)
	var sent := 0
	var forged := 0
	var snapshots := 0
	var confirmed := {}
	var tick_usec: int = 1000000 / Kernel.TICK_RATE
	var next_tick: int = Time.get_ticks_usec()

	for local_tick in total_ticks:
		next_tick += tick_usec
		while Time.get_ticks_usec() < next_tick:
			OS.delay_usec(200)
		var cmd: Dictionary
		if role == "attacker":
			cmd = Kernel.command(local_tick, 5000, -4000, 450000, true)
		else:
			var moving := (local_tick / 32) % 2 == 0
			cmd = Kernel.command(local_tick, 1000 if moving else 0, 0, 90000, local_tick % 12 == 0)
		udp.put_packet(Protocol.encode_intent(player_id, cmd))
		sent += 1
		if role == "attacker" and local_tick >= 32 and local_tick % 16 == 0:
			var teleport := Protocol.encode_intent(player_id, cmd)
			var claim := StreamPeerBuffer.new()
			claim.put_32(99999)
			claim.put_32(99999)
			teleport.append_array(claim.data_array)
			udp.put_packet(teleport)
			udp.put_packet(Protocol.encode_intent("honest", Kernel.command(local_tick + 1000, 1000, 0, 0, true)))
			forged += 2
		while udp.get_available_packet_count() > 0:
			var snap := Protocol.decode_snapshot(udp.get_packet())
			if not snap.is_empty():
				snapshots += 1
				confirmed = snap

	print(JSON.stringify({"client": player_id, "role": role, "sent": sent, "forged": forged,
		"snapshots": snapshots, "last_confirmed": confirmed}, "", true))
	quit(0)
