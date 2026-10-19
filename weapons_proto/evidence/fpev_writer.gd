class_name FpevWriter
extends RefCounted

const ConfigData = preload("res://evidence/evidence_config.gd")
const Crc32 = preload("res://evidence/crc32.gd")

const RECORD_SHOT := 1
const RECORD_VIS := 2
const RECORD_INPUT_REJECT := 3
const RECORD_CHECKPOINT := 4
const RECORD_REWIND_DECISION := 5
const RECORD_AIM_KIN := 6
const VIS_KEYFRAME := 1 << 0

var _file: FileAccess
var _file_bytes := PackedByteArray()
var _bytes_since_checkpoint := PackedByteArray()
var _previous_chain := PackedByteArray()
var _header_bytes := PackedByteArray()
var _config: Dictionary = {}
var _checkpoint_index := 0
var _records_since_checkpoint := 0
var _last_tick := 0
var _opened := false
var _closed := false


func open(path: String, header_fields: Dictionary, config_overrides: Dictionary = {}) -> bool:
	if _opened or _closed:
		return false
	_config = ConfigData.with_overrides(config_overrides)
	if not bool(_config["ENABLE_EVIDENCE_LOG"]):
		return false
	_header_bytes = _build_header(header_fields)
	if _header_bytes.is_empty():
		return false
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		return false
	_opened = true
	_previous_chain = _sha256(_header_bytes)
	_write_raw(_header_bytes)
	return true


func write_shot(fields: Dictionary, tick: int) -> bool:
	if not _can_write():
		return false
	var body := PackedByteArray()
	_append_u8(body, int(fields["shooter_slot"]))
	_append_u8(body, int(fields["target_slot"]))
	var weapon_id: Variant = fields["weapon_id"]
	var weapon_ids: Dictionary = _config["WEAPON_ID_MAP"]
	var weapon_value := int(weapon_id) if typeof(weapon_id) == TYPE_INT else int(weapon_ids.get(str(weapon_id), 0))
	_append_u8(body, weapon_value)
	_append_u8(body, int(fields["part"]))
	_append_u8(body, int(fields["outcome"]))
	_append_u8(body, int(fields["target_stance"]))
	_append_u16(body, int(fields["shot_index"]))
	_append_vec3f(body, fields["eye_pos"])
	_append_u16(body, int(fields["view_pitch_q"]))
	_append_u16(body, int(fields["view_yaw_q"]))
	_append_f32(body, float(fields["spread_x"]))
	_append_f32(body, float(fields["spread_y"]))
	_append_f32(body, float(fields["kick_up"]))
	_append_f32(body, float(fields["kick_side"]))
	_append_u8(body, int(fields["rewind_ticks"]))
	_append_u8(body, 0)
	_append_u16(body, int(fields["rewind_frac"]))
	_append_f64(body, float(fields["server_time_s"]))
	_append_f64(body, float(fields["client_claimed_time_s"]))
	_append_f32(body, float(fields["closest_dist"]))
	_append_vec3f(body, fields["ray_point"])
	_append_vec3f(body, fields["box_point"])
	_append_vec3f(body, fields["target_origin"])
	_append_f32(body, float(fields["target_yaw"]))
	if body.size() != 104:
		return false
	return _write_crc_record(RECORD_SHOT, int(fields.get("flags", 0)), tick, body)


func write_vis(fields: Dictionary, tick: int) -> bool:
	if not _can_write():
		return false
	var body := PackedByteArray()
	_append_u8(body, int(fields["viewer_slot"]))
	_append_u8(body, 0)
	_append_u16(body, int(fields["sent_mask"]))
	_append_u16(body, int(fields["sound_only_mask"]))
	_append_u16(body, 0)
	return _write_crc_record(
		RECORD_VIS,
		VIS_KEYFRAME if bool(fields.get("keyframe", false)) else 0,
		tick,
		body
	)


func write_input_reject(fields: Dictionary, tick: int) -> bool:
	if not _can_write():
		return false
	var body := PackedByteArray()
	_append_u8(body, int(fields["player_slot"]))
	_append_u8(body, int(fields["reason"]))
	_append_u32(body, int(fields["cmd_seq"]))
	_append_f64(body, float(fields["claimed_time_s"]))
	_append_f64(body, float(fields["expected_time_s"]))
	return _write_crc_record(RECORD_INPUT_REJECT, int(fields.get("flags", 0)), tick, body)


