class_name RemotePath
extends RefCounted
## Scripted remote players: server-side entities with an exact pose for any tick (game frame).
## They never predict and the client never sees this class, only snapshots.
## Closed-form kinds: LINEAR (back and forth, smooth turns), LINEAR_STRAIGHT (test only),
## CIRCLE, PEEK. Stepped kinds are driven through Movement.step with a scripted input, so they
## include real ground and air movement: STRAFE_JIGGLE, CROUCH_TOGGLE, BHOP_CHAIN.
## Pose layout: [x, y(feet), z, yaw(rad), pitch(rad), stance(0..3), alive(0/1), duck fraction].

enum Kind { LINEAR, LINEAR_STRAIGHT, CIRCLE, STRAFE_JIGGLE, PEEK, CROUCH_TOGGLE, BHOP_CHAIN, STATIC }

const SPEED := 250.0
const TURN_ACCEL := 2500.0        # reversal at the ends of LINEAR: 250.0 -> 0.0 -> -250.0 in 0.2 s

var kind: Kind = Kind.LINEAR
var slot := 1
var team := 2                     # 1 = viewer's team (always sent by culling), 2 = enemy (culled by line of sight)
var static_crouched := false      # STATIC kind: stands (stance 0) or crouches (stance 1) in place
var spawn_tick := 0
var despawn_tick := -1            # -1 = never
var teleports: Array = []         # [tick, dx, dz]: from this tick on the whole path is shifted
var teleport_ticks: PackedInt32Array = PackedInt32Array()

# closed-form parameters
var ox := 0.0                     # origin (x, z)
var oz := 0.0
var dir_x := 1.0                  # unit direction (LINEAR)
var dir_z := 0.0
var length := 600.0               # cruise distance between the turns (LINEAR)
var radius := 200.0               # CIRCLE
var peek_to_x := 0.0              # PEEK: cover (ox, oz) -> open (peek_to_x, peek_to_z)
var peek_to_z := 0.0
var peek_out_tick := 0
var peek_back_tick := 0
var period := 16                  # STRAFE_JIGGLE ticks per full left-right cycle
var phase := 0                    # tick offset so paths do not move in lockstep

# stepped state
var _world: Array = []
var _state := PlayerState.new()
var _next_tick := 0
var _cache := PackedFloat64Array()       # 8 values per tick


static func make_linear(p_slot: int, x: float, z: float, ang: float, cruise: float = 600.0) -> RemotePath:
	var r := RemotePath.new()
	r.kind = Kind.LINEAR
	r.slot = p_slot
	r.ox = x
	r.oz = z
	r.dir_x = cos(ang)
	r.dir_z = sin(ang)
	r.length = cruise
	return r


static func make_straight(p_slot: int, x: float, z: float, ang: float) -> RemotePath:
	var r := make_linear(p_slot, x, z, ang)
	r.kind = Kind.LINEAR_STRAIGHT
	return r


static func make_circle(p_slot: int, cx: float, cz: float, rad: float = 200.0) -> RemotePath:
	var r := RemotePath.new()
	r.kind = Kind.CIRCLE
	r.slot = p_slot
	r.ox = cx
	r.oz = cz
	r.radius = rad
	return r


static func make_peek(p_slot: int, cover_x: float, cover_z: float, open_x: float, open_z: float, out_tick: int, back_tick: int) -> RemotePath:
	var r := RemotePath.new()
	r.kind = Kind.PEEK
	r.slot = p_slot
	r.ox = cover_x
	r.oz = cover_z
	r.peek_to_x = open_x
	r.peek_to_z = open_z
	r.peek_out_tick = out_tick
	r.peek_back_tick = back_tick
	return r


static func make_static(p_slot: int, x: float, z: float, crouched: bool = false, p_team: int = 2) -> RemotePath:
	var r := RemotePath.new()
	r.kind = Kind.STATIC
	r.slot = p_slot
	r.ox = x
	r.oz = z
	r.static_crouched = crouched
	r.team = p_team
	return r


static func make_stepped(p_slot: int, p_kind: Kind, x: float, z: float, p_world: Array = []) -> RemotePath:
	var r := RemotePath.new()
	r.kind = p_kind
	r.slot = p_slot
	r._state.pos_x = x
	r._state.pos_z = z
	r._world = p_world
	return r


