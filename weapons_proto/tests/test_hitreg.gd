extends SceneTree

const HitRegLogic = preload("res://hitreg/hitreg.gd")
const HitboxBuilder = preload("res://hitreg/hitboxes.gd")
const History = preload("res://hitreg/lagcomp_history.gd")
const RayBoxLogic = preload("res://hitreg/ray_box.gd")
const RecoilLogic = preload("res://weapons/recoil.gd")
const RngTypes = preload("res://weapons/rng_source.gd")
const WeaponConfigData = preload("res://weapons/weapon_config.gd")
const DamageRegionData = preload("res://hitreg/damage_regions.gd")
const HitboxConfigData = preload("res://hitreg/hitbox_config.gd")
const ScriptedPath = preload("res://tests/scripted_path.gd")
const FrameAdapter = preload("res://shared/frame.gd")
const InputCommand = preload("res://shared/input_cmd.gd")

var passed := 0
var failed := 0


func _init() -> void:
	var version_info: Dictionary = Engine.get_version_info()
	var version_string := str(version_info.get("string", "unknown"))
	print("Godot version info: %s" % version_info)
	if not version_string.begins_with("4.4.1"):
		_fail("version guard expected Godot 4.4.1, got %s" % version_string)

	_test_scenario1_standing_headshot()
	_test_scenario2_lag_comp_moving_target()
	_test_scenario5_near_miss_ladder()
	_test_scenario3_peek_and_world()
	_test_scenario4_claimed_backtrack()
	_test_nonfinite_rewind_inputs_fail_closed()
	_test_scenario6_spread_decides()
	_test_scenario7_crouch_overlap()
	_test_scenario8_player_penetration()
	_test_scenario9_teammate()
	_test_scenario10_dead_and_missing()
	_test_scenario11_server_seed()
	_test_damage_regions_and_switches()
	_test_python_golden_cases()
	_finish()


func _test_scenario1_standing_headshot() -> void:
	var history = History.new(128, 16)
	history.push_sample(1, _sample(1000, [500.0, 0.0, 0.0], 180.0, 0, true))
	var context := _context(
		history,
		1000.0,
		[0.0, 0.0, 64.0],
		0.0,
		0.0,
		0.0,
		0,
		1000.0,
		[],
		{0: 1, 1: 2}
	)
	var result: Dictionary = HitRegLogic.process_shot(context)
	_check_bool("scenario1 one hit record", result["records"].size(), 1)
	var record: Dictionary = result["records"][0]
	_check_bool("scenario1 outcome hit", record["outcome"], 0)
	_check_bool("scenario1 head box", record["part"], 0)
	_check_bool("scenario1 head region", record["region_id"], 0)
	_check_float("scenario1 hit distance", record["closest_dist"], 0.0, 1e-12)
	var standing_head: Array = HitboxBuilder.build_boxes_precise(
		PackedFloat64Array([500.0, 0.0, 0.0]),
		180.0,
		HitboxBuilder.STAND
	)
	var head_padding := float(HitboxConfigData.HITBOX_PADDING_PER_BONE[0])
	var head_front_x := float(standing_head[0]["center64"][0]) \
			- float(standing_head[0]["half64"][0]) - head_padding
	var shot_direction: PackedFloat64Array = result["shot_direction"]
	var expected_entry := head_front_x / shot_direction[0]
	var expected_hit_point := [
		head_front_x,
		shot_direction[1] * expected_entry,
		64.0 + shot_direction[2] * expected_entry,
	]
	_check_float("scenario1 padded trace entry distance", record["trace_distance"], expected_entry, 1e-9)
	_check_vec3d("scenario1 padded hit ray point", record["ray_point"], expected_hit_point, 1e-9)
	_check_vec3d("scenario1 padded hit box point", record["box_point"], expected_hit_point, 1e-9)
	_check_bool("scenario1 rewind zero", result["rewind_decision"]["rewind_ticks"], 0)
	_check_bool("scenario1 rewind flags zero", result["rewind_decision"]["flags"], 0)
	_check_bool("scenario1 no input reject", result["input_reject"], null)


