extends SceneTree
## Headless authoritative server for the loopback spike.
##
## godot --headless --path godot --script res://net/server.gd -- \
##     --port 47911 --ticks 64 --players attacker,honest --out /tmp/run
##
## Waits for every expected player, binds each identity to the address it
## first spoke from, then runs a fixed 64 Hz tick: drain intents, submit them
## to the kernel, step, send each client its server-confirmed state. Every
## submit is written to a demo log so the run can be replayed offline
## (invariant 5) and checked against the Python oracle.

const Kernel = preload("res://kernel/fairplay_kernel.gd")
const Protocol = preload("res://net/protocol.gd")


func _initialize() -> void:
	var args := _parse(OS.get_cmdline_user_args())
	var port: int = int(args.get("port", "47911"))
	var ticks: int = int(args.get("ticks", "64"))
	var expected: Array = String(args.get("players", "attacker,honest")).split(",")
	var out_dir: String = args.get("out", "user://run")
	DirAccess.make_dir_recursive_absolute(out_dir)

	var udp := PacketPeerUDP.new()
	if udp.bind(port, "127.0.0.1") != OK:
		push_error("bind failed on port %d" % port)
		quit(2)
		return

	var bound := {}       # player_id -> "ip:port"
	var addresses := {}   # "ip:port" -> [ip, port]
	var stats := {"packets": 0, "malformed": 0, "unknown_player": 0,
		"address_mismatch": 0, "pre_start_discarded": 0}

	var deadline := Time.get_ticks_msec() + 10000
	while bound.size() < expected.size() and Time.get_ticks_msec() < deadline:
		_drain(udp, expected, bound, addresses, stats, null, null)
		OS.delay_msec(2)
	if bound.size() < expected.size():
		_write(out_dir + "/result.json", {"ok": false, "error": "players missing", "bound": bound.keys()})
		quit(3)
		return

	var kernel = Kernel.new(expected)
	var demo: Array = []
	var tick_usec: int = 1000000 / Kernel.TICK_RATE
	var next_tick: int = Time.get_ticks_usec()
	for _t in ticks:
		next_tick += tick_usec
		while Time.get_ticks_usec() < next_tick:
			OS.delay_usec(200)
		var submits: Array = []
		_drain(udp, expected, bound, addresses, stats, kernel, submits)
		kernel.step()
		demo.append(submits)
		for player_id in bound:
			var addr: Array = addresses[bound[player_id]]
			udp.set_dest_address(addr[0], addr[1])
			udp.put_packet(Protocol.encode_snapshot(kernel.tick, kernel.players[player_id]))

	var summary := {
		"ok": true, "engine": Engine.get_version_info()["string"],
		"ticks": kernel.tick, "digest": kernel.digest(), "stats": stats,
		"players": kernel.players, "evidence_counts": {},
	}
	for player_id in expected:
		summary["evidence_counts"][player_id] = kernel.evidence_counts(player_id)
	_write(out_dir + "/demo.json", demo)
	_write(out_dir + "/result.json", summary)
	print(JSON.stringify({"server": "done", "digest": summary["digest"], "stats": stats}))
	quit(0)


## Reads every waiting packet. Before the match (kernel == null) it only binds
## identities. During the match it submits valid intents from the bound address.
func _drain(udp: PacketPeerUDP, expected: Array, bound: Dictionary, addresses: Dictionary,
		stats: Dictionary, kernel, submits) -> void:
	while udp.get_available_packet_count() > 0:
		var packet := udp.get_packet()
		var source := "%s:%d" % [udp.get_packet_ip(), udp.get_packet_port()]
		addresses[source] = [udp.get_packet_ip(), udp.get_packet_port()]
		stats["packets"] += 1
		var decoded := Protocol.decode_intent(packet)
		if decoded.is_empty():
			stats["malformed"] += 1
			continue
		var player_id: String = decoded["player_id"]
		if not expected.has(player_id):
			stats["unknown_player"] += 1
			continue
		if not bound.has(player_id):
			if kernel == null and not bound.values().has(source):
				bound[player_id] = source
			else:
				stats["address_mismatch"] += 1
			continue
		if bound[player_id] != source:
			# Placeholder for real authentication (invariant 2): an identity is
			# only accepted from the address it bound to.
			stats["address_mismatch"] += 1
			continue
		if kernel == null:
			stats["pre_start_discarded"] += 1
			continue
		var cmd: Dictionary = decoded["command"]
		kernel.submit(player_id, cmd)
		submits.append([player_id, cmd])


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
