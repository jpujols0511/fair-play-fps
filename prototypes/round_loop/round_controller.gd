extends RefCounted
## Round controller (round loop spec v0.1 Sections 1, 4, 5). Server-side only.
## Phase enum + tick-driven state machine at 128 Hz. Every timer is float seconds advanced by
## 1.0 / 128.0 per tick (exact in binary). A duration ends on the first tick at or after it.
## Clients never call step(); they read get_snapshot_fields() from snapshots and send buy requests.

const Economy = preload("res://economy.gd")
const Weapons = preload("res://weapons_table.gd")

enum Phase { WARMUP, FREEZE, LIVE, PLANTED, ROUND_END }
enum Reason { NONE, T_ELIMINATED, CT_ELIMINATED, BOMB_EXPLODED, BOMB_DEFUSED, TIME_EXPIRED }

const TICK_RATE := 128.0
const DT := 1.0 / 128.0

## Spec values are Joan's; PROPOSED ones are marked and are DECISION FOR JOAN switches.
const DEFAULTS := {
	"freeze_s": 15.0,                  # spec
	"round_s": 100.0,                  # spec (1:40)
	"plant_s": 3.2,                    # spec
	"defuse_kit_s": 10.0,              # spec
	"defuse_nokit_s": 15.0,            # spec
	"bomb_timer_s": 40.0,              # PROPOSED (CS 35/40/45), note (b)
	"round_end_s": 5.0,                # PROPOSED, note (g)8
	"buy_window_into_live_s": 0.0,     # PROPOSED, note (g)1
	"max_rounds_per_half": 12,         # PROPOSED MR12, note (f)1 (round count, not math)
	"t_elim_after_plant_ends_round": false,  # PROPOSED CS rule, note (g)3
	"plant_team_bonus_mode": "each",   # PROPOSED, note (c)
	"defuse_team_split_mode": "team",  # PROPOSED, note (c)
	"loss_reset_mode": "reset",        # PROPOSED, note (f)3
	"max_cash": 16000.0,               # PROPOSED, note (f)2
}

var cfg: Dictionary = DEFAULTS.duplicate()
var phase: int = Phase.WARMUP
var tick: int = 0                 # server tick counter (index, not math)
var phase_elapsed: float = 0.0    # seconds in the current phase
var round_number: int = 0
var players: Dictionary = {}      # slot -> {team, alive, cash, has_kit, armor, helmet, items}
var score: Dictionary = {"T": 0, "CT": 0}
var loss_streak: Dictionary = {"T": 0, "CT": 0}
var winner: String = ""
var reason: int = Reason.NONE
var match_over: bool = false

var planter: int = -1
var plant_progress: float = 0.0
var defuser: int = -1
var defuse_progress: float = 0.0
var defuse_needed: float = 0.0

var events: Array = []            # server-only transition / economy events (for snapshots + logs)


func _init(overrides: Dictionary = {}) -> void:
	for k in overrides:
		cfg[k] = overrides[k]


# ---------------------------------------------------------------- setup

func add_player(slot: int, team: String) -> void:
	players[slot] = {"team": team, "alive": true, "cash": 0.0, "has_kit": false, "armor": false, "helmet": false, "items": []}


func team_slots(team: String) -> Array:
	var out := []
	for s in players:
		if players[s]["team"] == team:
			out.append(s)
	out.sort()
	return out


func alive_slots(team: String) -> Array:
	var out := []
	for s in team_slots(team):
		if players[s]["alive"]:
			out.append(s)
	return out


## Server command: WARMUP -> FREEZE, everyone gets start cash.
func start_match() -> void:
	if phase != Phase.WARMUP:
		return
	for s in players:
		players[s]["cash"] = Economy.START_CASH
	_start_round()


# ---------------------------------------------------------------- tick