func _test_scenario2_lag_comp_moving_target() -> void:
	var history = History.new(128, 16)
	var expected_view_tick := 1000.0 - 80.0 * 128.0 / 1000.0 - 4.0
	for tick in range(975, 1001):
		var target_y := 250.0 * (float(tick) - expected_view_tick) / 128.0
		history.push_sample(1, _sample(tick, [500.0, target_y, 0.0], 0.0, 0, true))

	var view_sample: Dictionary = history.sample_at(1, expected_view_tick)
	var target_boxes: Array = HitboxBuilder.build_boxes_precise(
		view_sample["origin64"],
		0.0,
		HitboxBuilder.STAND
	)
	var chest_center: PackedFloat64Array = target_boxes[1]["center64"]
	# At yaw 90 the padded A-pose arm overlaps the chest center; aim low in the chest
	# to isolate the rewind result while still requiring a chest hit.
	var upper_chest_point := PackedFloat64Array([chest_center[0], chest_center[1], 57.0])
	var angles := _aim_angles([0.0, 0.0, 64.0], upper_chest_point)
	var context := _context(
		history,
		1000.0,
		[0.0, 0.0, 64.0],
		angles[0],
		angles[1],
		80.0,
		4,
		expected_view_tick,
		[],
		{0: 1, 1: 2}
	)
	var result: Dictionary = HitRegLogic.process_shot(context)
	_check_float("scenario2 chosen rewind", result["rewind_decision"]["wanted_rewind_ticks"], 14.24, 1e-9)
	_check_bool("scenario2 chest hit", result["records"].size(), 1)
	_check_bool("scenario2 chest part", result["records"][0]["part"], 1)
	_check_bool("scenario2 chest region", result["records"][0]["region_id"], 1)

	var current_origin := PackedFloat64Array([
		500.0,
		250.0 * (1000.0 - expected_view_tick) / 128.0,
		0.0,
	])
	var current_boxes: Array = HitboxBuilder.build_boxes_precise(
		current_origin,
		0.0,
		HitboxBuilder.STAND
	)
	var no_rewind := RayBoxLogic.trace_target(
		PackedFloat64Array([0.0, 0.0, 64.0]),
		result["shot_direction"],
		8192.0,
		current_boxes
	)
	_check_bool("scenario2 without rewind is a clean miss", no_rewind["outcome"], "none")


func _test_scenario5_near_miss_ladder() -> void:
	var expected := [
		{"z": 74.5, "outcome": 1},
		{"z": 74.99, "outcome": 1},
		{"z": 75.0, "outcome": 1},
		{"z": 77.98, "outcome": 1},
		{"z": 78.000001, "outcome": -1},
	]
	for case in expected:
		var history = History.new(128, 16)
		history.push_sample(1, _sample(1000, [500.0, 0.0, 0.0], 180.0, 0, true))
		var context := _context(
			history,
			1000.0,
			[0.0, 0.0, float(case["z"])],
			0.0,
			0.0,
			0.0,
			0,
			1000.0,
			[],
			{0: 1, 1: 2}
		)
		var result: Dictionary = HitRegLogic.process_shot(context)
		var expected_count := 0 if int(case["outcome"]) < 0 else 1
		_check_bool("scenario5 z %.2f record count" % case["z"], result["records"].size(), expected_count)
		if expected_count > 0:
			var record: Dictionary = result["records"][0]
			_check_bool("scenario5 z %.2f near miss" % case["z"], record["outcome"], 1)
			var head_boxes: Array = HitboxBuilder.build_boxes_precise(
				PackedFloat64Array([500.0, 0.0, 0.0]),
				180.0,
				HitboxBuilder.STAND
			)
			var head: Dictionary = head_boxes[0]
			var padding := float(HitboxConfigData.HITBOX_PADDING_PER_BONE[0])
			var front_x := float(head["center64"][0]) - float(head["half64"][0]) - padding
			var padded_top := float(head["center64"][2]) + float(head["half64"][2]) + padding
			var direction: PackedFloat64Array = result["shot_direction"]
			var ray_height := float(case["z"]) + direction[2] * front_x / direction[0]
			var expected_distance := ray_height - padded_top
			_check_float(
				"scenario5 z %.2f distance" % case["z"],
				record["closest_dist"],
				expected_distance,
				1e-8
			)


func _test_scenario3_peek_and_world() -> void:
	var wall := _world_box([250.0, 16.0, 0.0], [260.0, 200.0, 128.0])
	var open_history: Variant = _peek_history(940, 987)
	var view_tick := 1000.0 - 80.0 * 128.0 / 1000.0 - 4.0
	var open_angles := _upper_chest_angles(open_history, view_tick)
	var open_context := _context(
		open_history,
		1000.0,
		[0.0, 0.0, 64.0],
		open_angles[0],
		open_angles[1],
		80.0,
		4,
		view_tick,
		[wall],
		{0: 1, 1: 2}
	)
	var open_result: Dictionary = HitRegLogic.process_shot(open_context)
	_check_bool("scenario3 rewound peeker is hit", open_result["records"].size(), 1)
	_check_bool("scenario3 open peek hits chest", open_result["records"][0]["part"], 1)
	_check_bool("scenario3 open ray clears wall", open_result["world_hit"], false)
	_check_bool("scenario3 target is behind wall at now", open_history.sample_at(1, 1000.0)["origin64"][1] >= 16.0, true)

	var hidden_history: Variant = _peek_history(980, 1100)
	var hidden_angles := _upper_chest_angles(hidden_history, view_tick)
	var hidden_context := _context(
		hidden_history,
		1000.0,
		[0.0, 0.0, 64.0],
		hidden_angles[0],
		hidden_angles[1],
		80.0,
		4,
		view_tick,
		[wall],
		{0: 1, 1: 2}
	)
	var hidden_result: Dictionary = HitRegLogic.process_shot(hidden_context)
	_check_bool("scenario3 hidden ray is world blocked", hidden_result["world_hit"], true)
	_check_bool("scenario3 wall-blocked shot has no SHOT", hidden_result["records"].size(), 0)
	_check_bool("scenario3 wall-block still records rewind", hidden_result.has("rewind_decision"), true)
	var through_world_context := _context(
		hidden_history,
		1000.0,
		[0.0, 0.0, 64.0],
		hidden_angles[0],
		hidden_angles[1],
		80.0,
		4,
		view_tick,
		[wall],
		{0: 1, 1: 2},
		{"WORLD_BLOCKS_SHOTS": false}
	)
	var through_world_result: Dictionary = HitRegLogic.process_shot(through_world_context)
	_check_bool("J14 off permits hidden target hit", through_world_result["records"].size() > 0, true)
	_check_bool(
		"J14 off logs THROUGH_WORLD",
		int(through_world_result["records"][0]["flags"]) & (1 << 2),
		1 << 2
	)


