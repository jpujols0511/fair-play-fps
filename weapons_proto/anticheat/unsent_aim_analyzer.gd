class_name UnsentAimAnalyzer
extends RefCounted

const ParamsData = preload("res://anticheat/anticheat_params.gd")
const HitboxBuilder = preload("res://hitreg/hitboxes.gd")
const RifleTables = preload("res://weapons/rifle_tables.gd")

const VIS_TYPE := 2
const SHOT_TYPE := 1
const AIM_KIN_TYPE := 6
const SHOT_TARGET_NOT_SENT := 1 << 3
const SHOT_THROUGH_WORLD := 1 << 2
const AIM_KIN_FLAGS := 0x03
const PART_NAMES := [
	"head", "chest", "stomach", "upper_arm_l", "upper_arm_r",
	"forearm_l", "forearm_r", "thigh_l", "thigh_r", "shin_l", "shin_r",
]
const REVIEW_REQUIRED := "NEEDS_HUMAN_REVIEW"
const NO_FLAG := "NO_FLAG"
const AUTO_ACTION := "NONE"


static func analyze(
		match_id: String,
		timeline: Array,
		evidence: Dictionary,
		preaim_spots: Array = [],
		params_overrides: Dictionary = {},
		server_metadata: Dictionary = {}
	) -> Dictionary:
	var params: Dictionary = ParamsData.for_server_metadata(server_metadata, params_overrides)
	var header: Dictionary = evidence.get("header", {})
	var records: Array = evidence.get("records", [])
	var evidence_chain_ok := bool(evidence.get("ok", false))
	if not bool(params["ENABLE_ANTICHEAT_REVIEW"]):
		return {
			"match_id": match_id,
			"analyzer_version": "0.1",
			"params": ParamsData.evidence_params(params),
			"evidence_chain_ok": evidence_chain_ok,
			"players": [],
			"aim_kinematics": [],
			"auto_action": AUTO_ACTION,
			"disabled": true,
		}
	var tick_rate := int(header.get("tick_rate", 128))
	var frames_by_tick := _frames_by_tick(timeline)
	var ticks := frames_by_tick.keys()
	ticks.sort()
	var slots: Array = header.get("slots", [])
	var teams := {}
	var player_refs := {}
	for slot_index in range(slots.size()):
		teams[slot_index] = int(slots[slot_index]["team"])
		player_refs[slot_index] = _bytes_hex(slots[slot_index]["player_ref"])
	var vis_by_viewer := _vis_records(records)
	var shots_by_player := _shots_by_player(records)
	var aim_kinematics := _aim_kin_records(records, frames_by_tick, shots_by_player, params)
	var aim_kin_rounds := _flagged_rounds(aim_kinematics)
	var players_out: Array = []

	for viewer_slot in range(slots.size()):
		var episodes: Array = []
		for target_slot in range(slots.size()):
			if target_slot == viewer_slot or teams[target_slot] == teams[viewer_slot]:
				continue
			episodes.append_array(_pair_episodes(
				viewer_slot,
				target_slot,
				ticks,
				frames_by_tick,
				vis_by_viewer,
				preaim_spots,
				teams,
				tick_rate,
				params
			))
		episodes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["start_tick"]) == int(b["start_tick"]):
				return int(a["target_slot"]) < int(b["target_slot"])
			return int(a["start_tick"]) < int(b["start_tick"])
		)
		var weighted_episodes := 0.0
		for episode in episodes:
			weighted_episodes += float(episode["weight"])

		var shots_at_unsent := _shots_at_unsent(
			viewer_slot,
			shots_by_player.get(viewer_slot, []),
			vis_by_viewer,
			tick_rate,
			frames_by_tick
		)
		var clean_unsent_hits := 0
		for shot in shots_at_unsent:
			if shot["outcome"] == "hit" and not bool(shot["through_world"]):
				clean_unsent_hits += 1
		var review_rounds: Dictionary = aim_kin_rounds.get(viewer_slot, {})
		var needs_aim_kin_review := review_rounds.size() >= int(params["N_AIM_KIN"])
		var status := NO_FLAG
		if evidence_chain_ok and (
				weighted_episodes >= float(params["MIN_EPISODES"])
				or clean_unsent_hits >= int(params["UNSENT_HITS_REQUIRED"])
				or needs_aim_kin_review
			):
			status = REVIEW_REQUIRED
		players_out.append({
			"slot": viewer_slot,
			"player_ref": str(player_refs[viewer_slot]),
			"weighted_episodes": _round_float(weighted_episodes, 4),
			"episodes": episodes,
			"shots_at_unsent": shots_at_unsent,
			"status": status,
		})

	return {
		"match_id": match_id,
		"analyzer_version": "0.1",
		"params": ParamsData.evidence_params(params),
		"evidence_chain_ok": evidence_chain_ok,
		"players": players_out,
		"aim_kinematics": aim_kinematics,
		"auto_action": AUTO_ACTION,
	}


