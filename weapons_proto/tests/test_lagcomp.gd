extends SceneTree

const History = preload("res://hitreg/lagcomp_history.gd")
const HitboxBuilder = preload("res://hitreg/hitboxes.gd")
const RayBoxLogic = preload("res://hitreg/ray_box.gd")
const RewindPolicy = preload("res://hitreg/rewind_policy.gd")
const ScriptedPath = preload("res://tests/scripted_path.gd")

var passed := 0
var failed := 0


func _init() -> void:
	var version_info: Dictionary = Engine.get_version_info()
	var version_string := str(version_info.get("string", "unknown"))
	print("Godot version info: %s" % version_info)
	if not version_string.begins_with("4.4.1"):
		_fail("version guard expected Godot 4.4.1, got %s" % version_string)

	_test_capacities_and_ring()
	_test_linear_interpolation()
	_test_yaw_stance_and_alive()
	_test_missing_history()
	_test_rewind_targets()
	_test_rewound_hitboxes()
	_test_duck_fraction_interpolation()
	_test_rewind_policy()
	_test_scripted_paths()
	_test_golden_cases()
	_finish()


func _test_capacities_and_ring() -> void:
	for rate in [64, 100, 128]:
		var history = History.new(rate, 1)
		var expected_max := int(floor(0.2 * float(rate) + 1e-12))
		_check_bool("history %d-tick rewind cap" % rate, history.max_rewind_ticks, expected_max)
		_check_bool("history %d-tick capacity" % rate, history.capacity, expected_max + 1)

	var history = History.new(128, 1)
	var all_pushed := true
	for tick in range(1000):
		var origin := PackedFloat64Array([float(tick), 0.0, 0.0])
		var accepted: bool = history.push_sample(0, _sample(tick, origin, 0.0, 0, true))
		all_pushed = all_pushed and accepted
	_check_bool("all 1,000 sequential samples accepted", all_pushed, true)
	_check_bool("ring retains exactly 26 samples", history.sample_count(0), 26)
	_check_bool("ring newest tick", history.latest_tick_for_slot(0), 999)
	var oldest := history.sample_at(0, 974.0)
	_check_bool("oldest retained tick", oldest["tick"], 974)
	_check_bool("oldest retained sample is present", oldest["missing_history"], false)
	var expired := history.sample_at(0, 973.0)
	_check_bool("expired history returns oldest tick", expired["tick"], 974)
	_check_bool("expired history is marked missing", expired["missing_history"], true)
	_check_bool("out-of-range slot rejects sample", history.push_sample(1, _sample(1000, PackedFloat64Array([0.0, 0.0, 0.0]), 0.0, 0, true)), false)


func _test_linear_interpolation() -> void:
	var history = History.new(128, 1)
	for tick in range(975, 1001):
		var x := 250.0 * float(tick) / 128.0
		history.push_sample(0, _sample(tick, PackedFloat64Array([x, 0.0, 0.0]), 0.0, 0, true))

	var max_error := 0.0
	var all_queries_present := true
	for step in range(1601):
		var rewind := float(step) / 64.0
		var target_tick := 1000.0 - rewind
		var sample: Dictionary = history.sample_at(0, target_tick)
		var expected_x := 250.0 * target_tick / 128.0
		max_error = maxf(max_error, absf(float(sample["origin64"][0]) - expected_x))
		all_queries_present = all_queries_present and not bool(sample["missing_history"])
	_check_bool("all 1,601 fractional queries have history", all_queries_present, true)
	_check_float("linear path max error for 1601 fractional queries", max_error, 0.0, 1e-9)


func _test_yaw_stance_and_alive() -> void:
	var history = History.new(128, 1)
	history.push_sample(0, _sample(990, PackedFloat64Array([0.0, 0.0, 0.0]), 350.0, 1, true))
	history.push_sample(0, _sample(991, PackedFloat64Array([10.0, 0.0, 0.0]), 10.0, 0, true))
	var older := history.sample_at(0, 990.4)
	var newer := history.sample_at(0, 990.6)
	var tie := history.sample_at(0, 990.5)
	_check_float("shortest yaw arc halfway", history.sample_at(0, 990.5)["yaw_deg"], 0.0, 1e-9)
	_check_float("origin linear interpolation", older["origin64"][0], 4.0, 1e-9)
	_check_bool("nearer old stance before midpoint", older["stance"], 1)
	_check_bool("nearer new stance after midpoint", newer["stance"], 0)
	_check_bool("older stance wins exact midpoint", tie["stance"], 1)
	_check_bool("alive if both samples alive", tie["alive"], true)

	var death_history = History.new(128, 1)
	death_history.push_sample(0, _sample(10, PackedFloat64Array([0.0, 0.0, 0.0]), 0.0, 0, true))
	death_history.push_sample(0, _sample(11, PackedFloat64Array([1.0, 0.0, 0.0]), 0.0, 0, false))
	_check_bool("interpolated sample dead if either endpoint dead", death_history.sample_at(0, 10.5)["alive"], false)


