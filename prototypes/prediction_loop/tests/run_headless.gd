extends SceneTree
## Headless gate runner for the prediction loop (S1-S9 from specs/prediction_loop_scope.md).
##   godot --headless --import                              (once)
##   godot --headless --script res://tests/run_headless.gd  (all gates)
##   godot --headless --script res://tests/run_headless.gd -- --quick   (shorter runs, for development)
## Everything is seeded, so every run prints the same numbers (S8 timings aside).

var quick := false
var remotes := 0              # --remotes N: every session also hosts N scripted remote players (Phase 3 regression)
var gate_results := {}
var ALL_BOTS: Array = Bots.KINDS + Bots.EXTRA + ["mixed"]
const SEEDS := [11, 22, 33]


func _init() -> void:
	var uargs := OS.get_cmdline_user_args()
	quick = "--quick" in uargs
	if "--remotes" in uargs:
		remotes = int(uargs[uargs.find("--remotes") + 1])
	print("Godot ", Engine.get_version_info()["string"], "  (QUICK mode)" if quick else "", "  with %d remote players" % remotes if remotes > 0 else "")
	_s1(); _s2(); _s3(); _s4(); _s5(); _s6(); _s7(); _s8(); _s9()
	print("\n==================== SUMMARY ====================")
	var bad := 0
	for g in gate_results:
		print("%s  %s" % ["PASS" if gate_results[g] else "FAIL", g])
		if not gate_results[g]:
			bad += 1
	print("%d of %d gates passed" % [gate_results.size() - bad, gate_results.size()])
	quit(1 if bad > 0 else 0)


# ---------------------------------------------------------------- helpers

func _mk(seed_value: int, ping: float, loss: float, jitter: bool, oracle: bool = false, csv: bool = false) -> Session:
	var s := Session.new(seed_value, ping, loss, jitter, oracle, csv)
	for r in RemotePath.make_set(remotes):
		s.add_remote(r)
	return s


func _ticks(full: int) -> int:
	return maxi(full / 10, 1000) if quick else full


func _gate(name: String, ok: bool, detail: String) -> void:
	gate_results[name] = ok
	print("GATE %s %s  %s" % [name, "PASS" if ok else "FAIL", detail])


func _run(kind: String, seed_value: int, ticks: int, ping: float, loss: float, jitter: bool, oracle: bool, csv: bool = false) -> Session:
	var s := _mk(seed_value, ping, loss, jitter, oracle, csv)
	for t in ticks:
		var i := Bots.input(kind, t, s.client.predicted)
		s.tick_once(i[0], i[1], i[2])
	return s


func _pct(arr: PackedFloat64Array, p: float) -> float:
	if arr.is_empty():
		return 0.0
	var a := arr.duplicate()
	a.sort()
	return a[mini(int(ceil(p * float(a.size()))) - 1, a.size() - 1)]


