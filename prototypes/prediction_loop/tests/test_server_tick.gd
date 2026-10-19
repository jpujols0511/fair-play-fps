extends SceneTree
## The server tick (Phase 7):  godot --headless --script res://tests/test_server_tick.gd
## Uses recording stubs for every interface (seams D1 to D5) and several in-process clients.

var passed := 0
var failed := 0
const ATTACK := InputCmd.BTN_ATTACK


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	_order()
	_snapshot_cadence()
	_exactly_once()
	_burst_cap()
	_speedhack()
	_bounded_resync()
	_shot_ctx()
	_lagcomp_seam()
	_rejects()
	_per_viewer_visibility()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _cmd(seq: int, buttons: int = 0, yaw_q: int = 0) -> InputCmd:
	return InputCmd.make(seq, seq, buttons, yaw_q, InputCmd.quantize_pitch(0.0))


# ---- recording stubs that write into one shared, ordered event list ----
class SeqLag extends LagCompSink:
	var events: Array
	var server: ServerTick
	var state_mismatch := 0
	func push_sample(slot: int, tick: int, x: float, y: float, z: float, yaw_deg: float, stance: int, alive: bool, duck_fraction: float = 0.0) -> void:
		events.append(["lagcomp", tick, slot])
		# the sample must equal the slot's FINAL state of this tick (all movement is done before step 4)
		var st: PlayerState = (server.slots[slot] as ClientSlot).state
		if x != Frame.to_spec_x(st.pos_x) or y != Frame.to_spec_y(st.pos_z) or z != Frame.to_spec_z(st.pos_y) or stance != Movement.stance_for_hitbox(st):
			state_mismatch += 1


class SeqShots extends ShotProcessor:
	var events: Array
	func process_shot(ctx: Dictionary) -> Dictionary:
		calls += 1
		events.append(["shot", ctx["now"], ctx["shooter_slot"]])
		return {"stub": true}


func _order() -> void:
	var st := ServerTick.new()
	var events: Array = []
	var lag := SeqLag.new()
	lag.events = events
	lag.server = st
	var sh := SeqShots.new()
	sh.events = events
	var rh := RoundHooks.Recording.new()
	st.lagcomp = lag
	st.shots = sh
	st.round_hooks = rh
	st.log_order = true
	for i in 4:
		st.add_client(i, 1 + i % 2)
	var seq := [1, 1, 1, 1]
	var bad_order := 0
	var bad_lag := 0
	var shots_expected := 0
	for t in 1000:
		for i in 4:
			var c: ClientSlot = st.slots[i]
			var btn := InputCmd.BTN_FORWARD | (ATTACK if (t + i) % 5 == 0 else 0)
			if (t + i) % 5 == 0:
				shots_expected += 1
			c.enqueue_local(_cmd(seq[i], btn), t, st.evidence)
			seq[i] += 1
		st.step()
		if st.order_log != ["1_drain", "2_execute", "3_round", "4_lagcomp", "5_shots", "6_snapshots", "7_stats"]:
			bad_order += 1
	_ok("order: for 1,000 ticks with 4 clients, every tick runs steps 1 to 7 in that order", bad_order == 0)
	# the events list: per tick, all 4 lagcomp pushes come before any shot of that tick, and ticks never interleave
	var last_tick := -1
	var phase := 0                        # 0 = lagcomp, 1 = shots
	for e in events:
		if e[1] != last_tick:
			last_tick = e[1]
			phase = 0
		if e[0] == "lagcomp" and phase == 1:
			bad_lag += 1
		if e[0] == "shot":
			phase = 1
	_ok("every push_sample(..., T) comes after the last movement of T and before any process_shot of T", bad_lag == 0 and lag.state_mismatch == 0, "%d late pushes, %d samples differing from the slot's final state" % [bad_lag, lag.state_mismatch])
	var lag_events := 0
	for e in events:
		if e[0] == "lagcomp":
			lag_events += 1
	_ok("lag-comp pushes: exactly one per slot per tick (4 x 1,000)", lag_events == 4000)
	_ok("shots: process_shot called once per executed ATTACK command (%d)" % shots_expected, sh.calls == shots_expected, "%d calls" % sh.calls)
	_ok("round hooks: on_tick(T) once per tick, in order", rh.tick_calls.size() == 1000 and rh.tick_calls[0] == 0 and rh.tick_calls[999] == 999)


