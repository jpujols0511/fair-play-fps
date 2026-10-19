extends SceneTree
## Remote-player measurement runner (Phase 3):
##   godot --headless --script res://tests/run_remote.gd                 (full grid, about 10 minutes)
##   godot --headless --script res://tests/run_remote.gd -- --quick      (short, for development)
##   godot --headless --script res://tests/run_remote.gd -- --cell       (only the default cell and its gates)
## Seeded, 128 tick, 7,680 ticks (60 s) x 5 seeds per cell. Prints a table and writes
## tests/logs/remote_grid.csv. NO recommendation: this produces the options for Joan (interp 2 / 3 / 4).

var quick := false
var only_cell := false
var rows: Array = []
var gate_fail := 0


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	var args := OS.get_cmdline_user_args()
	quick = "--quick" in args
	only_cell = "--cell" in args
	var ticks := 7680 / 8 if quick else 7680
	var seeds: Array = [101, 102] if quick else [101, 102, 103, 104, 105]
	print("Godot ", Engine.get_version_info()["string"], "  ticks per run %d, seeds %d%s" % [ticks, seeds.size(), "  (QUICK)" if quick else ""])
	print("\n== default cell: interp 4, 80 ms, 2%% loss, jitter off, 10 remotes ==")
	var d := _cell(4.0, 80.0, 0.02, false, 10, ticks, seeds)
	_print_row(d)
	_gates(d)
	NetConfig.SNAPSHOT_EVERY_TICKS = 1
	var d1 := _cell(4.0, 80.0, 0.02, false, 10, ticks, seeds)
	NetConfig.SNAPSHOT_EVERY_TICKS = 2
	var parts1: Array = []
	var names1 := ["LINEAR", "LINEAR_STRAIGHT", "CIRCLE", "STRAFE_JIGGLE", "PEEK", "CROUCH_TOGGLE", "BHOP_CHAIN (jump/landing)"]
	for k in d1["kind_max"]:
		parts1.append("%s %.3f" % [names1[k], d1["kind_max"][k]])
	print("INFO  same cell with 128 snapshots/s (C4 = 1): E_interp p99 %.4f, max %.4f (by kind: %s)" % [d1["p99"], d1["max"], ", ".join(parts1)])
	if not only_cell:
		print("\n== grid: interp 2/3/4 x loss 0/2/5%% x jitter off/on x remotes 2/6/10, ping 80 ms ==")
		print("| interp | loss | jitter | remotes | E_interp p50 | p99 | max | E_true p99 | starved %% | starve episodes/min | longest starve (ticks) | latency (ms) |")
		print("|---|---|---|---|---|---|---|---|---|---|---|---|")
		for it in [2.0, 3.0, 4.0]:
			for loss in [0.0, 0.02, 0.05]:
				for jit in [false, true]:
					for nrem in [2, 6, 10]:
						var c := _cell(it, 80.0, loss, jit, nrem, ticks, seeds)
						rows.append(c)
						_print_row(c)
		print("\n== ping 40 and 150 at interp 4, 2%% loss, jitter off, 10 remotes ==")
		for ping in [40.0, 150.0]:
			var c2 := _cell(4.0, ping, 0.02, false, 10, ticks, seeds)
			c2["ping"] = ping
			rows.append(c2)
			_print_row(c2)
		_write_csv()
	print("\n%s" % ("ALL GATES PASS" if gate_fail == 0 else "%d GATE(S) FAILED" % gate_fail))
	quit(1 if gate_fail > 0 else 0)


