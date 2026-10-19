class_name InterpBuffer
extends RefCounted
## Entity interpolation for ONE remote slot (specs/remote_interp_v0.1.md, PROPOSED).
## A ring of up to 16 samples ordered by server tick; sample(render_tick) draws the player
## between the two samples around render_tick. Hold when starved (C2 = 0), optional capped
## extrapolation, 4-tick blend back, snap on respawn / teleport (> 64 units), removal.
## Written to match tools/interp_ref.py exactly (golden: tests/test_interp.gd).

const RING := 16
const SNAP_DIST := 64.0
const BLEND_TICKS := 4

var extrap := 0.0                 # C2: ticks of extrapolation allowed (0.0 = hold)
var n := 0
var ticks := PackedInt32Array()
var xs := PackedFloat64Array()
var ys := PackedFloat64Array()
var zs := PackedFloat64Array()
var yaw_qs := PackedInt32Array()
var pitch_qs := PackedInt32Array()
var stances := PackedInt32Array()
var alives := PackedInt32Array()
var ducks := PackedFloat64Array()      # duck fraction per sample (q / 255.0), lerped like position
var news := PackedInt32Array()

var starving := false
var _blend_left := 0
var _blend_n := 0
var _off_x := 0.0
var _off_y := 0.0
var _off_z := 0.0
var _has_last := false
var _last_x := 0.0
var _last_y := 0.0
var _last_z := 0.0

# result of the last sample() call
var out_x := 0.0
var out_y := 0.0
var out_z := 0.0
var out_yaw := 0.0
var out_pitch := 0.0
var out_stance := 0
var out_alive := 0
var out_duck := 0.0               # lerped between the bracketing samples; remote crouch is DRAWN from this
var out_starved := false
var out_gap := 0                  # ticks between the two samples bracketing this draw (0 = held / starved)
var out_recovering := false      # starved, or drawn with a blend-back offset this call

# counters
var starved_ticks := 0
var snaps := 0


func _init(p_extrap: float = 0.0) -> void:
	extrap = p_extrap
	ticks.resize(RING + 1)
	xs.resize(RING + 1)
	ys.resize(RING + 1)
	zs.resize(RING + 1)
	yaw_qs.resize(RING + 1)
	pitch_qs.resize(RING + 1)
	stances.resize(RING + 1)
	alives.resize(RING + 1)
	ducks.resize(RING + 1)
	news.resize(RING + 1)


func is_empty() -> bool:
	return n == 0


func remove() -> void:
	n = 0
	starving = false
	_blend_left = 0
	_has_last = false


## x, y, z already dequantized (q / 8.0); yaw_q, pitch_q are the wire values.
func insert(tick: int, x: float, y: float, z: float, yaw_q: int, pitch_q: int, stance: int, alive: int, is_new: bool, duck: float = 0.0) -> void:
	if n > 0 and tick < ticks[0] and n >= RING:
		return
	var pos := -1
	for i in n:
		if ticks[i] == tick:
			pos = i
			break
	if pos < 0:
		pos = n
		while pos > 0 and ticks[pos - 1] > tick:
			ticks[pos] = ticks[pos - 1]
			xs[pos] = xs[pos - 1]
			ys[pos] = ys[pos - 1]
			zs[pos] = zs[pos - 1]
			yaw_qs[pos] = yaw_qs[pos - 1]
			pitch_qs[pos] = pitch_qs[pos - 1]
			stances[pos] = stances[pos - 1]
			alives[pos] = alives[pos - 1]
			ducks[pos] = ducks[pos - 1]
			news[pos] = news[pos - 1]
			pos -= 1
		n += 1
	ticks[pos] = tick
	xs[pos] = x
	ys[pos] = y
	zs[pos] = z
	yaw_qs[pos] = yaw_q
	pitch_qs[pos] = pitch_q
	stances[pos] = stance
	alives[pos] = alive
	ducks[pos] = duck
	news[pos] = 1 if is_new else 0
	if n > RING:
		for i in range(1, n):
			ticks[i - 1] = ticks[i]
			xs[i - 1] = xs[i]
			ys[i - 1] = ys[i]
			zs[i - 1] = zs[i]
			yaw_qs[i - 1] = yaw_qs[i]
			pitch_qs[i - 1] = pitch_qs[i]
			stances[i - 1] = stances[i]
			alives[i - 1] = alives[i]
			ducks[i - 1] = ducks[i]
			news[i - 1] = news[i]
		n -= 1


