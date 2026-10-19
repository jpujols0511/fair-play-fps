extends SceneTree

const HitboxBuilder = preload("res://hitreg/hitboxes.gd")
const ConfigData = preload("res://hitreg/hitbox_config.gd")
const SkeletonData = preload("res://shared/skeleton_constants.gd")
const FrameAdapter = preload("res://shared/frame.gd")
const InputCommand = preload("res://shared/input_cmd.gd")

const EXPECTED_PARTS := [
	"head", "chest", "stomach", "upper_arm_l", "upper_arm_r",
	"forearm_l", "forearm_r", "thigh_l", "thigh_r", "shin_l", "shin_r",
]
const EXPECTED_SIZES := [
	Vector3(8.0, 8.0, 12.0), Vector3(16.0, 16.0, 11.0), Vector3(14.0, 14.0, 9.0),
	Vector3(8.0, 8.0, 16.0), Vector3(8.0, 8.0, 16.0),
	Vector3(7.0, 7.0, 15.0), Vector3(7.0, 7.0, 15.0),
	Vector3(11.0, 11.0, 19.0), Vector3(11.0, 11.0, 19.0),
	Vector3(9.0, 9.0, 19.0), Vector3(9.0, 9.0, 19.0),
]
const EXPECTED_CENTERS := [
	Vector3(0.0, 0.0, 66.0), Vector3(0.0, 0.0, 54.5), Vector3(0.0, 0.0, 44.5),
	Vector3(0.0, 12.0, 50.0), Vector3(0.0, -12.0, 50.0),
	Vector3(0.0, 12.0, 34.5), Vector3(0.0, -12.0, 34.5),
	Vector3(0.0, 4.0, 30.5), Vector3(0.0, -4.0, 30.5),
	Vector3(0.0, 4.0, 11.5), Vector3(0.0, -4.0, 11.5),
]
const EXPECTED_STAND_BOTTOMS := [60.0, 49.0, 40.0, 42.0, 42.0, 27.0, 27.0, 21.0, 21.0, 2.0, 2.0]
const EXPECTED_STAND_TOPS := [72.0, 60.0, 49.0, 58.0, 58.0, 42.0, 42.0, 40.0, 40.0, 21.0, 21.0]
const EXPECTED_CROUCH_BOTTOMS := [24.0, 24.5, 20.0, 21.0, 21.0, 13.5, 13.5, 10.5, 10.5, 1.0, 1.0]
const EXPECTED_CROUCH_TOPS := [36.0, 30.0, 24.5, 29.0, 29.0, 21.0, 21.0, 20.0, 20.0, 10.5, 10.5]
const EXPECTED_SKELETON_SHA256 := "56db86a8d12c400f5149f7cfcbf17ec79dd662c93cc6a3d5f18d4d0c288f7aa0"

var passed := 0
var failed := 0


func _init() -> void:
	var version_info: Dictionary = Engine.get_version_info()
	var version_string := str(version_info.get("string", "unknown"))
	print("Godot version info: %s" % version_info)
	if not version_string.begins_with("4.4.1"):
		_fail("version guard expected Godot 4.4.1, got %s" % version_string)

	_test_table()
	_test_standing_geometry()
	_test_crouched_geometry()
	_test_duck_fraction()
	_test_yaw()
	_test_jump_poses()
	_test_frame_and_input_quantization()
	_test_config_and_hash()
	_finish()


func _test_table() -> void:
	var boxes: Array = HitboxBuilder.build_boxes(Vector3.ZERO, 0.0, HitboxBuilder.STAND)
	_check_bool("standing returns 11 boxes", boxes.size() == 11, true)
	for i in range(11):
		var box: Dictionary = boxes[i]
		_check_bool("box %d id" % i, box["id"] == i, true)
		_check_bool("box %d part" % i, box["part"] == EXPECTED_PARTS[i], true)
		_check_vec3d("box %d size" % i, _scale_float64(box["half64"], 2.0), _as_float64(EXPECTED_SIZES[i]), 1e-9)
		_check_vec3d(
			"box %d standing center" % i,
			box["center64"],
			_as_float64(EXPECTED_CENTERS[i]),
			1e-9
		)
		_check_bool("box %d includes Vector3 view" % i, typeof(box["center"]) == TYPE_VECTOR3, true)


