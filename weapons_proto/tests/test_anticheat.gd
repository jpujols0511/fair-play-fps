extends SceneTree

const AimKinLogic = preload("res://anticheat/aim_kin.gd")
const AntiCheatParams = preload("res://anticheat/anticheat_params.gd")
const ViewValidator = preload("res://anticheat/view_validator.gd")
const UnsentAnalyzer = preload("res://anticheat/unsent_aim_analyzer.gd")
const ReviewQueue = preload("res://anticheat/review_queue.gd")
const HitboxBuilder = preload("res://hitreg/hitboxes.gd")
const FpevReader = preload("res://evidence/fpev_reader.gd")
const ScriptedPath = preload("res://tests/scripted_path.gd")
const FrameAdapter = preload("res://shared/frame.gd")
const InputCommand = preload("res://shared/input_cmd.gd")

const EVIDENCE_ENABLED := {"ENABLE_EVIDENCE_LOG": true}
const REVIEW_ENABLED := {"ENABLE_ANTICHEAT_REVIEW": true}
const ANGLE_Q_STEP_DEG := 360.0 / 65536.0

var passed := 0
var failed := 0


func _init() -> void:
	var version: Dictionary = Engine.get_version_info()
	print("Godot version info: %s" % version)
	if not str(version.get("string", "unknown")).begins_with("4.4.1"):
		_fail("version guard expected Godot 4.4.1")

	_test_aim_kin_math()
	_test_aim_kin_false_positives()
	_test_view_validator()
	_test_analyzer_disabled_by_default()
	_test_server_selected_surf_profile()
	_test_unsent_episode_thresholds()
	_test_drop_rules()
	_test_tracking_correlation()
	_test_unsent_shot_thresholds()
	_test_aim_kin_review_threshold()
	_test_review_queue_guards()
	_test_source_language_guard()
	_test_golden_review_json()
	_finish()


func _test_analyzer_disabled_by_default() -> void:
	_check_bool(
		"offline anti-cheat review disabled by default",
		AntiCheatParams.DEFAULTS["ENABLE_ANTICHEAT_REVIEW"],
		false
	)
	var timeline := _make_simple_timeline(0, 31, 0.0, 0.0)
	var evidence := _evidence({0: 1, 1: 2}, [_vis(0, 0, 0, 0)])
	var report := UnsentAnalyzer.analyze("disabled", timeline, evidence)
	_check_bool("default analyzer reports disabled", report.get("disabled", false), true)
	_check_bool("default analyzer keeps auto action NONE", report["auto_action"], "NONE")
	_check_bool("default analyzer produces no status rows", report["players"].size(), 0)
	var write_result := ReviewQueue.write_report("user://review_disabled.flags.json", report)
	_check_bool("default review writer refuses output", write_result["errors"][0], "review_disabled")
	var repository_dir := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var python_ref := repository_dir.path_join("tools/anticheat_ref.py")
	var fixture_path := ProjectSettings.globalize_path(
		"res://tests/fixtures/anticheat_match.timeline.json"
	)
	var output: Array = []
	var exit_code := OS.execute(
		"python3",
		PackedStringArray(["-B", python_ref, fixture_path]),
		output,
		true
	)
	_check_bool("Python offline review requires explicit opt-in", exit_code, 2)
	_check_bool(
		"Python offline review explains default-off flags",
		_join_output(output).contains("offline review is disabled by default"),
		true
	)


func _test_server_selected_surf_profile() -> void:
	var timeline := _make_simple_timeline(0, 1, 0.0, 0.0)
	timeline[0]["players"][0]["aim_kin_profile"] = "surf"
	var evidence := _evidence({0: 1, 1: 2}, [_vis(0, 0, 0, 0)])
	var default_report := UnsentAnalyzer.analyze(
		"default-profile", timeline, evidence, [], REVIEW_ENABLED
	)
	var surf_report := UnsentAnalyzer.analyze(
		"surf-profile", timeline, evidence, [], REVIEW_ENABLED, {"mode": "surf"}
	)
	var forged_profile := UnsentAnalyzer.analyze(
		"client-profile-ignored",
		timeline,
		evidence,
		[],
		{"ENABLE_ANTICHEAT_REVIEW": true, "AIM_KIN_PROFILE": "surf"},
		{"mode": "default"}
	)
	_check_bool("unspecified match uses default AIM_KIN profile", default_report["params"]["AIM_KIN_PROFILE"], "default")
	_check_bool("server surf metadata selects surf AIM_KIN profile", surf_report["params"]["AIM_KIN_PROFILE"], "surf")
	_check_bool("client cannot select AIM_KIN profile", forged_profile["params"]["AIM_KIN_PROFILE"], "default")