func _dist(i: int, j: int) -> float:
	var dx := xs[i] - xs[j]
	var dy := ys[i] - ys[j]
	var dz := zs[i] - zs[j]
	return sqrt(dx * dx + dy * dy + dz * dz)


static func _arc(a: float, b: float, t: float) -> float:
	var d := fposmod(b - a + PI, TAU) - PI
	return fposmod(a + d * t, TAU)


## Draws the slot at render_tick (a fractional server tick). Returns false if nothing is there.
## Call once per client tick (the blend-back is counted in calls).
func sample(render: float) -> bool:
	out_starved = false
	out_recovering = false
	out_gap = 0
	if n == 0:
		_has_last = false
		return false
	var a_i := 0
	var rx := 0.0
	var ry := 0.0
	var rz := 0.0
	var ryaw := 0.0
	var rpitch := 0.0
	var rduck := 0.0
	if render <= float(ticks[0]):
		a_i = 0
		rx = xs[0]
		ry = ys[0]
		rz = zs[0]
		ryaw = InputCmd.dequantize_yaw(yaw_qs[0])
		rpitch = InputCmd.dequantize_pitch(pitch_qs[0])
		rduck = ducks[0]
	else:
		a_i = 0
		for k in n:
			if float(ticks[k]) <= render:
				a_i = k
		rx = xs[a_i]
		ry = ys[a_i]
		rz = zs[a_i]
		ryaw = InputCmd.dequantize_yaw(yaw_qs[a_i])
		rpitch = InputCmd.dequantize_pitch(pitch_qs[a_i])
		rduck = ducks[a_i]
		if a_i == n - 1:
			if render > float(ticks[a_i]):
				out_starved = true
				if extrap > 0.0 and n >= 2 and news[a_i] == 0 and _dist(a_i - 1, a_i) <= SNAP_DIST:
					var span := float(ticks[a_i] - ticks[a_i - 1])
					var e := minf(render - float(ticks[a_i]), extrap)
					rx = xs[a_i] + (xs[a_i] - xs[a_i - 1]) / span * e
					ry = ys[a_i] + (ys[a_i] - ys[a_i - 1]) / span * e
					rz = zs[a_i] + (zs[a_i] - zs[a_i - 1]) / span * e
		else:
			var b_i := a_i + 1
			if not (news[b_i] == 1 or _dist(a_i, b_i) > SNAP_DIST):
				out_gap = ticks[b_i] - ticks[a_i]
				var t := (render - float(ticks[a_i])) / float(ticks[b_i] - ticks[a_i])
				rx = xs[a_i] + (xs[b_i] - xs[a_i]) * t
				ry = ys[a_i] + (ys[b_i] - ys[a_i]) * t
				rz = zs[a_i] + (zs[b_i] - zs[a_i]) * t
				ryaw = _arc(InputCmd.dequantize_yaw(yaw_qs[a_i]), InputCmd.dequantize_yaw(yaw_qs[b_i]), t)
				# pitch is clamped to [-PI/2, PI/2] and never wraps: a plain lerp, signed (yaw alone takes the shortest arc)
				rpitch = lerpf(InputCmd.dequantize_pitch(pitch_qs[a_i]), InputCmd.dequantize_pitch(pitch_qs[b_i]), t)
				rduck = lerpf(ducks[a_i], ducks[b_i], t)
	out_x = rx
	out_y = ry
	out_z = rz
	out_yaw = ryaw
	out_pitch = rpitch
	out_duck = rduck
	out_stance = stances[a_i]
	out_alive = alives[a_i]
	if out_starved:
		out_recovering = true
		starving = true
		_blend_left = 0
		starved_ticks += 1
	else:
		if starving:
			starving = false
			if _has_last:
				var ox := _last_x - rx
				var oy := _last_y - ry
				var oz := _last_z - rz
				if sqrt(ox * ox + oy * oy + oz * oz) > SNAP_DIST:
					_blend_left = 0
					snaps += 1
				else:
					_off_x = ox
					_off_y = oy
					_off_z = oz
					_blend_left = BLEND_TICKS
					_blend_n = 0
		if _blend_left > 0:
			out_recovering = true
			_blend_n += 1
			var f := float(BLEND_TICKS - _blend_n) / float(BLEND_TICKS)
			out_x = rx + _off_x * f
			out_y = ry + _off_y * f
			out_z = rz + _off_z * f
			_blend_left -= 1
	_has_last = true
	_last_x = out_x
	_last_y = out_y
	_last_z = out_z
	return true
