class_name Movement
extends RefCounted
## Pure movement core. No node state, no physics bodies.
## Behaviour spec: specs/goldsrc_movement.md. Reference: specs/goldsrc_movement_sim.py.
## Every constant is a float literal; ticks are expressed as 1.0 / tick.

const FRICTION := 4.0
const STOP_SPEED := 100.0
const AIR_CAP := 30.0

## ---- Phase 1: friction, ground accel, air cap ----

## Scalar core (float64, used by the parity test). Speed after one ground tick of friction.
static func friction_speed(speed: float, dt: float) -> float:
	if speed <= 0.0:
		return 0.0
	var drop := FRICTION * maxf(speed, STOP_SPEED) * dt
	return maxf(speed - drop, 0.0)


## Friction on a horizontal velocity.
static func friction(velocity: Vector2, dt: float) -> Vector2:
	var speed := velocity.length()
	if speed <= 0.0:
		return Vector2.ZERO
	return velocity * (friction_speed(speed, dt) / speed)


## Speed added along wish_dir this tick: a slice of accel * wish_speed * dt,
## never more than the gap between cap_speed and the speed already going that way.
static func accel_gain(current_speed: float, cap_speed: float, wish_speed: float, accel: float, dt: float) -> float:
	var gap := cap_speed - current_speed
	if gap <= 0.0:
		return 0.0
	return minf(accel * wish_speed * dt, gap)


## Scalar cores of ground_accel / air_accel (float64).
static func ground_accel_gain(current_speed: float, top_speed: float, accel: float, dt: float) -> float:
	return accel_gain(current_speed, top_speed, top_speed, accel, dt)


static func air_accel_gain(current_speed: float, top_speed: float, accel: float, dt: float) -> float:
	return accel_gain(current_speed, minf(top_speed, AIR_CAP), top_speed, accel, dt)


## Velocity delta on the ground. current_speed = velocity.dot(wish_dir).
static func ground_accel(wish_dir: Vector2, current_speed: float, top_speed: float, accel: float, dt: float) -> Vector2:
	return wish_dir * ground_accel_gain(current_speed, top_speed, accel, dt)


## Velocity delta in the air. Same shape as ground_accel, but the gap check is
## capped at 30 while the slice size still uses the full top_speed.
static func air_accel(wish_dir: Vector2, current_speed: float, top_speed: float, accel: float, dt: float) -> Vector2:
	return wish_dir * air_accel_gain(current_speed, top_speed, accel, dt)


## ---- Phase 2: stamina, jump, bhop cap (only after phase 1 passes) ----

const GRAVITY := 800.0
## sqrt(2.0 * 800.0 * 45.0): up-speed of a fresh jump. The handoff's 268.33 is this, rounded.
const JUMP_SPEED := 268.32815729997475
const STAMINA_MS := 1315.789429
const BHOP_FACTOR := 1.2
const BHOP_PENALTY := 0.8


## 0..1 multiplier from the jump-stamina timer: 0.75 right after a jump, 1.0 once it has run out.
static func stamina_ratio(timer_ms: float) -> float:
	if timer_ms <= 0.0:
		return 1.0
	return maxf(100.0 - timer_ms * 0.019, 0.0) / 100.0


## Timer after one tick of dt seconds.
static func stamina_tick(timer_ms: float, dt: float) -> float:
	return maxf(timer_ms - dt * 1000.0, 0.0)


## Up-speed of a jump taken with the given stamina timer running.
static func jump(timer_ms: float) -> float:
	return JUMP_SPEED * stamina_ratio(timer_ms)


## Scalar core: speed at jump time. Over 1.2 * maxspeed it drops to 0.8 of that limit.
static func bhop_cap_speed(speed: float, maxspeed: float) -> float:
	var cap := BHOP_FACTOR * maxspeed
	if speed > cap:
		return speed * (cap / speed) * BHOP_PENALTY
	return speed


## Bhop cap on a horizontal velocity.
static func bhop_cap(velocity: Vector2, maxspeed: float) -> Vector2:
	var speed := velocity.length()
	if speed <= 0.0:
		return velocity
	return velocity * (bhop_cap_speed(speed, maxspeed) / speed)


## One half of gravity (applied before and after the move, so arcs match at any tick rate).
static func gravity_half(vz: float, dt: float) -> float:
	return vz - GRAVITY * dt / 2.0


## ---- Phase 3: stamina also slows ground speed (separate from Phase 1/2) ----