func _test_aim_kin_math() -> void:
	var constant := _constant_commands(0, 20, 100.0)
	var result := AimKinLogic.compute(constant, 16, 0.2, 0, 1)
	_check_float("AIM_KIN constant delta within wire angle step", result["fire_tick_delta_deg"], 0.78125, ANGLE_Q_STEP_DEG)
	_check_float("AIM_KIN constant speed within wire angle step", result["peak_ang_vel_dps"], 100.0, ANGLE_Q_STEP_DEG * AimKinLogic.TICK_RATE)
	_check_float(
		"AIM_KIN constant acceleration bounded by quantization",
		result["peak_ang_accel_dps2"],
		0.0,
		ANGLE_Q_STEP_DEG * AimKinLogic.TICK_RATE * AimKinLogic.TICK_RATE
	)
	_check_bool("AIM_KIN constant turn never settles", result["settle_ticks"], 255)
	_check_bool("AIM_KIN constant turn has no flags", result["flags"], 0)

	var quantized := _constant_commands(0, 20, 100.0, true)
	var quantized_result := AimKinLogic.compute(quantized, 16, 0.2, 0, 2)
	_check_float(
		"AIM_KIN 16-bit speed within angle noise",
		quantized_result["peak_ang_vel_dps"],
		100.0,
		ANGLE_Q_STEP_DEG * AimKinLogic.TICK_RATE
	)

	var snap_yaws := []
	for tick in range(20):
		snap_yaws.append(5.0 if tick == 16 else 0.0)
	var snap := AimKinLogic.compute(_commands_from_yaws(snap_yaws), 16, 0.2, 0, 3)
	_check_float("AIM_KIN fire-tick jump", snap["fire_tick_delta_deg"], 5.0, ANGLE_Q_STEP_DEG)
	_check_float("AIM_KIN snapback distance", snap["snapback_deg"], 5.0, ANGLE_Q_STEP_DEG)
	_check_float("AIM_KIN snapback cosine", snap["snapback_cos"], -1.0, 1e-9)
	_check_bool("AIM_KIN SNAPBACK flag", int(snap["flags"]) & 1, 1)

	var flick_yaws := []
	for tick in range(20):
		flick_yaws.append(20.0 if tick >= 16 else 0.0)
	var flick := AimKinLogic.compute(_commands_from_yaws(flick_yaws), 16, 0.2, 0, 4)
	_check_float(
		"AIM_KIN flick acceleration within wire noise",
		flick["peak_ang_accel_dps2"],
		327680.0,
		ANGLE_Q_STEP_DEG * AimKinLogic.TICK_RATE * AimKinLogic.TICK_RATE
	)
	_check_bool("AIM_KIN flick settles in one tick", flick["settle_ticks"], 1)
	_check_bool("AIM_KIN FLICK_STOP_AT_FIRE flag", int(flick["flags"]) & 2, 2)
	_check_bool("AIM_KIN flick is not snapback", int(flick["flags"]) & 1, 0)

	var wrap_yaws := []
	for tick in range(20):
		wrap_yaws.append(0.5 if tick >= 16 else 359.5)
	var wrap := AimKinLogic.compute(_commands_from_yaws(wrap_yaws), 16, 0.2, 0, 5)
	_check_float("AIM_KIN yaw wrap is one degree", wrap["fire_tick_delta_deg"], 1.0, ANGLE_Q_STEP_DEG)
	_check_bool("AIM_KIN yaw wrap is not a flick stop", int(wrap["flags"]) & 2, 0)

	var reset_commands := _commands_from_yaws(snap_yaws)
	reset_commands[15]["teleported"] = true
	var reset_result := AimKinLogic.compute(reset_commands, 16, 0.2, 0, 6)
	_check_bool("AIM_KIN excludes reset window", reset_result["excluded"], true)
	_check_bool("AIM_KIN reset has no flags", reset_result["flags"], 0)

	var repeat_commands := _commands_from_yaws(snap_yaws)
	repeat_commands[16]["repeated"] = true
	var repeat_result := AimKinLogic.compute(repeat_commands, 16, 0.2, 0, 7)
	_check_bool("AIM_KIN repeated fire tick has no snap", repeat_result["flags"], 0)
	var dead_commands := _commands_from_yaws(snap_yaws)
	dead_commands[16]["alive"] = false
	var dead_result := AimKinLogic.compute(dead_commands, 16, 0.2, 0, 8)
	_check_bool("AIM_KIN dead player is excluded", dead_result["excluded"], true)

	var out_of_order := constant.duplicate(true)
	out_of_order.reverse()
	var ordered_result := AimKinLogic.compute(out_of_order, 16, 0.2, 0, 1)
	_check_float("AIM_KIN orders by cmd_seq", ordered_result["peak_ang_vel_dps"], result["peak_ang_vel_dps"], 1e-9)


func _test_aim_kin_false_positives() -> void:
	var human_yaws: Array = []
	for tick in range(40):
		if tick < 20:
			human_yaws.append(0.0)
		elif tick <= 25:
			human_yaws.append([5.0, 20.0, 45.0, 70.0, 85.0, 90.0][tick - 20])
		elif tick == 26:
			human_yaws.append(93.0)
		elif tick <= 30:
			human_yaws.append(93.0 - float(tick - 26) * 0.75)
		else:
			human_yaws.append(90.0)
	var human_flick := AimKinLogic.compute(_commands_from_yaws(human_yaws), 26, 0.2, 0, 10)
	_check_bool("AIM_KIN human flick with overshoot is unflagged", human_flick["flags"], 0)
	var delayed_arrival := _commands_from_yaws(human_yaws)
	delayed_arrival.reverse()
	var delayed_flick := AimKinLogic.compute(delayed_arrival, 26, 0.2, 0, 10)
	_check_bool("AIM_KIN 150ms out-of-order arrival preserves result", delayed_flick["flags"], human_flick["flags"])

	var transfer_yaws: Array = []
	for tick in range(40):
		transfer_yaws.append(float(maxi(0, tick - 8)) * 1.2)
	var transfer := AimKinLogic.compute(_commands_from_yaws(transfer_yaws), 30, 0.2, 0, 11)
	_check_bool("AIM_KIN spray transfer is unflagged", transfer["flags"], 0)

	var slow_yaws: Array = []
	for tick in range(40):
		slow_yaws.append(float(tick) * 0.2)
	var slow := AimKinLogic.compute(_commands_from_yaws(slow_yaws), 30, 0.2, 0, 12)
	_check_bool("AIM_KIN slow precise adjustment is unflagged", slow["flags"], 0)

	var settle_yaws: Array = []
	for tick in range(40):
		if tick < 20:
			settle_yaws.append(0.0)
		elif tick == 20:
			settle_yaws.append(20.0)
		elif tick == 21:
			settle_yaws.append(30.0)
		else:
			settle_yaws.append(30.0)
	var three_tick_settle := AimKinLogic.compute(_commands_from_yaws(settle_yaws), 20, 0.2, 0, 13)
	_check_bool("AIM_KIN multi-tick settle is not a flick-stop", int(three_tick_settle["flags"]) & 2, 0)
	_check_bool("AIM_KIN multi-tick settle duration", three_tick_settle["settle_ticks"], 2)