func _test_standing_geometry() -> void:
	var boxes: Array = HitboxBuilder.build_boxes(Vector3.ZERO, 0.0, HitboxBuilder.STAND)
	for i in range(11):
		var box: Dictionary = boxes[i]
		_check_float(
			"standing box %d bottom" % i,
			box["center64"][2] - box["half64"][2],
			EXPECTED_STAND_BOTTOMS[i],
			1e-9
		)
		_check_float(
			"standing box %d top" % i,
			box["center64"][2] + box["half64"][2],
			EXPECTED_STAND_TOPS[i],
			1e-9
		)

	var stack_height := 2.0 + 19.0 + 19.0 + 9.0 + 11.0 + 12.0
	_check_float("standing segment stack", stack_height, 72.0, 1e-9)
	_check_float("head top equals stand height", boxes[0]["center64"][2] + boxes[0]["half64"][2], 72.0, 1e-9)
	var standing_eye := HitboxBuilder.eye_height(HitboxBuilder.STAND)
	_check_bool(
		"standing eye is inside head",
		standing_eye >= boxes[0]["center64"][2] - boxes[0]["half64"][2]
				and standing_eye <= boxes[0]["center64"][2] + boxes[0]["half64"][2],
		true
	)
	_check_float("left arm center beside chest", boxes[3]["center64"][1], 12.0, 1e-9)
	_check_float("right arm center beside chest", boxes[4]["center64"][1], -12.0, 1e-9)
	var thigh_left: Dictionary = boxes[7]
	var thigh_right: Dictionary = boxes[8]
	var overlap := minf(
		thigh_left["center64"][1] + thigh_left["half64"][1],
		thigh_right["center64"][1] + thigh_right["half64"][1]
	) - maxf(
		thigh_left["center64"][1] - thigh_left["half64"][1],
		thigh_right["center64"][1] - thigh_right["half64"][1]
	)
	_check_float("thigh overlap", overlap, 3.0, 1e-9)


func _test_crouched_geometry() -> void:
	var boxes: Array = HitboxBuilder.build_boxes(Vector3.ZERO, 0.0, HitboxBuilder.CROUCH)
	for i in range(11):
		var box: Dictionary = boxes[i]
		_check_float(
			"crouched box %d bottom" % i,
			box["center64"][2] - box["half64"][2],
			EXPECTED_CROUCH_BOTTOMS[i],
			1e-9
		)
		_check_float(
			"crouched box %d top" % i,
			box["center64"][2] + box["half64"][2],
			EXPECTED_CROUCH_TOPS[i],
			1e-9
		)
		_check_float("crouched box %d depth unchanged" % i, box["half64"][0] * 2.0, EXPECTED_SIZES[i].x, 1e-9)
		_check_float("crouched box %d width unchanged" % i, box["half64"][1] * 2.0, EXPECTED_SIZES[i].y, 1e-9)

	_check_float("crouched head remains 12 tall", boxes[0]["half64"][2] * 2.0, 12.0, 1e-9)
	_check_float("crouched eye height", HitboxBuilder.eye_height(HitboxBuilder.CROUCH), 32.0, 1e-9)
	var crouched_eye := HitboxBuilder.eye_height(HitboxBuilder.CROUCH)
	_check_bool(
		"crouched eye is inside head",
		crouched_eye >= boxes[0]["center64"][2] - boxes[0]["half64"][2]
				and crouched_eye <= boxes[0]["center64"][2] + boxes[0]["half64"][2],
		true
	)
	var head_bottom: float = float(boxes[0]["center64"][2]) - float(boxes[0]["half64"][2])
	var head_top: float = float(boxes[0]["center64"][2]) + float(boxes[0]["half64"][2])
	var chest_bottom: float = float(boxes[1]["center64"][2]) - float(boxes[1]["half64"][2])
	var chest_top: float = float(boxes[1]["center64"][2]) + float(boxes[1]["half64"][2])
	_check_float(
		"raw crouched head/chest overlap z=24.5..30",
		minf(head_top, chest_top) - maxf(head_bottom, chest_bottom),
		5.5,
		1e-9
	)
	_check_float("raw crouched head-only top band", head_top - chest_top, 6.0, 1e-9)
	_check_float("raw crouched head-only bottom sliver", chest_bottom - head_bottom, 0.5, 1e-9)


