class_name ClientMain
extends Node
## The client process (Phase 6): a window client or a headless bot client, over a real transport.
##   godot --path . -- --client --connect 127.0.0.1:27015                                   (window, keyboard + mouse)
##   godot --headless --path . -- --client --connect 127.0.0.1:27015 --bot mixed --ticks 7680   (headless bot)
##   extra: --transport enet|udp   --shim 80,0.02[,5]  (ping ms, loss, jitter ms; runs 80 ms / 2% over real sockets, no root)
## Real time only decides HOW MANY ticks run; each tick uses 1.0 / 128.0. The tick order is the same as everywhere:
## step 3 the client reads input, predicts and sends; step 4 it reconciles against what arrived; step 5 smoothing and HUD.

const TICK_US := 1000000.0 / 128.0
const MAX_BACKLOG_TICKS := 8

var transport
var shim: TransportShim = null
var endpoint: NetEndpoint
var nc: NetClient
var address := "127.0.0.1"
var port := 27015
var bot := ""
var world_name := "default"
var max_ticks := 0
var headless := false
var tick := 0
var state := "connecting"          # connecting -> running -> done
var _acc := 0.0
var _last_us := 0
var _hello_us := 0
var _connect_start_us := 0
var overruns := 0
var errors := PackedFloat64Array()     # error at each correction (units)
var mem_start := 0
var mem_minute := 0
var _done := false
var _lost_seen := 0
var _shim_base_ms := 0.0           # the shim's clock during the handshake runs on real time, then continues in ticks from here

# window mode
var yaw := 0.0
var pitch := 0.0
var jump_pulse := false
var camera: Camera3D
var self_cap: MeshInstance3D
var remote_caps: Array = []
var hud: Label
var crosshair: Control


func setup(args: PackedStringArray) -> void:
	headless = DisplayServer.get_name() == "headless"
	var shim_args: PackedStringArray = []
	for i in args.size():
		var val := ServerMain.arg_value(args, i)
		if args[i] in ["--connect", "--bot", "--ticks", "--transport", "--shim", "--world"] and val == "":
			print("CLIENT_ERROR flag %s needs a value" % args[i])
			_done = true
			get_tree().quit(2)
			return
		match args[i]:
			"--connect":
				var parts := val.split(":")
				if parts.size() != 2 or not parts[1].is_valid_int():
					print("CLIENT_ERROR --connect wants host:port, got '%s'" % val)
					_done = true
					get_tree().quit(2)
					return
				address = parts[0]
				port = int(parts[1])
			"--bot": bot = val
			"--world": world_name = val
			"--ticks": max_ticks = int(val)
			"--transport": NetConfig.TRANSPORT = val
			"--shim": shim_args = val.split(",")
	var inner = TransportUdp.new() if NetConfig.TRANSPORT == "udp" else TransportEnet.new()
	var e: int = inner.connect_to(address, port)
	transport = inner
	if not shim_args.is_empty():
		shim = TransportShim.new(inner, 1, float(shim_args[0]), float(shim_args[1]) if shim_args.size() > 1 else 0.0, float(shim_args[2]) if shim_args.size() > 2 else 0.0)
		transport = shim
	endpoint = NetEndpoint.new(transport)
	nc = NetClient.new()
	nc.setup(Movement.crouch_test_world() if world_name == "crouch" else Movement.default_world(), endpoint)
	add_child(nc)
	print("Godot ", Engine.get_version_info()["string"])
	print("CLIENT connecting to %s:%d with %s%s (error code %d), bot '%s', ticks %d" % [address, port, NetConfig.TRANSPORT, " + shim %s" % ",".join(shim_args) if shim != null else "", e, bot, max_ticks])
	_last_us = Time.get_ticks_usec()
	_connect_start_us = _last_us
	if e != OK:
		print("CLIENT_ERROR could not start the transport")
		_finish(2)


func _process(_delta: float) -> void:
	if _done:
		return
	var now := Time.get_ticks_usec()
	if state == "connecting":
		_connect(now)
		return
	_acc += float(now - _last_us)
	_last_us = now
	if _acc > TICK_US * float(MAX_BACKLOG_TICKS):
		overruns += 1
		_acc = TICK_US
	var ran := false
	while _acc >= TICK_US and not _done:
		_acc -= TICK_US
		_tick()
		ran = true
	if not ran and headless:
		OS.delay_usec(300)
	if not headless:
		_view_update()