func _test_scenario4_claimed_backtrack() -> void:
	var expected_view_tick := 1000.0 - 80.0 * 128.0 / 1000.0 - 4.0
	var claimed_tick := expected_view_tick - 5.0
	var history: Variant = _moving_history(1000, expected_view_tick)
	var cheat_sample: Dictionary = history.sample_at(1, claimed_tick)
	var cheat_boxes: Array = HitboxBuilder.build_boxes_precise(
		cheat_sample["origin64"],
		0.0,
		HitboxBuilder.STAND
	)
	var angles := _aim_angles([0.0, 0.0, 64.0], cheat_boxes[0]["center64"])
	var context := _context(
		history,
		1000.0,
		[0.0, 0.0, 64.0],
		angles[0],
		angles[1],
		80.0,
		4,
		claimed_tick,
		[],
		{0: 1, 1: 2}
	)
	var result: Dictionary = HitRegLogic.process_shot(context)
	_check_bool("scenario4 backtrack clamp reason", result["rewind_decision"]["reason"], 1)
	_check_bool("scenario4 backtrack input reject", result["input_reject"]["reason"], 1)
	_check_bool("scenario4 padded boundary remains logged", result["records"].size(), 1)
	_check_bool("scenario4 old head position is a near miss", result["records"][0]["outcome"], 1)
	_check_bool("scenario4 near miss is inside 4-unit logger", result["records"][0]["closest_dist"] <= 4.0, true)


func _test_nonfinite_rewind_inputs_fail_closed() -> void:
	var history := History.new(128, 16)
	var nan_claim_context := _context(
		history,
		1000.0,
		[0.0, 0.0, 64.0],
		0.0,
		0.0,
		80.0,
		4,
		NAN,
		[],
		{0: 1}
	)
	var nan_claim_result: Dictionary = HitRegLogic.process_shot(nan_claim_context)
	_check_bool("NaN claim has INPUT_REJECT reason 1", nan_claim_result["input_reject"]["reason"], 1)
	_check_bool("NaN claim sets rewind claim flag", int(nan_claim_result["rewind_decision"]["flags"]) & 2, 2)
	_check_float(
		"NaN claim clamps to finite expected tick",
		float(nan_claim_result["rewind_decision"]["clamped_claimed_view_tick"]),
		float(nan_claim_result["rewind_decision"]["expected_view_tick"]),
		1e-6
	)
	_check_bool(
		"NaN claim rewind remains finite",
		is_finite(float(nan_claim_result["rewind_decision"]["wanted_rewind_ticks"])),
		true
	)

	var nan_rtt_context := _context(
		history,
		1000.0,
		[0.0, 0.0, 64.0],
		0.0,
		0.0,
		NAN,
		4,
		996.0,
		[],
		{0: 1}
	)
	var nan_rtt_result: Dictionary = HitRegLogic.process_shot(nan_rtt_context)
	_check_bool("NaN RTT has INPUT_REJECT reason 1", nan_rtt_result["input_reject"]["reason"], 1)
	_check_bool("NaN RTT sets rewind claim flag", int(nan_rtt_result["rewind_decision"]["flags"]) & 2, 2)
	_check_float("NaN RTT is sanitized to zero", float(nan_rtt_result["rewind_decision"]["rtt_ms"]), 0.0, 0.0)
	_check_float(
		"NaN RTT clamps to finite expected tick",
		float(nan_rtt_result["rewind_decision"]["chosen_view_tick"]),
		996.0,
		1e-6
	)


