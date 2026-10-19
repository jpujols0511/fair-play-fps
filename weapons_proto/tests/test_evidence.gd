extends SceneTree

const FpevWriter = preload("res://evidence/fpev_writer.gd")
const FpevCrc32 = preload("res://evidence/crc32.gd")
const EvidenceConfig = preload("res://evidence/evidence_config.gd")
const FpevReader = preload("res://evidence/fpev_reader.gd")
const FpevJsonl = preload("res://evidence/fpev_jsonl.gd")
const FrameAdapter = preload("res://shared/frame.gd")
const InputCommand = preload("res://shared/input_cmd.gd")

const EVIDENCE_ENABLED := {"ENABLE_EVIDENCE_LOG": true}

var passed := 0
var failed := 0


func _init() -> void:
	var info: Dictionary = Engine.get_version_info()
	var version_string := str(info.get("string", "unknown"))
	print("Godot version info: %s" % info)
	if not version_string.begins_with("4.4.1"):
		_fail("version guard expected Godot 4.4.1, got %s" % version_string)

	_test_disabled_by_default()
	_test_crc32()
	_test_record_sizes_and_header()
	_test_aim_kin_switch()
	_test_golden_roundtrip()
	_test_tamper_suite()
	_finish()


func _test_disabled_by_default() -> void:
	_check_bool("evidence ledger disabled by default", EvidenceConfig.ENABLE_EVIDENCE_LOG, false)
	var writer = FpevWriter.new()
	_check_bool(
		"default writer refuses to open",
		writer.open("user://evidence_disabled_default.fpev", _header_fields()),
		false
	)
	var reader = FpevReader.new()
	var read_result: Dictionary = reader.read_bytes(PackedByteArray())
	_check_bool("default reader refuses to read", read_result["ok"], false)
	_check_bool("default reader reports evidence_disabled", read_result["errors"][0]["kind"], "evidence_disabled")
	var read_file_result: Dictionary = reader.read_file("user://evidence_default_off_missing.fpev")
	_check_bool(
		"default reader gates file access before open",
		read_file_result["errors"][0]["kind"],
		"evidence_disabled"
	)
	var export_result: Dictionary = FpevJsonl.new().export_bytes(PackedByteArray())
	_check_bool("default JSONL export is disabled", export_result["ok"], false)
	var project_dir := ProjectSettings.globalize_path("res://")
	var repository_dir := project_dir.path_join("..").simplify_path()
	var python_ref := repository_dir.path_join("tools/fpev_ref.py")
	var golden_path := ProjectSettings.globalize_path("res://tests/golden/match_small.fpev")
	var output: Array = []
	var exit_code := OS.execute(
		"python3",
		PackedStringArray(["-B", python_ref, "verify", golden_path]),
		output,
		true
	)
	_check_bool("Python verifier requires explicit evidence opt-in", exit_code, 2)
	_check_bool(
		"Python verifier explains default-off flag",
		_join_output(output).contains("evidence logging is disabled by default"),
		true
	)


func _test_crc32() -> void:
	var vector := "123456789".to_utf8_buffer()
	_check_int("IEEE CRC-32 test vector", FpevCrc32.compute(vector), 0xCBF43926)


