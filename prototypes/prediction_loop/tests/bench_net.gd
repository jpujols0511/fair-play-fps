extends SceneTree
## Netcode performance for 12 players (Phase 9):  godot --headless --script res://tests/bench_net.gd [-- --quick]
## 1,000 warm-up iterations, then 10,000 timed (Time.get_ticks_usec). Reports median / p99 / max and PASS / FAIL
## against the PROPOSED budgets (handout Phase 9). A FAIL is only a discussion trigger; nothing is ported.
## --quick: 100 warm-up and 1,000 timed, for development.

var warm := 1000
var runs := 10000
var results: Array = []
var fails := 0
const PLAYERS := 12
const REMOTES := 11


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	if "--quick" in OS.get_cmdline_user_args():
		warm = 100
		runs = 1000
	print("Godot ", Engine.get_version_info()["string"])
	print("iterations: %d warm-up, %d timed%s" % [warm, runs, "  (QUICK)" if runs < 10000 else ""])
	_encode_one()
	_encode_all()
	_decode()
	_interpolate()
	_visibility()
	_server_tick()
	_s8()
	print("\n==================== SUMMARY ====================")
	for r in results:
		print(r)
	print("%d of %d lines passed" % [results.size() - fails, results.size()])
	for r in results:
		if r.begins_with("FAIL"):
			print("Rust discussion trigger: ", r.substr(6).split("  ")[0], ", ", r.substr(r.find("measured")))
	quit(0)             # a FAIL is a measurement, not a crash; the PR text carries the verdict


# ---- helpers ----

func _stats(a: PackedFloat64Array) -> Array:
	var b := a.duplicate()
	b.sort()
	return [b[b.size() / 2], b[mini(int(ceil(0.99 * float(b.size()))) - 1, b.size() - 1)], b[b.size() - 1]]


## budgets: [median_ms, p99_ms, max_ms], 0 or negative = not budgeted
func _report(name: String, us: PackedFloat64Array, budgets: Array) -> void:
	var st := _stats(us)
	var med: float = st[0] / 1000.0
	var p99: float = st[1] / 1000.0
	var mx: float = st[2] / 1000.0
	var ok := true
	var parts: Array = []
	if budgets[0] > 0.0:
		ok = ok and med <= budgets[0]
		parts.append("median <= %.4f" % budgets[0])
	if budgets[1] > 0.0:
		ok = ok and p99 <= budgets[1]
		parts.append("p99 <= %.4f" % budgets[1])
	if budgets[2] > 0.0:
		ok = ok and mx <= budgets[2]
		parts.append("max <= %.4f" % budgets[2])
	var line := "%s  %s  median %.4f ms, p99 %.4f ms, max %.4f ms  (budget %s)" % ["PASS" if ok else "FAIL", name, med, p99, mx, ", ".join(parts)]
	if not ok:
		line += "  measured median %.4f ms vs budget %s" % [med, ", ".join(parts)]
		fails += 1
	results.append(line)
	print(line)


func _fill_entities(sc: Snapshot, viewer: int, t: int) -> void:
	sc.clear_entities()
	for i in PLAYERS:
		if i == viewer:
			continue
		var f := float(t) * 0.05 + float(i)
		sc.set_entity(i, 100.0 * sin(f), 0.0, 100.0 * cos(f * 0.7), (t * 37 + i * 911) & 0xFFFF, 32768, i & 1, true)


func _own(t: int) -> PlayerState:
	var s := PlayerState.new()
	s.pos_x = 3.0 * sin(float(t) * 0.01)
	s.pos_z = 2.0 * float(t % 100)
	s.vel_x = 250.0
	return s


# ---- 1. encode one snapshot ----

