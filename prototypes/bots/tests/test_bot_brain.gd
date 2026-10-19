extends SceneTree
## Headless tests for bots step 2 (five-state brain). Follows: CD-r3.
## Run: godot --headless --path prototypes/bots --script res://tests/test_bot_brain.gd

const Brain = preload("res://bot_brain.gd")
const BotView = preload("res://bot_view.gd")
const H = preload("res://tests/harness.gd")
const S = Brain.State

var h = H.new()


func _view(health: float = 100.0, mag: float = 30.0, reserve: float = 90.0) -> BotView:
	var v := BotView.new()
	v.slot = 1; v.team = "T"; v.alive = true; v.round_live = true
	v.health = health; v.mag = mag; v.reserve = reserve
	v.x = 0.0; v.y = 0.0; v.z = 0.0
	return v


func _enemy(slot: int, x: float, z: float = 0.0) -> Dictionary:
	return {"slot": slot, "x": x, "y": 0.0, "z": z}


## Run `n` ticks from `t0` with the same view; returns the last result.
func _run(b, v: BotView, t0: int, n: int) -> Dictionary:
	var r: Dictionary = {}
	for i in range(n):
		r = b.think(v, t0 + i)
	return r


## Brain already in ENGAGE (saw one enemy, waited the reaction delay). Returns next free tick.
func _engaged(b, v: BotView) -> int:
	v.enemies = [_enemy(7, 800.0)]
	b.think(v, 0)                       # IDLE -> PATROL, first sighting at tick 0
	var r := _run(b, v, 1, 58)          # ticks 1..58: reaction 0.45 s -> tick 58 (57.6 rounds up)
	h.eq("setup: engaged", r["state"], S.ENGAGE)
	return 59


func _ready_ticks() -> int:
	return int(ceil(Brain.REACTION_DELAY_S * Brain.TICK_RATE - 1e-9))


func _init() -> void:
	_test_idle()
	_test_patrol_to_engage()
	_test_engage_intent()
	_test_low_health()
	_test_outnumbered()
	_test_out_of_ammo()
	_test_retreat_to_patrol()
	_test_engage_to_flank()
	_test_flank_hook_and_exits()
	_test_lose_contact()
	_test_crouched_aim()
	_test_full_reload_exit()
	_test_idle_straight_to_retreat()
	_test_one_v_one_not_outnumbered()
	_test_patrol_to_retreat()
	_test_radio_cooldown()
	_test_patrol_route()
	_test_unsent_enemy()
	_test_determinism()
	_test_source_rules()
	print("RESULT bot_brain: %d passed, %d failed" % [h.passed, h.failed])
	quit(0 if h.failed == 0 else 1)


func _test_idle() -> void:
	var b = Brain.new(1)
	var v := _view()
	v.round_live = false
	h.eq("IDLE while round not live", b.think(v, 0)["state"], S.IDLE)
	v.round_live = true
	h.eq("IDLE -> PATROL when round live", b.think(v, 1)["state"], S.PATROL)
	v.alive = false
	h.eq("PATROL -> IDLE on death", b.think(v, 2)["state"], S.IDLE)
	var b2 = Brain.new(1)
	var v2 := _view()
	_engaged(b2, v2)
	v2.round_live = false
	h.eq("ENGAGE -> IDLE on round end", b2.think(v2, 100)["state"], S.IDLE)
	var it: Dictionary = b2.think(v2, 101)["intent"]
	h.check("IDLE intent: no fire, no move", not it["fire"] and it["move_target"].size() == 0)


func _test_patrol_to_engage() -> void:
	var b = Brain.new(2)
	var v := _view()
	b.think(v, 0)
	v.enemies = [_enemy(7, 800.0)]
	var first := 10
	var r := _run(b, v, first, 58)      # ticks 10..67 -> 57 ticks after first sighting at the end
	h.eq("reaction ticks at 128 = 58 (first tick >= 0.45 s)", _ready_ticks(), 58)
	h.eq("PATROL holds before reaction delay (57 ticks)", r["state"], S.PATROL)
	r = b.think(v, first + 58)
	h.eq("PATROL -> ENGAGE at reaction delay", r["state"], S.ENGAGE)
	h.eq("ENGAGE entry radio ENEMY_SPOTTED", r["intent"]["radio"], Brain.RADIO_ENEMY_SPOTTED)
	# Losing sight for one tick restarts the reaction timer.
	var b2 = Brain.new(2)
	var v2 := _view()
	b2.think(v2, 0)
	v2.enemies = [_enemy(7, 800.0)]
	_run(b2, v2, 1, 40)
	v2.enemies = []
	b2.think(v2, 41)
	v2.enemies = [_enemy(7, 800.0)]
	r = _run(b2, v2, 42, 40)
	h.eq("broken sighting restarts reaction timer", r["state"], S.PATROL)


