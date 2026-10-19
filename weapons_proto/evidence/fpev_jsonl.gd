class_name FpevJsonl
extends RefCounted

const Reader = preload("res://evidence/fpev_reader.gd")
const ConfigData = preload("res://evidence/evidence_config.gd")
const FrameAdapter = preload("res://shared/frame.gd")
const InputCommand = preload("res://shared/input_cmd.gd")
const WEAPON_NAMES := {1: "AK47", 2: "M4A1"}
const PART_NAMES := [
	"head", "chest", "stomach", "upper_arm_l", "upper_arm_r",
	"forearm_l", "forearm_r", "thigh_l", "thigh_r", "shin_l", "shin_r",
]
const STANCE_NAMES := ["stand", "crouch", "air", "crouch_air"]
const MOVE_STATE_NAMES := ["stand", "crouch", "air", "run"]
const REWIND_REASONS := [
	"none", "claimed_time_out_of_window", "over_rewind_cap",
	"claimed_time_and_cap", "negative_rewind", "claimed_time_and_negative",
	"missing_history", "reserved",
]
const INPUT_REASONS := {
	1: "claimed_time_out_of_window",
	2: "view_angle_delta_too_large",
	3: "input_rate_off",
	4: "malformed",
}

var _config: Dictionary = {}


func _init(config_overrides: Dictionary = {}) -> void:
	_config = ConfigData.with_overrides(config_overrides)


func export_bytes(data: PackedByteArray, expected_final_hash: PackedByteArray = PackedByteArray()) -> Dictionary:
	var reader := Reader.new(_config)
	var verification := reader.read_bytes(data, expected_final_hash)
	var lines: Array[String] = []
	for record in verification["records"]:
		var row: Dictionary = _record_json(record)
		if not row.is_empty():
			lines.append(JSON.stringify(row))
	var text := "\n".join(lines)
	if not text.is_empty():
		text += "\n"
	return {
		"ok": bool(verification["ok"]),
		"text": text,
		"status": reader.chain_status(verification),
		"verification": verification,
	}


func _record_json(record: Dictionary) -> Dictionary:
	var fields: Dictionary = record["fields"]
	var tick := int(record["tick"])
	match int(record["type"]):
		1:
			return _shot_json(tick, int(record["flags"]), fields)
		2:
			return _vis_json(tick, int(record["flags"]), fields)
		3:
			return {
				"type": "input_reject",
				"tick": tick,
				"player": int(fields["player_slot"]),
				"reason": str(INPUT_REASONS.get(int(fields["reason"]), "unknown")),
				"cmd_seq": int(fields["cmd_seq"]),
				"claimed_time": _round_float(float(fields["claimed_time_s"]), 9),
				"expected_time": _round_float(float(fields["expected_time_s"]), 9),
			}
		4:
			return {
				"type": "checkpoint",
				"tick": tick,
				"record_count": int(fields["record_count"]),
				"chain": fields["chain_sha256"].hex_encode(),
			}
		5:
			return _rewind_json(tick, int(record["flags"]), fields)
		6:
			return _aim_kin_json(tick, int(record["flags"]), fields)
	return {}


func _shot_json(tick: int, flags: int, fields: Dictionary) -> Dictionary:
	return {
		"type": "shot",
		"tick": tick,
		"shooter": int(fields["shooter_slot"]),
		"target": int(fields["target_slot"]),
		"weapon": str(WEAPON_NAMES.get(int(fields["weapon_id"]), "unknown")),
		"part": str(PART_NAMES[int(fields["part"])]) if int(fields["part"]) < PART_NAMES.size() else "unknown",
		"outcome": "hit" if int(fields["outcome"]) == 0 else "near_miss",
		"stance": str(STANCE_NAMES[int(fields["target_stance"])]) if int(fields["target_stance"]) < STANCE_NAMES.size() else "unknown",
		"shot_index": int(fields["shot_index"]),
		"eye": _round_vec(fields["eye_pos"], 6),
		"view": {
			"pitch": _round_float(
				FrameAdapter.pitch_to_spec_deg(
					InputCommand.dequantize_pitch(int(fields["view_pitch_q"]))
				),
				6
			),
			"yaw": _round_float(
				FrameAdapter.yaw_to_spec_deg(
					InputCommand.dequantize_yaw(int(fields["view_yaw_q"]))
				),
				6
			),
		},
		"spread": [
			_round_float(float(fields["spread_x"]), 6),
			_round_float(float(fields["spread_y"]), 6),
		],
		"kick": {
			"up": _round_float(float(fields["kick_up"]), 6),
			"side": _round_float(float(fields["kick_side"]), 6),
		},
		"rewind": {
			"ticks": int(fields["rewind_ticks"]),
			"frac": _round_float(float(fields["rewind_frac"]) / 65536.0, 9),
		},
		"server_time": _round_float(float(fields["server_time_s"]), 9),
		"client_time": _round_float(float(fields["client_claimed_time_s"]), 9),
		"closest_dist": _round_float(float(fields["closest_dist"]), 6),
		"ray_point": _round_vec(fields["ray_point"], 6),
		"box_point": _round_vec(fields["box_point"], 6),
		"target_origin": _round_vec(fields["target_origin"], 6),
		"target_yaw": _round_float(float(fields["target_yaw"]), 6),
		"flags": _shot_flags(flags),
	}