func write_rewind_decision(fields: Dictionary, tick: int) -> bool:
	if not _can_write():
		return false
	var body := PackedByteArray()
	_append_u8(body, int(fields["shooter_slot"]))
	_append_u8(body, int(fields["reason"]))
	_append_u8(body, int(fields["interp_ticks"]))
	_append_u8(body, int(fields["targets_rewound"]))
	_append_u8(body, int(fields["rewind_ticks"]))
	_append_u8(body, int(fields["max_rewind_ticks"]))
	_append_u16(body, int(fields["rewind_frac"]))
	_append_u16(body, int(fields["shot_index"]))
	_append_u16(body, int(fields["rewound_mask"]))
	_append_u32(body, int(fields["cmd_seq"]))
	_append_f64(body, float(fields["claimed_view_tick"]))
	_append_f64(body, float(fields["expected_view_tick"]))
	_append_f64(body, float(fields["chosen_view_tick"]))
	_append_f32(body, float(fields["wanted_rewind_ticks"]))
	_append_f32(body, float(fields["rtt_ms"]))
	_append_u32(body, _checkpoint_index)
	_append_bytes(body, _previous_chain.slice(0, 8))
	if body.size() != 60:
		return false
	return _write_crc_record(RECORD_REWIND_DECISION, int(fields.get("flags", 0)), tick, body)


func write_aim_kin(fields: Dictionary, tick: int) -> bool:
	if not _can_write():
		return false
	if not bool(_config["ENABLE_AIM_KIN"]):
		return false
	var body := PackedByteArray()
	_append_u8(body, int(fields["shooter_slot"]))
	_append_u8(body, int(fields.get("window_ticks", 16)))
	_append_u16(body, int(fields["shot_index"]))
	_append_u8(body, int(fields["move_state"]))
	_append_u8(body, 0)
	for key in [
		"spread_at_fire", "peak_ang_vel_dps", "peak_ang_accel_dps2",
		"fire_tick_delta_deg", "snapback_deg", "snapback_cos", "pre_fire_speed_dps",
	]:
		_append_f32(body, float(fields[key]))
	_append_u8(body, int(fields["settle_ticks"]))
	_append_u8(body, 0)
	if body.size() != 36:
		return false
	return _write_crc_record(RECORD_AIM_KIN, int(fields.get("flags", 0)), tick, body)


func write_shot_result(result: Dictionary, tick: int) -> bool:
	if not _can_write():
		return false
	if result.get("input_reject") != null:
		if not write_input_reject(result["input_reject"], tick):
			return false
	if not write_rewind_decision(result["rewind_decision"], tick):
		return false
	for shot_record in result["records"]:
		if not write_shot(shot_record, tick):
			return false
	return true


func end_tick(tick: int) -> bool:
	if not _can_write():
		return false
	_last_tick = int(tick)
	var interval := int(_config["CHECKPOINT_INTERVAL_TICKS"])
	if interval <= 0:
		return false
	if (int(tick) + 1) % interval == 0:
		return _write_checkpoint(int(tick))
	return true


func close() -> bool:
	if not _can_write():
		return false
	var result := _write_checkpoint(_last_tick)
	_file.flush()
	_file.close()
	_closed = true
	_opened = false
	return result


func bytes() -> PackedByteArray:
	return _file_bytes.duplicate()


func final_chain_sha256() -> PackedByteArray:
	return _previous_chain.duplicate()


func checkpoint_index() -> int:
	return _checkpoint_index


func _can_write() -> bool:
	return _opened and not _closed and _file != null


func _write_crc_record(record_type: int, flags: int, tick: int, body_without_crc: PackedByteArray) -> bool:
	var header := _record_header(record_type, flags, body_without_crc.size() + 4, tick)
	var crc_input := header.duplicate()
	crc_input.append_array(body_without_crc)
	var body := body_without_crc.duplicate()
	_append_u32(body, Crc32.compute(crc_input))
	return _write_non_checkpoint(header, body, tick)


func _write_non_checkpoint(header: PackedByteArray, body: PackedByteArray, tick: int) -> bool:
	var record := header.duplicate()
	record.append_array(body)
	_write_raw(record)
	_bytes_since_checkpoint.append_array(record)
	_records_since_checkpoint += 1
	_last_tick = int(tick)
	return true


func _write_checkpoint(tick: int) -> bool:
	var body_count := PackedByteArray()
	_append_u32(body_count, _records_since_checkpoint)
	var header := _record_header(
		RECORD_CHECKPOINT,
		0,
		36,
		int(tick)
	)
	var hash_input := _previous_chain.duplicate()
	hash_input.append_array(_bytes_since_checkpoint)
	hash_input.append_array(header)
	hash_input.append_array(body_count)
	var chain := _sha256(hash_input)
	var body := body_count.duplicate()
	body.append_array(chain)
	var record := header.duplicate()
	record.append_array(body)
	_write_raw(record)
	_previous_chain = chain
	_bytes_since_checkpoint = PackedByteArray()
	_records_since_checkpoint = 0
	_checkpoint_index += 1
	_last_tick = int(tick)
	return true