static func _pair_episodes(
		viewer_slot: int,
		target_slot: int,
		ticks: Array,
		frames_by_tick: Dictionary,
		vis_by_viewer: Dictionary,
		preaim_spots: Array,
		teams: Dictionary,
		tick_rate: int,
		params: Dictionary
	) -> Array:
	var episodes: Array = []
	var run: Array = []
	var minimum_ticks := int(ceil(float(params["Y_MS"]) * float(tick_rate) / 1000.0))
	for tick_value in ticks:
		var tick := int(tick_value)
		var frame: Dictionary = frames_by_tick[tick]
		var players: Dictionary = frame["players"]
		if not players.has(viewer_slot) or not players.has(target_slot):
			_append_finished_run(episodes, run, viewer_slot, target_slot, ticks, frames_by_tick, vis_by_viewer, preaim_spots, teams, tick_rate, params, minimum_ticks)
			run = []
			continue
		var viewer: Dictionary = players[viewer_slot]
		var target: Dictionary = players[target_slot]
		var active := bool(viewer.get("alive", true)) \
				and not bool(viewer.get("spectating", false)) \
				and not bool(viewer.get("in_menu", false))
		var sent := _vis_at(vis_by_viewer, viewer_slot, tick)
		var target_sent := (int(sent["sent_mask"]) & (1 << target_slot)) != 0
		if not active or not bool(target.get("alive", true)) or target_sent:
			_append_finished_run(episodes, run, viewer_slot, target_slot, ticks, frames_by_tick, vis_by_viewer, preaim_spots, teams, tick_rate, params, minimum_ticks)
			run = []
			continue
		var aim: Dictionary = _aim_angle(viewer, target)
		if float(aim["theta_deg"]) <= float(params["X_DEG"]):
			if not run.is_empty() and tick != int(run[-1]["tick"]) + 1:
				_append_finished_run(episodes, run, viewer_slot, target_slot, ticks, frames_by_tick, vis_by_viewer, preaim_spots, teams, tick_rate, params, minimum_ticks)
				run = []
			run.append({
				"tick": tick,
				"theta_deg": float(aim["theta_deg"]),
				"viewer": viewer,
				"target": target,
				"target_point": aim["target_point"],
				"bearing": float(aim["bearing"]),
				"round": int(frame.get("round", 0)),
			})
		else:
			_append_finished_run(episodes, run, viewer_slot, target_slot, ticks, frames_by_tick, vis_by_viewer, preaim_spots, teams, tick_rate, params, minimum_ticks)
			run = []
	_append_finished_run(episodes, run, viewer_slot, target_slot, ticks, frames_by_tick, vis_by_viewer, preaim_spots, teams, tick_rate, params, minimum_ticks)
	return episodes