## Runs every bot x seed and folds the numbers together.
func _sweep(ticks: int, ping: float, loss: float, jitter: bool) -> Dictionary:
	var agg := {"ticks": 0, "mismatch_seqs": 0, "unexplained": 0, "explained": 0, "lost": 0, "executed": 0,
		"overflows": 0, "corr": 0, "matches": 0, "max_vis": 0.0, "max_flips": 0, "max_replay": 0,
		"seq_errors": PackedFloat64Array(), "rec_errors": PackedFloat64Array(), "max_rec_err": 0.0, "snaps_big": 0,
		"snap_n": 0, "snap_bytes": 0, "snap_min": 1 << 30, "snap_max": 0, "snap_full": 0, "snap_dropped": 0}
	for bi in ALL_BOTS.size():
		var kind: String = ALL_BOTS[bi]
		for sd in SEEDS:
			# every bot gets its own network seed, so the 21 runs have independent drop streams
			var s := _run(kind, sd + 1000 * bi, ticks, ping, loss, jitter, true)
			agg["ticks"] += ticks
			agg["mismatch_seqs"] += s.seq_mismatches
			agg["unexplained"] += s.unexplained_corrections
			agg["explained"] += s.explained_corrections
			agg["lost"] += s.server.lost_seqs.size()
			agg["executed"] += s.server.executed_total
			agg["overflows"] += s.client.ring.overflows
			var snd := s.server.sender
			agg["snap_n"] += snd.snapshots
			agg["snap_bytes"] += snd.bytes_total
			agg["snap_min"] = mini(agg["snap_min"], snd.bytes_min)
			agg["snap_max"] = maxi(agg["snap_max"], snd.bytes_max)
			agg["snap_full"] += snd.full_sent
			agg["snap_dropped"] += s.client.receiver.dropped_missing_baseline
			agg["corr"] += s.client.corrections
			agg["matches"] += s.client.matches
			agg["max_vis"] = maxf(agg["max_vis"], s.max_unexplained_visual)
			agg["max_flips"] = maxi(agg["max_flips"], s.client.max_flips)
			for r in s.replay_lens:
				agg["max_replay"] = maxi(agg["max_replay"], r)
			agg["seq_errors"].append_array(s.seq_errors)
			agg["rec_errors"].append_array(s.reconcile_errors)
			for e in s.reconcile_errors:
				agg["max_rec_err"] = maxf(agg["max_rec_err"], e)
				if e > Client.SNAP_DISTANCE:
					agg["snaps_big"] += 1
	return agg


# ---------------------------------------------------------------- S1

func _s1() -> void:
	print("\n== S1 Determinism: client == server bit for bit, 10,000 ticks, 0 ms, no loss ==")
	var all_ok := true
	var total := 0
	for kind in ALL_BOTS:
		var s := _run(kind, 1, _ticks(10000), 0.0, 0.0, false, true, true)
		var executed := s.server.executed_total
		var ok := s.seq_mismatches == 0 and s.client.corrections == 0 and s.server.lost_seqs.is_empty() and executed >= s.tick - 1
		# the server's state after seq N equals the client's stored state for N
		var last := s.server.next_seq - 1
		ok = ok and s.server.state.equals(PlayerState.from_packed(s.client.first_pred[last]))
		total += executed
		print("  %-7s executed %5d cmds, mismatching seqs %d, corrections %d, server==client at seq %d: %s" % [kind, executed, s.seq_mismatches, s.client.corrections, last, str(ok)])
		all_ok = all_ok and ok
	# same seed -> same CSV, twice (with the real 80 ms / 2% network, jitter on)
	var a := _run("mixed", 7, _ticks(10000), 80.0, 0.02, true, false, true)
	var b := _run("mixed", 7, _ticks(10000), 80.0, 0.02, true, false, true)
	var c := _run("mixed", 8, _ticks(10000), 80.0, 0.02, true, false, true)
	var same := a.csv_sha256() == b.csv_sha256() and a.final_hex() == b.final_hex()
	var diff := a.csv_sha256() != c.csv_sha256()
	print("  CSV twice, same seed: %s (sha256 %s...)   different seed differs: %s" % [str(same), a.csv_sha256().substr(0, 16), str(diff)])
	_gate("S1 determinism", all_ok and same and diff, "%d commands compared, 0 differences expected" % total)


# ---------------------------------------------------------------- S2

