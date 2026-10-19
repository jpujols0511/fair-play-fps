class_name FpevReader
extends RefCounted

const Crc32 = preload("res://evidence/crc32.gd")
const ConfigData = preload("res://evidence/evidence_config.gd")
const RECORD_SHOT := 1
const RECORD_VIS := 2
const RECORD_INPUT_REJECT := 3
const RECORD_CHECKPOINT := 4
const RECORD_REWIND_DECISION := 5
const RECORD_AIM_KIN := 6
const BODY_LENGTHS := {
	RECORD_SHOT: 108,
	RECORD_VIS: 12,
	RECORD_INPUT_REJECT: 26,
	RECORD_CHECKPOINT: 36,
	RECORD_REWIND_DECISION: 64,
	RECORD_AIM_KIN: 40,
}

var _config: Dictionary = {}


func _init(config_overrides: Dictionary = {}) -> void:
	_config = ConfigData.with_overrides(config_overrides)


func read_file(path: String, expected_final_hash: PackedByteArray = PackedByteArray()) -> Dictionary:
	if not bool(_config["ENABLE_EVIDENCE_LOG"]):
		return _failure(0, 0, "evidence_disabled")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _failure(0, 0, "open_failed")
	var data := file.get_buffer(file.get_length())
	file.close()
	return read_bytes(data, expected_final_hash)


func read_bytes(data: PackedByteArray, expected_final_hash: PackedByteArray = PackedByteArray()) -> Dictionary:
	if not bool(_config["ENABLE_EVIDENCE_LOG"]):
		return _failure(0, 0, "evidence_disabled")
	var errors: Array = []
	var warnings: Array = []
	var records: Array = []
	var header_result := _read_file_header(data)
	if not bool(header_result["ok"]):
		errors.append(header_result["error"])
		return _result(header_result.get("header", {}), records, errors, warnings, PackedByteArray(), 0)
	var header: Dictionary = header_result["header"]
	var header_size := int(header_result["header_size"])
	var previous_chain := _sha256(data.slice(0, header_size))
	var bytes_since_checkpoint := PackedByteArray()
	var records_since_checkpoint := 0
	var checkpoints_seen := 0
	var offset := header_size
	var record_index := 0
	var last_record_type := 0

	while offset < data.size():
		var record_offset := offset
		if data.size() - offset < 8:
			errors.append(_error(offset, record_index, "truncated_record_header"))
			break
		var record_type := int(data[offset])
		var flags := int(data[offset + 1])
		var body_length := int(data.decode_u16(offset + 2))
		var tick := int(data.decode_u32(offset + 4))
		var record_length := 8 + body_length
		if body_length < 0 or record_length > data.size() - offset:
			errors.append(_error(offset, record_index, "truncated_record"))
			break
		var raw_record := data.slice(offset, offset + record_length)
		var expected_length := int(BODY_LENGTHS.get(record_type, -1))
		if expected_length >= 0 and body_length != expected_length:
			errors.append(_error(offset, record_index, "record_length"))
		var fields: Dictionary = {}
		if expected_length >= 0 and body_length == expected_length:
			fields = _decode_fields(record_type, data, offset + 8, body_length)
		else:
			fields = {"raw_body": data.slice(offset + 8, offset + record_length)}

		if _has_crc(record_type) and body_length >= 4:
			var crc_offset := offset + record_length - 4
			var calculated_crc := Crc32.compute(data.slice(offset, crc_offset))
			var stored_crc := int(data.decode_u32(crc_offset))
			fields["crc32"] = stored_crc
			if calculated_crc != stored_crc:
				errors.append(_error(offset, record_index, "crc32"))

		if record_type == RECORD_REWIND_DECISION and expected_length == body_length:
			if int(fields["checkpoint_index"]) != checkpoints_seen \
					or fields["chain_prefix"] != previous_chain.slice(0, 8):
				errors.append(_error(offset, record_index, "rewind_checkpoint_link"))

		if record_type == RECORD_CHECKPOINT and body_length == 36:
			var declared_count := int(fields["record_count"])
			var chain_bytes := previous_chain.duplicate()
			chain_bytes.append_array(bytes_since_checkpoint)
			chain_bytes.append_array(data.slice(offset, offset + 12))
			var calculated_chain := _sha256(chain_bytes)
			if declared_count != records_since_checkpoint:
				errors.append(_error(offset, record_index, "checkpoint_record_count"))
			if calculated_chain != fields["chain_sha256"]:
				errors.append(_error(offset, record_index, "checkpoint_chain"))
			previous_chain = fields["chain_sha256"]
			bytes_since_checkpoint = PackedByteArray()
			records_since_checkpoint = 0
			checkpoints_seen += 1
		else:
			bytes_since_checkpoint.append_array(raw_record)
			records_since_checkpoint += 1
			if expected_length < 0:
				warnings.append({
					"offset": record_offset,
					"record_index": record_index,
					"kind": "unknown_record_type",
					"type": record_type,
				})

		records.append({
			"type": record_type,
			"flags": flags,
			"length": body_length,
			"tick": tick,
			"offset": record_offset,
			"record_index": record_index,
			"fields": fields,
		})
		last_record_type = record_type
		offset += record_length
		record_index += 1

	if last_record_type != RECORD_CHECKPOINT:
		errors.append(_error(data.size(), record_index, "missing_final_checkpoint"))
	if expected_final_hash.size() == 32 and previous_chain != expected_final_hash:
		errors.append(_error(data.size(), record_index, "final_hash_mismatch"))
	return _result(header, records, errors, warnings, previous_chain, checkpoints_seen)