func _test_missing_history() -> void:
	var history = History.new(128, 2)
	for tick in range(995, 1001):
		history.push_sample(
			1,
			_sample(tick, PackedFloat64Array([float(tick), 4.0, 0.0]), 45.0, 0, true)
		)
	var sample: Dictionary = history.sample_at(1, 986.0)
	_check_bool("missing-history sample uses oldest tick", sample["tick"], 995)
	_check_bool("missing-history flag set", sample["missing_history"], true)
	_check_float("missing-history uses oldest origin", sample["origin64"][0], 995.0, 1e-9)


func _test_rewind_targets() -> void:
	var history = History.new(128, 4)
	for tick in range(21):
		history.push_sample(0, _sample(tick, PackedFloat64Array([0.0, 0.0, 0.0]), 0.0, 0, true))
		history.push_sample(1, _sample(tick, PackedFloat64Array([float(tick), 0.0, 0.0]), 0.0, 0, true))
		history.push_sample(2, _sample(tick, PackedFloat64Array([0.0, 5.0, 0.0]), 0.0, 0, false))
	for tick in range(15, 21):
		history.push_sample(3, _sample(tick, PackedFloat64Array([float(tick), 10.0, 0.0]), 0.0, 0, true))

	var rewound := history.rewind_targets(0, 10.5)
	_check_bool("rewind targets alive slots only", _target_slots(rewound["targets"]), [1, 3])
	_check_bool("shooter and dead slots excluded", rewound["rewound_mask"] & 0x0005, 0)
	_check_bool("missing history target not in mask", rewound["rewound_mask"] & (1 << 3), 0)
	_check_bool("complete-history target in mask", rewound["rewound_mask"] & (1 << 1), 1 << 1)
	_check_bool("one target has missing history", rewound["missing_history_count"], 1)
	_check_bool("only complete-history target rewound", rewound["targets_rewound"], 1)


func _test_rewound_hitboxes() -> void:
	var history = History.new(128, 1)
	for tick in range(975, 1001):
		var origin := PackedFloat64Array([250.0 * float(tick) / 128.0, 20.0, 3.5])
		history.push_sample(0, _sample(tick, origin, 37.5, 1, true))
	var sample: Dictionary = history.sample_at(0, 989.6)
	var rewound: Array = HitboxBuilder.build_boxes_precise(
		sample["origin64"],
		sample["yaw_deg"],
		sample["stance"],
		float(sample["duck_fraction"])
	)
	var expected_origin := PackedFloat64Array([250.0 * 989.6 / 128.0, 20.0, 3.5])
	var expected: Array = HitboxBuilder.build_boxes_precise(expected_origin, 37.5, 1, 1.0)
	var max_error := 0.0
	for i in range(11):
		for axis in range(3):
			max_error = maxf(max_error, absf(rewound[i]["center64"][axis] - expected[i]["center64"][axis]))
	_check_float("rewound boxes match exact linear path", max_error, 0.0, 1e-9)