func _s2() -> void:
	print("\n== S2 Parity with the Python sim (tolerance 0.01) ==")
	var movement_dir := ProjectSettings.globalize_path("res://").path_join("../../movement_proto").simplify_path()
	var same_file := FileAccess.get_md5("res://scripts/movement.gd") == FileAccess.get_md5(movement_dir.path_join("movement.gd"))
	print("  one movement.gd (prototype == movement_proto): ", same_file)

	# direct numbers from the shared Movement
	var dt := 1.0 / 128.0
	var a := 10.0 * 250.0 * dt
	var dd := maxf(Movement.AIR_CAP - a, 0.0)
	var w := Vector2(dd / 250.0, sqrt(1.0 - (dd / 250.0) * (dd / 250.0)))
	var d := Movement.air_accel(w, 250.0 * w.x, 250.0, 10.0, dt)
	var gain_sec := (Vector2(250.0 + d.x, d.y).length() - 250.0) * 128.0
	var v := 250.0
	var timer := 0.0
	for hop in 20:
		v = Movement.bhop_cap_speed(v, 250.0)
		var vz := Movement.jump(timer)
		timer = Movement.STAMINA_MS
		var z := 0.0
		while true:
			vz = Movement.gravity_half(vz, dt)
			z += vz * dt
			vz = Movement.gravity_half(vz, dt)
			var dd2 := maxf(Movement.AIR_CAP - a, 0.0)
			var w2 := Vector2(dd2 / v, sqrt(1.0 - (dd2 / v) * (dd2 / v)))
			var d2 := Movement.air_accel(w2, v * w2.x, 250.0, 10.0, dt)
			v = Vector2(v + d2.x, d2.y).length()
			timer = Movement.stamina_tick(timer, dt)
			if z <= 0.0:
				break
	print("  strafe gain @250, 128 tick: %.4f u/s per second (want 201.71)   top bhop @128 tick: %.4f (want 340.72)" % [gain_sec, v])
	var ok := same_file and absf(gain_sec - 201.71) <= 0.01 and absf(v - 340.72) <= 0.01

	# the movement project's own parity tests (456 + 41 cases, 64/100/128 tick), run as child processes
	var godot := OS.get_executable_path()
	for t in ["test_parity", "test_parity_phase3"]:
		var out: Array = []
		OS.execute(godot, ["--headless", "--path", movement_dir, "--import"], [], true)
		var code := OS.execute(godot, ["--headless", "--path", movement_dir, "--script", "res://tests/%s.gd" % t], out, true)
		var text := "".join(out)
		var line := text.strip_edges().split("\n")[-1]
		print("  %s.gd exit %d: %s" % [t, code, line])
		ok = ok and code == 0
	_gate("S2 parity", ok, "340.72 / 201.71 within 0.01")


# ---------------------------------------------------------------- S3

func _s3() -> void:
	print("\n== S3 Accuracy at 80 ms ping, 2% loss (jitter off) ==")
	var g := _sweep(_ticks(20000), 80.0, 0.02, false)
	_report_sweep(g)
	var p99 := _pct(g["seq_errors"], 0.99)
	var mx := _pct(g["seq_errors"], 1.0)
	var ok: bool = g["unexplained"] == 0 and p99 < 1.0 and mx < 8.0
	_gate("S3 accuracy", ok, "p99 %.4f units (<1), max %.4f (<8), unexplained corrections %d (0 expected), every reconcile with no lost command: error 0.0" % [p99, mx, g["unexplained"]])


func _report_sweep(g: Dictionary) -> void:
	print("  snapshots (real bytes, own block f64, no remotes yet): %d sent (%d full), bytes min %d / mean %.1f / max %d; client dropped for a missing baseline: %d" % [g["snap_n"], g["snap_full"], g["snap_min"], float(g["snap_bytes"]) / maxf(float(g["snap_n"]), 1.0), g["snap_max"], g["snap_dropped"]])
	print("  %d ticks over %d runs; %d cmds executed; fully lost (all 3 copies): %d (%.6f%% of cmds; 0.02^3 = 0.0008%%)" % [g["ticks"], ALL_BOTS.size() * SEEDS.size(), g["executed"], g["lost"], 100.0 * float(g["lost"]) / maxf(float(g["executed"]), 1.0)])
	print("  reconciles: %d matched exactly (error 0.0), %d corrected (%d explained by a lost cmd/teleport, %d unexplained)" % [g["matches"], g["corr"], g["explained"], g["unexplained"]])
	print("  per-seq error vs server: p50 %.4f p99 %.4f max %.4f units;  error at correction: max %.4f;  longest replay %d ticks;  ring overflows %d" % [_pct(g["seq_errors"], 0.5), _pct(g["seq_errors"], 0.99), _pct(g["seq_errors"], 1.0), g["max_rec_err"], g["max_replay"], g["overflows"]])


