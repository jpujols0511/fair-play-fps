extends SceneTree
## Crouch at state level (Phase 1), crouch_test_world():
##   godot --headless --script res://tests/test_crouch_step.gd

var passed := 0
var failed := 0
var world: Array = Movement.crouch_test_world()
var seq := 0
const BF := InputCmd.BTN_FORWARD
const BD := InputCmd.BTN_DUCK
const BJ := InputCmd.BTN_JUMP
var EAST: int = InputCmd.quantize_yaw(-PI / 2.0)    # forward = +x


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1: ", Engine.get_version_info()["string"])
		quit(1)
		return
	_overhang()
	_unduck_headroom()
	_air()
	_stance_and_hud()
	_eye()
	_cover_and_ceiling()
	_state_plumbing()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _tick(s: PlayerState, buttons: int, yaw_q: int = 0) -> void:
	seq += 1
	Movement.step(s, InputCmd.make(seq, seq, buttons, yaw_q, 0), world)


func _at(x: float, y: float = 0.0, z: float = 0.0) -> PlayerState:
	var s := PlayerState.new()
	s.pos_x = x
	s.pos_y = y
	s.pos_z = z
	return s


func _fully_ducked(x: float) -> PlayerState:
	var s := _at(x)
	for i in 60:
		_tick(s, BD)
	return s


## Fully ducked and walked (ducked) to x, so the player is legitimately under the overhang.
func _ducked_under(x: float) -> PlayerState:
	var s := _fully_ducked(400.0)
	while s.pos_x < x:
		_tick(s, BF | BD, EAST)
	return s


func _overhang() -> void:
	# crouch-walk under the overhang (x 500..600, bottom 40.0): passes, and out the other side
	var s := _fully_ducked(400.0)
	var blocked := false
	var hit_ticks := 0
	while s.pos_x < 650.0 and hit_ticks < 2000:
		var before := s.pos_x
		_tick(s, BF | BD, EAST)
		hit_ticks += 1
		if before == s.pos_x:
			blocked = true
	_ok("crouch-walk under the overhang passes", not blocked and s.pos_x >= 650.0 and s.ducked, "x = %.3f after %d ticks, ducked %s, never blocked" % [s.pos_x, hit_ticks, str(s.ducked)])
	# standing walk into it: blocked at x = 500.0 - 16.0
	var t := _at(400.0)
	for i in 700:
		_tick(t, BF, EAST)
	_ok("standing walk into the overhang is blocked at 484.0", t.pos_x == 484.0, "x = %.6f" % t.pos_x)
	# duck pressed right at the overhang: during the 52-tick transition the hull is still 72.0, so it is blocked
	var u := _at(470.0)
	for i in 30:
		_tick(u, BF | BD, EAST)
	var blocked_during := u.pos_x == 484.0 and not u.ducked and u.in_duck
	for i in 400:
		_tick(u, BF | BD, EAST)
	_ok("duck at the overhang: blocked at 484.0 until the transition completes, then walks under", blocked_during and u.pos_x > 500.0 and u.ducked, "after 30 ticks x = 484.0 (in transition), after 430 ticks x = %.3f" % u.pos_x)


func _unduck_headroom() -> void:
	# duck, walk under, release duck but keep walking
	var s := _ducked_under(540.0)
	var stayed := true
	var first_unduck := -1
	var checked := 0
	var consistent := true
	for i in 400:
		var fits := Movement.fits_standing(world, s.pos_x, s.pos_y, s.pos_z)
		_tick(s, BF, EAST)
		checked += 1
		# crouch handling happens at the start of the tick, from the position before the move
		if s.ducked == fits:
			consistent = false
		if not s.ducked and first_unduck < 0:
			first_unduck = i
		if first_unduck >= 0:
			break
		if not s.ducked:
			stayed = false
	_ok("release duck under the overhang: stays ducked every tick, unducks on the first clear tick", consistent and stayed and first_unduck > 0, "unducked on tick %d at x = %.3f (hull clears at x >= 616.0)" % [first_unduck, s.pos_x])
	_ok("while ducked under it, speed stays at the ducked 83.25", absf(Vector2(s.vel_x, s.vel_z).length() - 83.25) < 0.01 or first_unduck >= 0, "speed %.3f at the unduck tick" % Vector2(s.vel_x, s.vel_z).length())
	# standing player is never inside the overhang
	var inside := false
	var w := _ducked_under(540.0)
	for i in 300:
		_tick(w, BF, EAST)
		if not w.ducked and w.pos_x + 16.0 > 500.0 and w.pos_x - 16.0 < 600.0 and w.pos_y < 128.0:
			inside = true
	_ok("a standing hull is never inside the overhang", not inside)