## One server tick. input keys (all optional, built by the server from validated commands):
##   "kills": Array of [killer_slot, victim_slot]  (from server hit registration)
##   "plant_hold": slot of a T holding plant inside a bomb site (server zone check), or -1
##   "defuse_hold": slot of a CT holding defuse on the bomb (server range check), or -1
func step(input: Dictionary = {}) -> void:
	tick += 1
	phase_elapsed += DT
	match phase:
		Phase.WARMUP:
			pass
		Phase.FREEZE:
			_step_freeze()
		Phase.LIVE:
			_step_live(input)
		Phase.PLANTED:
			_step_planted(input)
		Phase.ROUND_END:
			_step_round_end()


func _step_freeze() -> void:
	if phase_elapsed >= float(cfg["freeze_s"]):
		_set_phase(Phase.LIVE)


func _step_live(input: Dictionary) -> void:
	_apply_kills(input.get("kills", []))
	# Plant (server-timed). Interrupt or planter change restarts from 0.
	var p: int = input.get("plant_hold", -1)
	if p >= 0 and players.has(p) and players[p]["alive"] and players[p]["team"] == "T":
		if p != planter:
			planter = p
			plant_progress = 0.0
		plant_progress += DT
		if plant_progress >= float(cfg["plant_s"]):
			_on_planted()
			return
	else:
		planter = -1
		plant_progress = 0.0
	# Win checks. T eliminated first, so a same-tick double wipe in LIVE goes to CT.
	if alive_slots("T").is_empty():
		_end_round("CT", Reason.T_ELIMINATED)
	elif alive_slots("CT").is_empty():
		_end_round("T", Reason.CT_ELIMINATED)
	elif phase_elapsed >= float(cfg["round_s"]):
		_end_round("CT", Reason.TIME_EXPIRED)


func _step_planted(input: Dictionary) -> void:
	_apply_kills(input.get("kills", []))
	# Defuse (server-timed). Kit/no-kit time fixed when the defuse starts.
	var d: int = input.get("defuse_hold", -1)
	if d >= 0 and players.has(d) and players[d]["alive"] and players[d]["team"] == "CT":
		if d != defuser:
			defuser = d
			defuse_progress = 0.0
			defuse_needed = float(cfg["defuse_kit_s"]) if players[d]["has_kit"] else float(cfg["defuse_nokit_s"])
		defuse_progress += DT
		if defuse_progress >= defuse_needed:
			_on_defused()
			return  # defuse beats an explosion on the same tick
	else:
		defuser = -1
		defuse_progress = 0.0
	if phase_elapsed >= float(cfg["bomb_timer_s"]):
		_end_round("T", Reason.BOMB_EXPLODED)
	elif alive_slots("CT").is_empty():
		_end_round("T", Reason.CT_ELIMINATED)
	elif cfg["t_elim_after_plant_ends_round"] and alive_slots("T").is_empty():
		_end_round("CT", Reason.T_ELIMINATED)


func _step_round_end() -> void:
	if match_over:
		return
	if phase_elapsed >= float(cfg["round_end_s"]):
		_start_round()


# ---------------------------------------------------------------- transitions (server-only)

func _set_phase(p: int) -> void:
	events.append({"tick": tick, "type": "phase", "from": phase, "to": p})
	phase = p
	phase_elapsed = 0.0


func _start_round() -> void:
	round_number += 1
	winner = ""
	reason = Reason.NONE
	planter = -1
	plant_progress = 0.0
	defuser = -1
	defuse_progress = 0.0
	for s in players:
		players[s]["alive"] = true
	_set_phase(Phase.FREEZE)


func _on_planted() -> void:
	var r: Dictionary = Economy.plant_rewards(planter, team_slots("T"), cfg["plant_team_bonus_mode"])
	_pay(r, "plant")
	events.append({"tick": tick, "type": "planted", "slot": planter})
	_set_phase(Phase.PLANTED)


func _on_defused() -> void:
	var r: Dictionary = Economy.defuse_rewards(defuser, team_slots("CT"), alive_slots("CT"), cfg["defuse_team_split_mode"])
	_pay(r, "defuse")
	events.append({"tick": tick, "type": "defused", "slot": defuser})
	_end_round("CT", Reason.BOMB_DEFUSED)