func chain_status(result: Dictionary) -> String:
	if bool(result["ok"]):
		return "CHAIN OK"
	var first: Dictionary = result["first_error"]
	return "CHAIN BROKEN at record %d (offset %d): %s" % [
		int(first["record_index"]),
		int(first["offset"]),
		str(first["kind"]),
	]


func _read_file_header(data: PackedByteArray) -> Dictionary:
	if data.size() < 118:
		return {"ok": false, "error": _error(0, 0, "truncated_file_header")}
	if data.slice(0, 4).get_string_from_ascii() != "FPEV":
		return {"ok": false, "error": _error(0, 0, "bad_magic")}
	var map_length := int(data[116])
	if data.size() < 118 + map_length:
		return {"ok": false, "error": _error(0, 0, "truncated_map_name")}
	var slot_count_offset := 117 + map_length
	var slot_count := int(data[slot_count_offset])
	var header_size := 118 + map_length + slot_count * 33
	if data.size() < header_size:
		return {"ok": false, "error": _error(0, 0, "truncated_slots")}
	var slots: Array = []
	var slot_offset := slot_count_offset + 1
	for slot in range(slot_count):
		slots.append({
			"slot": slot,
			"player_ref": data.slice(slot_offset, slot_offset + 32),
			"team": int(data[slot_offset + 32]),
		})
		slot_offset += 33
	return {
		"ok": true,
		"header_size": header_size,
		"header": {
			"magic": "FPEV",
			"format_version": int(data.decode_u16(4)),
			"tick_rate": int(data.decode_u16(6)),
			"match_id": data.slice(8, 24),
			"start_unix_ms": data.decode_u64(24),
			"kernel_sha256": data.slice(32, 64),
			"skeleton_sha256": data.slice(64, 96),
			"build_id": data.slice(96, 116),
			"map_name": data.slice(117, 117 + map_length).get_string_from_utf8(),
			"slot_count": slot_count,
			"slots": slots,
		},
	}


