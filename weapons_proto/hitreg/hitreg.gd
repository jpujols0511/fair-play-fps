class_name HitReg
extends RefCounted

# Server-only: clients never call this module or claim a hit/position.
const RecoilLogic = preload("res://weapons/recoil.gd")
const WeaponConfigData = preload("res://weapons/weapon_config.gd")
const HitboxBuilder = preload("res://hitreg/hitboxes.gd")
const RayBoxLogic = preload("res://hitreg/ray_box.gd")
const RewindPolicy = preload("res://hitreg/rewind_policy.gd")
const DamageRegionData = preload("res://hitreg/damage_regions.gd")
const HitboxConfigData = preload("res://hitreg/hitbox_config.gd")
const FrameAdapter = preload("res://shared/frame.gd")
const InputCommand = preload("res://shared/input_cmd.gd")

const WORLD_PARALLEL_EPS := 1e-12
const PLAYER_HIT_TIE_EPS := 1e-6
const SHOT_FLAG_REWIND_CLAMPED := 1 << 0
const SHOT_FLAG_CLAIMED_TIME_OUT_OF_WINDOW := 1 << 1
const SHOT_FLAG_THROUGH_WORLD := 1 << 2
const SHOT_FLAG_TARGET_NOT_SENT := 1 << 3


static func process_shot(context: Dictionary) -> Dictionary:
	var shooter: Dictionary = context.get("shooter", {})
	if shooter.is_empty():
		return {"error": "missing shooter context"}
	if not context.has("history") or not context.has("rng"):
		return {"error": "history and injected rng are required"}

	var tick_rate := int(context.get("tick_rate", 128))
	if tick_rate <= 0:
		return {"error": "tick_rate must be positive"}
	var now := float(context.get("now", 0.0))
	var shooter_slot := int(shooter.get("slot", -1))
	var eye := _as_float64(shooter.get("eye64", shooter.get("eye", null)))
	if eye.size() != 3 or shooter_slot < 0:
		return {"error": "shooter requires a slot and 3D eye position"}

	var weapon_id := str(shooter.get("weapon_id", ""))
	var weapon_state: Dictionary = shooter.get("weapon_state", {})
	if weapon_state.is_empty():
		weapon_state = RecoilLogic.initial_state(weapon_id)
	var move_state: Dictionary = shooter.get("move_state", {
		"in_air": false,
		"horizontal_speed": 0.0,
		"crouched": false,
	})
	var view_pitch := float(shooter.get("view_pitch", 0.0))
	var view_yaw := float(shooter.get("view_yaw", 0.0))
	var view_pitch_q := _input_pitch_q(shooter, view_pitch)
	var view_yaw_q := _input_yaw_q(shooter, view_yaw)
	var quantized_spec_pitch := FrameAdapter.pitch_to_spec_deg(
		InputCommand.dequantize_pitch(view_pitch_q)
	)
	var quantized_spec_yaw := FrameAdapter.yaw_to_spec_deg(
		InputCommand.dequantize_yaw(view_yaw_q)
	)
	var shot_index := int(shooter.get("shot_index", 0))
	var cmd_seq := int(shooter.get("cmd_seq", 0))
	var claimed_view_tick := float(shooter.get("claimed_view_tick", now))
	var rtt_ms := float(context.get("rtt_ms", 0.0))
	var interp_ticks := int(context.get("interp_ticks", RewindPolicy.INTERP_TICKS))
	var config: Dictionary = WeaponConfigData.with_overrides(context.get("config", {}))
	var hitbox_config: Dictionary = HitboxConfigData.with_overrides(context.get("hitbox_config", {}))
	var history: Variant = context["history"]
	var rewind: Dictionary = RewindPolicy.choose(
		now,
		rtt_ms,
		interp_ticks,
		claimed_view_tick,
		tick_rate
	)
	var target_query: Dictionary = history.rewind_targets(
		shooter_slot,
		float(rewind["chosen_view_tick"])
	)
	rewind = RewindPolicy.with_missing_history(
		rewind,
		int(target_query["missing_history_count"])
	)
	rewind["shooter_slot"] = shooter_slot
	rewind["shot_index"] = shot_index
	rewind["cmd_seq"] = cmd_seq
	rewind["targets_rewound"] = int(target_query["targets_rewound"])
	rewind["rewound_mask"] = int(target_query["rewound_mask"])

	var spread_at_fire := RecoilLogic.spread_for_next_shot(weapon_state, move_state)
	var shot_update: Dictionary = RecoilLogic.fire_shot(
		weapon_state,
		move_state,
		context["rng"],
		now / float(tick_rate)
	)
	var shot_math: Dictionary = shot_update["shot"]
	var updated_weapon_state: Dictionary = shot_update["state"]
	var px := float(weapon_state.get("px", 0.0))
	var py := float(weapon_state.get("py", 0.0))
	var direction := shot_direction(
		quantized_spec_pitch + px,
		quantized_spec_yaw + py,
		float(shot_math["spread_x"]),
		float(shot_math["spread_y"])
	)

	var world_boxes: Array = context.get("world_boxes", [])
	var weapon_range := float(config["WEAPON_RANGE_UNITS"])
	var first_world_hit := _first_world_hit(eye, direction, weapon_range, world_boxes)
	var has_world_hit := first_world_hit <= weapon_range
	var segment_length := weapon_range
	if bool(config["WORLD_BLOCKS_SHOTS"]) and has_world_hit:
		segment_length = minf(segment_length, first_world_hit)

	var teams: Variant = context.get("teams", {})
	var sent_mask := _sent_mask(context, shooter_slot, now)
	var candidates: Array = []
	for target in target_query["targets"]:
		var sample: Dictionary = target["sample"]
		var boxes: Array = HitboxBuilder.build_boxes_precise(
			sample["origin64"],
			float(sample["yaw_deg"]),
			int(sample["stance"]),
			float(sample.get("duck_fraction", -1.0)),
			hitbox_config
		)
		var trace: Dictionary = RayBoxLogic.trace_target(
			eye,
			direction,
			segment_length,
			boxes,
			{},
			float(hitbox_config["NEAR_MISS_LOG_UNITS"]),
			hitbox_config
		)
		candidates.append({
			"slot": int(target["slot"]),
			"sample": sample,
			"boxes": boxes,
			"trace": trace,
		})

	var first_player_hit := INF
	var first_player_slot := 2147483647
	for candidate in candidates:
		var trace: Dictionary = candidate["trace"]
		if trace["outcome"] != "hit":
			continue
		var distance := float(trace["dist"])
		var slot := int(candidate["slot"])
		if distance < first_player_hit - PLAYER_HIT_TIE_EPS \
				or (absf(distance - first_player_hit) <= PLAYER_HIT_TIE_EPS and slot < first_player_slot):
			first_player_hit = distance
			first_player_slot = slot

	if not bool(config["PLAYER_PENETRATION"]) and is_finite(first_player_hit):
		segment_length = minf(segment_length, first_player_hit)

	var sent_records: Array = []
	for candidate in candidates:
		var slot := int(candidate["slot"])
		var sample: Dictionary = candidate["sample"]
		var trace: Dictionary = RayBoxLogic.trace_target(
			eye,
			direction,
			segment_length,
			candidate["boxes"],
			{},
			float(hitbox_config["NEAR_MISS_LOG_UNITS"]),
			hitbox_config
		)
		if trace["outcome"] == "none":
			continue
		if not bool(config["PLAYER_PENETRATION"]) and trace["outcome"] == "hit" \
				and slot != first_player_slot:
			continue

		var through_world := false
		if not bool(config["WORLD_BLOCKS_SHOTS"]) and has_world_hit:
			var target_along_ray := _distance_along_ray(eye, trace["ray_point"], direction)
			through_world = target_along_ray > first_world_hit + PLAYER_HIT_TIE_EPS
		var target_team := _team_for(teams, slot)
		var shooter_team := _team_for(teams, shooter_slot)
		var same_team := shooter_team != 0 and shooter_team == target_team
		var shot_flags := _shot_flags(rewind, through_world, (sent_mask & (1 << slot)) == 0)
		var outcome := 0 if trace["outcome"] == "hit" else 1
		var box_id := int(trace["box_id"])
		sent_records.append({
			"shooter_slot": shooter_slot,
			"target_slot": slot,
			"weapon_id": weapon_id,
			"part": box_id,
			"outcome": outcome,
			"target_stance": int(sample["stance"]),
			"trace_distance": float(trace["dist"]),
			"shot_index": shot_index,
			"eye_pos": eye,
			"view_pitch_q": view_pitch_q,
			"view_yaw_q": view_yaw_q,
			"spread_x": float(shot_math["spread_x"]),
			"spread_y": float(shot_math["spread_y"]),
			"kick_up": float(shot_math["kick_up"]),
			"kick_side": float(shot_math["kick_side"]),
			"rewind_ticks": int(rewind["rewind_ticks"]),
			"rewind_frac": int(rewind["rewind_frac"]),
			"server_time_s": float(rewind["chosen_view_tick"]) / float(tick_rate),
			"client_claimed_time_s": claimed_view_tick / float(tick_rate),
			"closest_dist": 0.0 if outcome == 0 else float(trace["dist"]),
			"ray_point": trace["ray_point"],
			"box_point": trace["box_point"],
			"target_origin": sample["origin64"],
			"target_yaw": float(sample["yaw_deg"]),
			"region_id": DamageRegionData.region_for_box(box_id),
			"damage": null,
			"same_team": same_team,
			"through_world": through_world,
			"flags": shot_flags,
		})
	_sort_target_records(sent_records)

	var input_reject: Variant = null
	if bool(rewind["input_reject"]):
		input_reject = {
			"player_slot": shooter_slot,
			"reason": 1,
			"cmd_seq": cmd_seq,
			"claimed_time_s": claimed_view_tick / float(tick_rate),
			"expected_time_s": float(rewind["expected_view_tick"]) / float(tick_rate),
		}

	return {
		"records": sent_records,
		"rewind_decision": rewind,
		"input_reject": input_reject,
		"spread_at_fire": spread_at_fire,
		"move_state": _snapshot_move_state(move_state),
		"shot_direction": direction,
		"weapon_state": updated_weapon_state,
		"world_hit": has_world_hit,
		"world_hit_distance": first_world_hit,
		"segment_length": segment_length,
		"shot_index": shot_index,
	}