func _test_record_sizes_and_header() -> void:
	var writer = FpevWriter.new()
	var header_fields := _header_fields()
	_check_bool(
		"writer opens fixture file with explicit opt-in",
		writer.open("user://fpev_sizes_test.fpev", header_fields, EVIDENCE_ENABLED),
		true
	)
	var expected_header_size := 118 + "fp_range".to_utf8_buffer().size() + 33 * 2

	_check_bool("SHOT write", writer.write_shot(_shot(), 10), true)
	_check_bool(
		"VIS write",
		writer.write_vis({"viewer_slot": 0, "sent_mask": 0x0002, "sound_only_mask": 0, "keyframe": true}, 10),
		true
	)
	_check_bool(
		"INPUT_REJECT write",
		writer.write_input_reject({
			"player_slot": 0,
			"reason": 1,
			"cmd_seq": 17,
			"claimed_time_s": 7.0,
			"expected_time_s": 7.01,
		}, 10),
		true
	)
	var rewind := {
		"shooter_slot": 0,
		"reason": 1,
		"interp_ticks": 4,
		"targets_rewound": 1,
		"rewind_ticks": 14,
		"max_rewind_ticks": 25,
		"rewind_frac": 15729,
		"shot_index": 18,
		"rewound_mask": 2,
		"cmd_seq": 17,
		"claimed_view_tick": 85.75,
		"expected_view_tick": 85.76,
		"chosen_view_tick": 85.76,
		"wanted_rewind_ticks": 14.24,
		"rtt_ms": 80.0,
		"flags": 2,
	}
	_check_bool("REWIND_DECISION write", writer.write_rewind_decision(rewind, 10), true)
	_check_bool("AIM_KIN write", writer.write_aim_kin(_aim_kin(), 13), true)
	_check_bool("128-tick periodic checkpoint", writer.end_tick(127), true)
	_check_bool("checkpoint index after periodic write", writer.checkpoint_index(), 1)
	_check_bool("final checkpoint close", writer.close(), true)

	var data: PackedByteArray = writer.bytes()
	_check_bool("binary header size", expected_header_size, 192)
	_check_bool("header begins with FPEV", data.slice(0, 4).get_string_from_ascii(), "FPEV")
	_check_bool("header tick rate little-endian", data.decode_u16(6), 128)
	_check_bool("header slot count", data[117 + "fp_range".length()], 2)
	_check_bool("file header byte length", expected_header_size, 192)

	var record_sizes := {}
	var record_offsets := {}
	var offset := expected_header_size
	var record_index := 0
	while offset < data.size():
		var record_type := int(data[offset])
		var body_length := int(data.decode_u16(offset + 2))
		record_sizes[record_type] = int(record_sizes.get(record_type, 0)) + 1
		if not record_offsets.has(record_type):
			record_offsets[record_type] = []
		record_offsets[record_type].append(offset)
		_check_bool(
			"record %d body length" % record_type,
			body_length,
			{1: 108, 2: 12, 3: 26, 4: 36, 5: 64, 6: 40}[record_type]
		)
		if record_type != 4:
			var crc_offset := offset + 8 + body_length - 4
			var crc_expected := FpevCrc32.compute(data.slice(offset, crc_offset))
			_check_int(
				"record %d CRC" % record_type,
				int(data.decode_u32(crc_offset)),
				crc_expected
			)
		offset += 8 + body_length
		record_index += 1
	_check_bool("all six record types emitted", record_sizes.keys().size() >= 6, true)
	_check_bool("two checkpoints emitted", record_sizes[4], 2)
	_check_bool("first checkpoint count excludes itself", data.decode_u32(record_offsets[4][0] + 8), 5)
	_check_bool("final checkpoint count is zero", data.decode_u32(offset - 44 + 8), 0)

	var rewind_offset := int(record_offsets[5][0])
	var header_digest := _sha256(data.slice(0, expected_header_size))
	_check_bool("rewind prefix checkpoint index", data.decode_u32(rewind_offset + 8 + 48), 0)
	_check_bytes(
		"rewind chain prefix starts at header hash",
		data.slice(rewind_offset + 8 + 52, rewind_offset + 8 + 60),
		header_digest.slice(0, 8)
	)
	var reader = FpevReader.new(EVIDENCE_ENABLED)
	var verified: Dictionary = reader.read_bytes(data, writer.final_chain_sha256())
	_check_bool("P6b reader verifies writer output", verified["ok"], true)
	_check_bool("P6b reader reports no errors", verified["errors"].size(), 0)
	_check_bool("P6b reader finds all records", verified["records"].size(), 7)
	_check_bool("P6b reader verifies two checkpoints", verified["checkpoint_count"], 2)
	_check_bool("P6b chain status", reader.chain_status(verified), "CHAIN OK")
	var exported: Dictionary = FpevJsonl.new(EVIDENCE_ENABLED).export_bytes(data, writer.final_chain_sha256())
	_check_bool("JSONL export chain status", exported["status"], "CHAIN OK")
	var json_lines: Array = exported["text"].split("\n", false)
	_check_bool("JSONL has one line per record", json_lines.size(), 7)
	var first_line: Dictionary = JSON.parse_string(json_lines[0])
	_check_bool("JSONL first record type", first_line["type"], "shot")
	_check_bool("JSONL head name", first_line["part"], "head")
	_check_bool("JSONL hit outcome name", first_line["outcome"], "hit")


