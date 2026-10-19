extends SceneTree
## Phase 3 parity (stamina slows ground speed):
##   godot --headless --script res://tests/test_parity_phase3.gd
## Separate from test_parity.gd so Phase 1/2 stay green on their own.
## Expected values: python3 specs/goldsrc_movement_sim.py --emit-cases-phase3 tests/reference_cases_phase3.json

var tol := 0.01
var passed := 0
var failed := 0


func _init() -> void:
	var f := FileAccess.open("res://tests/reference_cases_phase3.json", FileAccess.READ)
	var cases: Dictionary = JSON.parse_string(f.get_as_text())
	tol = cases["tolerance"]
	print("== PHASE 3: stamina slows ground speed ==")
	for c in cases["top_speed"]:
		_check("ground_top_speed @ %.1f ms" % c["timer_ms"], Movement.ground_top_speed(250.0, c["timer_ms"]), c["expect"])
	for c in cases["run"]:
		var dt := 1.0 / float(c["tick"])
		var timer: float = c["timer_ms"]
		var v: float = c["v0"]
		var k := 0
		for smp in c["samples"]:
			while k < int(smp["after_ticks"]):
				timer = Movement.stamina_tick(timer, dt)
				v = Movement.friction_speed(v, dt)
				var top := Movement.ground_top_speed(250.0, timer)
				v += Movement.accel_gain(v, top, top, 10.0, dt)
				k += 1
			_check("ground run %d tick from %.0f u/s, after %d ticks" % [c["tick"], c["v0"], k], v, smp["speed"])
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _check(name: String, got: float, want: float) -> void:
	if absf(got - want) <= tol:
		passed += 1
		print("PASS  %s  got %.4f want %.4f" % [name, got, want])
	else:
		failed += 1
		print("FAIL  %s  got %.4f want %.4f" % [name, got, want])