# ---------------------------------------------------------------- S4

func _s4() -> void:
	print("\n== S4 No visible jitter (jitter ON: +/-5 ms) ==")
	var g := _sweep(_ticks(20000), 80.0, 0.02, true)
	_report_sweep(g)
	print("  visual motion not explained by predicted motion: max %.4f units/tick (<=1);  max sign flips in 13 ticks: %d (<3)" % [g["max_vis"], g["max_flips"]])
	var ok: bool = g["unexplained"] == 0 and g["max_vis"] <= 1.0 and g["max_flips"] < 3

	# At 2% loss almost nothing needs correcting, so also force corrections: the server shoves
	# the player 6 units (no teleport flag) every 400 ticks, with jitter on.
	var worst := 0.0
	var flips := 0
	var shoves := 0
	for kind in ALL_BOTS:
		var s := _mk(5, 80.0, 0.02, true, false, false)
		for t in _ticks(6000):
			if t % 400 == 399:
				var st := s.server.state
				s.server.teleport(st.pos_x + 6.0, st.pos_y, st.pos_z, false, true)
				shoves += 1
			var i := Bots.input(kind, t, s.client.predicted)
			s.tick_once(i[0], i[1], i[2])
		worst = maxf(worst, s.max_unexplained_visual)
		flips = maxi(flips, s.client.max_flips)
	print("  forced 6-unit corrections (%d shoves, jitter on): visual unexplained max %.4f units/tick, max flips %d" % [shoves, worst, flips])
	ok = ok and worst <= 1.0 and flips < 3
	_gate("S4 no visible jitter", ok, "max %.4f units/tick beyond simulated motion, <3 flips. Human playtest still needed (main.tscn, key J = jitter)." % maxf(worst, g["max_vis"]))


# ---------------------------------------------------------------- S5

func _s5() -> void:
	print("\n== S5 Zero added input latency ==")
	var ok := true
	# (a) key press: visual moves on the very tick the key is read, over the real network, jitter on
	var lat_ticks: Array = []
	for sd in [1, 2, 3, 4, 5]:
		var s := _mk(sd, 80.0, 0.02, true)
		for t in 200:
			s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		var before := s.client.visual
		s.tick_once(InputCmd.BTN_FORWARD, 0, InputCmd.quantize_pitch(0.0))
		var moved := (s.client.visual - before).length() > 0.0 and s.client.offset == Vector3.ZERO
		lat_ticks.append(0 if moved else 1)
		ok = ok and moved
		# jump: vertical speed and height respond on the same tick
		var s2 := _mk(sd, 80.0, 0.02, true)
		for t in 200:
			s2.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		s2.tick_once(InputCmd.BTN_JUMP, 0, InputCmd.quantize_pitch(0.0))
		var jumped := s2.client.predicted.vel_up > 0.0 and s2.client.visual.y > 0.0
		ok = ok and jumped
	print("  key->visual latency in ticks (5 seeds): ", lat_ticks, "   jump same tick: ", ok)
	# (b) whole bot runs over 80 ms / jitter on, no loss: the visual is bit-identical to a standalone local simulation
	var diffs := 0
	for kind in ALL_BOTS:
		var s := _mk(3, 80.0, 0.0, true)
		var local := PlayerState.new()
		var cmd_seq := 1
		for t in _ticks(6000):
			var i := Bots.input(kind, t, s.client.predicted)
			s.tick_once(i[0], i[1], i[2])
			Movement.step(local, InputCmd.make(cmd_seq, t, i[0], i[1], i[2]), s.world)
			cmd_seq += 1
			var lv := Vector3(local.pos_x, local.pos_y, local.pos_z)
			if s.client.visual != lv:
				diffs += 1
	print("  visual vs standalone local sim (no netcode), 7 bots: %d differing ticks (0 expected: nothing added between key and visual)" % diffs)
	_gate("S5 zero input latency", ok and diffs == 0, "visual changes on the tick the key is read")


