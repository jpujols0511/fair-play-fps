extends Node3D

const HitRegLogic = preload("res://hitreg/hitreg.gd")
const HitboxBuilder = preload("res://hitreg/hitboxes.gd")
const LagCompHistory = preload("res://hitreg/lagcomp_history.gd")
const ScriptedPath = preload("res://tests/scripted_path.gd")
const RecoilLogic = preload("res://weapons/recoil.gd")
const RifleTables = preload("res://weapons/rifle_tables.gd")
const DamageRegionData = preload("res://hitreg/damage_regions.gd")
const RngSource = preload("res://weapons/rng_source.gd")
const FpevWriter = preload("res://evidence/fpev_writer.gd")
const FpevReader = preload("res://evidence/fpev_reader.gd")
const FpevJsonl = preload("res://evidence/fpev_jsonl.gd")
const EvidenceConfig = preload("res://evidence/evidence_config.gd")
const AimKinLogic = preload("res://anticheat/aim_kin.gd")
const UnsentAnalyzer = preload("res://anticheat/unsent_aim_analyzer.gd")
const ReviewQueue = preload("res://anticheat/review_queue.gd")
const AntiCheatParams = preload("res://anticheat/anticheat_params.gd")
const FrameAdapter = preload("res://shared/frame.gd")
const InputCommand = preload("res://shared/input_cmd.gd")

const TICK_RATE := 128.0
const TICK_SECONDS := 1.0 / TICK_RATE
const PLAYER_COUNT := 6
const SMOKE_TICKS := 2000
const SMOKE_SHOTS := 50
const SMOKE_BACKTRACK_SHOTS := 5
const SMOKE_SNAPBACK_SHOTS := [10, 20, 30]
const SMOKE_MATCH_ID := "8a7f0b1e-4f39-4b5d-9a62-19c5317b8e40"
const BUILD_ID := "a7f2c9416be55d1a0834bca9e760218f0d3c5a71"
const FIXED_START_UNIX_MS := 1800000000000
const MOVE_SPEED := 260.0
const MOUSE_SENSITIVITY := 0.12
const GAME_INK := Color("#101819")
const GAME_PAPER := Color("#e8e2d3")
const GAME_ACID := Color("#d2ff6b")
const GAME_ORANGE := Color("#ff8b45")

var _camera: Camera3D
var _hud: CanvasLayer
var _world_root: Node3D
var _player_visuals: Dictionary = {}
var _player_states: Array = []
var _teams: Dictionary = {}
var _world_boxes: Array = []
var _history: LagCompHistory
var _weapon_state: Dictionary = {}
var _weapon_table_ids: Array = []
var _weapon_index := 0
var _shot_index := 0
var _cmd_seq := 0
var _tick := 0
var _ping_ms := 80.0
var _interp_ticks := 4
var _backtrack_debug := false
var _silent_aim_debug := false
var _silent_shots_remaining := 0
var _silent_return_tick := -1
var _silent_base_pitch := 0.0
var _silent_base_yaw := 0.0
var _fire_requested := false
var _session_started := false
var _session_closed := false
var _smoke_mode := false
var _match_id := ""
var _match_directory := ""
var _evidence_path := ""
var _jsonl_path := ""
var _review_path := ""
var _writer
var _evidence_config: Dictionary = {}
var _review_config: Dictionary = {}
var _server_metadata: Dictionary = {"mode": "default"}
var _vis_state: Dictionary = {}
var _record_counts := {"shot": 0, "vis": 0, "rewind": 0, "input_reject": 0, "aim_kin": 0}
var _timeline: Array = []
var _view_commands: Array = []
var _pending_aim: Array = []
var _scheduled_shots: Dictionary = {}
var _last_result := "NO SHOT"
var _last_spread := 0.0
var _last_rewind: Dictionary = {}
var _last_aim_kin: Dictionary = {}
var _verify_status := "EVIDENCE OPEN"
var _review_status := ""
var _frame_remainder := 0.0
var _shot_visuals: Array = []
var _materials: Dictionary = {}
var _static_round_spans: Array = []


func _ready() -> void:
	_camera = $ShooterCamera
	_hud = $HUD
	_reset_simulation(false, false)
	_world_root = Node3D.new()
	_world_root.name = "ProceduralRange"
	add_child(_world_root)
	_build_materials()
	_build_world()
	_build_player_visuals()
	_update_camera()
	_update_hud()
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _process(delta: float) -> void:
	if not _session_started and not _session_closed:
		_start_session(false)
	if _session_started:
		_frame_remainder += minf(delta, 0.1)
		while _frame_remainder >= TICK_SECONDS:
			_frame_remainder -= TICK_SECONDS
			_step_tick(_tick, false)
			_tick += 1
	_update_player_visuals()
	_update_camera()
	_update_shot_visuals(delta)
	_update_hud()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_player_states[0]["view_yaw"] = fposmod(
			float(_player_states[0]["view_yaw"]) - event.relative.x * MOUSE_SENSITIVITY,
			360.0
		)
		_player_states[0]["view_pitch"] = clampf(
			float(_player_states[0]["view_pitch"]) + event.relative.y * MOUSE_SENSITIVITY,
			-89.0,
			89.0
		)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_fire_requested = true
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_1:
				_weapon_index = 0
				_reset_weapon()
			KEY_2:
				_weapon_index = mini(1, _weapon_table_ids.size() - 1)
				_reset_weapon()
			KEY_I:
				_interp_ticks = 2 if _interp_ticks == 4 else _interp_ticks + 1
			KEY_B:
				_backtrack_debug = not _backtrack_debug
			KEY_N:
				_silent_aim_debug = not _silent_aim_debug
				_silent_shots_remaining = 3 if _silent_aim_debug else 0
			KEY_L:
				_close_and_verify()
			KEY_K:
				_run_review()
			KEY_R:
				_reset_simulation(false, true)
			KEY_F1:
				_ping_ms = 0.0
			KEY_F2:
				_ping_ms = 40.0
			KEY_F3:
				_ping_ms = 80.0
			KEY_F4:
				_ping_ms = 150.0
			KEY_F5:
				_ping_ms = 250.0