func _decode_fields(record_type: int, data: PackedByteArray, start: int, _length: int) -> Dictionary:
	match record_type:
		RECORD_SHOT:
			return {
				"shooter_slot": int(data[start]),
				"target_slot": int(data[start + 1]),
				"weapon_id": int(data[start + 2]),
				"part": int(data[start + 3]),
				"outcome": int(data[start + 4]),
				"target_stance": int(data[start + 5]),
				"shot_index": int(data.decode_u16(start + 6)),
				"eye_pos": _read_vec3f(data, start + 8),
				"view_pitch_q": int(data.decode_u16(start + 20)),
				"view_yaw_q": int(data.decode_u16(start + 22)),
				"spread_x": data.decode_float(start + 24),
				"spread_y": data.decode_float(start + 28),
				"kick_up": data.decode_float(start + 32),
				"kick_side": data.decode_float(start + 36),
				"rewind_ticks": int(data[start + 40]),
				"reserved": int(data[start + 41]),
				"rewind_frac": int(data.decode_u16(start + 42)),
				"server_time_s": data.decode_double(start + 44),
				"client_claimed_time_s": data.decode_double(start + 52),
				"closest_dist": data.decode_float(start + 60),
				"ray_point": _read_vec3f(data, start + 64),
				"box_point": _read_vec3f(data, start + 76),
				"target_origin": _read_vec3f(data, start + 88),
				"target_yaw": data.decode_float(start + 100),
				"crc32": int(data.decode_u32(start + 104)),
			}
		RECORD_VIS:
			return {
				"viewer_slot": int(data[start]),
				"reserved": int(data[start + 1]),
				"sent_mask": int(data.decode_u16(start + 2)),
				"sound_only_mask": int(data.decode_u16(start + 4)),
				"reserved2": int(data.decode_u16(start + 6)),
				"crc32": int(data.decode_u32(start + 8)),
			}
		RECORD_INPUT_REJECT:
			return {
				"player_slot": int(data[start]),
				"reason": int(data[start + 1]),
				"cmd_seq": int(data.decode_u32(start + 2)),
				"claimed_time_s": data.decode_double(start + 6),
				"expected_time_s": data.decode_double(start + 14),
				"crc32": int(data.decode_u32(start + 22)),
			}
		RECORD_CHECKPOINT:
			return {
				"record_count": int(data.decode_u32(start)),
				"chain_sha256": data.slice(start + 4, start + 36),
			}
		RECORD_REWIND_DECISION:
			return {
				"shooter_slot": int(data[start]),
				"reason": int(data[start + 1]),
				"interp_ticks": int(data[start + 2]),
				"targets_rewound": int(data[start + 3]),
				"rewind_ticks": int(data[start + 4]),
				"max_rewind_ticks": int(data[start + 5]),
				"rewind_frac": int(data.decode_u16(start + 6)),
				"shot_index": int(data.decode_u16(start + 8)),
				"rewound_mask": int(data.decode_u16(start + 10)),
				"cmd_seq": int(data.decode_u32(start + 12)),
				"claimed_view_tick": data.decode_double(start + 16),
				"expected_view_tick": data.decode_double(start + 24),
				"chosen_view_tick": data.decode_double(start + 32),
				"wanted_rewind_ticks": data.decode_float(start + 40),
				"rtt_ms": data.decode_float(start + 44),
				"checkpoint_index": int(data.decode_u32(start + 48)),
				"chain_prefix": data.slice(start + 52, start + 60),
				"crc32": int(data.decode_u32(start + 60)),
			}
		RECORD_AIM_KIN:
			return {
				"shooter_slot": int(data[start]),
				"window_ticks": int(data[start + 1]),
				"shot_index": int(data.decode_u16(start + 2)),
				"move_state": int(data[start + 4]),
				"reserved": int(data[start + 5]),
				"spread_at_fire": data.decode_float(start + 6),
				"peak_ang_vel_dps": data.decode_float(start + 10),
				"peak_ang_accel_dps2": data.decode_float(start + 14),
				"fire_tick_delta_deg": data.decode_float(start + 18),
				"snapback_deg": data.decode_float(start + 22),
				"snapback_cos": data.decode_float(start + 26),
				"pre_fire_speed_dps": data.decode_float(start + 30),
				"settle_ticks": int(data[start + 34]),
				"reserved2": int(data[start + 35]),
				"crc32": int(data.decode_u32(start + 36)),
			}
	return {}


func _read_vec3f(data: PackedByteArray, offset: int) -> PackedFloat64Array:
	return PackedFloat64Array([
		data.decode_float(offset),
		data.decode_float(offset + 4),
		data.decode_float(offset + 8),
	])


func _has_crc(record_type: int) -> bool:
	return record_type in [
		RECORD_SHOT,
		RECORD_VIS,
		RECORD_INPUT_REJECT,
		RECORD_REWIND_DECISION,
		RECORD_AIM_KIN,
	]


func _sha256(data: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish()


func _error(offset: int, record_index: int, kind: String) -> Dictionary:
	return {"offset": offset, "record_index": record_index, "kind": kind}


func _failure(offset: int, record_index: int, kind: String) -> Dictionary:
	var errors: Array = [_error(offset, record_index, kind)]
	return _result({}, [], errors, [], PackedByteArray(), 0)


func _result(
		header: Dictionary,
		records: Array,
		errors: Array,
		warnings: Array,
		final_chain: PackedByteArray,
		checkpoint_count: int
	) -> Dictionary:
	return {
		"ok": errors.is_empty(),
		"header": header,
		"records": records,
		"errors": errors,
		"first_error": errors[0] if not errors.is_empty() else {},
		"warnings": warnings,
		"final_chain_sha256": final_chain,
		"checkpoint_count": checkpoint_count,
	}