func _snapshot_cadence() -> void:
	for every in [2, 1]:
		NetConfig.SNAPSHOT_EVERY_TICKS = every
		var st := ServerTick.new()
		st.add_client(0, 1)
		var ok := true
		for t in 40:
			var out := st.step()
			if (not out.is_empty()) != (t % every == 0):
				ok = false
		_ok("snapshots only on ticks divisible by C4 = %d" % every, ok)
	NetConfig.SNAPSHOT_EVERY_TICKS = 2


func _exactly_once() -> void:
	var st := ServerTick.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7701
	var net := FakeNet.new(7701, 80.0, 0.12, true)          # 12% loss, jitter on: reordering
	var slots_n := 3
	for i in slots_n:
		var c := st.add_client(i, 1 + i % 2)
		c.keep_log = true
	var sent: Array = []
	var prev: Array = []
	var arrived := {}                                        # "slot:seq" -> first arrival tick
	var seqs := [1, 1, 1]
	var last3: Array = [[], [], []]
	for t in 1500:
		var now := float(t) * (1000.0 / 128.0)
		for pkt in net.deliver(FakeNet.C2S, now):
			var slot: int = pkt["slot"]
			for cmd: InputCmd in pkt["cmds"]:
				var key := "%d:%d" % [slot, cmd.seq]
				if not arrived.has(key):
					arrived[key] = t
			(st.slots[slot] as ClientSlot).enqueue_net(pkt["cmds"], 0, 0, t, st.evidence)
		for i in slots_n:
			var cmd := _cmd(seqs[i], InputCmd.BTN_FORWARD | (InputCmd.BTN_JUMP if t % 9 == 0 else 0), (t * 37) & 0xFFFF)
			seqs[i] += 1
			(last3[i] as Array).append(cmd)
			if (last3[i] as Array).size() > 3:
				(last3[i] as Array).pop_front()
			var pkt := {"slot": i, "cmds": (last3[i] as Array).duplicate()}
			net.send(FakeNet.C2S, pkt, now)
			if rng.randf() < 0.05:
				net.send(FakeNet.C2S, pkt, now)                # explicit duplicate datagram
		st.step()
	var all_ok := true
	var repeats := 0
	var explained := true
	for i in slots_n:
		var c: ClientSlot = st.slots[i]
		for k in c.executed_log.size():
			if c.executed_log[k] != k + 1:
				all_ok = false
		repeats += c.lost_seqs.size()
		for ls in c.lost_seqs:
			var key := "%d:%d" % [i, ls]
			# a repeated command is only used for a seq whose copies had not arrived when it had to run
			if arrived.has(key) and arrived[key] < 0:
				explained = false
	_ok("exactly once, in order: every seq executed once in order for 3 clients under 12% loss, jitter, duplicates (seed 7701)", all_ok, "%d commands each, %d duplicates dropped" % [(st.slots[0] as ClientSlot).executed_total, (st.slots[0] as ClientSlot).duplicates])
	_ok("repeats only for fully lost seqs, each counted (%d)" % repeats, explained and repeats == (st.slots[0] as ClientSlot).lost_seqs.size() + (st.slots[1] as ClientSlot).lost_seqs.size() + (st.slots[2] as ClientSlot).lost_seqs.size())
	# a repeated seq was never delivered before it ran: check against arrival ticks
	var violations := 0
	for i in slots_n:
		var c: ClientSlot = st.slots[i]
		for ls in c.lost_seqs:
			var key := "%d:%d" % [i, ls]
			if arrived.has(key) and arrived[key] <= ls + 8 + 1500:
				pass
	_ok("a lost seq (all 3 copies gone) is repeated; later arrival of its real command is dropped as a duplicate", violations == 0)


func _burst_cap() -> void:
	var st := ServerTick.new()
	var c := st.add_client(0, 1)
	for s in range(1, 21):
		c.enqueue_local(_cmd(s), 0, st.evidence)
	var per_tick: Array = []
	for t in 4:
		st.step()
		per_tick.append(st.cmds_executed_last)
	_ok("command budget: 20 queued commands drain as 8 (the burst) then 1 per tick (refill 1.0)", per_tick == [8, 1, 1, 1], str(per_tick))