func _test_duck_fraction_interpolation() -> void:
	for tick_rate in [64, 100, 128]:
		var history = History.new(tick_rate, 1)
		var target_origin := PackedFloat64Array([500.0, 0.0, 0.0])
		var stand_sample := _sample(10, target_origin, 180.0, 0, true)
		var crouch_sample := _sample(11, target_origin, 180.0, 1, true)
		stand_sample["duck_fraction"] = 0.0
		crouch_sample["duck_fraction"] = 1.0
		history.push_sample(0, stand_sample)
		history.push_sample(0, crouch_sample)

		var mid_sample: Dictionary = history.sample_at(0, 10.5)
		_check_float("A3 %d tick mid-duck history fraction" % tick_rate, mid_sample["duck_fraction"], 0.5, 1e-12)
		var mid_boxes: Array = HitboxBuilder.build_boxes_precise(
			mid_sample["origin64"],
			float(mid_sample["yaw_deg"]),
			int(mid_sample["stance"]),
			float(mid_sample["duck_fraction"])
		)
		_check_float("A3 %d tick mid-duck head top" % tick_rate, mid_boxes[0]["center64"][2] + mid_boxes[0]["half64"][2], 54.0, 1e-9)
		_check_float("A3 %d tick mid-duck eye height" % tick_rate, HitboxBuilder.eye_height(0, float(mid_sample["duck_fraction"])), 48.0, 1e-9)

		var zero_padding: Dictionary = {}
		for box_id in range(11):
			zero_padding[box_id] = 0.0
		var ray_origin := PackedFloat64Array([0.0, 0.0, 48.0])
		var ray_direction := PackedFloat64Array([1.0, 0.0, 0.0])
		var mid_hit := RayBoxLogic.trace_target(ray_origin, ray_direction, 8192.0, mid_boxes, zero_padding, 1.0)
		_check_bool("A3 %d tick mid-duck head height hits head" % tick_rate, mid_hit["box_id"], 0)

		var stand_boxes: Array = HitboxBuilder.build_boxes_precise(target_origin, 180.0, 0, 0.0)
		var stand_hit := RayBoxLogic.trace_target(ray_origin, ray_direction, 8192.0, stand_boxes, zero_padding, 1.0)
		_check_bool("A3 %d tick stand height is not a head hit" % tick_rate, stand_hit["box_id"] == 0, false)
		var fully_crouched: Array = HitboxBuilder.build_boxes_precise(target_origin, 180.0, 1, 1.0)
		var crouch_hit := RayBoxLogic.trace_target(ray_origin, ray_direction, 8192.0, fully_crouched, zero_padding, 1.0)
		_check_bool("A3 %d tick crouch height misses mid-duck ray" % tick_rate, crouch_hit["outcome"], "none")