func _vis_json(tick: int, flags: int, fields: Dictionary) -> Dictionary:
	return {
		"type": "vis",
		"tick": tick,
		"viewer": int(fields["viewer_slot"]),
		"sent": _mask_slots(int(fields["sent_mask"])),
		"sound_only": _mask_slots(int(fields["sound_only_mask"])),
		"keyframe": (flags & 1) != 0,
	}


func _rewind_json(tick: int, flags: int, fields: Dictionary) -> Dictionary:
	return {
		"type": "rewind_decision",
		"tick": tick,
		"shooter": int(fields["shooter_slot"]),
		"shot_index": int(fields["shot_index"]),
		"cmd_seq": int(fields["cmd_seq"]),
		"reason": str(REWIND_REASONS[int(fields["reason"])]) if int(fields["reason"]) < REWIND_REASONS.size() else "unknown",
		"flags": _rewind_flags(flags),
		"interp_ticks": int(fields["interp_ticks"]),
		"rtt_ms": _round_float(float(fields["rtt_ms"]), 6),
		"claimed_view_tick": _round_float(float(fields["claimed_view_tick"]), 9),
		"expected_view_tick": _round_float(float(fields["expected_view_tick"]), 9),
		"chosen_view_tick": _round_float(float(fields["chosen_view_tick"]), 9),
		"wanted_rewind_ticks": _round_float(float(fields["wanted_rewind_ticks"]), 6),
		"rewind": {
			"ticks": int(fields["rewind_ticks"]),
			"frac": _round_float(float(fields["rewind_frac"]) / 65536.0, 9),
		},
		"max_rewind_ticks": int(fields["max_rewind_ticks"]),
		"targets_rewound": int(fields["targets_rewound"]),
		"rewound": _mask_slots(int(fields["rewound_mask"])),
		"checkpoint_index": int(fields["checkpoint_index"]),
	}


func _aim_kin_json(tick: int, flags: int, fields: Dictionary) -> Dictionary:
	return {
		"type": "aim_kin",
		"tick": tick,
		"shooter": int(fields["shooter_slot"]),
		"shot_index": int(fields["shot_index"]),
		"window_ticks": int(fields["window_ticks"]),
		"move_state": str(MOVE_STATE_NAMES[int(fields["move_state"])]) if int(fields["move_state"]) < MOVE_STATE_NAMES.size() else "unknown",
		"spread_at_fire": _round_float(float(fields["spread_at_fire"]), 6),
		"peak_ang_vel_dps": _round_float(float(fields["peak_ang_vel_dps"]), 6),
		"peak_ang_accel_dps2": _round_float(float(fields["peak_ang_accel_dps2"]), 6),
		"fire_tick_delta_deg": _round_float(float(fields["fire_tick_delta_deg"]), 6),
		"snapback_deg": _round_float(float(fields["snapback_deg"]), 6),
		"snapback_cos": _round_float(float(fields["snapback_cos"]), 6),
		"pre_fire_speed_dps": _round_float(float(fields["pre_fire_speed_dps"]), 6),
		"settle_ticks": int(fields["settle_ticks"]),
		"flags": _aim_kin_flags(flags),
	}


func _mask_slots(mask: int) -> Array:
	var slots: Array = []
	for slot in range(16):
		if mask & (1 << slot):
			slots.append(slot)
	return slots


func _shot_flags(flags: int) -> Array[String]:
	var names: Array[String] = []
	if flags & (1 << 0):
		names.append("rewind_clamped")
	if flags & (1 << 1):
		names.append("claimed_time_out_of_window")
	if flags & (1 << 2):
		names.append("through_world")
	if flags & (1 << 3):
		names.append("target_not_sent")
	return names


func _rewind_flags(flags: int) -> Array[String]:
	var names: Array[String] = []
	if flags & (1 << 0):
		names.append("rewind_clamped")
	if flags & (1 << 1):
		names.append("claimed_time_out_of_window")
	if flags & (1 << 4):
		names.append("negative_rewind")
	if flags & (1 << 5):
		names.append("missing_history")
	return names


func _aim_kin_flags(flags: int) -> Array[String]:
	var names: Array[String] = []
	if flags & (1 << 0):
		names.append("snapback")
	if flags & (1 << 1):
		names.append("flick_stop_at_fire")
	return names


func _round_vec(value: Variant, digits: int) -> Array[float]:
	return [
		_round_float(float(value[0]), digits),
		_round_float(float(value[1]), digits),
		_round_float(float(value[2]), digits),
	]


func _round_float(value: float, digits: int) -> float:
	var scale := pow(10.0, float(digits))
	return roundf(value * scale) / scale
