extends SceneTree
## Remote-player interpolation (Phase 3):  godot --headless --script res://tests/test_interp.gd
## Golden: python3 tools/interp_ref.py --emit prototypes/prediction_loop/tests/golden (seed 7101, 1,000 streams).

var passed := 0
var failed := 0


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	_golden()
	_unit()
	_session_tests()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


static func _angdiff(a: float, b: float) -> float:
	var d := fposmod(a - b + PI, TAU) - PI
	return absf(d)


func _golden() -> void:
	var raw := FileAccess.get_file_as_bytes("res://tests/golden/interp_cases.json.gz")
	var txt := raw.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8()
	var g: Dictionary = JSON.parse_string(txt)
	var streams: Array = g["streams"]
	var bad_present := 0
	var bad_pos := 0
	var bad_ang := 0
	var bad_flags := 0
	var checked := 0
	var starved_total := 0
	var worst_pos := 0.0
	var worst_ang := 0.0
	for st in streams:
		var buf := InterpBuffer.new(float(st["extrap"]))
		var removed_at := -1
		for t in st["ticks"]:
			for e in t["events"]:
				if e[0] == "s":
					if int(e[1]) <= removed_at:
						continue
					buf.insert(int(e[1]), float(int(e[2])) / 8.0, float(int(e[3])) / 8.0, float(int(e[4])) / 8.0, int(e[5]), int(e[6]), int(e[7]), int(e[8]), int(e[9]) == 1, float(int(e[10])) / 255.0)
				else:
					removed_at = maxi(removed_at, int(e[1]))
					buf.remove()
			var vis := buf.sample(float(int(t["render_q"])) / 256.0)
			checked += 1
			if vis != bool(t["present"]):
				bad_present += 1
				continue
			if not vis:
				continue
			var dp := maxf(absf(buf.out_x - float(t["x"])), maxf(absf(buf.out_y - float(t["y"])), absf(buf.out_z - float(t["z"]))))
			var da := maxf(_angdiff(buf.out_yaw, float(t["yaw"])), maxf(absf(buf.out_pitch - float(t["pitch"])), absf(buf.out_duck - float(t["duck"]))))
			worst_pos = maxf(worst_pos, dp)
			worst_ang = maxf(worst_ang, da)
			if dp > 1.0e-9:
				bad_pos += 1
			if da > 1.0e-9:
				bad_ang += 1
			if buf.out_stance != int(t["stance"]) or buf.out_alive != int(t["alive"]) or buf.out_starved != bool(t["starved"]):
				bad_flags += 1
			if bool(t["starved"]):
				starved_total += 1
	_ok("golden: %d streams, %d ticks: presence matches Python" % [streams.size(), checked], bad_present == 0, "%d differ" % bad_present)
	_ok("golden: positions within 1e-9", bad_pos == 0, "%d differ, worst %.12f" % [bad_pos, worst_pos])
	_ok("golden: yaw, pitch (plain lerp, signed) and duck fraction within 1e-9", bad_ang == 0, "%d differ, worst %.12f" % [bad_ang, worst_ang])
	_ok("golden: stance, alive and starved flags exact (%d starved ticks)" % starved_total, bad_flags == 0, "%d differ" % bad_flags)


func _put(b: InterpBuffer, tick: int, x: float, z: float, yaw_deg: float = 0.0, is_new: bool = false) -> void:
	b.insert(tick, x, 0.0, z, InputCmd.quantize_yaw(deg_to_rad(yaw_deg)), InputCmd.quantize_pitch(0.0), 0, 1, is_new)