func present(tick: int) -> bool:
	return tick >= spawn_tick and (despawn_tick < 0 or tick < despawn_tick)


func add_teleport(tick: int, dx: float, dz: float) -> void:
	teleports.append([tick, dx, dz])
	teleport_ticks.append(tick)


func _shift(tick: float) -> Vector2:
	var sx := 0.0
	var sz := 0.0
	for t in teleports:
		if tick >= float(t[0]):
			sx += t[1]
			sz += t[2]
	return Vector2(sx, sz)


## Travelled distance along the LINEAR path at time t seconds, and the direction sign (+1 / -1).
## One cycle: cruise out (length / SPEED), turn (0.2 s), cruise back, turn.
func _linear_u(t: float) -> Vector2:
	var tt := length / SPEED
	var ramp := SPEED / TURN_ACCEL                     # 0.1 s to stop
	var turn := 2.0 * ramp
	var half := tt + turn
	var cyc := 2.0 * half
	var c := fposmod(t, cyc)
	var back := c >= half
	if back:
		c -= half
	var u := 0.0
	var sgn := 1.0
	if c < tt:
		u = SPEED * c
	else:
		var s := c - tt
		if s < ramp:
			u = length + SPEED * s - 0.5 * TURN_ACCEL * s * s
		else:
			var s2 := s - ramp
			u = length + SPEED * ramp - 0.5 * TURN_ACCEL * ramp * ramp - 0.5 * TURN_ACCEL * s2 * s2
			sgn = -1.0
	if back:
		u = length - u
		sgn = -sgn
	return Vector2(u, sgn)


## Exact position at a fractional tick (closed-form kinds evaluate directly, stepped kinds
## interpolate their per-tick poses linearly). [x, y, z].
func exact_at(t: float, tick_rate: float = 128.0) -> PackedFloat64Array:
	var out := PackedFloat64Array([0.0, 0.0, 0.0])
	match kind:
		Kind.LINEAR, Kind.LINEAR_STRAIGHT, Kind.CIRCLE, Kind.PEEK, Kind.STATIC:
			var p := _closed_pose(t, tick_rate)
			var sh := _shift(t)
			out[0] = p[0] + sh.x
			out[1] = p[1]
			out[2] = p[2] + sh.y
		_:
			var f := floorf(t)
			var i := int(f)
			var a := pose(i)
			var b := pose(i + 1)
			var w := t - f
			for k in 3:
				out[k] = a[k] + (b[k] - a[k]) * w
	return out


func _closed_pose(t: float, tick_rate: float) -> PackedFloat64Array:
	var sec := t / tick_rate
	var x := ox
	var z := oz
	var yaw := 0.0
	match kind:
		Kind.LINEAR_STRAIGHT:
			x = ox + dir_x * SPEED * sec
			z = oz + dir_z * SPEED * sec
			yaw = atan2(-dir_x, -dir_z)
		Kind.LINEAR:
			var uv := _linear_u(sec)
			x = ox + dir_x * uv.x
			z = oz + dir_z * uv.x
			yaw = atan2(-dir_x * uv.y, -dir_z * uv.y)
		Kind.CIRCLE:
			var th := (SPEED / radius) * sec
			x = ox + radius * cos(th)
			z = oz + radius * sin(th)
			yaw = atan2(sin(th), -cos(th))        # tangent (-sin, cos); yaw = atan2(-dx, -dz)
		Kind.PEEK:
			var d := Vector2(peek_to_x - ox, peek_to_z - oz)
			var dist := d.length()
			var travel := dist / SPEED * tick_rate    # ticks to cross
			var f := 0.0
			if t >= float(peek_out_tick) and t < float(peek_back_tick):
				f = clampf((t - float(peek_out_tick)) / travel, 0.0, 1.0)
			elif t >= float(peek_back_tick):
				f = 1.0 - clampf((t - float(peek_back_tick)) / travel, 0.0, 1.0)
			x = ox + d.x * f
			z = oz + d.y * f
			yaw = atan2(-d.x, -d.y)
	var stance := 1.0 if (kind == Kind.STATIC and static_crouched) else 0.0
	return PackedFloat64Array([x, 0.0, z, yaw, 0.0, stance, 1.0, stance])