## Ground top speed while the stamina timer runs. It sets both the speed cap and the accel slice.
static func ground_top_speed(maxspeed: float, timer_ms: float) -> float:
	return maxspeed * stamina_ratio(timer_ms)


## ---- Phase 4: collision v1 (one box + one step, no slope) and the shared step ----
## Used by both the client (prediction) and the server. Pure: state in, state out, only the
## fixed tick length. Custom box tests, no Godot physics bodies.

const TICK_RATE := 128.0
const MAX_SPEED := 250.0      # knife
const ACCEL := 10.0
const AIR_ACCEL := 10.0
const HULL_HALF := 16.0       # player hull is a 32 x 32 box in the floor plane
const STEP_HEIGHT := 18.0     # biggest ledge walked up without jumping

## ---- Crouch (specs/goldsrc_movement.md "Crouch (PROPOSED, Oct 17 2026)", rules K1-K11) ----
const CROUCH_SCALE := 0.5                     # locked: half-height crouch
const STAND_BODY := 72.0
const STAND_EYE := 64.0
const DUCK_BODY := CROUCH_SCALE * STAND_BODY  # 36.0
const DUCK_EYE := CROUCH_SCALE * STAND_EYE    # 32.0
## DECISION FOR JOAN switches (C6, C7, C8). Defaults are the proposals.
const DUCK_TIME_S := 0.4                      # C6
const DUCK_SPEED_FACTOR := 0.333              # C7
const AIR_DUCK_LIFTS_FEET := true             # C8
const AIR_DUCK_LIFT := (STAND_BODY - DUCK_BODY) / 2.0   # 18.0
const RUN_SPEED := 140.0                      # move_state "run" threshold (strictly greater)


## K4: the transition completes on the first tick where duck_ticks / tick_rate >= DUCK_TIME_S.
static func duck_complete(duck_ticks: int, tick_rate: float) -> bool:
	return float(duck_ticks) / tick_rate >= DUCK_TIME_S - 1.0e-9


## K3: eye height after duck_ticks ticks of holding duck on the ground (linear 64.0 -> 32.0).
static func duck_eye_height(duck_ticks: int, tick_rate: float) -> float:
	if duck_complete(duck_ticks, tick_rate):
		return DUCK_EYE
	return STAND_EYE - (STAND_EYE - DUCK_EYE) * ((float(duck_ticks) / tick_rate) / DUCK_TIME_S)


static func hull_height(s: PlayerState) -> float:
	return DUCK_BODY if s.ducked else STAND_BODY


## Crouch fraction 0.0 (standing) .. 1.0 (fully ducked) for the blended hitbox and remote models (Addendum 1 A1-a / 3).
## 1.0 if ducked, the transition progress while the ground duck is in progress, else 0.0.
static func duck_fraction(s: PlayerState) -> float:
	if s.ducked:
		return 1.0
	if s.in_duck:
		return clampf((float(s.duck_ticks) / TICK_RATE) / DUCK_TIME_S, 0.0, 1.0)
	return 0.0


## K11, seam D6. Eye height above the feet.
static func eye_height(s: PlayerState) -> float:
	if s.ducked:
		return DUCK_EYE
	if s.in_duck:
		return duck_eye_height(s.duck_ticks, TICK_RATE)
	return STAND_EYE


## K11, seam D6. Evidence / hitbox stance: 0 stand, 1 crouch, 2 air, 3 crouch-air.
## The ground transition counts as stand (the hull is still 72.0).
static func stance_for_hitbox(s: PlayerState) -> int:
	return (1 if s.ducked else 0) | (0 if s.on_ground else 2)


## K11, seam D6. HUD / recoil move state: 0 stand, 1 crouch, 2 air, 3 run. Order: air, run, crouched, stand.
static func move_state_for_hud(s: PlayerState) -> int:
	if not s.on_ground:
		return 2
	if sqrt(s.vel_x * s.vel_x + s.vel_z * s.vel_z) > RUN_SPEED:
		return 3
	if s.ducked:
		return 1
	return 0


## World = floor at y = 0 plus boxes. Each box is [min_x, min_z, max_x, max_z, top] with an
## optional 6th value bottom (default 0.0: standing on the floor). v1 default: one box (the
## wall) and one step. default_world() never changes.
static func default_world() -> Array:
	return [
		PackedFloat64Array([300.0, -100.0, 364.0, 100.0, 128.0]),    # the box
		PackedFloat64Array([-200.0, -100.0, -104.0, 100.0, 16.0]),   # the step
	]


