extends SceneTree
## Headless parity test:  godot --headless --script res://tests/test_parity.gd
## Expected values come from specs/goldsrc_movement_sim.py (tests/reference_cases.json).
## Build order is enforced: phase 2 (jump, stamina, bhop) only runs if phase 1 passes.

var tol := 0.01
var passed := 0
var failed := 0


func _init() -> void:
	var f := FileAccess.open("res://tests/reference_cases.json", FileAccess.READ)
	if f == null:
		print("FAIL  cannot open tests/reference_cases.json")
		quit(1)
		return
	var cases: Dictionary = JSON.parse_string(f.get_as_text())
	tol = cases["tolerance"]

	print("== PHASE 1: friction, ground accel, air cap ==")
	_phase1(cases["phase1"])
	if failed > 0:
		print("PHASE 1 FAILED - phase 2 (jump, stamina, bhop) skipped by build order")
	else:
		print("PHASE 1 PASSED")
		print("== PHASE 2: stamina, jump, bhop cap ==")
		_phase2(cases["phase2"])

	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _check(name: String, got: float, want: float) -> void:
	if absf(got - want) <= tol:
		passed += 1
		print("PASS  %s  got %.4f want %.4f" % [name, got, want])
	else:
		failed += 1
		print("FAIL  %s  got %.4f want %.4f" % [name, got, want])


func _v(a: Array) -> Vector2:
	return Vector2(a[0], a[1])


func _phase1(p: Dictionary) -> void:
	for c in p["friction"]:
		var dt := 1.0 / float(c["tick"])
		var s: float = c["speed"]
		var steps: int = int(c.get("steps", 1))
		for i in steps:
			s = Movement.friction_speed(s, dt)
		_check("friction %d tick, %.1f u/s, %d step(s)" % [c["tick"], c["speed"], steps], s, c["expect"])
		# vector wrapper must agree with the scalar core
		if c["speed"] > 0.0:
			var v := Vector2(c["speed"], 0.0)
			for i in steps:
				v = Movement.friction(v, dt)
			_check("friction(Vector2) %d tick, %.1f u/s, %d step(s)" % [c["tick"], c["speed"], steps], v.length(), c["expect"])

	for c in p["ground_accel"]:
		_accel_case("ground_accel", c, true)
	for c in p["air_accel"]:
		_accel_case("air_accel", c, false)

	for c in p["strafe_gain"]:
		var dt := 1.0 / float(c["tick"])
		var v: float = c["speed"]
		var a := 10.0 * 250.0 * dt
		var dd := maxf(Movement.AIR_CAP - a, 0.0)
		var w := Vector2(dd / v, sqrt(1.0 - (dd / v) * (dd / v)))
		var d := Movement.air_accel(w, v * w.x, 250.0, 10.0, dt)
		var after := Vector2(v + d.x, d.y).length()
		_check("strafe gain/tick %d tick @ %.0f" % [c["tick"], v], after - v, c["gain_per_tick"])
		_check("strafe gain/sec  %d tick @ %.0f" % [c["tick"], v], (after - v) * float(c["tick"]), c["gain_per_sec"])


func _accel_case(fn: String, c: Dictionary, ground: bool) -> void:
	var dt := 1.0 / float(c["tick"])
	var vel := _v(c["vel"])
	var w := _v(c["wish_dir"])
	var cur := vel.dot(w)
	var d: Vector2
	if ground:
		d = Movement.ground_accel(w, cur, 250.0, 10.0, dt)
	else:
		d = Movement.air_accel(w, cur, 250.0, 10.0, dt)
	var want := _v(c["delta"])
	var label := "%s %d tick vel(%.0f,%.0f) wish(%.2f,%.2f)" % [fn, c["tick"], vel.x, vel.y, w.x, w.y]
	_check(label + " dx", d.x, want.x)
	_check(label + " dy", d.y, want.y)
	_check(label + " speed", (vel + d).length(), c["speed_after"])


func _phase2(p: Dictionary) -> void:
	for c in p["stamina_ratio"]:
		_check("stamina_ratio @ %.1f ms" % c["timer_ms"], Movement.stamina_ratio(c["timer_ms"]), c["expect"])
	_check("stamina_ratio right after a jump is 0.75", Movement.stamina_ratio(Movement.STAMINA_MS), 0.75)
	_check("stamina_ratio floor at 0", Movement.stamina_ratio(1.0e9), 0.0)
	for c in p["jump"]:
		_check("jump vz @ stamina %.1f ms" % c["timer_ms"], Movement.jump(c["timer_ms"]), c["expect"])
	for c in p["bhop_cap"]:
		_check("bhop_cap %.4f" % c["speed"], Movement.bhop_cap_speed(c["speed"], c["maxspeed"]), c["expect"])
		if c["speed"] > 0.0:
			_check("bhop_cap(Vector2) %.4f" % c["speed"], Movement.bhop_cap(Vector2(c["speed"], 0.0), c["maxspeed"]).length(), c["expect"])
	for c in p["chain"]:
		_chain(c)


## 20 chained hops with ideal strafing, built only from movement.gd functions.
func _chain(c: Dictionary) -> void:
	var tick: int = int(c["tick"])
	var dt := 1.0 / float(tick)
	var v := 250.0
	var timer := 0.0
	var a := 10.0 * 250.0 * dt
	var dd := maxf(Movement.AIR_CAP - a, 0.0)
	for i in c["hops"].size():
		var want: Dictionary = c["hops"][i]
		v = Movement.bhop_cap_speed(v, 250.0)
		var vz := Movement.jump(timer)
		var vz0 := vz
		timer = Movement.STAMINA_MS
		var z := 0.0
		var n := 0
		while true:
			vz = Movement.gravity_half(vz, dt)
			z += vz * dt
			vz = Movement.gravity_half(vz, dt)
			n += 1
			var w := Vector2(dd / v, sqrt(1.0 - (dd / v) * (dd / v)))
			var d := Movement.air_accel(w, v * w.x, 250.0, 10.0, dt)
			v = Vector2(v + d.x, d.y).length()
			timer = Movement.stamina_tick(timer, dt)
			if z <= 0.0:
				break
		var label := "chain %d tick hop %d" % [tick, i + 1]
		_check(label + " vz", vz0, want["vz"])
		_check(label + " air ticks", float(n), float(want["ticks"]))
		_check(label + " end speed", v, want["speed"])
	if tick == 128:
		_check("TOP BHOP 128 tick (S2: 340.72)", v, 340.72)