## Horizontal velocity (u/s) at an integer tick from the last two poses; zero across a teleport.
func vel(tick: int) -> Vector2:
	if tick < 1:
		return Vector2.ZERO
	var a := pose(tick)
	var b := pose(tick - 1)
	var dx := a[0] - b[0]
	var dz := a[2] - b[2]
	if sqrt(dx * dx + dz * dz) > 64.0:
		return Vector2.ZERO
	return Vector2(dx, dz) * Movement.TICK_RATE


## Pose at an integer tick (positions include teleport shifts). Stepped kinds must be asked
## in increasing tick order the first time (the server does); earlier ticks come from the cache.
func pose(tick: int) -> PackedFloat64Array:
	var p: PackedFloat64Array
	match kind:
		Kind.LINEAR, Kind.LINEAR_STRAIGHT, Kind.CIRCLE, Kind.PEEK, Kind.STATIC:
			p = _closed_pose(float(tick), 128.0)
		_:
			_advance_to(tick)
			var o := tick * 8
			p = _cache.slice(o, o + 8)
	if not teleports.is_empty():
		var s := _shift(float(tick))
		p[0] += s.x
		p[2] += s.y
	return p


func _advance_to(tick: int) -> void:
	while _next_tick <= tick:
		var t := _next_tick
		var buttons := 0
		var yaw := 0.0
		var tt := t + phase
		match kind:
			Kind.STRAFE_JIGGLE:
				var half := maxi(period / 2, 1)
				buttons = InputCmd.BTN_LEFT if (tt / half) % 2 == 0 else InputCmd.BTN_RIGHT
			Kind.CROUCH_TOGGLE:
				buttons = InputCmd.BTN_DUCK if (tt / 64) % 2 == 0 else 0
			Kind.BHOP_CHAIN:
				var jb := InputCmd.BTN_JUMP if tt % 2 == 0 else 0
				var sp := _state.speed()
				if tt < 40 or sp < 200.0:
					buttons = InputCmd.BTN_FORWARD | jb
				else:
					var dd := maxf(Movement.AIR_CAP - Movement.AIR_ACCEL * Movement.MAX_SPEED / Movement.TICK_RATE, 0.0)
					var th := acos(clampf(dd / sp, -1.0, 1.0))
					yaw = -(atan2(_state.vel_z, _state.vel_x) + th)
					buttons = InputCmd.BTN_RIGHT | jb
		Movement.step(_state, InputCmd.make(t, t, buttons, InputCmd.quantize_yaw(yaw), 0), _world)
		var facing := InputCmd.dequantize_yaw(InputCmd.quantize_yaw(yaw))
		_cache.append_array(PackedFloat64Array([_state.pos_x, _state.pos_y, _state.pos_z, facing, 0.0,
			float(Movement.stance_for_hitbox(_state)), 1.0, Movement.duck_fraction(_state)]))
		_next_tick += 1


## The fixed set used by the measurement runner: the first `count` of these (slots 1..count).
## All start far from the default world's boxes. Stepped paths use an empty world.
static func make_set(count: int) -> Array:
	var out: Array = []
	var makers := [
		func(sl): return make_linear(sl, -1500.0, -800.0, 0.0),
		func(sl): return make_circle(sl, 1500.0, -1500.0),
		func(sl): return make_stepped(sl, Kind.BHOP_CHAIN, -2000.0, 0.0),
		func(sl): return make_stepped(sl, Kind.STRAFE_JIGGLE, 2000.0, 0.0),
		func(sl): return make_linear(sl, 800.0, 1200.0, PI / 2.0, 900.0),
		func(sl): return make_stepped(sl, Kind.CROUCH_TOGGLE, 2000.0, 600.0),
		func(sl): return make_circle(sl, -1500.0, 1500.0, 300.0),
		func(sl):
			var r := make_stepped(sl, Kind.STRAFE_JIGGLE, 2400.0, -600.0)
			r.period = 24
			r.phase = 4
			return r,
		func(sl):
			var r := make_stepped(sl, Kind.BHOP_CHAIN, -2400.0, 900.0)
			r.phase = 7
			return r,
		func(sl): return make_linear(sl, 0.0, 2000.0, 1.0, 1200.0),
	]
	for i in mini(count, makers.size()):
		out.append((makers[i] as Callable).call(i + 1))
	return out
