class_name Recoil
extends RefCounted

const RifleTableData = preload("res://weapons/rifle_tables.gd")
const WeaponConfigData = preload("res://weapons/weapon_config.gd")

const RUN_SPEED_THRESHOLD := 140.0
const RECOVERY_DELAY_S := 0.4
const RECOVERY_PERIOD_S := 0.0225


static func initial_state(
		weapon_id: String,
		config_overrides: Dictionary = {},
		silenced: bool = true
	) -> Dictionary:
	var weapon: Dictionary = RifleTableData.get_weapon(weapon_id)
	if weapon.is_empty():
		return {}
	return {
		"weapon_id": weapon_id,
		"shots_in_burst": 0,
		"accuracy": float(weapon["accuracy_start"]),
		"px": 0.0,
		"py": 0.0,
		"side_dir": true,
		"next_fire_s": 0.0,
		"last_fire_s": -INF,
		"idle_time_s": 0.0,
		"next_recovery_s": INF,
		"trigger_held": false,
		"silenced": silenced,
		"config": WeaponConfigData.with_overrides(config_overrides),
	}


static func accuracy_for_shots(weapon_id: String, shot_count: int) -> float:
	if shot_count <= 0:
		var weapon: Dictionary = RifleTableData.get_weapon(weapon_id)
		return float(weapon.get("accuracy_start", NAN))
	return RifleTableData.accuracy_for_shots(weapon_id, shot_count)


static func spread_for_next_shot(weapon_state: Dictionary, move_state: Dictionary) -> float:
	var weapon_id := str(weapon_state.get("weapon_id", ""))
	var weapon: Dictionary = RifleTableData.get_weapon(weapon_id)
	if weapon.is_empty():
		return NAN

	var state_name := _spread_state(move_state)
	var spread_table: Dictionary = weapon["spread"]
	if weapon_id == RifleTableData.M4A1 and state_name == "stand" \
			and not bool(weapon_state.get("silenced", true)):
		state_name = "stand_unsilenced"
	var params: Array = spread_table.get(state_name, [])
	if params.size() != 2:
		return NAN
	return float(params[0]) + float(params[1]) * float(weapon_state.get("accuracy", NAN))


static func fire_due(weapon_state: Dictionary, time_s: float) -> bool:
	return time_s + 1e-9 >= float(weapon_state.get("next_fire_s", INF))