func _test_scenario6_spread_decides() -> void:
	var history := History.new(128, 16)
	history.push_sample(1, _sample(1000, [2000.0, 0.0, 0.0], 180.0, 0, true))
	var spread_state := RecoilLogic.initial_state("AK47")
	var lower_draws := _vertical_spread_draws(-0.5, -0.5)
	var spread_context := _context(
		history,
		1000.0,
		[0.0, 0.0, 66.0],
		0.0,
		0.0,
		0.0,
		0,
		1000.0,
		[],
		{0: 1, 1: 2},
		{},
		RngTypes.ReplayRng.new(lower_draws, false),
		0xFFFF,
		1,
		10,
		"AK47",
		spread_state
	)
	var spread_result: Dictionary = HitRegLogic.process_shot(spread_context)
	_check_bool("scenario6 spread produces one hit", spread_result["records"].size(), 1)
	_check_bool("scenario6 spread moves head aim to chest", spread_result["records"][0]["part"], 1)
	_check_float(
		"scenario6 downward vertical offset",
		spread_result["records"][0]["spread_y"],
		-0.0055,
		1e-9
	)
	var zero_context := _context(
		history, 1000.0, [0.0, 0.0, 66.0], 0.0, 0.0, 0.0, 0, 1000.0, [], {0: 1, 1: 2}
	)
	var zero_result: Dictionary = HitRegLogic.process_shot(zero_context)
	_check_bool("scenario6 zero spread remains a headshot", zero_result["records"][0]["part"], 0)


func _test_scenario7_crouch_overlap() -> void:
	var history := History.new(128, 16)
	history.push_sample(1, _sample(1000, [500.0, 0.0, 0.0], 180.0, HitboxBuilder.CROUCH, true))
	var head_context := _context(
		history, 1000.0, [0.0, 0.0, 33.0], 0.0, 0.0, 0.0, 0, 1000.0, [], {0: 1, 1: 2}
	)
	var head_result: Dictionary = HitRegLogic.process_shot(head_context)
	_check_bool("scenario7 z=33.0 crouched head hits head", head_result["records"][0]["part"], 0)
	_check_float("scenario7 crouched head distance", head_result["records"][0]["closest_dist"], 0.0, 1e-12)
	var crouched_boxes: Array = HitboxBuilder.build_boxes_precise(
		PackedFloat64Array([500.0, 0.0, 0.0]),
		180.0,
		HitboxBuilder.CROUCH
	)
	var head_front_x := float(crouched_boxes[0]["center64"][0]) \
			- float(crouched_boxes[0]["half64"][0]) \
			- float(HitboxConfigData.HITBOX_PADDING_PER_BONE[0])
	_check_float(
		"scenario7 padded head entry",
		head_result["records"][0]["trace_distance"],
		head_front_x / float(head_result["shot_direction"][0]),
		1e-9
	)

	var overlap_context := _context(
		history, 1000.0, [0.0, 0.0, 27.25], 0.0, 0.0, 0.0, 0, 1000.0, [], {0: 1, 1: 2}
	)
	var overlap_result: Dictionary = HitRegLogic.process_shot(overlap_context)
	_check_bool("scenario7 z=27.25 entry-first selects chest", overlap_result["records"][0]["part"], 1)
	var chest_front_x := float(crouched_boxes[1]["center64"][0]) \
			- float(crouched_boxes[1]["half64"][0]) \
			- float(HitboxConfigData.HITBOX_PADDING_PER_BONE[1])
	_check_float(
		"scenario7 padded chest trace entry distance",
		overlap_result["records"][0]["trace_distance"],
		chest_front_x / float(overlap_result["shot_direction"][0]),
		1e-9
	)
	var head_priority_context := _context(
		history, 1000.0, [0.0, 0.0, 27.25], 0.0, 0.0, 0.0, 0, 1000.0, [], {0: 1, 1: 2}
	)
	head_priority_context["hitbox_config"] = {
		"CROUCH_HEAD_OVERLAP_RULE": "head_priority_in_overlap",
	}
	var head_priority_result: Dictionary = HitRegLogic.process_shot(head_priority_context)
	_check_bool("scenario7 configured overlap alternative selects head", head_priority_result["records"][0]["part"], 0)
	_check_float(
		"scenario7 alternative padded head entry",
		head_priority_result["records"][0]["trace_distance"],
		head_front_x / float(head_priority_result["shot_direction"][0]),
		1e-9
	)


func _test_scenario8_player_penetration() -> void:
	var behind := History.new(128, 16)
	behind.push_sample(1, _sample(1000, [200.0, 0.0, 10.0], 180.0, 0, true))
	behind.push_sample(2, _sample(1000, [400.0, 0.0, 0.0], 180.0, 0, true))
	var context := _context(
		behind, 1000.0, [0.0, 0.0, 73.0], 0.0, 0.0, 0.0, 0, 1000.0, [], {0: 1, 1: 2, 2: 2}
	)
	var behind_result: Dictionary = HitRegLogic.process_shot(context)
	_check_bool("scenario8 behind target ignored after first hit", behind_result["records"].size(), 1)
	_check_bool("scenario8 first target is hit", behind_result["records"][0]["target_slot"], 1)

	var front := History.new(128, 16)
	front.push_sample(1, _sample(200, [200.0, 0.0, 10.0], 180.0, 0, true))
	front.push_sample(2, _sample(200, [100.0, 0.0, 0.0], 180.0, 0, true))
	var front_context := _context(
		front, 200.0, [0.0, 0.0, 74.5], 0.0, 0.0, 0.0, 0, 200.0, [], {0: 1, 1: 2, 2: 2}
	)
	var front_result: Dictionary = HitRegLogic.process_shot(front_context)
	_check_bool("scenario8 front graze creates two records", front_result["records"].size(), 2)
	_check_bool("scenario8 front target is near miss", front_result["records"][1]["outcome"], 1)
	_check_bool(
		"scenario8 hit records share shot index",
		front_result["records"][0]["shot_index"],
		front_result["records"][1]["shot_index"]
	)

	var penetration_context := _context(
		behind,
		1000.0,
		[0.0, 0.0, 73.0],
		0.0,
		0.0,
		0.0,
		0,
		1000.0,
		[],
		{0: 1, 1: 2, 2: 2},
		{"PLAYER_PENETRATION": true}
	)
	var penetrated: Dictionary = HitRegLogic.process_shot(penetration_context)
	_check_bool("J13 penetration alternative reaches rear target", penetrated["records"].size(), 2)


