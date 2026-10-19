extends SceneTree

const RecoilLogic = preload("res://weapons/recoil.gd")
const RifleTableData = preload("res://weapons/rifle_tables.gd")
const WeaponConfigData = preload("res://weapons/weapon_config.gd")
const RngTypes = preload("res://weapons/rng_source.gd")

var passed := 0
var failed := 0
var suppress_float_pass_output := false


func _init() -> void:
	var version_info: Dictionary = Engine.get_version_info()
	var version_string := str(version_info.get("string", "unknown"))
	print("Godot version info: %s" % version_info)
	if not version_string.begins_with("4.4.1"):
		_fail("version guard expected Godot 4.4.1, got %s" % version_string)

	var cases_file := FileAccess.open("res://tests/recoil_cases_cd9.json", FileAccess.READ)
	if cases_file == null:
		_fail("cannot open tests/recoil_cases_cd9.json")
		_finish()
		return
	var parsed: Variant = JSON.parse_string(cases_file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("recoil_cases_cd9.json is not a JSON object")
		_finish()
		return

	var cases: Dictionary = parsed
	var legacy_file := FileAccess.open("res://tests/recoil_cases.json", FileAccess.READ)
	if legacy_file == null:
		_fail("cannot open legacy tests/recoil_cases.json")
		_finish()
		return
	var legacy_variant: Variant = JSON.parse_string(legacy_file.get_as_text())
	if typeof(legacy_variant) != TYPE_DICTIONARY:
		_fail("legacy recoil_cases.json is not a JSON object")
		_finish()
		return
	var legacy_cases: Dictionary = legacy_variant
	_test_unchanged_spray_fields(cases, legacy_cases)
	_test_all_sprays(cases)
	_test_accuracy_step_table()
	_test_pre_shot_accuracy_spread()
	_test_spread_table(cases)
	_test_rng_strictness()
	_test_spot_checks(cases)
	_test_recovery(cases)
	_test_switches()
	_finish()


func _test_all_sprays(cases: Dictionary) -> void:
	var tolerances: Dictionary = cases["tolerances"]
	var count := 0
	for spray_case in cases["sprays"]:
		count += 1
		_test_spray(spray_case, tolerances)
	_check_bool("all 16 required and extended sprays tested", count, 16)


func _test_unchanged_spray_fields(cases: Dictionary, legacy_cases: Dictionary) -> void:
	var legacy_by_key := {}
	for spray_case in legacy_cases["sprays"]:
		var key := "%s|%s|%d|%d" % [
			str(spray_case["weapon"]),
			str(spray_case["state"]),
			int(spray_case["tick"]),
			int(spray_case["seed"]),
		]
		legacy_by_key[key] = spray_case

	var changed_fields := ["spread", "spread_x", "spread_y", "aim_up", "aim_side"]
	for spray_case in cases["sprays"]:
		var key := "%s|%s|%d|%d" % [
			str(spray_case["weapon"]),
			str(spray_case["state"]),
			int(spray_case["tick"]),
			int(spray_case["seed"]),
		]
		var legacy_case: Dictionary = legacy_by_key.get(key, {})
		var shots: Array = spray_case["shots"]
		var legacy_shots: Array = legacy_case.get("shots", [])
		var unchanged := shots.size() == legacy_shots.size()
		if unchanged:
			for shot_index in range(shots.size()):
				var shot: Dictionary = shots[shot_index]
				var legacy_shot: Dictionary = legacy_shots[shot_index]
				if shot.size() != legacy_shot.size():
					unchanged = false
					break
				for field in legacy_shot:
					if changed_fields.has(str(field)):
						continue
					if shot.get(field) != legacy_shot[field]:
						unchanged = false
						break
				if not unchanged:
					break
		_check_bool(
			"%s/%s/%d time, kicks and raw RNG draws unchanged" % [
				str(spray_case["weapon"]),
				str(spray_case["state"]),
				int(spray_case["tick"]),
			],
			unchanged,
			true
		)


func _test_accuracy_step_table() -> void:
	for shot_count in range(1, 11):
		var ak_expected := 0.35 if shot_count <= 5 else 1.25
		var m4_expected := 0.30 if shot_count <= 6 else 1.00
		_check_float(
			"AK47 stock accuracy after shot %d" % shot_count,
			RecoilLogic.accuracy_for_shots("AK47", shot_count),
			ak_expected,
			1e-12
		)
		_check_float(
			"M4A1 stock accuracy after shot %d" % shot_count,
			RecoilLogic.accuracy_for_shots("M4A1", shot_count),
			m4_expected,
			1e-12
		)
	_check_float(
		"legacy smooth accuracy function remains available",
		RifleTableData.accuracy_for_shots_smooth("AK47", 4),
		0.67,
		1e-12
	)


func _test_pre_shot_accuracy_spread() -> void:
	var ak_expected := [0.0055, 0.009625, 0.009625, 0.009625, 0.009625, 0.009625, 0.034375]
	var ak_state := RecoilLogic.initial_state("AK47")
	var ak_rng = RngTypes.GodotRng.new(1337)
	for index in range(ak_expected.size()):
		var shot: Dictionary = RecoilLogic.fire_shot(
			ak_state,
			_movement_state("stand"),
			ak_rng,
			float(index) * 0.1
		)
		_check_float(
			"AK47 pre-shot accuracy spread %d" % (index + 1),
			float(shot["shot"]["spread"]),
			float(ak_expected[index]),
			1e-12
		)
		ak_state = shot["state"]

	var m4_expected := [
		0.005, 0.0075, 0.0075, 0.0075, 0.0075, 0.0075, 0.0075, 0.025
	]
	var m4_state := RecoilLogic.initial_state("M4A1")
	var m4_rng = RngTypes.GodotRng.new(1337)
	for index in range(m4_expected.size()):
		var shot: Dictionary = RecoilLogic.fire_shot(
			m4_state,
			_movement_state("stand"),
			m4_rng,
			float(index) * 0.1
		)
		_check_float(
			"M4A1 pre-shot accuracy spread %d" % (index + 1),
			float(shot["shot"]["spread"]),
			float(m4_expected[index]),
			1e-12
		)
		m4_state = shot["state"]


func _test_spray(spray_case: Dictionary, tolerances: Dictionary) -> void:
	var draws: Array = []
	for expected in spray_case["shots"]:
		draws.append_array(expected["draws"])
	var replay = RngTypes.ReplayRng.new(draws, false)
	var weapon_id := str(spray_case["weapon"])
	var tick := int(spray_case["tick"])
	var movement := _movement_state(str(spray_case["state"]))
	var state := RecoilLogic.initial_state(weapon_id)
	var dt := 1.0 / float(tick)
	var time_s := 0.0
	var shot_index := 0
	var max_steps := int(spray_case["shots"].size()) * tick + tick
	var comparisons_before := passed
	var failures_before := failed
	suppress_float_pass_output = true

	for _step in range(max_steps):
		if shot_index >= spray_case["shots"].size():
			break
		var fired := false
		if RecoilLogic.fire_due(state, time_s):
			fired = true
			var result: Dictionary = RecoilLogic.fire_shot(state, movement, replay, time_s)
			state = result["state"]
			var got: Dictionary = result["shot"]
			var want: Dictionary = spray_case["shots"][shot_index]
			var label := "%s %s%d#%02d" % [
				str(spray_case.get("source", spray_case["state"])),
				weapon_id,
				tick,
				shot_index + 1,
			]
			_check_float("%s time" % label, got["time_s"], want["t"], float(tolerances["time_s"]))
			_check_float("%s spread" % label, got["spread"], want["spread"], float(tolerances["spread"]))
			var recorded_draws: Array = want["draws"]
			var expected_spread_x := (
				float(recorded_draws[0]["value"]) + float(recorded_draws[1]["value"])
			) * float(want["spread"])
			var expected_spread_y := (
				float(recorded_draws[2]["value"]) + float(recorded_draws[3]["value"])
			) * float(want["spread"])
			_check_float("%s golden spread_x recomputed from draws" % label, want["spread_x"], expected_spread_x, 1e-9)
			_check_float("%s golden spread_y recomputed from draws" % label, want["spread_y"], expected_spread_y, 1e-9)
			_check_float("%s spread_x matches golden draw formula" % label, got["spread_x"], want["spread_x"], 1e-9)
			_check_float("%s spread_y matches golden draw formula" % label, got["spread_y"], want["spread_y"], 1e-9)
			_check_float("%s kick_up" % label, got["kick_up"], want["kick_up"], float(tolerances["deg"]))
			_check_float("%s kick_side" % label, got["kick_side"], want["kick_side"], float(tolerances["deg"]))
			_check_float("%s aim_up" % label, got["aim_up"], want["aim_up"], float(tolerances["deg"]))
			_check_float("%s aim_side" % label, got["aim_side"], want["aim_side"], float(tolerances["deg"]))
			shot_index += 1
		state = RecoilLogic.finish_tick(state, dt, fired)
		time_s += dt

	suppress_float_pass_output = false
	if failed == failures_before and passed - comparisons_before == spray_case["shots"].size() * 6:
		print(
			"PASS  spray %s %s/%d: %d/%d shot-by-shot numeric comparisons"
			% [
				str(spray_case.get("source", spray_case["state"])),
				weapon_id,
				tick,
				passed - comparisons_before,
				spray_case["shots"].size() * 6,
			]
		)
	_check_bool("%s%d replay consumed all draws" % [weapon_id, tick], replay.remaining_count() == 0, true)
	_check_bool("%s%d replay had no strictness error" % [weapon_id, tick], not replay.failed, true)


func _test_spread_table(cases: Dictionary) -> void:
	for expected in cases["spread_table"]:
		var weapon_id := str(expected["weapon"])
		var movement := _movement_state(str(expected["state"]))
		var state := RecoilLogic.initial_state(weapon_id)
		_check_float(
			"%s %s first spread" % [weapon_id, expected["state"]],
			RecoilLogic.spread_for_next_shot(state, movement),
			float(expected["first"]),
			0.0001
		)
		var table: Dictionary = RifleTableData.get_weapon(weapon_id)
		state["accuracy"] = float(table["accuracy_cap"])
		_check_float(
			"%s %s max spread" % [weapon_id, expected["state"]],
			RecoilLogic.spread_for_next_shot(state, movement),
			float(expected["max"]),
			0.0001
		)

	var unsilenced := RecoilLogic.initial_state(RifleTableData.M4A1, {}, false)
	_check_float(
		"M4A1 unsilenced standing table entry",
		RecoilLogic.spread_for_next_shot(unsilenced, _movement_state("stand")),
		0.020 * 0.2,
		1e-12
	)


func _test_rng_strictness() -> void:
	var wrong_kind = RngTypes.ReplayRng.new([
		{"kind": "randint", "args": [0, 1], "value": 0},
	], false)
	wrong_kind.uniform(-0.5, 0.5)
	_check_bool("ReplayRng rejects a wrong draw kind", wrong_kind.failed, true)

	var exhausted = RngTypes.ReplayRng.new([
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
	], false)
	exhausted.uniform(-0.5, 0.5)
	exhausted.uniform(-0.5, 0.5)
	_check_bool("ReplayRng rejects an extra draw", exhausted.failed, true)

	var first = RngTypes.GodotRng.new(1337)
	var second = RngTypes.GodotRng.new(1337)
	_check_float("GodotRng seeded uniform replay", first.uniform(-1.0, 1.0), second.uniform(-1.0, 1.0), 0.0)
	var first_integer: int = first.randint(0, 100)
	var second_integer: int = second.randint(0, 100)
	_check_bool("GodotRng seeded integer replay", first_integer == second_integer, true)


func _movement_state(state_name: String) -> Dictionary:
	return {
		"in_air": state_name == "air",
		"horizontal_speed": 141.0 if state_name == "run" else 0.0,
		"crouched": state_name == "crouch",
	}


func _check_float(name: String, got: float, want: float, tolerance: float) -> void:
	if absf(got - want) <= tolerance:
		passed += 1
		if not suppress_float_pass_output:
			print("PASS  %s  got %.6f want %.6f" % [name, got, want])
	else:
		_fail("%s got %.9f want %.9f tolerance %.9f" % [name, got, want, tolerance])


func _check_bool(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		passed += 1
		print("PASS  %s  got %s want %s" % [name, str(got), str(want)])
	else:
		_fail("%s got %s want %s" % [name, str(got), str(want)])


func _fail(message: String) -> void:
	failed += 1
	print("FAIL  %s" % message)


func _finish() -> void:
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _test_spot_checks(cases: Dictionary) -> void:
	var expected_peaks := {
		"AK47:64": 4.61,
		"AK47:128": 4.61,
		"M4A1:64": 2.72,
		"M4A1:128": 2.64,
	}
	var expected_durations := {
		"AK47:64": 2.781,
		"AK47:128": 2.773,
		"M4A1:64": 2.547,
		"M4A1:128": 2.539,
	}
	for spray_case in cases["sprays"]:
		if spray_case["state"] != "stand":
			continue
		var key := "%s:%d" % [spray_case["weapon"], spray_case["tick"]]
		var peak := 0.0
		for shot in spray_case["shots"]:
			peak = maxf(peak, float(shot["kick_up"]))
		_check_float("%s peak kick_up" % key, peak, float(expected_peaks[key]), 0.005)
		var last_shot: Dictionary = spray_case["shots"][-1]
		_check_float("%s spray duration" % key, last_shot["t"], float(expected_durations[key]), 0.0005)

	for decay_case in cases["decay_between_shots"]:
		var dt := 1.0 / float(decay_case["tick"])
		var px := -float(decay_case["start"])
		var elapsed := 0.0
		while elapsed < 0.0955 - 1e-9:
			px = RecoilLogic.decay_kick(px, 0.0, dt)[0]
			elapsed += dt
		_check_float(
			"kick decay %d tick" % decay_case["tick"],
			absf(px),
			float(decay_case["value"]),
			0.005
		)


func _test_recovery(cases: Dictionary) -> void:
	for recovery_case in cases["recovery"]:
		var tick := int(recovery_case["tick"])
		var dt := 1.0 / float(tick)
		var px := float(recovery_case["kick"])
		var elapsed := 0.0
		var steps := 0
		while px > 0.0001 and steps < tick:
			px = RecoilLogic.decay_kick(px, 0.0, dt)[0]
			elapsed += dt
			steps += 1
		_check_bool("2 degree kick recovery steps %d tick" % tick, steps, int(recovery_case["steps"]))
		_check_float("2 degree kick recovery seconds %d tick" % tick, elapsed, float(recovery_case["seconds"]), 1e-9)

	_test_stock_counter_recovery(cases)
	_test_release_switches()
	_test_legacy_recovery_switches()


func _test_release_switches() -> void:
	_check_float(
		"CD-r9 stock release cap default",
		float(WeaponConfigData.defaults()["SHOTS_FIRED_RELEASE_CAP"]),
		15.0,
		0.0
	)
	_check_bool(
		"CD-r9 recovery delay defaults from release",
		WeaponConfigData.defaults()["RECOVERY_DELAY_FROM"],
		"release"
	)
	_check_bool(
		"CD-r9 first drop is strictly after the delay",
		WeaponConfigData.defaults()["BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD"],
		false
	)
	_check_bool(
		"CD-r9 recovery is limited to one drop per tick",
		WeaponConfigData.defaults()["RECOVERY_ONE_PER_TICK"],
		true
	)

	var capped_state := _state_after_shots(30, {})
	capped_state = RecoilLogic.release_trigger(capped_state, float(capped_state["last_fire_s"]))
	_check_bool("CD-r9 release edge caps 30-shot counter at 15", capped_state["shots_in_burst"], 15)
	var release_edge := _state_after_shots(30, {})
	release_edge = RecoilLogic.finish_tick(release_edge, 0.0, false, false, 3.0)
	_check_bool("trigger release edge applies the stock cap", release_edge["shots_in_burst"], 15)
	var release_delay_edge := _state_after_shots(3, {})
	release_delay_edge = RecoilLogic.finish_tick(release_delay_edge, 0.0, false, false, 0.8)
	_check_float("trigger release edge resets stock delay", release_delay_edge["idle_time_s"], 0.0, 1e-12)

	var held_state := _state_after_shots(30, {})
	var held_tick := RecoilLogic.finish_tick(held_state, 0.5, false, true, 3.0)
	_check_bool("held trigger does not recover shot counter", held_tick["shots_in_burst"], 30)


func _test_stock_counter_recovery(cases: Dictionary) -> void:
	var first_drop_ticks := {64: 26, 100: 41, 128: 52}
	var thirty_shot_reset_ticks := {64: 54, 100: 83, 128: 94}
	var tap_reset_ticks := {64: 30, 100: 47, 128: 58}
	var sim_recovery_by_tick := {}
	for row in cases["shot_counter_recovery"]:
		sim_recovery_by_tick[int(row["tick"])] = row

	for tick in [64, 100, 128]:
		var dt := 1.0 / float(tick)
		var sim_row: Dictionary = sim_recovery_by_tick[tick]
		var thirty := _state_after_shots(30, {})
		thirty = RecoilLogic.release_trigger(thirty, float(thirty["last_fire_s"]))
		_check_bool("CD-r9 30-shot counter is capped at release", thirty["shots_in_burst"], 15)
		var thirty_result := _recover_schedule(thirty, dt, tick * 2)
		_check_bool(
			"Python sim 30-shot first-drop tick %d Hz" % tick,
			int(sim_row["30_shot_spray"]["first_drop_tick"]),
			first_drop_ticks[tick]
		)
		_check_bool(
			"Python sim 30-shot reset tick %d Hz" % tick,
			int(sim_row["30_shot_spray"]["reset_tick"]),
			thirty_shot_reset_ticks[tick]
		)
		_check_bool(
			"CD-r9 30-shot first-drop tick %d Hz" % tick,
			thirty_result["first_drop_tick"],
			first_drop_ticks[tick]
		)
		_check_float(
			"CD-r9 30-shot first-drop seconds %d Hz" % tick,
			float(thirty_result["first_drop_tick"]) * dt,
			float(first_drop_ticks[tick]) * dt,
			1e-9
		)
		_check_bool(
			"CD-r9 30-shot counter reaches zero at tick %d Hz" % tick,
			thirty_result["count"],
			thirty_shot_reset_ticks[tick]
		)
		_check_float(
			"CD-r9 30-shot reset seconds %d Hz" % tick,
			float(thirty_result["count"]) * dt,
			float(thirty_shot_reset_ticks[tick]) * dt,
			1e-9
		)

		var tap := _state_after_shots(3, {})
		tap = RecoilLogic.release_trigger(tap, float(tap["last_fire_s"]))
		var tap_result := _recover_schedule(tap, dt, tick * 2)
		_check_bool(
			"Python sim 3-shot tap reset tick %d Hz" % tick,
			int(sim_row["3_shot_tap"]["reset_tick"]),
			tap_reset_ticks[tick]
		)
		_check_bool("CD-r9 3-shot tap reset tick %d Hz" % tick, tap_result["count"], tap_reset_ticks[tick])

	var edge := _state_after_shots(30, {})
	edge = RecoilLogic.release_trigger(edge, float(edge["last_fire_s"]))
	for _tick in range(40):
		edge = RecoilLogic.recover_tick(edge, 0.01)
	_check_bool("CD-r9 100 Hz tick 40 has no recovery drop", edge["shots_in_burst"], 15)
	edge = RecoilLogic.recover_tick(edge, 0.01)
	_check_bool("CD-r9 100 Hz first drop is tick 41", edge["shots_in_burst"], 14)

	var large_dt := _state_after_shots(30, {})
	large_dt = RecoilLogic.release_trigger(large_dt, float(large_dt["last_fire_s"]))
	large_dt = RecoilLogic.recover_tick(large_dt, 0.5)
	_check_bool("one-per-tick stock path drops only once for large dt", large_dt["shots_in_burst"], 14)


func _test_legacy_recovery_switches() -> void:
	var legacy_config := {
		"SHOTS_FIRED_RELEASE_CAP": 0.0,
		"RECOVERY_DELAY_FROM": "last_shot",
		"BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD": true,
		"RECOVERY_ONE_PER_TICK": false,
	}
	var legacy_thirty := _state_after_shots(30, legacy_config)
	legacy_thirty = RecoilLogic.release_trigger(legacy_thirty, float(legacy_thirty["last_fire_s"]))
	legacy_thirty = RecoilLogic.recover_tick(legacy_thirty, 1.075)
	_check_bool("legacy switches preserve 30-shot 1.075 s reset", legacy_thirty["shots_in_burst"], 0)
	_check_float("legacy 30-shot elapsed time", legacy_thirty["idle_time_s"], 1.075, 1e-9)

	var legacy_tap := _state_after_shots(3, legacy_config)
	legacy_tap = RecoilLogic.release_trigger(legacy_tap, float(legacy_tap["last_fire_s"]))
	legacy_tap = RecoilLogic.recover_tick(legacy_tap, 0.4675)
	_check_bool("legacy switches preserve 3-shot 0.4675 s reset", legacy_tap["shots_in_burst"], 0)
	_check_float("legacy 3-shot elapsed time", legacy_tap["idle_time_s"], 0.4675, 1e-9)


func _recover_schedule(state: Dictionary, dt: float, maximum_steps: int) -> Dictionary:
	var steps := 0
	var first_drop_tick := 0
	var current := state
	while int(current["shots_in_burst"]) > 0 and steps < maximum_steps:
		var before := int(current["shots_in_burst"])
		current = RecoilLogic.recover_tick(current, dt)
		steps += 1
		if first_drop_tick == 0 and int(current["shots_in_burst"]) < before:
			first_drop_tick = steps
	return {"count": steps, "first_drop_tick": first_drop_tick, "state": current}


func _test_switches() -> void:
	var moving_air := _movement_state("air")
	moving_air["horizontal_speed"] = 20.0
	var moving_state := _fire_once({"KICK_MOVING_BEFORE_AIR": true}, moving_air)
	var air_state := _fire_once({"KICK_MOVING_BEFORE_AIR": false}, moving_air)
	_check_float("J2 on uses moving kick in air", moving_state["px"], -1.5, 1e-12)
	_check_float("J2 off uses air kick", air_state["px"], -2.0, 1e-12)

	var j3_rng = RngTypes.ReplayRng.new(_single_shot_draws(1, 8, 1), false)
	var j3_state := RecoilLogic.initial_state("AK47", {"FLIP_ROLL_INCLUSIVE": false})
	var j3_result: Dictionary = RecoilLogic.fire_shot(j3_state, _movement_state("stand"), j3_rng, 0.0)
	_check_bool("J3 off uses 1..k and flips on one", not bool(j3_result["state"]["side_dir"]), true)
	_check_bool("J3 alternative recorded exact roll bounds", not j3_rng.failed and j3_rng.remaining_count() == 0, true)

	var fixed_config := {"KICK_PATTERN_MODE": "fixed"}
	var fixed_rng = RngTypes.GodotRng.new(11)
	var fixed_state := RecoilLogic.initial_state("AK47", fixed_config)
	var fixed_first: Dictionary = RecoilLogic.fire_shot(
			fixed_state, _movement_state("stand"), fixed_rng, 0.0)
	var fixed_second: Dictionary = RecoilLogic.fire_shot(
			fixed_first["state"], _movement_state("stand"), fixed_rng, 0.1)
	_check_bool("J1 fixed stub starts without a flip", fixed_first["state"]["side_dir"], true)
	_check_bool("J1 fixed stub follows deterministic sequence", fixed_second["state"]["side_dir"], false)

	var stock_state := _state_after_shots(6, {})
	var stock_accuracy := float(stock_state["accuracy"])
	var stock_recovered := _recover_to_zero(stock_state, 0.1)
	_check_float("J4 stock recovery keeps cap accuracy", stock_recovered["accuracy"], stock_accuracy, 1e-12)
	_check_float("J4 six-shot AK accuracy is capped before recovery", stock_accuracy, 1.25, 1e-12)
	var stale_shot: Dictionary = RecoilLogic.fire_shot(
		stock_recovered,
		_movement_state("stand"),
		RngTypes.GodotRng.new(77),
		3.0
	)
	_check_float("J4 next AK shot uses stored cap accuracy", stale_shot["shot"]["spread"], 0.034375, 1e-12)
	var reset_state := _state_after_shots(6, {"ACCURACY_RESET_ON_RECOVERY": true})
	var reset_recovered := _recover_to_zero(reset_state, 0.1)
	_check_float("J4 reset alternative restores starting accuracy", reset_recovered["accuracy"], 0.2, 1e-12)
	var reset_shot: Dictionary = RecoilLogic.fire_shot(
		reset_recovered,
		_movement_state("stand"),
		RngTypes.GodotRng.new(77),
		3.0
	)
	_check_float("J4 reset alternative returns to first-shot spread", reset_shot["shot"]["spread"], 0.0055, 1e-12)


func _state_after_shots(shot_count: int, config: Dictionary) -> Dictionary:
	var state := RecoilLogic.initial_state("AK47", config)
	var rng = RngTypes.GodotRng.new(2026)
	for i in range(shot_count):
		var result: Dictionary = RecoilLogic.fire_shot(
				state, _movement_state("stand"), rng, float(i) * 0.1)
		state = result["state"]
	return state


func _recover_to_zero(state: Dictionary, dt: float) -> Dictionary:
	var result := RecoilLogic.release_trigger(state, float(state.get("last_fire_s", 0.0)))
	var elapsed := 0.0
	while int(result["shots_in_burst"]) > 0 and elapsed < 2.0:
		result = RecoilLogic.recover_tick(result, dt)
		elapsed += dt
	return result


func _fire_once(config: Dictionary, movement: Dictionary) -> Dictionary:
	var state := RecoilLogic.initial_state("AK47", config)
	var rng = RngTypes.GodotRng.new(77)
	var result: Dictionary = RecoilLogic.fire_shot(state, movement, rng, 0.0)
	return result["state"]


func _single_shot_draws(randint_min: int, randint_max: int, randint_value: int) -> Array:
	return [
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "randint", "args": [randint_min, randint_max], "value": randint_value},
	]