func run_smoke() -> Dictionary:
	_reset_simulation(true, true)
	if not _start_session(
			true,
			{"ENABLE_EVIDENCE_LOG": true},
			{"ENABLE_ANTICHEAT_REVIEW": true}
		):
		return {"ok": false, "error": "evidence writer could not start"}
	for tick in range(SMOKE_TICKS):
		_step_tick(tick, true)
		_tick = tick + 1
	var verification := _close_and_verify()
	var analyzer_result := _run_review()
	var file_bytes := FileAccess.get_file_as_bytes(_evidence_path)
	var shot_command_count := int(verification.get("shot_command_count", 0))
	return {
		"ok": bool(verification.get("ok", false))
			and int(_record_counts["rewind"]) == SMOKE_SHOTS
			and int(_record_counts["input_reject"]) == SMOKE_BACKTRACK_SHOTS
			and int(_record_counts["aim_kin"]) == shot_command_count
			and int(verification.get("hit_count", 0)) > 0
			and int(verification.get("near_miss_count", 0)) > 0
			and bool(verification.get("snapback_seen", false))
			and bool(analyzer_result.get("ok", false)),
		"tick_count": SMOKE_TICKS,
		"shot_count": SMOKE_SHOTS,
		"shot_command_count": shot_command_count,
		"record_counts": _record_counts.duplicate(true),
		"verification": verification,
		"review": analyzer_result,
		"sha256": _sha256(file_bytes).hex_encode(),
		"evidence_path": _evidence_path,
		"jsonl_path": _jsonl_path,
		"review_path": _review_path,
	}


func _unique_shot_command_count(records: Array) -> int:
	var shot_indices := {}
	for record in records:
		if int(record["type"]) != FpevWriter.RECORD_SHOT:
			continue
		shot_indices[int(record["fields"]["shot_index"])] = true
	return shot_indices.size()


func _reset_simulation(smoke_mode: bool, close_existing: bool) -> void:
	if close_existing and _session_started and not _session_closed and _writer != null:
		_writer.close()
	_writer = null
	_evidence_config = EvidenceConfig.defaults()
	_review_config = AntiCheatParams.defaults()
	_server_metadata = {"mode": "default"}
	_smoke_mode = smoke_mode
	_tick = 0
	_shot_index = 0
	_cmd_seq = 0
	_frame_remainder = 0.0
	_ping_ms = 80.0
	_interp_ticks = 4
	_backtrack_debug = false
	_silent_aim_debug = false
	_silent_shots_remaining = 0
	_silent_return_tick = -1
	_silent_base_pitch = 0.0
	_silent_base_yaw = 0.0
	_fire_requested = false
	_session_started = false
	_session_closed = false
	_evidence_path = ""
	_jsonl_path = ""
	_review_path = ""
	_last_result = "NO SHOT"
	_last_spread = 0.0
	_last_rewind = {}
	_last_aim_kin = {}
	_verify_status = "EVIDENCE OPEN"
	_review_status = ""
	_record_counts = {"shot": 0, "vis": 0, "rewind": 0, "input_reject": 0, "aim_kin": 0}
	_vis_state.clear()
	_timeline.clear()
	_view_commands.clear()
	_pending_aim.clear()
	_scheduled_shots.clear()
	_weapon_table_ids = RifleTables.TABLES.keys()
	_player_states = _initial_player_states()
	_teams.clear()
	for player in _player_states:
		_teams[int(player["slot"])] = int(player["team"])
	_history = LagCompHistory.new(int(TICK_RATE), PLAYER_COUNT)
	_reset_weapon()
	if smoke_mode:
		_match_id = SMOKE_MATCH_ID
		_ping_ms = 80.0
		_interp_ticks = 4
		_prepare_smoke_schedule()
	else:
		_match_id = _random_match_id()
		_schedule_runtime_aim()
	_clear_shot_visuals()
	if not _player_visuals.is_empty():
		_update_player_visuals()


func _start_session(
		smoke_mode: bool,
		evidence_overrides: Dictionary = {},
		review_overrides: Dictionary = {}
	) -> bool:
	if _session_started:
		return true
	_smoke_mode = smoke_mode
	_evidence_config = EvidenceConfig.with_overrides(evidence_overrides)
	_review_config = AntiCheatParams.with_overrides(review_overrides)
	if not bool(_evidence_config["ENABLE_EVIDENCE_LOG"]):
		_writer = null
		_session_started = true
		_verify_status = "EVIDENCE DISABLED"
		_review_status = "REVIEW DISABLED"
		return true
	_match_directory = "user://matches/%s" % _match_id
	if smoke_mode:
		_match_directory = "user://smoke_runs/%s_%d_%d" % [
			SMOKE_MATCH_ID,
			OS.get_process_id(),
			Time.get_ticks_usec(),
		]
	var absolute_directory := ProjectSettings.globalize_path(_match_directory)
	if DirAccess.make_dir_recursive_absolute(absolute_directory) != OK:
		return false
	_evidence_path = _match_directory.path_join("evidence.fpev")
	_jsonl_path = _match_directory.path_join("evidence.jsonl")
	_review_path = _match_directory.path_join("review").path_join("%s.flags.json" % _match_id)
	var fields := _header_fields(smoke_mode)
	_writer = FpevWriter.new()
	if not _writer.open(_evidence_path, fields, _evidence_config):
		_writer = null
		return false
	_session_started = true
	return true


func _header_fields(smoke_mode: bool) -> Dictionary:
	var slots: Array = []
	for player in _player_states:
		slots.append({
			"account_id": "range-slot-%d" % int(player["slot"]),
			"team": int(player["team"]),
		})
	return {
		"match_id": _match_id,
		"tick_rate": int(TICK_RATE),
		"start_unix_ms": FIXED_START_UNIX_MS if smoke_mode else int(Time.get_unix_time_from_system() * 1000.0),
		"kernel_sha256": EvidenceConfig.KERNEL_SHA256_PLACEHOLDER,
		"skeleton_sha256": EvidenceConfig.SKELETON_SHA256,
		"build_id": BUILD_ID,
		"map_name": "fp_range",
		"salt": "local-range-review-salt",
		"slots": slots,
	}


func _random_match_id() -> String:
	var crypto := Crypto.new()
	var bytes := crypto.generate_random_bytes(16)
	if bytes.size() != 16:
		bytes = PackedByteArray([0x8a, 0x7f, 0x0b, 0x1e, 0x4f, 0x39, 0x4b, 0x5d, 0x9a, 0x62, 0x19, 0xc5, 0x31, 0x7b, 0x8e, 0x40])
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8), hex.substr(8, 4), hex.substr(12, 4),
		hex.substr(16, 4), hex.substr(20, 12),
	]