static func _append_finished_run(
		episodes: Array,
		run: Array,
		viewer_slot: int,
		target_slot: int,
		ticks: Array,
		frames_by_tick: Dictionary,
		vis_by_viewer: Dictionary,
		preaim_spots: Array,
		teams: Dictionary,
		tick_rate: int,
		params: Dictionary,
		minimum_ticks: int
	) -> void:
	if run.size() < minimum_ticks:
		return
	var start_tick := int(run[0]["tick"])
	var end_tick := int(run[-1]["tick"])
	var drop_reasons: Array[String] = []
	var checked := ["just_left_view", "sound", "preaim", "teammate", "dead", "same_team"]
	if _just_left_view(viewer_slot, target_slot, start_tick, vis_by_viewer, tick_rate, params):
		drop_reasons.append("just_left_view")
	if _sound_explains(
			viewer_slot, target_slot, start_tick, run[0], ticks,
			frames_by_tick, vis_by_viewer, tick_rate, params
		):
		drop_reasons.append("sound")
	if _preaim_explains(run[0]["target_point"], run[0]["viewer"].get("map_area", ""), preaim_spots):
		drop_reasons.append("preaim")
	var viewer_state: Dictionary = run[0]["viewer"]
	var target_state: Dictionary = run[0]["target"]
	if not bool(viewer_state.get("alive", true)) \
			or bool(viewer_state.get("spectating", false)) \
			or bool(viewer_state.get("in_menu", false)):
		drop_reasons.append("dead")
	if teams.get(viewer_slot, 0) == teams.get(target_slot, -1):
		drop_reasons.append("same_team")
	var correlation := _tracking_correlation(run, tick_rate)
	var target_speed := _mean_target_speed(run, tick_rate)
	var tracking := target_speed > float(params["MIN_TARGET_SPEED"]) \
			and correlation >= float(params["TRACKING_CORRELATION"])
	var weight := 0.0 if drop_reasons.size() > 0 else 1.0
	if weight > 0.0 and _teammate_has_target_sent(
			viewer_slot, target_slot, start_tick, ticks, frames_by_tick,
			vis_by_viewer, teams, tick_rate, params
		):
		weight = float(params["TEAM_INFO_WEIGHT"])
		drop_reasons.append("teammate")
	episodes.append({
		"kind": "tracking" if tracking else "aim",
		"target_slot": target_slot,
		"round": int(run[0]["round"]),
		"start_tick": start_tick,
		"end_tick": end_tick,
		"min_theta_deg": _round_float(_run_min_theta(run), 4),
		"tracking_correlation": _round_float(correlation, 4),
		"target_speed_ups": _round_float(target_speed, 3),
		"dropped_reasons_checked": checked,
		"dropped": weight == 0.0,
		"drop_reasons": drop_reasons,
		"weight": weight,
	})


static func _frames_by_tick(timeline: Array) -> Dictionary:
	var frames := {}
	for source_frame in timeline:
		var frame: Dictionary = source_frame.duplicate(true)
		var players_by_slot := {}
		var source_players: Variant = frame.get("players", [])
		if typeof(source_players) == TYPE_DICTIONARY:
			for slot in source_players:
				players_by_slot[int(slot)] = source_players[slot]
		else:
			for player in source_players:
				players_by_slot[int(player["slot"])] = player
		frame["players"] = players_by_slot
		frames[int(frame["tick"])] = frame
	return frames


static func _vis_records(records: Array) -> Dictionary:
	var result := {}
	for record in records:
		if int(record["type"]) != VIS_TYPE:
			continue
		var fields: Dictionary = record["fields"]
		var viewer := int(fields["viewer_slot"])
		if not result.has(viewer):
			result[viewer] = []
		result[viewer].append({
			"tick": int(record["tick"]),
			"sent_mask": int(fields["sent_mask"]),
			"sound_only_mask": int(fields["sound_only_mask"]),
		})
	for viewer in result:
		result[viewer].sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["tick"]) < int(b["tick"])
		)
	return result