func _test_aim_kin_switch() -> void:
	var writer = FpevWriter.new()
	_check_bool(
		"AIM_KIN disabled writer opens",
		writer.open(
			"user://fpev_no_aim_kin_test.fpev",
			_header_fields(),
			{"ENABLE_EVIDENCE_LOG": true, "ENABLE_AIM_KIN": false}
		),
		true
	)
	_check_bool("J19 AIM_KIN disabled", writer.write_aim_kin(_aim_kin(), 3), false)
	_check_bool("disabled AIM_KIN leaves writer usable", writer.write_vis({
		"viewer_slot": 0, "sent_mask": 2, "sound_only_mask": 0,
	}, 4), true)
	_check_bool("disabled AIM_KIN writer closes", writer.close(), true)
	_check_bool("J19 proposed default is enabled when ledger is opted in", EvidenceConfig.ENABLE_AIM_KIN, true)
	_check_bool("proposed checkpoint cadence", EvidenceConfig.CHECKPOINT_INTERVAL_TICKS, 128)
	_check_bool("retention decision proposal", EvidenceConfig.RETENTION_DAYS, 90)


func _test_golden_roundtrip() -> void:
	var fixture_file := FileAccess.open("res://tests/golden/match_small.json", FileAccess.READ)
	if fixture_file == null:
		_fail("cannot open tests/golden/match_small.json")
		return
	var fixture_variant: Variant = JSON.parse_string(fixture_file.get_as_text())
	if typeof(fixture_variant) != TYPE_DICTIONARY:
		_fail("match_small.json is not a JSON object")
		return
	var fixture: Dictionary = fixture_variant
	var godot_bytes := _build_match_bytes(fixture, "user://match_small_gd.fpev")
	_check_bool("GDScript golden writer produced bytes", godot_bytes.size() > 0, true)
	var golden_bytes := FileAccess.get_file_as_bytes("res://tests/golden/match_small.fpev")
	_check_byte_match("GDScript writer matches Python golden bytes", godot_bytes, golden_bytes)
	var expected_final := _hex_bytes(str(fixture["expected_final_chain_sha256"]))
	var reader = FpevReader.new(EVIDENCE_ENABLED)
	var verified: Dictionary = reader.read_bytes(golden_bytes, expected_final)
	if not bool(verified["ok"]):
		print("P6c GDScript reader errors: %s" % JSON.stringify(verified["errors"]))
	_check_bool("Python golden passes GDScript reader", verified["ok"], true)
	_check_bool("golden has at least three checkpoints", int(verified["checkpoint_count"]) >= 3, true)
	_check_bool("golden has 108 records", verified["records"].size(), 108)

	var jsonl: Dictionary = FpevJsonl.new(EVIDENCE_ENABLED).export_bytes(golden_bytes, expected_final)
	var expected_jsonl := FileAccess.get_file_as_string("res://tests/golden/match_small.jsonl")
	_check_bool("GDScript exporter chain status", jsonl["status"], "CHAIN OK")
	_check_string_match("GDScript JSONL matches golden", jsonl["text"], expected_jsonl)
	var first_shot_fields: Dictionary = {}
	for record in verified["records"]:
		if int(record["type"]) == FpevWriter.RECORD_SHOT:
			first_shot_fields = record["fields"]
			break
	var first_shot_json: Dictionary = {}
	for line in str(jsonl["text"]).split("\n", false):
		var row: Variant = JSON.parse_string(line)
		if typeof(row) == TYPE_DICTIONARY and str(row.get("type", "")) == "shot":
			first_shot_json = row
			break
	var expected_pitch := FrameAdapter.pitch_to_spec_deg(
		InputCommand.dequantize_pitch(int(first_shot_fields["view_pitch_q"]))
	)
	var expected_yaw := FrameAdapter.yaw_to_spec_deg(
		InputCommand.dequantize_yaw(int(first_shot_fields["view_yaw_q"]))
	)
	_check_bool(
		"JSONL pitch uses InputCmd/Frame spec conversion",
		float(first_shot_json["view"]["pitch"]),
		roundf(expected_pitch * 1000000.0) / 1000000.0
	)
	_check_bool(
		"JSONL yaw uses InputCmd/Frame spec conversion",
		float(first_shot_json["view"]["yaw"]),
		roundf(expected_yaw * 1000000.0) / 1000000.0
	)
	_check_bool("match_small first shot pitch q is zero", int(first_shot_fields["view_pitch_q"]), 0)
	_check_bool("match_small first shot yaw q is zero", int(first_shot_fields["view_yaw_q"]), 0)
	_check_bool("match_small q=0 pitch is 90 spec degrees", float(first_shot_json["view"]["pitch"]), 90.0)
	_check_bool("match_small q=0 yaw is 90 spec degrees", float(first_shot_json["view"]["yaw"]), 90.0)

	var project_dir := ProjectSettings.globalize_path("res://")
	var repository_dir := project_dir.path_join("..").simplify_path()
	var python_ref := repository_dir.path_join("tools/fpev_ref.py")
	var fixture_path := ProjectSettings.globalize_path("res://tests/golden/match_small.json")
	var gd_path := ProjectSettings.globalize_path("user://match_small_gd.fpev")
	var py_path := ProjectSettings.globalize_path("user://match_small_python.fpev")
	var py_jsonl_path := ProjectSettings.globalize_path("user://match_small_python.jsonl")
	var output_file := FileAccess.open("user://match_small_gd.fpev", FileAccess.WRITE)
	if output_file == null:
		_fail("cannot write temporary GDScript match file")
		return
	output_file.store_buffer(godot_bytes)
	output_file.close()

	var command_output: Array = []
	var exit_code := OS.execute(
		"python3",
		PackedStringArray([python_ref, "write", "--enable-evidence-log", fixture_path, py_path]),
		command_output,
		true
	)
	_check_bool("Python writer exits successfully", exit_code, 0)
	if exit_code == 0:
		var python_bytes := FileAccess.get_file_as_bytes("user://match_small_python.fpev")
		_check_byte_match("Python writer matches GDScript bytes", python_bytes, godot_bytes)

	command_output.clear()
	exit_code = OS.execute(
		"python3",
		PackedStringArray([
			python_ref, "verify", "--enable-evidence-log", gd_path,
			"--expected-final-hash", str(fixture["expected_final_chain_sha256"]),
		]),
		command_output,
		true
	)
	_check_bool("Python reader accepts GDScript output", exit_code, 0)
	_check_bool("Python reader reports CHAIN OK", _join_output(command_output).strip_edges(), "CHAIN OK")

	command_output.clear()
	exit_code = OS.execute(
		"python3",
		PackedStringArray([
			python_ref, "export", "--enable-evidence-log", gd_path,
			"--quiet",
			"--expected-final-hash", str(fixture["expected_final_chain_sha256"]),
			"--jsonl-out", py_jsonl_path,
		]),
		command_output,
		true
	)
	_check_bool("Python export exits successfully", exit_code, 0)
	if exit_code == 0:
		_check_bool(
			"Python and GDScript JSONL are identical",
			FileAccess.get_file_as_string("user://match_small_python.jsonl") == jsonl["text"],
			true
		)


