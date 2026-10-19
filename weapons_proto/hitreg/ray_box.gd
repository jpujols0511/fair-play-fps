class_name RayBox
extends RefCounted

const PARALLEL_EPS := 1e-12
const DISTANCE_TIE_EPS := 1e-6
const UNIT_DIRECTION_EPS := 1e-9
const HitboxConfigData = preload("res://hitreg/hitbox_config.gd")


static func intersect_box(
		origin: PackedFloat64Array,
		direction: PackedFloat64Array,
		length: float,
		box: Dictionary,
		padding: float = 2.0
	) -> Dictionary:
	if not _valid_ray(origin, direction, length) \
			or not _valid_box(box) \
			or not is_finite(padding) \
			or padding < 0.0:
		return _miss_result()
	var center: PackedFloat64Array = box["center64"]
	var source_half: PackedFloat64Array = box["half64"]
	if center.size() != 3 or source_half.size() != 3:
		return _miss_result()
	var half := PackedFloat64Array([
		source_half[0] + padding,
		source_half[1] + padding,
		source_half[2] + padding,
	])

	var yaw_rad := deg_to_rad(float(box.get("yaw_deg", 0.0)))
	var cos_yaw := cos(yaw_rad)
	var sin_yaw := sin(yaw_rad)
	var dx := origin[0] - center[0]
	var dy := origin[1] - center[1]
	var local_origin := PackedFloat64Array([
		dx * cos_yaw + dy * sin_yaw,
		-dx * sin_yaw + dy * cos_yaw,
		origin[2] - center[2],
	])
	var local_direction := PackedFloat64Array([
		direction[0] * cos_yaw + direction[1] * sin_yaw,
		-direction[0] * sin_yaw + direction[1] * cos_yaw,
		direction[2],
	])

	var starts_inside := true
	for axis in range(3):
		if absf(local_origin[axis]) > half[axis]:
			starts_inside = false
			break
	if starts_inside:
		return _hit_result(
			box,
			0.0,
			origin.duplicate(),
			PackedFloat64Array([0.0, 0.0, 0.0])
		)

	var t_enter := -INF
	var t_exit := INF
	var enter_axis := -1
	var enter_sign := 0.0
	for axis in range(3):
		var o := local_origin[axis]
		var d := local_direction[axis]
		var h := half[axis]
		if absf(d) < PARALLEL_EPS:
			if absf(o) > h:
				return _miss_result()
			continue
		var t1 := (-h - o) / d
		var t2 := (h - o) / d
		var near_t := minf(t1, t2)
		var far_t := maxf(t1, t2)
		if near_t > t_enter:
			t_enter = near_t
			enter_axis = axis
			enter_sign = -1.0 if d > 0.0 else 1.0
		t_exit = minf(t_exit, far_t)
		if t_enter > t_exit:
			return _miss_result()

	if t_exit < 0.0 or t_enter > length:
		return _miss_result()
	var hit_distance := maxf(t_enter, 0.0)
	if hit_distance > length:
		return _miss_result()
	var ray_point := _point_on_ray(origin, direction, hit_distance)
	var normal_local := PackedFloat64Array([0.0, 0.0, 0.0])
	if enter_axis >= 0:
		normal_local[enter_axis] = enter_sign
	var normal_world := PackedFloat64Array([
		normal_local[0] * cos_yaw - normal_local[1] * sin_yaw,
		normal_local[0] * sin_yaw + normal_local[1] * cos_yaw,
		normal_local[2],
	])
	return _hit_result(box, hit_distance, ray_point, normal_world)


static func trace_boxes(
		origin: PackedFloat64Array,
		direction: PackedFloat64Array,
		length: float,
		boxes: Array,
		padding_by_box: Dictionary = {},
		config_overrides: Dictionary = {}
	) -> Dictionary:
	var config: Dictionary = HitboxConfigData.with_overrides(config_overrides)
	if not _valid_ray(origin, direction, length) \
			or not _valid_boxes(boxes, padding_by_box, config):
		return _miss_result()
	var hits: Array = []
	for box in boxes:
		var padding := _padding_for_box(box, padding_by_box, config)
		var result := intersect_box(origin, direction, length, box, padding)
		if bool(result["hit"]):
			hits.append(result)
	if hits.is_empty():
		return _miss_result()
	if str(config["CROUCH_HEAD_OVERLAP_RULE"]) == HitboxConfigData.CROUCH_HEAD_OVERLAP_HEAD_PRIORITY:
		var overlap_head := _head_priority_overlap_hit(hits, boxes, padding_by_box, config)
		if not overlap_head.is_empty():
			return overlap_head

	var nearest := INF
	for hit in hits:
		nearest = minf(nearest, float(hit["dist"]))
	var best: Dictionary = {}
	var best_priority := 2147483647
	var best_id := 2147483647
	for hit in hits:
		if float(hit["dist"]) > nearest + DISTANCE_TIE_EPS:
			continue
		var priority := _box_priority(int(hit["box_id"]))
		var box_id := int(hit["box_id"])
		if priority < best_priority or (priority == best_priority and box_id < best_id):
			best = hit
			best_priority = priority
			best_id = box_id
	return best