func _test_view_validator() -> void:
	var normal := ViewValidator.validate_view(0.0, 0.0, 0.0, 180.0)
	_check_bool("J15 default permits a large yaw flick", normal["ok"], true)
	var finite_limit := ViewValidator.validate_view(
		0.0, 0.0, 0.0, 180.0, {"MAX_VIEW_DELTA_DEG_PER_TICK": 90.0}
	)
	_check_bool("J15 finite alternative rejects yaw delta", finite_limit["ok"], false)
	_check_bool("J15 finite alternative reason 2", finite_limit["reason"], 2)
	var exact_limit := ViewValidator.validate_view(
		0.0, 0.0, 0.0, 90.0, {"MAX_VIEW_DELTA_DEG_PER_TICK": 90.0}
	)
	_check_bool("J15 finite alternative includes its limit", exact_limit["ok"], true)
	var malformed := ViewValidator.validate_view(0.0, 0.0, 90.0, 0.0)
	_check_bool("J15 pitch outside +/-89 is malformed", malformed["reason"], 4)
	var nonfinite := ViewValidator.validate_view(0.0, 0.0, 0.0, INF)
	_check_bool("J15 non-finite angle is malformed", nonfinite["reason"], 4)


func _test_unsent_episode_thresholds() -> void:
	var pitch := _head_pitch()
	var exact := _analyze_static(0, 31, 2.0, pitch)
	_check_bool("7A exactly 32 ticks at 2 degrees counts", exact["players"][0]["episodes"].size(), 1)
	_check_float("7A inclusive angle threshold", exact["players"][0]["episodes"][0]["min_theta_deg"], 2.0, 1e-6)
	var short := _analyze_static(0, 30, 2.0, pitch)
	_check_bool("7A 31 ticks does not count", short["players"][0]["episodes"].size(), 0)
	var outside := _analyze_static(0, 31, 2.01, pitch)
	_check_bool("7A 2.01 degrees does not count", outside["players"][0]["episodes"].size(), 0)
	var weighted_three := _analyze_weighted_mix(3, 0)
	var weighted_two_seven_five := _analyze_weighted_mix(2, 3)
	var invalid_chain := _analyze_weighted_mix(3, 0, false)
	_check_float("7A exactly 3.0 weighted episodes", weighted_three["players"][0]["weighted_episodes"], 3.0, 1e-9)
	_check_bool("7A 3.0 weighted episodes reaches review", weighted_three["players"][0]["status"], "NEEDS_HUMAN_REVIEW")
	_check_float("7A teammate weight yields 2.75", weighted_two_seven_five["players"][0]["weighted_episodes"], 2.75, 1e-9)
	_check_bool("7A 2.75 weighted episodes stays unflagged", weighted_two_seven_five["players"][0]["status"], "NO_FLAG")
	_check_bool("7A invalid evidence chain cannot raise a review flag", invalid_chain["players"][0]["status"], "NO_FLAG")


func _test_drop_rules() -> void:
	var age63 := _analyze_just_left(63)
	var age65 := _analyze_just_left(65)
	_check_float("7A G=63-tick recent visibility drops episode", age63["players"][0]["weighted_episodes"], 0.0, 1e-9)
	_check_float("7A G=65-tick visibility is outside grace", age65["players"][0]["weighted_episodes"], 1.0, 1e-9)

	var sound_inside := _analyze_sound(255, 3.9)
	var sound_old := _analyze_sound(257, 3.9)
	var sound_angle_outside := _analyze_sound(255, 4.1)
	_check_float("7A S=1992ms sound explains aim", sound_inside["players"][0]["weighted_episodes"], 0.0, 1e-9)
	_check_float("7A S=2008ms sound is too old", sound_old["players"][0]["weighted_episodes"], 1.0, 1e-9)
	_check_float("7A sound angle 4.1 degrees does not explain", sound_angle_outside["players"][0]["weighted_episodes"], 1.0, 1e-9)

	var preaim_inside := _analyze_preaim(true)
	var preaim_outside := _analyze_preaim(false)
	_check_float("7A common pre-aim spot drops episode", preaim_inside["players"][0]["weighted_episodes"], 0.0, 1e-9)
	_check_float("7A pre-aim spot outside radius counts", preaim_outside["players"][0]["weighted_episodes"], 1.0, 1e-9)

	var teammate := _analyze_teammate()
	_check_float("7A teammate information weighs 0.25", teammate["players"][0]["weighted_episodes"], 0.25, 1e-9)
	_check_bool("7A teammate explanation is recorded", teammate["players"][0]["episodes"][0]["drop_reasons"].has("teammate"), true)

	var dead_viewer := _analyze_static(0, 31, 0.0, _head_pitch(), {"viewer_alive": false})
	_check_bool("7A dead viewer produces no episode", dead_viewer["players"][0]["episodes"].size(), 0)
	var same_team := _analyze_static(0, 31, 0.0, _head_pitch(), {"target_team": 1})
	_check_bool("7A same-team target is excluded", same_team["players"][0]["episodes"].size(), 0)


