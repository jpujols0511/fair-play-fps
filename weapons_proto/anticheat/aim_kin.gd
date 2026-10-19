class_name AimKin
extends RefCounted

const ParamsData = preload("res://anticheat/anticheat_params.gd")
const FrameAdapter = preload("res://shared/frame.gd")
const InputCommand = preload("res://shared/input_cmd.gd")
const TICK_RATE := 128.0
const SETTLE_NEVER := 255


static func compute(
		commands: Array,
		fire_tick: int,
		spread_at_fire: float,
		move_state: int,
		shot_index: int,
		params_overrides: Dictionary = {}
	) -> Dictionary:
	var params: Dictionary = ParamsData.with_overrides(params_overrides)
	var ordered := commands.duplicate(true)
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var seq_a := int(a.get("cmd_seq", 0))
		var seq_b := int(b.get("cmd_seq", 0))
		if seq_a == seq_b:
			return int(a.get("tick", 0)) < int(b.get("tick", 0))
		return seq_a < seq_b
	)
	var by_tick := {}
	var excluded_reason := ""
	for command in ordered:
		var tick := int(command["tick"])
		by_tick[tick] = command
		if tick <= fire_tick and tick >= fire_tick - int(params["EXCLUDE_AFTER_RESET_TICKS"]):
			if bool(command.get("teleported", false)):
				excluded_reason = "teleport"
			elif bool(command.get("respawned", false)):
				excluded_reason = "respawn"
			elif bool(command.get("round_start", false)):
				excluded_reason = "round_start"
		if tick == fire_tick and not bool(command.get("alive", true)):
			excluded_reason = "dead"
		if tick == fire_tick and bool(command.get("spectating", false)):
			excluded_reason = "spectating"

	var directions := {}
	var first_tick := fire_tick - int(params["WINDOW_BEFORE_TICKS"]) - 1
	var last_tick := fire_tick + int(params["WINDOW_AFTER_TICKS"])
	for tick in range(first_tick, last_tick + 1):
		if not by_tick.has(tick):
			continue
		var command: Dictionary = by_tick[tick]
		if bool(command.get("repeated", false)):
			continue
		var pitch_q := 0
		var yaw_q := 0
		if command.has("view_pitch_q") and command.has("view_yaw_q"):
			pitch_q = clampi(int(command["view_pitch_q"]), 0, 65535)
			yaw_q = clampi(int(command["view_yaw_q"]), 0, 65535)
		else:
			pitch_q = InputCommand.quantize_pitch(
				FrameAdapter.pitch_to_game_rad(float(command.get("view_pitch", 0.0)))
			)
			yaw_q = InputCommand.quantize_yaw(
				FrameAdapter.yaw_to_game_rad(float(command.get("view_yaw", 0.0)))
			)
		var pitch := FrameAdapter.pitch_to_spec_deg(InputCommand.dequantize_pitch(pitch_q))
		var yaw := FrameAdapter.yaw_to_spec_deg(InputCommand.dequantize_yaw(yaw_q))
		directions[tick] = _view_direction(pitch, yaw)

	var deltas := {}
	var angular_velocity := {}
	var angular_acceleration := {}
	for tick in range(fire_tick - int(params["WINDOW_BEFORE_TICKS"]), last_tick + 1):
		if not directions.has(tick) or not directions.has(tick - 1):
			continue
		var delta := _angle_between(directions[tick - 1], directions[tick])
		deltas[tick] = delta
		angular_velocity[tick] = delta * TICK_RATE
		if angular_velocity.has(tick - 1):
			angular_acceleration[tick] = (
				float(angular_velocity[tick]) - float(angular_velocity[tick - 1])
			) * TICK_RATE

	var peak_velocity := 0.0
	var peak_acceleration := 0.0
	var peak_tick := fire_tick
	for tick in angular_velocity:
		var velocity := float(angular_velocity[tick])
		if velocity > peak_velocity:
			peak_velocity = velocity
			peak_tick = int(tick)
	for value in angular_acceleration.values():
		peak_acceleration = maxf(peak_acceleration, absf(float(value)))

	var pre_fire_total := 0.0
	var pre_fire_count := 0
	for tick in range(fire_tick - 4, fire_tick):
		if angular_velocity.has(tick):
			pre_fire_total += float(angular_velocity[tick])
			pre_fire_count += 1
	var pre_fire_speed := pre_fire_total / float(pre_fire_count) if pre_fire_count > 0 else 0.0
	var fire_delta := float(deltas.get(fire_tick, 0.0))
	var snapback := 0.0
	var snapback_cos := 0.0
	if directions.has(fire_tick - 1) and directions.has(fire_tick):
		var pre_direction: PackedFloat64Array = directions[fire_tick - 1]
		var fire_direction: PackedFloat64Array = directions[fire_tick]
		var fire_move := _subtract(fire_direction, pre_direction)
		for tick in range(fire_tick + 1, fire_tick + int(params["WINDOW_AFTER_TICKS"]) + 1):
			if not directions.has(tick) or not directions.has(tick - 1):
				continue
			var before_distance := _angle_between(pre_direction, directions[tick - 1])
			var after_distance := _angle_between(pre_direction, directions[tick])
			var improvement := before_distance - after_distance
			if improvement <= snapback:
				continue
			var back_move := _subtract(directions[tick], directions[tick - 1])
			snapback = improvement
			snapback_cos = _cosine(fire_move, back_move)

	var settle_ticks := SETTLE_NEVER
	if peak_velocity > 0.0:
		for tick in range(peak_tick + 1, last_tick + 1):
			if angular_velocity.has(tick) \
					and float(angular_velocity[tick]) < peak_velocity * float(params["SETTLE_FRACTION"]):
				settle_ticks = tick - peak_tick
				break

	var flags := 0
	var excluded := not excluded_reason.is_empty()
	if not excluded:
		if (
				fire_delta >= float(params["SNAP_MIN_FIRE_DELTA_DEG"])
				and snapback >= fire_delta * float(params["SNAPBACK_MIN_FRACTION"])
				and snapback_cos <= float(params["SNAPBACK_MAX_COS"])
				and pre_fire_speed < fire_delta * TICK_RATE * float(params["PRE_FIRE_SPEED_MAX_FRACTION"])
			):
			flags |= 1 << 0
		if (
				peak_acceleration >= float(params["FLICK_MIN_PEAK_ACCEL_DPS2"])
				and settle_ticks <= int(params["FLICK_MAX_SETTLE_TICKS"])
				and peak_tick == fire_tick
			):
			flags |= 1 << 1
	return {
		"shooter_slot": int(by_tick.get(fire_tick, {}).get("player_slot", 0)),
		"window_ticks": int(params["WINDOW_BEFORE_TICKS"]),
		"shot_index": shot_index,
		"move_state": move_state,
		"spread_at_fire": spread_at_fire,
		"peak_ang_vel_dps": peak_velocity,
		"peak_ang_accel_dps2": peak_acceleration,
		"fire_tick_delta_deg": fire_delta,
		"snapback_deg": snapback,
		"snapback_cos": snapback_cos,
		"pre_fire_speed_dps": pre_fire_speed,
		"settle_ticks": settle_ticks,
		"flags": flags,
		"excluded": excluded,
		"exclusion_reason": excluded_reason,
	}