func _initial_player_states() -> Array:
	var result: Array = []
	for slot in range(PLAYER_COUNT):
		result.append({
			"slot": slot,
			"team": 1 if slot == 0 else 2,
			"origin64": PackedFloat64Array([0.0, 0.0, 0.0]),
			"yaw_deg": 0.0,
			"stance": 0,
			"alive": true,
			"view_pitch": 0.0,
			"view_yaw": 0.0,
			"map_area": "range",
			"move_state": {"in_air": false, "horizontal_speed": 0.0, "crouched": false},
		})
	return result


func _reset_weapon() -> void:
	if _weapon_table_ids.is_empty():
		_weapon_table_ids = RifleTables.TABLES.keys()
	_weapon_index = clampi(_weapon_index, 0, _weapon_table_ids.size() - 1)
	_weapon_state = RecoilLogic.initial_state(str(_weapon_table_ids[_weapon_index]))


func _prepare_smoke_schedule() -> void:
	_scheduled_shots.clear()
	for index in range(SMOKE_SHOTS):
		var tick := 100 + index * 36
		_scheduled_shots[tick] = {
			"index": index,
			"target_slot": 1,
			"near_miss": index % 4 == 1 and index not in SMOKE_SNAPBACK_SHOTS,
			"backtrack": index < SMOKE_BACKTRACK_SHOTS,
			"silent": index in SMOKE_SNAPBACK_SHOTS,
		}


func _schedule_runtime_aim() -> void:
	_scheduled_shots.clear()


func _step_tick(tick: int, smoke: bool) -> void:
	if not _session_started and not _start_session(smoke):
		_last_result = "EVIDENCE OPEN FAILED"
		return
	_update_players(tick, smoke)
	if not smoke:
		_move_shooter_from_input()
		if _silent_return_tick == tick:
			_player_states[0]["view_pitch"] = _silent_base_pitch
			_player_states[0]["view_yaw"] = _silent_base_yaw
			_silent_return_tick = -1
		if _silent_aim_debug and _silent_shots_remaining > 0:
			_set_silent_idle_view()
		var will_fire := _fire_requested and RecoilLogic.fire_due(_weapon_state, float(tick) / TICK_RATE)
		if will_fire and _silent_aim_debug and _silent_shots_remaining > 0:
			_set_silent_fire_view()
			_silent_return_tick = tick + 1
			_silent_shots_remaining -= 1
	_push_history(tick)
	_write_visibility(tick)
	_record_view_command(tick)
	if smoke and _scheduled_shots.has(tick):
		_process_shot(tick, _scheduled_shots[tick])
	elif not smoke and _fire_requested and RecoilLogic.fire_due(_weapon_state, float(tick) / TICK_RATE):
		_process_shot(tick, {})
	_fire_requested = false
	_process_pending_aim(tick)
	_record_timeline_frame(tick)
	if _writer != null and _session_started and not _session_closed:
		_writer.end_tick(tick)
	_tick = tick


func _update_players(tick: int, smoke: bool) -> void:
	for slot in range(1, PLAYER_COUNT):
		var player: Dictionary = _player_states[slot]
		var pose: Dictionary = {}
		match slot:
			1:
				pose = _strafer_pose(tick)
			2:
				pose = ScriptedPath.circle(
					PackedFloat64Array([850.0, 180.0, 0.0]),
					110.0,
					42.0,
					tick,
					int(TICK_RATE)
				)
			3:
				pose = ScriptedPath.peek(
					PackedFloat64Array([500.0, -260.0, 0.0]),
					PackedFloat64Array([500.0, -10.0, 0.0]),
					120,
					260,
					250.0,
					tick,
					int(TICK_RATE)
				)
			4:
				pose = ScriptedPath.linear(
					PackedFloat64Array([720.0, 220.0, 0.0]),
					PackedFloat64Array([0.0, 0.0, 0.0]),
					tick,
					int(TICK_RATE)
				)
			5:
				pose = ScriptedPath.linear(
					PackedFloat64Array([920.0, -40.0, 0.0]),
					PackedFloat64Array([0.0, 0.0, 0.0]),
					tick,
					int(TICK_RATE)
				)
		player["origin64"] = pose["origin64"]
		player["yaw_deg"] = float(pose["yaw_deg"])
		player["stance"] = ScriptedPath.stance_toggle(80, tick) if slot == 4 else 0
		player["alive"] = true
		player["move_state"] = {
			"in_air": false,
			"horizontal_speed": 250.0 if slot == 1 else 0.0,
			"crouched": slot == 4 and int(player["stance"]) == HitboxBuilder.CROUCH,
		}
	if smoke:
		_set_smoke_view(tick)


func _strafer_pose(tick: int) -> Dictionary:
	var leg_ticks := 103
	var cycle_tick := tick % (leg_ticks * 2)
	if cycle_tick < leg_ticks:
		return ScriptedPath.linear(
			PackedFloat64Array([480.0, 0.0, 0.0]),
			PackedFloat64Array([250.0, 0.0, 0.0]),
			cycle_tick,
			int(TICK_RATE)
		)
	return ScriptedPath.linear(
		PackedFloat64Array([480.0 + 250.0 * float(leg_ticks) / TICK_RATE, 0.0, 0.0]),
		PackedFloat64Array([-250.0, 0.0, 0.0]),
		cycle_tick - leg_ticks,
		int(TICK_RATE)
	)


func _move_shooter_from_input() -> void:
	var direction := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		direction.x += 1.0
	if Input.is_key_pressed(KEY_S):
		direction.x -= 1.0
	if Input.is_key_pressed(KEY_A):
		direction.y += 1.0
	if Input.is_key_pressed(KEY_D):
		direction.y -= 1.0
	if direction.length_squared() > 0.0:
		direction = direction.normalized()
		var origin: PackedFloat64Array = _player_states[0]["origin64"]
		origin[0] += direction.x * MOVE_SPEED * TICK_SECONDS
		origin[1] += direction.y * MOVE_SPEED * TICK_SECONDS
		_player_states[0]["origin64"] = origin
	_player_states[0]["move_state"] = {
		"in_air": false,
		"horizontal_speed": MOVE_SPEED if direction.length_squared() > 0.0 else 0.0,
		"crouched": Input.is_key_pressed(KEY_CTRL),
	}
	_player_states[0]["stance"] = HitboxBuilder.CROUCH if Input.is_key_pressed(KEY_CTRL) else HitboxBuilder.STAND