func _test_engage_intent() -> void:
	var b = Brain.new(3)
	var v := _view()
	var t := _engaged(b, v)
	v.enemies = [_enemy(7, 800.0), _enemy(8, 300.0, 40.0)]
	v.teammates = [{"slot": 2, "x": 10.0, "y": 0.0, "z": 0.0, "alive": true}]
	var it: Dictionary = b.think(v, t)["intent"]
	h.eq_f("aims at nearest visible enemy x", it["aim_target"][0], 300.0)
	h.eq_f("aims at chest height", it["aim_target"][1], Brain.AIM_CHEST_STAND)
	h.eq_f("aims at nearest visible enemy z", it["aim_target"][2], 40.0)
	h.check("fires with ammo", it["fire"])
	h.check("aim error yaw within dial", absf(it["aim_err_yaw_deg"]) <= Brain.AIM_ERROR_DEG)
	h.check("aim error pitch within half dial", absf(it["aim_err_pitch_deg"]) <= Brain.AIM_ERROR_DEG * 0.5)


func _test_low_health() -> void:
	var b = Brain.new(4)
	var v := _view()
	var t := _engaged(b, v)
	_run(b, v, t, 300)                  # stay engaged past the radio cooldown
	t += 300
	v.health = 30.0
	h.eq("health exactly 30% stays ENGAGE", b.think(v, t)["state"], S.ENGAGE)
	v.health = 29.9
	var r: Dictionary = b.think(v, t + 1)
	h.eq("health < 30% -> RETREAT", r["state"], S.RETREAT)
	h.eq("low-health retreat radio FALLING_BACK", r["intent"]["radio"], Brain.RADIO_FALLING_BACK)
	h.check("RETREAT holds fire", not r["intent"]["fire"])
	v.teammates = [{"slot": 2, "x": -300.0, "y": 0.0, "z": 50.0, "alive": true}]
	var it: Dictionary = b.think(v, t + 2)["intent"]
	h.eq_f("retreats toward nearest live teammate (x)", it["move_target"][0], -300.0)
	h.eq_f("retreats toward nearest live teammate (z)", it["move_target"][2], 50.0)
	v.teammates = []
	it = b.think(v, t + 3)["intent"]
	h.eq_f("no teammate: retreat away from last seen enemy", it["move_target"][0], -Brain.RETREAT_STEP)


func _test_outnumbered() -> void:
	var b = Brain.new(5)
	var v := _view()
	var t := _engaged(b, v)
	_run(b, v, t, 300)                  # past the radio cooldown
	t += 300
	v.enemies = [_enemy(7, 800.0), _enemy(8, 900.0)]
	v.teammates = [{"slot": 2, "x": 100.0, "y": 0.0, "z": 0.0, "alive": true}]
	h.eq("2 v 2 (teammate within 512) stays ENGAGE", b.think(v, t)["state"], S.ENGAGE)
	v.teammates = [{"slot": 2, "x": 600.0, "y": 0.0, "z": 0.0, "alive": true}]
	var r: Dictionary = b.think(v, t + 1)
	h.eq("teammate beyond 512 -> outnumbered -> RETREAT", r["state"], S.RETREAT)
	h.eq("outnumbered radio NEED_BACKUP", r["intent"]["radio"], Brain.RADIO_NEED_BACKUP)
	var b2 = Brain.new(5)
	var v2 := _view()
	var t2 := _engaged(b2, v2)
	v2.enemies = [_enemy(7, 800.0), _enemy(8, 900.0)]
	v2.teammates = [{"slot": 2, "x": 100.0, "y": 0.0, "z": 0.0, "alive": false}]
	h.eq("dead teammate doesn't count as support", b2.think(v2, t2)["state"], S.RETREAT)


