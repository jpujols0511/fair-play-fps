extends RefCounted
## Bots step 2: five-state brain, pure logic (bot_spec_v0.1 §1 step 2). Follows: CD-r3.
## Input: a bot_view.gd view (own state, teammates, culled enemies only) + a server tick.
## Output: state + intent {move_target, aim_target, aim_err_yaw_deg, aim_err_pitch_deg, fire, reload, radio}.
## The Phase 8 controller turns intents into InputCmds later. No physics, no scene, no server access.
## Deterministic: one seeded RandomNumberGenerator per bot. Floats in all math.

const BotView = preload("bot_view.gd")   # relative to this script

enum State { IDLE, PATROL, ENGAGE, RETREAT, FLANK }
const STATE_NAMES := ["IDLE", "PATROL", "ENGAGE", "RETREAT", "FLANK"]

const TICK_RATE := 128.0

# PROPOSED thresholds (CURRENT_DECISIONS OPEN item 12 / bot_spec_v0.1). Named so Joan can tune them.
const RETREAT_HEALTH_FRAC := 0.30      # retreat below 30% health (Joan, hard mode §6)
const SUPPORT_RADIUS := 512.0          # teammates within this count against "outnumbered"
const FLANK_AFTER_S := 3.0             # enemy held in view this long without a kill -> FLANK
const RETREAT_CLEAR_S := 2.0           # no enemy in view this long + reloaded -> PATROL
const LOSE_CONTACT_S := 2.0            # ENGAGE with no enemy in view this long -> PATROL (PROPOSED, not in spec text)
const REACTION_DELAY_S := 0.45         # step 7 dial, casual start
const AIM_ERROR_DEG := 4.0             # step 7 dial, casual start
const RADIO_COOLDOWN_S := 2.0
const ARRIVE_RADIUS := 16.0
const RETREAT_STEP := 256.0            # retreat away from the last seen enemy by this much if no teammate
const AIM_CHEST_STAND := 54.5          # standing chest center (hitbox v0.2)
const AIM_CHEST_CROUCH := 27.25        # crouched chest center at scale 0.5 (Devin Addendum 2 A2-a table)
const FLANK_ENGAGE_RANGE := 1024.0     # FLANK: a seen enemy within this range ends the wait (PROPOSED)

# Radio call ids (step 3: text/sound events, no voice files).
const RADIO_ENEMY_SPOTTED := "ENEMY_SPOTTED"
const RADIO_NEED_BACKUP := "NEED_BACKUP"
const RADIO_FALLING_BACK := "FALLING_BACK"
const RADIO_FLANKING := "FLANKING"

var state: int = State.IDLE
var rng := RandomNumberGenerator.new()

var patrol_route: Array = []           # Array of PackedFloat64Array [x, y, z] (map data, not enemy data)
var flank_route: Array = []            # Array of PackedFloat64Array; empty = no flank available
var _patrol_i: int = 0
var _flank_i: int = 0

# Memory: only things the bot itself saw.
var _first_seen_tick: int = -1         # first tick of the current continuous sighting
var _last_seen_tick: int = -1
var _last_seen_pos := PackedFloat64Array()
var _state_since_tick: int = 0
var _last_radio_tick: int = -1000000
var _flank_lost_contact: bool = false
var _flank_waiting: bool = false        # at the flank start (route point 0) waiting for the step 6 hook

## Step 6 hook (stub, present): returns true when a teammate has drawn fire, so the flank may go.
## Default stub: always true. Step 6 replaces this with teammate-state / radio based logic.
var flank_coordination_hook: Callable = func(_view) -> bool: return true


func _init(seed_value: int = 0, patrol: Array = [], flank: Array = []) -> void:
	rng.seed = seed_value
	patrol_route = patrol
	flank_route = flank


static func _secs(ticks: int) -> float:
	return float(ticks) / TICK_RATE


static func _dist2d(ax: float, az: float, bx: float, bz: float) -> float:
	return sqrt((ax - bx) * (ax - bx) + (az - bz) * (az - bz))


func _nearest_enemy(view: BotView) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for e in view.enemies:
		var d := _dist2d(view.x, view.z, float(e["x"]), float(e["z"]))
		if d < best_d or (d == best_d and int(e["slot"]) < int(best["slot"])):
			best_d = d
			best = e
	return best