func _set_smoke_view(tick: int) -> void:
	var schedule: Dictionary = _scheduled_shots.get(tick, {})
	var selected_tick := tick
	var silent_entry: Dictionary = {}
	if not schedule.is_empty() and bool(schedule["silent"]):
		silent_entry = schedule
	else:
		for fire_tick in _scheduled_shots:
			var candidate: Dictionary = _scheduled_shots[fire_tick]
			if bool(candidate["silent"]) and tick >= int(fire_tick) - 8 and tick <= int(fire_tick) + 3:
				selected_tick = int(fire_tick)
				silent_entry = candidate
				break
	var target_slot := int(schedule.get("target_slot", silent_entry.get("target_slot", 1)))
	var target: Dictionary = _player_states[target_slot]
	var shooter: Dictionary = _player_states[0]
	var desired := _view_to_target(shooter, target, HitboxBuilder.STAND)
	var weapon_px := float(_weapon_state.get("px", 0.0))
	var weapon_py := float(_weapon_state.get("py", 0.0))
	var pitch := float(desired["pitch"]) - weapon_px
	var yaw := float(desired["yaw"]) - weapon_py
	var near_miss := not schedule.is_empty() and bool(schedule["near_miss"])
	if near_miss:
		pitch = _pitch_to_z(shooter, target, 72.5) - weapon_px
	if not silent_entry.is_empty():
		var fire_tick := selected_tick
		if tick < fire_tick:
			yaw -= 5.0
		elif tick > fire_tick:
			yaw -= 5.0
	shooter["view_pitch"] = pitch
	shooter["view_yaw"] = yaw


func _set_silent_idle_view() -> void:
	var shooter: Dictionary = _player_states[0]
	var target: Dictionary = _player_states[1]
	var aim := _view_to_target(shooter, target, HitboxBuilder.STAND)
	_silent_base_pitch = float(aim["pitch"]) - float(_weapon_state.get("px", 0.0))
	_silent_base_yaw = float(aim["yaw"]) - float(_weapon_state.get("py", 0.0)) - 5.0
	shooter["view_pitch"] = _silent_base_pitch
	shooter["view_yaw"] = _silent_base_yaw


func _set_silent_fire_view() -> void:
	var shooter: Dictionary = _player_states[0]
	var target: Dictionary = _player_states[1]
	var aim := _view_to_target(shooter, target, HitboxBuilder.STAND)
	shooter["view_pitch"] = float(aim["pitch"]) - float(_weapon_state.get("px", 0.0))
	shooter["view_yaw"] = float(aim["yaw"]) - float(_weapon_state.get("py", 0.0))


func _push_history(tick: int) -> void:
	for player in _player_states:
		_history.push_sample(int(player["slot"]), {
			"tick": tick,
			"origin64": player["origin64"],
			"yaw_deg": float(player["yaw_deg"]),
			"stance": int(player["stance"]),
			"alive": bool(player["alive"]),
		})


func _write_visibility(tick: int) -> void:
	if _writer == null or not _session_started or _session_closed:
		return
	for viewer in _player_states:
		var slot := int(viewer["slot"])
		var sent_mask := _visible_mask(slot)
		var sound_mask := _sound_mask(slot, sent_mask)
		var previous: Dictionary = _vis_state.get(slot, {})
		var keyframe := tick == 0 or previous.is_empty()
		if keyframe or sent_mask != int(previous.get("sent_mask", -1)) \
				or sound_mask != int(previous.get("sound_only_mask", -1)):
			_writer.write_vis({
				"viewer_slot": slot,
				"sent_mask": sent_mask,
				"sound_only_mask": sound_mask,
				"keyframe": keyframe,
			}, tick)
			_record_counts["vis"] += 1
			_vis_state[slot] = {"sent_mask": sent_mask, "sound_only_mask": sound_mask}


func _visible_mask(viewer_slot: int) -> int:
	var viewer: Dictionary = _player_states[viewer_slot]
	var mask := 1 << viewer_slot
	for target in _player_states:
		var target_slot := int(target["slot"])
		if target_slot == viewer_slot:
			continue
		if int(target["team"]) == int(viewer["team"]) or _line_of_sight(viewer, target):
			mask |= 1 << target_slot
	return mask


func _sound_mask(viewer_slot: int, sent_mask: int) -> int:
	var viewer: Dictionary = _player_states[viewer_slot]
	var sound_mask := 0
	for target in _player_states:
		var slot := int(target["slot"])
		if slot == viewer_slot or int(target["team"]) == int(viewer["team"]):
			continue
		if sent_mask & (1 << slot):
			continue
		if _distance(viewer["origin64"], target["origin64"]) <= 1000.0:
			sound_mask |= 1 << slot
	return sound_mask


func _line_of_sight(viewer: Dictionary, target: Dictionary) -> bool:
	var eye := _eye_position(viewer)
	var boxes: Array = HitboxBuilder.build_boxes_precise(
		target["origin64"],
		float(target["yaw_deg"]),
		int(target["stance"])
	)
	for box_id in [0, 1]:
		var center: PackedFloat64Array = boxes[box_id]["center64"]
		var ray := _normalize(PackedFloat64Array([
			center[0] - eye[0],
			center[1] - eye[1],
			center[2] - eye[2],
		]))
		var length := _distance(eye, center)
		if HitRegLogic._first_world_hit(eye, ray, length, _world_boxes) >= length - 0.5:
			return true
	return false