func _test_out_of_ammo() -> void:
	var b = Brain.new(6)
	var v := _view()
	var t := _engaged(b, v)
	v.mag = 0.0
	var r: Dictionary = b.think(v, t)
	h.eq("empty magazine -> RETREAT", r["state"], S.RETREAT)
	h.check("reload requested with reserve", r["intent"]["reload"])
	h.check("no fire with empty magazine", not r["intent"]["fire"])
	# Totally out of ammo: retreat, no reload, never returns to PATROL.
	var b2 = Brain.new(6)
	var v2 := _view(100.0, 0.0, 0.0)
	var t2 := _engaged_noammo(b2, v2)
	h.eq("out of ammo on sight -> RETREAT (never ENGAGE)", b2.state, S.RETREAT)
	v2.enemies = []
	r = _run(b2, v2, t2, 1000)
	h.eq("no ammo at all: stays RETREAT after clear time", r["state"], S.RETREAT)
	h.check("no ammo at all: reload false", not r["intent"]["reload"])
	v2.mag = 30.0
	h.eq("ammo back -> PATROL", b2.think(v2, t2 + 1000)["state"], S.PATROL)


func _engaged_noammo(b, v: BotView) -> int:
	v.enemies = [_enemy(7, 800.0)]
	_run(b, v, 0, 59)
	return 59


func _test_retreat_to_patrol() -> void:
	var b = Brain.new(7)
	var v := _view()
	var t := _engaged(b, v)
	v.health = 20.0
	b.think(v, t)                       # RETREAT, enemy last seen at tick t
	v.enemies = []
	var clear := int(Brain.RETREAT_CLEAR_S * Brain.TICK_RATE)   # 256
	var r := _run(b, v, t + 1, clear - 1)   # last tick t+clear-1: 255 ticks unseen
	h.eq("RETREAT holds before 2.0 s clear", r["state"], S.RETREAT)
	r = b.think(v, t + clear)
	h.eq("RETREAT -> PATROL after 2.0 s unseen with ammo", r["state"], S.PATROL)


func _test_engage_to_flank() -> void:
	var flank := [PackedFloat64Array([0.0, 0.0, 300.0]), PackedFloat64Array([400.0, 0.0, 300.0])]
	var b = Brain.new(8, [], flank)
	var v := _view()
	v.enemies = [_enemy(7, 800.0)]
	b.think(v, 0)
	# FLANK_AFTER_S is timed from entering ENGAGE (tick 58, after the reaction delay): 58 + 384 = 442.
	var n := 58 + int(Brain.FLANK_AFTER_S * Brain.TICK_RATE)
	var r := _run(b, v, 1, n - 1)       # up to tick 441
	h.eq("ENGAGE holds before 3.0 s in ENGAGE", r["state"], S.ENGAGE)
	r = b.think(v, n)
	h.eq("ENGAGE -> FLANK after 3.0 s in ENGAGE with a flank route", r["state"], S.FLANK)
	h.eq("FLANK entry radio FLANKING", r["intent"]["radio"], Brain.RADIO_FLANKING)
	var b2 = Brain.new(8)
	r = _run(b2, v, 0, 600)
	h.eq("no flank route: stays ENGAGE", r["state"], S.ENGAGE)