static func shot_direction(pitch_deg: float, yaw_deg: float, spread_x: float, spread_y: float) -> PackedFloat64Array:
	var pitch := deg_to_rad(pitch_deg)
	var yaw := deg_to_rad(yaw_deg)
	var cos_pitch := cos(pitch)
	var sin_pitch := sin(pitch)
	var cos_yaw := cos(yaw)
	var sin_yaw := sin(yaw)
	var direction := PackedFloat64Array([
		cos_pitch * cos_yaw - spread_x * sin_yaw + spread_y * sin_pitch * cos_yaw,
		cos_pitch * sin_yaw + spread_x * cos_yaw + spread_y * sin_pitch * sin_yaw,
		-sin_pitch + spread_y * cos_pitch,
	])
	var magnitude := sqrt(
		direction[0] * direction[0]
		+ direction[1] * direction[1]
		+ direction[2] * direction[2]
	)
	return PackedFloat64Array([
		direction[0] / magnitude,
		direction[1] / magnitude,
		direction[2] / magnitude,
	])


static func _input_pitch_q(shooter: Dictionary, spec_pitch_deg: float) -> int:
	var supplied := int(shooter.get("view_pitch_q", -1))
	if supplied >= 0 and supplied <= 65535:
		return supplied
	return InputCommand.quantize_pitch(FrameAdapter.pitch_to_game_rad(spec_pitch_deg))