func _unit() -> void:
	# remote duck fraction: a ducking remote is drawn smoothly between samples (no step), monotonic
	var dk := InterpBuffer.new()
	var q_prev := 0
	for k in 8:
		var qd := mini(255, k * 40)
		dk.insert(k * 2, 0.0, 0.0, 0.0, 0, 32768, 1 if qd > 0 else 0, 1, false, Quant.q_to_duck(qd))
	var mono := true
	var max_step_duck := 0.0
	var last := -1.0
	for r in range(0, 14 * 8 + 1):
		dk.sample(float(r) / 8.0)
		if last >= 0.0:
			mono = mono and dk.out_duck >= last - 1.0e-12
			max_step_duck = maxf(max_step_duck, dk.out_duck - last)
		last = dk.out_duck
	_ok("remote duck: out_duck is monotonic and smooth across the transition (render steps of 1/8 tick)", mono and max_step_duck < 40.0 / 255.0 / 8.0 + 1.0e-9 and dk.out_duck > 0.0, "largest step %.5f per 1/8 tick (a hard step would be %.3f)" % [max_step_duck, 40.0 / 255.0])
	var mid := InterpBuffer.new()
	mid.insert(10, 0.0, 0.0, 0.0, 0, 32768, 0, 1, false, 0.0)
	mid.insert(12, 0.0, 0.0, 0.0, 0, 32768, 1, 1, false, 1.0)
	mid.sample(11.0)
	_ok("remote duck: halfway between standing and ducked samples = 0.5", absf(mid.out_duck - 0.5) < 1.0e-12 and mid.out_stance == 0)
	# pitch is a plain signed lerp (never wraps into 0..2PI)
	var pb := InterpBuffer.new()
	pb.insert(10, 0.0, 0.0, 0.0, 0, InputCmd.quantize_pitch(-0.5), 0, 1, false)
	pb.insert(12, 0.0, 0.0, 0.0, 0, InputCmd.quantize_pitch(0.5), 0, 1, false)
	pb.sample(11.0)
	_ok("pitch: -0.5 -> +0.5 halfway = 0.0 (signed, no wrap)", absf(pb.out_pitch) < 1.0e-4, "%.6f" % pb.out_pitch)
	pb.sample(10.5)
	_ok("pitch stays signed: a quarter of the way = -0.25", absf(pb.out_pitch + 0.25) < 1.0e-4 and pb.out_pitch < 0.0, "%.6f" % pb.out_pitch)
	# shortest arc: 350 -> 10 degrees, halfway = 0 (not 180)
	var b := InterpBuffer.new()
	_put(b, 10, 0.0, 0.0, 350.0)
	_put(b, 12, 0.0, 0.0, 10.0)
	b.sample(11.0)
	_ok("shortest arc: 350 -> 10, halfway = 0 degrees", _angdiff(b.out_yaw, 0.0) < 0.002, "%.4f degrees" % rad_to_deg(b.out_yaw if b.out_yaw < PI else b.out_yaw - TAU))
	# interpolation is linear between the two bracketing samples; stance comes from the older one
	var c := InterpBuffer.new()
	c.insert(10, 0.0, 0.0, 0.0, 0, 32768, 0, 1, false)
	c.insert(12, 8.0, 0.0, 0.0, 0, 32768, 1, 1, false)
	c.sample(11.0)
	_ok("linear halfway", absf(c.out_x - 4.0) < 1.0e-12 and c.out_stance == 0, "x = %.6f stance %d" % [c.out_x, c.out_stance])
	c.sample(12.0)
	_ok("stance switches when the newer sample is reached", c.out_stance == 1 and absf(c.out_x - 8.0) < 1.0e-12)
	# C2 = 0: a forced 3-snapshot gap holds the pose, then blends back over 4 ticks without a jump over 64
	var h := InterpBuffer.new(0.0)
	for k in 6:
		_put(h, k * 2, float(k) * 4.0, 0.0)
	var held_ok := true
	var starved_n := 0
	for r in range(10, 17):            # render ticks 10..16 with the newest sample at tick 10 (x = 20)
		h.sample(float(r))
		if r > 10:
			starved_n += 1
			held_ok = held_ok and h.out_starved and h.out_x == 20.0
	_ok("C2 = 0: no extrapolation, the pose is held exactly (E vs held pose 0.0)", held_ok and starved_n == 6 and h.starved_ticks == 6, "%d starved ticks" % h.starved_ticks)
	for k in range(6, 14):
		_put(h, k * 2, float(k) * 4.0, 0.0)
	var prev := h.out_x
	var max_step := 0.0
	var seq: Array = []
	for r in range(17, 22):
		h.sample(float(r))
		seq.append(snappedf(h.out_x, 0.001))
		max_step = maxf(max_step, absf(h.out_x - prev))
		prev = h.out_x
	_ok("blend back after starvation: no jump (largest step %.3f units, snap limit 64)" % max_step, max_step < 64.0 and not h.out_starved, str(seq))
	# extrapolation switch (C2 > 0, not the default): linear from the last two samples, capped
	var e := InterpBuffer.new(2.0)
	_put(e, 0, 0.0, 0.0)
	_put(e, 2, 8.0, 0.0)
	e.sample(5.0)
	_ok("C2 = 2.0: extrapolates 2 ticks (4 u/tick) then holds", absf(e.out_x - 16.0) < 1.0e-12 and e.out_starved, "x = %.3f (8.0 + 2 ticks x 4.0)" % e.out_x)
	# respawn / teleport snap: a jump over 64 units is never interpolated
	var t := InterpBuffer.new()
	_put(t, 10, 0.0, 0.0)
	_put(t, 12, 500.0, 0.0)
	t.sample(11.9)
	var before := t.out_x
	t.sample(12.0)
	_ok("teleport (500 units): held until render tick reaches the new sample, then exactly there", before == 0.0 and t.out_x == 500.0, "x %.1f -> %.1f" % [before, t.out_x])
	var n := InterpBuffer.new()
	_put(n, 10, 0.0, 0.0)
	_put(n, 12, 30.0, 0.0, 0.0, true)
	n.sample(11.0)
	_ok("a sample marked new (respawn) snaps even for a short distance", n.out_x == 0.0)
	n.sample(12.0)
	_ok("... and is drawn there once reached", n.out_x == 30.0)
	# removal
	n.remove()
	_ok("removal clears the slot at once", not n.sample(12.5) and n.is_empty())
	# ring: 16 samples, oldest dropped; a too-old sample is ignored when full
	var rg := InterpBuffer.new()
	for k in 20:
		_put(rg, 100 + k, float(k), 0.0)
	_put(rg, 5, 999.0, 0.0)
	_ok("ring keeps 16 samples; a sample older than the oldest is ignored when full", rg.n == 16 and rg.ticks[0] == 104 and rg.ticks[15] == 119)