func _connect(now: int) -> void:
	if shim != null:
		shim.now_ms = float(now - _connect_start_us) / 1000.0
	for raw in transport.poll():
		var m := Packet.parse(raw)
		if not m.is_empty() and m["msg"] == Packet.MSG_WELCOME:
			endpoint.welcome = m
		elif not m.is_empty() and m["msg"] == Packet.MSG_CHALLENGE:
			endpoint.cookie = m["cookie"]
			_hello_us = 0                    # answer the challenge now, not after the next 100 ms
	if endpoint.welcome.is_empty():
		if now - _hello_us > 100000:
			_hello_us = now
			endpoint.send_hello()
		if now - _connect_start_us > 5000000:
			print("CLIENT_ERROR no WELCOME within 5 s")
			_finish(2)
		return
	var w: Dictionary = endpoint.welcome
	NetConfig.INTERP_TICKS = float(w["interp_ticks"])          # the SERVER dictates it (netcode Section 9)
	NetConfig.SNAPSHOT_EVERY_TICKS = int(w["snapshot_every"])
	print("CLIENT welcome: slot %d, server tick %d, interp %d ticks, snapshot every %d ticks" % [w["slot"], w["server_tick"], w["interp_ticks"], w["snapshot_every"]])
	for i in Snapshot.MAX_SLOTS:
		(nc.client.remotes[i] as InterpBuffer).extrap = NetConfig.EXTRAP_MAX_TICKS
	state = "running"
	_shim_base_ms = float(now - _connect_start_us) / 1000.0
	_last_us = now
	if not headless:
		_view_build()


func _tick() -> void:
	endpoint.tick = tick
	if shim != null:
		shim.now_ms = _shim_base_ms + float(tick) * (1000.0 / Movement.TICK_RATE)
	var buttons := 0
	var yaw_q := 0
	var pitch_q := InputCmd.quantize_pitch(0.0)
	if bot != "":
		var i := Bots.input(bot, tick, nc.get_player_state())
		buttons = i[0]
		yaw_q = i[1]
		pitch_q = i[2]
	else:
		buttons = _read_buttons()
		yaw_q = InputCmd.quantize_yaw(yaw)
		pitch_q = InputCmd.quantize_pitch(pitch)
	nc.send_input(InputCmd.make(0, tick, buttons, yaw_q, pitch_q))     # step 3: predict and send
	nc.poll_and_update(tick)                                            # steps 4 and 5
	for e in nc.client.reconcile_log:
		if e[2]:
			errors.append(e[1])
	tick += 1
	if tick == 7680:
		mem_minute = OS.get_static_memory_usage()
	if tick == 128:
		mem_start = OS.get_static_memory_usage()
	if max_ticks > 0 and tick >= max_ticks:
		_report()
		for k in 5:                          # BYE is unreliable: retry it 5 times, 20 ms apart; the server also drops a silent client after 5 s
			endpoint.send_bye()
			transport.poll()
			OS.delay_msec(20)
		_finish(0)


func _pct(a: PackedFloat64Array, p: float) -> float:
	if a.is_empty():
		return 0.0
	var b := a.duplicate()
	b.sort()
	return b[mini(int(ceil(p * float(b.size()))) - 1, b.size() - 1)]


func _report() -> void:
	var st := nc.get_stats()
	var secs := float(tick) / 128.0
	var max_err := 0.0
	for e in errors:
		max_err = maxf(max_err, e)
	var mem_end := OS.get_static_memory_usage()
	var out_bytes: int = transport.inner.sent_bytes if shim != null else transport.sent_bytes
	print("CLIENT_STATS ticks=%d corrections=%d error_p99=%.4f error_max=%.4f snapshots=%d snapshot_loss=%.4f rtt_ms=%.1f rx_B_per_s=%.0f tx_B_per_s=%.0f overruns=%d overrun_pct=%.4f dropped_missing_baseline=%d malformed=%d mem_start_MB=%.2f mem_minute_MB=%.2f mem_end_MB=%.2f mem_growth_after_minute_MB=%.2f" % [
		tick, st["corrections"], _pct(errors, 0.99), max_err, st["snapshots"], st["snapshot_loss"], st["rtt_ms"], st["bytes_per_s"], float(out_bytes) / secs, overruns, 100.0 * float(overruns) / maxf(float(tick), 1.0),
		st["dropped_missing_baseline"], Packet.malformed, float(mem_start) / 1048576.0, float(mem_minute) / 1048576.0, float(mem_end) / 1048576.0,
		(float(mem_end - mem_minute) / 1048576.0) if mem_minute > 0 else 0.0])
	var mchg: Array = []
	for c in nc.client.mask_log:
		mchg.append("%d:%d" % [c[0], c[1]])
	print("CLIENT_MASKS slot=%d changes=%s" % [endpoint.welcome.get("slot", -1), ",".join(mchg)])


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	transport.close()
	get_tree().quit(code)