func _test_tracking_correlation() -> void:
	var high := _analyze_tracking(0.93)
	var low := _analyze_tracking(1.30)
	_check_float(
		"7A tracking correlation fixture near 0.85",
		high["players"][0]["episodes"][0]["tracking_correlation"],
		0.85,
		0.01
	)
	_check_bool("7A correlation 0.85 is tracking", high["players"][0]["episodes"][0]["kind"], "tracking")
	_check_float(
		"7A tracking correlation fixture near 0.75",
		low["players"][0]["episodes"][0]["tracking_correlation"],
		0.75,
		0.01
	)
	_check_bool("7A correlation 0.75 is aim only", low["players"][0]["episodes"][0]["kind"], "aim")


func _test_unsent_shot_thresholds() -> void:
	var two_hits := _analyze_shots([
		{"outcome": 0, "flags": 1 << 3},
		{"outcome": 0, "flags": 1 << 3},
	])
	var hit_and_nears := _analyze_shots([
		{"outcome": 0, "flags": 1 << 3},
		{"outcome": 1, "flags": 1 << 3},
		{"outcome": 1, "flags": 1 << 3},
		{"outcome": 1, "flags": 1 << 3},
	])
	var wall_hits := _analyze_shots([
		{"outcome": 0, "flags": (1 << 3) | (1 << 2)},
		{"outcome": 0, "flags": (1 << 3) | (1 << 2)},
	])
	_check_bool("7A two clean shots at unsent trigger review", two_hits["players"][0]["status"], "NEEDS_HUMAN_REVIEW")
	_check_bool("7A one hit plus near misses do not trigger review", hit_and_nears["players"][0]["status"], "NO_FLAG")
	_check_bool("7A THROUGH_WORLD hits do not trigger review", wall_hits["players"][0]["status"], "NO_FLAG")


func _test_aim_kin_review_threshold() -> void:
	var three_rounds := _analyze_aim_kin([1, 2, 3])
	var three_flick_rounds := _analyze_aim_kin([1, 2, 3], 2)
	var one_round := _analyze_aim_kin([1, 1, 1])
	var two_rounds := _analyze_aim_kin([1, 2])
	var no_shot := _analyze_aim_kin([])
	_check_bool("7B three flagged rounds require review", three_rounds["players"][0]["status"], "NEEDS_HUMAN_REVIEW")
	_check_bool("7B three flick-stop rounds require review", three_flick_rounds["players"][0]["status"], "NEEDS_HUMAN_REVIEW")
	_check_bool("7B three flags in one round do not require review", one_round["players"][0]["status"], "NO_FLAG")
	_check_bool("7B two flagged rounds do not require review", two_rounds["players"][0]["status"], "NO_FLAG")
	_check_bool("7B exports AIM_KIN review entries", three_rounds["aim_kinematics"].size(), 3)
	_check_bool("7B no shot produces no AIM_KIN", no_shot["aim_kinematics"].size(), 0)


func _test_review_queue_guards() -> void:
	var valid := {
		"match_id": "test",
		"analyzer_version": "0.1",
		"params": {},
		"evidence_chain_ok": true,
		"players": [{"slot": 0, "player_ref": "00", "status": "NO_FLAG"}],
		"auto_action": "NONE",
	}
	_check_bool("review queue accepts review-only schema", ReviewQueue.validate(valid)["ok"], true)
	var bad_action := valid.duplicate(true)
	bad_action["auto_action"] = "BAN"
	_check_bool("review queue refuses non-NONE action", ReviewQueue.validate(bad_action)["ok"], false)
	var bad_status := valid.duplicate(true)
	bad_status["players"][0]["status"] = "PUNISH"
	_check_bool("review queue refuses unsupported status", ReviewQueue.validate(bad_status)["ok"], false)
	var default_write := ReviewQueue.write_report("user://review_disabled.flags.json", valid)
	_check_bool("default review writer is disabled", default_write["errors"][0], "review_disabled")
	var bad_write := ReviewQueue.write_report(
		"user://invalid_review.flags.json",
		bad_action,
		REVIEW_ENABLED
	)
	_check_bool("invalid report is not written", bad_write["ok"], false)
	var write := ReviewQueue.write_report("user://valid_review.flags.json", valid, REVIEW_ENABLED)
	_check_bool("valid review report writes", write["ok"], true)
	var nested_write := ReviewQueue.write_report(
		"user://review/anticheat_test.flags.json",
		valid,
		REVIEW_ENABLED
	)
	_check_bool("review queue creates review directory", nested_write["ok"], true)


