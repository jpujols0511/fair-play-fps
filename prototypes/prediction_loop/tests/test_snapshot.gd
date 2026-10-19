extends SceneTree
## Snapshots: full + delta, seq/ack, baseline ring.   godot --headless --script res://tests/test_snapshot.gd
## Golden data: python3 tools/snapshot_ref.py --emit prototypes/prediction_loop/tests/golden (seed 7001).

var passed := 0
var failed := 0


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	var f := FileAccess.open("res://tests/golden/snapshot_cases.json", FileAccess.READ)
	var g: Dictionary = JSON.parse_string(f.get_as_text())
	_ok("own-player field count comes from PlayerState.to_packed()", Snapshot.own_count() == int(g["own_fields"]) and Snapshot.own_count() == 13, "F = %d" % Snapshot.own_count())
	_golden(g)
	_named(g)
	_quant(g)
	_serial()
	_ack_and_ring()
	_receiver()
	_fuzz()
	_duck_and_acks()
	_stale_ack_recovery()
	_wired()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _hex(s: String) -> PackedByteArray:
	return s.hex_decode()


func _golden(g: Dictionary) -> void:
	var cases: Array = g["cases"]
	var bad_base := 0
	var bad_full := 0
	var bad_delta := 0
	var bad_decode := 0
	var bad_roundtrip := 0
	for c in cases:
		var base_bytes := _hex(c["base_full"])
		var tf := _hex(c["target_full"])
		var td := _hex(c["target_delta"])
		var b := Snapshot.decode(base_bytes)
		var t := Snapshot.decode(tf)
		if b == null or t == null:
			bad_decode += 1
			continue
		if b.encode() != base_bytes:
			bad_base += 1
		if t.encode() != tf:
			bad_full += 1
		if t.encode(b) != td:
			bad_delta += 1
		var d := Snapshot.decode(td, b)
		if d == null or not d.same_content(t):
			bad_roundtrip += 1
	_ok("golden: GDScript decode of the Python bytes, then full re-encode == Python full bytes (base and target)", bad_base + bad_full + bad_decode == 0, "%d pairs, %d bad" % [cases.size(), bad_base + bad_full + bad_decode])
	_ok("golden: GDScript delta bytes == Python delta bytes", bad_delta == 0, "%d pairs, %d differ" % [cases.size(), bad_delta])
	_ok("golden: GDScript decodes the Python delta to the target (incl. sequence wraps 65535 -> 0)", bad_roundtrip == 0, "%d pairs, %d differ" % [cases.size(), bad_roundtrip])