func _test_flank_hook_and_exits() -> void:
	var flank := [PackedFloat64Array([0.0, 0.0, 300.0]), PackedFloat64Array([400.0, 0.0, 300.0])]
	var b = Brain.new(9, [], flank)
	b.flank_coordination_hook = func(_v) -> bool: return false
	var v := _view()
	v.enemies = [_enemy(7, 800.0)]
	_run(b, v, 0, 443)
	h.eq("in FLANK", b.state, S.FLANK)
	var it: Dictionary = b.think(v, 443)["intent"]
	h.eq_f("FLANK: heads for the flank start (route point 0), not own spot", it["move_target"][2], 300.0)
	h.check("FLANK: keeps firing at a visible enemy while moving to cover", it["fire"] and it["aim_target"].size() == 3)
	# At the flank start, hook false, enemy NOT in view: hold at route point 0.
	v.z = 300.0
	v.enemies = []
	var r: Dictionary = b.think(v, 444)
	h.eq("hook false, unseen: still FLANK", r["state"], S.FLANK)
	h.eq_f("hook false: holds at route point 0 (x)", r["intent"]["move_target"][0], 0.0)
	h.eq_f("hook false: holds at route point 0 (z)", r["intent"]["move_target"][2], 300.0)
	# Waiting at the start and an enemy shows up in range: ENGAGE after the reaction delay, don't stand in plain sight.
	v.enemies = [_enemy(7, 600.0, 300.0)]
	r = _run(b, v, 445, 58)
	h.eq("waiting + seen: FLANK during reaction delay", r["state"], S.FLANK)
	r = b.think(v, 445 + 58)
	h.eq("waiting + seen in range: FLANK -> ENGAGE", r["state"], S.ENGAGE)
	h.check("after FLANK -> ENGAGE: fires", r["intent"]["fire"])
	r = _run(b, v, 445 + 59, 300)
	h.eq("no bounce: stays ENGAGE for < 3.0 s after re-engaging", r["state"], S.ENGAGE)
	# Waiting, enemy seen but OUT of range: keep holding.
	var bf = Brain.new(9, [], flank)
	bf.flank_coordination_hook = func(_v) -> bool: return false
	var vf := _view()
	vf.enemies = [_enemy(7, 800.0)]
	_run(bf, vf, 0, 443)
	vf.z = 300.0
	vf.enemies = [_enemy(7, 2000.0, 300.0)]
	r = _run(bf, vf, 443, 120)
	h.eq("waiting + enemy beyond FLANK_ENGAGE_RANGE: stays FLANK", r["state"], S.FLANK)
	# Hook true at the start: move on to point 1; lose contact, re-seen -> ENGAGE after reaction.
	var b1 = Brain.new(9, [], flank)
	var v1 := _view()
	v1.enemies = [_enemy(7, 800.0)]
	_run(b1, v1, 0, 443)
	v1.z = 300.0
	v1.enemies = []
	it = b1.think(v1, 443)["intent"]
	h.eq_f("hook true: moves on to point 1", it["move_target"][0], 400.0)
	v1.enemies = [_enemy(7, 800.0)]
	r = _run(b1, v1, 444, 58)           # ticks 444..501: 57 ticks after re-sighting at the end
	h.eq("FLANK holds during reaction delay after re-sighting", r["state"], S.FLANK)
	r = b1.think(v1, 444 + 58)
	h.eq("FLANK -> ENGAGE when enemy re-seen (after reaction)", r["state"], S.ENGAGE)
	# Route finished with no contact -> PATROL.
	var b2 = Brain.new(9, [], flank)
	var v2 := _view()
	v2.enemies = [_enemy(7, 800.0)]
	_run(b2, v2, 0, 443)
	v2.enemies = []
	v2.z = 300.0
	b2.think(v2, 443)                   # reach point 0
	v2.x = 400.0
	b2.think(v2, 444)                   # reach point 1 -> route done
	h.eq("FLANK -> PATROL when route finished", b2.think(v2, 445)["state"], S.PATROL)
	# Low health during flank -> RETREAT.
	var b3 = Brain.new(9, [], flank)
	var v3 := _view()
	v3.enemies = [_enemy(7, 800.0)]
	_run(b3, v3, 0, 443)
	v3.health = 10.0
	h.eq("FLANK -> RETREAT on low health", b3.think(v3, 443)["state"], S.RETREAT)


func _test_crouched_aim() -> void:
	var b = Brain.new(14)
	var v := _view()
	var t := _engaged(b, v)
	var e := _enemy(7, 800.0)
	e["duck"] = 1.0
	v.enemies = [e]
	var it: Dictionary = b.think(v, t)["intent"]
	h.eq_f("crouched enemy: aims at crouched chest 27.25", it["aim_target"][1], Brain.AIM_CHEST_CROUCH)
	e["duck"] = 0.5
	it = b.think(v, t + 1)["intent"]
	h.eq_f("mid-duck enemy (f 0.5): aims at blended chest 40.875", it["aim_target"][1], 40.875)
	# From the server: duck fraction goes through the snapshot quantization (u8 / 255.0).
	var players := _players(300.0)
	players[2]["duck_fraction"] = 0.5
	var vv: BotView = BotView.from_server(players, 1, 1 << 7)
	h.eq_f("view carries quantized remote duck (128 / 255)", float(vv.enemies[0]["duck"]), 128.0 / 255.0)
	players[2]["duck_fraction"] = 1.0
	vv = BotView.from_server(players, 1, 1 << 7)
	var b2 = Brain.new(14)
	var r: Dictionary = {}
	for i in range(60):
		r = b2.think(vv, i)
	h.eq_f("crouched enemy via snapshot view: aim height 27.25", r["intent"]["aim_target"][1], 27.25)


