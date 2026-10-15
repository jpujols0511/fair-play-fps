extends RefCounted
## Fairness kernel: GDScript port of prototype/fairplay_sim.py.
##
## Integer-only on purpose. The result digest must match the Python contract
## oracle byte for byte, so the same command stream proves the same outcome in
## both implementations. Invariant 1: clients submit intent; this code decides
## movement, cadence, ammunition and evidence.

const TICK_RATE := 64
const INPUT_SCALE := 1000
const MAX_SPEED := 48
const ACCELERATION := 8
const FRICTION := 6
const FIRE_INTERVAL_TICKS := 8
const MAGAZINE_SIZE := 12
# Hits and lag compensation (decision 0003). Distances are millimetres.
const HIT_RADIUS := 400
const MAX_RANGE := 50000
const DAMAGE := 25
const MAX_REWIND_TICKS := 13
const VIEW_RANGE := 60000  # players farther away are never sent to a client
const TRIG_SCALE := 1000000
# round(sin(k degrees) * TRIG_SCALE) for k = 0..90, identical to the Python
# oracle. Fixed integers so every implementation computes the same rays.
const SIN_TABLE := [
	0, 17452, 34899, 52336, 69756, 87156, 104528, 121869, 139173, 156434,
	173648, 190809, 207912, 224951, 241922, 258819, 275637, 292372, 309017, 325568,
	342020, 358368, 374607, 390731, 406737, 422618, 438371, 453990, 469472, 484810,
	500000, 515038, 529919, 544639, 559193, 573576, 587785, 601815, 615661, 629320,
	642788, 656059, 669131, 681998, 694658, 707107, 719340, 731354, 743145, 754710,
	766044, 777146, 788011, 798636, 809017, 819152, 829038, 838671, 848048, 857167,
	866025, 874620, 882948, 891007, 898794, 906308, 913545, 920505, 927184, 933580,
	939693, 945519, 951057, 956305, 961262, 965926, 970296, 974370, 978148, 981627,
	984808, 987688, 990268, 992546, 994522, 996195, 997564, 998630, 999391, 999848,
	1000000,
]

var tick: int = 0
var players: Dictionary = {}
var evidence: Array = []
var _queued: Dictionary = {}
var _history: Dictionary = {}  # tick -> {player_id: [x, y]} at the start of that tick


func _init(player_ids: Array) -> void:
	var ids: Array = player_ids.duplicate()
	ids.sort()
	for player_id in ids:
		players[player_id] = new_state()


static func new_state() -> Dictionary:
	return {
		"x": 0, "y": 0, "velocity_x": 0, "velocity_y": 0,
		"yaw_millidegrees": 0, "health": 100, "ammunition": MAGAZINE_SIZE,
		"next_fire_tick": 0, "last_sequence": -1,
	}


