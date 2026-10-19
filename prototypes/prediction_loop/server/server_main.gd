class_name ServerMain
extends Node
## Headless dedicated server (Phase 7): real-time loop + transport glue + handshake around ServerTick (server_tick.gd,
## client_slot.gd), which owns the fixed tick order. Several clients share one world; bots (Phase 8) use the same slots.
##   godot --headless --path . -- --server --port 27015 [--transport enet|udp] [--interp 4] [--exit-on-bye] [--max-seconds N]
## Real time only decides HOW MANY ticks run (an accumulator on Time.get_ticks_usec()); every tick uses 1.0 / 128.0.

const TICK_US := 1000000.0 / 128.0
const MAX_BACKLOG_TICKS := 8
const SILENT_TICKS := 5 * 128                  # a client silent for 5 s is dropped (PROPOSED)
const STATS_EVERY_TICKS := 10 * 128

var transport
var tick := 0
var port := 27015
var exit_on_bye := false
var max_seconds := 0.0
var _acc := 0.0
var _last_us := 0
var overruns := 0
var tick_us := PackedFloat64Array()
var _started_us := 0
var _done := false
var dropped_silent := 0
var had_client := false
var bye_count := 0
var bind_addr := "127.0.0.1"                  # loopback unless --bind-all
var _secret := PackedByteArray()               # HELLO cookie secret, random per run
var acks_rejected := 0
var cookies_rejected := 0
var _last_rx := 0
var _last_tx := 0


var server := ServerTick.new()
var peer_slot: Dictionary = {}                 # transport peer_id -> slot id
var slot_peer: Dictionary = {}                 # slot id -> peer_id
var bots_wanted := 0
var humans_joined := 0


## Value of a flag, or "" when the flag is the last argument (the caller reports it; no out-of-range read).
static func arg_value(args: PackedStringArray, i: int) -> String:
	return args[i + 1] if i + 1 < args.size() else ""


func setup(args: PackedStringArray) -> void:
	for i in args.size():
		var needs_value := args[i] in ["--port", "--interp", "--transport", "--max-seconds", "--bots"]
		if needs_value and arg_value(args, i) == "":
			print("SERVER_ERROR flag %s needs a value" % args[i])
			get_tree().quit(2)
			_done = true
			return
		match args[i]:
			"--port": port = int(arg_value(args, i))
			"--interp": NetConfig.INTERP_TICKS = float(arg_value(args, i))
			"--transport": NetConfig.TRANSPORT = arg_value(args, i)
			"--exit-on-bye": exit_on_bye = true
			"--max-seconds": max_seconds = float(arg_value(args, i))
			"--bots": bots_wanted = int(arg_value(args, i))
			"--bind-all": bind_addr = "*"
	var rc := Crypto.new()
	_secret = rc.generate_random_bytes(16)
	if bots_wanted > 0:
		server.world = Movement.crouch_test_world()          # the bot routes need the overhang and the cover
		for k in mini(bots_wanted, 15):
			var route := Waypoints.load_route(Waypoints.NAMES[k % Waypoints.NAMES.size()])
			server.add_bot(k, 2, route)
			print("SERVER bot %d on route %s (team 2)" % [k, route["name"]])
	transport = TransportUdp.new() if NetConfig.TRANSPORT == "udp" else TransportEnet.new()
	var e: int = transport.listen(port, bind_addr)
	print("Godot ", Engine.get_version_info()["string"])
	print("SERVER listening on %s:%d with %s (error code %d); tick 128 Hz, interp %.1f ticks, snapshot every %d ticks" % [bind_addr, port, NetConfig.TRANSPORT, e, NetConfig.INTERP_TICKS, NetConfig.SNAPSHOT_EVERY_TICKS])
	print("SWITCHES C1 INTERP_TICKS=%.1f C2 EXTRAP_MAX_TICKS=%.1f C3 OWN_STATE_PRECISION=%s C4 SNAPSHOT_EVERY_TICKS=%d C5 BASELINE_RING=%d C9 VIS_LATERAL_MARGIN=%.1f C10 TRANSPORT=%s C11 CMD_BURST=%.1f (refill %.1f/tick, window %d) C12 SENT_MASK_HISTORY_TICKS=%d" % [
		NetConfig.INTERP_TICKS, NetConfig.EXTRAP_MAX_TICKS, NetConfig.OWN_STATE_PRECISION, NetConfig.SNAPSHOT_EVERY_TICKS, NetConfig.BASELINE_RING,
		NetConfig.VIS_LATERAL_MARGIN, NetConfig.TRANSPORT, NetConfig.CMD_BURST, NetConfig.CMD_REFILL, NetConfig.CMD_WINDOW, NetConfig.SENT_MASK_HISTORY_TICKS])
	_last_us = Time.get_ticks_usec()
	_started_us = _last_us
	if e != OK:
		print("SERVER_ERROR could not listen")
		get_tree().quit(2)
		_done = true