static func trace_target(
		origin: PackedFloat64Array,
		direction: PackedFloat64Array,
		length: float,
		boxes: Array,
		padding_by_box: Dictionary = {},
		near_miss_limit: float = HitboxConfigData.NEAR_MISS_LOG_UNITS,
		config_overrides: Dictionary = {}
	) -> Dictionary:
	var config: Dictionary = HitboxConfigData.with_overrides(config_overrides)
	if not _valid_ray(origin, direction, length) \
			or not is_finite(near_miss_limit) \
			or near_miss_limit < 0.0 \
			or not _valid_boxes(boxes, padding_by_box, config):
		return _target_miss_result()
	var hit := trace_boxes(origin, direction, length, boxes, padding_by_box, config)
	if bool(hit["hit"]):
		return {
			"outcome": "hit",
			"box_id": hit["box_id"],
			"part": hit["part"],
			"dist": hit["dist"],
			"ray_point": hit["point"],
			"box_point": hit["point"].duplicate(),
		}
	if boxes.is_empty():
		return _target_miss_result()

	var closest: Array = []
	var minimum_distance := INF
	for box in boxes:
		var padding := _padding_for_box(box, padding_by_box, config)
		var result := _closest_segment_box(origin, direction, length, box, padding)
		minimum_distance = minf(minimum_distance, float(result["dist"]))
		closest.append(result)

	var best: Dictionary = {}
	var best_priority := 2147483647
	var best_id := 2147483647
	for result in closest:
		if float(result["dist"]) > minimum_distance + DISTANCE_TIE_EPS:
			continue
		var priority := _box_priority(int(result["box_id"]))
		var box_id := int(result["box_id"])
		if priority < best_priority or (priority == best_priority and box_id < best_id):
			best = result
			best_priority = priority
			best_id = box_id

	var distance := float(best["dist"])
	var outcome := "near_miss" if distance > 0.0 and distance <= near_miss_limit else "none"
	best["outcome"] = outcome
	return best