func _run(extrap_ticks: float, interp_ticks: float, ping: float, loss: float, jitter: bool, remotes: Array, ticks: int, seed_value: int) -> Session:
	NetConfig.INTERP_TICKS = interp_ticks
	NetConfig.EXTRAP_MAX_TICKS = extrap_ticks
	var s := Session.new(seed_value, ping, loss, jitter, false, false)
	s.measure_remotes = true
	for r in remotes:
		s.add_remote(r)
	for tk in ticks:
		s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
	NetConfig.INTERP_TICKS = 4.0
	NetConfig.EXTRAP_MAX_TICKS = 0.0
	return s


func _max(a: PackedFloat64Array) -> float:
	var m := 0.0
	for v in a:
		m = maxf(m, v)
	return m


func _session_tests() -> void:
	# exactness: a straight path, no loss: only the 1/8 quantization remains
	var s := _run(0.0, 4.0, 80.0, 0.0, false, [RemotePath.make_straight(1, -1000.0, -1000.0, 0.7)], 1200, 3)
	var worst := _max(s.e_interp_all)
	_ok("linear path, no loss: E_interp <= 0.1083 (sqrt(3)/16, quantization only) every tick", worst <= 0.1083 and s.e_interp_all.size() > 1000, "worst %.5f over %d ticks" % [worst, s.e_interp_all.size()])
	var lat := 0.0
	for v in s.latency_ticks:
		lat += v
	lat /= float(s.latency_ticks.size())
	_ok("display latency at interp 4 and 80 ms (jitter off) = 10 ticks (one-way 6 + interp 4)", absf(lat - 10.0) < 0.01, "%.3f ticks = %.1f ms" % [lat, lat * 7.8125])
	for it in [2.0, 3.0]:
		var si := _run(0.0, it, 80.0, 0.0, false, [RemotePath.make_straight(1, -1000.0, -1000.0, 0.7)], 600, 3)
		var l := 0.0
		for v in si.latency_ticks:
			l += v
		l /= float(si.latency_ticks.size())
		_ok("display latency at interp %d = %d ticks" % [int(it), int(6.0 + it)], absf(l - (6.0 + it)) < 0.01, "%.3f ticks" % l)
	# respawn / teleport snap through the whole stack: no slide
	var tp := RemotePath.make_straight(1, -1000.0, -1000.0, 0.0)
	tp.add_teleport(700, 0.0, 500.0)
	var st := Session.new(4, 80.0, 0.0, false, false, false)
	st.add_remote(tp)
	var zs: Array = []
	var slid := 0
	for tk in 900:
		st.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		var b: InterpBuffer = st.client.remotes[1]
		if tk > 650 and tk < 760 and st.client.remote_visible[1] == 1:
			zs.append(b.out_z)
			var z0 := -1000.0
			# the path moves only in x; z is either the old z or the old z + 500, never in between
			if absf(b.out_z - z0) > 0.2 and absf(b.out_z - (z0 + 500.0)) > 0.2:
				slid += 1
	_ok("teleport_at(tick 700, +500 units): the drawn pose jumps, never slides", slid == 0 and zs.size() > 50, "%d samples, %d in between" % [zs.size(), slid])
	# removal through the whole stack: gone on the tick the snapshot without it arrives
	var dp := RemotePath.make_straight(1, -1000.0, -1000.0, 0.7)
	dp.despawn_tick = 400
	var sd := Session.new(5, 80.0, 0.0, false, false, false)
	sd.add_remote(dp)
	var vis_405 := -1
	var vis_406 := -1
	for tk in 500:
		sd.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		if tk == 405:
			vis_405 = sd.client.remote_visible[1]
		if tk == 406:
			vis_406 = sd.client.remote_visible[1]
	_ok("REMOVED: visible at tick 405, gone on tick 406 (the arrival of the snapshot without it)", vis_405 == 1 and vis_406 == 0, "visible(405) = %d, visible(406) = %d" % [vis_405, vis_406])
	# a ducking remote through the whole stack: the drawn duck fraction slides, never steps
	var sc := Session.new(6, 80.0, 0.0, false, false, false)
	sc.add_remote(RemotePath.make_stepped(1, RemotePath.Kind.CROUCH_TOGGLE, 2000.0, 600.0))
	var cb: InterpBuffer = sc.client.remotes[1]
	var dprev := -1.0
	var dstep := 0.0
	var dmax := 0.0
	var dmid := 0
	for tk in 700:
		sc.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		if sc.client.remote_visible[1] == 1:
			if dprev >= 0.0 and cb.out_duck > dprev:
				dstep = maxf(dstep, cb.out_duck - dprev)
			dprev = cb.out_duck
			dmax = maxf(dmax, cb.out_duck)
			if cb.out_duck > 0.1 and cb.out_duck < 0.9:
				dmid += 1
	_ok("crouching remote through the stack: out_duck rises smoothly to 1.0 (largest rise %.3f per tick, %d in-between draws)" % [dstep, dmid], dstep < 0.06 and dmax > 0.99 and dmid > 20)
	# determinism
	var a := _run(0.0, 4.0, 80.0, 0.02, true, RemotePath.make_set(6), 1500, 21)
	var b2 := _run(0.0, 4.0, 80.0, 0.02, true, RemotePath.make_set(6), 1500, 21)
	var c2 := _run(0.0, 4.0, 80.0, 0.02, true, RemotePath.make_set(6), 1500, 22)
	_ok("determinism: same seed -> identical E_interp series", a.e_interp_all.to_byte_array() == b2.e_interp_all.to_byte_array() and a.e_interp_all.size() > 5000, "%d values" % a.e_interp_all.size())
	_ok("a different seed gives a different series", a.e_interp_all.to_byte_array() != c2.e_interp_all.to_byte_array())
	# remotes never change own-player prediction
	var with_r := Session.new(9, 80.0, 0.02, true, true, false)
	for r in RemotePath.make_set(10):
		with_r.add_remote(r)
	var without := Session.new(9, 80.0, 0.02, true, true, false)
	for tk in 2000:
		var i := Bots.input("mixed", tk, with_r.client.predicted)
		with_r.tick_once(i[0], i[1], i[2])
		var j := Bots.input("mixed", tk, without.client.predicted)
		without.tick_once(j[0], j[1], j[2])
	_ok("remotes present: own-player prediction is bit-identical to a run without remotes", with_r.client.predicted.equals(without.client.predicted) and with_r.client.corrections == without.client.corrections, "final state hex equal: %s" % str(with_r.client.predicted.hex() == without.client.predicted.hex()))