func _build_header(fields: Dictionary) -> PackedByteArray:
	var map_name := str(fields.get("map_name", ""))
	var map_bytes := map_name.to_utf8_buffer()
	var slots: Array = fields.get("slots", [])
	if map_bytes.size() > 255 or slots.size() > int(_config["MAX_SLOTS"]):
		return PackedByteArray()
	var match_id := _fixed_bytes(fields.get("match_id", ""), 16)
	var kernel_sha := _fixed_bytes(
		fields.get("kernel_sha256", _config["KERNEL_SHA256_PLACEHOLDER"]),
		32
	)
	var skeleton_sha := _fixed_bytes(fields.get("skeleton_sha256", _config["SKELETON_SHA256"]), 32)
	var build_id := _fixed_bytes(fields.get("build_id", ""), 20)
	if match_id.size() != 16 or kernel_sha.size() != 32 \
			or skeleton_sha.size() != 32 or build_id.size() != 20:
		return PackedByteArray()

	var output := PackedByteArray()
	output.append_array("FPEV".to_ascii_buffer())
	_append_u16(output, int(fields.get("format_version", _config["FORMAT_VERSION"])))
	_append_u16(output, int(fields.get("tick_rate", 128)))
	output.append_array(match_id)
	_append_u64(output, int(fields.get("start_unix_ms", 0)))
	output.append_array(kernel_sha)
	output.append_array(skeleton_sha)
	output.append_array(build_id)
	_append_u8(output, map_bytes.size())
	output.append_array(map_bytes)
	_append_u8(output, slots.size())
	for slot in slots:
		var player_ref := _player_ref(slot, fields)
		if player_ref.size() != 32:
			return PackedByteArray()
		output.append_array(player_ref)
		_append_u8(output, int(slot.get("team", 0)))
	return output


func _player_ref(slot: Dictionary, header_fields: Dictionary) -> PackedByteArray:
	if slot.has("player_ref"):
		return _fixed_bytes(slot["player_ref"], 32)
	if not slot.has("account_id"):
		return PackedByteArray()
	var salt_value: Variant = slot.get("salt", header_fields.get("salt", ""))
	var salt: PackedByteArray
	if typeof(salt_value) == TYPE_STRING:
		salt = str(salt_value).to_utf8_buffer()
	else:
		salt = salt_value
	var player_input := str(slot["account_id"]).to_utf8_buffer()
	player_input.append_array(salt)
	return _sha256(player_input)


func _fixed_bytes(value: Variant, expected_size: int) -> PackedByteArray:
	var result := PackedByteArray()
	if typeof(value) == TYPE_PACKED_BYTE_ARRAY:
		result = value.duplicate()
	elif typeof(value) == TYPE_STRING:
		var hex_string := str(value).replace("-", "").replace(" ", "")
		if hex_string.length() != expected_size * 2:
			return PackedByteArray()
		for offset in range(0, hex_string.length(), 2):
			var high := _hex_nibble(hex_string.unicode_at(offset))
			var low := _hex_nibble(hex_string.unicode_at(offset + 1))
			if high < 0 or low < 0:
				return PackedByteArray()
			result.append((high << 4) | low)
	if result.size() != expected_size:
		return PackedByteArray()
	return result


func _hex_nibble(codepoint: int) -> int:
	if codepoint >= 48 and codepoint <= 57:
		return codepoint - 48
	if codepoint >= 65 and codepoint <= 70:
		return codepoint - 55
	if codepoint >= 97 and codepoint <= 102:
		return codepoint - 87
	return -1


func _record_header(record_type: int, flags: int, body_length: int, tick: int) -> PackedByteArray:
	var header := PackedByteArray()
	_append_u8(header, record_type)
	_append_u8(header, flags)
	_append_u16(header, body_length)
	_append_u32(header, tick)
	return header


func _write_raw(data: PackedByteArray) -> void:
	_file.store_buffer(data)
	_file_bytes.append_array(data)


func _sha256(data: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish()


func _append_vec3f(target: PackedByteArray, value: Variant) -> void:
	for axis in range(3):
		_append_f32(target, float(value[axis]))


func _append_u8(target: PackedByteArray, value: int) -> void:
	target.append(value & 0xFF)


func _append_u16(target: PackedByteArray, value: int) -> void:
	var encoded := PackedByteArray()
	encoded.resize(2)
	encoded.encode_u16(0, value)
	target.append_array(encoded)


func _append_u32(target: PackedByteArray, value: int) -> void:
	var encoded := PackedByteArray()
	encoded.resize(4)
	encoded.encode_u32(0, value)
	target.append_array(encoded)


func _append_u64(target: PackedByteArray, value: int) -> void:
	var encoded := PackedByteArray()
	encoded.resize(8)
	encoded.encode_u64(0, value)
	target.append_array(encoded)


func _append_f32(target: PackedByteArray, value: float) -> void:
	var encoded := PackedByteArray()
	encoded.resize(4)
	encoded.encode_float(0, value)
	target.append_array(encoded)


func _append_f64(target: PackedByteArray, value: float) -> void:
	var encoded := PackedByteArray()
	encoded.resize(8)
	encoded.encode_double(0, value)
	target.append_array(encoded)


func _append_bytes(target: PackedByteArray, data: PackedByteArray) -> void:
	target.append_array(data)