static func _closest_segment_box(
		origin: PackedFloat64Array,
		direction: PackedFloat64Array,
		length: float,
		box: Dictionary,
		padding: float
	) -> Dictionary:
	if not _valid_ray(origin, direction, length) \
			or not _valid_box(box) \
			or not is_finite(padding) \
			or padding < 0.0:
		return _target_miss_result()
	var center: PackedFloat64Array = box["center64"]
	var source_half: PackedFloat64Array = box["half64"]
	var half := PackedFloat64Array([
		source_half[0] + padding,
		source_half[1] + padding,
		source_half[2] + padding,
	])
	var yaw_rad := deg_to_rad(float(box.get("yaw_deg", 0.0)))
	var cos_yaw := cos(yaw_rad)
	var sin_yaw := sin(yaw_rad)
	var dx := origin[0] - center[0]
	var dy := origin[1] - center[1]
	var local_origin := PackedFloat64Array([
		dx * cos_yaw + dy * sin_yaw,
		-dx * sin_yaw + dy * cos_yaw,
		origin[2] - center[2],
	])
	var local_direction := PackedFloat64Array([
		direction[0] * cos_yaw + direction[1] * sin_yaw,
		-direction[0] * sin_yaw + direction[1] * cos_yaw,
		direction[2],
	])
	for axis in range(3):
		if absf(local_direction[axis]) < PARALLEL_EPS:
			local_direction[axis] = 0.0

	var breakpoints: Array[float] = [0.0, length]
	for axis in range(3):
		var d := local_direction[axis]
		if absf(d) < PARALLEL_EPS:
			continue
		for face in [-half[axis], half[axis]]:
			var crossing := (float(face) - local_origin[axis]) / d
			if crossing > 0.0 and crossing < length:
				breakpoints.append(crossing)
	breakpoints.sort()

	var best_t := 0.0
	var best_distance_squared := INF
	if length == 0.0:
		best_distance_squared = float(
			_distance_at_local(0.0, local_origin, local_direction, half)["distance_squared"]
		)
	else:
		for interval in range(breakpoints.size() - 1):
			var start_t := breakpoints[interval]
			var end_t := breakpoints[interval + 1]
			if end_t <= start_t:
				continue
			var midpoint := (start_t + end_t) * 0.5
			var terms: Array = []
			var numerator := 0.0
			var denominator := 0.0
			for axis in range(3):
				var position := local_origin[axis] + local_direction[axis] * midpoint
				var boundary := 0.0
				if position < -half[axis]:
					boundary = -half[axis]
				elif position > half[axis]:
					boundary = half[axis]
				else:
					continue
				var d := local_direction[axis]
				var offset := local_origin[axis] - boundary
				terms.append([offset, d])
				numerator += d * offset
				denominator += d * d

			var candidate_t := start_t
			if denominator > 0.0:
				candidate_t = clampf(-numerator / denominator, start_t, end_t)
			var candidate_distance_squared := 0.0
			for term in terms:
				var delta: float = float(term[0]) + float(term[1]) * candidate_t
				candidate_distance_squared += delta * delta

			var improves := candidate_distance_squared < best_distance_squared - 1e-24
			var equal_but_earlier := (
				absf(candidate_distance_squared - best_distance_squared) <= 1e-24
				and candidate_t < best_t
			)
			if improves or equal_but_earlier:
				best_t = candidate_t
				best_distance_squared = candidate_distance_squared

	var closest_local: Dictionary = _distance_at_local(
		best_t,
		local_origin,
		local_direction,
		half
	)
	var box_local: PackedFloat64Array = closest_local["box_point"]
	var ray_point := _point_on_ray(origin, direction, best_t)
	var box_point := PackedFloat64Array([
		center[0] + cos_yaw * box_local[0] - sin_yaw * box_local[1],
		center[1] + sin_yaw * box_local[0] + cos_yaw * box_local[1],
		center[2] + box_local[2],
	])
	return {
		"outcome": "none",
		"box_id": int(box["id"]),
		"part": str(box["part"]),
		"dist": sqrt(best_distance_squared),
		"ray_point": ray_point,
		"box_point": box_point,
	}


static func _padding_for_box(
		box: Dictionary,
		padding_by_box: Dictionary,
		config: Dictionary
	) -> float:
	var box_id := int(box["id"])
	var per_bone: Dictionary = config["HITBOX_PADDING_PER_BONE"]
	return float(padding_by_box.get(
		box_id,
		per_bone.get(box_id, float(config["HITBOX_PADDING"]))
	))


static func _valid_ray(
		origin: PackedFloat64Array,
		direction: PackedFloat64Array,
		length: float
	) -> bool:
	if origin.size() != 3 or direction.size() != 3 or not is_finite(length) or length < 0.0:
		return false
	var direction_length_squared := 0.0
	for axis in range(3):
		var origin_value := float(origin[axis])
		var direction_value := float(direction[axis])
		if not is_finite(origin_value) or not is_finite(direction_value):
			return false
		direction_length_squared += direction_value * direction_value
	return is_finite(direction_length_squared) \
		and absf(direction_length_squared - 1.0) <= UNIT_DIRECTION_EPS


static func _valid_box(box: Dictionary) -> bool:
	if not box.has("id") or not box.has("part") \
			or not box.has("center64") or not box.has("half64"):
		return false
	var center: Variant = box["center64"]
	var half: Variant = box["half64"]
	if typeof(center) != TYPE_PACKED_FLOAT64_ARRAY \
			or typeof(half) != TYPE_PACKED_FLOAT64_ARRAY \
			or center.size() != 3 or half.size() != 3:
		return false
	if not is_finite(float(box.get("yaw_deg", NAN))):
		return false
	for axis in range(3):
		if not is_finite(float(center[axis])) \
				or not is_finite(float(half[axis])) \
				or float(half[axis]) < 0.0:
			return false
	return true