func _test_duck_fraction() -> void:
	var zero := PackedFloat64Array([0.0, 0.0, 0.0])
	var standing: Array = HitboxBuilder.build_boxes_precise(zero, 0.0, HitboxBuilder.STAND, 0.0)
	var crouched: Array = HitboxBuilder.build_boxes_precise(zero, 0.0, HitboxBuilder.CROUCH, 1.0)
	var mid_duck: Array = HitboxBuilder.build_boxes_precise(zero, 0.0, HitboxBuilder.STAND, 0.5)
	_check_float("A2-a half crouch head top", crouched[0]["center64"][2] + crouched[0]["half64"][2], 36.0, 1e-9)
	_check_float("A2-a half crouch head center", crouched[0]["center64"][2], 30.0, 1e-9)
	_check_float("A2-a half crouch chest center", crouched[1]["center64"][2], 27.25, 1e-9)
	_check_float("A3 half-duck head bottom", mid_duck[0]["center64"][2] - mid_duck[0]["half64"][2], 42.0, 1e-9)
	_check_float("A3 half-duck head top", mid_duck[0]["center64"][2] + mid_duck[0]["half64"][2], 54.0, 1e-9)
	_check_float("A3 half-duck eye", HitboxBuilder.eye_height(HitboxBuilder.STAND, 0.5), 48.0, 1e-9)
	for i in range(11):
		_check_vec3d(
			"A3 duck fraction zero reproduces standing box %d" % i,
			HitboxBuilder.build_boxes_precise(zero, 0.0, HitboxBuilder.CROUCH, 0.0)[i]["center64"],
			standing[i]["center64"],
			1e-9
		)
		_check_vec3d(
			"A3 duck fraction zero reproduces standing size %d" % i,
			HitboxBuilder.build_boxes_precise(zero, 0.0, HitboxBuilder.CROUCH, 0.0)[i]["half64"],
			standing[i]["half64"],
			1e-9
		)
		_check_vec3d(
			"A3 duck fraction one reproduces crouched box %d" % i,
			HitboxBuilder.build_boxes_precise(zero, 0.0, HitboxBuilder.STAND, 1.0)[i]["center64"],
			crouched[i]["center64"],
			1e-9
		)
		_check_vec3d(
			"A3 duck fraction one reproduces crouched size %d" % i,
			HitboxBuilder.build_boxes_precise(zero, 0.0, HitboxBuilder.STAND, 1.0)[i]["half64"],
			crouched[i]["half64"],
			1e-9
		)
	for step in range(65):
		var fraction := float(step) / 64.0
		var boxes: Array = HitboxBuilder.build_boxes_precise(zero, 0.0, HitboxBuilder.STAND, fraction)
		var eye := HitboxBuilder.eye_height(HitboxBuilder.STAND, fraction)
		_check_bool(
			"A3 eye stays strictly inside head f=%.5f" % fraction,
			eye > boxes[0]["center64"][2] - boxes[0]["half64"][2]
				and eye < boxes[0]["center64"][2] + boxes[0]["half64"][2],
			true
		)
	_check_bool("A2-b default overlap rule is entry first", ConfigData.CROUCH_HEAD_OVERLAP_RULE, "entry_first")
	_check_bool(
		"A2-b head priority alternative is configurable",
		ConfigData.with_overrides({
			"CROUCH_HEAD_OVERLAP_RULE": "head_priority_in_overlap",
		})["CROUCH_HEAD_OVERLAP_RULE"],
		"head_priority_in_overlap"
	)