func _record_view_command(tick: int) -> void:
	if _writer == null or _session_closed or not bool(_evidence_config.get("ENABLE_AIM_KIN", false)):
		return
	var shooter: Dictionary = _player_states[0]
	var view_pitch := float(shooter["view_pitch"])
	var view_yaw := float(shooter["view_yaw"])
	_view_commands.append({
		"cmd_seq": _cmd_seq,
		"tick": tick,
		"player_slot": 0,
		"view_pitch": view_pitch,
		"view_yaw": view_yaw,
		"view_pitch_q": InputCommand.quantize_pitch(FrameAdapter.pitch_to_game_rad(view_pitch)),
		"view_yaw_q": InputCommand.quantize_yaw(FrameAdapter.yaw_to_game_rad(view_yaw)),
		"alive": bool(shooter["alive"]),
		"spectating": false,
		"repeated": false,
		"round_start": tick % 500 == 0,
		"move_state": HitRegLogic._snapshot_move_state(shooter["move_state"]),
	})
	_cmd_seq += 1


func _process_shot(tick: int, shot_spec: Dictionary) -> void:
	if _session_closed:
		return
	_shot_index += 1
	var shooter_state: Dictionary = _player_states[0]
	var weapon_name := str(_weapon_table_ids[_weapon_index])
	var expected_view_tick := float(tick) - _ping_ms * float(TICK_RATE) / 1000.0 - float(_interp_ticks)
	var claimed_view_tick := expected_view_tick
	if _backtrack_debug or bool(shot_spec.get("backtrack", false)):
		claimed_view_tick -= 5.0
	var shooter := {
		"slot": 0,
		"eye64": _eye_position(shooter_state),
		"weapon_id": weapon_name,
		"weapon_state": _weapon_state,
		"move_state": shooter_state["move_state"],
		"view_pitch": float(shooter_state["view_pitch"]),
		"view_yaw": float(shooter_state["view_yaw"]),
		"view_pitch_q": InputCommand.quantize_pitch(
			FrameAdapter.pitch_to_game_rad(float(shooter_state["view_pitch"]))
		),
		"view_yaw_q": InputCommand.quantize_yaw(
			FrameAdapter.yaw_to_game_rad(float(shooter_state["view_yaw"]))
		),
		"shot_index": _shot_index,
		"cmd_seq": _cmd_seq - 1,
		"claimed_view_tick": claimed_view_tick,
	}
	var visible: Dictionary = _vis_state.get(0, {"sent_mask": 0})
	var result: Dictionary = HitRegLogic.process_shot({
		"shooter": shooter,
		"history": _history,
		"rng": RngSource.GodotRng.new(_seed_for_shot(tick, _shot_index)),
		"tick_rate": int(TICK_RATE),
		"now": float(tick),
		"rtt_ms": _ping_ms,
		"interp_ticks": _interp_ticks,
		"world_boxes": _world_boxes,
		"teams": _teams,
		"sent_mask": int(visible["sent_mask"]),
	})
	if result.has("error"):
		_last_result = "SHOT ERROR"
		return
	_weapon_state = result["weapon_state"]
	_last_spread = float(result["spread_at_fire"])
	_last_rewind = result["rewind_decision"].duplicate(true)
	if _writer != null:
		_record_counts["rewind"] += 1
		if result.get("input_reject") != null:
			_record_counts["input_reject"] += 1
		_writer.write_shot_result(result, tick)
		for record in result["records"]:
			_record_counts["shot"] += 1
	if result["records"].is_empty():
		_last_result = "MISS"
	else:
		var record: Dictionary = result["records"][0]
		if int(record["outcome"]) == 0:
			_last_result = "HIT / %s / %s" % [
				_part_name(int(record["part"])),
				DamageRegionData.region_name(int(record["region_id"])),
			]
		else:
			_last_result = "NEAR / %.2f u" % float(record["closest_dist"])
	_add_shot_visual(result)
	if _writer != null and bool(_evidence_config.get("ENABLE_AIM_KIN", false)) \
			and not result["records"].is_empty():
		_pending_aim.append({
			"fire_tick": tick,
			"shot_index": _shot_index,
			"move_state": int(result["move_state"]),
			"spread_at_fire": _last_spread,
			"shooter_slot": 0,
		})


func _process_pending_aim(tick: int) -> void:
	if _writer == null or _session_closed or not bool(_evidence_config.get("ENABLE_AIM_KIN", false)):
		return
	var remaining: Array = []
	for pending in _pending_aim:
		if tick < int(pending["fire_tick"]) + 3:
			remaining.append(pending)
			continue
		var aim_params := AntiCheatParams.for_server_metadata(_server_metadata)
		var fields := AimKinLogic.compute(
			_view_commands,
			int(pending["fire_tick"]),
			float(pending["spread_at_fire"]),
			int(pending["move_state"]),
			int(pending["shot_index"]),
			aim_params
		)
		fields["shooter_slot"] = int(pending["shooter_slot"])
		_last_aim_kin = fields.duplicate(true)
		if _writer.write_aim_kin(fields, int(pending["fire_tick"])):
			_record_counts["aim_kin"] += 1
	_pending_aim = remaining


func _record_timeline_frame(tick: int) -> void:
	if _writer == null or _session_closed or not bool(_review_config.get("ENABLE_ANTICHEAT_REVIEW", false)):
		return
	var players: Array = []
	for player in _player_states:
		players.append({
			"slot": int(player["slot"]),
			"team": int(player["team"]),
			"alive": bool(player["alive"]),
			"origin64": player["origin64"].duplicate(),
			"yaw_deg": float(player["yaw_deg"]),
			"stance": int(player["stance"]),
			"view_pitch": float(player["view_pitch"]),
			"view_yaw": float(player["view_yaw"]),
			"teleported": false,
			"spectating": false,
			"in_menu": false,
			"map_area": "fp_range",
		})
	_timeline.append({
		"tick": tick,
		"round": int(tick / 500) + 1,
		"players": players,
		"sound_events": [],
	})