func _process(_delta: float) -> void:
	if _done:
		return
	var now := Time.get_ticks_usec()
	_acc += float(now - _last_us)
	_last_us = now
	if _acc > TICK_US * float(MAX_BACKLOG_TICKS):
		overruns += 1
		_acc = TICK_US                           # drop the backlog, run one tick
	var ran := false
	while _acc >= TICK_US:
		_acc -= TICK_US
		var t0 := Time.get_ticks_usec()
		_tick()
		tick_us.append(float(Time.get_ticks_usec() - t0))
		if tick_us.size() > STATS_EVERY_TICKS:
			tick_us = tick_us.slice(tick_us.size() - STATS_EVERY_TICKS)
		ran = true
		if _done:
			return
	if not ran:
		OS.delay_usec(300)


func _tick() -> void:
	# step 1: drain the transport into the per-client input queues
	for item in transport.poll():
		_on_datagram(item[0], item[1])
	for ev in transport.events:
		if ev[0] == "disconnect":
			_drop(ev[1], "disconnect")
	transport.events.clear()
	for id in peer_slot.keys():
		var sl: ClientSlot = server.slots[peer_slot[id]]
		if sl != null and server.tick - sl.last_heard > SILENT_TICKS:
			dropped_silent += 1
			_drop(id, "silent for 5 s")
	# steps 2 to 6 happen inside ServerTick.step(); it returns the snapshots to send
	var out := server.step()
	for slot_id in out:
		var id: int = slot_peer.get(slot_id, -1)
		if id >= 0:
			var pkt := Packet.encode_snapshot(out[slot_id])
			if Packet.may_send(pkt):
				transport.send_to(id, pkt)
	tick = server.tick
	if tick % 128 == 0:
		transport.prune()
	# step 7: stats
	if tick % STATS_EVERY_TICKS == 0:
		_print_stats()
	if max_seconds > 0.0 and float(Time.get_ticks_usec() - _started_us) / 1.0e6 >= max_seconds:
		print("SERVER_EXIT max-seconds reached")
		_finish(0)