func _test_yaw() -> void:
	var origin := PackedFloat64Array([10.0, 20.0, 33.5])
	for yaw_deg in [0.0, 90.0, 180.0, 270.0, 37.5]:
		var boxes: Array = HitboxBuilder.build_boxes_precise(origin, yaw_deg, HitboxBuilder.STAND)
		var radians := deg_to_rad(yaw_deg)
		var c := cos(radians)
		var s := sin(radians)
		for i in range(11):
			var local: Vector3 = EXPECTED_CENTERS[i]
			var expected := PackedFloat64Array([
				origin[0] + local.x * c - local.y * s,
				origin[1] + local.x * s + local.y * c,
				origin[2] + local.z,
			])
			_check_vec3d(
				"yaw %.1f box %d center" % [yaw_deg, i],
				boxes[i]["center64"],
				expected,
				1e-9
			)
			_check_vec3d(
				"yaw %.1f box %d half sizes" % [yaw_deg, i],
				boxes[i]["half64"],
				_as_float64(EXPECTED_SIZES[i] * 0.5),
				1e-9
			)
			_check_float("yaw %.1f box %d yaw" % [yaw_deg, i], boxes[i]["yaw_deg"], yaw_deg, 1e-9)
		_check_vec3d(
			"yaw %.1f forward axis" % yaw_deg,
			boxes[0]["axes64"][0],
			PackedFloat64Array([c, s, 0.0]),
			1e-9
		)
		_check_vec3d(
			"yaw %.1f left axis" % yaw_deg,
			boxes[0]["axes64"][1],
			PackedFloat64Array([-s, c, 0.0]),
			1e-9
		)
		_check_vec3d(
			"yaw %.1f z-up axis" % yaw_deg,
			boxes[0]["axes64"][2],
			PackedFloat64Array([0.0, 0.0, 1.0]),
			1e-9
		)

	var yaw90: Array = HitboxBuilder.build_boxes_precise(origin, 90.0, HitboxBuilder.STAND)
	_check_vec3d(
		"yaw 90 left shoulder expected position",
		yaw90[3]["center64"],
		PackedFloat64Array([-2.0, 20.0, 83.5]),
		1e-9
	)


func _test_jump_poses() -> void:
	var offset := PackedFloat64Array([10.0, 20.0, 33.5])
	var yaw_deg := 37.5
	var zero := PackedFloat64Array([0.0, 0.0, 0.0])
	var stand: Array = HitboxBuilder.build_boxes_precise(zero, yaw_deg, HitboxBuilder.STAND)
	var air: Array = HitboxBuilder.build_boxes_precise(offset, yaw_deg, HitboxBuilder.AIR)
	var crouch: Array = HitboxBuilder.build_boxes_precise(zero, yaw_deg, HitboxBuilder.CROUCH)
	var crouch_air: Array = HitboxBuilder.build_boxes_precise(offset, yaw_deg, HitboxBuilder.CROUCH_AIR)
	for i in range(11):
		_check_vec3d(
			"jump stand box %d rigid shift" % i,
			air[i]["center64"],
			_add_float64(stand[i]["center64"], offset),
			1e-9
		)
		_check_vec3d("jump stand box %d size unchanged" % i, air[i]["half64"], stand[i]["half64"], 1e-9)
		_check_vec3d(
			"crouch-jump box %d rigid shift" % i,
			crouch_air[i]["center64"],
			_add_float64(crouch[i]["center64"], offset),
			1e-9
		)
		_check_vec3d(
			"crouch-jump box %d size unchanged" % i,
			crouch_air[i]["half64"],
			crouch[i]["half64"],
			1e-9
		)


func _test_frame_and_input_quantization() -> void:
	var spec_position := PackedFloat64Array([
		FrameAdapter.to_spec_x(12.5),
		FrameAdapter.to_spec_y(-44.25),
		FrameAdapter.to_spec_z(64.0),
	])
	_check_vec3d("A2-f game-to-spec position", spec_position, PackedFloat64Array([12.5, 44.25, 64.0]), 1e-9)
	_check_float("A2-f spec-to-game y", FrameAdapter.to_game_z(spec_position[1]), -44.25, 1e-9)
	_check_float("A2-f spec-to-game height", FrameAdapter.to_game_y(spec_position[2]), 64.0, 1e-9)

	var game_yaw := deg_to_rad(37.5)
	var yaw_q := InputCommand.quantize_yaw(game_yaw)
	var spec_yaw := FrameAdapter.yaw_to_spec_deg(InputCommand.dequantize_yaw(yaw_q))
	_check_float("A2-e/F yaw uses input_cmd wire quantization", spec_yaw, 127.5, 0.0055)
	var game_pitch := deg_to_rad(15.0)
	var pitch_q := InputCommand.quantize_pitch(game_pitch)
	var spec_pitch := FrameAdapter.pitch_to_spec_deg(InputCommand.dequantize_pitch(pitch_q))
	_check_float("A2-e/F pitch is positive-up on wire, positive-down in spec", spec_pitch, -15.0, 0.0055)
	_check_bool(
		"A2-e pitch clamps to signed 16-bit range",
		InputCommand.quantize_pitch(deg_to_rad(120.0)),
		65535
	)