## Outnumbered = more visible enemies than support. Support counts the BOT ITSELF plus live teammates
## within SUPPORT_RADIUS, so a 1v1 is not outnumbered (1 enemy vs support 1.0).
func _outnumbered(view: BotView) -> bool:
	var support := 1.0   # the bot itself
	for t in view.teammates:
		if bool(t["alive"]) and _dist2d(view.x, view.z, float(t["x"]), float(t["z"])) <= SUPPORT_RADIUS:
			support += 1.0
	return float(view.enemies.size()) > support


func _set_state(s: int, tick: int) -> void:
	if s != state:
		state = s
		_state_since_tick = tick
		if s == State.FLANK:
			_flank_i = 0
			_flank_lost_contact = false
			_flank_waiting = false


func _radio(id: String, tick: int) -> String:
	if _secs(tick - _last_radio_tick) >= RADIO_COOLDOWN_S:
		_last_radio_tick = tick
		return id
	return ""


static func _empty_intent() -> Dictionary:
	return {"move_target": PackedFloat64Array(), "aim_target": PackedFloat64Array(),
		"aim_err_yaw_deg": 0.0, "aim_err_pitch_deg": 0.0, "fire": false, "reload": false, "radio": ""}


## One decision per server tick. Returns {state: int, state_name: String, intent: Dictionary}.
func think(view: BotView, tick: int) -> Dictionary:
	# --- perception (only from the view)
	var enemy := _nearest_enemy(view)
	var sees := not enemy.is_empty()
	if sees:
		if _first_seen_tick < 0:
			_first_seen_tick = tick
		_last_seen_tick = tick
		_last_seen_pos = PackedFloat64Array([float(enemy["x"]), float(enemy["y"]), float(enemy["z"])])
	else:
		_first_seen_tick = -1
	var reacted := sees and _secs(tick - _first_seen_tick) >= REACTION_DELAY_S - 1e-9
	var unseen_s := INF if _last_seen_tick < 0 else _secs(tick - _last_seen_tick)
	var low_health := view.health < RETREAT_HEALTH_FRAC * view.max_health
	var no_ammo := view.mag <= 0.0
	var reloaded := view.mag > 0.0 and (view.mag >= view.mag_size or view.reserve <= 0.0)   # full reload per spec
	var in_range := sees and _dist2d(view.x, view.z, float(enemy["x"]), float(enemy["z"])) <= FLANK_ENGAGE_RANGE
	var prev := state
	var radio := ""

	# --- transitions
	if not view.alive or not view.round_live:
		_set_state(State.IDLE, tick)
	else:
		match state:
			State.IDLE:
				_set_state(State.PATROL, tick)
				if reacted:
					# low health / empty magazine checked first: straight to RETREAT
					_set_state(State.RETREAT if (low_health or no_ammo) else State.ENGAGE, tick)
			State.PATROL:
				if reacted:
					if low_health or no_ammo:
						_set_state(State.RETREAT, tick)
					else:
						_set_state(State.ENGAGE, tick)
			State.ENGAGE:
				if low_health or (sees and _outnumbered(view)) or no_ammo:
					_set_state(State.RETREAT, tick)
				elif sees and not flank_route.is_empty() and _secs(tick - maxi(_first_seen_tick, _state_since_tick)) >= FLANK_AFTER_S - 1e-9:
					# timed from the later of first sighting and entering ENGAGE, so FLANK -> ENGAGE can't bounce straight back
					_set_state(State.FLANK, tick)
				elif not sees and unseen_s >= LOSE_CONTACT_S - 1e-9:
					_set_state(State.PATROL, tick)
			State.RETREAT:
				if unseen_s >= RETREAT_CLEAR_S - 1e-9 and reloaded:
					_set_state(State.PATROL, tick)
			State.FLANK:
				if not sees:
					_flank_lost_contact = true
				_flank_waiting = false
				if _flank_i == 0 and not flank_route.is_empty():
					var p0: PackedFloat64Array = flank_route[0]
					if _dist2d(view.x, view.z, p0[0], p0[2]) <= ARRIVE_RADIUS:
						_flank_waiting = not bool(flank_coordination_hook.call(view))
				if low_health or no_ammo:
					_set_state(State.RETREAT, tick)
				elif reacted and in_range and (_flank_waiting or _flank_lost_contact):
					# Seen while holding at the flank start, or re-seen after breaking contact: fight, don't stand in plain sight.
					_set_state(State.ENGAGE, tick)
				elif _flank_i >= flank_route.size():
					_set_state(State.PATROL, tick)

	# --- entry radio (text/sound event ids)
	if state != prev:
		match state:
			State.ENGAGE: radio = _radio(RADIO_ENEMY_SPOTTED, tick)
			State.RETREAT: radio = _radio(RADIO_NEED_BACKUP if (sees and _outnumbered(view)) else RADIO_FALLING_BACK, tick)
			State.FLANK: radio = _radio(RADIO_FLANKING, tick)

	# --- intent
	var it := _empty_intent()
	it["radio"] = radio
	match state:
		State.PATROL:
			if not patrol_route.is_empty():
				var wp: PackedFloat64Array = patrol_route[_patrol_i % patrol_route.size()]
				if _dist2d(view.x, view.z, wp[0], wp[2]) <= ARRIVE_RADIUS:
					_patrol_i = (_patrol_i + 1) % patrol_route.size()
					wp = patrol_route[_patrol_i]
				it["move_target"] = wp
		State.ENGAGE:
			if sees:
				it["aim_target"] = PackedFloat64Array([float(enemy["x"]), float(enemy["y"]) + _chest_height(enemy), float(enemy["z"])])
				it["aim_err_yaw_deg"] = rng.randf_range(-AIM_ERROR_DEG, AIM_ERROR_DEG)
				it["aim_err_pitch_deg"] = rng.randf_range(-AIM_ERROR_DEG, AIM_ERROR_DEG) * 0.5
				it["fire"] = view.mag > 0.0
			elif _last_seen_pos.size() == 3:
				it["move_target"] = _last_seen_pos   # where the bot itself last saw the enemy
		State.RETREAT:
			it["reload"] = view.mag < view.mag_size and view.reserve > 0.0
			var mate: Dictionary = {}
			var md := INF
			for t in view.teammates:
				if bool(t["alive"]):
					var d := _dist2d(view.x, view.z, float(t["x"]), float(t["z"]))
					if d < md:
						md = d
						mate = t
			if not mate.is_empty():
				it["move_target"] = PackedFloat64Array([float(mate["x"]), float(mate["y"]), float(mate["z"])])
			elif _last_seen_pos.size() == 3:
				var dx := view.x - _last_seen_pos[0]
				var dz := view.z - _last_seen_pos[2]
				var n := sqrt(dx * dx + dz * dz)
				if n > 0.0:
					it["move_target"] = PackedFloat64Array([view.x + dx / n * RETREAT_STEP, view.y, view.z + dz / n * RETREAT_STEP])
		State.FLANK:
			if _flank_i < flank_route.size():
				var fp: PackedFloat64Array = flank_route[_flank_i]
				if not _flank_waiting and _dist2d(view.x, view.z, fp[0], fp[2]) <= ARRIVE_RADIUS:
					_flank_i += 1
					if _flank_i < flank_route.size():
						fp = flank_route[_flank_i]
				# Waiting = hold AT route point 0 (behind cover by route design), never in the open.
				it["move_target"] = fp
			if sees and reacted:
				# Enemy still in view while moving to cover: keep shooting on the way.
				it["aim_target"] = PackedFloat64Array([float(enemy["x"]), float(enemy["y"]) + _chest_height(enemy), float(enemy["z"])])
				it["aim_err_yaw_deg"] = rng.randf_range(-AIM_ERROR_DEG, AIM_ERROR_DEG)
				it["aim_err_pitch_deg"] = rng.randf_range(-AIM_ERROR_DEG, AIM_ERROR_DEG) * 0.5
				it["fire"] = view.mag > 0.0
	return {"state": state, "state_name": STATE_NAMES[state], "intent": it}


## Chest aim height blended by the enemy's duck fraction (as sent in the snapshot): 54.5 standing -> 27.25 crouched.
static func _chest_height(enemy: Dictionary) -> float:
	var f := clampf(float(enemy.get("duck", 0.0)), 0.0, 1.0)
	return AIM_CHEST_STAND + (AIM_CHEST_CROUCH - AIM_CHEST_STAND) * f