static func _input_yaw_q(shooter: Dictionary, spec_yaw_deg: float) -> int:
	var supplied := int(shooter.get("view_yaw_q", -1))
	if supplied >= 0 and supplied <= 65535:
		return supplied
	return InputCommand.quantize_yaw(FrameAdapter.yaw_to_game_rad(spec_yaw_deg))


static func _first_world_hit(
		origin: PackedFloat64Array,
		direction: PackedFloat64Array,
		length: float,
		world_boxes: Array
	) -> float:
	var nearest := INF
	for box in world_boxes:
		var distance := _world_aabb_entry(origin, direction, length, box)
		nearest = minf(nearest, distance)
	return nearest


static func _world_aabb_entry(
		origin: PackedFloat64Array,
		direction: PackedFloat64Array,
		length: float,
		box: Dictionary
	) -> float:
	var minimum: PackedFloat64Array = box["min64"]
	var maximum: PackedFloat64Array = box["max64"]
	var inside := true
	for axis in range(3):
		if origin[axis] < minimum[axis] or origin[axis] > maximum[axis]:
			inside = false
			break
	if inside:
		return 0.0

	var enter := -INF
	var exit := INF
	for axis in range(3):
		var o := origin[axis]
		var d := direction[axis]
		if absf(d) < WORLD_PARALLEL_EPS:
			if o < minimum[axis] or o > maximum[axis]:
				return INF
			continue
		var t1 := (minimum[axis] - o) / d
		var t2 := (maximum[axis] - o) / d
		enter = maxf(enter, minf(t1, t2))
		exit = minf(exit, maxf(t1, t2))
		if enter > exit:
			return INF
	if exit < 0.0 or enter > length:
		return INF
	var distance := maxf(enter, 0.0)
	return distance if distance <= length else INF


