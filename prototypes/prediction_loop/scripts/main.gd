extends Node3D
## Playable view of the prediction loop. main.gd owns the tick: _physics_process (128 Hz)
## reads input and calls Session.tick_once(), which runs the fixed order
## FakeNet -> FakeServer -> Client predict -> Client reconcile -> smoothing/HUD.
## Nothing here depends on Godot's node order.
##   RED capsule   = server position
##   BLUE capsule  = client predicted position
##   GREEN capsule = the smoothed visual (what the camera follows)

const SENSITIVITY := 0.0022
const PINGS := [0.0, 40.0, 80.0, 150.0, 250.0]
const LOSSES := [0.0, 0.02, 0.05, 0.10]

var session: Session
var netclient: NetClient          # the HUD reads from this (crosshair via snapshot_received)
var crosshair: Control            # Game Builder's crosshair.gd, symlinked, driven by REAL snapshot fields
var ping_i := 2
var loss_i := 1
var jitter := false      # off by default; J turns it on for the S4 playtest
var yaw := 0.0
var pitch := 0.0
var jump_pulse := false
var chase := false
var culling := true           # V: server-side visibility culling on/off
var show_true := true         # X: thin true-position ghosts of the remote players
var remote_count := 6         # 0 key: toggle remotes on/off
var remote_caps: Array = []
var remote_ghosts: Array = []
var remote_labels: Array = []     # 'sent' / 'culled' per remote (V toggles culling itself)
var corr_ticks: Array = []
var last_corr_total := 0
var status := ""
var green: MeshInstance3D
var red: MeshInstance3D
var blue: MeshInstance3D
var camera: Camera3D
var hud: Label


func _ready() -> void:
	Engine.physics_ticks_per_second = int(Movement.TICK_RATE)
	var uargs := OS.get_cmdline_user_args()
	if "--server" in uargs or "--client" in uargs:
		# process roles for real networking (Phase 6): the demo below is the in-process version
		set_process(false)
		set_physics_process(false)
		set_process_unhandled_input(false)
		if "--server" in uargs:
			var sv := ServerMain.new()
			add_child(sv)
			sv.setup(uargs)
		else:
			var cl := ClientMain.new()
			add_child(cl)
			cl.setup(uargs)
		return
	_build_world()
	_new_session(1)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _new_session(seed_value: int) -> void:
	session = Session.new(seed_value, PINGS[ping_i], LOSSES[loss_i], jitter, false, true)
	corr_ticks.clear()
	last_corr_total = 0
	for r in RemotePath.make_set(remote_count):
		session.add_remote(r)
	if remote_count > 0:
		# two stand-ins behind the tall box for the culling overlay: an enemy (culled) and a teammate (always sent)
		session.add_remote(RemotePath.make_static(11, 400.0, 0.0, false, 2))
		session.add_remote(RemotePath.make_static(12, 400.0, 40.0, false, 1))
	session.server.vis_enabled = culling
	session.server.vis_rtt_ms = PINGS[ping_i]
	if netclient != null:
		netclient.queue_free()
	netclient = NetClient.new()
	add_child(netclient)
	netclient.adopt(session.client)
	if crosshair != null:
		netclient.snapshot_received.connect(crosshair._on_snapshot)


func _capsule(color: Color, alpha: float) -> MeshInstance3D:
	var m := CapsuleMesh.new()
	m.radius = 16.0
	m.height = 72.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	if alpha < 1.0:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	add_child(mi)
	return mi


func _box(min_x: float, min_z: float, max_x: float, max_z: float, top: float, color: Color) -> void:
	var bm := BoxMesh.new()
	bm.size = Vector3(max_x - min_x, top, max_z - min_z)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.material_override = mat
	mi.position = Vector3((min_x + max_x) / 2.0, top / 2.0, (min_z + max_z) / 2.0)
	add_child(mi)