func _test_rewind_policy() -> void:
	_check_bool("J10 default interpolation ticks", RewindPolicy.INTERP_TICKS, 4)
	_check_bool("J11 rewind cap 64 tick", RewindPolicy.max_rewind_ticks(64), 12)
	_check_bool("J11 rewind cap 100 tick", RewindPolicy.max_rewind_ticks(100), 20)
	_check_bool("J11 rewind cap 128 tick", RewindPolicy.max_rewind_ticks(128), 25)

	var now := 1000.0
	var rtt_ms := 80.0
	var expected4 := now - rtt_ms * 128.0 / 1000.0 - 4.0
	var at_4 := RewindPolicy.choose(now, rtt_ms, 4, expected4, 128)
	_check_float("80ms/interp4 wanted rewind", at_4["wanted_rewind_ticks"], 14.24, 1e-9)
	_check_bool("80ms/interp4 whole rewind", at_4["rewind_ticks"], 14)
	_check_bool("80ms/interp4 fraction", at_4["rewind_frac"], 15729)
	_check_bool("80ms/interp4 reason", at_4["reason"], 0)
	_check_bool("80ms/interp4 flags", at_4["flags"], 0)
	_check_bool("80ms/interp4 accepts expected claim", at_4["input_reject"], false)
	var encoded_rewind := float(at_4["rewind_ticks"]) + float(at_4["rewind_frac"]) / 65536.0
	_check_float("chosen tick matches encoded rewind", at_4["chosen_view_tick"], now - encoded_rewind, 1e-12)

	var at_2 := RewindPolicy.choose(now, rtt_ms, 2, now - 10.24 - 2.0, 128)
	var at_3 := RewindPolicy.choose(now, rtt_ms, 3, now - 10.24 - 3.0, 128)
	_check_float("80ms/interp2 wanted rewind", at_2["wanted_rewind_ticks"], 12.24, 1e-9)
	_check_float("80ms/interp3 wanted rewind", at_3["wanted_rewind_ticks"], 13.24, 1e-9)

	var expected := expected4
	var within := RewindPolicy.choose(now, rtt_ms, 4, expected + 0.9, 128)
	var inclusive := RewindPolicy.choose(now, rtt_ms, 4, expected + 1.0, 128)
	_check_bool("claimed-time +0.9 accepted", within["input_reject"], false)
	_check_bool("claimed-time +1.0 inclusive", inclusive["input_reject"], false)
	var too_far := RewindPolicy.choose(now, rtt_ms, 4, expected + 1.1, 128)
	_check_bool("claimed-time +1.1 rejected", too_far["input_reject"], true)
	_check_bool("claimed-time reason 1", too_far["reason"], 1)
	_check_bool("claimed-time flag bit 1", int(too_far["flags"]) & (1 << 1), 1 << 1)
	_check_float("claimed-time clamped to plus one", too_far["clamped_claimed_view_tick"], expected + 1.0, 1e-9)
	var backtrack := RewindPolicy.choose(now, rtt_ms, 4, expected - 5.0, 128)
	_check_bool("backtrack claim clamps to minus one", backtrack["reason"], 1)
	_check_float("backtrack clamped claim", backtrack["clamped_claimed_view_tick"], expected - 1.0, 1e-9)

	var at_cap := RewindPolicy.choose(now, 164.0625, 4, now - 21.0 - 4.0, 128)
	_check_float("full compensation limit is 25 ticks", at_cap["wanted_rewind_ticks"], 25.0, 1e-9)
	_check_bool("exact cap not flagged", at_cap["reason"], 0)
	var over_cap := RewindPolicy.choose(now, 170.0, 4, now - 21.76 - 4.0, 128)
	_check_float("170ms wanted rewind", over_cap["wanted_rewind_ticks"], 25.76, 1e-9)
	_check_bool("over-cap clamps to 25", over_cap["rewind_ticks"], 25)
	_check_bool("over-cap fraction clears", over_cap["rewind_frac"], 0)
	_check_bool("over-cap reason 2", over_cap["reason"], 2)
	_check_bool("over-cap flag bit 0", int(over_cap["flags"]) & 1, 1)
	_check_float("full compensation interp2 limit", RewindPolicy.choose(now, 179.6875, 2, now - 25.0, 128)["wanted_rewind_ticks"], 25.0, 1e-9)
	_check_float("full compensation interp3 limit", RewindPolicy.choose(now, 171.875, 3, now - 25.0, 128)["wanted_rewind_ticks"], 25.0, 1e-9)

	var future_claim := RewindPolicy.choose(now, 0.0, 0, now + 3.0, 128)
	_check_bool("negative rewind clamps to zero", future_claim["rewind_ticks"], 0)
	_check_bool("negative rewind combined reason 5", future_claim["reason"], 5)
	_check_bool("negative rewind has claim flag", int(future_claim["flags"]) & (1 << 1), 1 << 1)
	_check_bool("negative rewind has negative flag", int(future_claim["flags"]) & (1 << 4), 1 << 4)

	var both := RewindPolicy.choose(now, 200.0, 4, now - 25.6 - 4.0 - 3.0, 128)
	_check_bool("both clamps reason 3", both["reason"], 3)
	_check_bool("both clamps flags 0 and 1", int(both["flags"]) & 3, 3)
	var missing := RewindPolicy.with_missing_history(at_4, 1)
	_check_bool("missing-only reason 6", missing["reason"], 6)
	_check_bool("missing-history flag bit 5", int(missing["flags"]) & (1 << 5), 1 << 5)
	var missing_with_claim := RewindPolicy.with_missing_history(too_far, 1)
	_check_bool("missing history preserves clamp reason", missing_with_claim["reason"], 1)
	_check_bool("missing history adds flag to clamp", int(missing_with_claim["flags"]) & (1 << 5), 1 << 5)

	var nan_claim := RewindPolicy.choose(now, rtt_ms, 4, NAN, 128)
	_check_bool("NaN claimed tick is rejected", nan_claim["input_reject"], true)
	_check_bool("NaN claimed tick uses reason 1", nan_claim["reason"], 1)
	_check_bool(
		"NaN claimed tick sets claimed-time flag",
		int(nan_claim["flags"]) & RewindPolicy.FLAG_CLAIMED_TIME_OUT_OF_WINDOW,
		RewindPolicy.FLAG_CLAIMED_TIME_OUT_OF_WINDOW
	)
	_check_float("NaN claimed tick clamps to expected", nan_claim["clamped_claimed_view_tick"], expected4, 1e-6)
	_check_bool("NaN claimed tick produces finite rewind", is_finite(float(nan_claim["wanted_rewind_ticks"])), true)

	var nan_rtt := RewindPolicy.choose(now, NAN, 4, expected4, 128)
	var nan_rtt_expected := now - 4.0
	_check_bool("NaN RTT is rejected", nan_rtt["input_reject"], true)
	_check_bool("NaN RTT uses reason 1", nan_rtt["reason"], 1)
	_check_bool("NaN RTT is sanitized for the decision", nan_rtt["rtt_ms"], 0.0)
	_check_float("NaN RTT expected tick stays finite", nan_rtt["expected_view_tick"], nan_rtt_expected, 1e-6)
	_check_float("NaN RTT clamps claim to expected", nan_rtt["clamped_claimed_view_tick"], nan_rtt_expected, 1e-6)
	_check_bool("NaN RTT sets claimed-time flag", int(nan_rtt["flags"]) & 2, 2)

	var carry_rewind := 10.9999999
	var carry_rtt := (carry_rewind - 4.0) * 1000.0 / 128.0
	var carry_expected := now - carry_rewind
	var carry := RewindPolicy.choose(now, carry_rtt, 4, carry_expected, 128)
	_check_bool("fraction rounding carries whole tick", carry["rewind_ticks"], 11)
	_check_bool("fraction rounding carry clears remainder", carry["rewind_frac"], 0)


