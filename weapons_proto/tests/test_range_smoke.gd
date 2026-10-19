extends SceneTree

const RangeScene = preload("res://scenes/range.tscn")
const EvidenceConfig = preload("res://evidence/evidence_config.gd")
const AntiCheatParams = preload("res://anticheat/anticheat_params.gd")

var passed := 0
var failed := 0


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var disabled_range: Node = RangeScene.instantiate()
	root.add_child(disabled_range)
	_check("evidence writer disabled by default", not EvidenceConfig.ENABLE_EVIDENCE_LOG)
	_check(
		"offline review disabled by default",
		not bool(AntiCheatParams.DEFAULTS["ENABLE_ANTICHEAT_REVIEW"])
	)
	_check("default range session starts without an evidence writer", disabled_range._start_session(false))
	_check("default range has no writer", disabled_range._writer == null)
	disabled_range._fire_requested = true
	disabled_range._step_tick(0, false)
	_check("range shot simulation still runs with evidence off", disabled_range._last_result != "EVIDENCE OPEN FAILED")
	_check("range shot does not create evidence writer", disabled_range._writer == null)
	var key_l := InputEventKey.new()
	key_l.pressed = true
	key_l.physical_keycode = KEY_L
	disabled_range._unhandled_input(key_l)
	_check("L reports evidence disabled", disabled_range._verify_status == "EVIDENCE DISABLED")
	var key_k := InputEventKey.new()
	key_k.pressed = true
	key_k.physical_keycode = KEY_K
	disabled_range._unhandled_input(key_k)
	_check("K reports review disabled", disabled_range._review_status == "REVIEW DISABLED")
	disabled_range.free()

	var range_scene: Node = RangeScene.instantiate()
	root.add_child(range_scene)
	_check("range scene instantiates", is_instance_valid(range_scene))

	var first: Dictionary = range_scene.run_smoke()
	_check("first smoke run passes", bool(first.get("ok", false)))
	_check("first run tick count", int(first.get("tick_count", 0)) == 2000)
	_check("first run has 50 rewind decisions", int(first["verification"]["rewind_count"]) == 50)
	_check("first run has exactly five claimed-time rejects", int(first["verification"]["input_reject_reason1_count"]) == 5)
	_check(
		"first run writes AIM_KIN for every SHOT command with records",
		int(first["record_counts"]["aim_kin"]) == int(first["shot_command_count"])
	)
	_check("first run has a hit", int(first["verification"]["hit_count"]) > 0)
	_check("first run has a near miss", int(first["verification"]["near_miss_count"]) > 0)
	_check("first run records server AIM_KIN snapback", bool(first["verification"]["snapback_seen"]))
	_check("first run writes JSONL", FileAccess.file_exists(str(first["jsonl_path"])))
	_check("first run writes review JSON", FileAccess.file_exists(str(first["review_path"])))
	var review_text := FileAccess.get_file_as_string(str(first["review_path"]))
	var review_report: Variant = JSON.parse_string(review_text)
	_check("range review remains review-only", str(review_report.get("auto_action", "")) == "NONE")
	_check("range review confirms evidence chain", bool(review_report.get("evidence_chain_ok", false)))

	var second: Dictionary = range_scene.run_smoke()
	_check("second smoke run passes", bool(second.get("ok", false)))
	_check("smoke evidence is deterministic", str(first["sha256"]) == str(second["sha256"]))

	var project_dir := ProjectSettings.globalize_path("res://")
	var repository_dir := project_dir.path_join("..").simplify_path()
	var python_ref := repository_dir.path_join("tools/fpev_ref.py")
	var evidence_path := ProjectSettings.globalize_path(str(second["evidence_path"]))
	var output: Array = []
	var exit_code := OS.execute(
		"python3",
		PackedStringArray(["-B", python_ref, "verify", "--enable-evidence-log", evidence_path]),
		output,
		true
	)
	if exit_code == 0:
		_check("Python verifies smoke evidence", _join_output(output).strip_edges() == "CHAIN OK")
	else:
		print("Python verifier was unavailable; run: python3 tools/fpev_ref.py verify --enable-evidence-log \"%s\"" % evidence_path)

	print("%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _check(name: String, condition: bool) -> void:
	if condition:
		passed += 1
		print("PASS  %s" % name)
	else:
		failed += 1
		print("FAIL  %s" % name)


func _join_output(output: Array) -> String:
	var lines: Array[String] = []
	for line in output:
		lines.append(str(line))
	return "\n".join(lines)