static func fire_shot(
		weapon_state: Dictionary,
		move_state: Dictionary,
		rng: Object,
		time_s: float
	) -> Dictionary:
	var weapon_id := str(weapon_state.get("weapon_id", ""))
	var weapon: Dictionary = RifleTableData.get_weapon(weapon_id)
	if weapon.is_empty():
		return {"state": weapon_state.duplicate(true), "shot": {}}

	var spread := spread_for_next_shot(weapon_state, move_state)
	var sx := (float(rng.uniform(-0.5, 0.5)) + float(rng.uniform(-0.5, 0.5))) * spread
	var sy := (float(rng.uniform(-0.5, 0.5)) + float(rng.uniform(-0.5, 0.5))) * spread
	var px := float(weapon_state.get("px", 0.0))
	var py := float(weapon_state.get("py", 0.0))
	var kick_up := -px
	var kick_side := py
	var aim_up := kick_up + rad_to_deg(atan(sy))
	var aim_side := kick_side + rad_to_deg(atan(sx))
	var shot_count := int(weapon_state.get("shots_in_burst", 0)) + 1

	var next_state := weapon_state.duplicate(true)
	var profile := _kick_profile(weapon_state, move_state)
	var up := float(profile[0])
	var side := float(profile[1])
	if shot_count > 1:
		up += float(shot_count) * float(profile[2])
		side += float(shot_count) * float(profile[3])

	var max_up := float(profile[4])
	var max_side := float(profile[5])
	if px > -max_up:
		px = maxf(px - up, -max_up)
	if absf(py) < max_side:
		py = minf(py + side, max_side) if bool(weapon_state.get("side_dir", true)) \
				else maxf(py - side, -max_side)

	var flip_min := 0
	var flip_max := int(profile[6])
	var config: Dictionary = weapon_state.get("config", WeaponConfigData.defaults())
	if not bool(config.get("FLIP_ROLL_INCLUSIVE", true)):
		flip_min = 1
	var flip_roll := int(rng.randint(flip_min, flip_max))
	var should_flip := flip_roll == flip_min
	if str(config.get("KICK_PATTERN_MODE", WeaponConfigData.KICK_PATTERN_RANDOM_FLIP)) \
			== WeaponConfigData.KICK_PATTERN_FIXED:
		var sequence: Array = config.get("FIXED_FLIP_SEQUENCE", [false, true])
		if not sequence.is_empty():
			should_flip = bool(sequence[(shot_count - 1) % sequence.size()])

	var cycle_s := float(weapon["cycle_s"])
	var old_shots := int(weapon_state.get("shots_in_burst", 0))
	next_state["shots_in_burst"] = shot_count
	next_state["accuracy"] = RifleTableData.accuracy_for_shots(weapon_id, shot_count)
	next_state["px"] = px
	next_state["py"] = py
	next_state["side_dir"] = not bool(weapon_state.get("side_dir", true)) if should_flip \
			else bool(weapon_state.get("side_dir", true))
	next_state["next_fire_s"] = time_s + cycle_s if old_shots == 0 \
			else float(weapon_state.get("next_fire_s", time_s)) + cycle_s
	next_state["last_fire_s"] = time_s
	next_state["idle_time_s"] = 0.0
	next_state["trigger_held"] = true
	var first_recovery_drop := RECOVERY_DELAY_S
	if bool(config.get("BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD", true)):
		first_recovery_drop += RECOVERY_PERIOD_S
	next_state["next_recovery_s"] = first_recovery_drop

	return {
		"state": next_state,
		"shot": {
			"shot_index": shot_count,
			"time_s": time_s,
			"spread": spread,
			"spread_x": sx,
			"spread_y": sy,
			"kick_up": kick_up,
			"kick_side": kick_side,
			"aim_up": aim_up,
			"aim_side": aim_side,
		},
	}


static func decay_kick(px: float, py: float, dt: float) -> Array[float]:
	var length := sqrt(px * px + py * py)
	if length == 0.0:
		return [0.0, 0.0]
	var new_length := maxf(length - (10.0 + 0.5 * length) * dt, 0.0)
	var scale := new_length / length
	return [px * scale, py * scale]


static func decay_tick(weapon_state: Dictionary, dt: float) -> Dictionary:
	var next_state := weapon_state.duplicate(true)
	var kick := decay_kick(float(weapon_state.get("px", 0.0)), float(weapon_state.get("py", 0.0)), dt)
	next_state["px"] = kick[0]
	next_state["py"] = kick[1]
	return next_state


static func recover_tick(weapon_state: Dictionary, dt: float) -> Dictionary:
	var next_state := weapon_state.duplicate(true)
	var shot_count := int(weapon_state.get("shots_in_burst", 0))
	var config: Dictionary = weapon_state.get("config", WeaponConfigData.defaults())
	if shot_count <= 0:
		if bool(config.get("ACCURACY_RESET_ON_RECOVERY", false)):
			next_state["accuracy"] = float(RifleTableData.get_weapon(
					str(weapon_state.get("weapon_id", "")))["accuracy_start"])
		return next_state

	var idle_time := float(weapon_state.get("idle_time_s", 0.0)) + dt
	var next_recovery := float(weapon_state.get("next_recovery_s", INF))
	var one_per_tick := bool(config.get("RECOVERY_ONE_PER_TICK", true))
	if one_per_tick:
		if idle_time > next_recovery + 1e-9:
			shot_count -= 1
			if bool(config.get("ACCURACY_RESET_ON_RECOVERY", false)):
				var weapon_id := str(weapon_state.get("weapon_id", ""))
				if shot_count <= 0:
					next_state["accuracy"] = float(RifleTableData.get_weapon(weapon_id)["accuracy_start"])
				else:
					next_state["accuracy"] = RifleTableData.accuracy_for_shots(weapon_id, shot_count)
			next_recovery = idle_time + RECOVERY_PERIOD_S
	else:
		while idle_time + 1e-9 >= next_recovery and shot_count > 0:
			shot_count -= 1
			if bool(config.get("ACCURACY_RESET_ON_RECOVERY", false)):
				var weapon_id := str(weapon_state.get("weapon_id", ""))
				if shot_count <= 0:
					next_state["accuracy"] = float(RifleTableData.get_weapon(weapon_id)["accuracy_start"])
				else:
					next_state["accuracy"] = RifleTableData.accuracy_for_shots(weapon_id, shot_count)
			next_recovery += RECOVERY_PERIOD_S

	next_state["idle_time_s"] = idle_time
	next_state["shots_in_burst"] = shot_count
	next_state["next_recovery_s"] = INF if shot_count <= 0 else next_recovery
	return next_state