# ---------------------------------------------------------------- S6

func _s6() -> void:
	print("\n== S6 Loss stability ==")
	var all_ok := true
	for loss in [0.02, 0.10]:
		var g := _sweep(_ticks(20000), 80.0, loss, false)
		var expected: float = loss * loss * loss
		var frac := float(g["lost"]) / maxf(float(g["executed"]), 1.0)
		var exp_events: float = expected * float(g["executed"])
		print("  loss %.0f%%:" % (loss * 100.0))
		_report_sweep(g)
		print("    fully lost: expected %.1f events (%.6f%%), measured %d (%.6f%%); pass if within expected + 4 sigma + 1" % [exp_events, expected * 100.0, g["lost"], frac * 100.0])
		var ok: bool = g["unexplained"] == 0 and g["overflows"] == 0 and g["snaps_big"] == 0 and float(g["lost"]) <= exp_events + 4.0 * sqrt(exp_events) + 1.0
		# when every error comes from a lost command, errors only live between the loss and its correction
		print("    stable: unexplained %d, overflows %d, corrections that needed a >64-unit snap %d  ->  %s" % [g["unexplained"], g["overflows"], g["snaps_big"], str(ok)])
		all_ok = all_ok and ok
	_gate("S6 loss stability (2% and 10%)", all_ok, "no unexplained corrections, no ring overflow, no snaps")


# ---------------------------------------------------------------- S7

func _s7() -> void:
	print("\n== S7 Big corrections snap ==")
	var ok := true
	var ticks_to_snap: Array = []
	for kind in ["run", "bhop", "wall"]:
		# flagged teleport
		var s := _mk(4, 80.0, 0.0, false)
		s.schedule_teleport(1000, 100.0, 0.0, 100.0, true)
		var snap_tick := -1
		var slid := 0
		for t in 1400:
			var i := Bots.input(kind, t, s.client.predicted)
			s.tick_once(i[0], i[1], i[2])
			if snap_tick < 0 and s.client.corrections > 0:
				snap_tick = t
				if s.client.visual != Vector3(s.client.predicted.pos_x, s.client.predicted.pos_y, s.client.predicted.pos_z):
					slid += 1
			elif snap_tick >= 0 and t > snap_tick and s.client.offset != Vector3.ZERO:
				slid += 1
		var good := snap_tick >= 0 and slid == 0
		ok = ok and good
		ticks_to_snap.append(snap_tick - 1000)
		print("  %-5s flagged teleport at tick 1000: correction applied at tick %d (arrival), ticks with a visible slide afterwards: %d" % [kind, snap_tick, slid])
		# unflagged 100-unit shove (over the 64-unit threshold) snaps; a 6-unit one fades
		for dist in [100.0, 6.0]:
			var s2 := _mk(4, 80.0, 0.0, false)
			var fired := false
			var seen_offset := false
			var snapped := false
			for t in 800:
				if t == 500:
					var st := s2.server.state
					s2.server.teleport(st.pos_x + dist, st.pos_y, st.pos_z, false, true)
					fired = true
				var i2 := Bots.input("run", t, s2.client.predicted)
				s2.tick_once(i2[0], i2[1], i2[2])
				if fired and s2.client.corrections > 0:
					if s2.client.offset.length() > 0.0:
						seen_offset = true
					elif s2.client.visual == Vector3(s2.client.predicted.pos_x, s2.client.predicted.pos_y, s2.client.predicted.pos_z):
						snapped = true
			var expect_snap: bool = dist > Client.SNAP_DISTANCE
			var good2 := (snapped and not seen_offset) if expect_snap else seen_offset
			ok = ok and good2
			print("      unflagged %.0f-unit shove: %s (%s)" % [dist, "snapped" if snapped and not seen_offset else "faded over ~13 ticks", "ok" if good2 else "WRONG"])
	_gate("S7 snap on teleports", ok, "snap happens on the tick the correction arrives, no 100 ms slide")