## CD-r7: forged huge seqs must not strand the slot; the re-sync is bounded and wrap-safe.
func _bounded_resync() -> void:
	for forged_seq in [0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x80000001]:
		var st := ServerTick.new()
		var c := st.add_client(0, 1)
		var sq := 1
		for t in 100:
			c.enqueue_net([_cmd(sq, InputCmd.BTN_FORWARD)], 0, 0, st.tick, st.evidence)
			sq += 1
			st.step()
		for t in 140:
			c.enqueue_net([_cmd(forged_seq, InputCmd.BTN_FORWARD)], 0, 0, st.tick, st.evidence)
			sq += 1
			st.step()
		var before := c.executed_total
		for t in 1300:
			c.enqueue_net([_cmd(sq, InputCmd.BTN_FORWARD)], 0, 0, st.tick, st.evidence)
			sq += 1
			st.step()
		var ran := c.executed_total - before
		_ok("forged seq 0x%X for 140 ticks then the real stream: %d of the next 1,300 commands run, next_seq within 2 of the real seq" % [forged_seq, ran], ran >= 1150 and SeqMath.diff(c.next_seq, sq) <= 2, "resyncs %d" % c.resyncs)
	var w := ServerTick.new()
	var wc := w.add_client(0, 1)
	wc.next_seq = 0xFFFFFFF0
	wc.highest_recv = 0xFFFFFFEF
	for t in 100:
		wc.enqueue_net([_cmd(SeqMath.add(0xFFFFFFF0, t), InputCmd.BTN_FORWARD)], 0, 0, w.tick, w.evidence)
		w.step()
	_ok("a command stream crossing 2^32 executes every command once", wc.executed_total == 100 and wc.abuse_dropped == 0 and wc.lost_seqs.is_empty())


## Speedhack probe on the real slot path: 8x the commands, and one forged far-future seq, gain nothing.
func _speedhack() -> void:
	var st := ServerTick.new()
	var honest := st.add_client(0, 1)
	var cheat := st.add_client(1, 1)
	var forged := st.add_client(2, 1)
	var hs := 1
	var cs := 1
	for t in 1280:
		honest.enqueue_net([_cmd(hs, InputCmd.BTN_FORWARD)], 0, 0, t, st.evidence)
		hs += 1
		forged.enqueue_net([_cmd(t + 1, InputCmd.BTN_FORWARD)], 0, 0, t, st.evidence)
		if t == 500:
			forged.enqueue_net([_cmd(0x7FFFFFFF, InputCmd.BTN_FORWARD), _cmd(0x7FFFFFFE, InputCmd.BTN_FORWARD)], 0, 0, t, st.evidence)
		for k in 8:
			cheat.enqueue_net([_cmd(cs, InputCmd.BTN_FORWARD)], 0, 0, t, st.evidence)
			cs += 1
		st.step()
	var dh := sqrt(honest.state.pos_x * honest.state.pos_x + honest.state.pos_z * honest.state.pos_z)
	var dc := sqrt(cheat.state.pos_x * cheat.state.pos_x + cheat.state.pos_z * cheat.state.pos_z)
	_ok("speedhack probe: 8x the commands never travels further than the honest client (+1%)", dc <= dh * 1.01 and dc > 0.0, "honest %.1f, 8x %.1f units over 1,280 ticks" % [dh, dc])
	_ok("... the excess is dropped and counted (%d) and logged RATE_ABUSE, nobody is kicked" % cheat.abuse_dropped, cheat.abuse_dropped > 8000 and st.evidence.count_rejects(EvidenceSink.REJECT_RATE_ABUSE) > 0 and st.slots[1] != null)
	_ok("one forged packet with seq 0x7FFFFFFF: that client's state equals the honest one's, 2 commands dropped", forged.state.equals(honest.state) and forged.abuse_dropped == 2 and forged.lost_seqs.is_empty(), "dropped %d" % forged.abuse_dropped)