static func _valid_boxes(
		boxes: Array,
		padding_by_box: Dictionary,
		config: Dictionary
	) -> bool:
	for box in boxes:
		if typeof(box) != TYPE_DICTIONARY or not _valid_box(box):
			return false
		var padding := _padding_for_box(box, padding_by_box, config)
		if not is_finite(padding) or padding < 0.0:
			return false
	return true


static func _head_priority_overlap_hit(
		hits: Array,
		boxes: Array,
		padding_by_box: Dictionary,
		config: Dictionary
	) -> Dictionary:
	var head_hit: Dictionary = {}
	var head_box: Dictionary = {}
	var chest_box: Dictionary = {}
	for hit in hits:
		if int(hit["box_id"]) == 0:
			head_hit = hit
	for box in boxes:
		if int(box["id"]) == 0:
			head_box = box
		elif int(box["id"]) == 1:
			chest_box = box
	if head_hit.is_empty() or head_box.is_empty() or chest_box.is_empty():
		return {}

	var head_padding := _padding_for_box(head_box, padding_by_box, config)
	var chest_padding := _padding_for_box(chest_box, padding_by_box, config)
	var overlap_bottom := maxf(
		float(head_box["center64"][2]) - float(head_box["half64"][2]) - head_padding,
		float(chest_box["center64"][2]) - float(chest_box["half64"][2]) - chest_padding
	)
	var overlap_top := minf(
		float(head_box["center64"][2]) + float(head_box["half64"][2]) + head_padding,
		float(chest_box["center64"][2]) + float(chest_box["half64"][2]) + chest_padding
	)
	var hit_z := float(head_hit["point"][2])
	if overlap_top >= overlap_bottom and hit_z >= overlap_bottom and hit_z <= overlap_top:
		return head_hit
	return {}


static func _distance_at_local(
		t: float,
		origin: PackedFloat64Array,
		direction: PackedFloat64Array,
		half: PackedFloat64Array
	) -> Dictionary:
	var ray_point := PackedFloat64Array([0.0, 0.0, 0.0])
	var box_point := PackedFloat64Array([0.0, 0.0, 0.0])
	var distance_squared := 0.0
	for axis in range(3):
		var point := origin[axis] + direction[axis] * t
		var closest := clampf(point, -half[axis], half[axis])
		var difference := point - closest
		ray_point[axis] = point
		box_point[axis] = closest
		distance_squared += difference * difference
	return {
		"distance_squared": distance_squared,
		"ray_point": ray_point,
		"box_point": box_point,
	}


static func _target_miss_result() -> Dictionary:
	return {
		"outcome": "none",
		"box_id": -1,
		"part": "",
		"dist": INF,
		"ray_point": PackedFloat64Array([0.0, 0.0, 0.0]),
		"box_point": PackedFloat64Array([0.0, 0.0, 0.0]),
	}


static func _point_on_ray(origin: PackedFloat64Array, direction: PackedFloat64Array, t: float) -> PackedFloat64Array:
	return PackedFloat64Array([
		origin[0] + t * direction[0],
		origin[1] + t * direction[1],
		origin[2] + t * direction[2],
	])


static func _hit_result(
		box: Dictionary,
		distance: float,
		point: PackedFloat64Array,
		normal: PackedFloat64Array
	) -> Dictionary:
	return {
		"hit": true,
		"box_id": int(box["id"]),
		"part": str(box["part"]),
		"dist": distance,
		"point": point,
		"ray_point": point.duplicate(),
		"box_point": point.duplicate(),
		"normal": normal,
	}


static func _miss_result() -> Dictionary:
	return {
		"hit": false,
		"box_id": -1,
		"part": "",
		"dist": INF,
		"point": PackedFloat64Array([0.0, 0.0, 0.0]),
		"ray_point": PackedFloat64Array([0.0, 0.0, 0.0]),
		"box_point": PackedFloat64Array([0.0, 0.0, 0.0]),
		"normal": PackedFloat64Array([0.0, 0.0, 0.0]),
	}


static func _box_priority(box_id: int) -> int:
	if box_id == 0:
		return 0
	if box_id == 1:
		return 1
	if box_id == 2:
		return 2
	if box_id == 3 or box_id == 4:
		return 3
	if box_id == 5 or box_id == 6:
		return 4
	if box_id == 7 or box_id == 8:
		return 5
	if box_id == 9 or box_id == 10:
		return 6
	return 7
