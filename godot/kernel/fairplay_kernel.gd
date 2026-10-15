extends RefCounted
## Fairness kernel: GDScript port of prototype/fairplay_sim.py.
##
## Integer-only on purpose. The result digest must match the Python contract
## oracle byte for byte, so the same command stream proves the same outcome in
## both implementations. Invariant 1: clients submit intent; this code decides
## movement, cadence, ammunition and evidence.

const TICK_RATE := 64
const SUPPORTED_TICK_RATES := [64, 128]
const INPUT_SCALE := 1000
const MAX_SPEED := 48
const ACCELERATION := 8
const FRICTION := 6
const FIRE_INTERVAL_TICKS := 8
const MAGAZINE_SIZE := 12

var tick: int = 0
var tick_rate: int = TICK_RATE
var players: Dictionary = {}
var evidence: Array = []
var _queued: Dictionary = {}
var _position_remainders: Dictionary = {}


func _init(player_ids: Array, requested_tick_rate: int = TICK_RATE) -> void:
	assert(SUPPORTED_TICK_RATES.has(requested_tick_rate),
		"tick rate must be 64 or 128")
	tick_rate = requested_tick_rate
	var ids: Array = player_ids.duplicate()
	ids.sort()
	for player_id in ids:
		players[player_id] = new_state()
		_position_remainders[player_id] = [0, 0]


static func new_state() -> Dictionary:
	return {
		"x": 0, "y": 0, "velocity_x": 0, "velocity_y": 0,
		"yaw_millidegrees": 0, "health": 100, "ammunition": MAGAZINE_SIZE,
		"next_fire_tick": 0, "last_sequence": -1,
	}


static func command(sequence: int, move_x: int = 0, move_y: int = 0,
		yaw_millidegrees: int = 0, fire: bool = false) -> Dictionary:
	return {
		"sequence": sequence, "move_x": move_x, "move_y": move_y,
		"yaw_millidegrees": yaw_millidegrees, "fire": fire,
	}


## Python-style floor division (GDScript int division truncates toward zero).
static func floor_div(a: int, b: int) -> int:
	var q: int = a / b
	if a % b != 0 and ((a < 0) != (b < 0)):
		q -= 1
	return q


static func isqrt(n: int) -> int:
	if n <= 0:
		return 0
	var r: int = int(sqrt(float(n)))
	while r * r > n:
		r -= 1
	while (r + 1) * (r + 1) <= n:
		r += 1
	return r


static func approach_zero(value: int, amount: int) -> int:
	if value > 0:
		return maxi(0, value - amount)
	if value < 0:
		return mini(0, value + amount)
	return 0


func submit(player_id: String, cmd: Dictionary) -> bool:
	if not players.has(player_id):
		return false
	var state: Dictionary = players[player_id]
	if cmd["sequence"] <= state["last_sequence"]:
		_record(player_id, "stale_input", {"sequence": cmd["sequence"]})
		return false
	if _queued.has(player_id) and cmd["sequence"] <= _queued[player_id]["sequence"]:
		_record(player_id, "reordered_input", {"sequence": cmd["sequence"]})
		return false
	_queued[player_id] = cmd
	return true


func step() -> void:
	var ids: Array = players.keys()
	ids.sort()
	for player_id in ids:
		var state: Dictionary = players[player_id]
		# A missing input is a neutral tick: no move, no fire, same facing, and
		# no sequence number consumed (decision 0002).
		var cmd: Dictionary = _queued.get(player_id,
			command(state["last_sequence"], 0, 0, state["yaw_millidegrees"]))
		_queued.erase(player_id)
		_apply_input(player_id, state, cmd)
	tick += 1


func _apply_input(player_id: String, state: Dictionary, cmd: Dictionary) -> void:
	var move_x: int = clampi(cmd["move_x"], -INPUT_SCALE, INPUT_SCALE)
	var move_y: int = clampi(cmd["move_y"], -INPUT_SCALE, INPUT_SCALE)
	if move_x != cmd["move_x"] or move_y != cmd["move_y"]:
		_record(player_id, "input_clamped", {
			"requested_x": cmd["move_x"], "requested_y": cmd["move_y"],
			"accepted_x": move_x, "accepted_y": move_y,
		})
	if move_x == 0:
		state["velocity_x"] = approach_zero(
			state["velocity_x"], FRICTION * TICK_RATE / tick_rate)
	else:
		state["velocity_x"] += floor_div(
			ACCELERATION * TICK_RATE * move_x, tick_rate * INPUT_SCALE)
	if move_y == 0:
		state["velocity_y"] = approach_zero(
			state["velocity_y"], FRICTION * TICK_RATE / tick_rate)
	else:
		state["velocity_y"] += floor_div(
			ACCELERATION * TICK_RATE * move_y, tick_rate * INPUT_SCALE)
	var vx: int = state["velocity_x"]
	var vy: int = state["velocity_y"]
	var magnitude: int = isqrt(vx * vx + vy * vy)
	if magnitude > MAX_SPEED and magnitude != 0:
		state["velocity_x"] = floor_div(vx * MAX_SPEED, magnitude)
		state["velocity_y"] = floor_div(vy * MAX_SPEED, magnitude)
	var remainder: Array = _position_remainders[player_id]
	remainder[0] += state["velocity_x"] * TICK_RATE
	remainder[1] += state["velocity_y"] * TICK_RATE
	var x_step := divide_with_remainder(remainder[0], tick_rate)
	var y_step := divide_with_remainder(remainder[1], tick_rate)
	state["x"] += x_step[0]
	state["y"] += y_step[0]
	remainder[0] = x_step[1]
	remainder[1] = y_step[1]
	state["yaw_millidegrees"] = posmod(cmd["yaw_millidegrees"], 360000)
	state["last_sequence"] = cmd["sequence"]
	if cmd["fire"]:
		_attempt_fire(player_id, state)


func _attempt_fire(player_id: String, state: Dictionary) -> void:
	if tick < state["next_fire_tick"]:
		_record(player_id, "fire_cadence_rejected", {"next_legal_tick": state["next_fire_tick"]})
		return
	if state["ammunition"] <= 0:
		_record(player_id, "empty_fire_rejected", {})
		return
	state["ammunition"] -= 1
	state["next_fire_tick"] = tick + fire_interval_ticks()
	_record(player_id, "shot_accepted", {
		"origin_x": state["x"], "origin_y": state["y"],
		"yaw_millidegrees": state["yaw_millidegrees"],
		"ammunition_after": state["ammunition"],
	})


func _record(player_id: String, category: String, detail: Dictionary) -> void:
	evidence.append({"tick": tick, "player_id": player_id, "category": category, "detail": detail})


func fire_interval_ticks() -> int:
	return FIRE_INTERVAL_TICKS * tick_rate / TICK_RATE


static func divide_with_remainder(value: int, divisor: int) -> Array:
	var quotient: int = value / divisor
	return [quotient, value - quotient * divisor]


## Same canonical form as the Python oracle: sorted keys, no whitespace.
func digest() -> String:
	var payload := {
		"tick_rate": tick_rate,
		"ticks": tick,
		"players": players,
		"position_remainders": _position_remainders,
		"evidence": evidence,
	}
	return JSON.stringify(payload, "", true).sha256_text()


func evidence_counts(player_id: String) -> Dictionary:
	var counts := {}
	for event in evidence:
		if event["player_id"] == player_id:
			counts[event["category"]] = counts.get(event["category"], 0) + 1
	return counts