func _test_source_language_guard() -> void:
	var directory := DirAccess.open("res://anticheat")
	if directory == null:
		_fail("cannot scan anticheat sources")
		return
	var found_bad_term := false
	var forbidden := ["kick", "ban", "punish", "penalty"]
	for filename in directory.get_files():
		if not filename.ends_with(".gd"):
			continue
		var file := FileAccess.open("res://anticheat/" + filename, FileAccess.READ)
		if file == null:
			continue
		for line in file.get_as_text().split("\n"):
			var parts := str(line).split("#", true, 1)
			var code := str(parts[0]).to_lower() if not parts.is_empty() else ""
			for term in forbidden:
				if code.contains(term):
					found_bad_term = true
					_fail("review-only source contains forbidden term %s in %s" % [term, filename])
	_check_bool("anti-cheat source contains no action functions", found_bad_term, false)


func _test_golden_review_json() -> void:
	var fixture_path := ProjectSettings.globalize_path(
		"res://tests/fixtures/anticheat_match.timeline.json"
	)
	var fixture_file := FileAccess.open("res://tests/fixtures/anticheat_match.timeline.json", FileAccess.READ)
	if fixture_file == null:
		_fail("cannot open offline review fixture")
		return
	var fixture: Dictionary = JSON.parse_string(fixture_file.get_as_text())
	var reader = FpevReader.new(EVIDENCE_ENABLED)
	var evidence: Dictionary = reader.read_file(
		"res://tests/golden/match_small.fpev",
		_hex_bytes(str(fixture["expected_final_chain_sha256"]))
	)
	_check_bool("P7 golden input evidence chain verifies", evidence["ok"], true)
	var timeline := _build_fixture_timeline(fixture)
	var review_params := REVIEW_ENABLED.duplicate(true)
	review_params.merge(fixture.get("params", {}), true)
	var report := UnsentAnalyzer.analyze(
		str(fixture["match_id"]),
		timeline,
		evidence,
		fixture.get("preaim_spots", []),
		review_params,
		fixture.get("server_metadata", {})
	)
	var golden := FileAccess.get_file_as_string("res://tests/golden/anticheat_match.flags.json")
	var serialized := JSON.stringify(report, "\t", true, true) + "\n"
	_check_string_match("GDScript report matches committed golden JSON", serialized, golden)
	_check_bool("P7 golden output is review-only", report["auto_action"], "NONE")
	_check_bool("P7 golden selects surf from server metadata", report["params"]["AIM_KIN_PROFILE"], "surf")
	var queue_write := ReviewQueue.write_report(
		"user://anticheat_match.flags.json",
		report,
		REVIEW_ENABLED
	)
	_check_bool("review queue writes analyzer output", queue_write["ok"], true)
	_check_string_match(
		"review queue output matches golden bytes",
		FileAccess.get_file_as_string("user://anticheat_match.flags.json"),
		golden
	)

	var repository_dir := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
	var python_ref := repository_dir.path_join("tools/anticheat_ref.py")
	var python_output_path := ProjectSettings.globalize_path("user://anticheat_python.flags.json")
	var command_output: Array = []
	var exit_code := OS.execute(
		"python3",
		PackedStringArray([
			python_ref,
			fixture_path,
			"--enable-review",
			"--enable-evidence-log",
			"--output",
			python_output_path,
		]),
		command_output,
		true
	)
	_check_bool("Python analyzer exits successfully", exit_code, 0)
	if exit_code == 0:
		_check_string_match(
			"Python report matches committed golden JSON",
			FileAccess.get_file_as_string("user://anticheat_python.flags.json"),
			golden
		)


func _build_fixture_timeline(fixture: Dictionary) -> Array:
	var tick_rate := int(fixture["tick_rate"])
	var end_tick := int(fixture["end_tick"])
	var states_by_slot := {}
	for player in fixture["players"]:
		var slot := int(player["slot"])
		states_by_slot[slot] = []
		for tick in range(end_tick + 1):
			var state := ScriptedPath.sample(
				player["path"],
				tick,
				tick_rate,
				int(player.get("stance_every_n_ticks", 0)),
				int(player.get("spawn_tick", -1)),
				int(player.get("death_tick", -1))
			)
			state["slot"] = slot
			state["team"] = int(player["team"])
			state["map_area"] = str(player.get("map_area", ""))
			state["view_pitch"] = float(player.get("default_view_pitch", 0.0))
			state["view_yaw"] = float(player.get("default_view_yaw", 90.0))
			state["spectating"] = bool(player.get("spectating", false))
			state["in_menu"] = bool(player.get("in_menu", false))
			state["teleported"] = false
			state["respawned"] = false
			states_by_slot[slot].append(state)

	for window in fixture.get("aim_windows", []):
		var viewer_slot := int(window["viewer_slot"])
		var target_slot := int(window["target_slot"])
		for tick in range(int(window["start_tick"]), int(window["end_tick"]) + 1):
			var viewer: Dictionary = states_by_slot[viewer_slot][tick]
			var target: Dictionary = states_by_slot[target_slot][tick]
			var eye: PackedFloat64Array = viewer["origin64"].duplicate()
			eye[2] += HitboxBuilder.eye_height(int(viewer["stance"]))
			var boxes: Array = HitboxBuilder.build_boxes_precise(
				target["origin64"],
				float(target["yaw_deg"]),
				int(target["stance"])
			)
			var point: PackedFloat64Array = boxes[int(window.get("part", 0))]["center64"]
			var dx := point[0] - eye[0]
			var dy := point[1] - eye[1]
			var dz := point[2] - eye[2]
			var pitch := -rad_to_deg(atan2(dz, sqrt(dx * dx + dy * dy)))
			var yaw := rad_to_deg(atan2(dy, dx))
			var pitch_q := InputCommand.quantize_pitch(FrameAdapter.pitch_to_game_rad(pitch))
			var yaw_q := InputCommand.quantize_yaw(FrameAdapter.yaw_to_game_rad(yaw))
			viewer["view_pitch"] = FrameAdapter.pitch_to_spec_deg(
				InputCommand.dequantize_pitch(pitch_q)
			)
			viewer["view_yaw"] = FrameAdapter.yaw_to_spec_deg(
				InputCommand.dequantize_yaw(yaw_q)
			)

	var sounds_by_tick := {}
	for sound in fixture.get("sound_events", []):
		var sound_tick := int(sound["tick"])
		if not sounds_by_tick.has(sound_tick):
			sounds_by_tick[sound_tick] = []
		sounds_by_tick[sound_tick].append(sound)
	var timeline: Array = []
	var sorted_slots := states_by_slot.keys()
	sorted_slots.sort()
	for tick in range(end_tick + 1):
		var round_id := 0
		for span in fixture.get("round_spans", []):
			if tick >= int(span["start_tick"]) and tick <= int(span["end_tick"]):
				round_id = int(span["round"])
				break
		var players: Array = []
		for slot in sorted_slots:
			players.append(states_by_slot[slot][tick])
		timeline.append({
			"tick": tick,
			"round": round_id,
			"players": players,
			"sound_events": sounds_by_tick.get(tick, []),
		})
	return timeline