func _close_and_verify() -> Dictionary:
	if not bool(_evidence_config.get("ENABLE_EVIDENCE_LOG", false)):
		_verify_status = "EVIDENCE DISABLED"
		return {"ok": false, "error": "evidence_disabled"}
	if not _session_started or _writer == null:
		return {"ok": false, "error": "no evidence session"}
	if not _session_closed:
		_writer.close()
		_session_closed = true
	var data := FileAccess.get_file_as_bytes(_evidence_path)
	var expected_chain: PackedByteArray = _writer.final_chain_sha256()
	var reader = FpevReader.new(_evidence_config)
	var verification: Dictionary = reader.read_bytes(data, expected_chain)
	var jsonl: Dictionary = FpevJsonl.new(_evidence_config).export_bytes(data, expected_chain)
	var jsonl_file := FileAccess.open(_jsonl_path, FileAccess.WRITE)
	if jsonl_file != null:
		jsonl_file.store_string(str(jsonl["text"]))
		jsonl_file.close()
	var hits := 0
	var near_misses := 0
	var rewinds := 0
	var reason_one_rejects := 0
	var snapback_seen := false
	for record in verification["records"]:
		match int(record["type"]):
			1:
				if int(record["fields"]["outcome"]) == 0:
					hits += 1
				else:
					near_misses += 1
			3:
				if int(record["fields"]["reason"]) == 1:
					reason_one_rejects += 1
			4:
				pass
			5:
				rewinds += 1
			6:
				if int(record["flags"]) & 1:
					snapback_seen = true
	_verify_status = reader.chain_status(verification)
	print("Evidence verification: %s" % _verify_status)
	return {
		"ok": bool(verification["ok"]) and bool(jsonl["ok"]),
		"status": reader.chain_status(verification),
		"hit_count": hits,
		"near_miss_count": near_misses,
		"rewind_count": rewinds,
		"input_reject_reason1_count": reason_one_rejects,
		"shot_command_count": _unique_shot_command_count(verification["records"]),
		"snapback_seen": snapback_seen,
		"record_counts": _record_counts.duplicate(true),
		"file_size": data.size(),
	}


func _run_review() -> Dictionary:
	if not bool(_review_config.get("ENABLE_ANTICHEAT_REVIEW", false)):
		_review_status = "REVIEW DISABLED"
		return {"ok": false, "error": "review_disabled"}
	if not bool(_evidence_config.get("ENABLE_EVIDENCE_LOG", false)):
		_review_status = "EVIDENCE DISABLED"
		return {"ok": false, "error": "evidence_disabled"}
	if not _session_closed:
		var verified := _close_and_verify()
		if not bool(verified.get("ok", false)):
			return verified
	var reader = FpevReader.new(_evidence_config)
	var verification: Dictionary = reader.read_file(_evidence_path, _writer.final_chain_sha256())
	var report: Dictionary = UnsentAnalyzer.analyze(
		_match_id,
		_timeline,
		verification,
		[],
		_review_config,
		_server_metadata
	)
	var result: Dictionary = ReviewQueue.write_report(_review_path, report, _review_config)
	if bool(result["ok"]):
		_review_status = "REVIEW JSON READY"
	return result


func _seed_for_shot(tick: int, shot_index: int) -> int:
	var context := "%s:%d:%d" % [_match_id, tick, shot_index]
	var hash_context := HashingContext.new()
	hash_context.start(HashingContext.HASH_SHA256)
	hash_context.update(context.to_utf8_buffer())
	var digest := hash_context.finish()
	return int(digest.decode_u32(0))


func _sha256(data: PackedByteArray) -> PackedByteArray:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(data)
	return context.finish()


func _eye_position(player: Dictionary) -> PackedFloat64Array:
	var origin: PackedFloat64Array = player["origin64"].duplicate()
	origin[2] += HitboxBuilder.eye_height(int(player["stance"]))
	return origin


func _view_to_target(shooter: Dictionary, target: Dictionary, stance: int) -> Dictionary:
	var eye := _eye_position(shooter)
	var boxes: Array = HitboxBuilder.build_boxes_precise(
		target["origin64"],
		float(target["yaw_deg"]),
		stance
	)
	var point: PackedFloat64Array = boxes[0]["center64"]
	var dx := point[0] - eye[0]
	var dy := point[1] - eye[1]
	var dz := point[2] - eye[2]
	return {
		"pitch": -rad_to_deg(atan2(dz, sqrt(dx * dx + dy * dy))),
		"yaw": rad_to_deg(atan2(dy, dx)),
	}


func _pitch_to_z(shooter: Dictionary, target: Dictionary, height: float) -> float:
	var eye := _eye_position(shooter)
	var target_origin: PackedFloat64Array = target["origin64"]
	var dx := target_origin[0] - eye[0]
	var dy := target_origin[1] - eye[1]
	var dz := height - eye[2]
	return -rad_to_deg(atan2(dz, sqrt(dx * dx + dy * dy)))


