extends SceneTree
## Bot input driver (Phase 8):  godot --headless --script res://tests/test_bots.gd
## Bots are slots whose commands skip the transport and nothing else (specs/bot_spec_v0.0_skeleton.md rules 2, 3, 4, 8).

var passed := 0
var failed := 0
const TICKS := 3840


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	_waypoint_semantics()
	_routes_determinism()
	_crouch_overhang()
	_same_path()
	_no_hidden_info()
	_validation_ten_bots()
	_cover_peek_flips()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _server_with(route_names: Array, record := false) -> ServerTick:
	var st := ServerTick.new()
	var worlds := false
	for k in route_names.size():
		var r := Waypoints.load_route(route_names[k])
		if r["world"] == "crouch":
			worlds = true
		var d := st.add_bot(k, 2, r)
		d.record = record
	st.world = Movement.crouch_test_world() if worlds else Movement.default_world()
	return st


func _run(st: ServerTick, ticks: int) -> void:
	for i in ticks:
		st.step()


func _waypoint_semantics() -> void:
	var route := Waypoints.normalize({"name": "t", "spawn": [0.0, 0.0], "loop": false, "waypoints": [
		{"x": 0.0, "z": -300.0, "jump": true}, {"x": 0.0, "z": -600.0, "duck": true, "wait_ticks": 5}, {"x": 0.0, "z": -300.0}]})
	var st := ServerTick.new()
	var d := st.add_bot(0, 2, route)
	d.record = true
	_run(st, 700)
	var jumps := 0
	var fresh := true
	var jump_ticks: Array = []
	for c: InputCmd in d.cmd_log:
		if (c.buttons & InputCmd.BTN_JUMP) != 0:
			jumps += 1
			jump_ticks.append(c.tick)
			if c.tick > 0 and (d.cmd_log[c.tick - 1].buttons & InputCmd.BTN_JUMP) != 0:
				fresh = false
	_ok("default arrive_radius is 16.0 when the route omits it", route["waypoints"][0]["arrive_radius"] == 16.0)
	_ok("BTN_JUMP is a fresh press: exactly one command carries it, the previous tick does not", jumps == 1 and fresh, "jump at tick %s" % [jump_ticks])
	# wait_ticks: 5 commands without FORWARD at waypoint 1, with DUCK held; DUCK stays until the next waypoint is reached
	var idle_ticks: Array = []
	for c: InputCmd in d.cmd_log:
		if (c.buttons & InputCmd.BTN_FORWARD) == 0:
			idle_ticks.append(c.tick)
	var first_idle: int = idle_ticks[0] if not idle_ticks.is_empty() else -1
	var all_ducked := true
	for t in range(first_idle, first_idle + 5):
		if (d.cmd_log[t].buttons & InputCmd.BTN_DUCK) == 0:
			all_ducked = false
	_ok("wait_ticks 5: five commands without FORWARD, DUCK held", idle_ticks.size() >= 5 and idle_ticks[4] == first_idle + 4 and all_ducked, "idle from tick %d" % first_idle)
	_ok("a route without loop finishes and stands still", d.finished and (d.cmd_log[d.cmd_log.size() - 1].buttons & InputCmd.BTN_FORWARD) == 0)


func _routes_determinism() -> void:
	for rn in Waypoints.NAMES:
		var hexes: Array = []
		var reached_all := true
		var steps_ok := true
		for run in 2:
			var st := _server_with([rn])
			_run(st, TICKS)
			var d: BotDriver = st.bots[0]
			hexes.append((st.slots[0] as ClientSlot).state.hex())
			var seen := {}
			for i in d.reached:
				seen[i] = true
			if seen.size() != d.route["waypoints"].size():
				reached_all = false
			if (st.slots[0] as ClientSlot).lost_seqs.size() != 0 or st.evidence.input_rejects.size() != 0:
				steps_ok = false
		_ok("route %s: reaches every waypoint within 3,840 ticks" % rn, reached_all)
		_ok("route %s: final PlayerState.hex() identical across two runs; 0 rejects, 0 repeats" % rn, hexes[0] == hexes[1] and steps_ok, hexes[0].substr(0, 24) + "...")