static func _vis_at(vis_by_viewer: Dictionary, viewer_slot: int, tick: int) -> Dictionary:
	var current := {"sent_mask": 0, "sound_only_mask": 0}
	for vis in vis_by_viewer.get(viewer_slot, []):
		if int(vis["tick"]) > tick:
			break
		current = vis
	return current


static func _aim_angle(viewer: Dictionary, target: Dictionary) -> Dictionary:
	var eye := _eye_position(viewer)
	var target_boxes: Array = HitboxBuilder.build_boxes_precise(
		_as_position(target.get("origin64", target.get("origin", [0.0, 0.0, 0.0]))),
		float(target.get("yaw_deg", target.get("yaw", 0.0))),
		int(target.get("stance", HitboxBuilder.STAND))
	)
	var view_direction := _view_direction(
		float(viewer.get("view_pitch", 0.0)),
		float(viewer.get("view_yaw", 0.0))
	)
	var best_theta := INF
	var best_point := PackedFloat64Array([0.0, 0.0, 0.0])
	var best_bearing := 0.0
	for box_id in [0, 1]:
		var center: PackedFloat64Array = target_boxes[box_id]["center64"]
		var direction := _normalize(PackedFloat64Array([
			center[0] - eye[0],
			center[1] - eye[1],
			center[2] - eye[2],
		]))
		var theta := _angle_between(view_direction, direction)
		if theta < best_theta:
			best_theta = theta
			best_point = center
			best_bearing = rad_to_deg(atan2(center[1] - eye[1], center[0] - eye[0]))
	return {"theta_deg": best_theta, "target_point": best_point, "bearing": best_bearing}


static func _eye_position(player: Dictionary) -> PackedFloat64Array:
	var origin := _as_position(player.get("origin64", player.get("origin", [0.0, 0.0, 0.0]))).duplicate()
	var stance := int(player.get("stance", HitboxBuilder.STAND))
	origin[2] += HitboxBuilder.eye_height(stance)
	return origin


static func _as_position(value: Variant) -> PackedFloat64Array:
	if typeof(value) == TYPE_PACKED_FLOAT64_ARRAY:
		return value
	if typeof(value) == TYPE_VECTOR3:
		return PackedFloat64Array([value.x, value.y, value.z])
	return PackedFloat64Array([float(value[0]), float(value[1]), float(value[2])])


static func _view_direction(pitch_deg: float, yaw_deg: float) -> PackedFloat64Array:
	var pitch := deg_to_rad(pitch_deg)
	var yaw := deg_to_rad(yaw_deg)
	var cp := cos(pitch)
	return PackedFloat64Array([
		cp * cos(yaw),
		cp * sin(yaw),
		-sin(pitch),
	])


static func _normalize(vector: PackedFloat64Array) -> PackedFloat64Array:
	var length := sqrt(
		vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2]
	)
	if length <= 0.0:
		return PackedFloat64Array([0.0, 0.0, 0.0])
	return PackedFloat64Array([vector[0] / length, vector[1] / length, vector[2] / length])