## view_tick: the server tick the client was seeing when it acted; -1 is now.
static func command(sequence: int, move_x: int = 0, move_y: int = 0,
		yaw_millidegrees: int = 0, fire: bool = false, view_tick: int = -1) -> Dictionary:
	return {
		"sequence": sequence, "move_x": move_x, "move_y": move_y,
		"yaw_millidegrees": yaw_millidegrees, "fire": fire, "view_tick": view_tick,
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


static func _sin_quarter(millidegrees: int) -> int:
	var index: int = millidegrees / 1000
	var fraction: int = millidegrees % 1000
	if index >= 90:
		return SIN_TABLE[90]
	return SIN_TABLE[index] + (SIN_TABLE[index + 1] - SIN_TABLE[index]) * fraction / 1000


## sin(yaw) * TRIG_SCALE in integers: table plus linear interpolation.
static func sin_scaled(millidegrees: int) -> int:
	var m: int = posmod(millidegrees, 360000)
	var quadrant: int = m / 90000
	var rest: int = m % 90000
	if quadrant == 0:
		return _sin_quarter(rest)
	if quadrant == 1:
		return _sin_quarter(90000 - rest)
	if quadrant == 2:
		return -_sin_quarter(rest)
	return -_sin_quarter(90000 - rest)


static func cos_scaled(millidegrees: int) -> int:
	return sin_scaled(millidegrees + 90000)


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
	var seen := {}
	for player_id in players:
		seen[player_id] = [players[player_id]["x"], players[player_id]["y"]]
	_history[tick] = seen
	_history.erase(tick - MAX_REWIND_TICKS - 1)
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
		state["velocity_x"] = approach_zero(state["velocity_x"], FRICTION)
	else:
		state["velocity_x"] += floor_div(ACCELERATION * move_x, INPUT_SCALE)
	if move_y == 0:
		state["velocity_y"] = approach_zero(state["velocity_y"], FRICTION)
	else:
		state["velocity_y"] += floor_div(ACCELERATION * move_y, INPUT_SCALE)
	var vx: int = state["velocity_x"]
	var vy: int = state["velocity_y"]
	var magnitude: int = isqrt(vx * vx + vy * vy)
	if magnitude > MAX_SPEED and magnitude != 0:
		state["velocity_x"] = floor_div(vx * MAX_SPEED, magnitude)
		state["velocity_y"] = floor_div(vy * MAX_SPEED, magnitude)
	state["x"] += state["velocity_x"]
	state["y"] += state["velocity_y"]
	state["yaw_millidegrees"] = posmod(cmd["yaw_millidegrees"], 360000)
	state["last_sequence"] = cmd["sequence"]
	if cmd["fire"]:
		if state["health"] <= 0:
			_record(player_id, "eliminated_fire_rejected", {})
		else:
			_attempt_fire(player_id, state, cmd.get("view_tick", -1))


func _attempt_fire(player_id: String, state: Dictionary, view_tick: int = -1) -> void:
	if tick < state["next_fire_tick"]:
		_record(player_id, "fire_cadence_rejected", {"next_legal_tick": state["next_fire_tick"]})
		return
	if state["ammunition"] <= 0:
		_record(player_id, "empty_fire_rejected", {})
		return
	state["ammunition"] -= 1
	state["next_fire_tick"] = tick + FIRE_INTERVAL_TICKS
	_record(player_id, "shot_accepted", {
		"origin_x": state["x"], "origin_y": state["y"],
		"yaw_millidegrees": state["yaw_millidegrees"],
		"ammunition_after": state["ammunition"],
	})
	_resolve_hit(player_id, state, view_tick)


## Other players this viewer may know about. The server sends a client nothing
## else (THREAT_MODEL: no knowledge outside legitimate visibility). No map
## yet, so distance only; walls belong here.
func visible_to(viewer_id: String) -> Array:
	var viewer: Dictionary = players[viewer_id]
	var visible: Array = []
	var ids: Array = players.keys()
	ids.sort()
	for other_id in ids:
		if other_id == viewer_id:
			continue
		var dx: int = players[other_id]["x"] - viewer["x"]
		var dy: int = players[other_id]["y"] - viewer["y"]
		if dx * dx + dy * dy <= VIEW_RANGE * VIEW_RANGE:
			visible.append(other_id)
	return visible


## Lag compensation: rewind other players to the start of the tick the
## shooter saw, at most MAX_REWIND_TICKS, then trace a ray along its yaw.
## The closest living target within HIT_RADIUS and MAX_RANGE is hit.
func _resolve_hit(player_id: String, state: Dictionary, view_tick: int) -> void:
	var rewind := 0
	if view_tick > tick:
		_record(player_id, "view_tick_invalid", {"view_tick": view_tick})
	elif view_tick >= 0:
		rewind = tick - view_tick
		if rewind > MAX_REWIND_TICKS:
			_record(player_id, "rewind_limited", {"requested": rewind})
			rewind = MAX_REWIND_TICKS
	# Never past the history this kernel holds (a client's prediction kernel
	# starts mid-match with none).
	while not _history.has(tick - rewind):
		rewind -= 1
	var seen: Dictionary = _history[tick - rewind]
	var dx := cos_scaled(state["yaw_millidegrees"])
	var dy := sin_scaled(state["yaw_millidegrees"])
	var best := ""
	var best_along := 0
	var ids: Array = players.keys()
	ids.sort()
	for target_id in ids:
		if target_id == player_id or players[target_id]["health"] <= 0:
			continue
		var vx: int = seen[target_id][0] - state["x"]
		var vy: int = seen[target_id][1] - state["y"]
		var along: int = vx * dx + vy * dy
		if along < 0 or along > MAX_RANGE * TRIG_SCALE:
			continue
		if absi(vx * dy - vy * dx) > HIT_RADIUS * TRIG_SCALE:
			continue
		if best == "" or along < best_along:
			best = target_id
			best_along = along
	if best == "":
		return
	var target: Dictionary = players[best]
	target["health"] = maxi(0, target["health"] - DAMAGE)
	_record(player_id, "hit_confirmed", {
		"target": best, "damage": DAMAGE, "rewind_ticks": rewind,
		"distance": best_along / TRIG_SCALE,
	})
	if target["health"] == 0:
		_record(best, "player_eliminated", {"by": player_id})


func _record(player_id: String, category: String, detail: Dictionary) -> void:
	evidence.append({"tick": tick, "player_id": player_id, "category": category, "detail": detail})


## Same canonical form as the Python oracle: sorted keys, no whitespace.
func digest() -> String:
	var payload := {"ticks": tick, "players": players, "evidence": evidence}
	return JSON.stringify(payload, "", true).sha256_text()


func evidence_counts(player_id: String) -> Dictionary:
	var counts := {}
	for event in evidence:
		if event["player_id"] == player_id:
			counts[event["category"]] = counts.get(event["category"], 0) + 1
	return counts