func _on_datagram(id: int, raw: PackedByteArray) -> void:
	var m := Packet.parse(raw)
	if m.is_empty():
		server.evidence.input_reject(server.tick, -1, 0, EvidenceSink.REJECT_MALFORMED, {"bytes": raw.size()})
		return
	match m["msg"]:
		Packet.MSG_HELLO:
			if m["version"] != Packet.PROTOCOL_VERSION or m["tick_rate"] != 128:
				return
			if not peer_slot.has(id):
				var expect := _cookie(id)
				if m["cookie"] != expect:
					cookies_rejected += 1
					transport.send_to(id, Packet.encode_challenge(expect))      # 9 bytes, no state kept
					return
				transport.verify(id)
				var slot_id := server.free_slot()
				if slot_id < 0:
					return
				var cs := server.add_client(slot_id, 1 + humans_joined % 2)
				humans_joined += 1
				cs.last_heard = server.tick
				peer_slot[id] = slot_id
				slot_peer[slot_id] = id
				had_client = true
				print("SERVER client %d joined as slot %d (team %d)" % [id, slot_id, cs.team])
			var slot_id2: int = peer_slot[id]
			(server.slots[slot_id2] as ClientSlot).last_heard = server.tick
			transport.send_to(id, Packet.encode_welcome(slot_id2, server.tick, int(NetConfig.INTERP_TICKS), NetConfig.SNAPSHOT_EVERY_TICKS))
		Packet.MSG_INPUT:
			if not peer_slot.has(id):
				return
			var cs2: ClientSlot = server.slots[peer_slot[id]]
			# a forged or future ack is dropped and counted by SnapshotSender.on_ack (sent window only)
			if cs2.sender.next_seq > 1 and cs2.sender.ring.get_snap(m["ack_snap_seq"]) == null:
				acks_rejected += 1
			cs2.enqueue_net(m["cmds"], m["ack_snap_seq"], m["ack_delay_ticks"], server.tick, server.evidence)
		Packet.MSG_BYE:
			bye_count += 1
			_drop(id, "bye")


func _cookie(id: int) -> int:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(_secret)
	h.update(transport.peer_key(id).to_utf8_buffer())
	return h.finish().decode_u32(0)


func _drop(id: int, why: String) -> void:
	if peer_slot.has(id):
		var slot_id: int = peer_slot[id]
		print("SERVER client %d (slot %d) dropped: %s" % [id, slot_id, why])
		var chg: Array = []
		for c in (server.slots[slot_id] as ClientSlot).mask_changes:
			chg.append("%d:%d" % [c[0], c[1]])
		print("SERVER_MASKS slot=%d changes=%s" % [slot_id, ",".join(chg)])
		peer_slot.erase(id)
		slot_peer.erase(slot_id)
		server.remove_client(slot_id)
		transport.forget(id)
		if exit_on_bye and had_client and peer_slot.is_empty():
			print("SERVER_EXIT last client left (%s)" % why)
			_finish(0)


func _pct(a: PackedFloat64Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[mini(int(ceil(p * float(b.size()))) - 1, b.size() - 1)]


func _print_stats() -> void:
	var rx: int = transport.recv_bytes
	var tx: int = transport.sent_bytes
	var secs := float(STATS_EVERY_TICKS) / 128.0
	var lost := 0
	var rtt := -1.0
	for sl in server.slots:
		if sl != null:
			lost += (sl as ClientSlot).lost_seqs.size()
			rtt = maxf(rtt, (sl as ClientSlot).rtt_ticks * 1000.0 / 128.0)
	print("SERVER_STATS tick=%d clients=%d tick_us_median=%.0f tick_us_p99=%.0f overruns=%d rx_B_per_s=%.0f tx_B_per_s=%.0f cmds_fully_lost=%d rtt_ms=%.1f malformed=%d mem_MB=%.2f" % [
		tick, server.slot_count(), _pct(tick_us, 0.5), _pct(tick_us, 0.99), overruns, float(rx - _last_rx) / secs, float(tx - _last_tx) / secs, lost, rtt, Packet.malformed,
		float(OS.get_static_memory_usage()) / 1048576.0])
	_last_rx = rx
	_last_tx = tx


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	print("SERVER_FINAL ticks=%d overruns=%d overrun_pct=%.4f dropped_silent=%d byes=%d malformed=%d oversize_refused=%d acks_rejected=%d cookies_rejected=%d mem_MB=%.2f" % [
		tick, overruns, 100.0 * float(overruns) / maxf(float(tick), 1.0), dropped_silent, bye_count, Packet.malformed, Packet.oversize_refused, acks_rejected, cookies_rejected,
		float(OS.get_static_memory_usage()) / 1048576.0])
	transport.close()
	get_tree().quit(code)
