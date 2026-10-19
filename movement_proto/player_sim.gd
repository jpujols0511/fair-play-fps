class_name PlayerSim
extends RefCounted
## Kinematic player state stepped by hand with movement.gd. No physics bodies.
## Coordinates: Godot axes, 1 unit = 1 game unit. Horizontal velocity is (x, z); height is y.
## Per-tick order follows specs/goldsrc_movement.md: stamina countdown, jump (bhop cap,
## launch, no friction that tick), friction, gravity half, accelerate + move, gravity half, land.

const TICK_RATE := 128.0
const MAX_SPEED := 250.0   # knife
const ACCEL := 10.0
const AIR_ACCEL := 10.0

var position := Vector3.ZERO     # feet
var velocity := Vector2.ZERO     # horizontal (x, z)
var vz := 0.0                    # vertical speed (up is +)
var on_ground := true
var stamina_ms := 0.0
var autobhop := false            # hold-to-jump when true; off = fresh press only


func speed() -> float:
	return velocity.length()


## wish_dir: unit horizontal direction the player is pressing (or zero).
## jump_pressed: a fresh press arrived since the last tick.
func tick(wish_dir: Vector2, jump_pressed: bool) -> void:
	var dt := 1.0 / TICK_RATE
	stamina_ms = Movement.stamina_tick(stamina_ms, dt)

	var jumped := false
	if on_ground and jump_pressed:
		velocity = Movement.bhop_cap(velocity, MAX_SPEED)
		vz = Movement.jump(stamina_ms)
		stamina_ms = Movement.STAMINA_MS
		on_ground = false
		jumped = true
	if on_ground and not jumped:
		velocity = Movement.friction(velocity, dt)

	if not on_ground:
		vz = Movement.gravity_half(vz, dt)

	if wish_dir != Vector2.ZERO:
		var cur := velocity.dot(wish_dir)
		if on_ground:
			velocity += Movement.ground_accel(wish_dir, cur, Movement.ground_top_speed(MAX_SPEED, stamina_ms), ACCEL, dt)
		else:
			velocity += Movement.air_accel(wish_dir, cur, MAX_SPEED, AIR_ACCEL, dt)

	position.x += velocity.x * dt
	position.z += velocity.y * dt
	if not on_ground:
		position.y += vz * dt
		vz = Movement.gravity_half(vz, dt)
		if position.y <= 0.0:
			position.y = 0.0
			vz = 0.0
			on_ground = true