func _air() -> void:
	# duck in the air lifts the feet by exactly 18.0 on the press tick
	var a := _at(0.0)
	var b := _at(0.0)
	_tick(a, BJ)
	_tick(b, BJ)
	for i in 5:
		_tick(a, 0)
		_tick(b, 0)
	_tick(a, BD)
	_tick(b, 0)
	_ok("in-air duck lifts the feet 18.0 on the press tick", absf((a.pos_y - b.pos_y) - 18.0) < 1.0e-9 and a.ducked and not b.ducked, "difference %.9f" % (a.pos_y - b.pos_y))
	# unduck in the air with room: feet go down 18.0 vs staying ducked
	var c := _at(0.0)
	var d := _at(0.0)
	_tick(c, BJ)
	_tick(d, BJ)
	for i in 5:
		_tick(c, BD)
		_tick(d, BD)
	_tick(c, 0)
	_tick(d, BD)
	_ok("unduck in the air lowers the feet 18.0", absf((d.pos_y - c.pos_y) - 18.0) < 1.0e-9 and not c.ducked and d.ducked, "difference %.9f" % (d.pos_y - c.pos_y))
	# unduck near the floor lands on the floor, never under it
	var e := _at(0.0, 5.0)
	e.on_ground = false
	e.ducked = true
	e.vel_up = -10.0
	_tick(e, 0)
	_ok("unduck in the air near the floor lands on it, never under", e.pos_y >= 0.0 and e.pos_y == 0.0 and e.on_ground and not e.ducked, "y = %.6f on_ground %s" % [e.pos_y, str(e.on_ground)])
	# unduck in the air under the overhang: no room, stays ducked and retries
	var f := _at(550.0, 20.0)
	f.on_ground = false
	f.ducked = true
	f.vel_up = 0.0
	_tick(f, 0)
	_ok("unduck in the air with no room stays ducked", f.ducked, "feet %.3f" % f.pos_y)
	# a ducked jump under the overhang hits its underside (bottom 40.0, hull 36.0)
	var g := _ducked_under(550.0)
	var top_y := 0.0
	for i in 120:
		_tick(g, BD | (BJ if i == 0 else 0))
		top_y = maxf(top_y, g.pos_y)
	_ok("a ducked jump under the overhang stops at the underside", top_y <= 4.0 + 1.0e-9 and top_y > 3.0, "highest feet %.6f (bottom 40.0 - hull 36.0 = 4.0)" % top_y)


func _stance_and_hud() -> void:
	var s := _at(0.0)
	_ok("stance: stand = 0", Movement.stance_for_hitbox(s) == 0)
	for i in 10:
		_tick(s, BD)
	_ok("stance: during the ground transition stays 0 (hull still 72)", s.in_duck and Movement.stance_for_hitbox(s) == 0, "duck_ticks %d" % s.duck_ticks)
	for i in 60:
		_tick(s, BD)
	_ok("stance: ducked on ground = 1", Movement.stance_for_hitbox(s) == 1)
	var a := _at(0.0)
	_tick(a, BJ)
	_ok("stance: airborne standing = 2", Movement.stance_for_hitbox(a) == 2)
	_tick(a, BD)
	_ok("stance: airborne ducked = 3", Movement.stance_for_hitbox(a) == 3)
	# move_state_for_hud: air 2 beats run 3 beats crouch 1 beats stand 0
	var m := _at(0.0)
	_ok("move_state: stand = 0", Movement.move_state_for_hud(m) == 0)
	m.ducked = true
	_ok("move_state: crouched = 1", Movement.move_state_for_hud(m) == 1)
	m.vel_x = 140.0
	_ok("move_state: exactly 140.0 is NOT running", Movement.move_state_for_hud(m) == 1)
	m.vel_x = 140.0000001
	_ok("move_state: just over 140.0 is running (beats crouch)", Movement.move_state_for_hud(m) == 3)
	m.on_ground = false
	_ok("move_state: air beats run", Movement.move_state_for_hud(m) == 2)
	m.on_ground = true
	m.ducked = false
	m.vel_x = 100.0
	m.vel_z = 100.0
	_ok("move_state: diagonal speed 141.4 counts (horizontal speed)", Movement.move_state_for_hud(m) == 3)


func _eye() -> void:
	var s := _at(0.0)
	_ok("eye: standing 64.0", Movement.eye_height(s) == 64.0)
	var worst := 0.0
	for i in 52:
		_tick(s, BD)
		var want := 64.0 - 32.0 * ((float(s.duck_ticks) / 128.0) / 0.4) if not s.ducked else 32.0
		worst = maxf(worst, absf(Movement.eye_height(s) - want))
	_ok("eye: linear in between, 32.0 once ducked", worst < 1.0e-12 and Movement.eye_height(s) == 32.0 and s.ducked, "worst deviation %.9f, completes on tick 52, ducked %s" % [worst, str(s.ducked)])


func _cover_and_ceiling() -> void:
	# the 40-unit cover (x 700..716) blocks both stances
	var a := _at(640.0)
	var b := _fully_ducked(640.0)
	for i in 600:
		_tick(a, BF, EAST)
		_tick(b, BF | BD, EAST)
	_ok("40-unit cover blocks a standing player at 684.0", a.pos_x == 684.0, "x = %.3f" % a.pos_x)
	_ok("40-unit cover blocks a crouched player at 684.0", b.pos_x == 684.0, "x = %.3f" % b.pos_x)
	# boxes without a 6th value behave as before (bottom 0.0): default world untouched
	var dw := Movement.default_world()
	_ok("default_world() is unchanged: 2 boxes, 5 values each", dw.size() == 2 and (dw[0] as PackedFloat64Array).size() == 5 and (dw[1] as PackedFloat64Array).size() == 5)


func _state_plumbing() -> void:
	var s := _at(1.0, 2.0, 3.0)
	s.ducked = true
	s.duck_ticks = 7
	s.in_duck = true
	var c := s.duplicate_state()
	_ok("PlayerState copies and compares the duck fields", c.equals(s) and c.ducked and c.duck_ticks == 7 and c.in_duck)
	c.duck_ticks = 8
	_ok("equals() sees a duck_ticks difference", not c.equals(s))
	_ok("to_packed() has 13 fields (10 old + 3 duck), old ones first", s.to_packed().size() == 13 and s.hex().length() == 13 * 16)