func _hex_bytes(hex_string: String) -> PackedByteArray:
	var output := PackedByteArray()
	for offset in range(0, hex_string.length(), 2):
		output.append(
			(_hex_nibble(hex_string.unicode_at(offset)) << 4)
			| _hex_nibble(hex_string.unicode_at(offset + 1))
		)
	return output


func _hex_nibble(codepoint: int) -> int:
	if codepoint >= 48 and codepoint <= 57:
		return codepoint - 48
	if codepoint >= 97 and codepoint <= 102:
		return codepoint - 87
	if codepoint >= 65 and codepoint <= 70:
		return codepoint - 55
	return -1


func _constant_commands(start_tick: int, end_tick: int, speed_dps: float, quantized: bool = false) -> Array:
	var commands: Array = []
	for tick in range(start_tick, end_tick):
		var yaw := speed_dps * float(tick) / 128.0
		var command := {"cmd_seq": tick, "tick": tick, "alive": true, "spectating": false}
		if quantized:
			command["view_pitch_q"] = InputCommand.quantize_pitch(
				FrameAdapter.pitch_to_game_rad(0.0)
			)
			command["view_yaw_q"] = InputCommand.quantize_yaw(FrameAdapter.yaw_to_game_rad(yaw))
		else:
			command["view_pitch"] = 0.0
			command["view_yaw"] = yaw
		commands.append(command)
	return commands


func _commands_from_yaws(yaws: Array) -> Array:
	var commands: Array = []
	for tick in range(yaws.size()):
		commands.append({
			"cmd_seq": tick,
			"tick": tick,
			"view_pitch": 0.0,
			"view_yaw": float(yaws[tick]),
			"alive": true,
			"spectating": false,
		})
	return commands


func _head_pitch(target_origin: Array = [500.0, 0.0, 0.0]) -> float:
	var dx := float(target_origin[0])
	var dy := float(target_origin[1])
	var dz := 66.0 - 64.0
	return -rad_to_deg(atan2(dz, sqrt(dx * dx + dy * dy)))


func _analyze_static(
		start_tick: int,
		end_tick: int,
		yaw: float,
		pitch: float,
		options: Dictionary = {}
	) -> Dictionary:
	var timeline := _make_simple_timeline(start_tick, end_tick, yaw, pitch, options)
	var vis_records: Array = options.get("vis_records", [_vis(0, 0, 0, 0)])
	var teams := {
		0: int(options.get("viewer_team", 1)),
		1: int(options.get("target_team", 2)),
	}
	for extra in options.get("extra_players", []):
		teams[int(extra["slot"])] = int(extra["team"])
	var params := REVIEW_ENABLED.duplicate(true)
	params.merge(options.get("params", {}), true)
	return UnsentAnalyzer.analyze(
		"fixture",
		timeline,
		_evidence(teams, vis_records, options.get("records", [])),
		options.get("preaim_spots", []),
		params,
		options.get("server_metadata", {})
	)