static func _angle_between(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var dot := clampf(a[0] * b[0] + a[1] * b[1] + a[2] * b[2], -1.0, 1.0)
	var cx := a[1] * b[2] - a[2] * b[1]
	var cy := a[2] * b[0] - a[0] * b[2]
	var cz := a[0] * b[1] - a[1] * b[0]
	return rad_to_deg(atan2(sqrt(cx * cx + cy * cy + cz * cz), dot))


static func _just_left_view(
		viewer_slot: int,
		target_slot: int,
		start_tick: int,
		vis_by_viewer: Dictionary,
		tick_rate: int,
		params: Dictionary
	) -> bool:
	var grace := int(ceil(float(params["JUST_LEFT_VIEW_MS"]) * float(tick_rate) / 1000.0))
	for tick in range(maxi(0, start_tick - grace), start_tick):
		if int(_vis_at(vis_by_viewer, viewer_slot, tick)["sent_mask"]) & (1 << target_slot):
			return true
	return false


static func _sound_explains(
		viewer_slot: int,
		target_slot: int,
		start_tick: int,
		first_aim: Dictionary,
		ticks: Array,
		frames_by_tick: Dictionary,
		vis_by_viewer: Dictionary,
		tick_rate: int,
		params: Dictionary
	) -> bool:
	var window := int(ceil(float(params["SOUND_EXPLAIN_MS"]) * float(tick_rate) / 1000.0))
	var viewer: Dictionary = first_aim["viewer"]
	var eye := _eye_position(viewer)
	var view_direction := _view_direction(
		float(viewer.get("view_pitch", 0.0)),
		float(viewer.get("view_yaw", 0.0))
	)
	for tick_value in ticks:
		var tick := int(tick_value)
		if tick < start_tick - window or tick > start_tick:
			continue
		var vis := _vis_at(vis_by_viewer, viewer_slot, tick)
		if (int(vis["sound_only_mask"]) & (1 << target_slot)) == 0:
			continue
		var frame: Dictionary = frames_by_tick[tick]
		for sound in frame.get("sound_events", frame.get("sounds", [])):
			if int(sound.get("source_slot", -1)) != target_slot:
				continue
			if viewer_slot not in sound.get("heard_by", []):
				continue
			var sound_position := _as_position(sound.get("rounded_pos", [0.0, 0.0, 0.0]))
			var direction := _normalize(PackedFloat64Array([
				sound_position[0] - eye[0],
				sound_position[1] - eye[1],
				sound_position[2] - eye[2],
			]))
			if _angle_between(view_direction, direction) <= float(params["SOUND_ANGLE_DEG"]):
				return true
	return false


static func _preaim_explains(target_point: PackedFloat64Array, map_area: Variant, spots: Array) -> bool:
	for spot in spots:
		if spot.has("map_area") and spot["map_area"] != map_area:
			continue
		var point := _as_position(spot["point"])
		var dx := target_point[0] - point[0]
		var dy := target_point[1] - point[1]
		var dz := target_point[2] - point[2]
		var radius := float(spot["radius"])
		if dx * dx + dy * dy + dz * dz <= radius * radius:
			return true
	return false


static func _teammate_has_target_sent(
		viewer_slot: int,
		target_slot: int,
		start_tick: int,
		ticks: Array,
		frames_by_tick: Dictionary,
		vis_by_viewer: Dictionary,
		teams: Dictionary,
		tick_rate: int,
		params: Dictionary
	) -> bool:
	var window := int(ceil(float(params["TEAM_INFO_WINDOW_MS"]) * float(tick_rate) / 1000.0))
	for tick_value in ticks:
		var tick := int(tick_value)
		if tick < start_tick - window or tick > start_tick:
			continue
		var frame: Dictionary = frames_by_tick[tick]
		for teammate_value in frame["players"]:
			var teammate_slot := int(teammate_value)
			if teammate_slot == viewer_slot or teams.get(teammate_slot, 0) != teams.get(viewer_slot, -1):
				continue
			var teammate: Dictionary = frame["players"][teammate_slot]
			if not bool(teammate.get("alive", true)):
				continue
			var sent := _vis_at(vis_by_viewer, teammate_slot, tick)
			if int(sent["sent_mask"]) & (1 << target_slot):
				return true
	return false


static func _tracking_correlation(run: Array, tick_rate: int) -> float:
	var yaw_rates: Array[float] = []
	var bearing_rates: Array[float] = []
	for index in range(1, run.size()):
		var before: Dictionary = run[index - 1]
		var after: Dictionary = run[index]
		var tick_delta := int(after["tick"]) - int(before["tick"])
		if tick_delta <= 0:
			continue
		var yaw_before := float(before["viewer"].get("view_yaw", 0.0))
		var yaw_after := float(after["viewer"].get("view_yaw", 0.0))
		yaw_rates.append(_angle_delta(yaw_before, yaw_after) * float(tick_rate) / float(tick_delta))
		bearing_rates.append(
			_angle_delta(float(before["bearing"]), float(after["bearing"]))
			* float(tick_rate) / float(tick_delta)
		)
	return _pearson(yaw_rates, bearing_rates)


static func _mean_target_speed(run: Array, tick_rate: int) -> float:
	var total := 0.0
	var count := 0
	for index in range(1, run.size()):
		var before: Dictionary = run[index - 1]
		var after: Dictionary = run[index]
		var tick_delta := int(after["tick"]) - int(before["tick"])
		if tick_delta <= 0:
			continue
		var origin_before := _as_position(before["target"].get("origin64", before["target"].get("origin")))
		var origin_after := _as_position(after["target"].get("origin64", after["target"].get("origin")))
		var dx := origin_after[0] - origin_before[0]
		var dy := origin_after[1] - origin_before[1]
		var dz := origin_after[2] - origin_before[2]
		total += sqrt(dx * dx + dy * dy + dz * dz) * float(tick_rate) / float(tick_delta)
		count += 1
	return total / float(count) if count > 0 else 0.0


static func _run_min_theta(run: Array) -> float:
	var minimum := INF
	for sample in run:
		minimum = minf(minimum, float(sample["theta_deg"]))
	return minimum


static func _shots_by_player(records: Array) -> Dictionary:
	var result := {}
	for record in records:
		if int(record["type"]) != SHOT_TYPE:
			continue
		var fields: Dictionary = record["fields"]
		var shooter := int(fields["shooter_slot"])
		if not result.has(shooter):
			result[shooter] = []
		result[shooter].append(record)
	for shooter in result:
		result[shooter].sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if int(a["tick"]) == int(b["tick"]):
				return int(a["fields"]["shot_index"]) < int(b["fields"]["shot_index"])
			return int(a["tick"]) < int(b["tick"])
		)
	return result