func _test_full_reload_exit() -> void:
	var b = Brain.new(15)
	var v := _view()
	var t := _engaged(b, v)
	v.mag = 0.0
	b.think(v, t)                       # RETREAT
	v.enemies = []
	v.mag = 1.0
	var r := _run(b, v, t + 1, 600)
	h.eq("1 round left, reserve 90: stays RETREAT (not fully reloaded)", r["state"], S.RETREAT)
	h.check("1 round left: keeps reloading", r["intent"]["reload"])
	v.mag = 29.0
	h.eq("29 of 30: still RETREAT", b.think(v, t + 601)["state"], S.RETREAT)
	v.mag = 30.0
	h.eq("full magazine: RETREAT -> PATROL", b.think(v, t + 602)["state"], S.PATROL)
	var b2 = Brain.new(15)
	var v2 := _view()
	var t2 := _engaged(b2, v2)
	v2.mag = 0.0
	b2.think(v2, t2)
	v2.enemies = []
	v2.mag = 1.0
	v2.reserve = 0.0
	var r2 := _run(b2, v2, t2 + 1, 300)
	h.eq("1 round left, reserve empty: counts as reloaded -> PATROL", r2["state"], S.PATROL)


func _test_idle_straight_to_retreat() -> void:
	for case in [["low health", 20.0, 30.0], ["empty magazine", 100.0, 0.0]]:
		var b = Brain.new(16)
		var v := _view(float(case[1]), float(case[2]))
		v.round_live = false
		v.enemies = [_enemy(7, 800.0)]
		_run(b, v, 0, 100)              # IDLE while round not live; sighting timer runs from tick 0
		v.round_live = true
		var r: Dictionary = b.think(v, 100)
		h.eq("IDLE + reacted + %s: straight to RETREAT" % case[0], r["state"], S.RETREAT)
	var b3 = Brain.new(16)
	var v3 := _view()
	v3.round_live = false
	v3.enemies = [_enemy(7, 800.0)]
	_run(b3, v3, 0, 100)
	v3.round_live = true
	h.eq("IDLE + reacted + healthy: ENGAGE", b3.think(v3, 100)["state"], S.ENGAGE)


func _test_one_v_one_not_outnumbered() -> void:
	var b = Brain.new(17)
	var v := _view()
	var t := _engaged(b, v)
	h.eq("1v1 (support counts the bot itself): stays ENGAGE", b.think(v, t)["state"], S.ENGAGE)


func _test_lose_contact() -> void:
	var b = Brain.new(10)
	var v := _view()
	var t := _engaged(b, v)
	v.enemies = []
	var n := int(Brain.LOSE_CONTACT_S * Brain.TICK_RATE)
	var r := _run(b, v, t, n - 2)
	h.eq("ENGAGE holds while contact < 2.0 s", r["state"], S.ENGAGE)
	h.eq_f("ENGAGE without sight moves to last seen position", r["intent"]["move_target"][0], 800.0)
	r = _run(b, v, t + n - 2, 2)
	h.eq("ENGAGE -> PATROL after 2.0 s without contact", r["state"], S.PATROL)


func _test_patrol_to_retreat() -> void:
	var b = Brain.new(11)
	var v := _view(15.0)
	b.think(v, 0)
	v.enemies = [_enemy(7, 800.0)]
	var r := _run(b, v, 1, 59)
	h.eq("PATROL -> RETREAT on sight when already low health", r["state"], S.RETREAT)


func _test_radio_cooldown() -> void:
	var b = Brain.new(12)
	var v := _view()
	_engaged(b, v)                      # ENEMY_SPOTTED at tick 58
	v.enemies = []
	_run(b, v, 59, 256)                 # back to PATROL around tick 314
	v.enemies = [_enemy(7, 800.0)]
	var radios: Array = []
	for i in range(80):
		var r: Dictionary = b.think(v, 315 + i)
		if r["intent"]["radio"] != "":
			radios.append(r["intent"]["radio"])
	h.eq("second spot after > 2.0 s gets a radio call", radios, [Brain.RADIO_ENEMY_SPOTTED])
	var b2 = Brain.new(12)
	var v2 := _view()
	_engaged(b2, v2)                    # radio at tick 58
	v2.health = 10.0
	var r2: Dictionary = b2.think(v2, 59)
	h.eq("retreat 1 tick after a call: radio suppressed by cooldown", r2["intent"]["radio"], "")