func _test_config_and_hash() -> void:
	_check_float("J5 radius multiplier", ConfigData.BOX_RADIUS_MULTIPLIER, 2.0, 1e-12)
	_check_bool("J5 diameter mode", ConfigData.BOX_WIDTH_DEPTH_MODE, "diameter")
	_check_float("J6 config matches JSON", ConfigData.CROUCH_SCALE, SkeletonData.CROUCH_SCALE, 1e-12)
	_check_float("J7 stand height matches JSON", ConfigData.STAND_HEIGHT, SkeletonData.STAND_HEIGHT, 1e-12)
	_check_float("J7 eye height matches JSON", ConfigData.EYE_STAND, SkeletonData.EYE_STAND, 1e-12)
	_check_float("J8 proposed length scale", ConfigData.NON_HEAD_LENGTH_SCALE, 0.57, 1e-12)
	_check_bool("J8 uses rounded v0.2 table", ConfigData.LENGTH_TABLE_MODE, "v0.2_rounded")
	_check_bool("J9 A-pose default", ConfigData.ARM_POSE, "a_pose")

	var digest: String = SkeletonData.SKELETON_SHA256
	_check_bool("SKELETON_SHA256 matches canonical JSON", digest, EXPECTED_SKELETON_SHA256)
	_check_bool("SKELETON_SHA256 is 64 lowercase hex", digest.length() == 64 and digest == digest.to_lower(), true)


func _check_float(name: String, got: float, want: float, tolerance: float) -> void:
	if absf(got - want) <= tolerance:
		passed += 1
		print("PASS  %s  got %.9f want %.9f" % [name, got, want])
	else:
		_fail("%s got %.12f want %.12f tolerance %.12f" % [name, got, want, tolerance])


func _check_vec3d(name: String, got: PackedFloat64Array, want: PackedFloat64Array, tolerance: float) -> void:
	if got.size() == 3 and want.size() == 3:
		var max_error := maxf(
			maxf(absf(got[0] - want[0]), absf(got[1] - want[1])),
			absf(got[2] - want[2])
		)
		if max_error <= tolerance:
			passed += 1
			print(
				"PASS  %s  got (%.9f, %.9f, %.9f) want (%.9f, %.9f, %.9f)"
				% [name, got[0], got[1], got[2], want[0], want[1], want[2]]
			)
			return
	_fail(
		"%s got (%.12f, %.12f, %.12f) want (%.12f, %.12f, %.12f)"
		% [name, got[0], got[1], got[2], want[0], want[1], want[2]]
	)


func _as_float64(vector: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([vector.x, vector.y, vector.z])


func _scale_float64(vector: PackedFloat64Array, scale: float) -> PackedFloat64Array:
	return PackedFloat64Array([vector[0] * scale, vector[1] * scale, vector[2] * scale])


func _add_float64(left: PackedFloat64Array, right: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([left[0] + right[0], left[1] + right[1], left[2] + right[2]])


func _check_vec3(name: String, got: Vector3, want: Vector3, tolerance: float) -> void:
	if got.distance_to(want) <= tolerance:
		passed += 1
		print(
			"PASS  %s  got (%.9f, %.9f, %.9f) want (%.9f, %.9f, %.9f)"
			% [name, got.x, got.y, got.z, want.x, want.y, want.z]
		)
	else:
		_fail(
			"%s got (%.12f, %.12f, %.12f) want (%.12f, %.12f, %.12f)"
			% [name, got.x, got.y, got.z, want.x, want.y, want.z]
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
