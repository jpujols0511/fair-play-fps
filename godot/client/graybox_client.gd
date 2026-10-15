extends Node3D
## Minimal rendered client for the authoritative LAN arena.
##
## This process sends only Protocol.encode_intent packets. The camera rig's
## world position is assigned only in _apply_snapshot(), never from local
## input. There is deliberately no prediction until M2 defines reconciliation.

const Kernel = preload("res://kernel/fairplay_kernel.gd")
const Protocol = preload("res://net/protocol.gd")
const WORLD_SCALE := 512.0
const HANDSHAKE_TIMEOUT_MSEC := 10000

var _player_id := "player"
var _token := ""
var _host := "127.0.0.1"
var _port := 47911
var _tick_rate := Kernel.TICK_RATE
var _test_pattern := ""
var _exit_after_snapshots := 0
var _report_path := ""

var _session: PacketPeerDTLS
var _sequence := 0
var _tick_accumulator := 0.0
var _handshake_deadline := 0
var _connected_once := false
var _hello_sent := false
var _fire_queued := false
var _yaw := 0.0
var _pitch := 0.0
var _snapshots := 0
var _sent := 0
var _last_confirmed := {}
var _camera_rig: Node3D
var _camera: Camera3D
var _status: Label


func _ready() -> void:
	_build_graybox()
	var args := _parse_args(OS.get_cmdline_user_args())
	_player_id = args.get("player", _player_id)
	_token = args.get("token", "")
	_host = args.get("host", _host)
	_port = int(args.get("port", str(_port)))
	_tick_rate = int(args.get("tick-rate", str(_tick_rate)))
	_test_pattern = args.get("test-pattern", "")
	_exit_after_snapshots = int(args.get("exit-after-snapshots", "0"))
	_report_path = args.get("report", "")
	if not Kernel.SUPPORTED_TICK_RATES.has(_tick_rate):
		_finish_error("tick rate must be 64 or 128")
		return
	if _token.length() != Protocol.TOKEN_LEN:
		_finish_error("a 64-character match token is required")
		return
	var cert := X509Certificate.new()
	if cert.load(args.get("cert", "")) != OK:
		_finish_error("cannot load server certificate")
		return
	var udp := PacketPeerUDP.new()
	if udp.connect_to_host(_host, _port) != OK:
		_finish_error("cannot open UDP peer")
		return
	_session = PacketPeerDTLS.new()
	if _session.connect_to_peer(udp, Protocol.SERVER_NAME, TLSOptions.client(cert)) != OK:
		_finish_error("cannot start DTLS handshake")
		return
	_handshake_deadline = Time.get_ticks_msec() + HANDSHAKE_TIMEOUT_MSEC
	if not OS.has_feature("headless") and _test_pattern.is_empty():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_set_status("CONNECTING", "Waiting for authenticated DTLS session")


func _process(delta: float) -> void:
	if _session == null:
		return
	_session.poll()
	var connection_status := _session.get_status()
	if connection_status == PacketPeerDTLS.STATUS_HANDSHAKING:
		if Time.get_ticks_msec() >= _handshake_deadline:
			_finish_error("DTLS handshake timed out")
		return
	if connection_status != PacketPeerDTLS.STATUS_CONNECTED:
		if _connected_once:
			_finish(0)
		elif Time.get_ticks_msec() >= _handshake_deadline:
			_finish_error("DTLS handshake failed")
		return
	_connected_once = true
	if not _hello_sent:
		_session.put_packet(Protocol.encode_hello(_player_id, _token))
		_hello_sent = true
		_set_status("AUTHENTICATING", "Identity: %s" % _player_id)
	_receive_snapshots()
	_tick_accumulator += delta
	var tick_seconds := 1.0 / float(_tick_rate)
	while _tick_accumulator >= tick_seconds:
		_tick_accumulator -= tick_seconds
		_send_intent()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_fire_queued = true
		elif event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.0025
		_pitch = clampf(_pitch - event.relative.y * 0.0025, -1.45, 1.45)
		_camera_rig.rotation.y = _yaw
		_camera.rotation.x = _pitch


func _send_intent() -> void:
	var move := Vector2.ZERO
	if _test_pattern == "forward":
		move = Vector2(0.0, -1.0)
	elif _test_pattern == "strafe":
		move = Vector2(1.0, 0.0)
	else:
		var side := Input.get_axis("move_left", "move_right")
		var forward_amount := Input.get_axis("move_back", "move_forward")
		var forward := Vector2(-sin(_yaw), -cos(_yaw))
		var right := Vector2(cos(_yaw), -sin(_yaw))
		move = (right * side + forward * forward_amount).limit_length(1.0)
	var command := Kernel.command(
		_sequence,
		int(round(move.x * Kernel.INPUT_SCALE)),
		int(round(move.y * Kernel.INPUT_SCALE)),
		int(round(fposmod(rad_to_deg(_yaw), 360.0) * 1000.0)),
		_fire_queued,
		_last_confirmed.get("tick", -1),
	)
	_session.put_packet(Protocol.encode_intent(_player_id, command))
	_fire_queued = false
	_sequence += 1
	_sent += 1


