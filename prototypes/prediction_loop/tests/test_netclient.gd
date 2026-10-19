extends SceneTree
## NetClient API + crosshair wired in (Phase 4):  godot --headless --script res://tests/test_netclient.gd

var passed := 0
var failed := 0
const BF := InputCmd.BTN_FORWARD


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	_interface()
	_wire_match()
	_pixels()
	_newest_only()
	_standalone()
	_latency()
	_remotes_api()
	_remote_duck_and_rtt()
	_crosshair_untouched()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _session(ping: float, loss: float, jitter: bool, sd: int = 1) -> Session:
	return Session.new(sd, ping, loss, jitter, false, false)


func _interface() -> void:
	var nc := NetClient.new()
	var sig := {}
	for s in nc.get_signal_list():
		if s["name"] == "snapshot_received":
			sig = s
	_ok("signal snapshot_received exists with one Dictionary argument", not sig.is_empty() and sig["args"].size() == 1 and sig["args"][0]["type"] == TYPE_DICTIONARY)
	_ok("signal remote_removed(slot) exists", nc.has_signal("remote_removed"))
	_ok("get_latest() is {} before the first snapshot", nc.get_latest() == {})
	nc.free()
	var s := _session(80.0, 0.0, false)
	var nc2 := NetClient.new()
	nc2.adopt(s.client)
	var emitted: Array = []
	nc2.snapshot_received.connect(func(d): emitted.append(d))
	for t in 60:
		s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
	var l := nc2.get_latest()
	var keys_ok := l.size() == 5 and l.has("server_tick") and l.has("accuracy") and l.has("punch_pitch") and l.has("punch_yaw") and l.has("move_state")
	var types_ok: bool = keys_ok and typeof(l["server_tick"]) == TYPE_INT and typeof(l["accuracy"]) == TYPE_FLOAT and typeof(l["punch_pitch"]) == TYPE_FLOAT \
		and typeof(l["punch_yaw"]) == TYPE_FLOAT and typeof(l["move_state"]) == TYPE_INT
	_ok("get_latest() has exactly the 5 keys with the right types", keys_ok and types_ok, str(l))
	_ok("a snapshot was emitted for each newest snapshot (every 2nd tick)", emitted.size() > 20 and emitted.size() < 31, "%d emitted in 60 ticks" % emitted.size())
	nc2.free()


func _wire_match() -> void:
	var src = load("res://scripts/hud/fake_snapshot_source.gd")      # Game Builder's file, via symlink
	var rng := RandomNumberGenerator.new()
	rng.seed = 8484
	var bad := 0
	for i in 1000:
		var a := rng.randf_range(-0.5, 2.5)
		var d := rng.randf_range(-200.0, 200.0)
		if Quant.accuracy_to_q(a) != src.quantize_accuracy(a) or Quant.angle_to_q(d) != src.quantize_angle(d):
			bad += 1
		var qa: int = src.quantize_accuracy(a)
		var qd: int = src.quantize_angle(d)
		if Quant.q_to_accuracy(qa) != src.dequantize_accuracy(qa) or Quant.q_to_angle(qd) != src.dequantize_angle(qd):
			bad += 1
	_ok("wire match with the crosshair prototype: same integers and same dequantized floats on 1,000 random values", bad == 0, "%d differ" % bad)


func _drive(s: Session, nc: NetClient, buttons: int, ticks: int) -> void:
	for t in ticks:
		s.tick_once(buttons, 0, InputCmd.quantize_pitch(0.0))