static func release_trigger(weapon_state: Dictionary, time_s: float) -> Dictionary:
	var next_state := weapon_state.duplicate(true)
	var config: Dictionary = weapon_state.get("config", WeaponConfigData.defaults())
	var cap := float(config.get("SHOTS_FIRED_RELEASE_CAP", 0.0))
	var shot_count := int(weapon_state.get("shots_in_burst", 0))
	if cap > 0.0:
		shot_count = mini(shot_count, int(floor(cap)))
		next_state["shots_in_burst"] = shot_count
		if bool(config.get("ACCURACY_RESET_ON_RECOVERY", false)):
			var weapon_id := str(weapon_state.get("weapon_id", ""))
			next_state["accuracy"] = float(RifleTableData.get_weapon(weapon_id)["accuracy_start"]) \
					if shot_count <= 0 else RifleTableData.accuracy_for_shots(weapon_id, shot_count)
	if str(config.get("RECOVERY_DELAY_FROM", "last_shot")) == "release":
		next_state["idle_time_s"] = 0.0
		var first_recovery_drop := RECOVERY_DELAY_S
		if bool(config.get("BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD", true)):
			first_recovery_drop += RECOVERY_PERIOD_S
		next_state["next_recovery_s"] = first_recovery_drop
	next_state["trigger_held"] = false
	next_state["last_trigger_release_s"] = time_s
	return next_state


static func finish_tick(
		weapon_state: Dictionary,
		dt: float,
		fired: bool,
		trigger_held: bool = true,
		time_s: float = -1.0
	) -> Dictionary:
	var next_state := decay_tick(weapon_state, dt)
	var was_held := bool(weapon_state.get("trigger_held", false))
	if fired and not trigger_held:
		var release_time := time_s if time_s >= 0.0 else float(weapon_state.get("last_fire_s", 0.0))
		next_state = release_trigger(next_state, release_time)
	elif not fired and was_held and not trigger_held:
		var release_time := time_s if time_s >= 0.0 else \
				float(weapon_state.get("last_fire_s", 0.0)) + float(weapon_state.get("idle_time_s", 0.0)) + dt
		next_state = release_trigger(next_state, release_time)
	next_state["trigger_held"] = trigger_held
	if not fired:
		if trigger_held:
			next_state["idle_time_s"] = float(next_state.get("idle_time_s", 0.0)) + dt
		else:
			next_state = recover_tick(next_state, dt)
	return next_state


static func _spread_state(move_state: Dictionary) -> String:
	if bool(move_state.get("in_air", false)):
		return "air"
	if float(move_state.get("horizontal_speed", 0.0)) > RUN_SPEED_THRESHOLD:
		return "run"
	return "stand"


static func _kick_profile(weapon_state: Dictionary, move_state: Dictionary) -> Array:
	var weapon: Dictionary = RifleTableData.get_weapon(str(weapon_state.get("weapon_id", "")))
	var config: Dictionary = weapon_state.get("config", WeaponConfigData.defaults())
	var in_air := bool(move_state.get("in_air", false))
	var horizontal_speed := float(move_state.get("horizontal_speed", 0.0))
	var crouched := bool(move_state.get("crouched", false))
	var kick_state := "stand"
	if in_air and not (
			bool(config.get("KICK_MOVING_BEFORE_AIR", true)) and horizontal_speed > 0.0
		):
		kick_state = "air"
	elif horizontal_speed > 0.0:
		kick_state = "moving"
	elif crouched:
		kick_state = "crouch"
	return weapon["kick"][kick_state]