func _named(g: Dictionary) -> void:
	var n: Dictionary = g["named"]
	for name in n:
		var e: Dictionary = n[name]
		var t := Snapshot.decode(_hex(e["target_full"]))
		var x: Dictionary = e["expect"]
		var ok: bool = t != null and t.snap_seq == int(x["snap_seq"]) and t.server_tick == int(x["server_tick"]) and t.ack_cmd_seq == int(x["ack_cmd_seq"]) \
			and t.flags == int(x["flags"]) and t.own.to_byte_array().hex_encode() == x["own_hex"] \
			and t.hud_acc == int(x["hud"][0]) and t.hud_pp == int(x["hud"][1]) and t.hud_py == int(x["hud"][2]) and t.hud_ms == int(x["hud"][3])
		if ok:
			var ents: Dictionary = x["ents"]
			ok = t.entity_count() == ents.size()
			for k in ents:
				var v: Array = ents[k]
				for i in Snapshot.FIELDS:
					if t.ent[int(k) * Snapshot.FIELDS + i] != int(v[i]):
						ok = false
		_ok("named %s: decoded values equal the Python input" % name, ok)
	_ok("named empty delta = 14 + 111 + 1 = 126 bytes", int(n["empty_delta"]["size"]) == 126 and _hex(n["empty_delta"]["target_delta"]).size() == 126)
	var ed := Snapshot.decode(_hex(n["empty_delta"]["target_delta"]), Snapshot.decode(_hex(n["empty_delta"]["base_full"])))
	_ok("named empty delta has entity_count 0 and keeps every baseline entity", ed != null and _hex(n["empty_delta"]["target_delta"]).decode_u8(125) == 0 and ed.entity_count() == Snapshot.decode(_hex(n["empty_delta"]["base_full"])).entity_count())
	_ok("named one entity moved on x only = 126 + 2 + 2 bytes", int(n["one_entity_x_only"]["size"]) == 130 and _hex(n["one_entity_x_only"]["target_delta"]).size() == 130)
	_ok("named full 12-player snapshot = 280 bytes (< 400)", int(n["full_12_players"]["size"]) == 280 and _hex(n["full_12_players"]["target_full"]).size() == 280)
	var worst := _hex(n["all_15_remote_slots"]["target_full"]).size()
	_ok("named all 15 remote slots full = 336 bytes (< 1,200)", worst == 336 and worst < 1200, "%d bytes" % worst)
	# add + remove produce a REMOVED record (mask 0x80) and a full new entity
	var ar_b := Snapshot.decode(_hex(n["add_and_remove"]["base_full"]))
	var ar_t := Snapshot.decode(_hex(n["add_and_remove"]["target_full"]))
	var bytes := ar_t.encode(ar_b)
	var has_removed := false
	var d := Snapshot.decode(bytes, ar_b)
	for s in 16:
		if ar_b.present[s] == 1 and ar_t.present[s] == 0:
			has_removed = d != null and d.present[s] == 0
	_ok("named add + remove: removed slot disappears, added slot appears", has_removed and d.same_content(ar_t))


func _quant(g: Dictionary) -> void:
	var bad := 0
	var clamp_bad := 0
	for c in g["pos_quant"]:
		Quant.clamp_count = 0
		var q := Quant.pos_to_q(float(int(c[0])) / 32.0)
		if q != int(c[1]):
			bad += 1
		if (Quant.clamp_count == 1) != bool(c[2]):
			clamp_bad += 1
	_ok("quantization: 1/8 grid, ties away from zero, clamps match Python", bad == 0 and clamp_bad == 0, "%d position cases (incl. every x.0625 tie and the +-4096 edges)" % g["pos_quant"].size())
	Quant.clamp_count = 0
	var s := Snapshot.new()
	s.snap_seq = 1
	s.set_entity(0, -4096.0, 0.0, 4095.875, 0, 0, 0, true)
	var no_clamp := Quant.clamp_count == 0
	s.set_entity(1, 4096.0, 0.0, 0.0, 0, 0, 0, true)
	_ok("-4096.0 and 4095.875 encode; 4096.0 clamps and is counted", no_clamp and Quant.clamp_count == 1 and s.ent[Snapshot.FIELDS] == 32767, "clamp_count = %d" % Quant.clamp_count)
	_ok("ties round away from zero: +0.0625 -> 1, -0.0625 -> -1", Quant.pos_to_q(0.0625) == 1 and Quant.pos_to_q(-0.0625) == -1)
	var ba := 0
	for c in g["acc_quant"]:
		if Quant.accuracy_to_q(float(c[0])) != int(c[1]):
			ba += 1
	var bg := 0
	for c in g["ang_quant"]:
		if Quant.angle_to_q(float(c[0])) != int(c[1]):
			bg += 1
	_ok("HUD quantization (accuracy u16, angle i16) matches Python", ba == 0 and bg == 0, "%d accuracy, %d angle cases" % [g["acc_quant"].size(), g["ang_quant"].size()])


