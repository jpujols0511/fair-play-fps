extends SceneTree

const RayBoxLogic = preload("res://hitreg/ray_box.gd")
const HitboxBuilder = preload("res://hitreg/hitboxes.gd")
const HitboxConfig = preload("res://hitreg/hitbox_config.gd")
const WeaponConfig = preload("res://weapons/weapon_config.gd")
const SkeletonData = preload("res://shared/skeleton_constants.gd")

var passed := 0
var failed := 0


func _init() -> void:
	var version_info: Dictionary = Engine.get_version_info()
	var version_string := str(version_info.get("string", "unknown"))
	print("Godot version info: %s" % version_info)
	if not version_string.begins_with("4.4.1"):
		_fail("version guard expected Godot 4.4.1, got %s" % version_string)

	_test_rule1_slab()
	_test_rule2_overlap_priority()
	_test_rule3_inside_box()
	_test_rule4_near_miss_inclusive()
	_test_exact_near_miss_points()
	_test_near_miss_priority_and_determinism()
	_test_hitbox_integration()
	_test_range_config()
	_test_padding_boundaries()
	_test_crouched_head_chest()
	_test_golden_cases()
	_test_padded_golden_cases()
	_test_fail_closed_inputs()
	_test_cd7_golden_cases()
	_finish()


