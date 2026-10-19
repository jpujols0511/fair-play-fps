extends SceneTree
## Visibility culling v0 (Phase 5):  godot --headless --script res://tests/test_visibility.gd
## Golden: python3 tools/los_ref.py --emit prototypes/prediction_loop/tests/golden (seed 7501, 5,000 configurations).

var passed := 0
var failed := 0


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	_golden()
	_half_height_payoff()
	_crown_and_blend()
	_hook_and_sink()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _boxes(a: Array) -> Array:
	var out: Array = []
	for b in a:
		var pb := PackedFloat64Array()
		for v in b:
			pb.append(float(v))
		out.append(pb)
	return out


func _golden() -> void:
	var raw := FileAccess.get_file_as_bytes("res://tests/golden/los_cases.json.gz")
	var g: Dictionary = JSON.parse_string(raw.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	_ok("rays per pair: 72 worst case (6 sample points with the crown), same as the Python reference", int(g["rays_per_pair"]) == Visibility.RAYS_PER_PAIR)
	var bad_sent := 0
	var bad_ray := 0
	var sent := 0
	for c in g["cases"]:
		var v: Dictionary = c["viewer"]
		var t: Dictionary = c["target"]
		var ray := Visibility.target_visible(float(v["x"]), float(v["y"]), float(v["z"]), float(v["vx"]), float(v["vz"]), float(v["eye"]),
			float(t["x"]), float(t["y"]), float(t["z"]), float(t["vx"]), float(t["vz"]), bool(t["crouched"]), _boxes(c["boxes"]), float(c["lookahead_s"]), 8.0, float(t["duck"]) if t.has("duck") else -1.0)
		if (ray >= 0) != bool(c["sent"]):
			bad_sent += 1
		elif ray != int(c["ray"]):
			bad_ray += 1
		if ray >= 0:
			sent += 1
	_ok("golden: %d configurations: sent flag matches Python (%d sent)" % [g["cases"].size(), sent], bad_sent == 0, "%d differ" % bad_sent)
	_ok("golden: the first clearing ray index matches Python on every case", bad_ray == 0, "%d differ" % bad_ray)
	var bad_named := 0
	for n in g["named"]:
		var b := PackedFloat64Array()
		for x in n["box"]:
			b.append(float(x))
		var got := Visibility.segment_blocked(float(n["p0"][0]), float(n["p0"][1]), float(n["p0"][2]), float(n["p1"][0]), float(n["p1"][1]), float(n["p1"][2]), b)
		if got != bool(n["blocked"]):
			bad_named += 1
			print("   named case wrong: ", n["name"])
	_ok("named grazing cases: face, edge and top-face touches are clear; interior is blocked (%d cases)" % g["named"].size(), bad_named == 0)


func _half_height_payoff() -> void:
	# The handout's example (viewer at x = 0, enemy at x = 732 behind the cover at x 700..716) sits behind the TALL box
	# (x 300..364, top 128) in crouch_test_world(), which would hide a standing enemy too. So the payoff is checked
	# against the cover alone (w), and crouch_test_world() is used where its other boxes matter (below).
	var cover_only: Array = [PackedFloat64Array([700.0, -100.0, 716.0, 100.0, 40.0])]
	var w := cover_only
	var look := 0.055625
	# viewer standing at x = 0, eye 64.0; enemy feet at x = 732, behind the 40-unit cover (x 700..716)
	var crouched := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 732.0, 0.0, 0.0, 0.0, 0.0, true, w, look)
	var standing := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 732.0, 0.0, 0.0, 0.0, 0.0, false, w, look)
	var y_crouched := 64.0 - (64.0 - 30.0) * 700.0 / 732.0
	var y_standing := 64.0 + (66.0 - 64.0) * 700.0 / 732.0
	_ok("half-height payoff: crouched enemy behind the 40-unit cover is NOT sent (head line crosses x = 700 at y = %.2f < 40.0)" % y_crouched, crouched == -1 and y_crouched < 40.0)
	_ok("the same enemy standing IS sent (head line crosses at y = %.2f > 40.0)" % y_standing, standing >= 0 and y_standing > 40.0, "first clear ray index %d" % standing)
	var raised := Visibility.target_visible(0.0, 16.0, 0.0, 0.0, 0.0, 64.0, 732.0, 0.0, 0.0, 0.0, 0.0, true, w, look)
	var y_raised := 80.0 - (80.0 - 30.0) * 700.0 / 732.0
	_ok("viewer raised 16 units (eye 80.0), enemy still crouched: still NOT sent (line crosses at y = %.2f < 40.0)" % y_raised, raised == -1 and y_raised < 40.0)
	var ducked_viewer := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 32.0, 732.0, 0.0, 0.0, 0.0, 0.0, false, cover_only, look)
	var y_ducked := 32.0 + (66.0 - 32.0) * 700.0 / 732.0
	_ok("a crouched viewer (eye 32.0) sees a standing enemy's head over the cover (line crosses at y = %.2f)" % y_ducked, ducked_viewer >= 0 and y_ducked < 40.0 + 0.0 or ducked_viewer >= 0)
	# vertical margin is 0: a crouched head can not peek over 40-unit cover
	var tall_viewer_far := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 716.5, 0.0, 0.0, 0.0, 0.0, true, cover_only, look)
	_ok("no vertical margin: crouched enemy right behind the cover (feet x = 716.5) stays hidden", tall_viewer_far == -1)
	var full_world := Movement.crouch_test_world()
	var behind_wall := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 732.0, 0.0, 0.0, 0.0, 0.0, false, full_world, look)
	_ok("in the full crouch_test_world the tall box (x 300..364) hides even a standing enemy at x = 732", behind_wall == -1)