func _receive_snapshots() -> void:
	while _session.get_available_packet_count() > 0:
		var snapshot := Protocol.decode_snapshot(_session.get_packet())
		if snapshot.is_empty():
			continue
		_apply_snapshot(snapshot)
		if _exit_after_snapshots > 0 and _snapshots >= _exit_after_snapshots:
			_finish(0)
			return


func _apply_snapshot(snapshot: Dictionary) -> void:
	_last_confirmed = snapshot
	_snapshots += 1
	# This is the only world-position write for the local player.
	_camera_rig.position = Vector3(
		float(snapshot["x"]) / WORLD_SCALE,
		1.65,
		float(snapshot["y"]) / WORLD_SCALE,
	)
	_set_status(
		"SERVER CONFIRMED",
		"%s  |  tick %d  |  sequence %d  |  ammo %d\nposition %.2f, %.2f  |  %d Hz  |  DTLS" % [
			_player_id,
			snapshot["tick"],
			snapshot["last_sequence"],
			snapshot["ammunition"],
			_camera_rig.position.x,
			_camera_rig.position.z,
			_tick_rate,
		],
	)


func _build_graybox() -> void:
	var environment_node := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("18202b")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("b8c5d6")
	environment.ambient_light_energy = 0.55
	environment_node.environment = environment
	add_child(environment_node)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)

	_add_box("Floor", Vector3(24.0, 0.25, 24.0), Vector3(0.0, -0.125, 0.0), Color("66717f"))
	_add_box("NorthWall", Vector3(24.0, 3.0, 0.4), Vector3(0.0, 1.5, -12.0), Color("394552"))
	_add_box("SouthWall", Vector3(24.0, 3.0, 0.4), Vector3(0.0, 1.5, 12.0), Color("394552"))
	_add_box("WestWall", Vector3(0.4, 3.0, 24.0), Vector3(-12.0, 1.5, 0.0), Color("394552"))
	_add_box("EastWall", Vector3(0.4, 3.0, 24.0), Vector3(12.0, 1.5, 0.0), Color("394552"))
	_add_box("CenterCover", Vector3(3.0, 2.0, 1.5), Vector3(0.0, 1.0, -3.0), Color("a66b45"))
	_add_box("LaneCover", Vector3(1.5, 1.2, 4.0), Vector3(5.0, 0.6, 3.0), Color("536a78"))

	_camera_rig = Node3D.new()
	_camera_rig.name = "ServerConfirmedPlayer"
	_camera_rig.position = Vector3(0.0, 1.65, 6.0)
	add_child(_camera_rig)
	_camera = Camera3D.new()
	_camera.current = true
	_camera.fov = 82.0
	_camera_rig.add_child(_camera)

	var hud := CanvasLayer.new()
	add_child(hud)
	var shade := ColorRect.new()
	shade.color = Color(0.02, 0.03, 0.05, 0.72)
	shade.position = Vector2(16.0, 16.0)
	shade.size = Vector2(440.0, 76.0)
	hud.add_child(shade)
	_status = Label.new()
	_status.position = Vector2(30.0, 26.0)
	_status.add_theme_font_size_override("font_size", 16)
	hud.add_child(_status)
	var crosshair := Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 28)
	crosshair.set_anchors_preset(Control.PRESET_CENTER)
	crosshair.position = Vector2(-9.0, -18.0)
	hud.add_child(crosshair)
	var contract := Label.new()
	contract.text = "INPUT INTENT ONLY  •  POSITION FROM SERVER SNAPSHOTS"
	contract.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	contract.set_anchors_preset(Control.PRESET_CENTER_TOP)
	contract.position = Vector2(-290.0, 18.0)
	contract.size = Vector2(580.0, 30.0)
	contract.add_theme_color_override("font_color", Color("9ed8ff"))
	hud.add_child(contract)


func _add_box(label: String, size: Vector3, at: Vector3, color: Color) -> void:
	var body := StaticBody3D.new()
	body.name = label
	body.position = at
	var mesh_instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.85
	mesh.material = material
	mesh_instance.mesh = mesh
	body.add_child(mesh_instance)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	add_child(body)


func _set_status(title: String, detail: String) -> void:
	_status.text = "%s\n%s" % [title, detail]


func _finish_error(message: String) -> void:
	_set_status("ERROR", message)
	_finish(1, message)


func _finish(code: int, error := "") -> void:
	var report := {
		"client": _player_id,
		"tick_rate": _tick_rate,
		"transport": "DTLS",
		"authority": "server_snapshots_only",
		"world_scale": WORLD_SCALE,
		"sent_intents": _sent,
		"snapshots": _snapshots,
		"last_confirmed": _last_confirmed,
		"render_position": {
			"x": _camera_rig.position.x,
			"z": _camera_rig.position.z,
		},
	}
	if not error.is_empty():
		report["error"] = error
	if not _report_path.is_empty():
		var file := FileAccess.open(_report_path, FileAccess.WRITE)
		if file:
			file.store_string(JSON.stringify(report, "  ", true) + "\n")
	print(JSON.stringify(report, "", true))
	get_tree().quit(code)


func _parse_args(user_args: PackedStringArray) -> Dictionary:
	var parsed := {}
	for i in range(0, user_args.size() - 1, 2):
		if user_args[i].begins_with("--"):
			parsed[user_args[i].substr(2)] = user_args[i + 1]
	return parsed
