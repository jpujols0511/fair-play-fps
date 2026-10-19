extends SceneTree
## Wallhack bait (Phase 5):  godot --headless --script res://tests/run_wallhack_bait.gd
## Each run is 1,280 ticks (10 s, 640 snapshots) in crouch_test_world(). "Absent" is proven from the BYTES:
## every snapshot the server sends is decoded and the slot is looked for, not read from an internal flag.

var passed := 0
var failed := 0
const TICKS := 1280


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	print("== wallhack bait: %d ticks per run ==" % TICKS)
	_bait()
	_pop_in()
	_leak_back()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


## Runs a session with the viewer standing at the origin; returns [decoded snapshots as Array of Snapshot, session].
func _run(remotes: Array, ping: float, ticks: int) -> Array:
	var s := Session.new(77, ping, 0.0, false, false, false)
	s.world = Movement.crouch_test_world()
	s.server.world = s.world
	s.client.world = s.world
	s.server.vis_enabled = true
	s.server.vis_rtt_ms = ping
	for r in remotes:
		s.add_remote(r)
	var raw: Array = []
	s.server.snapshot_tap = func(b): raw.append([s.tick, b])
	for t in ticks:
		s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
	s.server.snapshot_tap = Callable()
	var rx := SnapshotReceiver.new()
	var decoded: Array = []
	for e in raw:
		var sn := rx.receive(e[1])
		sn.server_tick = e[0] if sn != null else 0
		decoded.append(sn)
	return [decoded, s]


func _count(decoded: Array, slot: int) -> int:
	var n := 0
	for sn in decoded:
		if sn.present[slot] == 1:
			n += 1
	return n


func _bait() -> void:
	var cases := {}
	var r1 := RemotePath.make_static(1, 400.0, 0.0, false, 2)                                   # standing still behind the tall box
	var r2 := RemotePath.make_static(2, 732.0, 0.0, true, 2)                                    # crouched behind the 40-unit cover ... but the tall box is also in the way
	var out := _run([r1], 80.0, TICKS)
	_ok("1. enemy standing still behind the tall box: present in 0 of %d decoded snapshots" % out[0].size(), _count(out[0], 1) == 0 and out[0].size() == 640, "present in %d" % _count(out[0], 1))

	# 2. crouched behind the 40-unit cover, in a world with only the cover (so the cover, not the tall box, does the hiding)
	var s2 := Session.new(78, 80.0, 0.0, false, false, false)
	var cover_world: Array = [PackedFloat64Array([700.0, -100.0, 716.0, 100.0, 40.0])]
	s2.world = cover_world
	s2.server.world = cover_world
	s2.client.world = cover_world
	s2.server.vis_enabled = true
	s2.add_remote(RemotePath.make_static(2, 732.0, 0.0, true, 2))
	var raw2: Array = []
	s2.server.snapshot_tap = func(b): raw2.append(b)
	for t in TICKS:
		s2.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
	s2.server.snapshot_tap = Callable()
	var rx2 := SnapshotReceiver.new()
	var present2 := 0
	for b in raw2:
		if rx2.receive(b).present[2] == 1:
			present2 += 1
	_ok("2. enemy crouched behind the 40-unit cover: present in 0 of %d decoded snapshots" % raw2.size(), present2 == 0 and raw2.size() == 640, "present in %d" % present2)

	# 3. walking back and forth behind the tall box, never exposed (z within +-72 plus margins, box spans +-100)
	var r3 := RemotePath.make_linear(3, 400.0, -60.0, PI / 2.0, 120.0)
	var out3 := _run([r3], 80.0, TICKS)
	_ok("3. enemy walking back and forth behind the tall box, never exposed: 0 of %d" % out3[0].size(), _count(out3[0], 3) == 0, "present in %d" % _count(out3[0], 3))

	# 4. teammate behind the tall box: always sent
	var r4 := RemotePath.make_static(4, 400.0, 0.0, false, 1)
	var out4 := _run([r4], 80.0, TICKS)
	_ok("4. teammate behind the tall box: %d of %d (always sent)" % [_count(out4[0], 4), out4[0].size()], _count(out4[0], 4) == 640)

	# 5. enemy exposed in the open
	var r5 := RemotePath.make_static(5, 0.0, 400.0, false, 2)
	var out5 := _run([r5], 80.0, TICKS)
	_ok("5. enemy exposed in the open: %d of %d" % [_count(out5[0], 5), out5[0].size()], _count(out5[0], 5) == 640)

	# 6. crouch-toggling behind the 40 cover: sent while the blended sample heights (stand .. crouch by the duck fraction, with the
	# crown) have a clear ray; reference = the same rule evaluated on the server's own pose and duck fraction, tick by tick
	var r6 := RemotePath.make_stepped(6, RemotePath.Kind.CROUCH_TOGGLE, 732.0, 0.0, [])
	var s6 := Session.new(79, 80.0, 0.0, false, false, false)
	s6.world = cover_world
	s6.server.world = cover_world
	s6.client.world = cover_world
	s6.server.vis_enabled = true
	s6.add_remote(r6)
	var raw6: Array = []
	s6.server.snapshot_tap = func(b): raw6.append(b)
	for t in TICKS:
		s6.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
	s6.server.snapshot_tap = Callable()
	var rx6 := SnapshotReceiver.new()
	var got6 := 0
	for b in raw6:
		if rx6.receive(b).present[6] == 1:
			got6 += 1
	var want6 := 0
	var edges := 0
	var prev := -1
	for t in range(0, TICKS, 2):
		var p6 := r6.pose(t)
		var standing := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, p6[0], p6[1], p6[2], 0.0, 0.0, false, cover_world, 80.0 / 2000.0 + 2.0 / 128.0, 8.0, p6[7]) >= 0
		want6 += 1 if standing else 0
		if prev != -1 and (1 if standing else 0) != prev:
			edges += 1
		prev = 1 if standing else 0
	_ok("6. enemy crouch-toggling behind the 40 cover: sent in %d snapshots, reference (the same rule with the duck fraction) %d, within +-1 per edge (%d edges)" % [got6, want6, edges], absi(got6 - want6) <= edges and got6 < 640 and got6 > 0)
	s2.server.snapshot_tap = Callable()