func _build_match_bytes(
		fixture: Dictionary,
		path: String,
		header_override: Dictionary = {}
	) -> PackedByteArray:
	var writer = FpevWriter.new()
	var header: Dictionary = header_override if not header_override.is_empty() else fixture["header"]
	if not writer.open(path, header, EVIDENCE_ENABLED):
		return PackedByteArray()
	var events_by_tick := {}
	for event in fixture["events"]:
		var write_tick := int(event.get("write_tick", event["tick"]))
		if not events_by_tick.has(write_tick):
			events_by_tick[write_tick] = []
		events_by_tick[write_tick].append(event)
	for tick in range(int(fixture["final_tick"]) + 1):
		for event in events_by_tick.get(tick, []):
			var fields: Dictionary = event["fields"]
			var written := false
			match str(event["kind"]):
				"shot":
					written = writer.write_shot(fields, int(event["tick"]))
				"vis":
					written = writer.write_vis(fields, int(event["tick"]))
				"input_reject":
					written = writer.write_input_reject(fields, int(event["tick"]))
				"rewind_decision":
					written = writer.write_rewind_decision(fields, int(event["tick"]))
				"aim_kin":
					written = writer.write_aim_kin(fields, int(event["tick"]))
				_:
					return PackedByteArray()
			if not written:
				return PackedByteArray()
		if not writer.end_tick(tick):
			return PackedByteArray()
	if not writer.close():
		return PackedByteArray()
	return writer.bytes()