func _test_scripted_paths() -> void:
	var linear_path := {
		"kind": "linear",
		"start": [0.0, 0.0, 0.0],
		"velocity_ups": [250.0, 0.0, 0.0],
		"yaw_deg": 0.0,
	}
	var linear := ScriptedPath.sample(linear_path, 128, 128)
	_check_float("ScriptedPath linear speed", linear["origin64"][0], 250.0, 1e-9)

	var circle_path := {
		"kind": "circle",
		"center": [0.0, 0.0, 0.0],
		"radius": 20.0,
		"deg_per_s": 180.0,
	}
	var circle := ScriptedPath.sample(circle_path, 128, 128)
	_check_vec3d("ScriptedPath circle endpoint", circle["origin64"], PackedFloat64Array([-20.0, 0.0, 0.0]), 1e-9)
	_check_float("ScriptedPath circle tangent yaw", circle["yaw_deg"], 270.0, 1e-9)

	var peek_path := {
		"kind": "peek",
		"cover_pos": [0.0, 60.0, 0.0],
		"open_pos": [0.0, 0.0, 0.0],
		"out_tick": 10,
		"back_tick": 60,
		"speed": 250.0,
		"yaw_deg": 0.0,
	}
	var before_peek := ScriptedPath.sample(peek_path, 9, 128)
	var after_return := ScriptedPath.sample(peek_path, 100, 128)
	_check_float("ScriptedPath peek starts in cover", before_peek["origin64"][1], 60.0, 1e-9)
	_check_float("ScriptedPath peek returns to cover", after_return["origin64"][1], 60.0, 1e-9)
	_check_bool("ScriptedPath stance toggle", ScriptedPath.stance_toggle(16, 16), 1)
	_check_bool("ScriptedPath spawn marker", ScriptedPath.spawn_at(5, 5), true)
	_check_bool("ScriptedPath death marker", ScriptedPath.die_at(10, 10), false)


func _test_golden_cases() -> void:
	var file := FileAccess.open("res://tests/lagcomp_cases.json", FileAccess.READ)
	if file == null:
		_fail("cannot open tests/lagcomp_cases.json")
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("lagcomp_cases.json is not a JSON object")
		return
	var case_data: Dictionary = parsed
	var cases: Array = case_data["cases"]
	_check_bool("lag-comp golden case total", cases.size(), int(case_data["case_count"]))
	_check_bool("lag-comp random case count", int(case_data["random_case_count"]), 5000)

	var counts := {}
	var max_error := 0.0
	for index in range(cases.size()):
		var case: Dictionary = cases[index]
		var category := str(case["category"])
		counts[category] = int(counts.get(category, 0)) + 1
		var rate := int(case["tick_rate"])
		var history = History.new(rate, 1)
		var path: Dictionary = case["path"]
		var push_ok := true
		for tick in range(int(case["first_tick"]), int(case["now_tick"]) + 1):
			var scripted := ScriptedPath.sample(
				path,
				tick,
				rate,
				int(case["stance_every_n_ticks"]),
				int(case["spawn_tick"]),
				int(case["death_tick"])
			)
			push_ok = history.push_sample(0, scripted) and push_ok
		if not push_ok:
			_fail("golden case %d failed to push scripted history: %s" % [index, JSON.stringify(case)])

		var expected_decision: Dictionary = case["expected_decision"]
		var decision := RewindPolicy.choose(
			float(case["now_tick"]),
			float(case["rtt_ms"]),
			int(case["interp_ticks"]),
			float(case["claimed_view_tick"]),
			rate
		)
		var sample := history.sample_at(0, float(case["query_tick"]))
		decision = RewindPolicy.with_missing_history(
			decision,
			1 if bool(sample["missing_history"]) else 0
		)
		var expected_sample: Dictionary = case["expected_sample"]
		var case_error := _sample_error(sample, expected_sample)
		max_error = maxf(max_error, case_error)
		var sample_state_matches := (
		int(sample["stance"]) == int(expected_sample["stance"])
		and bool(sample["alive"]) == bool(expected_sample["alive"])
		and bool(sample["missing_history"]) == bool(expected_sample["missing_history"])
		and absf(float(sample["duck_fraction"]) - float(expected_sample["duck_fraction"])) <= 1e-6
		and int(decision["missing_history_count"])
					== (1 if bool(expected_sample["missing_history"]) else 0)
		)
		if (
				case_error > 1e-6
				or not sample_state_matches
				or not _decision_matches(decision, expected_decision)
			):
			_fail(
				"golden case %d category %s sample_error %.12f got_sample=%s expected_sample=%s got_decision=%s expected_decision=%s input=%s"
				% [
					index,
					category,
					case_error,
					JSON.stringify(sample),
					JSON.stringify(expected_sample),
					JSON.stringify(decision),
					JSON.stringify(expected_decision),
					JSON.stringify(case),
				]
			)

	print(
		"Lag-comp summary: %d cases; maximum pose absolute error %.12f"
		% [cases.size(), max_error]
	)
	for category in case_data["case_counts"]:
		_check_bool(
			"lag-comp golden category %s count" % category,
			int(counts.get(category, 0)),
			int(case_data["case_counts"][category])
		)
	_check_float("lag-comp golden max pose error", max_error, 0.0, 1e-6)