func _serial() -> void:
	_ok("serial arithmetic: 0 is newer than 65535, not the reverse", Snapshot.seq_newer(0, 65535) and not Snapshot.seq_newer(65535, 0))
	_ok("serial arithmetic: equal is not newer; +32767 is newer, +32768 is not", not Snapshot.seq_newer(5, 5) and Snapshot.seq_newer(32772, 5) and not Snapshot.seq_newer(32773, 5))
	var b := _snap(65535)
	var t := _snap(0)
	t.set_entity(2, 10.0, 0.0, 10.0, 1, 2, 0, true)
	var d := Snapshot.decode(t.encode(b), b)
	_ok("a delta across the sequence wrap (65535 -> 0) decodes", d != null and d.same_content(t))


func _snap(seq: int) -> Snapshot:
	var s := Snapshot.new()
	s.snap_seq = seq
	s.server_tick = seq
	for i in s.own.size():
		s.own[i] = float(i) * 1.5
	return s


func _ack_and_ring() -> void:
	var st := PlayerState.new()
	var hud := SnapshotSender.stub_hud(st)
	var sender := SnapshotSender.new()
	var first := Snapshot.decode(sender.build(1, 0, st, hud))
	_ok("no ack yet -> full snapshot", first != null and first.kind == Snapshot.KIND_FULL)
	sender.on_ack(first.snap_seq)
	var second := Snapshot.decode(sender.build(2, 0, st, hud), first)
	_ok("acked snapshot in the ring -> delta", second != null and second.kind == Snapshot.KIND_DELTA and second.base_seq == first.snap_seq)
	# ack stuck, 40 snapshots sent: the acked one is overwritten -> full
	var old_ack := second.snap_seq
	var stale := SnapshotSender.new()
	var last := PackedByteArray()
	stale.build(1, 0, st, hud)
	stale.on_ack(1)
	for i in 40:
		last = stale.build(2 + i, 0, st, hud)
	var kind: int = Snapshot.peek(last)["kind"]
	_ok("acked snapshot 33 snapshots old -> full", kind == Snapshot.KIND_FULL, "kind %d" % kind)
	# ack 31 behind is still in the ring (ring = 32: newest + 31 older)
	var ring_edge := SnapshotSender.new()
	ring_edge.build(1, 0, st, hud)
	ring_edge.on_ack(1)
	var edge := PackedByteArray()
	for i in 31:
		edge = ring_edge.build(2 + i, 0, st, hud)
	_ok("acked snapshot 31 behind is still a delta (ring holds 32)", Snapshot.peek(edge)["kind"] == Snapshot.KIND_DELTA)
	# lost snapshot, then an ack of an OLDER one: delta against the older one decodes exactly
	var tx := SnapshotSender.new()
	var rx := SnapshotReceiver.new()
	var moving := PlayerState.new()
	var ok_all := true
	for i in 60:
		moving.pos_x += 1.25
		var bytes := tx.build(i, i, moving, SnapshotSender.stub_hud(moving))
		var lost := (i % 3 == 1)       # the client never sees every third snapshot
		if not lost:
			var got := rx.receive(bytes)
			if got == null:
				ok_all = false
			else:
				var truth := PlayerState.from_packed(got.own)
				if not truth.equals(moving):
					ok_all = false
			tx.on_ack(rx.newest_seq)
	_ok("lost snapshots, acks of older ones: every received snapshot decodes exactly", ok_all and rx.dropped_missing_baseline == 0 and rx.decoded == 40, "%d decoded, %d dropped" % [rx.decoded, rx.dropped_missing_baseline])


func _receiver() -> void:
	var st := PlayerState.new()
	var hud := SnapshotSender.stub_hud(st)
	var tx := SnapshotSender.new()
	var s1 := tx.build(1, 0, st, hud)
	tx.on_ack(1)
	var s2 := tx.build(2, 0, st, hud)               # delta against 1
	var rx := SnapshotReceiver.new()
	var r2 := rx.receive(s2)                       # baseline 1 was never received
	_ok("delta without its baseline: dropped, counted, no crash", r2 == null and rx.dropped_missing_baseline == 1 and rx.decoded == 0)
	tx.ack_snap_seq = -1
	var s3 := tx.build(3, 0, st, hud)               # full again
	var r3 := rx.receive(s3)
	_ok("the next full snapshot recovers", r3 != null and rx.newest_seq == 3 and rx.decoded == 1)
	var newer := rx.receive(tx.build(4, 0, st, hud))
	var older := rx.receive(s1)
	_ok("an older snapshot is decoded but never moves newest_seq back", older != null and rx.newest_seq == newer.snap_seq)