func _test_tamper_suite() -> void:
	var file := FileAccess.open("res://tests/golden/match_small.json", FileAccess.READ)
	if file == null:
		_fail("cannot open golden fixture for tamper tests")
		return
	var fixture: Dictionary = JSON.parse_string(file.get_as_text())
	var original := FileAccess.get_file_as_bytes("res://tests/golden/match_small.fpev")
	var expected_final := _hex_bytes(str(fixture["expected_final_chain_sha256"]))
	var baseline: Dictionary = FpevReader.new(EVIDENCE_ENABLED).read_bytes(original, expected_final)
	if not bool(baseline["ok"]):
		_fail("golden fixture must verify before tampering: %s" % JSON.stringify(baseline["errors"]))
		return
	var mutations := _tampered_copies(original, baseline["records"], fixture)

	var project_dir := ProjectSettings.globalize_path("res://")
	var repository_dir := project_dir.path_join("..").simplify_path()
	var python_ref := repository_dir.path_join("tools/fpev_ref.py")
	var golden_path := ProjectSettings.globalize_path("res://tests/golden/match_small.fpev")
	var fixture_path := ProjectSettings.globalize_path("res://tests/golden/match_small.json")
	var python_output: Array = []
	var exit_code := OS.execute(
		"python3",
		PackedStringArray([
			python_ref, "tamper-test", "--enable-evidence-log", golden_path, "--fixture", fixture_path,
			"--expected-final-hash", str(fixture["expected_final_chain_sha256"]),
		]),
		python_output,
		true
	)
	_check_bool("Python tamper suite exits successfully", exit_code, 0)
	var python_result: Variant = JSON.parse_string(_join_output(python_output))
	if typeof(python_result) != TYPE_DICTIONARY:
		_fail("Python tamper suite did not return JSON")
		return
	var python_cases: Array = python_result["cases"]
	_check_bool("both tamper readers cover all cases", python_cases.size(), mutations.size())
	var python_by_name := {}
	for python_case in python_cases:
		python_by_name[str(python_case["name"])] = python_case

	var reader = FpevReader.new(EVIDENCE_ENABLED)
	for name in mutations:
		var tampered: PackedByteArray = mutations[name]
		var gd_result: Dictionary = reader.read_bytes(tampered, expected_final)
		var py_case: Dictionary = python_by_name[name]
		var matches := (
			not bool(gd_result["ok"])
			and not bool(py_case["ok"])
			and _error_signature(gd_result["errors"]) == _error_signature(py_case["errors"])
		)
		_check_bool(
			"tamper %s detected identically by both readers (record %d)"
			% [name, int(gd_result["first_error"].get("record_index", -1))],
			matches,
			true
		)
		var got_kinds := _error_kinds(gd_result["errors"])
		for required_kind in _required_tamper_errors(name):
			_check_bool(
				"tamper %s reports %s" % [name, required_kind],
				got_kinds.has(required_kind),
				true
			)