func _test_scenario9_teammate() -> void:
	var history := History.new(128, 16)
	history.push_sample(1, _sample(1000, [500.0, 0.0, 0.0], 180.0, 0, true))
	var context := _context(
		history, 1000.0, [0.0, 0.0, 64.0], 0.0, 0.0, 0.0, 0, 1000.0, [], {0: 1, 1: 1}
	)
	var result: Dictionary = HitRegLogic.process_shot(context)
	_check_bool("scenario9 teammate is traced", result["records"].size(), 1)
	_check_bool("scenario9 same-team marker", result["records"][0]["same_team"], true)


func _test_scenario10_dead_and_missing() -> void:
	var dead_history := History.new(128, 16)
	dead_history.push_sample(1, _sample(1000, [500.0, 0.0, 0.0], 180.0, 0, false))
	var dead_context := _context(
		dead_history, 1000.0, [0.0, 0.0, 64.0], 0.0, 0.0, 0.0, 0, 1000.0, [], {0: 1, 1: 2}
	)
	var dead_result: Dictionary = HitRegLogic.process_shot(dead_context)
	_check_bool("scenario10 dead target not traced", dead_result["records"].size(), 0)

	var missing_history := History.new(128, 16)
	for tick in range(995, 1001):
		missing_history.push_sample(1, _sample(tick, [500.0, 0.0, 0.0], 180.0, 0, true))
	var missing_context := _context(
		missing_history, 1000.0, [0.0, 0.0, 64.0], 0.0, 0.0, 80.0, 4,
		1000.0 - 80.0 * 128.0 / 1000.0 - 4.0, [], {0: 1, 1: 2}
	)
	var missing_result: Dictionary = HitRegLogic.process_shot(missing_context)
	_check_bool("scenario10 missing-history target still traced", missing_result["records"].size(), 1)
	_check_bool("scenario10 missing-history rewind reason", missing_result["rewind_decision"]["reason"], 6)
	_check_bool(
		"scenario10 missing-history flag bit",
		int(missing_result["rewind_decision"]["flags"]) & (1 << 5),
		1 << 5
	)
	_check_bool("scenario10 missing-history target not in mask", missing_result["rewind_decision"]["rewound_mask"], 0)
	_check_float("scenario10 uses oldest target origin", missing_result["records"][0]["target_origin"][0], 500.0, 1e-9)


func _test_scenario11_server_seed() -> void:
	var history := History.new(128, 16)
	history.push_sample(1, _sample(1000, [2000.0, 0.0, 0.0], 180.0, 0, true))
	var max_accuracy_state := RecoilLogic.initial_state("AK47")
	max_accuracy_state["accuracy"] = 1.25
	var base_context := _context(
		history,
		1000.0,
		[0.0, 0.0, 66.0],
		0.0,
		0.0,
		0.0,
		0,
		1000.0,
		[],
		{0: 1, 1: 2},
		{},
		RngTypes.GodotRng.new(1),
		0xFFFF,
		1,
		10,
		"AK47",
		max_accuracy_state
	)
	_check_bool("scenario11 shooter command has no seed", base_context["shooter"].has("seed"), false)
	var first: Dictionary = HitRegLogic.process_shot(base_context)
	var first_signature := _shot_signature(first)
	var different_seed_found := false
	var second_signature := first_signature
	for seed in range(2, 65):
		var state := RecoilLogic.initial_state("AK47")
		state["accuracy"] = 1.25
		var context := _context(
			history,
			1000.0,
			[0.0, 0.0, 66.0],
			0.0,
			0.0,
			0.0,
			0,
			1000.0,
			[],
			{0: 1, 1: 2},
			{},
			RngTypes.GodotRng.new(seed),
			0xFFFF,
			1,
			10,
			"AK47",
			state
		)
		var result: Dictionary = HitRegLogic.process_shot(context)
		second_signature = _shot_signature(result)
		if second_signature != first_signature:
			different_seed_found = true
			break
	_check_bool("scenario11 different server seed can change result", different_seed_found, true)