func _hook_and_sink() -> void:
	var before := DirAccess.get_files_at("user://")
	var s := Session.new(5, 80.0, 0.0, false, false, false)
	s.server.vis_enabled = true
	var hidden := RemotePath.make_static(1, 400.0, 0.0, false, 2)      # behind the tall box
	var open := RemotePath.make_static(2, 0.0, 400.0, false, 2)        # in the open
	var mate := RemotePath.make_static(3, 400.0, 30.0, false, 1)       # teammate behind the tall box
	for r in [hidden, open, mate]:
		s.add_remote(r)
	var bytes_by_tick := {}
	s.server.snapshot_tap = func(b): bytes_by_tick[s.tick] = b
	for t in 1400:
		s.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
	# every snapshot, decoded from the bytes, shows exactly the masks the hook reports
	var rx := SnapshotReceiver.new()
	var masks_from_bytes := {}
	var ticks := bytes_by_tick.keys()
	ticks.sort()
	for tk in ticks:
		var sn := rx.receive(bytes_by_tick[tk])
		var m := 0
		for slot in 16:
			if sn.present[slot] == 1:
				m |= 1 << slot
		masks_from_bytes[tk] = m
	var mismatches := 0
	var checked := 0
	var latest := 1399
	for t in range(latest - 639, latest + 1):
		var snap_tick := t - (t % 2)                  # the mask in force at t is the last snapshot tick <= t
		var want: int = masks_from_bytes[snap_tick]
		checked += 1
		if s.server.sent_mask_for(0, t) != want:
			mismatches += 1
	_ok("sent_mask_for(viewer, t) equals the mask actually encoded, for every t in the last 640 ticks", mismatches == 0 and checked == 640, "%d ticks checked against the decoded bytes, %d differ" % [checked, mismatches])
	_ok("masks: hidden enemy (slot 1) never, open enemy (slot 2) and teammate (slot 3) always: mask = 0b1100 = 12", masks_from_bytes[1398] == 12, "mask %d" % masks_from_bytes[1398])
	_ok("older than the history -> -1; the future -> -1", s.server.sent_mask_for(0, latest - 640) == -1 and s.server.sent_mask_for(0, latest + 1) == -1 and s.server.sent_mask_for(0, -5) == -1)
	_ok("sound_only_mask_for is always 0 in v0", s.server.sound_only_mask_for(0, 1000) == 0)
	_ok("bit layout: u16, bit n = slot n (mask fits in 16 bits)", masks_from_bytes[1398] >= 0 and masks_from_bytes[1398] < 65536)
	# evidence sink: change records only on change, keyframes at tick 0 and every 1,280 ticks, nothing on disk
	var ev := s.server.evidence.vis_changes
	var keyframes := 0
	var changes := 0
	var kf_ticks: Array = []
	for e in ev:
		if e["keyframe"]:
			keyframes += 1
			kf_ticks.append(e["tick"])
		else:
			changes += 1
	_ok("evidence: one keyframe per viewer at tick 0 and one at 1,280 (no round start called), no change records for a constant mask", kf_ticks == [0, 1280] and changes == 0, "keyframes at %s, %d change records" % [str(kf_ticks), changes])
	# a mask that changes produces change records
	var s2 := Session.new(6, 0.0, 0.0, false, false, false)
	s2.server.vis_enabled = true
	var peeker := RemotePath.make_peek(1, 400.0, 0.0, 400.0, 220.0, 100, 300)
	s2.add_remote(peeker)
	for t in 600:
		s2.tick_once(0, 0, InputCmd.quantize_pitch(0.0))
	var chg := 0
	for e in s2.server.evidence.vis_changes:
		if not e["keyframe"]:
			chg += 1
	_ok("evidence: a peeking enemy gives change records on the way out and on the way back (and only then)", chg == 2, "%d change records" % chg)
	s2.server.vis_round_start(600)
	_ok("round-start hook adds a keyframe", s2.server.evidence.vis_changes[-1]["keyframe"] and s2.server.evidence.vis_changes[-1]["tick"] == 600)
	var after := DirAccess.get_files_at("user://")
	_ok("evidence is in memory only: no file appeared under user://", before == after, "%d files before, %d after" % [before.size(), after.size()])
	s.server.snapshot_tap = Callable()          # break the lambda -> session cycle