func _tampered_copies(
		original: PackedByteArray,
		records: Array,
		fixture: Dictionary
	) -> Dictionary:
	var shot := _find_record(records, 1)
	var vis := _find_record(records, 2)
	var input_reject := _find_record(records, 3)
	var rewind := _find_record(records, 5)
	var aim_kin := _find_record(records, 6)
	var checkpoints: Array = []
	var shots_before_first_checkpoint: Array = []
	for record in records:
		if int(record["type"]) == 4:
			checkpoints.append(record)
		elif not checkpoints.is_empty():
			pass
		if int(record["type"]) == 1 and (
				checkpoints.is_empty()
				or int(record["offset"]) < int(checkpoints[0]["offset"])
			):
			shots_before_first_checkpoint.append(record)
	var first_checkpoint: Dictionary = checkpoints[0]
	var final_checkpoint: Dictionary = checkpoints[-1]
	var first_shot_bytes: int = int(shot["offset"])
	var first_shot_length := 8 + int(shot["length"])
	var crc_offset := first_shot_bytes + first_shot_length - 1

	var result := {
		"shot_body": _flip_byte(original, int(shot["offset"]) + 8 + 24),
		"vis_body": _flip_byte(original, int(vis["offset"]) + 8 + 2),
		"input_reject_body": _flip_byte(original, int(input_reject["offset"]) + 8 + 2),
		"rewind_body": _flip_byte(original, int(rewind["offset"]) + 8 + 12),
		"aim_kin_body": _flip_byte(original, int(aim_kin["offset"]) + 8 + 6),
		"shot_crc": _flip_byte(original, crc_offset),
		"checkpoint_record_count": _flip_byte(original, int(first_checkpoint["offset"]) + 8),
		"delete_record": _remove_record(original, vis),
		"truncate_final_interval": original.slice(0, int(final_checkpoint["offset"])),
		"file_header": _flip_byte(original, 32),
	}

	var first_a: Dictionary = shots_before_first_checkpoint[0]
	var first_b: Dictionary = shots_before_first_checkpoint[1]
	result["swap_records"] = _swap_records(original, first_a, first_b)

	var rewind_before_checkpoint: Dictionary = _find_before(
		records, 5, int(first_checkpoint["offset"])
	)
	result["move_rewind_interval"] = _move_after_checkpoint(
		original,
		rewind_before_checkpoint,
		first_checkpoint
	)

	var alternate_header: Dictionary = fixture["header"].duplicate(true)
	alternate_header["start_unix_ms"] = int(alternate_header["start_unix_ms"]) + 1
	result["replace_with_other_valid_match"] = _build_match_bytes(
		fixture,
		"user://match_small_alternate.fpev",
		alternate_header
	)
	return result


func _find_record(records: Array, record_type: int) -> Dictionary:
	for record in records:
		if int(record["type"]) == record_type:
			return record
	return {}


func _find_before(records: Array, record_type: int, before_offset: int) -> Dictionary:
	for record in records:
		if int(record["type"]) == record_type and int(record["offset"]) < before_offset:
			return record
	return {}


func _flip_byte(source: PackedByteArray, offset: int) -> PackedByteArray:
	var result := source.duplicate()
	result[offset] = int(result[offset]) ^ 1
	return result