func _fuzz() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 424242
	var st := PlayerState.new()
	var tx := SnapshotSender.new()
	var good := tx.build(1, 0, st, SnapshotSender.stub_hud(st))
	var crashes := 0
	var nulls := 0
	for i in 5000:
		var b := good.duplicate()
		var mode := rng.randi() % 3
		if mode == 0:
			b.resize(rng.randi() % (good.size() + 1))
		elif mode == 1:
			for k in 1 + rng.randi() % 4:
				b[rng.randi() % b.size()] = rng.randi() % 256
		else:
			b = PackedByteArray()
			for k in rng.randi() % 400:
				b.append(rng.randi() % 256)
		var d := Snapshot.decode(b, null)
		if d == null:
			nulls += 1
	_ok("fuzz: 5,000 truncated / corrupted / random packets, no crash", crashes == 0, "%d rejected, %d still valid" % [nulls, 5000 - nulls])


func _wired() -> void:
	var a := _run_stream(11)
	var b := _run_stream(11)
	var c := _run_stream(12)
	_ok("determinism: two identical runs give byte-identical snapshot streams", a[0] == b[0] and a[1] == b[1], "sha256 %s... (%d snapshots)" % [a[0].substr(0, 16), a[1]])
	_ok("a different seed gives a different stream", a[0] != c[0])
	var s: Dictionary = a[2]
	_ok("wired in: client decodes every snapshot it receives and reconciles from it", s["decoded"] > 1000 and s["dropped_missing"] <= s["lost_seen"] + 2, "decoded %d, full %d, delta %d, dropped(no baseline) %d" % [s["decoded"], s["full"], s["delta"], s["dropped_missing"]])
	_ok("snapshot size at 80 ms / 2%% (no remotes): min %d / mean %.1f / max %d bytes" % [s["min"], s["mean"], s["max"]], s["max"] < 400 and s["min"] >= 126)


func _run_stream(seed_value: int) -> Array:
	var sess := Session.new(seed_value, 80.0, 0.02, false, false, false)
	for t in 4000:
		var i := Bots.input("mixed", t, sess.client.predicted)
		sess.tick_once(i[0], i[1], i[2])
	var sd := sess.server.sender
	return [sess.server.snap_hash(), sd.snapshots, {"decoded": sess.client.receiver.decoded, "full": sd.full_sent, "delta": sd.delta_sent,
		"dropped_missing": sess.client.receiver.dropped_missing_baseline, "lost_seen": sess.net.dropped[FakeNet.S2C],
		"min": sd.bytes_min, "max": sd.bytes_max, "mean": float(sd.bytes_total) / float(maxi(sd.snapshots, 1))}]