func _crouch_overhang() -> void:
	var st := _server_with(["crouch_overhang"])
	var s := (st.slots[0] as ClientSlot).state
	var under := 0
	var under_ducked := 0
	var laps := 0
	var was_under := false
	for i in TICKS:
		st.step()
		var crouched := (Movement.stance_for_hitbox(s) & 1) == 1
		if s.pos_x > 516.0 and s.pos_x < 584.0 and s.pos_y < 1.0:
			under += 1
			if crouched:
				under_ducked += 1
			was_under = true
		elif was_under and (s.pos_x > 616.0 or s.pos_x < 484.0):
			laps += 1
			was_under = false
	_ok("K7 crouch_overhang: every tick spent under the 40-high overhang (x 516 to 584) is ducked", under > 0 and under == under_ducked, "%d of %d ticks" % [under_ducked, under])
	_ok("K7 crouch_overhang: passes under and out again (laps >= 4 in 3,840 ticks)", laps >= 4, "%d passes" % laps)
	# unducks after clearing: sample the command stream at the waypoint that ends the duck
	var st2 := _server_with(["crouch_overhang"], true)
	var s2 := (st2.slots[0] as ClientSlot).state
	var released_ok := false
	for i in TICKS:
		st2.step()
		var cmd: InputCmd = st2.bots[0].cmd_log[i]
		if (cmd.buttons & InputCmd.BTN_DUCK) == 0 and s2.pos_x > 616.0 and (Movement.stance_for_hitbox(s2) & 1) == 0:
			released_ok = true
			break
	_ok("K7 crouch_overhang: after clearing the overhang DUCK is released and the stance is standing again", released_ok)


## Same input stream through the network path: encode_input -> parse -> enqueue_net must give bit-identical server states.
func _same_path() -> void:
	var route := Waypoints.load_route("jump_onto_step")
	var a := ServerTick.new()
	var d := a.add_bot(0, 2, route)
	d.record = true
	_run(a, TICKS)
	var b := ServerTick.new()
	var net := b.add_client(0, 2)
	var sp: Array = route["spawn"]
	net.state.pos_x = sp[0]
	net.state.pos_z = sp[1]
	var identical := true
	var first_diff := -1
	var hist: Array = []
	for t in TICKS:
		var group: Array = []
		for k in range(maxi(t - 2, 0), t + 1):
			group.append(d.cmd_log[k])
		var parsed := Packet.parse(Packet.encode_input(0, 0, group))
		net.enqueue_net(parsed["cmds"], 0, 0, t, b.evidence)
		b.step()
		if t % 128 == 127 or t == TICKS - 1:
			hist.append(t)
	var ha := (a.slots[0] as ClientSlot).state.hex()
	var hb := net.state.hex()
	_ok("same path: bot stream and the identical stream over encode_input/parse/enqueue_net give a bit-identical state after 3,840 ticks", ha == hb, ha.substr(0, 24) + "...")
	_ok("same path: same executed count, no repeats, no rejects on either side", (a.slots[0] as ClientSlot).executed_total == net.executed_total and net.lost_seqs.size() == 0 and b.evidence.input_rejects.size() == 0 and a.evidence.input_rejects.size() == 0, "%d commands" % net.executed_total)
	# state at every 128th tick, replayed in lockstep
	var a2 := ServerTick.new()
	a2.add_bot(0, 2, Waypoints.load_route("jump_onto_step"))
	var b2 := ServerTick.new()
	var net2 := b2.add_client(0, 2)
	net2.state.pos_x = sp[0]
	net2.state.pos_z = sp[1]
	var lock := true
	for t in TICKS:
		net2.enqueue_net([d.cmd_log[t]], 0, 0, t, b2.evidence)
		a2.step()
		b2.step()
		if t % 128 == 0 and (a2.slots[0] as ClientSlot).state.hex() != net2.state.hex():
			lock = false
	_ok("same path: states equal every 128 ticks in lockstep (30 checkpoints)", lock)