static func _sent_mask(context: Dictionary, shooter_slot: int, now: float) -> int:
	if context.has("sent_mask_for") and typeof(context["sent_mask_for"]) == TYPE_CALLABLE:
		return int(context["sent_mask_for"].call(shooter_slot, now))
	return int(context.get("sent_mask", 0xFFFF))


static func _team_for(teams: Variant, slot: int) -> int:
	if typeof(teams) == TYPE_DICTIONARY:
		return int(teams.get(slot, 0))
	if typeof(teams) == TYPE_ARRAY and slot >= 0 and slot < teams.size():
		return int(teams[slot])
	return 0


static func _shot_flags(rewind: Dictionary, through_world: bool, target_not_sent: bool) -> int:
	var flags := 0
	if int(rewind["flags"]) & RewindPolicy.FLAG_REWIND_CLAMPED:
		flags |= SHOT_FLAG_REWIND_CLAMPED
	if int(rewind["flags"]) & RewindPolicy.FLAG_CLAIMED_TIME_OUT_OF_WINDOW:
		flags |= SHOT_FLAG_CLAIMED_TIME_OUT_OF_WINDOW
	if through_world:
		flags |= SHOT_FLAG_THROUGH_WORLD
	if target_not_sent:
		flags |= SHOT_FLAG_TARGET_NOT_SENT
	return flags


static func _distance_along_ray(origin: PackedFloat64Array, point: PackedFloat64Array, direction: PackedFloat64Array) -> float:
	return (
		(point[0] - origin[0]) * direction[0]
		+ (point[1] - origin[1]) * direction[1]
		+ (point[2] - origin[2]) * direction[2]
	)


static func _as_float64(value: Variant) -> PackedFloat64Array:
	if typeof(value) == TYPE_PACKED_FLOAT64_ARRAY:
		return value
	if typeof(value) == TYPE_VECTOR3:
		return PackedFloat64Array([value.x, value.y, value.z])
	if typeof(value) == TYPE_ARRAY and value.size() == 3:
		return PackedFloat64Array([float(value[0]), float(value[1]), float(value[2])])
	return PackedFloat64Array()


static func _snapshot_move_state(move_state: Dictionary) -> int:
	if bool(move_state.get("in_air", false)):
		return 2
	if bool(move_state.get("crouched", false)):
		return 1
	if float(move_state.get("horizontal_speed", 0.0)) > RecoilLogic.RUN_SPEED_THRESHOLD:
		return 3
	return 0


static func _sort_target_records(records: Array) -> void:
	for i in range(records.size()):
		for j in range(i + 1, records.size()):
			var left: Dictionary = records[i]
			var right: Dictionary = records[j]
			var left_distance := float(left["closest_dist"])
			var right_distance := float(right["closest_dist"])
			var swap := right_distance < left_distance - PLAYER_HIT_TIE_EPS
			if absf(right_distance - left_distance) <= PLAYER_HIT_TIE_EPS:
				swap = int(right["target_slot"]) < int(left["target_slot"])
			if swap:
				records[i] = right
				records[j] = left