func _remove_record(source: PackedByteArray, record: Dictionary) -> PackedByteArray:
	var start := int(record["offset"])
	var end := start + 8 + int(record["length"])
	var result := source.slice(0, start)
	result.append_array(source.slice(end, source.size()))
	return result


func _swap_records(source: PackedByteArray, a: Dictionary, b: Dictionary) -> PackedByteArray:
	var a_start := int(a["offset"])
	var a_end := a_start + 8 + int(a["length"])
	var b_start := int(b["offset"])
	var b_end := b_start + 8 + int(b["length"])
	if b_start < a_start:
		var swap_record := a
		a = b
		b = swap_record
		var swap_start := a_start
		a_start = b_start
		b_start = swap_start
		var swap_end := a_end
		a_end = b_end
		b_end = swap_end
	var result := source.slice(0, a_start)
	result.append_array(source.slice(b_start, b_end))
	result.append_array(source.slice(a_end, b_start))
	result.append_array(source.slice(a_start, a_end))
	result.append_array(source.slice(b_end, source.size()))
	return result


func _move_after_checkpoint(
		source: PackedByteArray,
		record: Dictionary,
		checkpoint: Dictionary
	) -> PackedByteArray:
	var record_bytes := source.slice(
		int(record["offset"]),
		int(record["offset"]) + 8 + int(record["length"])
	)
	var removed := _remove_record(source, record)
	var shifted_checkpoint := int(checkpoint["offset"]) - record_bytes.size()
	var insert_at := shifted_checkpoint + 8 + int(checkpoint["length"])
	var result := removed.slice(0, insert_at)
	result.append_array(record_bytes)
	result.append_array(removed.slice(insert_at, removed.size()))
	return result


func _error_signature(errors: Array) -> Array[String]:
	var signature: Array[String] = []
	for error in errors:
		signature.append(
			"%s:%d:%d"
			% [str(error["kind"]), int(error["record_index"]), int(error["offset"])]
		)
	return signature


func _error_kinds(errors: Array) -> Array[String]:
	var kinds: Array[String] = []
	for error in errors:
		var kind := str(error["kind"])
		if not kinds.has(kind):
			kinds.append(kind)
	return kinds


func _required_tamper_errors(name: String) -> Array[String]:
	if name in ["shot_body", "vis_body", "input_reject_body", "rewind_body", "aim_kin_body", "shot_crc"]:
		return ["crc32", "checkpoint_chain"]
	if name in ["checkpoint_record_count", "delete_record"]:
		return ["checkpoint_record_count", "checkpoint_chain"]
	if name == "swap_records":
		return ["checkpoint_chain"]
	if name == "move_rewind_interval":
		return ["checkpoint_chain", "rewind_checkpoint_link"]
	if name == "truncate_final_interval":
		return ["missing_final_checkpoint"]
	if name == "replace_with_other_valid_match":
		return ["final_hash_mismatch"]
	return ["checkpoint_chain"]


func _header_fields() -> Dictionary:
	return {
		"match_id": "6f1c2b0e-8a43-4d7e-9c1a-2f0b9d3e5a71",
		"tick_rate": 128,
		"start_unix_ms": 1792000000000,
		"kernel_sha256": EvidenceConfig.KERNEL_SHA256_PLACEHOLDER,
		"skeleton_sha256": EvidenceConfig.SKELETON_SHA256,
		"build_id": "1111111111111111111111111111111111111111",
		"map_name": "fp_range",
		"salt": "fixture-salt",
		"slots": [
			{"account_id": "test-account-0", "team": 1},
			{"account_id": "test-account-1", "team": 2},
		],
	}