func _pct(a: PackedFloat64Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[mini(int(ceil(p * float(b.size()))) - 1, b.size() - 1)]


func _cell(interp: float, ping: float, loss: float, jitter: bool, nrem: int, ticks: int, seeds: Array) -> Dictionary:
	NetConfig.INTERP_TICKS = interp
	NetConfig.EXTRAP_MAX_TICKS = 0.0
	var e := PackedFloat64Array()      # clean (adjacent samples) + bridged, outside snap windows and recovery
	var eclean := PackedFloat64Array()
	var kind_max := {}
	var erec := PackedFloat64Array()
	var ebr := PackedFloat64Array()
	var et := PackedFloat64Array()
	var lat := 0.0
	var lat_n := 0
	var starved := 0
	var visible_ticks := 0
	var episodes := 0
	var longest := 0
	var unexplained := 0
	var snap_ticks := 0
	var total_ticks := 0
	var max_all := 0.0
	var kind_all := {}
	for sd in seeds:
		var s := Session.new(sd, ping, loss, jitter, false, false)
		s.measure_remotes = true
		for r in RemotePath.make_set(nrem):
			s.add_remote(r)
		for t in ticks:
			s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		eclean.append_array(s.e_interp)
		e.append_array(s.e_interp)
		e.append_array(s.e_bridged)
		erec.append_array(s.e_recovery)
		for k in s.e_by_kind:
			kind_max[k] = maxf(kind_max.get(k, 0.0), _pct(s.e_by_kind[k], 1.0))
			var ka: PackedFloat64Array = kind_all.get(k, PackedFloat64Array())
			ka.append_array(s.e_by_kind[k])
			kind_all[k] = ka
		ebr.append_array(s.e_bridged)
		et.append_array(s.e_true)
		for v in s.latency_ticks:
			lat += v
			lat_n += 1
		snap_ticks += s.snap_window_ticks
		total_ticks += ticks
		visible_ticks += s.e_interp_all.size()
		# starvation episodes per slot (consecutive starved ticks)
		var by_slot := {}
		for ev in s.client.starved_log:
			if not by_slot.has(ev[1]):
				by_slot[ev[1]] = []
			(by_slot[ev[1]] as Array).append(ev[0])
		var drops: Array = []
		for ms in s.net.drop_log[FakeNet.S2C]:
			drops.append(int(round(float(ms) / (1000.0 / Movement.TICK_RATE))))
		for slot in by_slot:
			var tl: Array = by_slot[slot]
			var run := 0
			var start := -1
			var prev := -10
			for i in tl.size():
				if tl[i] != prev + 1:
					if run > 0:
						longest = maxi(longest, run)
					run = 0
					start = tl[i]
					episodes += 1
					# explained: two consecutive snapshots (T, T + 2) were dropped shortly before the episode began
					var ok := false
					for dt in drops:
						if (dt + 2) in drops and start >= dt + 6 and start <= dt + 2 + 6 + 12:
							ok = true
					if not ok:
						unexplained += 1
				run += 1
				prev = tl[i]
			longest = maxi(longest, run)
		starved += s.client.starved_log.size()
	NetConfig.INTERP_TICKS = 4.0
	var minutes := float(total_ticks) / Movement.TICK_RATE / 60.0
	return {"interp": interp, "ping": ping, "loss": loss, "jitter": jitter, "remotes": nrem,
		"p50": _pct(e, 0.5), "p99": _pct(e, 0.99), "max": _pct(e, 1.0), "tp99": _pct(et, 0.99), "kind_max": kind_max, "kind_p99": _kind_p99(kind_all), "rec_max": _pct(erec, 1.0), "rec_n": erec.size(), "clean_max": _pct(eclean, 1.0), "clean_p99": _pct(eclean, 0.99), "bridged_max": _pct(ebr, 1.0), "bridged_n": ebr.size(),
		"starved_pct": 100.0 * float(starved) / maxf(float(visible_ticks), 1.0), "episodes_min": float(episodes) / minutes / float(maxi(nrem, 1)),
		"longest": longest, "latency_ms": lat / maxf(float(lat_n), 1.0) * 1000.0 / Movement.TICK_RATE, "latency_ticks": lat / maxf(float(lat_n), 1.0),
		"unexplained": unexplained, "episodes": episodes, "snap_ticks": snap_ticks, "n": e.size()}


func _print_row(c: Dictionary) -> void:
	print("| %d | %d%% | %s | %d | %.4f | %.4f | %.4f | %.3f | %.3f | %.2f | %d | %.1f |" % [int(c["interp"]), int(round(c["loss"] * 100.0)), "on" if c["jitter"] else "off", c["remotes"],
		c["p50"], c["p99"], c["max"], c["tp99"], c["starved_pct"], c["episodes_min"], c["longest"], c["latency_ms"]]
		+ ("  ping %d" % int(c["ping"]) if c.has("ping") else ""))


func _kind_p99(kind_all: Dictionary) -> Dictionary:
	var out := {}
	for k in kind_all:
		out[k] = _pct(kind_all[k], 0.99)
	return out


## Addendum 3 item 6: BHOP_CHAIN is the jump / landing path; every other kind stays on the ground.
const JUMP_KINDS := [6]


func _gate(name: String, ok: bool, detail: String) -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", name, detail])
	if not ok:
		gate_fail += 1


func _gates(c: Dictionary) -> void:
	_gate("default cell: E_interp p99 <= 0.25 units", c["p99"] <= 0.25, "p99 %.4f" % c["p99"])
	var worst_ground := 0.0
	var worst_jump := 0.0
	var worst_p99 := 0.0
	for k in c["kind_max"]:
		if k in JUMP_KINDS:
			worst_jump = maxf(worst_jump, c["kind_max"][k])
		else:
			worst_ground = maxf(worst_ground, c["kind_max"][k])
		worst_p99 = maxf(worst_p99, c["kind_p99"].get(k, 0.0))
	_gate("default cell: E_interp max <= 1.0 on non-jump paths (outside snaps and recovery)", worst_ground <= 1.0, "max %.4f over %d samples (%d ticks in snap windows and %d ticks starved or blending back are counted separately)" % [worst_ground, c["n"], c["snap_ticks"], c["rec_n"]])
	_gate("default cell: E_interp max <= 4.0 on jump / landing paths (BHOP_CHAIN)", worst_jump <= 4.0, "max %.4f" % worst_jump)
	print("INFO  per-kind p99 is report-only (CD-r5): worst per-kind p99 %.4f; the gate is the pooled p99 <= 0.25 above (%.4f)" % [worst_p99, c["p99"]])
	print("      breakdown: samples between ADJACENT snapshots (2 ticks apart): p99 %.4f, max %.4f;  samples bridging ONE lost snapshot (4 ticks apart, %d samples): max %.4f;  starved or blending back (2+ lost, %d ticks): max %.4f" % [c["clean_p99"], c["clean_max"], c["bridged_n"], c["bridged_max"], c["rec_n"], c["rec_max"]])
	var names := ["LINEAR", "LINEAR_STRAIGHT", "CIRCLE", "STRAFE_JIGGLE", "PEEK", "CROUCH_TOGGLE", "BHOP_CHAIN (jump/landing)"]
	var parts: Array = []
	for k in c["kind_max"]:
		parts.append("%s max %.3f p99 %.3f" % [names[k], c["kind_max"][k], c["kind_p99"].get(k, 0.0)])
	print("      E_interp by path kind (outside snaps and recovery): " + ", ".join(parts))
	_gate("default cell: every starved stretch is explained by 2+ consecutive lost snapshots", c["unexplained"] == 0, "%d episodes, %d unexplained, longest %d ticks, starved %.3f%% of drawn ticks" % [c["episodes"], c["unexplained"], c["longest"], c["starved_pct"]])
	_gate("default cell: display latency 10-11 ticks (+-1)", c["latency_ticks"] >= 9.0 and c["latency_ticks"] <= 12.0, "%.2f ticks = %.1f ms" % [c["latency_ticks"], c["latency_ms"]])


func _write_csv() -> void:
	var f := FileAccess.open("res://tests/logs/remote_grid.csv", FileAccess.WRITE)
	f.store_line("interp,ping_ms,loss,jitter,remotes,e_interp_p50,e_interp_p99,e_interp_max,e_true_p99,starved_pct,episodes_per_min_per_remote,longest_starve_ticks,latency_ms")
	for c in rows:
		f.store_line("%d,%d,%.2f,%s,%d,%.5f,%.5f,%.5f,%.4f,%.4f,%.3f,%d,%.2f" % [int(c["interp"]), int(c.get("ping", 80.0)), c["loss"], str(c["jitter"]), c["remotes"], c["p50"], c["p99"], c["max"], c["tp99"], c["starved_pct"], c["episodes_min"], c["longest"], c["latency_ms"]])