func _pixels() -> void:
	var xh = load("res://scripts/hud/crosshair.gd")
	var cases: Array = []
	# stand
	var s := _session(80.0, 0.0, false)
	var nc := NetClient.new()
	nc.adopt(s.client)
	_drive(s, nc, 0, 80)
	cases.append(["stand", nc.get_latest(), 4.0, 0.05, Color(0.2, 1.0, 0.2, 1.0)])
	# crouch (a ducked player stands still)
	_drive(s, nc, InputCmd.BTN_DUCK, 90)
	cases.append(["crouch", nc.get_latest(), 4.0, 0.05, Color(0.2, 1.0, 0.2, 1.0)])
	# run
	var r := _session(80.0, 0.0, false)
	var nr := NetClient.new()
	nr.adopt(r.client)
	_drive(r, nr, BF, 120)
	cases.append(["run", nr.get_latest(), 38.9, 0.1, Color(1.0, 0.9, 0.1, 1.0)])
	# air
	var a := _session(80.0, 0.0, false)
	var na := NetClient.new()
	na.adopt(a.client)
	_drive(a, na, 0, 40)
	var seen_air := false
	a.tick_once(InputCmd.BTN_JUMP, 0, InputCmd.quantize_pitch(0.0))
	for t in 60:
		a.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		if na.get_latest().get("move_state", -1) == 2:
			seen_air = true
			cases.append(["air", na.get_latest(), 86.4, 0.1, Color(1.0, 0.2, 0.2, 1.0)])
			break
	_ok("air state reached the HUD", seen_air)
	for c in cases:
		var snap: Dictionary = c[1]
		var gap: float = xh.gap_px(snap["accuracy"], 1080.0, 73.74)
		var col: Color = xh.color_for_state(snap["move_state"])
		_ok("pixels at 1080p, %s: gap %.3f (want %.1f +-%.2f), color %s" % [c[0], gap, c[2], c[3], "ok" if col == c[4] else "WRONG"], absf(gap - c[2]) <= c[3] and col == c[4],
			"accuracy %.6f move_state %d" % [snap["accuracy"], snap["move_state"]])
	nc.free()
	nr.free()
	na.free()


func _newest_only() -> void:
	var st := PlayerState.new()
	var tx := SnapshotSender.new()
	var packets: Array = []
	for i in 12:
		packets.append(tx.build(i * 2, 0, st, SnapshotSender.stub_hud(st)))      # snap_seq 1..12, all full (no acks)
	var c := Client.new([])
	var nc := NetClient.new()
	nc.adopt(c)
	var ticks: Array = []
	nc.snapshot_received.connect(func(d): ticks.append(d["server_tick"]))
	c.reconcile([packets[9], packets[11], packets[10]])        # seq 10, 12, 11
	_ok("newest-only: snapshots arriving as seq 10, 12, 11 emit for 10 and 12 only", ticks == [18, 22], str(ticks))
	nc.free()


## One standalone NetClient (own Client + FakeEndpoint) against the fake server, same tick order as Session.
func _standalone() -> void:
	var seed_value := 33
	var net := FakeNet.new(seed_value, 80.0, 0.02, false)
	var server := FakeServer.new(Movement.default_world())
	var ep := FakeEndpoint.new(net)
	var nc := NetClient.new()
	nc.setup(Movement.default_world(), ep)
	var ref := _session(80.0, 0.02, false, seed_value)
	var emitted := [0]
	nc.snapshot_received.connect(func(_d): emitted[0] += 1)
	var rtt_ok := true
	for t in 3000:
		var now := float(t) * (1000.0 / Movement.TICK_RATE)
		var c2s := net.deliver(FakeNet.C2S, now)
		var s2c := net.deliver(FakeNet.S2C, now)
		for p in c2s:
			server.receive(p)
		var snap: Variant = server.step(t)
		if snap != null:
			net.send(FakeNet.S2C, snap, now)
		ep.now_ms = now
		ep.inbox.append_array(s2c)
		var i := Bots.input("mixed", t, nc.get_player_state())
		nc.send_input(InputCmd.make(0, t, i[0], i[1], i[2]))
		nc.poll_and_update(t)
		var j := Bots.input("mixed", t, ref.client.predicted)
		ref.tick_once(j[0], j[1], j[2])
	_ok("standalone NetClient (own Client + endpoint) gives the same final player state as the Session-driven client", nc.get_player_state().hex() == ref.client.predicted.hex() and nc.get_player_state().equals(ref.client.predicted))
	var st := nc.get_stats()
	_ok("get_stats(): rtt about 12-13 ticks (94-100 ms), snapshot loss near 2%, bytes/s near 64 x 126", st["rtt_ms"] > 85.0 and st["rtt_ms"] < 115.0 and st["snapshot_loss"] > -0.01 and st["snapshot_loss"] < 0.06 and st["bytes_per_s"] > 7000.0 and st["bytes_per_s"] < 9000.0,
		"rtt %.1f ms, loss %.3f, %.0f B/s, %d snapshots, %d corrections" % [st["rtt_ms"], st["snapshot_loss"], st["bytes_per_s"], st["snapshots"], st["corrections"]])
	_ok("standalone: one emit per newest snapshot", emitted[0] > 1400 and emitted[0] <= st["snapshots"], "%d emitted, %d snapshots decoded" % [emitted[0], st["snapshots"]])
	_ok("get_visual_position() follows the predicted position (no corrections needed)", absf(nc.get_visual_position()[0] - nc.get_player_state().pos_x) < 0.01 + 1.0e-6 * absf(nc.get_player_state().pos_x), "visual is a 32-bit Vector3, so compared to 0.01 units")
	nc.free()