static func _shots_at_unsent(
		viewer_slot: int,
		records: Array,
		_vis_by_viewer: Dictionary,
		_tick_rate: int,
		_frames_by_tick: Dictionary
	) -> Array:
	var result: Array = []
	for record in records:
		var flags := int(record["flags"])
		if flags & (1 << 3) == 0:
			continue
		var fields: Dictionary = record["fields"]
		result.append({
			"tick": int(record["tick"]),
			"target_slot": int(fields["target_slot"]),
			"outcome": "hit" if int(fields["outcome"]) == 0 else "near_miss",
			"through_world": (flags & (1 << 2)) != 0,
		})
	return result


static func _aim_kin_records(
		records: Array,
		frames_by_tick: Dictionary,
		shots_by_player: Dictionary,
		params: Dictionary
	) -> Array:
	var shot_lookup := {}
	for shooter in shots_by_player:
		for shot in shots_by_player[shooter]:
			var fields: Dictionary = shot["fields"]
			if not fields.has("shot_index"):
				continue
			var key := "%d:%d" % [int(shooter), int(fields["shot_index"])]
			var previous: Dictionary = shot_lookup.get(key, {})
			if previous.is_empty() or (
					int(previous["fields"]["outcome"]) != 0
					and int(fields["outcome"]) == 0
				):
				shot_lookup[key] = shot
	var result: Array = []
	for record in records:
		if int(record["type"]) != AIM_KIN_TYPE or (int(record["flags"]) & AIM_KIN_FLAGS) == 0:
			continue
		var fields: Dictionary = record["fields"]
		var shooter_slot := int(fields["shooter_slot"])
		var shot_index := int(fields["shot_index"])
		var key := "%d:%d" % [shooter_slot, shot_index]
		if not shot_lookup.has(key):
			continue
		var shot: Dictionary = shot_lookup[key]
		var shot_fields: Dictionary = shot["fields"]
		var frame: Dictionary = frames_by_tick.get(int(record["tick"]), {})
		var round_index := int(frame.get("round", 0))
		var flags := int(record["flags"])
		var shot_flags: Array[String] = []
		if flags & 1:
			shot_flags.append("snapback")
		if flags & 2:
			shot_flags.append("flick_stop_at_fire")
		var move_state := int(fields["move_state"])
		var weapon_tables: Array = RifleTables.TABLES.values()
		var weapon_index := int(shot_fields["weapon_id"]) - 1
		if weapon_index < 0 or weapon_index >= weapon_tables.size():
			continue
		var weapon: Dictionary = weapon_tables[weapon_index]
		var spread_state: String = ["stand", "crouch", "air", "run"][clampi(move_state, 0, 3)]
		var spread_table: Array = weapon["spread"][spread_state]
		var spread_minimum := float(fields["spread_at_fire"]) <= float(spread_table[0]) + 1e-6
		result.append({
			"tick": int(record["tick"]),
			"shooter_slot": shooter_slot,
			"round": round_index,
			"shot_index": shot_index,
			"flags": shot_flags,
			"move_state": spread_state,
			"spread_at_fire": _round_float(float(fields["spread_at_fire"]), 6),
			"spread_at_first_shot_minimum": spread_minimum,
			"peak_ang_vel_dps": _round_float(float(fields["peak_ang_vel_dps"]), 6),
			"peak_ang_accel_dps2": _round_float(float(fields["peak_ang_accel_dps2"]), 6),
			"fire_tick_delta_deg": _round_float(float(fields["fire_tick_delta_deg"]), 6),
			"snapback_deg": _round_float(float(fields["snapback_deg"]), 6),
			"snapback_cos": _round_float(float(fields["snapback_cos"]), 6),
			"pre_fire_speed_dps": _round_float(float(fields["pre_fire_speed_dps"]), 6),
			"settle_ticks": int(fields["settle_ticks"]),
			"shot_outcome": "hit" if int(shot_fields["outcome"]) == 0 else "near_miss",
			"part": str(PART_NAMES[clampi(int(shot_fields["part"]), 0, PART_NAMES.size() - 1)]),
		})
	return result