func _test_damage_regions_and_switches() -> void:
	_check_float("J12 placeholder base damage", DamageRegionData.DAMAGE_TABLE["base_damage"], 0.0, 1e-12)
	for multiplier in DamageRegionData.DAMAGE_TABLE["multipliers"].values():
		_check_float("J12 placeholder damage multiplier", multiplier, 1.0, 1e-12)
	_check_bool("J13 non-penetration default", WeaponConfigData.PLAYER_PENETRATION, false)
	_check_bool("J14 world-block default", WeaponConfigData.WORLD_BLOCKS_SHOTS, true)
	var expected_regions := [0, 1, 2, 3, 3, 3, 3, 4, 4, 4, 4]
	for box_id in range(11):
		_check_bool(
			"damage region for box %d" % box_id,
			DamageRegionData.region_for_box(box_id),
			expected_regions[box_id]
		)


func _test_python_golden_cases() -> void:
	var file := FileAccess.open("res://tests/hitreg_cases.json", FileAccess.READ)
	if file == null:
		_fail("cannot open tests/hitreg_cases.json")
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("hitreg_cases.json is not a JSON object")
		return
	var data: Dictionary = parsed
	var named_cases: Array = data["named_cases"]
	var random_cases: Array = data["random_cases"]
	var all_cases := named_cases + random_cases
	_check_bool("hitreg named cases present", named_cases.size(), int(data["named_case_count"]))
	_check_bool("hitreg random cases present", random_cases.size(), 2000)
	_check_bool("hitreg total cases present", all_cases.size(), int(data["case_count"]))

	var seen_scenarios := {}
	var category_counts := {}
	var max_error := 0.0
	for index in range(all_cases.size()):
		var case: Dictionary = all_cases[index]
		var scenario_id := int(case["scenario_id"])
		seen_scenarios[scenario_id] = true
		var category := "named" if scenario_id > 0 else "random"
		category_counts[category] = int(category_counts.get(category, 0)) + 1
		var context := _build_golden_context(case)
		var result: Dictionary = HitRegLogic.process_shot(context)
		var error := _compare_golden_result(case, result)
		max_error = maxf(max_error, error)
	for scenario_id in range(1, 12):
		_check_bool("Python reference includes scenario %d" % scenario_id, seen_scenarios.has(scenario_id), true)
	for category in data["case_counts"]:
		_check_bool(
			"hitreg golden category %s count" % category,
			int(category_counts.get(category, 0)),
			int(data["case_counts"][category])
		)
	print("Hitreg golden summary: %d cases; max numeric error %.12f" % [all_cases.size(), max_error])
	_check_float("hitreg golden maximum error", max_error, 0.0, 1e-6)


func _build_golden_context(case: Dictionary) -> Dictionary:
	var source: Dictionary = case["context"]
	var tick_rate := int(source["tick_rate"])
	var now := int(source["now"])
	var history = History.new(tick_rate, 16)
	for player in source["players"]:
		var first_tick := maxi(0, now - history.max_rewind_ticks)
		var spawn_tick := int(player.get("spawn_tick", -1))
		if spawn_tick >= 0:
			first_tick = maxi(first_tick, spawn_tick)
		for tick in range(first_tick, now + 1):
			var sample: Dictionary = ScriptedPath.sample(
				player["path"],
				tick,
				tick_rate,
				int(player.get("stance_every_n_ticks", 0)),
				spawn_tick,
				int(player.get("death_tick", -1))
			)
			if player.has("stance"):
				sample["stance"] = int(player["stance"])
			history.push_sample(int(player["slot"]), sample)

	var shooter: Dictionary = source["shooter"].duplicate(true)
	shooter["eye64"] = PackedFloat64Array(shooter["eye64"])
	var weapon_state: Dictionary = RecoilLogic.initial_state(
		str(shooter["weapon_id"]),
		source.get("config", {}),
		bool(shooter.get("silenced", true))
	)
	for key in shooter.get("weapon_state", {}):
		weapon_state[key] = shooter["weapon_state"][key]
	shooter["weapon_state"] = weapon_state
	var teams := {int(shooter["slot"]): int(shooter["team"])}
	for player in source["players"]:
		teams[int(player["slot"])] = int(player["team"])
	var world_boxes: Array = []
	for source_box in source.get("world_boxes", []):
		world_boxes.append({
			"min64": PackedFloat64Array(source_box["min64"]),
			"max64": PackedFloat64Array(source_box["max64"]),
		})
	return {
		"now": float(source["now"]),
		"tick_rate": tick_rate,
		"shooter": shooter,
		"rtt_ms": float(source["rtt_ms"]),
		"interp_ticks": int(source["interp_ticks"]),
		"history": history,
		"teams": teams,
		"world_boxes": world_boxes,
		"rng": RngTypes.ReplayRng.new(case["draws"], false),
		"sent_mask": int(source.get("sent_mask", 0xFFFF)),
		"config": source.get("config", {}),
	}


