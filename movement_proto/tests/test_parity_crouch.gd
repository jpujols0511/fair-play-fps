extends SceneTree
## Crouch parity (Phase 1) at 64 / 100 / 128 tick, tolerance 0.01:
##   godot --headless --script res://tests/test_parity_crouch.gd
## Expected values: python3 specs/goldsrc_movement_sim.py --emit-crouch-cases tests/reference_cases_crouch.json
## Output is one line per group; the totals count every individual check.

var tol := 0.01
var passed := 0
var failed := 0


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1: ", Engine.get_version_info()["string"])
		quit(1)
		return
	var f := FileAccess.open("res://tests/reference_cases_crouch.json", FileAccess.READ)
	var c: Dictionary = JSON.parse_string(f.get_as_text())
	tol = c["tolerance"]
	var k: Dictionary = c["constants"]
	print("== CROUCH PARITY ==")
	_group("constants", [
		[Movement.CROUCH_SCALE, k["crouch_scale"]], [Movement.DUCK_TIME_S, k["duck_time_s"]],
		[Movement.DUCK_SPEED_FACTOR, k["duck_speed_factor"]], [Movement.AIR_DUCK_LIFT, k["air_duck_lift"]],
		[Movement.STAND_BODY, k["stand_body"]], [Movement.STAND_EYE, k["stand_eye"]],
		[Movement.DUCK_BODY, k["duck_body"]], [Movement.DUCK_EYE, k["duck_eye"]],
		[Movement.DUCK_BODY, 36.0], [Movement.DUCK_EYE, 32.0]])

	for t in c["transition"]:
		var tick := float(t["tick"])
		var n := 1
		while not Movement.duck_complete(n, tick):
			n += 1
		_group("duck completion tick @%d (want %d)" % [t["tick"], t["complete_tick"]], [[float(n), float(t["complete_tick"])]])
		var pairs: Array = []
		var eyes: Array = t["eye"]
		for i in eyes.size():
			pairs.append([Movement.duck_eye_height(i, tick), eyes[i]])
		_group("eye every tick of the transition @%d (64.0 -> 32.0, %d ticks)" % [t["tick"], eyes.size()], pairs)

	for r in c["ducked_run"]:
		var dt := 1.0 / float(r["tick"])
		var v := 0.0
		var first := -1
		var pairs2: Array = []
		var i := 0
		var timer := 0.0
		for smp in r["samples"]:
			while i < int(smp["after_ticks"]):
				timer = Movement.stamina_tick(timer, dt)
				v = Movement.friction_speed(v, dt)
				var top := Movement.ground_top_speed(250.0, timer) * Movement.DUCK_SPEED_FACTOR
				v += Movement.accel_gain(v, top, top, 10.0, dt)
				i += 1
				if first < 0 and v >= Movement.DUCK_SPEED_FACTOR * 250.0 - 1.0e-9:
					first = i
			pairs2.append([v, smp["speed"]])
		pairs2.append([v, r["steady"]])
		pairs2.append([v, 83.25])
		_group("ducked run from standstill @%d (steady 83.25)" % r["tick"], pairs2)
		_group("tick the ducked speed is first reached @%d (sim: %d)" % [r["tick"], r["first_reached_tick"]], [[float(first), float(r["first_reached_tick"])]])

	for r in c["stamina_duck"]:
		var dt2 := 1.0 / float(r["tick"])
		var v2 := 0.0
		var j := 0
		var timer2: float = r["timer_ms"]
		var pairs3: Array = []
		for smp in r["samples"]:
			while j < int(smp["after_ticks"]):
				timer2 = Movement.stamina_tick(timer2, dt2)
				v2 = Movement.friction_speed(v2, dt2)
				var top2 := Movement.ground_top_speed(250.0, timer2) * Movement.DUCK_SPEED_FACTOR
				v2 += Movement.accel_gain(v2, top2, top2, 10.0, dt2)
				j += 1
			pairs3.append([v2, smp["speed"]])
		_group("stamina x duck after a landing @%d" % r["tick"], pairs3)

	var plain := {64: 44.9788, 100: 44.9916, 128: 44.9999}
	for r in c["crouch_jump"]:
		var dt3 := 1.0 / float(r["tick"])
		var apex_plain := _apex(dt3, -1)
		var apex_duck := _apex(dt3, int(r["duck_tick"]))
		_group("jump apex @%d: plain %.4f, crouch-jump %.4f (= plain + 18.0)" % [r["tick"], apex_plain, apex_duck],
			[[apex_plain, r["plain_apex"]], [apex_duck, r["crouch_apex"]], [apex_plain, plain[int(r["tick"])]], [apex_duck - apex_plain, 18.0]])

	for r in c["cancel"]:
		var tick2 := float(r["tick"])
		_group("cancel mid-transition @%d: eye %.4f while holding, 64.0 on release" % [r["tick"], r["eye_before_release"]],
			[[Movement.duck_eye_height(int(r["hold_ticks"]), tick2), r["eye_before_release"]], [Movement.STAND_EYE, r["eye_on_release"]]])
	# the same cancel through the real step() (128 tick only: step() is fixed at 128 Hz)
	var s := PlayerState.new()
	var cmd := InputCmd.make(1, 0, InputCmd.BTN_DUCK, 0, 0)
	for i in 10:
		Movement.step(s, cmd, Movement.default_world())
	var held_eye := Movement.eye_height(s)
	Movement.step(s, InputCmd.make(2, 0, 0, 0, 0), Movement.default_world())
	_group("cancel through step() @128", [[held_eye, Movement.duck_eye_height(10, 128.0)], [Movement.eye_height(s), 64.0], [float(s.duck_ticks), 0.0]])

	var hr: Array = []
	for h in c["headroom"]:
		var w := [PackedFloat64Array([-1000.0, -1000.0, 1000.0, 1000.0, h["top"], h["bottom"]])]
		hr.append([1.0 if Movement.fits_standing(w, 0.0, h["feet"], 0.0) else 0.0, 1.0 if h["fits"] else 0.0])
	_group("standing headroom (K7)", hr)

	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


## Highest feet height of one jump; duck_tick = tick index at whose start duck is pressed in the air.
func _apex(dt: float, duck_tick: int) -> float:
	var vz := Movement.JUMP_SPEED
	var z := 0.0
	var best := 0.0
	var n := 0
	while true:
		if n == duck_tick:
			z += Movement.AIR_DUCK_LIFT
		vz = Movement.gravity_half(vz, dt)
		z += vz * dt
		vz = Movement.gravity_half(vz, dt)
		n += 1
		best = maxf(best, z)
		if z <= 0.0 and n > 1:
			return best
	return best


func _group(name: String, pairs: Array) -> void:
	var bad := 0
	var worst := 0.0
	for p in pairs:
		var d := absf(float(p[0]) - float(p[1]))
		worst = maxf(worst, d)
		if d <= tol:
			passed += 1
		else:
			failed += 1
			bad += 1
			print("FAIL  %s: got %.6f want %.6f" % [name, float(p[0]), float(p[1])])
	if bad == 0:
		print("PASS  %s  (%d checks, worst diff %.9f)" % [name, pairs.size(), worst])