func _duck_and_acks() -> void:
	# duck_q = int(round(f * 255.0)); decode = q / 255.0; error <= 0.5 / 255.0 for every fraction
	var worst := 0.0
	for k in 2001:
		var f := float(k) / 2000.0
		worst = maxf(worst, absf(Quant.q_to_duck(Quant.duck_to_q(f)) - f))
	_ok("duck fraction round trip: error <= 0.5 / 255.0", worst <= 0.5 / 255.0 + 1.0e-12, "worst %.6f (limit %.6f)" % [worst, 0.5 / 255.0])
	_ok("duck fraction endpoints: 0.0 -> 0, 1.0 -> 255, clamped outside", Quant.duck_to_q(0.0) == 0 and Quant.duck_to_q(1.0) == 255 and Quant.duck_to_q(-3.0) == 0 and Quant.duck_to_q(7.0) == 255)
	var a := Snapshot.new()
	a.snap_seq = 1
	a.set_entity(3, 10.0, 0.0, 10.0, 0, 0, 0, true, 0.0)
	var b := Snapshot.new()
	b.snap_seq = 2
	b.set_entity(3, 10.0, 0.0, 10.0, 0, 0, 0, true, 0.5)
	var d := b.encode(a)
	_ok("a duck change alone is a 1-byte field: delta = 126 + 2 + 1 bytes", d.size() == 129, "%d bytes" % d.size())
	var back := Snapshot.decode(d, a)
	_ok("duck_q survives the delta", back != null and back.ent[3 * Snapshot.FIELDS + Snapshot.E_DUCK] == Quant.duck_to_q(0.5))
	# forged acks
	var st := PlayerState.new()
	var hud := SnapshotSender.stub_hud(st)
	var tx := SnapshotSender.new()
	tx.build(1, 0, st, hud)
	tx.on_ack(1)
	tx.build(2, 0, st, hud)
	tx.on_ack(5000)                         # never sent
	tx.on_ack(3)                            # not sent yet (newer than the newest sent)
	tx.on_ack(0xFFFF)                       # nonsense
	_ok("forged acks for never-sent seqs: ack_snap_seq unchanged, all counted", tx.ack_snap_seq == 1 and tx.acks_rejected == 3, "ack %d, rejected %d" % [tx.ack_snap_seq, tx.acks_rejected])
	var nxt := tx.build(3, 0, st, hud)
	var peek := Snapshot.peek(nxt)
	_ok("the next snapshot still deltas from a real baseline (seq 1)", peek["kind"] == Snapshot.KIND_DELTA and peek["base_seq"] == 1)
	# an ack older than the 32-snapshot window is dropped too
	for i in 40:
		tx.build(4 + i, 0, st, hud)
	var before := tx.acks_rejected
	tx.on_ack(2)
	_ok("an ack for a seq that left the sent window is dropped and counted", tx.acks_rejected == before + 1 and tx.ack_snap_seq == 1)
	var rj := tx.acks_rejected
	tx.on_ack(-1)
	tx.on_ack(-7)
	_ok("ack -1 means no ack (not counted); any other negative ack is a forged one and is counted", tx.acks_rejected == rj + 1)


func _stale_ack_recovery() -> void:
	# the client is silent for 40 snapshots: its ack leaves the 32-snapshot window; the next in-window ack must be accepted
	var st := PlayerState.new()
	var hud := SnapshotSender.stub_hud(st)
	var tx := SnapshotSender.new()
	tx.build(1, 0, st, hud)
	tx.on_ack(1)
	var kind := 0
	for i in 40:
		kind = Snapshot.peek(tx.build(2 + i, 0, st, hud))["kind"]
	_ok("ack out of the window: full snapshots are sent", kind == Snapshot.KIND_FULL)
	var newest := tx.next_seq - 1
	tx.on_ack(newest)
	_ok("... and the first valid in-window ack recovers (next snapshot is a delta)", tx.ack_snap_seq == newest and Snapshot.peek(tx.build(99, 0, st, hud))["kind"] == Snapshot.KIND_DELTA)
	# across the u16 wrap: an ack 40000 serials old must not block a valid newer one
	var tw := SnapshotSender.new()
	tw.next_seq = 100
	tw.build(1, 0, st, hud)
	tw.on_ack(100)
	tw.next_seq = (100 + 40000) & 0xFFFF
	for i in 3:
		tw.build(2 + i, 0, st, hud)
	tw.on_ack((tw.next_seq - 1) & 0xFFFF)
	_ok("ack stuck 40,000 seqs back: a valid new ack is accepted (serial arithmetic cannot order them)", tw.ack_snap_seq == ((tw.next_seq - 1) & 0xFFFF))