# ---------------- window mode ----------------

func _read_buttons() -> int:
	var b := 0
	if Input.is_key_pressed(KEY_W): b |= InputCmd.BTN_FORWARD
	if Input.is_key_pressed(KEY_S): b |= InputCmd.BTN_BACK
	if Input.is_key_pressed(KEY_A): b |= InputCmd.BTN_LEFT
	if Input.is_key_pressed(KEY_D): b |= InputCmd.BTN_RIGHT
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C): b |= InputCmd.BTN_DUCK
	if jump_pulse or Input.is_key_pressed(KEY_SPACE): b |= InputCmd.BTN_JUMP
	jump_pulse = false
	return b


func _unhandled_input(event: InputEvent) -> void:
	if headless or state != "running":
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * 0.0022
		pitch = clampf(pitch - event.relative.y * 0.0022, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			jump_pulse = true
		elif event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			jump_pulse = true
		elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _capsule(color: Color, alpha: float) -> MeshInstance3D:
	var m := CapsuleMesh.new()
	m.radius = 16.0
	m.height = 72.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	add_child(mi)
	return mi


func _view_build() -> void:
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
	var fl := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60000.0, 60000.0)
	fl.mesh = pm
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.45, 0.47, 0.5)
	fl.material_override = fm
	add_child(fl)
	for b: PackedFloat64Array in Movement.default_world():
		var bm := BoxMesh.new()
		bm.size = Vector3(b[2] - b[0], b[4], b[3] - b[1])
		var bi := MeshInstance3D.new()
		bi.mesh = bm
		bi.position = Vector3((b[0] + b[2]) / 2.0, b[4] / 2.0, (b[1] + b[3]) / 2.0)
		add_child(bi)
	self_cap = _capsule(Color(0.2, 0.85, 0.3), 1.0)
	for i in Snapshot.MAX_SLOTS:
		var rc := _capsule(Color(1.0, 0.6, 0.1), 1.0)
		rc.visible = false
		remote_caps.append(rc)
	camera = Camera3D.new()
	camera.near = 1.0
	camera.far = 80000.0
	camera.fov = 90.0
	add_child(camera)
	var layer := CanvasLayer.new()
	crosshair = load("res://scripts/hud/crosshair.gd").new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(crosshair)
	nc.snapshot_received.connect(crosshair._on_snapshot)
	hud = Label.new()
	hud.position = Vector2(16.0, 12.0)
	hud.add_theme_font_size_override("font_size", 18)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	add_child(layer)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _view_update() -> void:
	if camera == null:
		return
	var c := nc.client
	var p := nc.get_player_state()
	var h := Movement.hull_height(p)
	(self_cap.mesh as CapsuleMesh).height = h
	self_cap.position = c.visual + Vector3(0.0, h / 2.0, 0.0)
	self_cap.visible = false
	camera.position = c.visual + Vector3(0.0, Movement.eye_height(p), 0.0)
	camera.rotation = Vector3(pitch, yaw, 0.0)
	for slot in Snapshot.MAX_SLOTS:
		var rc: MeshInstance3D = remote_caps[slot]
		rc.visible = c.remote_visible[slot] == 1
		if rc.visible:
			var b: InterpBuffer = c.remotes[slot]
			var hh := Movement.DUCK_BODY if (b.out_stance & 1) == 1 else Movement.STAND_BODY
			(rc.mesh as CapsuleMesh).height = hh
			rc.position = Vector3(b.out_x, b.out_y + hh / 2.0, b.out_z)
	var st := nc.get_stats()
	hud.text = "NETWORKED client  %s  speed %.1f u/s   %s\nrtt %.1f ms   snapshot loss %.1f%%   corrections %d   %.0f B/s in   interp %.0f ticks\nW A S D + mouse, Space jump, Ctrl/C duck, Esc releases the mouse" % [
		NetConfig.TRANSPORT, p.speed(), "ground" if p.on_ground else "air", st["rtt_ms"], st["snapshot_loss"] * 100.0, st["corrections"], st["bytes_per_s"], NetConfig.INTERP_TICKS]