static func _flagged_rounds(aim_kinematics: Array) -> Dictionary:
	var result := {}
	for item in aim_kinematics:
		var slot := int(item["shooter_slot"])
		if not result.has(slot):
			result[slot] = {}
		result[slot][int(item["round"])] = true
	return result


static func _bytes_hex(value: Variant) -> String:
	if typeof(value) == TYPE_PACKED_BYTE_ARRAY:
		return value.hex_encode()
	if typeof(value) == TYPE_STRING:
		return str(value).to_lower()
	return ""


static func _angle_delta(from_deg: float, to_deg: float) -> float:
	return fposmod(to_deg - from_deg + 180.0, 360.0) - 180.0


static func _pearson(a: Array[float], b: Array[float]) -> float:
	if a.size() != b.size() or a.size() < 2:
		return 0.0
	var mean_a := 0.0
	var mean_b := 0.0
	for index in range(a.size()):
		mean_a += a[index]
		mean_b += b[index]
	mean_a /= float(a.size())
	mean_b /= float(b.size())
	var covariance := 0.0
	var variance_a := 0.0
	var variance_b := 0.0
	for index in range(a.size()):
		var da := a[index] - mean_a
		var db := b[index] - mean_b
		covariance += da * db
		variance_a += da * da
		variance_b += db * db
	if variance_a <= 0.0 or variance_b <= 0.0:
		return 0.0
	return covariance / sqrt(variance_a * variance_b)


static func _round_float(value: float, places: int) -> float:
	var scale := pow(10.0, float(places))
	return roundf(value * scale) / scale