func _test_rule1_slab() -> void:
	var box := _box(1, "chest", [0.0, 0.0, 0.0], [1.0, 2.0, 3.0], 0.0)
	var hit := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		0.0
	)
	_check_bool("rule1_axis-aligned hit", hit["hit"], true)
	_check_float("rule1 entry distance", hit["dist"], 4.0, 1e-9)
	_check_vec3d("rule1 hit point", hit["point"], PackedFloat64Array([-1.0, 0.0, 0.0]), 1e-9)
	_check_vec3d("rule1 hit normal", hit["normal"], PackedFloat64Array([-1.0, 0.0, 0.0]), 1e-9)

	var parallel_face := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 2.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		0.0
	)
	_check_bool("rule1 parallel on face hits", parallel_face["hit"], true)
	_check_float("rule1 parallel face entry", parallel_face["dist"], 4.0, 1e-9)
	var parallel_outside := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 2.0000001, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		0.0
	)
	_check_bool("rule1 parallel outside misses", parallel_outside["hit"], false)

	var short_segment := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		3.999,
		box,
		0.0
	)
	_check_bool("rule1 segment ends before box", short_segment["hit"], false)
	var endpoint_hit := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		4.0,
		box,
		0.0
	)
	_check_bool("rule1 endpoint hit is inclusive", endpoint_hit["hit"], true)

	var behind := RayBoxLogic.intersect_box(
		PackedFloat64Array([5.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		0.0
	)
	_check_bool("rule1 box behind shooter misses", behind["hit"], false)

	var rotated := _box(2, "chest", [0.0, 0.0, 0.0], [1.0, 1.0, 1.0], 90.0)
	var rotated_hit := RayBoxLogic.intersect_box(
		PackedFloat64Array([0.0, -5.0, 0.0]),
		PackedFloat64Array([0.0, 1.0, 0.0]),
		10.0,
		rotated,
		0.0
	)
	_check_bool("rule1 yaw-frame slab hit", rotated_hit["hit"], true)
	_check_float("rule1 yaw-frame distance", rotated_hit["dist"], 4.0, 1e-9)
	_check_vec3d(
		"rule1 yaw-frame normal",
		rotated_hit["normal"],
		PackedFloat64Array([0.0, -1.0, 0.0]),
		1e-9
	)


func _test_rule2_overlap_priority() -> void:
	var head := _box(0, "head", [10.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var chest_near_tie := _box(1, "chest", [10.0000005, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var tie := RayBoxLogic.trace_boxes(
		PackedFloat64Array([0.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		20.0,
		[chest_near_tie, head],
		{0: 0.0, 1: 0.0}
	)
	_check_bool("rule2 head wins within distance tolerance", tie["box_id"], 0)

	var arm_left := _box(3, "upper_arm_l", [10.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var arm_right := _box(4, "upper_arm_r", [10.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var same_priority := RayBoxLogic.trace_boxes(
		PackedFloat64Array([0.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		20.0,
		[arm_right, arm_left],
		{3: 0.0, 4: 0.0}
	)
	_check_bool("rule2 lower id wins within priority group", same_priority["box_id"], 3)

	var head_farther := _box(0, "head", [11.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var chest_first := _box(1, "chest", [10.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var first_entry := RayBoxLogic.trace_boxes(
		PackedFloat64Array([0.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		20.0,
		[head_farther, chest_first],
		{0: 0.0, 1: 0.0}
	)
	_check_bool("rule2 smaller entry wins outside tolerance", first_entry["box_id"], 1)


func _test_rule3_inside_box() -> void:
	var box := _box(0, "head", [0.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var inside := RayBoxLogic.intersect_box(
		PackedFloat64Array([0.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		0.0,
		box,
		0.0
	)
	_check_bool("rule3 starts inside counts as hit", inside["hit"], true)
	_check_float("rule3 inside distance is zero", inside["dist"], 0.0, 1e-12)
	_check_vec3d(
		"rule3 inside point is origin",
		inside["point"],
		PackedFloat64Array([0.0, 0.0, 0.0]),
		1e-12
	)
	var boundary := RayBoxLogic.intersect_box(
		PackedFloat64Array([-1.0, 0.0, 0.0]),
		PackedFloat64Array([-1.0, 0.0, 0.0]),
		1.0,
		box,
		0.0
	)
	_check_bool("rule3 boundary start counts as inside", boundary["hit"], true)
	_check_float("rule3 boundary start distance", boundary["dist"], 0.0, 1e-12)


func _test_hitbox_integration() -> void:
	var target_boxes: Array = HitboxBuilder.build_boxes_precise(
		PackedFloat64Array([500.0, 0.0, 0.0]),
		180.0,
		HitboxBuilder.STAND
	)
	var result := RayBoxLogic.trace_boxes(
		PackedFloat64Array([0.0, 0.0, 64.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		8192.0,
		target_boxes
	)
	_check_bool("standing skeleton ray hits head", result["box_id"], 0)
	_check_float("standing skeleton padded head distance", result["dist"], 494.0, 1e-9)
	_check_vec3d(
		"standing skeleton padded hit point",
		result["point"],
		PackedFloat64Array([494.0, 0.0, 64.0]),
		1e-9
	)
	var unpadded := RayBoxLogic.trace_boxes(
		PackedFloat64Array([0.0, 0.0, 64.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		8192.0,
		target_boxes,
		_zero_padding_map(target_boxes)
	)
	_check_float("zero-padding skeleton hit restores legacy distance", unpadded["dist"], 496.0, 1e-9)
	_check_vec3d(
		"zero-padding skeleton hit restores legacy point",
		unpadded["point"],
		PackedFloat64Array([496.0, 0.0, 64.0]),
		1e-9
	)


func _test_rule4_near_miss_inclusive() -> void:
	var target_boxes: Array = HitboxBuilder.build_boxes_precise(
		PackedFloat64Array([500.0, 0.0, 0.0]),
		180.0,
		HitboxBuilder.STAND
	)
	var ladder := [
		{"z": 72.5, "outcome": "near_miss", "distance": 0.5},
		{"z": 72.99, "outcome": "near_miss", "distance": 0.99},
		{"z": 73.0, "outcome": "near_miss", "distance": 1.0},
		{"z": 73.01, "outcome": "none", "distance": 1.01},
	]
	for rung in ladder:
		var origin := PackedFloat64Array([0.0, 0.0, float(rung["z"])])
		var result := RayBoxLogic.trace_target(
			origin,
			PackedFloat64Array([1.0, 0.0, 0.0]),
			8192.0,
			target_boxes,
			_zero_padding_map(target_boxes),
			1.0
		)
		_check_bool("rule4 z %.2f outcome" % rung["z"], result["outcome"], rung["outcome"])
		_check_float("rule4 z %.2f closest distance" % rung["z"], result["dist"], rung["distance"], 1e-9)
		_check_bool("rule4 z %.2f closest box" % rung["z"], result["box_id"], 0)
		_check_vec3d(
			"rule4 z %.2f ray point" % rung["z"],
			result["ray_point"],
			PackedFloat64Array([496.0, 0.0, float(rung["z"])]),
			1e-9
		)
		_check_vec3d(
			"rule4 z %.2f box point" % rung["z"],
			result["box_point"],
			PackedFloat64Array([496.0, 0.0, 72.0]),
			1e-9
		)


func _test_exact_near_miss_points() -> void:
	var box := _box(2, "stomach", [0.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var diagonal := RayBoxLogic.trace_target(
		PackedFloat64Array([-5.0, 1.5, 1.5]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		[box],
		{2: 0.0},
		1.0
	)
	_check_bool("diagonal closest approach outcome", diagonal["outcome"], "near_miss")
	_check_float("diagonal closest approach distance", diagonal["dist"], sqrt(0.5), 1e-9)
	_check_vec3d(
		"diagonal closest ray point",
		diagonal["ray_point"],
		PackedFloat64Array([-1.0, 1.5, 1.5]),
		1e-9
	)
	_check_vec3d(
		"diagonal closest box point",
		diagonal["box_point"],
		PackedFloat64Array([-1.0, 1.0, 1.0]),
		1e-9
	)

	var clipped := RayBoxLogic.trace_target(
		PackedFloat64Array([-5.0, 3.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		3.0,
		[box],
		{2: 0.0},
		1.0
	)
	_check_float("near miss clips to segment endpoint", clipped["dist"], sqrt(5.0), 1e-9)
	_check_vec3d(
		"clipped nearest ray point",
		clipped["ray_point"],
		PackedFloat64Array([-2.0, 3.0, 0.0]),
		1e-9
	)
	_check_vec3d(
		"clipped nearest box point",
		clipped["box_point"],
		PackedFloat64Array([-1.0, 1.0, 0.0]),
		1e-9
	)


func _test_near_miss_priority_and_determinism() -> void:
	var head := _box(0, "head", [10.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var chest := _box(1, "chest", [10.0000005, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var origin := PackedFloat64Array([0.0, 1.5, 0.0])
	var direction := PackedFloat64Array([1.0, 0.0, 0.0])
	var first := RayBoxLogic.trace_target(
		origin, direction, 20.0, [chest, head], {0: 0.0, 1: 0.0}, 1.0
	)
	var second := RayBoxLogic.trace_target(
		origin, direction, 20.0, [chest, head], {0: 0.0, 1: 0.0}, 1.0
	)
	_check_bool("near-miss tie selects head priority", first["box_id"], 0)
	_check_bool("near-miss repeated result is deterministic", first["box_id"], second["box_id"])
	_check_float("near-miss repeated distance is deterministic", first["dist"], second["dist"], 0.0)
	_check_vec3d("near-miss repeated ray point is deterministic", first["ray_point"], second["ray_point"], 0.0)
	_check_vec3d("near-miss repeated box point is deterministic", first["box_point"], second["box_point"], 0.0)


func _test_range_config() -> void:
	_check_float("J17 proposed weapon range", WeaponConfig.WEAPON_RANGE_UNITS, 8192.0, 1e-12)
	_check_float("A4 default hitbox padding", HitboxConfig.HITBOX_PADDING, 2.0, 1e-12)
	_check_float("A4 near-miss log threshold", HitboxConfig.NEAR_MISS_LOG_UNITS, 4.0, 1e-12)
	for box_id in range(11):
		_check_float(
			"A4 per-bone padding %d" % box_id,
			float(HitboxConfig.HITBOX_PADDING_PER_BONE[box_id]),
			2.0,
			1e-12
		)


func _test_padding_boundaries() -> void:
	var box := _box(0, "head", [0.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var edge := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 3.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		2.0
	)
	_check_bool("A4 h+2 padded edge counts as a hit", edge["hit"], true)
	_check_float("A4 padded edge entry", edge["dist"], 2.0, 1e-9)

	var outside_origin := PackedFloat64Array([-5.0, 3.000001, 0.0])
	var outside_hit := RayBoxLogic.intersect_box(
		outside_origin,
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		2.0
	)
	_check_bool("A4 h+2+1e-6 misses the padded box", outside_hit["hit"], false)
	var outside_trace := RayBoxLogic.trace_target(
		outside_origin,
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		[box]
	)
	_check_bool("A4 padded edge outside remains a near miss", outside_trace["outcome"], "near_miss")
	_check_float("A4 distance to padded edge", outside_trace["dist"], 1e-6, 1e-9)

	var inside_padding := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 2.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		2.0
	)
	_check_bool("A4 h+1 is outside raw box but inside padding", inside_padding["hit"], true)

	var raw_front := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		0.0
	)
	var padded_front := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		2.0
	)
	_check_float("A4 zero padding restores raw entry", raw_front["dist"], 4.0, 1e-9)
	_check_float("A4 frontal padding moves entry 2 units closer", raw_front["dist"] - padded_front["dist"], 2.0, 1e-9)

	var at_four := RayBoxLogic.trace_target(
		PackedFloat64Array([-5.0, 0.0, 7.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		[box]
	)
	_check_bool("A4 near miss at 4.0 is logged", at_four["outcome"], "near_miss")
	_check_float("A4 padded near-miss distance 4.0", at_four["dist"], 4.0, 1e-9)
	var over_four := RayBoxLogic.trace_target(
		PackedFloat64Array([-5.0, 0.0, 7.000001]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		[box]
	)
	_check_bool("A4 near miss at 4.0+1e-6 is not logged", over_four["outcome"], "none")
	_check_float("A4 over-threshold distance", over_four["dist"], 4.000001, 1e-9)


func _test_crouched_head_chest() -> void:
	var target_boxes: Array = HitboxBuilder.build_boxes_precise(
		PackedFloat64Array([500.0, 0.0, 0.0]),
		180.0,
		HitboxBuilder.CROUCH
	)
	var zero_padding := _zero_padding_map(target_boxes)
	var head := RayBoxLogic.trace_target(
		PackedFloat64Array([0.0, 0.0, 33.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		8192.0,
		target_boxes,
		zero_padding,
		1.0
	)
	_check_bool("A2 test 7 z=33.0 selects crouched head", head["box_id"], 0)
	_check_float("A2 test 7 unpadded head entry", head["dist"], 496.0, 1e-9)
	var chest := RayBoxLogic.trace_target(
		PackedFloat64Array([0.0, 0.0, 27.25]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		8192.0,
		target_boxes,
		zero_padding,
		1.0
	)
	_check_bool("A2 test 7 z=27.25 entry-first selects chest", chest["box_id"], 1)
	_check_float("A2 test 7 unpadded chest entry", chest["dist"], 492.0, 1e-9)

	var padded_head := RayBoxLogic.trace_target(
		PackedFloat64Array([0.0, 0.0, 33.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		8192.0,
		target_boxes
	)
	_check_bool("A4 padded z=33.0 selects crouched head", padded_head["box_id"], 0)
	_check_float("A4 padded z=33.0 head entry", padded_head["dist"], 494.0, 1e-9)
	var padded_chest := RayBoxLogic.trace_target(
		PackedFloat64Array([0.0, 0.0, 27.25]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		8192.0,
		target_boxes
	)
	_check_bool("A4 padded entry-first z=27.25 selects chest", padded_chest["box_id"], 1)
	_check_float("A4 padded chest entry", padded_chest["dist"], 490.0, 1e-9)
	var head_priority := RayBoxLogic.trace_target(
		PackedFloat64Array([0.0, 0.0, 27.25]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		8192.0,
		target_boxes,
		{},
		HitboxConfig.NEAR_MISS_LOG_UNITS,
		{"CROUCH_HEAD_OVERLAP_RULE": "head_priority_in_overlap"}
	)
	_check_bool("A2-b head-priority alternative wins padded overlap", head_priority["box_id"], 0)
	_check_float("A2-b head-priority entry uses the head surface", head_priority["dist"], 494.0, 1e-9)


func _test_golden_cases() -> void:
	var file := FileAccess.open("res://tests/ray_box_cases.json", FileAccess.READ)
	if file == null:
		_fail("cannot open tests/ray_box_cases.json")
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("ray_box_cases.json is not a JSON object")
		return
	var case_data: Dictionary = parsed
	var cases: Array = case_data["cases"]
	_check_bool("golden case total", cases.size(), int(case_data["case_count"]))
	_check_bool("required seeded random cases", int(case_data["random_case_count"]), 20000)

	var expected_digest := _hash_expected_cases(cases)
	print("Canonical expected-results SHA-256: %s" % expected_digest)
	_check_bool("Python/GDScript expected-results SHA-256", expected_digest, case_data["expected_sha256"])

	var first_run := _evaluate_golden_cases(cases, true)
	print(
		"Golden summary: %d cases; maximum absolute error %.12f"
		% [cases.size(), first_run["max_error"]]
	)
	for category in case_data["case_counts"]:
		_check_bool(
			"golden category %s count" % category,
			int(first_run["category_counts"].get(category, 0)),
			int(case_data["case_counts"][category])
		)
	_check_float("golden maximum absolute error", first_run["max_error"], 0.0, 1e-6)

	var second_run := _evaluate_golden_cases(cases, false)
	print("Deterministic result SHA-256: %s" % first_run["result_sha256"])
	_check_bool("golden suite rerun is byte-identical", first_run["result_sha256"], second_run["result_sha256"])


func _test_padded_golden_cases() -> void:
	var file := FileAccess.open("res://tests/ray_box_padded_cases.json", FileAccess.READ)
	if file == null:
		_fail("cannot open tests/ray_box_padded_cases.json")
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("ray_box_padded_cases.json is not a JSON object")
		return
	var case_data: Dictionary = parsed
	var cases: Array = case_data["cases"]
	_check_bool("padded golden case total", cases.size(), int(case_data["case_count"]))
	_check_bool("padded seeded random cases", int(case_data["random_case_count"]), 20000)
	_check_bool("padded threshold is 4 units", float(case_data["near_miss_limit"]), 4.0)
	_check_float("padded amount is 2 units", float(case_data["padding"]), 2.0, 1e-12)
	var expected_digest := _hash_expected_cases(cases)
	print("Padded expected-results SHA-256: %s" % expected_digest)
	_check_bool("padded Python/GDScript expected-results SHA-256", expected_digest, case_data["expected_sha256"])
	var run := _evaluate_golden_cases(cases, true)
	print(
		"Padded golden summary: %d cases; maximum absolute error %.12f"
		% [cases.size(), run["max_error"]]
	)
	for category in case_data["case_counts"]:
		_check_bool(
			"padded category %s count" % category,
			int(run["category_counts"].get(category, 0)),
			int(case_data["case_counts"][category])
		)
	_check_float("padded golden maximum absolute error", run["max_error"], 0.0, 1e-6)


func _test_fail_closed_inputs() -> void:
	var box := _box(0, "head", [0.0, 0.0, 0.0], [1.0, 1.0, 1.0], 0.0)
	var nonfinite_origin := RayBoxLogic.intersect_box(
		PackedFloat64Array([NAN, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		box,
		0.0
	)
	_check_bool("non-finite origin fails closed", nonfinite_origin["hit"], false)
	var nonfinite_direction := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 0.0, 0.0]),
		PackedFloat64Array([NAN, 0.0, 0.0]),
		10.0,
		box,
		0.0
	)
	_check_bool("non-finite direction fails closed", nonfinite_direction["hit"], false)
	var nonfinite_length := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		NAN,
		box,
		0.0
	)
	_check_bool("non-finite length fails closed", nonfinite_length["hit"], false)
	var scaled_direction := RayBoxLogic.intersect_box(
		PackedFloat64Array([-5.0, 0.0, 0.0]),
		PackedFloat64Array([2.0, 0.0, 0.0]),
		10.0,
		box,
		0.0
	)
	_check_bool("non-unit direction fails closed", scaled_direction["hit"], false)
	var invalid_target := RayBoxLogic.trace_target(
		PackedFloat64Array([NAN, 0.0, 0.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		[box],
		{0: 0.0}
	)
	_check_bool("invalid target trace has no outcome", invalid_target["outcome"], "none")
	var exact_limit := RayBoxLogic.trace_target(
		PackedFloat64Array([-5.0, 0.0, 7.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		[box],
		{0: 2.0}
	)
	_check_bool("default near-miss limit includes 4.0", exact_limit["outcome"], "near_miss")
	_check_float("default near-miss distance is 4.0", exact_limit["dist"], 4.0, 1e-9)
	var legacy_limit := RayBoxLogic.trace_target(
		PackedFloat64Array([-5.0, 0.0, 7.0]),
		PackedFloat64Array([1.0, 0.0, 0.0]),
		10.0,
		[box],
		{0: 2.0},
		1.0
	)
	_check_bool("explicit legacy near-miss limit remains available", legacy_limit["outcome"], "none")


func _test_cd7_golden_cases() -> void:
	_test_cd7_golden(
		"res://tests/ray_box_cases_cd7.json",
		"CD-r7 zero-padding golden",
		1.0,
		0.0
	)
	_test_cd7_golden(
		"res://tests/ray_box_padded_cases_cd7.json",
		"CD-r7 padded golden",
		4.0,
		2.0
	)


func _test_cd7_golden(path: String, label: String, near_miss_limit: float, padding: float) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		_fail("cannot open %s" % path)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		_fail("%s is not a JSON object" % path)
		return
	var case_data: Dictionary = parsed
	var cases: Array = case_data["cases"]
	_check_bool("%s skeleton SHA" % label, case_data["skeleton_sha256"], SkeletonData.SKELETON_SHA256)
	_check_bool("%s case count" % label, cases.size(), int(case_data["case_count"]))
	_check_bool("%s near-miss threshold" % label, float(case_data["near_miss_limit"]), near_miss_limit)
	if padding > 0.0:
		_check_float("%s padding" % label, float(case_data["padding"]), padding, 1e-12)
	else:
		_check_bool("%s explicitly retains the legacy 1.0 logger" % label, bool(case_data.get("fixture_scope", "").contains("legacy")), true)
	var digest := _hash_expected_cases(cases)
	_check_bool("%s Python expected-results SHA" % label, digest, case_data["expected_sha256"])
	var result := _evaluate_golden_cases(cases, true)
	_check_float("%s maximum numeric error" % label, float(result["max_error"]), 0.0, 1e-6)


func _evaluate_golden_cases(cases: Array, validate: bool) -> Dictionary:
	var hash_context := HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update("[".to_utf8_buffer())
	var category_counts := {}
	var max_error := 0.0

	for index in range(cases.size()):
		var case: Dictionary = cases[index]
		var boxes := _load_case_boxes(case)
		var origin := PackedFloat64Array(case["origin"])
		var direction := PackedFloat64Array(case["direction"])
		var padding_by_box := _padding_map_for_case(case, boxes)
		var near_miss_limit := float(case.get("near_miss_limit", 1.0))
		var result := RayBoxLogic.trace_target(
			origin,
			direction,
			float(case["length"]),
			boxes,
			padding_by_box,
			near_miss_limit
		)
		var expected: Dictionary = case["expected"]
		var case_error := _case_error(result, expected)
		max_error = maxf(max_error, case_error)

		if validate:
			var category := str(case["category"])
			category_counts[category] = int(category_counts.get(category, 0)) + 1
			if (
					result["outcome"] != expected["outcome"]
					or int(result["box_id"]) != int(expected["box_id"])
					or result["part"] != expected["part"]
					or case_error > 1e-6
				):
				_fail(
					"golden case %d category %s max_error %.12f got %s expected %s input=%s"
					% [
						index,
						category,
						case_error,
						JSON.stringify(result),
						JSON.stringify(expected),
						JSON.stringify(case),
					]
				)

		if index > 0:
			hash_context.update(",".to_utf8_buffer())
		hash_context.update(_canonical_result_row(result).to_utf8_buffer())

	hash_context.update("]".to_utf8_buffer())
	return {
		"category_counts": category_counts,
		"max_error": max_error,
		"result_sha256": hash_context.finish().hex_encode(),
	}


func _padding_map_for_case(case: Dictionary, boxes: Array) -> Dictionary:
	var padding_by_box: Dictionary = {}
	var per_box: Dictionary = case.get("padding_by_box", {})
	if per_box.is_empty():
		var padding := float(case.get("padding", 0.0))
		for box in boxes:
			padding_by_box[int(box["id"])] = padding
	else:
		for key in per_box:
			padding_by_box[int(key)] = float(per_box[key])
	return padding_by_box


func _load_case_boxes(case: Dictionary) -> Array:
	var boxes: Array = []
	for source in case["boxes"]:
		var box: Dictionary = source.duplicate(true)
		box["center64"] = PackedFloat64Array(source["center64"])
		box["half64"] = PackedFloat64Array(source["half64"])
		boxes.append(box)
	return boxes


func _case_error(result: Dictionary, expected: Dictionary) -> float:
	var error := absf(float(result["dist"]) - float(expected["dist"]))
	for axis in range(3):
		error = maxf(error, absf(result["ray_point"][axis] - float(expected["ray_point"][axis])))
		error = maxf(error, absf(result["box_point"][axis] - float(expected["box_point"][axis])))
	return error


func _hash_expected_cases(cases: Array) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update("[".to_utf8_buffer())
	for index in range(cases.size()):
		if index > 0:
			context.update(",".to_utf8_buffer())
		context.update(_canonical_expected_row(cases[index]["expected"]).to_utf8_buffer())
	context.update("]".to_utf8_buffer())
	return context.finish().hex_encode()


func _canonical_expected_row(expected: Dictionary) -> String:
	return _canonical_row(
		int(expected["box_id"]),
		str(expected["part"]),
		str(expected["outcome"]),
		float(expected["dist"]),
		expected["ray_point"],
		expected["box_point"]
	)


func _canonical_result_row(result: Dictionary) -> String:
	return _canonical_row(
		int(result["box_id"]),
		str(result["part"]),
		str(result["outcome"]),
		float(result["dist"]),
		result["ray_point"],
		result["box_point"]
	)


func _canonical_row(
		box_id: int,
		part: String,
		outcome: String,
		distance: float,
		ray_point: Variant,
		box_point: Variant
	) -> String:
	return (
		"{\"box_id\":%d,\"box_point_q\":[%d,%d,%d],\"dist_q\":%d,\"outcome\":%s,"
		+ "\"part\":%s,\"ray_point_q\":[%d,%d,%d]}"
	) % [
		box_id,
		_quantize_hash_value(float(box_point[0])),
		_quantize_hash_value(float(box_point[1])),
		_quantize_hash_value(float(box_point[2])),
		_quantize_hash_value(distance),
		JSON.stringify(outcome),
		JSON.stringify(part),
		_quantize_hash_value(float(ray_point[0])),
		_quantize_hash_value(float(ray_point[1])),
		_quantize_hash_value(float(ray_point[2])),
	]


func _quantize_hash_value(value: float) -> int:
	var scaled := value * 1000000000.0
	return int(floor(scaled + 0.5)) if scaled >= 0.0 else int(ceil(scaled - 0.5))


func _box(id: int, part: String, center: Array, half: Array, yaw_deg: float) -> Dictionary:
	return {
		"id": id,
		"part": part,
		"center64": PackedFloat64Array(center),
		"half64": PackedFloat64Array(half),
		"yaw_deg": yaw_deg,
	}


func _zero_padding_map(boxes: Array) -> Dictionary:
	var result: Dictionary = {}
	for box in boxes:
		result[int(box["id"])] = 0.0
	return result


func _check_float(name: String, got: float, want: float, tolerance: float) -> void:
	if absf(got - want) <= tolerance:
		passed += 1
		print("PASS  %s  got %.9f want %.9f" % [name, got, want])
	else:
		_fail("%s got %.12f want %.12f tolerance %.12f" % [name, got, want, tolerance])


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
