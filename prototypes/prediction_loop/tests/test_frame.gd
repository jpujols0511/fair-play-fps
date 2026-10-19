extends SceneTree
## Frame adapter (seam D7): game frame <-> spec frame.   godot --headless --script res://tests/test_frame.gd

var passed := 0
var failed := 0


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	# walking forward at yaw 0 for 128 ticks moves spec_y up and spec_x not at all
	var s := PlayerState.new()
	var cmd := InputCmd.make(1, 0, InputCmd.BTN_FORWARD, 0, InputCmd.quantize_pitch(0.0))
	for i in 128:
		Movement.step(s, cmd, [])
	_ok("walk forward at yaw 0: spec_y goes up", Frame.to_spec_y(s.pos_z) > 100.0, "spec_y = %.3f" % Frame.to_spec_y(s.pos_z))
	_ok("walk forward at yaw 0: spec_x does not move", Frame.to_spec_x(s.pos_x) == 0.0, "spec_x = %.9f" % Frame.to_spec_x(s.pos_x))
	# yaw pi/2 faces -x in the game frame = spec yaw 180
	_close("game yaw pi/2 -> spec yaw 180", Frame.yaw_to_spec_deg(PI / 2.0), 180.0, 1.0e-12)
	_close("game yaw 0 -> spec yaw 90 (faces spec +y)", Frame.yaw_to_spec_deg(0.0), 90.0, 1.0e-12)
	var s2 := PlayerState.new()
	var quarter := InputCmd.quantize_yaw(PI / 2.0)
	for i in 128:
		Movement.step(s2, InputCmd.make(i, i, InputCmd.BTN_FORWARD, quarter, 0), [])
	_ok("walk at yaw pi/2: spec_x goes negative (spec 180 deg faces -x)", Frame.to_spec_x(s2.pos_x) < -100.0 and absf(Frame.to_spec_y(s2.pos_z)) < 1.0e-6, "spec_x = %.3f spec_y = %.9f" % [Frame.to_spec_x(s2.pos_x), Frame.to_spec_y(s2.pos_z)])
	# looking up 10 degrees -> spec pitch -10
	_close("look up 10 deg -> spec pitch -10", Frame.pitch_to_spec_deg(deg_to_rad(10.0)), -10.0, 1.0e-12)
	_ok("feet height maps to spec z", Frame.to_spec_z(12.5) == 12.5 and Frame.to_game_y(12.5) == 12.5)
	# round trips exact to 1e-12
	var worst := 0.0
	var rng := RandomNumberGenerator.new()
	rng.seed = 5151
	for i in 2000:
		var x := rng.randf_range(-4000.0, 4000.0)
		var y := rng.randf_range(0.0, 200.0)
		var z := rng.randf_range(-4000.0, 4000.0)
		var yaw := rng.randf_range(0.0, TAU)
		var pitch := rng.randf_range(-PI / 2.0, PI / 2.0)
		worst = maxf(worst, absf(Frame.to_game_x(Frame.to_spec_x(x)) - x))
		worst = maxf(worst, absf(Frame.to_game_y(Frame.to_spec_z(y)) - y))
		worst = maxf(worst, absf(Frame.to_game_z(Frame.to_spec_y(z)) - z))
		var dy := absf(Frame.yaw_to_game_rad(Frame.yaw_to_spec_deg(yaw)) - yaw)
		worst = maxf(worst, minf(dy, absf(dy - TAU)))
		worst = maxf(worst, absf(Frame.pitch_to_game_rad(Frame.pitch_to_spec_deg(pitch)) - pitch))
	_ok("round trips exact to 1e-12 (2000 random poses)", worst < 1.0e-12, "worst %.15f" % worst)
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _close(name: String, got: float, want: float, tol: float) -> void:
	_ok(name, absf(got - want) <= tol, "got %.12f want %.12f" % [got, want])