static func _view_direction(pitch_deg: float, yaw_deg: float) -> PackedFloat64Array:
	var pitch := deg_to_rad(pitch_deg)
	var yaw := deg_to_rad(yaw_deg)
	var cos_pitch := cos(pitch)
	return PackedFloat64Array([
		cos_pitch * cos(yaw),
		cos_pitch * sin(yaw),
		-sin(pitch),
	])


static func _angle_between(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var dot := clampf(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1.0, 1.0)
	var cross_x := a[1] * b[2] - a[2] * b[1]
	var cross_y := a[2] * b[0] - a[0] * b[2]
	var cross_z := a[0] * b[1] - a[1] * b[0]
	var cross_length := sqrt(cross_x * cross_x + cross_y * cross_y + cross_z * cross_z)
	return rad_to_deg(atan2(cross_length, dot))


static func _subtract(a: PackedFloat64Array, b: PackedFloat64Array) -> PackedFloat64Array:
	return PackedFloat64Array([a[0] - b[0], a[1] - b[1], a[2] - b[2]])


static func _cosine(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var dot := a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
	var mag_a := sqrt(a[0] * a[0] + a[1] * a[1] + a[2] * a[2])
	var mag_b := sqrt(b[0] * b[0] + b[1] * b[1] + b[2] * b[2])
	if mag_a == 0.0 or mag_b == 0.0:
		return 0.0
	return clampf(dot / (mag_a * mag_b), -1.0, 1.0)