# ---------------------------------------------------------------- S8

func _s8() -> void:
	print("\n== S8 Replay cost: 32 ticks in GDScript ==")
	# a player mid-bhop at full speed
	var warm := _run("bhop", 1, 2000, 0.0, 0.0, false, false)
	var base := warm.client.predicted.duplicate_state()
	var c := Client.new(warm.world)
	c.predicted.copy_from(base)
	for t in 32:
		var i := Bots.input("bhop", 2000 + t, c.predicted)
		c.predict(i[0], i[1], i[2], 2000 + t)
	var runs := 1000
	for w in 100:
		c._replay_from(0, base)
	var times := PackedFloat64Array()
	for r in runs:
		var t0 := Time.get_ticks_usec()
		c._replay_from(0, base)
		times.append(float(Time.get_ticks_usec() - t0))
	times.sort()
	var med := times[runs / 2]
	var worst := times[runs - 1]
	# the whole reconcile() call as the loop uses it (compare, mismatch, replay, drop)
	var tamper := base.duplicate_state()
	tamper.pos_x += 1.0
	var full := PackedFloat64Array()
	for r in runs:
		var cc := Client.new(warm.world)
		cc.predicted.copy_from(base)
		for t in 32:
			var i := Bots.input("bhop", 2000 + t, cc.predicted)
			cc.predict(i[0], i[1], i[2], 2000 + t)
		var t1 := Time.get_ticks_usec()
		cc.reconcile_states([{"last_seq": 0 + 1, "state": tamper}])
		full.append(float(Time.get_ticks_usec() - t1))
	full.sort()
	print("  replay of 32 ticks (Movement.step x32 incl. ring writes), %d runs: median %.0f us, p99 %.0f us, worst %.0f us   (limit 1000 us)" % [runs, med, times[int(runs * 0.99)], worst])
	print("  full reconcile() with a 31-tick replay: median %.0f us, worst %.0f us" % [full[runs / 2], full[runs - 1]])
	print("  per Movement.step: %.1f us" % (med / 32.0))
	var ok := med < 1000.0
	if ok and worst >= 1000.0:
		print("  NOTE: median passes but the worst run is over 1 ms (OS scheduling noise or a real tail); rerun on the dev machine.")
	if not ok:
		print("  S8 FAILED: this is the measured trigger for the Rust port (godot-rust/gdext). Not started.")
	_gate("S8 replay cost", ok, "median %.0f us, worst %.0f us for 32 ticks (verdict on the median; worst reported)" % [med, worst])


# ---------------------------------------------------------------- S9

func _s9() -> void:
	print("\n== S9 Recording replays headless to the same final state ==")
	var ping := 80.0
	var loss := 0.02
	var s := _mk(9, ping, loss, true, false, true)
	s.schedule_teleport(1500, 120.0, 0.0, 120.0, true)
	s.schedule_teleport(2600, 0.0, 0.0, 0.0, false)
	var n := _ticks(6000)
	for t in n:
		if t == n / 2:
			s.apply_config(150.0, 0.05, true)
		var i := Bots.input("mixed", t, s.client.predicted)
		s.tick_once(i[0], i[1], i[2])
	var d := Recorder.to_dict(s)
	var path := ProjectSettings.globalize_path("res://recordings/last_run.json")
	var saved := Recorder.save(path, d)
	var loaded := Recorder.load_file(path)
	var r := Recorder.replay(loaded)
	var same_state: bool = r.final_hex() == loaded["final"]["state_hex"]
	var same_csv: bool = r.csv_sha256() == loaded["final"]["csv_sha256"]
	print("  saved %s (%d ticks, %d cmds): %s" % [path.get_file(), s.tick, s.cmd_log.size(), str(saved)])
	print("  replayed from file: final state identical %s, CSV sha256 identical %s (%s...)" % [str(same_state), str(same_csv), r.csv_sha256().substr(0, 16)])
	_gate("S9 replay", saved and same_state and same_csv, "final server+client state bit-identical after replay")