func _compare_golden_result(case: Dictionary, result: Dictionary) -> float:
	var expected: Dictionary = case["expected"]
	var max_error := 0.0
	var records: Array = result["records"]
	var expected_records: Array = expected["records"]
	var mismatch := records.size() != expected_records.size()
	if mismatch:
		_fail(
			"hitreg case %s record count got %d want %d input=%s"
			% [case["name"], records.size(), expected_records.size(), JSON.stringify(case)]
		)
	for i in range(mini(records.size(), expected_records.size())):
		var got: Dictionary = records[i]
		var want: Dictionary = expected_records[i]
		var exact_keys := [
			"shooter_slot", "target_slot", "weapon_id", "part", "outcome",
			"target_stance", "shot_index", "view_pitch_q", "view_yaw_q",
			"rewind_ticks", "rewind_frac", "region_id", "same_team",
			"through_world", "flags",
		]
		for key in exact_keys:
			if got[key] != want[key]:
				mismatch = true
		var numeric_keys := [
			"trace_distance", "closest_dist", "spread_x", "spread_y",
			"kick_up", "kick_side", "server_time_s", "client_claimed_time_s",
			"target_yaw",
		]
		for key in numeric_keys:
			max_error = maxf(max_error, absf(float(got[key]) - float(want[key])))
		for key in ["eye_pos", "ray_point", "box_point", "target_origin"]:
			for axis in range(3):
				max_error = maxf(
					max_error,
					absf(float(got[key][axis]) - float(want[key][axis]))
				)
		if got["damage"] != want["damage"]:
			mismatch = true
	if max_error > 1e-6:
		mismatch = true

	var got_decision: Dictionary = result["rewind_decision"]
	var want_decision: Dictionary = expected["rewind_decision"]
	for key in [
		"shooter_slot", "shot_index", "cmd_seq", "rewind_ticks", "rewind_frac",
		"max_rewind_ticks", "flags", "reason", "input_reject", "targets_rewound",
		"rewound_mask", "missing_history_count",
	]:
		if got_decision[key] != want_decision[key]:
			mismatch = true
	for key in [
		"expected_view_tick", "chosen_view_tick", "wanted_rewind_ticks", "rtt_ticks",
	]:
		max_error = maxf(max_error, absf(float(got_decision[key]) - float(want_decision[key])))
	if max_error > 1e-6:
		mismatch = true

	var got_reject: Variant = result["input_reject"]
	var want_reject: Variant = expected["input_reject"]
	if (got_reject == null) != (want_reject == null):
		mismatch = true
	elif got_reject != null:
		for key in ["player_slot", "reason", "cmd_seq"]:
			if got_reject[key] != want_reject[key]:
				mismatch = true
		for key in ["claimed_time_s", "expected_time_s"]:
			max_error = maxf(max_error, absf(float(got_reject[key]) - float(want_reject[key])))
	if absf(float(result["spread_at_fire"]) - float(expected["spread_at_fire"])) > 1e-6:
		mismatch = true
	if int(result["move_state"]) != int(expected["move_state"]):
		mismatch = true
	for axis in range(3):
		max_error = maxf(
			max_error,
			absf(float(result["shot_direction"][axis]) - float(expected["shot_direction"][axis]))
		)
	if max_error > 1e-6:
		mismatch = true
	if mismatch:
		_fail(
			"hitreg case %s max_error %.12f got=%s expected=%s input=%s"
			% [case["name"], max_error, JSON.stringify(result), JSON.stringify(expected), JSON.stringify(case)]
		)
	return max_error


func _moving_history(now_tick: int, anchor_tick: float) -> Variant:
	var history := History.new(128, 16)
	for tick in range(now_tick - 25, now_tick + 1):
		var target_y := 250.0 * (float(tick) - anchor_tick) / 128.0
		history.push_sample(1, _sample(tick, [500.0, target_y, 0.0], 0.0, 0, true))
	return history


func _peek_history(out_tick: int, back_tick: int) -> Variant:
	var history := History.new(128, 16)
	var path := {
		"kind": "peek",
		"cover_pos": [500.0, 60.0, 0.0],
		"open_pos": [500.0, 0.0, 0.0],
		"out_tick": out_tick,
		"back_tick": back_tick,
		"speed": 250.0,
		"yaw_deg": 0.0,
	}
	for tick in range(975, 1001):
		history.push_sample(1, ScriptedPath.sample(path, tick, 128))
	return history


func _upper_chest_angles(history, target_tick: float) -> Array[float]:
	var sample: Dictionary = history.sample_at(1, target_tick)
	var boxes: Array = HitboxBuilder.build_boxes_precise(
		sample["origin64"],
		float(sample["yaw_deg"]),
		int(sample["stance"])
	)
	var chest: PackedFloat64Array = boxes[1]["center64"]
	return _aim_angles([0.0, 0.0, 64.0], PackedFloat64Array([chest[0], chest[1], 57.0]))