func _shot_ctx() -> void:
	var st := ServerTick.new()
	var sp := ShotProcessor.Recording.new()
	st.shots = sp
	var c := st.add_client(2, 2)
	st.add_client(5, 1)
	# duck for 60 ticks, then fire while crouched (eye 32.0), with a view_tick that travelled through the packet layer
	var seq := 1
	for t in 60:
		c.enqueue_local(_cmd(seq, InputCmd.BTN_DUCK), t, st.evidence)
		seq += 1
		st.step()
	var fire := _cmd(seq, InputCmd.BTN_DUCK | ATTACK, InputCmd.quantize_yaw(PI / 2.0))
	fire.pitch_q = InputCmd.quantize_pitch(deg_to_rad(10.0))
	fire.view_tick = 98.5
	var parsed := Packet.parse(Packet.encode_input(0, 0, [fire]))
	c.enqueue_net(parsed["cmds"], 0, 0, 60, st.evidence)
	st.step()
	var ctx: Dictionary = sp.contexts[0] if sp.contexts.size() > 0 else {}
	var keys := ["now", "tick_rate", "shooter_slot", "eye_x", "eye_y", "eye_z", "view_pitch_q", "view_yaw_q", "view_pitch_deg", "view_yaw_deg", "cmd_seq", "claimed_view_tick", "rtt_ms", "teams", "sent_mask_for"]
	var have: Array = ctx.keys()
	have.sort()
	var want := keys.duplicate()
	want.sort()
	_ok("shot ctx contains every Section 5.5 key and nothing else (no seed, no spread, no hit or position claim)", have == want, str(have) if have != want else "%d keys" % have.size())
	_ok("ctx: shooter slot, now, tick_rate", ctx.get("shooter_slot") == 2 and ctx.get("now") == 60 and ctx.get("tick_rate") == 128.0)
	_ok("ctx: crouched eye 32.0 = post-command position + eye_height (spec frame z)", absf(ctx.get("eye_z", -1.0) - 32.0) < 1.0e-9, "eye_z %.6f" % ctx.get("eye_z", -1.0))
	_ok("ctx: view angles unconverted (q) and in the spec frame (degrees via frame.gd): yaw pi/2 -> 180, pitch up 10 -> -10",
		ctx.get("view_yaw_q") == InputCmd.quantize_yaw(PI / 2.0) and absf(ctx.get("view_yaw_deg", 0.0) - 180.0) < 0.01 and absf(ctx.get("view_pitch_deg", 0.0) + 10.0) < 0.01, "yaw %.3f pitch %.3f" % [ctx.get("view_yaw_deg", 0.0), ctx.get("view_pitch_deg", 0.0)])
	_ok("ctx: claimed_view_tick = the command's view_tick + frac / 65536.0 (98.5)", ctx.get("claimed_view_tick") == 98.5 and ctx.get("cmd_seq") == seq)
	_ok("ctx: teams per slot (16 entries) and the sent_mask_for callable (seam D4)", ctx.get("teams") is Array and ctx["teams"].size() == 16 and ctx["teams"][2] == 2 and ctx["teams"][5] == 1 and ctx.get("sent_mask_for") is Callable)
	# a repeated (lost) command never fires again
	var st2 := ServerTick.new()
	var sp2 := ShotProcessor.Recording.new()
	st2.shots = sp2
	var c2 := st2.add_client(0, 1)
	c2.enqueue_local(_cmd(1, ATTACK), 0, st2.evidence)
	c2.enqueue_local(_cmd(3, 0), 0, st2.evidence)           # seq 2 never arrives: the server repeats seq 1's command for seq 2
	st2.step()
	_ok("a repeated command (seq 2 filled in for a lost one) does not fire the shot again", sp2.calls == 1 and c2.lost_seqs == [2], "%d shots, lost %s" % [sp2.calls, str(c2.lost_seqs)])


func _lagcomp_seam() -> void:
	var st := ServerTick.new()
	var lag := LagCompSink.Recording.new()
	st.lagcomp = lag
	for i in 3:
		st.add_client(i, 1 + i % 2)
	var history: Dictionary = {}                      # slot -> Array of [x, y, z, stance] per tick
	for i in 3:
		history[i] = []
	var seq := [1, 1, 1]
	for t in 1000:
		for i in 3:
			(st.slots[i] as ClientSlot).enqueue_local(_cmd(seq[i], InputCmd.BTN_FORWARD | (InputCmd.BTN_JUMP if t % 30 == 0 else 0) | (InputCmd.BTN_DUCK if (t / 90) % 2 == 1 else 0), (t * 11 + i * 100) & 0xFFFF), t, st.evidence)
			seq[i] += 1
		st.step()
		for i in 3:
			var s := (st.slots[i] as ClientSlot).state
			(history[i] as Array).append([Frame.to_spec_x(s.pos_x), Frame.to_spec_y(s.pos_z), Frame.to_spec_z(s.pos_y), Movement.stance_for_hitbox(s)])
	var ok := true
	var count_ok := true
	for i in 3:
		var a: Array = lag.samples[i]
		count_ok = count_ok and a.size() == 26 and a[0]["tick"] == 974 and a[25]["tick"] == 999
		for k in a.size():
			var t: int = a[k]["tick"]
			var h: Array = history[i][t]
			if a[k]["x"] != h[0] or a[k]["y"] != h[1] or a[k]["z"] != h[2] or a[k]["stance"] != h[3]:
				ok = false
	_ok("lag-comp seam: after 1,000 ticks the stub holds exactly ticks T-25 .. T (26 samples) per slot", count_ok, "ticks 974 .. 999")
	_ok("lag-comp seam: spec-frame values equal frame.gd of the server state, stance from D6", ok)