func _make_simple_timeline(
		start_tick: int,
		end_tick: int,
		yaw: float,
		pitch: float,
		options: Dictionary = {}
	) -> Array:
	var frames: Array = []
	var aim_start := int(options.get("aim_start", start_tick))
	var target_origin: Array = options.get("target_origin", [500.0, 0.0, 0.0])
	var target_team := int(options.get("target_team", 2))
	var viewer_team := int(options.get("viewer_team", 1))
	var target_positions: Dictionary = options.get("target_positions", {})
	var round_by_tick: Dictionary = options.get("round_by_tick", {})
	var viewer_yaws: Dictionary = options.get("viewer_yaws", {})
	var sounds_by_tick: Dictionary = options.get("sounds_by_tick", {})
	for tick in range(end_tick + 1):
		var origin: Array = target_positions.get(tick, target_origin)
		var view_yaw := float(viewer_yaws.get(tick, 20.0 if tick < aim_start else yaw))
		var viewer := {
			"slot": 0,
			"team": viewer_team,
			"alive": bool(options.get("viewer_alive", true)),
			"spectating": bool(options.get("viewer_spectating", false)),
			"in_menu": bool(options.get("viewer_in_menu", false)),
			"origin64": PackedFloat64Array([0.0, 0.0, 0.0]),
			"stance": 0,
			"view_pitch": pitch,
			"view_yaw": view_yaw,
			"map_area": str(options.get("map_area", "range")),
		}
		var target := {
			"slot": 1,
			"team": target_team,
			"alive": bool(options.get("target_alive", true)),
			"origin64": PackedFloat64Array(origin),
			"yaw_deg": float(options.get("target_yaw", 180.0)),
			"stance": int(options.get("target_stance", 0)),
		}
		var players := [viewer, target]
		for extra in options.get("extra_players", []):
			var state: Dictionary = extra.duplicate(true)
			if state.has("positions") and state["positions"].has(tick):
				state["origin64"] = PackedFloat64Array(state["positions"][tick])
			players.append(state)
		var frame := {
			"tick": tick,
			"round": int(round_by_tick.get(tick, options.get("round", 1))),
			"players": players,
			"sound_events": sounds_by_tick.get(tick, []),
		}
		frames.append(frame)
	return frames


func _evidence(teams: Dictionary, vis_records: Array, other_records: Array = []) -> Dictionary:
	var slots: Array = []
	var slot_ids := teams.keys()
	slot_ids.sort()
	for slot in slot_ids:
		var player_ref := PackedByteArray()
		player_ref.resize(32)
		player_ref.fill(int(slot) + 1)
		slots.append({
			"slot": int(slot),
			"team": int(teams[slot]),
			"player_ref": player_ref,
		})
	var records := vis_records.duplicate(true)
	records.append_array(other_records)
	records.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["tick"]) == int(b["tick"]):
			return int(a["type"]) < int(b["type"])
		return int(a["tick"]) < int(b["tick"])
	)
	return {
		"ok": true,
		"header": {"tick_rate": 128, "slots": slots},
		"records": records,
	}


func _vis(tick: int, viewer: int, sent_mask: int, sound_mask: int) -> Dictionary:
	return {
		"type": 2,
		"flags": 0,
		"tick": tick,
		"fields": {
			"viewer_slot": viewer,
			"sent_mask": sent_mask,
			"sound_only_mask": sound_mask,
		},
	}


func _analyze_just_left(sent_age_ticks: int) -> Dictionary:
	var start := 100
	var sent_tick := start - sent_age_ticks
	var vis := [
		_vis(0, 0, 0, 0),
		_vis(sent_tick, 0, 1 << 1, 0),
		_vis(sent_tick + 1, 0, 0, 0),
	]
	return _analyze_static(
		start, start + 31, 0.0, _head_pitch(),
		{"aim_start": start, "vis_records": vis}
	)


func _analyze_sound(sound_age_ticks: int, sound_angle_deg: float) -> Dictionary:
	var start := 300
	var sound_tick := start - sound_age_ticks
	var rounded_sound := PackedFloat64Array([
		500.0,
		500.0 * tan(deg_to_rad(sound_angle_deg)),
		66.0,
	])
	var options := {
		"aim_start": start,
		"vis_records": [
			_vis(0, 0, 0, 0),
			_vis(sound_tick, 0, 0, 1 << 1),
		],
		"sounds_by_tick": {
			sound_tick: [{
				"source_slot": 1,
				"rounded_pos": rounded_sound,
				"heard_by": [0],
			}],
		},
	}
	return _analyze_static(start, start + 31, 0.0, _head_pitch(), options)


func _analyze_preaim(inside: bool) -> Dictionary:
	var point := [500.0, 0.0, 66.0] if inside else [500.0, 2.0, 66.0]
	return _analyze_static(
		0, 31, 0.0, _head_pitch(),
		{"preaim_spots": [{"map_area": "range", "point": point, "radius": 1.0}]}
	)


func _analyze_teammate() -> Dictionary:
	var extra := {
		"slot": 2,
		"team": 1,
		"alive": true,
		"origin64": PackedFloat64Array([0.0, 50.0, 0.0]),
		"yaw_deg": 0.0,
		"stance": 0,
		"view_pitch": 0.0,
		"view_yaw": 0.0,
	}
	var vis := [
		_vis(0, 0, 0, 0),
		_vis(0, 2, 1 << 1, 0),
	]
	return _analyze_static(
		0, 31, 0.0, _head_pitch(),
		{"extra_players": [extra], "vis_records": vis}
	)


func _analyze_shots(shots: Array) -> Dictionary:
	var records: Array = []
	for index in range(shots.size()):
		records.append({
			"type": 1,
			"flags": int(shots[index]["flags"]),
			"tick": index,
			"fields": {
				"shooter_slot": 0,
				"target_slot": 1,
				"outcome": int(shots[index]["outcome"]),
				"part": 0,
			},
		})
	return _analyze_static(
		0, 1, 90.0, 0.0,
		{"records": records, "vis_records": [_vis(0, 0, 0, 0)]}
	)