## Test-only world (Phase 1): the default world plus an overhang (crouched 36.0 fits under
## 40.0, standing 72.0 does not) and a 40-unit cover box.
static func crouch_test_world() -> Array:
	var w := default_world()
	w.append(PackedFloat64Array([500.0, -100.0, 600.0, 100.0, 128.0, 40.0]))   # overhang
	w.append(PackedFloat64Array([700.0, -100.0, 716.0, 100.0, 40.0]))          # cover
	return w


static func _bottom(b: PackedFloat64Array) -> float:
	return b[5] if b.size() > 5 else 0.0


## K10: highest top among boxes under the hull at (x, z) that the feet can stand on (top at or
## below ref_feet); 0.0 (the floor) when none.
static func support_height(world: Array, x: float, z: float, ref_feet: float = 1.0e30) -> float:
	var h := 0.0
	for i in world.size():
		var b: PackedFloat64Array = world[i]
		if b[4] <= ref_feet and x + HULL_HALF > b[0] and x - HULL_HALF < b[2] and z + HULL_HALF > b[1] and z - HULL_HALF < b[3]:
			h = maxf(h, b[4])
	return h


## Index of the tallest box that blocks a hull of `height` at (x, feet, z); -1 if none.
## A box blocks if its vertical span [bottom, top] overlaps [feet, feet + height].
static func blocking_box(world: Array, x: float, feet: float, z: float, height: float = STAND_BODY) -> int:
	var best := -1
	var best_top := feet
	for i in world.size():
		var b: PackedFloat64Array = world[i]
		if b[4] > best_top and _bottom(b) < feet + height and x + HULL_HALF > b[0] and x - HULL_HALF < b[2] and z + HULL_HALF > b[1] and z - HULL_HALF < b[3]:
			best = i
			best_top = b[4]
	return best


## K7: does the standing hull fit at these feet?
static func fits_standing(world: Array, x: float, feet: float, z: float) -> bool:
	return blocking_box(world, x, feet, z, STAND_BODY) < 0


static func _move_x(world: Array, s: PlayerState, dt: float, h: float) -> void:
	var nx := s.pos_x + s.vel_x * dt
	var i := blocking_box(world, nx, s.pos_y, s.pos_z, h)
	if i < 0:
		s.pos_x = nx
		return
	var b: PackedFloat64Array = world[i]
	if s.on_ground and b[4] - s.pos_y <= STEP_HEIGHT and blocking_box(world, nx, b[4], s.pos_z, h) < 0:
		s.pos_x = nx
		s.pos_y = b[4]
		return
	s.pos_x = b[0] - HULL_HALF if s.vel_x > 0.0 else b[2] + HULL_HALF
	s.vel_x = 0.0


static func _move_z(world: Array, s: PlayerState, dt: float, h: float) -> void:
	var nz := s.pos_z + s.vel_z * dt
	var i := blocking_box(world, s.pos_x, s.pos_y, nz, h)
	if i < 0:
		s.pos_z = nz
		return
	var b: PackedFloat64Array = world[i]
	if s.on_ground and b[4] - s.pos_y <= STEP_HEIGHT and blocking_box(world, s.pos_x, b[4], nz, h) < 0:
		s.pos_z = nz
		s.pos_y = b[4]
		return
	s.pos_z = b[1] - HULL_HALF if s.vel_z > 0.0 else b[3] + HULL_HALF
	s.vel_z = 0.0


## K3-K7: crouch handling for this tick (after the timers, before the jump).
static func _crouch(s: PlayerState, duck_held: bool, world: Array) -> void:
	if s.on_ground:
		if duck_held:
			if not s.ducked:
				s.duck_ticks += 1
				s.in_duck = true
				if duck_complete(s.duck_ticks, TICK_RATE):
					s.ducked = true
					s.in_duck = false
		elif s.ducked:
			if fits_standing(world, s.pos_x, s.pos_y, s.pos_z):
				s.ducked = false
				s.duck_ticks = 0
				s.in_duck = false
		else:
			s.duck_ticks = 0
			s.in_duck = false
	else:
		if duck_held:
			if not s.ducked:
				s.ducked = true
				s.in_duck = false
				s.duck_ticks = 0
				if AIR_DUCK_LIFTS_FEET:
					s.pos_y += AIR_DUCK_LIFT
		elif s.ducked:
			var new_feet := s.pos_y - AIR_DUCK_LIFT if AIR_DUCK_LIFTS_FEET else s.pos_y
			var sup := support_height(world, s.pos_x, s.pos_z, s.pos_y)
			var landed := false
			if new_feet <= sup:
				new_feet = sup
				landed = true
			if fits_standing(world, s.pos_x, new_feet, s.pos_z):
				s.ducked = false
				s.pos_y = new_feet
				if landed:
					s.on_ground = true
					s.vel_up = 0.0
		else:
			s.duck_ticks = 0
			s.in_duck = false