func _no_hidden_info() -> void:
	var st := _server_with(["cover_peek", "step_loop"])
	var d: BotDriver = st.bots[0]
	var own: ClientSlot = st.slots[0]
	var leaks: Array = []
	for prop in d.get_property_list():
		if prop["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE == 0:
			continue
		var v = d.get(prop["name"])
		if v is Object and v != own:
			leaks.append(prop["name"])
		if v is Array and prop["name"] != "cmd_log" and prop["name"] != "reached":
			for e in v:
				if e is Object:
					leaks.append(prop["name"])
	_ok("the driver references no object except its own slot (no ServerTick, no other slots)", leaks.is_empty(), str(leaks))
	var src := FileAccess.get_file_as_string("res://server/bots/bot_driver.gd")
	var bad: Array = []
	for word in ["slots[", "ServerTick", "sent_mask", "Visibility", "lagcomp", "teams"]:
		if src.contains(word):
			bad.append(word)
	_ok("bot_driver.gd source never mentions server internals", bad.is_empty(), str(bad))


func _validation_ten_bots() -> void:
	var names: Array = []
	for k in 10:
		names.append(Waypoints.NAMES[k % Waypoints.NAMES.size()])
	var st := _server_with(names)
	_run(st, 7680)
	var rej := st.evidence.input_rejects.size()
	var lost := 0
	var dup := 0
	var over := 0
	var rate := 0
	var done := 0
	for i in 10:
		var s: ClientSlot = st.slots[i]
		lost += s.lost_seqs.size()
		dup += s.duplicates
		over += s.abuse_dropped
		rate += s.resyncs
		done += s.executed_total
	_ok("10 bots x 7,680 ticks: 0 rejects", rej == 0, "%d rejects, %d duplicates, %d abuse drops, %d resyncs, %d repeats" % [rej, dup, over, rate, lost])
	_ok("10 bots x 7,680 ticks: every command executed exactly once", done == 76800, "%d executed" % done)


## cover_peek against the blended-height visibility rule (CD-r2 crown + duck fraction). The viewer stands at (400, -300), a spot
## where a fully ducked bot behind the 40-unit cover is hidden even with the crown point and the 8.0 lateral margin. A bot that is
## only half ducked (crown 72.0 - 36.0 f above the cover line) IS visible: it is sent until the fraction reaches ~1.0, so the bot
## drops out of the mask only for the tail of each 64-tick duck phase (the 0.4 s duck transition takes ~51 ticks).
func _cover_peek_flips() -> void:
	var st := ServerTick.new()
	st.world = Movement.crouch_test_world()
	var viewer := st.add_client(0, 1)
	viewer.state.pos_x = 400.0
	viewer.state.pos_z = -300.0
	st.add_bot(1, 2, Waypoints.load_route("cover_peek"))
	var bot: ClientSlot = st.slots[1]
	var flips := 0
	var prev := -1
	var mismatches := 0
	var full_duck_hidden := true
	var stand_visible := true
	var half_visible := 0
	var full_duck_seen := 0
	var look := (viewer.rtt_ticks * 1000.0 / Movement.TICK_RATE if viewer.rtt_ticks >= 0.0 else 0.0) / 2000.0 + float(NetConfig.SNAPSHOT_EVERY_TICKS) / Movement.TICK_RATE
	for i in 1280:
		st.step()
		if (st.tick - 1) % NetConfig.SNAPSHOT_EVERY_TICKS == 0:
			var t := st.tick - 1
			var sent := (st.sent_mask_for(0, t) >> 1) & 1
			var f := Movement.duck_fraction(bot.state)
			var rule := 1 if Visibility.target_visible(viewer.state.pos_x, 0.0, viewer.state.pos_z, 0.0, 0.0, Movement.eye_height(viewer.state),
				bot.state.pos_x, bot.state.pos_y, bot.state.pos_z, bot.state.vel_x, bot.state.vel_z, false, st.world, look, NetConfig.VIS_LATERAL_MARGIN, f) >= 0 else 0
			if sent != rule:
				mismatches += 1
			if prev >= 0 and sent != prev:
				flips += 1
			prev = sent
			if f >= 1.0:
				full_duck_seen += 1
				if sent == 1:
					full_duck_hidden = false
			if f == 0.0 and sent == 0:
				stand_visible = false
			if f > 0.1 and f < 0.9 and sent == 1:
				half_visible += 1
	_ok("cover_peek: the bot flips in and out of the viewer's sent mask once per 64-tick phase", flips >= 14 and flips <= 24, "%d flips in 1,280 ticks" % flips)
	_ok("cover_peek: the mask equals the blended-height visibility rule on every snapshot tick", mismatches == 0, "%d mismatches" % mismatches)
	_ok("cover_peek: standing is always sent, fully ducked (fraction 1.0) is never sent, half ducked is sent (its crown is above the cover)", stand_visible and full_duck_hidden and full_duck_seen > 20 and half_visible > 50, "%d fully ducked snapshot ticks hidden, %d half-ducked ticks visible" % [full_duck_seen, half_visible])
