class_name Hitboxes
extends RefCounted

const SkeletonData = preload("res://shared/skeleton_constants.gd")
const ConfigData = preload("res://hitreg/hitbox_config.gd")

const STAND := 0
const CROUCH := 1
const AIR := 2
const CROUCH_AIR := 3


static func build_boxes(
		origin: Vector3,
		yaw_deg: float,
		stance: int,
		duck_fraction: float = -1.0,
		config_overrides: Dictionary = {}
	) -> Array:
	return build_boxes_precise(
		PackedFloat64Array([origin.x, origin.y, origin.z]),
		yaw_deg,
		stance,
		duck_fraction,
		config_overrides
	)


static func build_boxes_precise(
		origin: PackedFloat64Array,
		yaw_deg: float,
		stance: int,
		duck_fraction: float = -1.0,
		config_overrides: Dictionary = {}
	) -> Array:
	if origin.size() != 3:
		return []
	if stance < STAND or stance > CROUCH_AIR:
		return []
	var config: Dictionary = ConfigData.with_overrides(config_overrides)
	var blend := clampf(duck_fraction, 0.0, 1.0) if duck_fraction >= 0.0 \
			else (1.0 if stance == CROUCH or stance == CROUCH_AIR else 0.0)
	var yaw_rad := deg_to_rad(yaw_deg)
	var cos_yaw := cos(yaw_rad)
	var sin_yaw := sin(yaw_rad)
	var forward := Vector3(cos_yaw, sin_yaw, 0.0)
	var left := Vector3(-sin_yaw, cos_yaw, 0.0)
	var up := Vector3(0.0, 0.0, 1.0)
	var axes64 := [
		PackedFloat64Array([cos_yaw, sin_yaw, 0.0]),
		PackedFloat64Array([-sin_yaw, cos_yaw, 0.0]),
		PackedFloat64Array([0.0, 0.0, 1.0]),
	]
	var boxes: Array = []

	for source in SkeletonData.BOXES:
		var center_x := float(source["center_stand"][0])
		var center_y := float(source["center_stand"][1])
		var center_z := float(source["center_stand"][2])
		var half_x := float(source["size"][0]) * 0.5
		var half_y := float(source["size"][1]) * 0.5
		var stand_bottom := center_z - float(source["size"][2]) * 0.5
		var stand_top := center_z + float(source["size"][2]) * 0.5
		var crouched_geometry := _crouch_geometry(
			stand_bottom,
			stand_top,
			float(source["size"][2]),
			bool(source["fixed_size_in_crouch"]),
			float(config["CROUCH_SCALE"]),
			float(config["STAND_HEIGHT"])
		)
		var bottom := lerpf(stand_bottom, float(crouched_geometry[0]), blend)
		var top := lerpf(stand_top, float(crouched_geometry[1]), blend)
		center_z = (bottom + top) * 0.5
		var half_z := (top - bottom) * 0.5

		# Vector3 is float32 in this Godot build; server geometry keeps float64 arrays.
		var world_center64 := PackedFloat64Array([
			origin[0] + cos_yaw * center_x - sin_yaw * center_y,
			origin[1] + sin_yaw * center_x + cos_yaw * center_y,
			origin[2] + center_z,
		])
		var half64 := PackedFloat64Array([half_x, half_y, half_z])
		boxes.append({
			"id": int(source["id"]),
			"part": str(source["part"]),
			"center": Vector3(world_center64[0], world_center64[1], world_center64[2]),
			"center64": world_center64,
			"half": Vector3(half_x, half_y, half_z),
			"half64": half64,
			"yaw_deg": yaw_deg,
			"axes": [forward, left, up],
			"axes64": axes64,
		})
	return boxes


static func eye_height(
		stance: int,
		duck_fraction: float = -1.0,
		config_overrides: Dictionary = {}
	) -> float:
	if stance < STAND or stance > CROUCH_AIR:
		return NAN
	var config: Dictionary = ConfigData.with_overrides(config_overrides)
	var blend := clampf(duck_fraction, 0.0, 1.0) if duck_fraction >= 0.0 \
			else (1.0 if stance == CROUCH or stance == CROUCH_AIR else 0.0)
	var crouched_eye := float(config["EYE_STAND"]) * float(config["CROUCH_SCALE"])
	return lerpf(float(config["EYE_STAND"]), crouched_eye, blend)


static func _crouch_geometry(
		stand_bottom: float,
		stand_top: float,
		size_z: float,
		fixed_size: bool,
		crouch_scale: float,
		stand_height: float
	) -> Array:
	var bottom := stand_bottom
	var top := stand_top
	if fixed_size:
		top = crouch_scale * stand_height
		bottom = top - size_z
	else:
		bottom = stand_bottom * crouch_scale
		top = stand_top * crouch_scale
	return [bottom, top]