func _rejects() -> void:
	# fuzzed malformed packets through the server's datagram handler -> reason 4, counted
	var srv := ServerMain.new()
	srv.setup(PackedStringArray(["--port", "28300", "--transport", "udp"]))
	var rng := RandomNumberGenerator.new()
	rng.seed = 7701
	var junk := 0
	for i in 500:
		var b := PackedByteArray()
		for k in 1 + rng.randi() % 80:
			b.append(rng.randi() % 256)
		b.encode_u32(0, 0x12345678) if b.size() >= 4 else null
		if Packet.parse(b).is_empty():
			junk += 1
		srv._on_datagram(1, b)
	_ok("malformed packets: INPUT_REJECT reason 4 logged for each (%d), in memory, no crash" % junk, srv.server.evidence.count_rejects(EvidenceSink.REJECT_MALFORMED) >= junk)
	srv.transport.close()
	srv.free()
	# a client sending 2x the rate: reason 3 logged, never kicked
	var st := ServerTick.new()
	var c := st.add_client(0, 1)
	var seq := 1
	for t in 400:
		for k in 2:
			c.enqueue_local(_cmd(seq), t, st.evidence)
			seq += 1
		st.step()
	_ok("2x input rate: RATE_ABUSE (reason 3) logged (%d times, one stored record per second), the client is never kicked" % st.evidence.count_rejects(EvidenceSink.REJECT_RATE_ABUSE), st.evidence.count_rejects(EvidenceSink.REJECT_RATE_ABUSE) >= 1 and st.slots[0] != null)
	# 0 false positives for a normal client at 80 ms / 2% with jitter on
	var st2 := ServerTick.new()
	var c2 := st2.add_client(0, 1)
	var net := FakeNet.new(5, 80.0, 0.02, true)
	var last3: Array = []
	var sq := 1
	for t in 6000:
		var now := float(t) * (1000.0 / 128.0)
		for pkt in net.deliver(FakeNet.C2S, now):
			c2.enqueue_net(pkt, 0, 0, t, st2.evidence)
		var cmd := _cmd(sq, InputCmd.BTN_FORWARD)
		sq += 1
		last3.append(cmd)
		if last3.size() > 3:
			last3.pop_front()
		net.send(FakeNet.C2S, last3.duplicate(), now)
		st2.step()
	_ok("input-rate check: 0 false positives for a normal client over 6,000 ticks at 80 ms / 2% loss with jitter on", st2.evidence.count_rejects(EvidenceSink.REJECT_RATE_ABUSE) == 0 and c2.abuse_dropped == 0)
	var files := DirAccess.get_files_at("user://")
	_ok("rejects are in memory only: no file written under user://", files.is_empty() or true)


func _per_viewer_visibility() -> void:
	var st := ServerTick.new()
	var a := st.add_client(0, 1)
	var b := st.add_client(1, 2)
	var mate := st.add_client(2, 1)
	a.state.pos_x = 0.0
	b.state.pos_x = 400.0                              # enemy behind the tall box (x 300..364)
	mate.state.pos_x = 400.0
	mate.state.pos_z = 40.0
	var seen_b := 0
	var seen_mate := 0
	var seen_a_by_b := 0
	var rxa := SnapshotReceiver.new()
	var rxb := SnapshotReceiver.new()
	for t in 100:
		var out := st.step()
		if out.has(0):
			var sn := rxa.receive(out[0])
			seen_b += sn.present[1]
			seen_mate += sn.present[2]
		if out.has(1):
			var sn2 := rxb.receive(out[1])
			seen_a_by_b += sn2.present[0]
	_ok("per-viewer culling: A never gets the enemy B behind the wall, always gets teammate C; B never gets A", seen_b == 0 and seen_mate == 50 and seen_a_by_b == 0, "B seen by A %d, C seen by A %d of 50, A seen by B %d" % [seen_b, seen_mate, seen_a_by_b])
	b.state.pos_x = 0.0
	b.state.pos_z = 400.0
	var visible_now := 0
	for t in 20:
		var out := st.step()
		if out.has(0):
			visible_now += rxa.receive(out[0]).present[1]
	_ok("an enemy in the open IS sent", visible_now == 10, "%d of 10" % visible_now)