func _end_round(win_team: String, why: int) -> void:
	winner = win_team
	reason = why
	var lose_team := "CT" if win_team == "T" else "T"
	score[win_team] += 1
	loss_streak[win_team] = Economy.next_loss_streak(loss_streak[win_team], true, cfg["loss_reset_mode"])
	loss_streak[lose_team] = Economy.next_loss_streak(loss_streak[lose_team], false, cfg["loss_reset_mode"])
	var cap: float = cfg["max_cash"]
	for s in team_slots(win_team):
		players[s]["cash"] = Economy.credit(players[s]["cash"], Economy.win_bonus(), cap)
	var lb: float = Economy.loss_bonus(loss_streak[lose_team])
	for s in team_slots(lose_team):
		players[s]["cash"] = Economy.credit(players[s]["cash"], lb, cap)
	events.append({"tick": tick, "type": "round_end", "winner": win_team, "reason": why})
	if score[win_team] >= int(cfg["max_rounds_per_half"]) + 1:
		match_over = true
	_set_phase(Phase.ROUND_END)


func _apply_kills(kills: Array) -> void:
	for k in kills:
		var killer: int = k[0]
		var victim: int = k[1]
		if not players.has(victim) or not players[victim]["alive"]:
			continue
		players[victim]["alive"] = false
		if victim == planter:
			planter = -1
			plant_progress = 0.0
		if victim == defuser:
			defuser = -1
			defuse_progress = 0.0
		if players.has(killer) and killer != victim:
			var amt: float = Economy.kill_reward(players[killer]["team"], players[victim]["team"])
			players[killer]["cash"] = Economy.credit(players[killer]["cash"], amt, cfg["max_cash"])


func _pay(rewards: Dictionary, why: String) -> void:
	for s in rewards:
		if players.has(s):
			players[s]["cash"] = Economy.credit(players[s]["cash"], rewards[s], cfg["max_cash"])
	events.append({"tick": tick, "type": "pay", "why": why, "rewards": rewards})


# ---------------------------------------------------------------- buy (server applies, UI only requests)

func buy_open() -> bool:
	if phase == Phase.FREEZE:
		return true
	return phase == Phase.LIVE and phase_elapsed < float(cfg["buy_window_into_live_s"])


## A buy request carries only (slot, item_id). Price and team restriction come from the server table.
func request_buy(slot: int, item_id: String) -> Dictionary:
	if not players.has(slot):
		return {"result": Economy.BuyResult.UNKNOWN_ITEM, "new_cash": 0.0}
	var pl: Dictionary = players[slot]
	var res: Dictionary = Economy.validate_buy(pl["cash"], Weapons.get_item(item_id), pl["team"], buy_open(), pl["alive"])
	if res["result"] == Economy.BuyResult.OK:
		pl["cash"] = res["new_cash"]
		pl["items"].append(item_id)
		if item_id == "defuse_kit":
			pl["has_kit"] = true
		elif item_id == "armor_vest":
			pl["armor"] = true
		elif item_id == "armor_helmet":
			pl["armor"] = true
			pl["helmet"] = true
	events.append({"tick": tick, "type": "buy", "slot": slot, "item": item_id, "result": res["result"]})
	return res


# ---------------------------------------------------------------- snapshot fields

## What the server broadcasts each snapshot (spec Section 5: timers as snapshot fields).
func get_snapshot_fields() -> Dictionary:
	var time_left := 0.0
	match phase:
		Phase.FREEZE:
			time_left = float(cfg["freeze_s"]) - phase_elapsed
		Phase.LIVE:
			time_left = float(cfg["round_s"]) - phase_elapsed
		Phase.PLANTED:
			time_left = float(cfg["bomb_timer_s"]) - phase_elapsed
		Phase.ROUND_END:
			time_left = float(cfg["round_end_s"]) - phase_elapsed
	return {
		"server_tick": tick,
		"phase": phase,
		"round": round_number,
		"time_left_s": maxf(time_left, 0.0),
		"plant_progress_s": plant_progress,
		"defuse_progress_s": defuse_progress,
		"score_t": score["T"],
		"score_ct": score["CT"],
		"winner": winner,
		"reason": reason,
		"match_over": match_over,
	}