func _shot() -> Dictionary:
	return {
		"shooter_slot": 0,
		"target_slot": 1,
		"weapon_id": "AK47",
		"part": 0,
		"outcome": 0,
		"target_stance": 0,
		"shot_index": 18,
		"eye_pos": PackedFloat64Array([0.0, 0.0, 64.0]),
		"view_pitch_q": 0,
		"view_yaw_q": 0,
		"spread_x": 0.001,
		"spread_y": -0.002,
		"kick_up": 1.0,
		"kick_side": 0.25,
		"rewind_ticks": 14,
		"rewind_frac": 15729,
		"server_time_s": 85.76,
		"client_claimed_time_s": 85.75,
		"closest_dist": 0.0,
		"ray_point": PackedFloat64Array([496.0, 0.0, 64.0]),
		"box_point": PackedFloat64Array([496.0, 0.0, 64.0]),
		"target_origin": PackedFloat64Array([500.0, 0.0, 0.0]),
		"target_yaw": 180.0,
		"flags": 2,
	}


func _aim_kin() -> Dictionary:
	return {
		"shooter_slot": 0,
		"window_ticks": 16,
		"shot_index": 18,
		"move_state": 0,
		"spread_at_fire": 0.2,
		"peak_ang_vel_dps": 12.0,
		"peak_ang_accel_dps2": 1500.0,
		"fire_tick_delta_deg": 0.1,
		"snapback_deg": 0.0,
		"snapback_cos": 0.0,
		"pre_fire_speed_dps": 3.0,
		"settle_ticks": 2,
		"flags": 0,
	}


func _sha256(data: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish()


func _hex_bytes(hex_string: String) -> PackedByteArray:
	var output := PackedByteArray()
	for offset in range(0, hex_string.length(), 2):
		var high := _hex_nibble(hex_string.unicode_at(offset))
		var low := _hex_nibble(hex_string.unicode_at(offset + 1))
		output.append((high << 4) | low)
	return output


func _hex_nibble(codepoint: int) -> int:
	if codepoint >= 48 and codepoint <= 57:
		return codepoint - 48
	if codepoint >= 97 and codepoint <= 102:
		return codepoint - 87
	if codepoint >= 65 and codepoint <= 70:
		return codepoint - 55
	return -1


func _join_output(output: Array) -> String:
	var text := ""
	for part in output:
		text += str(part)
	return text


func _check_int(name: String, got: int, want: int) -> void:
	if got == want:
		passed += 1
		print("PASS  %s  got %d want %d" % [name, got, want])
	else:
		_fail("%s got %d want %d" % [name, got, want])


func _check_bytes(name: String, got: PackedByteArray, want: PackedByteArray) -> void:
	if got == want:
		passed += 1
		print("PASS  %s  %s" % [name, got.hex_encode()])
	else:
		_fail("%s got %s want %s" % [name, got.hex_encode(), want.hex_encode()])


func _check_byte_match(name: String, got: PackedByteArray, want: PackedByteArray) -> void:
	if got == want:
		passed += 1
		print("PASS  %s  %d bytes sha256=%s" % [name, got.size(), _sha256(got).hex_encode()])
	else:
		var first_difference := -1
		for index in range(mini(got.size(), want.size())):
			if got[index] != want[index]:
				first_difference = index
				break
		_fail(
			"%s size %d/%d first differing offset %d"
			% [name, got.size(), want.size(), first_difference]
		)


func _check_string_match(name: String, got: String, want: String) -> void:
	if got == want:
		passed += 1
		print("PASS  %s  %d chars sha256=%s" % [
			name,
			got.length(),
			_sha256(got.to_utf8_buffer()).hex_encode(),
		])
	else:
		_fail("%s length %d want %d" % [name, got.length(), want.length()])


func _check_bool(name: String, got: Variant, want: Variant) -> void:
	if got == want:
		passed += 1
		print("PASS  %s  got %s want %s" % [name, str(got), str(want)])
	else:
		_fail("%s got %s want %s" % [name, str(got), str(want)])


func _fail(message: String) -> void:
	failed += 1
	print("FAIL  %s" % message)


func _finish() -> void:
	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