func _build_world() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.55, 0.7, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	add_child(sun)

	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(60000.0, 60000.0)
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 uv = wp.xz / 64.0;
	vec2 g = abs(fract(uv - 0.5) - 0.5) / fwidth(uv);
	float l = 1.0 - min(min(g.x, g.y), 1.0);
	ALBEDO = mix(vec3(0.75), vec3(0.15), l);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	floor_node.material_override = mat
	add_child(floor_node)

	for b: PackedFloat64Array in Movement.default_world():
		_box(b[0], b[1], b[2], b[3], b[4], Color(0.55, 0.5, 0.45) if b[4] > 20.0 else Color(0.8, 0.7, 0.3))

	for i in Snapshot.MAX_SLOTS:
		var rc := _capsule(Color(1.0, 0.6, 0.1), 1.0)
		rc.visible = false
		remote_caps.append(rc)
		var rg := _capsule(Color(1.0, 1.0, 1.0), 0.18)
		rg.visible = false
		remote_ghosts.append(rg)
		var lb := Label3D.new()
		lb.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lb.no_depth_test = true
		lb.pixel_size = 0.35
		lb.position = Vector3(0.0, 56.0, 0.0)
		rg.add_child(lb)
		remote_labels.append(lb)
	green = _capsule(Color(0.2, 0.85, 0.3), 1.0)
	red = _capsule(Color(1.0, 0.15, 0.15), 0.35)
	blue = _capsule(Color(0.2, 0.4, 1.0), 0.35)
	camera = Camera3D.new()
	camera.near = 1.0
	camera.far = 80000.0
	camera.fov = 90.0
	add_child(camera)

	var layer := CanvasLayer.new()
	crosshair = load("res://scripts/hud/crosshair.gd").new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(crosshair)
	hud = Label.new()
	hud.position = Vector2(16.0, 12.0)
	hud.add_theme_font_size_override("font_size", 18)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	add_child(layer)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * SENSITIVITY
		pitch = clampf(pitch - event.relative.y * SENSITIVITY, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: jump_pulse = true
			KEY_BRACKETLEFT: _set_ping(-1)
			KEY_BRACKETRIGHT: _set_ping(1)
			KEY_MINUS: _set_loss(-1)
			KEY_EQUAL: _set_loss(1)
			KEY_J:
				jitter = not jitter
				_apply_net()
			KEY_T: chase = not chase
			KEY_2: _set_interp(2.0)
			KEY_3: _set_interp(3.0)
			KEY_4: _set_interp(4.0)
			KEY_X: show_true = not show_true
			KEY_V:
				culling = not culling
				session.server.vis_enabled = culling
				status = "culling %s" % ("ON: hidden enemies are not sent" if culling else "OFF: everyone is sent")
			KEY_0:
				remote_count = 0 if remote_count > 0 else 6
				_new_session(session.seed_value + 1)
			KEY_K:
				var st := session.server.state
				session.server.teleport(st.pos_x + 200.0, 0.0, st.pos_z + 200.0, true)
				status = "server teleport (flagged): client should snap"
			KEY_G:
				var st2 := session.server.state
				session.server.teleport(st2.pos_x + 6.0, st2.pos_y, st2.pos_z, false, true)
				status = "server shove 6 units: client should fade ~100 ms"
			KEY_L: _save_recording()
			KEY_R:
				_new_session(session.seed_value + 1)
				status = "reset (new seed %d)" % session.seed_value
			KEY_ESCAPE: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			jump_pulse = true
		elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Capsule follows the hull height (72.0 standing, 36.0 ducked).
func _place(mi: MeshInstance3D, feet: Vector3, st: PlayerState) -> void:
	var h := Movement.hull_height(st)
	(mi.mesh as CapsuleMesh).height = h
	mi.position = feet + Vector3(0.0, h / 2.0, 0.0)


func _set_interp(ticks: float) -> void:
	NetConfig.INTERP_TICKS = ticks
	status = "interpolation delay %.0f ticks = %.3f ms" % [ticks, ticks * 1000.0 / Movement.TICK_RATE]


func _set_ping(d: int) -> void:
	ping_i = clampi(ping_i + d, 0, PINGS.size() - 1)
	_apply_net()


func _set_loss(d: int) -> void:
	loss_i = clampi(loss_i + d, 0, LOSSES.size() - 1)
	_apply_net()


func _apply_net() -> void:
	session.apply_config(PINGS[ping_i], LOSSES[loss_i], jitter)


func _save_recording() -> void:
	var d := Recorder.to_dict(session)
	var path := ProjectSettings.globalize_path("res://recordings/live_%d.json" % Time.get_unix_time_from_system())
	status = "saved %s" % path.get_file() if Recorder.save(path, d) else "save failed"
	var csv_path := path.replace(".json", ".csv")
	var f := FileAccess.open(csv_path, FileAccess.WRITE)
	if f:
		f.store_string("\n".join(session.csv))


## main.gd owns the tick. One call = one 128 Hz tick = one InputCmd.
func _physics_process(_delta: float) -> void:
	var buttons := 0
	if Input.is_key_pressed(KEY_W): buttons |= InputCmd.BTN_FORWARD
	if Input.is_key_pressed(KEY_S): buttons |= InputCmd.BTN_BACK
	if Input.is_key_pressed(KEY_A): buttons |= InputCmd.BTN_LEFT
	if Input.is_key_pressed(KEY_D): buttons |= InputCmd.BTN_RIGHT
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C): buttons |= InputCmd.BTN_DUCK
	if jump_pulse or Input.is_key_pressed(KEY_SPACE): buttons |= InputCmd.BTN_JUMP
	jump_pulse = false
	session.tick_once(buttons, InputCmd.quantize_yaw(yaw), InputCmd.quantize_pitch(pitch))
	if session.client.corrections != last_corr_total:
		last_corr_total = session.client.corrections
		corr_ticks.append(session.tick)
	while not corr_ticks.is_empty() and corr_ticks[0] < session.tick - int(Movement.TICK_RATE):
		corr_ticks.pop_front()