func _encode_one() -> void:
	var own := _own(0)
	var hud := [Quant.accuracy_to_q(0.0054), 0, 0, 3]
	# delta: acked every time, 11 moving remotes
	var sd := SnapshotSender.new()
	var us := PackedFloat64Array()
	for i in warm + runs:
		_fill_entities(sd.scratch, 0, i)
		own.pos_x += 3.0
		var t0 := Time.get_ticks_usec()
		var b := sd.build(i * 2, i, own, hud)
		var dt := float(Time.get_ticks_usec() - t0)
		sd.on_ack(sd.next_seq - 1 if sd.next_seq > 0 else 65535)
		if i >= warm:
			us.append(dt)
	_report("1a encode one delta snapshot (11 remotes, all moving, own block + HUD)", us, [0.04, -1.0, -1.0])
	var sf := SnapshotSender.new()
	us = PackedFloat64Array()
	for i in warm + runs:
		_fill_entities(sf.scratch, 0, i)
		var t0 := Time.get_ticks_usec()
		var b := sf.build(i * 2, i, own, hud)
		var dt := float(Time.get_ticks_usec() - t0)
		if i >= warm:
			us.append(dt)
	_report("1b encode one full snapshot (never acked)", us, [-1.0, -1.0, -1.0])
	print("   delta bytes: %d (last), full bytes: %d (last)" % [sd.bytes_max, sf.bytes_max])


# ---- 2. encode for all 12 clients ----

func _encode_all() -> void:
	var senders: Array = []
	for k in PLAYERS:
		senders.append(SnapshotSender.new())
	var own := _own(0)
	var hud := [Quant.accuracy_to_q(0.0054), 0, 0, 3]
	var us := PackedFloat64Array()
	for i in warm + runs:
		var t0 := Time.get_ticks_usec()
		for k in PLAYERS:
			var s: SnapshotSender = senders[k]
			_fill_entities(s.scratch, k, i)
			s.build(i * 2, i, own, hud)
		var dt := float(Time.get_ticks_usec() - t0)
		for k in PLAYERS:
			senders[k].on_ack(senders[k].next_seq - 1)
		if i >= warm:
			us.append(dt)
	_report("2 encode for all 12 clients on one snapshot tick (own entity set each; includes filling entities)", us, [0.5, 1.0, -1.0])


# ---- 3. decode ----

func _decode() -> void:
	var sender := SnapshotSender.new()
	var own := _own(0)
	var hud := [Quant.accuracy_to_q(0.0054), 0, 0, 3]
	var chain: Array = []
	for i in warm + runs:
		_fill_entities(sender.scratch, 0, i)
		own.pos_x += 3.0
		chain.append(sender.build(i * 2, i, own, hud))
		sender.on_ack(sender.next_seq - 1)
	var rx := SnapshotReceiver.new()
	var us := PackedFloat64Array()
	for i in warm + runs:
		var t0 := Time.get_ticks_usec()
		var s := rx.receive(chain[i])
		var dt := float(Time.get_ticks_usec() - t0)
		if s == null:
			print("FAIL decode returned null at %d" % i)
		if i >= warm:
			us.append(dt)
	_report("3 decode one delta snapshot on the client (incl. baseline lookup)", us, [0.05, -1.0, -1.0])


# ---- 4. interpolate ----

func _interpolate() -> void:
	var bufs: Array = []
	for k in REMOTES:
		bufs.append(InterpBuffer.new())
	var fed := -1
	var us := PackedFloat64Array()
	for i in warm + runs:
		var render := float(i) * 0.5 + 40.0              # a render time that advances half a snapshot per client tick... 
		while fed < int(render) + 8:
			fed += 2
			for k in REMOTES:
				var f := float(fed) * 0.05 + float(k)
				bufs[k].insert(fed, 100.0 * sin(f), 0.0, 100.0 * cos(f * 0.7), (fed * 37 + k * 911) & 0xFFFF, 32768, k & 1, 1, false)
		var t0 := Time.get_ticks_usec()
		for k in REMOTES:
			(bufs[k] as InterpBuffer).sample(render)
		var dt := float(Time.get_ticks_usec() - t0)
		if i >= warm:
			us.append(dt)
	_report("4 interpolate 11 remotes for one client tick (bracket search + lerp + shortest-arc yaw)", us, [0.05, -1.0, -1.0])


# ---- 5. visibility ----

func _vis_pass(world: Array, iterations: int) -> PackedFloat64Array:
	var us := PackedFloat64Array()
	var visible := 0
	for i in warm + iterations:
		var t0 := Time.get_ticks_usec()
		for v in PLAYERS:
			var vz := -550.0 + 100.0 * float(v)
			for o in PLAYERS:
				if o == v:
					continue
				var oz := -550.0 + 100.0 * float(o)
				if Visibility.target_visible(-200.0, 0.0, vz, 0.0, 0.0, 64.0, 200.0, 0.0, oz, 0.0, 0.0, false, world, 0.02, 8.0) >= 0:
					visible += 1
		var dt := float(Time.get_ticks_usec() - t0)
		if i >= warm:
			us.append(dt)
	if visible != 0:
		print("   NOTE: %d targets were visible; the worst case needs nothing visible" % visible)
	return us