func _test_patrol_route() -> void:
	var route := [PackedFloat64Array([100.0, 0.0, 0.0]), PackedFloat64Array([100.0, 0.0, 100.0])]
	var b = Brain.new(13, route)
	var v := _view()
	h.eq_f("patrol: first waypoint", b.think(v, 0)["intent"]["move_target"][0], 100.0)
	v.x = 95.0
	var it: Dictionary = b.think(v, 1)["intent"]
	h.eq_f("patrol: advances inside arrive radius", it["move_target"][2], 100.0)


func _players(enemy_x: float) -> Array:
	return [
		{"slot": 1, "team": "T", "alive": true, "health": 100.0, "mag": 30.0, "reserve": 90.0, "x": 0.0, "y": 0.0, "z": 0.0},
		{"slot": 2, "team": "T", "alive": true, "health": 100.0, "mag": 30.0, "reserve": 90.0, "x": -50.0, "y": 0.0, "z": 0.0},
		{"slot": 7, "team": "CT", "alive": true, "health": 100.0, "mag": 30.0, "reserve": 90.0, "x": enemy_x, "y": 0.0, "z": 0.0},
	]


func _log(b, players: Array, mask: int, ticks: int) -> String:
	var out := PackedStringArray()
	for t in range(ticks):
		var v: BotView = BotView.from_server(players, 1, mask)
		var r: Dictionary = b.think(v, t)
		out.append("%d %s %s" % [t, r["state_name"], var_to_str(r["intent"]).replace("\n", " ")])
	return "\n".join(out)


func _test_unsent_enemy() -> void:
	var route := [PackedFloat64Array([100.0, 0.0, 0.0]), PackedFloat64Array([-100.0, 0.0, 0.0])]
	# Enemy slot 7 is 40 units away but culled for slot 1 (bit 7 not set). Teammate always sent.
	var hidden = Brain.new(77, route)
	var log_hidden := _log(hidden, _players(40.0), 0, 1280)
	var v: BotView = BotView.from_server(_players(40.0), 1, 0)
	h.eq("view drops unsent enemy", v.enemies.size(), 0)
	h.eq("view keeps teammate (always sent)", v.teammates.size(), 1)
	h.eq("never reacts to unsent enemy: still PATROL after 10 s", hidden.state, S.PATROL)
	var empty_world := _players(40.0)
	empty_world.remove_at(2)
	var log_empty := _log(Brain.new(77, route), empty_world, 0, 1280)
	h.check("unsent enemy: decisions identical to a world without that enemy (1,280 ticks)", log_hidden == log_empty)
	var sent = Brain.new(77, route)
	_log(sent, _players(40.0), 1 << 7, 59)
	h.eq("same enemy, sent (bit 7): ENGAGE after reaction", sent.state, S.ENGAGE)


func _scripted(seed_value: int) -> String:
	var flank := [PackedFloat64Array([0.0, 0.0, 300.0]), PackedFloat64Array([400.0, 0.0, 300.0])]
	var b = Brain.new(seed_value, [PackedFloat64Array([100.0, 0.0, 0.0])], flank)
	var out := PackedStringArray()
	var v := _view()
	for t in range(2000):
		v.enemies = [_enemy(7, 800.0 - float(t % 300))] if (t / 200) % 2 == 1 else []
		v.health = 100.0 - float(t) * 0.04
		var r: Dictionary = b.think(v, t)
		out.append("%d %d %s" % [t, r["state"], var_to_str(r["intent"]).replace("\n", " ")])
	return "\n".join(out)


func _test_determinism() -> void:
	var a := _scripted(4242)
	var b := _scripted(4242)
	h.check("same seed: identical 2,000-tick state + intent log", a == b, a.sha256_text().substr(0, 16))
	var c := _scripted(4243)
	h.check("different seed: aim errors differ", a != c)
	var states := {}
	for line in a.split("\n"):
		states[line.split(" ")[1]] = true
	h.check("scripted run visits ENGAGE, RETREAT and PATROL", states.has("1") and states.has("2") and states.has("3"), str(states.keys()))


func _test_source_rules() -> void:
	var src := FileAccess.get_file_as_string("res://bot_brain.gd")
	for bad in ["from_server", "sent_mask", "players", "Body3D", "PhysicsServer", "Engine.", "get_tree", "Node"]:
		h.check("bot_brain.gd does not reference '%s'" % bad, src.find(bad) < 0)
	h.check("bot_brain.gd extends RefCounted", src.find("extends RefCounted") >= 0)
	h.check("bot_brain.gd declares Follows: CD-r3", src.find("Follows: CD-r3") >= 0)