func _process(_delta: float) -> void:
	var c := session.client
	var sv := session.server.state
	var cp := c.predicted
	_place(green, c.visual, cp)
	_place(blue, Vector3(cp.pos_x, cp.pos_y, cp.pos_z), cp)
	_place(red, Vector3(sv.pos_x, sv.pos_y, sv.pos_z), sv)
	var look := Basis.from_euler(Vector3(pitch, yaw, 0.0))
	if chase:
		camera.position = c.visual + Vector3(0.0, 120.0, 0.0) + look.z * 260.0
	else:
		camera.position = c.visual + Vector3(0.0, Movement.eye_height(cp), 0.0)
	camera.rotation = Vector3(pitch, yaw, 0.0)
	green.visible = chase
	for slot in Snapshot.MAX_SLOTS:
		var rc: MeshInstance3D = remote_caps[slot]
		var b: InterpBuffer = c.remotes[slot]
		rc.visible = c.remote_visible[slot] == 1
		if rc.visible:
			var hh := Movement.STAND_BODY - (Movement.STAND_BODY - Movement.DUCK_BODY) * b.out_duck      # 72.0 - 36.0 * out_duck: the smooth fraction, not the stance bit
			(rc.mesh as CapsuleMesh).height = hh
			rc.position = Vector3(b.out_x, b.out_y + hh / 2.0, b.out_z)
		(remote_ghosts[slot] as MeshInstance3D).visible = false
	if show_true:
		for r: RemotePath in session.server.remotes:
			if r.present(session.tick):
				var tp := r.exact_at(float(session.tick))
				var g: MeshInstance3D = remote_ghosts[r.slot]
				g.visible = true
				g.position = Vector3(tp[0], tp[1] + Movement.STAND_BODY / 2.0, tp[2])
				var mask := session.server.sent_mask_for(0, session.tick - 1)
				var label := "?" if mask < 0 else ("sent" if (mask >> r.slot) & 1 == 1 else "CULLED")     # -1 = outside the history: unknown, not "sent"
				(remote_labels[r.slot] as Label3D).text = "slot %d: %s" % [r.slot, label]
	var n := session.net
	hud.text = "speed %6.1f u/s   %s%s   stamina x%.2f   eye %.1f\n" % [cp.speed(), "ground" if cp.on_ground else "air", " DUCKED" if cp.ducked else "", Movement.stamina_ratio(cp.stamina_ms), Movement.eye_height(cp)] \
		+ "net: ping %d ms  loss %d%%  jitter %s   tick %d @ %d Hz\n" % [int(PINGS[ping_i]), int(LOSSES[loss_i] * 100.0), "ON" if jitter else "off", session.tick, int(Movement.TICK_RATE)] \
		+ "error vs server (last reconcile) %.3f u   offset %.3f u   corrections/sec %d   last replay %d ticks\n" % [c.last_error, c.offset.length(), corr_ticks.size(), c.last_replay_len] \
		+ "packets c2s sent %d dropped %d | s2c sent %d dropped %d | cmds fully lost %d | ring %d/256\n" % [n.sent[0], n.dropped[0], n.sent[1], n.dropped[1], session.server.lost_seqs.size(), c.ring.count()] \
		+ "RED server  BLUE predicted  GREEN you (T = chase cam)   ORANGE remotes (drawn %.1f ticks behind), white ghosts = true position (X)\n" % [float(session.tick) - c.render_tick] \
		+ "interp [2 3 4] = %.0f ticks   remotes visible %d   0 = toggle remotes\n" % [NetConfig.INTERP_TICKS, c.remote_visible.count(1)] \
		+ "[ ] ping   - = loss   J jitter   K teleport   G shove   V culling   L save recording+CSV   R reset   Esc mouse\n" \
		+ status
