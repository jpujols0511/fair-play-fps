class_name ScriptedPath
extends RefCounted


static func linear(
		start: PackedFloat64Array,
		velocity_ups: PackedFloat64Array,
		tick: int,
		tick_rate: int
	) -> Dictionary:
	var time_s := float(tick) / float(tick_rate)
	return {
		"origin64": PackedFloat64Array([
			start[0] + velocity_ups[0] * time_s,
			start[1] + velocity_ups[1] * time_s,
			start[2] + velocity_ups[2] * time_s,
		]),
		"yaw_deg": 0.0,
	}


static func circle(
		center: PackedFloat64Array,
		radius: float,
		deg_per_s: float,
		tick: int,
		tick_rate: int
	) -> Dictionary:
	var angle_deg := deg_per_s * float(tick) / float(tick_rate)
	var angle_rad := deg_to_rad(angle_deg)
	return {
		"origin64": PackedFloat64Array([
			center[0] + radius * cos(angle_rad),
			center[1] + radius * sin(angle_rad),
			center[2],
		]),
		"yaw_deg": fposmod(angle_deg + 90.0, 360.0),
	}


static func peek(
		cover_pos: PackedFloat64Array,
		open_pos: PackedFloat64Array,
		out_tick: int,
		back_tick: int,
		speed: float,
		tick: int,
		tick_rate: int
	) -> Dictionary:
	var dx := open_pos[0] - cover_pos[0]
	var dy := open_pos[1] - cover_pos[1]
	var dz := open_pos[2] - cover_pos[2]
	var distance := sqrt(dx * dx + dy * dy + dz * dz)
	var move_ticks := distance / speed * float(tick_rate) if speed > 0.0 else INF
	var position := PackedFloat64Array([cover_pos[0], cover_pos[1], cover_pos[2]])
	if tick >= out_tick and float(tick) < float(out_tick) + move_ticks:
		var fraction := (float(tick) - float(out_tick)) / move_ticks
		position = _lerp_position(cover_pos, open_pos, fraction)
	elif float(tick) >= float(out_tick) + move_ticks and tick < back_tick:
		position = PackedFloat64Array([open_pos[0], open_pos[1], open_pos[2]])
	elif tick >= back_tick and float(tick) < float(back_tick) + move_ticks:
		var fraction := (float(tick) - float(back_tick)) / move_ticks
		position = _lerp_position(open_pos, cover_pos, fraction)
	elif float(tick) >= float(back_tick) + move_ticks:
		position = PackedFloat64Array([cover_pos[0], cover_pos[1], cover_pos[2]])
	return {"origin64": position, "yaw_deg": 0.0}


static func stance_toggle(every_n_ticks: int, tick: int) -> int:
	if every_n_ticks <= 0:
		return 0
	var half_cycle := int(floor(float(tick) / float(every_n_ticks)))
	return 1 if half_cycle % 2 == 1 else 0


static func spawn_at(tick: int, spawn_tick: int) -> bool:
	return tick >= spawn_tick


static func die_at(tick: int, death_tick: int) -> bool:
	return death_tick < 0 or tick < death_tick


static func sample(
		path: Dictionary,
		tick: int,
		tick_rate: int,
		stance_every_n_ticks: int = 0,
		spawn_tick: int = -1,
		death_tick: int = -1
	) -> Dictionary:
	var pose: Dictionary = {}
	match str(path["kind"]):
		"linear":
			pose = linear(
				PackedFloat64Array(path["start"]),
				PackedFloat64Array(path["velocity_ups"]),
				tick,
				tick_rate
			)
			if path.has("yaw_deg"):
				pose["yaw_deg"] = float(path["yaw_deg"])
		"circle":
			pose = circle(
				PackedFloat64Array(path["center"]),
				float(path["radius"]),
				float(path["deg_per_s"]),
				tick,
				tick_rate
			)
		"peek":
			pose = peek(
				PackedFloat64Array(path["cover_pos"]),
				PackedFloat64Array(path["open_pos"]),
				int(path["out_tick"]),
				int(path["back_tick"]),
				float(path["speed"]),
				tick,
				tick_rate
			)
			if path.has("yaw_deg"):
				pose["yaw_deg"] = float(path["yaw_deg"])
		_:
			pose = {"origin64": PackedFloat64Array([0.0, 0.0, 0.0]), "yaw_deg": 0.0}
	return {
		"tick": tick,
		"origin64": pose["origin64"],
		"yaw_deg": float(pose["yaw_deg"]),
		"stance": stance_toggle(stance_every_n_ticks, tick),
		"alive": spawn_at(tick, spawn_tick) and die_at(tick, death_tick),
	}


static func _lerp_position(a: PackedFloat64Array, b: PackedFloat64Array, fraction: float) -> PackedFloat64Array:
	return PackedFloat64Array([
		a[0] + (b[0] - a[0]) * fraction,
		a[1] + (b[1] - a[1]) * fraction,
		a[2] + (b[2] - a[2]) * fraction,
	])