## The first snapshot containing the enemy is sent at least 2 ticks before the first tick a margin-free,
## look-ahead-free ray is clear.
func _pop_in() -> void:
	for ping in [0.0, 80.0, 150.0]:
		var r := RemotePath.make_straight(1, 400.0, 0.0, PI / 2.0)          # starts behind the tall box, walks +z across the viewer's line
		var out := _run([r], ping, 400)
		var decoded: Array = out[0]
		var first_sent := -1
		for sn in decoded:
			if sn.present[1] == 1:
				first_sent = sn.server_tick
				break
		var first_clear := -1
		var wall: Array = Movement.crouch_test_world()
		for t in 400:
			var p := r.pose(t)
			if Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, p[0], p[1], p[2], 0.0, 0.0, false, wall, 0.0, 0.0) >= 0:
				first_clear = t
				break
		var lead := first_clear - first_sent
		_ok("no pop-in at ping %d ms: first snapshot with the enemy at tick %d, first margin-free ray clear at tick %d: lead %d ticks (>= 2)" % [int(ping), first_sent, first_clear, lead], first_sent >= 0 and first_clear > 0 and lead >= 2)


## After it hides again, REMOVED goes out within 1 snapshot after the last tick the margin rule said visible, and the client's buffer drops it the same tick.
func _leak_back() -> void:
	var r := RemotePath.make_linear(1, 400.0, 0.0, PI / 2.0, 500.0)       # starts behind the box, out to z = 500, and back behind it
	var ping := 80.0
	var s := Session.new(80, ping, 0.0, false, false, false)
	s.world = Movement.crouch_test_world()
	s.server.world = s.world
	s.client.world = s.world
	s.server.vis_enabled = true
	s.server.vis_rtt_ms = ping
	s.add_remote(r)
	var look := ping / 2000.0 + 2.0 / 128.0
	var visible_ticks: Array = []
	var absent_after := -1
	var client_gone := -1
	var saw_visible := false
	var last_rule_tick := -1
	var prev_vis := false
	var transitions := 0
	var decoded_present := {}
	s.server.snapshot_tap = func(b): pass
	for t in 900:
		s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
		if t % 2 == 0:
			var p := r.pose(t)
			var v := r.vel(t)
			var rule := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, p[0], p[1], p[2], v.x, v.y, false, s.world, look, 8.0) >= 0
			if rule and absent_after < 0:
				last_rule_tick = t
			if prev_vis and not rule and absent_after < 0:
				transitions += 1
				absent_after = t
			prev_vis = rule
		if saw_visible and client_gone < 0 and s.client.remote_visible[1] == 0:
			client_gone = t
		if s.client.remote_visible[1] == 1:
			saw_visible = true
	s.server.snapshot_tap = Callable()
	# the snapshot that first leaves it out is at `absent_after` (a snapshot tick, decided by the same rule); the client drops it
	# on arrival: absent_after + one-way 6 ticks, the same tick it decodes
	_ok("leak back: REMOVED goes out on the first snapshot after the last tick the rule said visible (tick %d) and the client buffer drops it on arrival (tick %d = %d + 6)" % [absent_after, client_gone, absent_after],
		absent_after > 0 and client_gone == absent_after + 6, "last visible-by-rule snapshot tick %d" % last_rule_tick)