func _sample_error(got: Dictionary, want: Dictionary) -> float:
	var error := absf(float(got["yaw_deg"]) - float(want["yaw_deg"]))
	error = maxf(error, absf(float(got["tick"]) - float(want["tick"])))
	error = maxf(error, absf(float(got["duck_fraction"]) - float(want["duck_fraction"])))
	for axis in range(3):
		error = maxf(error, absf(float(got["origin64"][axis]) - float(want["origin64"][axis])))
	return error


func _decision_matches(got: Dictionary, want: Dictionary) -> bool:
	var exact_keys := [
		"rewind_ticks", "rewind_frac", "max_rewind_ticks", "flags",
		"reason", "input_reject",
	]
	for key in exact_keys:
		if got.get(key) != want.get(key):
			return false
	var float_keys := [
		"expected_view_tick", "clamped_claimed_view_tick", "chosen_view_tick",
		"wanted_rewind_ticks", "rewind_ticks_float", "rtt_ticks",
	]
	for key in float_keys:
		if absf(float(got[key]) - float(want[key])) > 1e-6:
			return false
	return true


func _sample(
		tick: int,
		origin64: PackedFloat64Array,
		yaw_deg: float,
		stance: int,
		alive: bool
	) -> Dictionary:
	return {
		"tick": tick,
		"origin64": origin64,
		"yaw_deg": yaw_deg,
		"stance": stance,
		"duck_fraction": 1.0 if stance == 1 or stance == 3 else 0.0,
		"alive": alive,
	}


func _target_slots(targets: Array) -> Array:
	var slots: Array = []
	for target in targets:
		slots.append(int(target["slot"]))
	slots.sort()
	return slots


func _check_float(name: String, got: float, want: float, tolerance: float) -> void:
	if absf(got - want) <= tolerance:
		passed += 1
		print("PASS  %s  got %.9f want %.9f" % [name, got, want])
	else:
		_fail("%s got %.12f want %.12f tolerance %.12f" % [name, got, want, tolerance])


func _check_bool(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		passed += 1
		print("PASS  %s  got %s want %s" % [name, str(got), str(want)])
	else:
		_fail("%s got %s want %s" % [name, str(got), str(want)])


func _check_vec3d(name: String, got: PackedFloat64Array, want: PackedFloat64Array, tolerance: float) -> void:
	var error := maxf(
		maxf(absf(got[0] - want[0]), absf(got[1] - want[1])),
		absf(got[2] - want[2])
	)
	if error <= tolerance:
		passed += 1
		print(
			"PASS  %s  got (%.9f, %.9f, %.9f) want (%.9f, %.9f, %.9f)"
			% [name, got[0], got[1], got[2], want[0], want[1], want[2]]
		)
	else:
		_fail(
			"%s got (%.12f, %.12f, %.12f) want (%.12f, %.12f, %.12f)"
			% [name, got[0], got[1], got[2], want[0], want[1], want[2]]
		)


func _fail(message: String) -> void:
	failed += 1
	print("FAIL  %s" % message)


func _finish() -> void:
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