func _analyze_aim_kin(rounds: Array, aim_flags: int = 1) -> Dictionary:
	var records: Array = [_vis(0, 0, 0, 0)]
	var round_by_tick := {}
	var last_tick := 0
	for index in range(rounds.size()):
		var tick := 10 + index * 10
		last_tick = tick
		round_by_tick[tick] = int(rounds[index])
		records.append({
			"type": 1,
			"flags": 0,
			"tick": tick,
			"fields": {
				"shooter_slot": 0,
				"target_slot": 1,
				"shot_index": index + 1,
				"outcome": 0,
				"part": 0,
				"weapon_id": 1,
			},
		})
		records.append({
			"type": 6,
			"flags": aim_flags,
			"tick": tick,
			"fields": {
				"shooter_slot": 0,
				"shot_index": index + 1,
				"move_state": 0,
				"spread_at_fire": 0.2,
				"peak_ang_vel_dps": 500.0,
				"peak_ang_accel_dps2": 300000.0,
				"fire_tick_delta_deg": 5.0,
				"snapback_deg": 4.0,
				"snapback_cos": -0.9,
				"pre_fire_speed_dps": 0.2,
				"settle_ticks": 1,
			},
		})
	var timeline := _make_simple_timeline(
		0, last_tick + 1, 90.0, 0.0,
		{"round_by_tick": round_by_tick}
	)
	var teams := {0: 1, 1: 2}
	return UnsentAnalyzer.analyze(
		"fixture",
		timeline,
		_evidence(teams, [_vis(0, 0, 0, 0)], records.slice(1)),
		[],
		REVIEW_ENABLED
	)


func _analyze_tracking(noise_scale: float) -> Dictionary:
	var frames: Array = []
	var bearing := 0.0
	var residual := 0.0
	var rate_pattern := [0.02, 0.04, 0.06, 0.08]
	var noise_pattern := [0.008, -0.018, 0.018, -0.008]
	for tick in range(32):
		if tick > 0:
			var phase := (tick - 1) % 4
			bearing += rate_pattern[phase]
			residual += noise_pattern[phase] * noise_scale
		var target_y := 500.0 * tan(deg_to_rad(bearing))
		var target := {
			"slot": 1,
			"team": 2,
			"alive": true,
			"origin64": PackedFloat64Array([500.0, target_y, 0.0]),
			"yaw_deg": 90.0,
			"stance": 0,
		}
		var viewer := {
			"slot": 0,
			"team": 1,
			"alive": true,
			"origin64": PackedFloat64Array([0.0, 0.0, 0.0]),
			"stance": 0,
			"view_pitch": _head_pitch([500.0, target_y, 0.0]),
			"view_yaw": bearing + 0.5 + residual,
			"map_area": "range",
		}
		frames.append({"tick": tick, "round": 1, "players": [viewer, target], "sound_events": []})
	return UnsentAnalyzer.analyze(
		"fixture",
		frames,
		_evidence({0: 1, 1: 2}, [_vis(0, 0, 0, 0)]),
		[],
		REVIEW_ENABLED
	)


func _analyze_weighted_mix(
		full_weight_count: int,
		teammate_weight_count: int,
		chain_ok: bool = true
	) -> Dictionary:
	var total_targets := full_weight_count + teammate_weight_count
	var teammate_slot := total_targets + 1
	var teammate_mask := 0
	for slot in range(full_weight_count + 1, total_targets + 1):
		teammate_mask |= 1 << slot
	var teams := {0: 1, teammate_slot: 1}
	var vis := [_vis(0, 0, 0, 0), _vis(0, teammate_slot, teammate_mask, 0)]
	var frames: Array = []
	for tick in range(total_targets * 32):
		var block := mini(int(floor(float(tick) / 32.0)), total_targets - 1)
		var viewer := {
			"slot": 0,
			"team": 1,
			"alive": true,
			"origin64": PackedFloat64Array([0.0, 0.0, 0.0]),
			"stance": 0,
			"view_pitch": _head_pitch(),
			"view_yaw": 0.0,
			"map_area": "range",
		}
		var players: Array = [viewer]
		for target_index in range(total_targets):
			var slot := target_index + 1
			var target_y := 0.0 if target_index == block else 200.0
			players.append({
				"slot": slot,
				"team": 2,
				"alive": true,
				"origin64": PackedFloat64Array([500.0, target_y, 0.0]),
				"yaw_deg": 180.0,
				"stance": 0,
			})
			teams[slot] = 2
		players.append({
			"slot": teammate_slot,
			"team": 1,
			"alive": true,
			"origin64": PackedFloat64Array([0.0, -100.0, 0.0]),
			"yaw_deg": 0.0,
			"stance": 0,
			"view_pitch": 0.0,
			"view_yaw": 0.0,
		})
		frames.append({
			"tick": tick,
			"round": block + 1,
			"players": players,
			"sound_events": [],
		})
	var evidence := _evidence(teams, vis)
	evidence["ok"] = chain_ok
	return UnsentAnalyzer.analyze(
		"weighted-fixture",
		frames,
		evidence,
		[],
		REVIEW_ENABLED
	)


func _join_output(output: Array) -> String:
	var parts := PackedStringArray()
	for value in output:
		parts.append(str(value))
	return "\n".join(parts)


func _check_float(name: String, got: float, want: float, tolerance: float) -> void:
	if absf(got - want) <= tolerance:
		passed += 1
		print("PASS  %s  got %.9f want %.9f" % [name, got, want])
	else:
		_fail("%s got %.12f want %.12f tolerance %.12f" % [name, got, want, tolerance])


func _check_string_match(name: String, got: String, want: String) -> void:
	if got == want:
		passed += 1
		print("PASS  %s  %d characters" % [name, got.length()])
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