func _histogram(ping: float, label: String, lo: int, hi: int) -> void:
	var counts := {}
	var worst_lo := 999
	var worst_hi := -1
	for trial in 40:
		var s := _session(ping, 0.0, false, 500 + trial)
		var nc := NetClient.new()
		nc.adopt(s.client)
		var start := 200 + trial               # different phases against the 2-tick snapshot cadence
		var t0 := -1
		var t1 := -1
		for t in start + 120:
			var b := BF if t >= start else 0
			s.tick_once(b, 0, InputCmd.quantize_pitch(0.0))
			if t0 < 0 and Movement.move_state_for_hud(s.client.predicted) == 3:
				t0 = t
			if t1 < 0 and nc.get_latest().get("move_state", 0) == 3:
				t1 = t
		var d := t1 - t0
		counts[d] = counts.get(d, 0) + 1
		worst_lo = mini(worst_lo, d)
		worst_hi = maxi(worst_hi, d)
		nc.free()
	var keys := counts.keys()
	keys.sort()
	var hist: Array = []
	for k in keys:
		hist.append("%d ticks x%d" % [k, counts[k]])
	_ok("latency stand -> run -> crosshair color, %s: %d to %d ticks (%.1f to %.1f ms), expected %d to %d" % [label, worst_lo, worst_hi, worst_lo * 7.8125, worst_hi * 7.8125, lo, hi], worst_lo >= lo and worst_hi <= hi, "histogram (40 start phases): " + ", ".join(hist))


func _latency() -> void:
	_histogram(80.0, "80 ms, jitter off", 12, 14)
	# The handout expected 0 to 2 ticks at 0 ms. With the fixed tick order (a packet sent in step 3 is delivered in
	# step 1 of the NEXT tick, each way) the floor is: command arrives +1, snapshot sent 0 or 1 tick later (even ticks
	# only), arrives +1 = 2 to 3 ticks. Recorded as a spec question; the check below is the measured, explained range.
	_histogram(0.0, "0 ms (handout guessed 0-2; tick-order floor is 2-3)", 2, 3)
	var s := _session(80.0, 0.0, false)
	var plain := _session(80.0, 0.0, false)
	var nc := NetClient.new()
	nc.adopt(s.client)
	for t in 1500:
		var i := Bots.input("mixed", t, s.client.predicted)
		s.tick_once(i[0], i[1], i[2])
		var j := Bots.input("mixed", t, plain.client.predicted)
		plain.tick_once(j[0], j[1], j[2])
	_ok("own movement unaffected: attaching NetClient leaves the predicted state bit-identical", s.client.predicted.hex() == plain.client.predicted.hex())
	nc.free()


func _remotes_api() -> void:
	var s := _session(80.0, 0.0, false)
	var r := RemotePath.make_straight(2, -1000.0, -1000.0, 0.7)
	r.despawn_tick = 500
	s.add_remote(r)
	var nc := NetClient.new()
	nc.adopt(s.client)
	var removed: Array = []
	nc.remote_removed.connect(func(slot): removed.append(slot))
	var present_at_300 := false
	var rt_ok := false
	for t in 560:
		s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		if t == 300:
			var rp := nc.get_remote_players()
			present_at_300 = rp.size() == 1 and rp[0]["slot"] == 2 and rp[0]["alive"] and rp[0]["stance"] == 0
			rt_ok = absf(nc.get_render_tick() - (300.0 - 10.0)) < 1.0e-9
	_ok("get_remote_players(): slot 2 present with stance and alive", present_at_300)
	_ok("get_render_tick() = tick - one-way 6 - interp 4 = 290", rt_ok)
	_ok("remote_removed(slot) fires when the slot disappears; the list is then empty", removed == [2] and nc.get_remote_players().is_empty(), str(removed))
	nc.free()