## One 128 Hz tick for one player, in place. Order follows specs/goldsrc_movement.md (K9):
## timers, crouch, jump (bhop cap, launch, no friction that tick), friction, gravity half,
## accelerate + move (X then Z, step-up), gravity half, land.
static func step(s: PlayerState, cmd: InputCmd, world: Array) -> void:
	var dt := 1.0 / TICK_RATE
	s.stamina_ms = stamina_tick(s.stamina_ms, dt)

	var b := cmd.buttons
	_crouch(s, (b & InputCmd.BTN_DUCK) != 0, world)
	var h := DUCK_BODY if s.ducked else STAND_BODY
	var duck_factor := DUCK_SPEED_FACTOR if s.ducked else 1.0

	var fwd := 0.0
	var side := 0.0
	if b & InputCmd.BTN_FORWARD: fwd += 1.0
	if b & InputCmd.BTN_BACK: fwd -= 1.0
	if b & InputCmd.BTN_RIGHT: side += 1.0
	if b & InputCmd.BTN_LEFT: side -= 1.0
	var has_wish := fwd != 0.0 or side != 0.0
	var wx := 0.0
	var wz := 0.0
	if has_wish:
		var yaw := InputCmd.dequantize_yaw(cmd.yaw_q)
		var sy := sin(yaw)
		var cy := cos(yaw)
		wx = -fwd * sy + side * cy
		wz = -fwd * cy - side * sy
		var l := sqrt(wx * wx + wz * wz)
		wx /= l
		wz /= l

	var jump_pressed := (b & InputCmd.BTN_JUMP) != 0 and (s.prev_buttons & InputCmd.BTN_JUMP) == 0
	s.prev_buttons = b

	var jumped := false
	if s.on_ground and jump_pressed:
		var sp := sqrt(s.vel_x * s.vel_x + s.vel_z * s.vel_z)
		if sp > 0.0:
			var k := bhop_cap_speed(sp, MAX_SPEED) / sp
			s.vel_x *= k
			s.vel_z *= k
		s.vel_up = jump(s.stamina_ms)
		s.stamina_ms = STAMINA_MS
		s.on_ground = false
		jumped = true
	if s.on_ground and not jumped:
		var sp2 := sqrt(s.vel_x * s.vel_x + s.vel_z * s.vel_z)
		if sp2 > 0.0:
			var k2 := friction_speed(sp2, dt) / sp2
			s.vel_x *= k2
			s.vel_z *= k2

	if not s.on_ground:
		s.vel_up = gravity_half(s.vel_up, dt)

	if has_wish:
		var cur := s.vel_x * wx + s.vel_z * wz
		var gain := 0.0
		if s.on_ground:
			gain = ground_accel_gain(cur, ground_top_speed(MAX_SPEED, s.stamina_ms) * duck_factor, ACCEL, dt)
		else:
			gain = air_accel_gain(cur, MAX_SPEED * duck_factor, AIR_ACCEL, dt)
		s.vel_x += wx * gain
		s.vel_z += wz * gain

	_move_x(world, s, dt, h)
	_move_z(world, s, dt, h)

	if s.on_ground:
		var sup := support_height(world, s.pos_x, s.pos_z, s.pos_y)
		if s.pos_y > sup:
			if s.pos_y - sup <= STEP_HEIGHT:
				s.pos_y = sup
			else:
				s.on_ground = false
				s.vel_up = 0.0
	else:
		var feet_before := s.pos_y
		s.pos_y += s.vel_up * dt
		if s.vel_up > 0.0:
			# head against the underside of a box (only boxes with bottom > 0 can do this)
			for i in world.size():
				var bx: PackedFloat64Array = world[i]
				var bb := _bottom(bx)
				if bb >= feet_before + h and s.pos_y + h > bb and s.pos_x + HULL_HALF > bx[0] and s.pos_x - HULL_HALF < bx[2] and s.pos_z + HULL_HALF > bx[1] and s.pos_z - HULL_HALF < bx[3]:
					s.pos_y = bb - h
					s.vel_up = 0.0
		s.vel_up = gravity_half(s.vel_up, dt)
		var sup2 := support_height(world, s.pos_x, s.pos_z, feet_before)
		if s.pos_y <= sup2:
			s.pos_y = sup2
			s.vel_up = 0.0
			s.on_ground = true