func _visibility() -> void:
	# a wall between the two groups: every one of the 60 rays per pair is tested and blocked
	var wall := PackedFloat64Array([-20.0, -2000.0, 20.0, 2000.0, 2000.0])
	var w1: Array = [wall]
	var w10: Array = [wall]
	for k in 9:
		w10.append(PackedFloat64Array([1000.0 + 100.0 * float(k), -50.0, 1050.0 + 100.0 * float(k), 50.0, 128.0]))
	var n := mini(runs, 2000)       # each iteration is 132 pairs x 60 rays
	_report("5a visibility 12 viewers x 11 enemies, worst case (nothing visible), 1-box world, %d timed iterations" % n, _vis_pass(w1, n), [1.0, 2.0, -1.0])
	_report("5b visibility 12 x 11 worst case, 10-box world, %d timed iterations" % n, _vis_pass(w10, n), [1.0, 2.0, -1.0])


# ---- 6. full server tick ----

func _server_tick() -> void:
	var st := ServerTick.new()
	st.world = Movement.crouch_test_world()
	for k in 10:
		st.add_bot(k, 2, Waypoints.load_route(Waypoints.NAMES[k % Waypoints.NAMES.size()]))
	var humans: Array = [st.add_client(10, 1), st.add_client(11, 1)]
	var shot_calls := [0]
	var stub := CountingShots.new()
	stub.counter = shot_calls
	st.shots = stub
	var seqs := [1, 1]
	var recent: Array = [[], []]
	var us := PackedFloat64Array()
	var snap_bytes := 0
	for i in warm + runs:
		var t0 := Time.get_ticks_usec()
		# step 1 for the two network clients: build and parse a 3-command datagram like the transport would hand over
		for h in 2:
			var cs: ClientSlot = humans[h]
			var inp := Bots.input("mixed", i, cs.state)
			var buttons: int = inp[0] | (InputCmd.BTN_ATTACK if i % 16 == 0 else 0)
			var c := InputCmd.make(seqs[h], i, buttons, inp[1], inp[2])
			c.view_tick = float(i)
			seqs[h] += 1
			recent[h].append(c)
			if recent[h].size() > 3:
				recent[h].pop_front()
			var parsed := Packet.parse(Packet.encode_input(cs.sender.next_seq - 1, 0, recent[h]))
			cs.enqueue_net(parsed["cmds"], parsed["ack_snap_seq"], parsed["ack_delay_ticks"], st.tick, st.evidence)
		var out := st.step()
		var dt := float(Time.get_ticks_usec() - t0)
		for k in out:
			snap_bytes += out[k].size()
		if i >= warm:
			us.append(dt)
	_report("6 full server tick, 12 players (10 bots + 2 in-process clients; drain, movement, lag-comp push, shot stub, even-tick visibility + 12 encodes)", us, [2.0, 3.9, 7.8125])
	print("   shots reached the stub: %d; snapshot bytes per client per snapshot: %.1f" % [shot_calls[0], float(snap_bytes) / float((warm + runs) / 2 * PLAYERS)])


class CountingShots extends ShotProcessor:
	var counter: Array
	func process_shot(_ctx: Dictionary) -> void:
		counter[0] += 1


# ---- 7. S8 rerun ----

func _s8() -> void:
	var w := Movement.default_world()
	var c := Client.new(w)
	for t in 2000:
		var i := Bots.input("bhop", t, c.predicted)
		c.predict(i[0], i[1], i[2], t)
	var base := c.predicted.duplicate_state()
	var c2 := Client.new(w)
	c2.predicted.copy_from(base)
	for t in 32:
		var i := Bots.input("bhop", 2000 + t, c2.predicted)
		c2.predict(i[0], i[1], i[2], 2000 + t)
	for k in 100:
		c2._replay_from(0, base)
	var us := PackedFloat64Array()
	for r in 1000:
		var t0 := Time.get_ticks_usec()
		c2._replay_from(0, base)
		us.append(float(Time.get_ticks_usec() - t0))
	_report("7 S8 rerun: replay 32 ticks (1,000 runs)", us, [1.0, -1.0, -1.0])
