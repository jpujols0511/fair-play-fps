extends Node
## Stand-in for NetClient (crosshair spec review note f). Same HUD interface:
##   signal snapshot_received(snap: Dictionary)
##   func get_latest() -> Dictionary
## Keys: server_tick (int), accuracy (float), punch_pitch (float, deg, + = up),
##       punch_yaw (float, deg), move_state (int: 0 stand, 1 crouch, 2 air, 3 run).
##
## Runs a scripted 9-second loop at 128 tick, sends every 2nd tick (64/sec),
## with an optional one-way-pair delay so you can feel note (a).
## The numbers are DEMO CURVES shaped after goldsrc_recoil_spread.md
## (AK standing / running / air spread, AK standing kick), not the real sim.

signal snapshot_received(snap: Dictionary)

const TICK_RATE: float = 128.0
const TICK_DT: float = 1.0 / 128.0
const SEND_EVERY: int = 2
const LOOP_S: float = 9.0

## Round-trip delay added before a snapshot reaches the HUD (0 / 40 / 80 / 150 ms).
@export var delay_ms: float = 80.0
@export var rng_seed: int = 1337
@export var autorun: bool = true

var server_tick: int = 0
var segment: String = "stand"

var _loop_tick: int = 0
var _acc_time: float = 0.0
var _now: float = 0.0
var _queue: Array = []
var _latest: Dictionary = {}
var _rng := RandomNumberGenerator.new()

# spray state
var _shots: int = 0  # burst counter (drives accuracy)
var _fired: int = 0  # shots fired this loop
var _next_fire: float = 0.0
var _last_shot_t: float = -100.0
var _decay_t: float = 0.0
var _punch_up: float = 0.0
var _punch_side: float = 0.0
var _side_dir: float = 1.0


# ---------- wire quantization (review note d) ----------

static func quantize_accuracy(a: float) -> int:
	return int(round(clampf(a, 0.0, 2.0) * 65535.0 / 2.0))


static func dequantize_accuracy(q: int) -> float:
	return float(q) * 2.0 / 65535.0


static func quantize_angle(deg: float) -> int:
	return clampi(int(round(deg * 65536.0 / 360.0)), -32768, 32767)


static func dequantize_angle(q: int) -> float:
	return float(q) * 360.0 / 65536.0


static func make_snapshot(tick: int, accuracy: float, punch_pitch: float,
		punch_yaw: float, move_state: int) -> Dictionary:
	return {
		"server_tick": tick,
		"accuracy": dequantize_accuracy(quantize_accuracy(accuracy)),
		"punch_pitch": dequantize_angle(quantize_angle(punch_pitch)),
		"punch_yaw": dequantize_angle(quantize_angle(punch_yaw)),
		"move_state": clampi(move_state, 0, 3),
	}


# ---------- interface ----------

func get_latest() -> Dictionary:
	return _latest


func reset() -> void:
	_rng.seed = rng_seed
	_loop_tick = 0
	_shots = 0
	_fired = 0
	_next_fire = 0.0
	_last_shot_t = -100.0
	_decay_t = 0.0
	_punch_up = 0.0
	_punch_side = 0.0
	_side_dir = 1.0


func _ready() -> void:
	reset()


func _process(delta: float) -> void:
	if not autorun:
		return
	_now += delta
	_acc_time += delta
	while _acc_time >= TICK_DT:
		_acc_time -= TICK_DT
		var snap: Dictionary = step_tick()
		if not snap.is_empty():
			_queue.append([_now + delay_ms / 1000.0, snap])
	while not _queue.is_empty() and _queue[0][0] <= _now:
		_latest = _queue.pop_front()[1]
		snapshot_received.emit(_latest)


## Advances the scripted "server" one tick. Returns a snapshot on send ticks, else {}.
func step_tick() -> Dictionary:
	var t: float = float(_loop_tick) * TICK_DT
	var state: int = 0
	var spread: float = 0.0
	var acc: float = 0.2
	if t < 2.0:
		segment = "standing still"
		state = 0
		spread = 0.0275 * acc
	elif t < 3.5:
		segment = "running"
		state = 3
		spread = 0.04 + 0.07 * acc
	elif t < 4.3:
		segment = "air"
		state = 2
		spread = 0.04 + 0.40 * acc
	elif t < 5.0:
		segment = "landed, standing"
		state = 0
		spread = 0.0275 * acc
	else:
		segment = "AK spray (standing)" if _fired < 30 else "spray recovery"
		state = 0
		if t < 5.0 + TICK_DT:
			_next_fire = t
		if _fired < 30 and t >= _next_fire:
			_fire(t)
		_recover_burst(t)
		if _shots > 0:
			acc = minf(1.25, pow(float(_shots), 3.0) / 200.0 + 0.35)
		spread = 0.0275 * acc
	_decay_punch()
	_loop_tick += 1
	server_tick += 1
	if t >= LOOP_S - TICK_DT:
		reset()
	if server_tick % SEND_EVERY != 0:
		return {}
	return make_snapshot(server_tick, spread, _punch_up, _punch_side, state)


func _fire(t: float) -> void:
	_shots += 1
	_fired += 1
	_last_shot_t = t
	_decay_t = t + 0.4
	_next_fire += 0.0955
	var up_add: float = 1.0
	var side_add: float = 0.375
	if _shots > 1:
		up_add += 0.175 * float(_shots - 1)
		side_add += 0.0375 * float(_shots - 1)
	# Demo simplification: clamp at the max (the real rule lives in Devin's recoil code).
	_punch_up = minf(_punch_up + up_add, 5.75)
	if _rng.randi_range(0, 8) == 0:
		_side_dir = -_side_dir
	_punch_side = clampf(_punch_side + side_add * _side_dir, -1.75, 1.75)


func _recover_burst(t: float) -> void:
	# After 0.4 s without firing, the burst counter drops by 1 every 0.0225 s.
	if _shots > 0 and t - _last_shot_t > 0.4:
		while _shots > 0 and t >= _decay_t:
			_shots -= 1
			_decay_t += 0.0225


func _decay_punch() -> void:
	var mag: float = sqrt(_punch_up * _punch_up + _punch_side * _punch_side)
	if mag <= 0.0:
		return
	var drop: float = (10.0 + 0.5 * mag) * TICK_DT
	var k: float = maxf(mag - drop, 0.0) / mag
	_punch_up *= k
	_punch_side *= k
