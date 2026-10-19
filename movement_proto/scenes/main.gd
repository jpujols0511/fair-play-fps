extends Node3D
## Playable test scene: flat floor, a visual-only capsule, WASD + mouse look + space.
## Movement is Movement.step on a PlayerState (flat floor, empty world), once per physics tick (128 Hz).
## Ctrl or C = duck (crouch). PlayerSim stays in the repo for test_player_step.gd.

const SENSITIVITY := 0.0022

var state := PlayerState.new()
var world: Array = []        # flat floor only
var autobhop := false        # DEBUG ONLY: hold space = a fresh press every other tick
var tick := 0
var yaw := 0.0
var pitch := 0.0
var jump_queued := false
var peak_speed := 0.0
var capsule: MeshInstance3D
var camera: Camera3D
var hud: Label


func _ready() -> void:
	Engine.physics_ticks_per_second = int(Movement.TICK_RATE)
	_build_world()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


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

	# Reference pillars so speed is visible.
	for i in range(-20, 21):
		for j in range(-20, 21):
			if (i + j) % 5 != 0 or (i == 0 and j == 0):
				continue
			var box := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3(32.0, 128.0, 32.0)
			box.mesh = bm
			box.position = Vector3(i * 512.0, 64.0, j * 512.0)
			add_child(box)

	var cm := CapsuleMesh.new()
	cm.radius = 16.0
	cm.height = 72.0
	capsule = MeshInstance3D.new()
	capsule.mesh = cm
	add_child(capsule)

	camera = Camera3D.new()
	camera.near = 1.0
	camera.far = 80000.0
	camera.fov = 90.0
	add_child(camera)

	var layer := CanvasLayer.new()
	hud = Label.new()
	hud.position = Vector2(16.0, 12.0)
	hud.add_theme_font_size_override("font_size", 22)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 6)
	layer.add_child(hud)
	add_child(layer)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		yaw -= event.relative.x * SENSITIVITY
		pitch = clampf(pitch - event.relative.y * SENSITIVITY, -1.5, 1.5)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_SPACE:
			jump_queued = true
		elif event.keycode == KEY_B:
			autobhop = not autobhop
		elif event.keycode == KEY_R:
			state = PlayerState.new()
			peak_speed = 0.0
		elif event.keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			jump_queued = true
		elif Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(_delta: float) -> void:
	var buttons := 0
	if Input.is_key_pressed(KEY_W): buttons |= InputCmd.BTN_FORWARD
	if Input.is_key_pressed(KEY_S): buttons |= InputCmd.BTN_BACK
	if Input.is_key_pressed(KEY_A): buttons |= InputCmd.BTN_LEFT
	if Input.is_key_pressed(KEY_D): buttons |= InputCmd.BTN_RIGHT
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C): buttons |= InputCmd.BTN_DUCK
	if jump_queued or (autobhop and Input.is_key_pressed(KEY_SPACE) and tick % 2 == 0):
		buttons |= InputCmd.BTN_JUMP
	jump_queued = false
	tick += 1
	Movement.step(state, InputCmd.make(tick, tick, buttons, InputCmd.quantize_yaw(yaw), 0), world)
	peak_speed = maxf(peak_speed, state.speed())


func _process(_delta: float) -> void:
	var h := Movement.hull_height(state)
	(capsule.mesh as CapsuleMesh).height = h
	var feet := Vector3(state.pos_x, state.pos_y, state.pos_z)
	capsule.position = feet + Vector3(0.0, h / 2.0, 0.0)
	camera.position = feet + Vector3(0.0, Movement.eye_height(state), 0.0)
	camera.rotation = Vector3(pitch, yaw, 0.0)
	hud.text = "speed  %6.1f u/s\nvert   %6.1f u/s\npeak   %6.1f u/s\ntick %d Hz   %s%s   stamina x%.2f   eye %.1f\nautobhop [B, DEBUG ONLY]: %s   reset [R]   release mouse [Esc]\nW A S D + mouse, Space / mouse wheel = jump, Ctrl or C = duck" % [
		state.speed(), state.vel_up, peak_speed, Engine.physics_ticks_per_second,
		"ground" if state.on_ground else "air", " DUCKED" if state.ducked else "", Movement.stamina_ratio(state.stamina_ms), Movement.eye_height(state),
		"ON" if autobhop else "off"]