func _world_box(minimum: Array, maximum: Array) -> Dictionary:
	return {
		"min64": PackedFloat64Array(minimum),
		"max64": PackedFloat64Array(maximum),
	}


func _vertical_spread_draws(first: float, second: float) -> Array:
	return [
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": first},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": second},
		{"kind": "randint", "args": [0, 8], "value": 1},
	]


func _shot_signature(result: Dictionary) -> String:
	if result["records"].is_empty():
		return "none"
	var record: Dictionary = result["records"][0]
	return "%d:%d:%d" % [int(record["outcome"]), int(record["part"]), int(record["region_id"])]


func _context(
		history,
		now: float,
		eye: Array,
		pitch: float,
		yaw: float,
		rtt_ms: float,
		interp_ticks: int,
		claimed_tick: float,
		world_boxes: Array,
		teams: Dictionary,
		config: Dictionary = {},
		rng_override: Variant = null,
		sent_mask: int = 0xFFFF,
		shot_index: int = 1,
		cmd_seq: int = 10,
		weapon_id: String = "AK47",
		weapon_state_override: Dictionary = {},
		move_state_override: Dictionary = {},
		hitbox_config_overrides: Dictionary = {}
	) -> Dictionary:
	var weapon_state := weapon_state_override
	if weapon_state.is_empty():
		weapon_state = RecoilLogic.initial_state(weapon_id)
	var move_state := move_state_override
	if move_state.is_empty():
		move_state = {"in_air": false, "horizontal_speed": 0.0, "crouched": false}
	var rng_source = rng_override if rng_override != null else RngTypes.ReplayRng.new(_zero_shot_draws(), false)
	return {
		"now": now,
		"tick_rate": 128,
		"shooter": {
			"slot": 0,
			"eye64": PackedFloat64Array(eye),
			"view_pitch": pitch,
			"view_yaw": yaw,
			"view_pitch_q": InputCommand.quantize_pitch(FrameAdapter.pitch_to_game_rad(pitch)),
			"view_yaw_q": InputCommand.quantize_yaw(FrameAdapter.yaw_to_game_rad(yaw)),
			"weapon_id": weapon_id,
			"weapon_state": weapon_state,
			"move_state": move_state,
			"cmd_seq": cmd_seq,
			"claimed_view_tick": claimed_tick,
			"shot_index": shot_index,
		},
		"rtt_ms": rtt_ms,
		"interp_ticks": interp_ticks,
		"history": history,
		"teams": teams,
		"world_boxes": world_boxes,
		"rng": rng_source,
		"sent_mask": sent_mask,
		"config": config,
		"hitbox_config": hitbox_config_overrides,
	}


func _zero_shot_draws() -> Array:
	return [
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "uniform", "args": [-0.5, 0.5], "value": 0.0},
		{"kind": "randint", "args": [0, 8], "value": 1},
	]


func _sample(tick: int, origin: Array, yaw: float, stance: int, alive: bool) -> Dictionary:
	return {
		"tick": tick,
		"origin64": PackedFloat64Array(origin),
		"yaw_deg": yaw,
		"stance": stance,
		"alive": alive,
	}


func _aim_angles(eye: Array, target: PackedFloat64Array) -> Array[float]:
	var dx := float(target[0]) - float(eye[0])
	var dy := float(target[1]) - float(eye[1])
	var dz := float(target[2]) - float(eye[2])
	var horizontal := sqrt(dx * dx + dy * dy)
	var yaw := rad_to_deg(atan2(dy, dx))
	var pitch := -rad_to_deg(atan2(dz, horizontal))
	return [
		_wire_pitch(pitch),
		_wire_yaw(yaw),
	]


func _wire_pitch(spec_pitch_deg: float) -> float:
	var pitch_q := InputCommand.quantize_pitch(FrameAdapter.pitch_to_game_rad(spec_pitch_deg))
	return FrameAdapter.pitch_to_spec_deg(InputCommand.dequantize_pitch(pitch_q))


func _wire_yaw(spec_yaw_deg: float) -> float:
	var yaw_q := InputCommand.quantize_yaw(FrameAdapter.yaw_to_game_rad(spec_yaw_deg))
	return FrameAdapter.yaw_to_spec_deg(InputCommand.dequantize_yaw(yaw_q))


func _check_float(name: String, got: float, want: float, tolerance: float) -> void:
	if absf(got - want) <= tolerance:
		passed += 1
		print("PASS  %s  got %.9f want %.9f" % [name, got, want])
	else:
		_fail("%s got %.12f want %.12f tolerance %.12f" % [name, got, want, tolerance])


func _check_vec3d(name: String, got: PackedFloat64Array, want: Array, tolerance: float) -> void:
	var error := maxf(
		maxf(absf(got[0] - float(want[0])), absf(got[1] - float(want[1]))),
		absf(got[2] - float(want[2]))
	)
	if error <= tolerance:
		passed += 1
		print("PASS  %s  got (%.9f, %.9f, %.9f)" % [name, got[0], got[1], got[2]])
	else:
		_fail("%s error %.12f" % [name, error])


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