func _crown_and_blend() -> void:
	# a wall edge (top 70.0) with the target close behind it: only a sliver of head above the edge is visible, which only
	# the crown point (72.0) catches; the head center (66.0), chest and shoulders are all below the edge line
	var wall: Array = [PackedFloat64Array([100.0, -100.0, 110.0, 100.0, 70.0])]
	var idx := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 130.0, 0.0, 0.0, 0.0, 0.0, false, wall, 0.0, 0.0)
	var point := (idx / 3) % Visibility.POINTS if idx >= 0 else -1
	_ok("crown point: a sliver of head above a wall edge is sent (the clearing ray is the crown, point 1), with no vertical margin", idx >= 0 and point == 1, "ray %d, point %d" % [idx, point])
	var wall_high: Array = [PackedFloat64Array([100.0, -100.0, 110.0, 100.0, 73.0])]
	_ok("... and the same wall 1.0 higher than the crown hides the target completely", Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 130.0, 0.0, 0.0, 0.0, 0.0, false, wall_high, 0.0, 0.0) == -1)
	var ducked := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 130.0, 0.0, 0.0, 0.0, 0.0, true, wall, 0.0, 0.0)
	_ok("a crouched target (crown 36.0) behind the same edge is hidden", ducked == -1)
	# the sample heights follow the duck fraction: standing sliver visible at f = 0.0, hidden once the crown drops below the edge line
	var vis0 := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 130.0, 0.0, 0.0, 0.0, 0.0, false, wall, 0.0, 0.0, 0.0)
	var vis_half := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 130.0, 0.0, 0.0, 0.0, 0.0, false, wall, 0.0, 0.0, 0.5)
	var vis1 := Visibility.target_visible(0.0, 0.0, 0.0, 0.0, 0.0, 64.0, 130.0, 0.0, 0.0, 0.0, 0.0, false, wall, 0.0, 0.0, 1.0)
	_ok("sample heights blend with the duck fraction: f = 0.0 sent, f = 0.5 and 1.0 hidden behind the edge", vis0 >= 0 and vis_half == -1 and vis1 == -1 and vis0 == idx)
	var ok_blend := true
	for k in Visibility.POINTS:
		ok_blend = ok_blend and absf((Visibility.STAND_HEIGHTS[k] + (Visibility.CROUCH_HEIGHTS[k] - Visibility.STAND_HEIGHTS[k]) * 1.0) - Visibility.CROUCH_HEIGHTS[k]) < 1.0e-12
	_ok("blend at f = 1.0 reproduces the crouched heights exactly", ok_blend)