func _remote_duck_and_rtt() -> void:
	# get_remote_players() carries the smooth duck fraction, equal to the interpolation buffer's out_duck
	var s := _session(80.0, 0.0, false)
	s.add_remote(RemotePath.make_stepped(3, RemotePath.Kind.CROUCH_TOGGLE, 2000.0, 600.0))
	var nc := NetClient.new()
	nc.adopt(s.client)
	var has_key := true
	var matches := true
	var mid := 0
	var top := 0.0
	var mono_step := 0.0
	var last := -1.0
	for t in 700:
		s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		for rp in nc.get_remote_players():
			has_key = has_key and rp.has("duck")
			matches = matches and absf(rp["duck"] - (s.client.remotes[rp["slot"]] as InterpBuffer).out_duck) < 1.0e-12
			top = maxf(top, rp["duck"])
			if rp["duck"] > 0.1 and rp["duck"] < 0.9:
				mid += 1
			if last >= 0.0 and rp["duck"] > last:
				mono_step = maxf(mono_step, rp["duck"] - last)
			last = rp["duck"]
	_ok("get_remote_players() has \"duck\" (the smooth 0.0..1.0 fraction): equals out_duck, reaches 1.0, passes through in-between values, rises by < 0.06 per tick", has_key and matches and top > 0.99 and mid > 20 and mono_step < 0.06, "%d in-between draws, max rise %.3f" % [mid, mono_step])
	nc.free()
	# RTT: one sample per command; an ack older than 255 commands is ignored
	var a := _session(80.0, 0.0, false)
	for t in 600:
		a.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
	var c := a.client
	var rtt0 := c.rtt_ticks
	var snap := Snapshot.new()
	snap.snap_seq = (c.receiver.newest_seq + 1) & 0xFFFF
	snap.server_tick = 99999
	snap.ack_cmd_seq = maxi(c.ring.newest - 300, 1)
	c.reconcile([snap.encode()])
	_ok("an ack more than 255 commands old does not touch the RTT estimate", c.rtt_ticks == rtt0, "%.4f -> %.4f" % [rtt0, c.rtt_ticks])
	var acked := c._rtt_acked_seq
	var snap2 := Snapshot.new()
	snap2.snap_seq = (c.receiver.newest_seq + 1) & 0xFFFF
	snap2.server_tick = 100000
	snap2.ack_cmd_seq = acked
	c.reconcile([snap2.encode()])
	_ok("a repeated ack of the same command gives no second RTT sample", c.rtt_ticks == rtt0 and c._rtt_acked_seq == acked)


func _crosshair_untouched() -> void:
	var here := ProjectSettings.globalize_path("res://").path_join("../crosshair").simplify_path()
	var bad := 0
	var n := 0
	var f := FileAccess.open("res://tests/golden/crosshair_files.sha256", FileAccess.READ)
	for line in f.get_as_text().strip_edges().split("\n"):
		var parts := line.split("  ")
		n += 1
		if FileAccess.get_sha256(here.path_join(parts[1])) != parts[0]:
			bad += 1
	_ok("crosshair files are exactly the ones brought in from gamebuilder/crosshair (%d files, sha256)" % n, bad == 0, "%d differ" % bad)
	var repo := ProjectSettings.globalize_path("res://").path_join("../..").simplify_path()
	var out: Array = []
	var code := OS.execute("git", ["-C", repo, "diff", "--exit-code", "origin/gamebuilder/crosshair", "--", "prototypes/crosshair"], out, true)
	if code == 0:
		_ok("git diff --exit-code origin/gamebuilder/crosshair -- prototypes/crosshair prints nothing", true)
	else:
		print("SKIP  git diff against origin/gamebuilder/crosshair (git exit %d: ref not available here); the sha256 check above is the check" % code)
	var godot := OS.get_executable_path()
	var cdir := here
	OS.execute(godot, ["--headless", "--path", cdir, "--import"], [], true)
	var out2: Array = []
	var code2 := OS.execute(godot, ["--headless", "--path", cdir, "--script", "res://tests/test_crosshair.gd"], out2, true)
	var text := "".join(out2)
	var last := text.strip_edges().split("\n")[-1]
	_ok("the crosshair's own test still passes from this branch", code2 == 0 and ("27 passed" in text), "exit %d: %s" % [code2, last])