func _distance(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var dx := a[0] - b[0]
	var dy := a[1] - b[1]
	var dz := a[2] - b[2]
	return sqrt(dx * dx + dy * dy + dz * dz)


func _normalize(v: PackedFloat64Array) -> PackedFloat64Array:
	var magnitude := sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
	if magnitude <= 0.0:
		return PackedFloat64Array([0.0, 0.0, 0.0])
	return PackedFloat64Array([v[0] / magnitude, v[1] / magnitude, v[2] / magnitude])


func _part_name(part_id: int) -> String:
	var names := ["head", "chest", "stomach", "arm", "leg"]
	return names[clampi(part_id, 0, names.size() - 1)]


func _build_materials() -> void:
	var floor_material := StandardMaterial3D.new()
	floor_material.albedo_color = Color("#202a28")
	floor_material.roughness = 0.92
	_materials["floor"] = floor_material
	_materials["wall"] = _solid_material(Color("#59635c"))
	_materials["grid"] = _line_material(Color("#71827a"))
	_materials["player"] = _line_material(GAME_PAPER)
	_materials["ghost"] = _line_material(Color("#ff5f58", 0.40), true)
	_materials["ray"] = _line_material(GAME_ACID)
	_materials["hit"] = _solid_material(GAME_ACID)
	_materials["near"] = _solid_material(GAME_ORANGE)


func _solid_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.8
	material.metallic = 0.08
	return material


func _line_material(color: Color, alpha: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.vertex_color_use_as_albedo = false
	if alpha:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = false
	return material


func _build_world() -> void:
	var floor := MeshInstance3D.new()
	floor.name = "RangeFloor"
	var plane := PlaneMesh.new()
	plane.size = Vector2(2400.0, 1800.0)
	floor.mesh = plane
	floor.material_override = _materials["floor"]
	floor.position.y = 0.0
	_world_root.add_child(floor)
	_build_grid()
	_world_boxes = [
		{"min64": PackedFloat64Array([380.0, -260.0, 0.0]), "max64": PackedFloat64Array([405.0, -55.0, 132.0])},
		{"min64": PackedFloat64Array([650.0, 250.0, 0.0]), "max64": PackedFloat64Array([680.0, 440.0, 105.0])},
		{"min64": PackedFloat64Array([260.0, 285.0, 0.0]), "max64": PackedFloat64Array([340.0, 315.0, 74.0])},
	]
	for index in range(_world_boxes.size()):
		_add_world_box(_world_boxes[index], index)
	var environment := WorldEnvironment.new()
	var environment_data := Environment.new()
	environment_data.background_mode = Environment.BG_COLOR
	environment_data.background_color = Color("#111a19")
	environment_data.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment_data.ambient_light_color = Color("#91a39a")
	environment_data.ambient_light_energy = 0.34
	environment.environment = environment_data
	_world_root.add_child(environment)


func _build_grid() -> void:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, _materials["grid"])
	for x in range(-600, 1601, 100):
		mesh.surface_add_vertex(_game_to_godot(PackedFloat64Array([float(x), -800.0, 0.03])))
		mesh.surface_add_vertex(_game_to_godot(PackedFloat64Array([float(x), 900.0, 0.03])))
	for y in range(-800, 901, 100):
		mesh.surface_add_vertex(_game_to_godot(PackedFloat64Array([-600.0, float(y), 0.03])))
		mesh.surface_add_vertex(_game_to_godot(PackedFloat64Array([1600.0, float(y), 0.03])))
	mesh.surface_end()
	var grid_instance := MeshInstance3D.new()
	grid_instance.name = "RangeGrid"
	grid_instance.mesh = mesh
	_world_root.add_child(grid_instance)


func _add_world_box(box: Dictionary, index: int) -> void:
	var minimum: PackedFloat64Array = box["min64"]
	var maximum: PackedFloat64Array = box["max64"]
	var size_x := maximum[0] - minimum[0]
	var size_y := maximum[1] - minimum[1]
	var size_z := maximum[2] - minimum[2]
	var center := PackedFloat64Array([
		(minimum[0] + maximum[0]) * 0.5,
		(minimum[1] + maximum[1]) * 0.5,
		(minimum[2] + maximum[2]) * 0.5,
	])
	var instance := MeshInstance3D.new()
	instance.name = "WorldBlock%d" % index
	var mesh := BoxMesh.new()
	mesh.size = Vector3(size_x, size_z, size_y)
	instance.mesh = mesh
	instance.material_override = _materials["wall"]
	instance.position = _game_to_godot(center)
	_world_root.add_child(instance)


func _build_player_visuals() -> void:
	for slot in range(1, PLAYER_COUNT):
		var instance := MeshInstance3D.new()
		instance.name = "PlayerBoxes_%d" % slot
		_world_root.add_child(instance)
		_player_visuals[slot] = instance
	_update_player_visuals()


func _update_player_visuals() -> void:
	if _player_states.is_empty():
		return
	for slot in range(1, PLAYER_COUNT):
		if not _player_visuals.has(slot):
			continue
		var player: Dictionary = _player_states[slot]
		var mesh := ImmediateMesh.new()
		mesh.surface_begin(Mesh.PRIMITIVE_LINES, _materials.get("player"))
		var boxes: Array = HitboxBuilder.build_boxes_precise(
			player["origin64"],
			float(player["yaw_deg"]),
			int(player["stance"])
		)
		for box in boxes:
			_append_box_edges(mesh, box)
		mesh.surface_end()
		var instance: MeshInstance3D = _player_visuals[slot]
		instance.mesh = mesh
		instance.visible = bool(player["alive"])


func _append_box_edges(mesh: ImmediateMesh, box: Dictionary) -> void:
	var center: PackedFloat64Array = box["center64"]
	var half: PackedFloat64Array = box["half64"]
	var axes: Array = box["axes64"]
	var corners: Array = []
	for bits in range(8):
		var sx := -1.0 if bits & 1 == 0 else 1.0
		var sy := -1.0 if bits & 2 == 0 else 1.0
		var sz := -1.0 if bits & 4 == 0 else 1.0
		corners.append(PackedFloat64Array([
			center[0] + axes[0][0] * half[0] * sx + axes[1][0] * half[1] * sy + axes[2][0] * half[2] * sz,
			center[1] + axes[0][1] * half[0] * sx + axes[1][1] * half[1] * sy + axes[2][1] * half[2] * sz,
			center[2] + axes[0][2] * half[0] * sx + axes[1][2] * half[1] * sy + axes[2][2] * half[2] * sz,
		]))
	for edge in [
		[0, 1], [0, 2], [0, 4], [1, 3], [1, 5], [2, 3],
		[2, 6], [3, 7], [4, 5], [4, 6], [5, 7], [6, 7],
	]:
		mesh.surface_add_vertex(_game_to_godot(corners[edge[0]]))
		mesh.surface_add_vertex(_game_to_godot(corners[edge[1]]))


func _game_to_godot(point: PackedFloat64Array) -> Vector3:
	return Vector3(
		FrameAdapter.to_game_x(float(point[0])),
		FrameAdapter.to_game_y(float(point[2])),
		FrameAdapter.to_game_z(float(point[1]))
	)


func _update_camera() -> void:
	if _camera == null or _player_states.is_empty():
		return
	var shooter: Dictionary = _player_states[0]
	var eye := _eye_position(shooter)
	_camera.position = _game_to_godot(eye)
	var pitch_q := InputCommand.quantize_pitch(
		FrameAdapter.pitch_to_game_rad(float(shooter["view_pitch"]))
	)
	var yaw_q := InputCommand.quantize_yaw(
		FrameAdapter.yaw_to_game_rad(float(shooter["view_yaw"]))
	)
	var direction := HitRegLogic.shot_direction(
		FrameAdapter.pitch_to_spec_deg(InputCommand.dequantize_pitch(pitch_q)),
		FrameAdapter.yaw_to_spec_deg(InputCommand.dequantize_yaw(yaw_q)),
		0.0,
		0.0
	)
	var godot_direction := Vector3(
		FrameAdapter.to_game_x(direction[0]),
		FrameAdapter.to_game_y(direction[2]),
		FrameAdapter.to_game_z(direction[1])
	)
	_camera.look_at(_camera.position + godot_direction * 100.0, Vector3.UP)


func _update_hud() -> void:
	if _hud == null:
		return
	var rewind := float(_last_rewind.get("rewind_ticks_float", 0.0))
	var reason := str(_reason_name(int(_last_rewind.get("reason", 0))))
	var flags := str(_rewind_flag_names(int(_last_rewind.get("flags", 0))))
	var aim_flags := str(_aim_flag_names(int(_last_aim_kin.get("flags", 0))))
	_hud.update_state({
		"last_result": _last_result,
		"ping_ms": int(_ping_ms),
		"interp_ticks": _interp_ticks,
		"rewind_ticks": rewind,
		"rewind_reason": reason,
		"rewind_flags": flags,
		"spread_at_fire": _last_spread,
		"aim_kin_flags": aim_flags,
		"record_counts": _record_counts,
		"verify_status": _verify_status,
		"review_status": _review_status,
		"weapon_label": "RIFLE %02d" % (_weapon_index + 1),
		"debug_modes": "BACKTRACK %s  //  SNAPBACK %s"
			% ["ON" if _backtrack_debug else "OFF", "ON" if _silent_aim_debug else "OFF"],
	})


func _add_shot_visual(result: Dictionary) -> void:
	if _smoke_mode or _world_root == null:
		return
	var effect := Node3D.new()
	effect.name = "ShotVisual_%d" % int(result["shot_index"])
	_world_root.add_child(effect)
	var eye: PackedFloat64Array = _eye_position(_player_states[0])
	var direction: PackedFloat64Array = result["shot_direction"]
	var segment_end := PackedFloat64Array([
		eye[0] + direction[0] * float(result["segment_length"]),
		eye[1] + direction[1] * float(result["segment_length"]),
		eye[2] + direction[2] * float(result["segment_length"]),
	])
	var records: Array = result["records"]
	if not records.is_empty() and int(records[0]["outcome"]) == 0:
		segment_end = records[0]["ray_point"]
	var ray_material := _fade_material(GAME_ACID)
	effect.add_child(_line_instance(
		eye,
		segment_end,
		ray_material,
		"ShotSegment"
	))
	var fade_materials: Array = [ray_material]
	for record in records:
		if int(record["outcome"]) == 0:
			var hit_material := _fade_material(GAME_ACID)
			effect.add_child(_marker_instance(record["ray_point"], 5.0, hit_material, "HitMarker"))
			fade_materials.append(hit_material)
		else:
			var near_material := _fade_material(GAME_ORANGE)
			effect.add_child(_marker_instance(record["box_point"], 4.0, near_material, "NearMarker"))
			effect.add_child(_line_instance(
				record["box_point"],
				record["ray_point"],
				_fade_material(Color(GAME_ORANGE, 0.6)),
				"NearMissGap"
			))
			fade_materials.append(near_material)
	var chosen_tick := float(result["rewind_decision"]["chosen_view_tick"])
	for slot in range(1, PLAYER_COUNT):
		var sample: Dictionary = _history.sample_at(slot, chosen_tick)
		if bool(sample.get("missing_history", true)) and int(sample.get("tick", -1)) < 0:
			continue
		var ghost_boxes: Array = HitboxBuilder.build_boxes_precise(
			sample["origin64"],
			float(sample["yaw_deg"]),
			int(sample["stance"])
		)
		var ghost_material := _fade_material(Color("#ff5f58", 0.40))
		var ghost_mesh := ImmediateMesh.new()
		ghost_mesh.surface_begin(Mesh.PRIMITIVE_LINES, ghost_material)
		for box in ghost_boxes:
			_append_box_edges(ghost_mesh, box)
		ghost_mesh.surface_end()
		var ghost_instance := MeshInstance3D.new()
		ghost_instance.name = "RewindGhost_%d" % slot
		ghost_instance.mesh = ghost_mesh
		effect.add_child(ghost_instance)
		fade_materials.append(ghost_material)
	_shot_visuals.append({"node": effect, "age": 0.0, "materials": fade_materials})


func _line_instance(
		start64: PackedFloat64Array,
		end64: PackedFloat64Array,
		material: StandardMaterial3D,
		instance_name: String
	) -> MeshInstance3D:
	var mesh := ImmediateMesh.new()
	mesh.surface_begin(Mesh.PRIMITIVE_LINES, material)
	mesh.surface_add_vertex(_game_to_godot(start64))
	mesh.surface_add_vertex(_game_to_godot(end64))
	mesh.surface_end()
	var instance := MeshInstance3D.new()
	instance.name = instance_name
	instance.mesh = mesh
	return instance


func _marker_instance(
		position64: PackedFloat64Array,
		radius: float,
		material: StandardMaterial3D,
		instance_name: String
	) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	var instance := MeshInstance3D.new()
	instance.name = instance_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = _game_to_godot(position64)
	return instance


func _fade_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color
	return material


func _update_shot_visuals(delta: float) -> void:
	var active: Array = []
	for shot in _shot_visuals:
		shot["age"] = float(shot["age"]) + delta
		var alpha := clampf(1.0 - float(shot["age"]) / 3.0, 0.0, 1.0)
		if alpha <= 0.0:
			if is_instance_valid(shot["node"]):
				shot["node"].queue_free()
			continue
		for material in shot["materials"]:
			var color: Color = material.albedo_color
			color.a = minf(color.a, alpha)
			material.albedo_color = color
		active.append(shot)
	_shot_visuals = active


func _clear_shot_visuals() -> void:
	for shot in _shot_visuals:
		if is_instance_valid(shot["node"]):
			shot["node"].queue_free()
	_shot_visuals.clear()


func _reason_name(reason: int) -> String:
	var names := [
		"none", "claim out of window", "rewind cap", "claim + cap",
		"negative rewind", "claim + negative", "missing history",
	]
	return names[clampi(reason, 0, names.size() - 1)]


func _rewind_flag_names(flags: int) -> String:
	var names: Array[String] = []
	if flags & 1:
		names.append("CLAMPED")
	if flags & 2:
		names.append("CLAIM")
	if flags & 16:
		names.append("NEGATIVE")
	if flags & 32:
		names.append("MISSING")
	return " / ".join(names) if not names.is_empty() else "none"


func _aim_flag_names(flags: int) -> String:
	var names: Array[String] = []
	if flags & 1:
		names.append("SNAPBACK")
	if flags & 2:
		names.append("FLICK_STOP")
	return " / ".join(names) if not names.is_empty() else "none"
