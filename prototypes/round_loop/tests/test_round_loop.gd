extends SceneTree
## Headless: godot --headless --path . --script res://tests/test_round_loop.gd
## Every phase transition and win condition of round loop spec v0.1, at 128 Hz.
## Tick counts: freeze 15.0 s = 1920, round 100.0 s = 12800, plant 3.2 s = 410 (3.203125 s),
## defuse 10.0 s kit = 1280, 15.0 s no kit = 1920, bomb 40.0 s (PROPOSED) = 5120, round end 5.0 s = 640.

const RC = preload("res://round_controller.gd")
const E = preload("res://economy.gd")
const H = preload("res://tests/harness.gd")

const T_SLOTS := [1, 2, 3, 4, 5]
const CT_SLOTS := [6, 7, 8, 9, 10]

var h


func _new(overrides: Dictionary = {}):
	var c = RC.new(overrides)
	for s in T_SLOTS:
		c.add_player(s, "T")
	for s in CT_SLOTS:
		c.add_player(s, "CT")
	c.start_match()
	return c


func _run(c, n: int, input: Dictionary = {}) -> void:
	for i in range(n):
		c.step(input)


func _to_live(c) -> void:
	_run(c, 1920)


func _wipe(team_slots: Array, killer: int) -> Dictionary:
	var k := []
	for s in team_slots:
		k.append([killer, s])
	return {"kills": k}


func _planted(overrides: Dictionary = {}):
	var c = _new(overrides)
	_to_live(c)
	_run(c, 410, {"plant_hold": 3})
	return c


func _init() -> void:
	print("Godot ", Engine.get_version_info()["string"])
	h = H.new()
	h.eq_f("DT is exactly 1/128", RC.DT, 0.0078125, 0.0)

	# --- WARMUP
	var c = RC.new()
	c.add_player(1, "T")
	c.add_player(6, "CT")
	_run(c, 1000)
	h.eq("WARMUP holds until start_match", c.phase, RC.Phase.WARMUP)
	c.start_match()
	h.eq("start_match -> FREEZE", c.phase, RC.Phase.FREEZE)
	h.eq("round number 1", c.round_number, 1)
	h.eq_f("start cash 800 (T)", c.players[1]["cash"], 800.0)
	h.eq_f("start cash 800 (CT)", c.players[6]["cash"], 800.0)

	# --- FREEZE 15 s
	c = _new()
	h.eq_f("freeze time_left 15.0 at start", c.get_snapshot_fields()["time_left_s"], 15.0)
	_run(c, 1919, {"kills": [[6, 1]]})
	h.eq("FREEZE at tick 1919", c.phase, RC.Phase.FREEZE)
	h.check("kills ignored during FREEZE", c.players[1]["alive"])
	c.step()
	h.eq("FREEZE -> LIVE at tick 1920 (15.0 s)", c.phase, RC.Phase.LIVE)
	h.eq_f("live time_left 100.0 at start", c.get_snapshot_fields()["time_left_s"], 100.0)
	_run(c, 128)
	h.eq_f("live time_left 99.0 after 128 ticks", c.get_snapshot_fields()["time_left_s"], 99.0)

	# --- Buy window (server-validated)
	c = _new()
	h.eq("FREEZE: AK with 800 rejected (funds)", c.request_buy(1, "ak47")["result"], E.BuyResult.INSUFFICIENT_FUNDS)
	h.eq_f("FREEZE: rejected buy keeps 800", c.players[1]["cash"], 800.0)
	h.eq("FREEZE: vest + helmet with 800 rejected (funds)", c.request_buy(6, "armor_helmet")["result"], E.BuyResult.INSUFFICIENT_FUNDS)
	h.eq_f("FREEZE: rejected helmet keeps 800", c.players[6]["cash"], 800.0)
	h.eq("FREEZE: vest 650 accepted", c.request_buy(6, "armor_vest")["result"], E.BuyResult.OK)
	h.eq_f("vest deducted: 150 left", c.players[6]["cash"], 150.0)
	h.check("armor flag set server-side", c.players[6]["armor"])
	h.check("vest only: no helmet", not c.players[6]["helmet"])
	c.players[5]["cash"] = 1000.0
	h.eq("FREEZE: vest + helmet with 1000 accepted", c.request_buy(5, "armor_helmet")["result"], E.BuyResult.OK)
	h.eq_f("vest + helmet deducted: 0 left", c.players[5]["cash"], 0.0)
	h.check("helmet flag set server-side", c.players[5]["helmet"])
	h.eq("FREEZE: kit accepted for CT", c.request_buy(7, "defuse_kit")["result"], E.BuyResult.OK)
	h.check("kit flag set server-side", c.players[7]["has_kit"])
	h.eq("FREEZE: kit rejected for T", c.request_buy(2, "defuse_kit")["result"], E.BuyResult.WRONG_TEAM)
	_to_live(c)
	h.eq("LIVE: buy rejected (window 0.0 s, PROPOSED)", c.request_buy(8, "glock")["result"], E.BuyResult.NOT_BUY_TIME)
	c = _new({"buy_window_into_live_s": 20.0})
	_to_live(c)
	_run(c, 1280)
	h.eq("LIVE +10 s with 20 s window: buy OK", c.request_buy(8, "glock")["result"], E.BuyResult.OK)
	_run(c, 1280)
	h.eq("LIVE +20 s with 20 s window: closed", c.request_buy(9, "glock")["result"], E.BuyResult.NOT_BUY_TIME)

	# --- Clock zero, no plant = CT win
	c = _new()
	_to_live(c)
	_run(c, 12799)
	h.eq("LIVE at 12799 ticks", c.phase, RC.Phase.LIVE)
	c.step()
	h.eq("clock zero (100.0 s) -> ROUND_END", c.phase, RC.Phase.ROUND_END)
	h.eq("clock zero winner CT", c.winner, "CT")
	h.eq("clock zero reason TIME_EXPIRED", c.reason, RC.Reason.TIME_EXPIRED)
	h.eq_f("CT win bonus: 800 + 3000", c.players[6]["cash"], 3800.0)
	h.eq_f("T first loss bonus: 800 + 1400", c.players[1]["cash"], 2200.0)

	# --- Elimination
	c = _new()
	_to_live(c)
	c.step(_wipe(T_SLOTS, 6))
	h.eq("all T dead -> CT win", c.winner, "CT")
	h.eq("reason T_ELIMINATED", c.reason, RC.Reason.T_ELIMINATED)
	h.eq_f("CT killer: 800 + 5x300 + 3000", c.players[6]["cash"], 5300.0)
	h.eq_f("CT teammate: 800 + 3000", c.players[7]["cash"], 3800.0)
	c = _new()
	_to_live(c)
	_run(c, 100, {"kills": [[1, 6]]})
	h.eq("one CT dead: still LIVE", c.phase, RC.Phase.LIVE)
	h.eq_f("kill paid once (dead victim not re-paid)", c.players[1]["cash"], 1100.0)
	c.step(_wipe(CT_SLOTS, 1))
	h.eq("all CT dead -> T win", c.winner, "T")
	h.eq("reason CT_ELIMINATED", c.reason, RC.Reason.CT_ELIMINATED)
	c = _new()
	_to_live(c)
	var both: Dictionary = _wipe(T_SLOTS, 6)
	both["kills"].append_array(_wipe(CT_SLOTS, 1)["kills"])
	c.step(both)
	h.eq("double wipe same tick in LIVE -> CT (PROPOSED)", c.winner, "CT")

	# --- Plant 3.2 s
	c = _new()
	_to_live(c)
	_run(c, 409, {"plant_hold": 3})
	h.eq("plant held 409 ticks: still LIVE", c.phase, RC.Phase.LIVE)
	c.step({"plant_hold": 3})
	h.eq("plant held 410 ticks (3.203125 s) -> PLANTED", c.phase, RC.Phase.PLANTED)
	h.eq_f("planter: 800 + 200 + 300", c.players[3]["cash"], 1300.0)
	h.eq_f("T teammate: 800 + 300", c.players[1]["cash"], 1100.0)
	h.eq_f("CT unchanged on plant", c.players[6]["cash"], 800.0)
	h.eq_f("bomb time_left 40.0 at plant", c.get_snapshot_fields()["time_left_s"], 40.0)
	c = _new()
	_to_live(c)
	_run(c, 200, {"plant_hold": 3})
	c.step()
	_run(c, 409, {"plant_hold": 3})
	h.eq("interrupted plant restarts: 409 more not enough", c.phase, RC.Phase.LIVE)
	c.step({"plant_hold": 3})
	h.eq("interrupted plant: 410 fresh ticks plants", c.phase, RC.Phase.PLANTED)
	c = _new()
	_to_live(c)
	_run(c, 300, {"plant_hold": 3})
	c.step({"plant_hold": 3, "kills": [[6, 3]]})
	_run(c, 200, {"plant_hold": 3})
	h.eq("dead planter can't plant", c.phase, RC.Phase.LIVE)
	h.eq_f("plant progress reset after planter death", c.plant_progress, 0.0)
	_run(c, 410, {"plant_hold": 4})
	h.eq("other T plants with fresh 410 ticks", c.phase, RC.Phase.PLANTED)
	c = _new()
	_to_live(c)
	_run(c, 410, {"plant_hold": 7})
	h.eq("CT can't plant", c.phase, RC.Phase.LIVE)
	c = _new()
	_to_live(c)
	_run(c, 12390)
	_run(c, 410, {"plant_hold": 3})
	h.eq("plant completing on the clock-zero tick wins (PROPOSED)", c.phase, RC.Phase.PLANTED)
	c = _new()
	_to_live(c)
	_run(c, 12391)
	_run(c, 409, {"plant_hold": 3})
	h.eq("plant still in progress at clock zero -> CT win", c.winner, "CT")
	h.eq("... reason TIME_EXPIRED", c.reason, RC.Reason.TIME_EXPIRED)

	# --- Planted: explosion
	c = _planted()
	_run(c, 5119)
	h.eq("PLANTED at 5119 ticks (round clock ignored)", c.phase, RC.Phase.PLANTED)
	c.step()
	h.eq("bomb 40.0 s -> T win", c.winner, "T")
	h.eq("reason BOMB_EXPLODED", c.reason, RC.Reason.BOMB_EXPLODED)
	h.eq_f("planter after win: 1300 + 3000", c.players[3]["cash"], 4300.0)
	h.eq_f("CT after loss: 800 + 1400", c.players[6]["cash"], 2200.0)

	# --- Defuse
	c = _new()
	c.request_buy(7, "defuse_kit")
	_to_live(c)
	_run(c, 410, {"plant_hold": 3})
	_run(c, 1279, {"defuse_hold": 7})
	h.eq("kit defuse 1279 ticks: still PLANTED", c.phase, RC.Phase.PLANTED)
	c.step({"defuse_hold": 7})
	h.eq("kit defuse 10.0 s -> CT win", c.winner, "CT")
	h.eq("reason BOMB_DEFUSED", c.reason, RC.Reason.BOMB_DEFUSED)
	h.eq_f("defuser: 800 - 200 kit + 300 + 120 + 3000", c.players[7]["cash"], 4020.0)
	h.eq_f("CT teammate: 800 + 120 + 3000", c.players[6]["cash"], 3920.0)
	h.eq_f("planter after loss: 1300 + 1400", c.players[3]["cash"], 2700.0)
	c = _planted()
	_run(c, 1919, {"defuse_hold": 8})
	h.eq("no-kit defuse 1919 ticks: still PLANTED", c.phase, RC.Phase.PLANTED)
	c.step({"defuse_hold": 8})
	h.eq("no-kit defuse 15.0 s -> CT win", c.reason, RC.Reason.BOMB_DEFUSED)
	c = _planted()
	_run(c, 1000, {"defuse_hold": 8})
	c.step()
	_run(c, 1919, {"defuse_hold": 8})
	h.eq("interrupted defuse restarts from 0", c.phase, RC.Phase.PLANTED)
	c.step({"defuse_hold": 8})
	h.eq("interrupted defuse: fresh 1920 ticks defuses", c.reason, RC.Reason.BOMB_DEFUSED)
	c = _planted()
	_run(c, 1000, {"defuse_hold": 8})
	c.step({"defuse_hold": 8, "kills": [[1, 8]]})
	h.eq_f("defuser killed: progress reset", c.defuse_progress, 0.0)
	c = _planted()
	_run(c, 410, {"defuse_hold": 2})
	h.eq_f("T can't defuse", c.defuse_progress, 0.0)
	c = _new()
	c.request_buy(7, "defuse_kit")
	_to_live(c)
	_run(c, 410, {"plant_hold": 3})
	_run(c, 3840)
	_run(c, 1280, {"defuse_hold": 7})
	h.eq("defuse finishing on the explosion tick -> CT (PROPOSED)", c.reason, RC.Reason.BOMB_DEFUSED)
	c = _new()
	c.request_buy(7, "defuse_kit")
	_to_live(c)
	_run(c, 410, {"plant_hold": 3})
	_run(c, 3841)
	_run(c, 1279, {"defuse_hold": 7})
	h.eq("defuse 1 tick short at explosion -> T", c.reason, RC.Reason.BOMB_EXPLODED)

	# --- Elimination after plant
	c = _planted()
	c.step(_wipe(CT_SLOTS, 1))
	h.eq("all CT dead after plant -> T win", c.reason, RC.Reason.CT_ELIMINATED)
	c = _planted()
	c.step(_wipe(T_SLOTS, 6))
	h.eq("all T dead after plant: round continues (CS rule, default)", c.phase, RC.Phase.PLANTED)
	_run(c, 1920, {"defuse_hold": 6})
	h.eq("... CT must still defuse", c.reason, RC.Reason.BOMB_DEFUSED)
	c = _planted({"t_elim_after_plant_ends_round": true})
	c.step(_wipe(T_SLOTS, 6))
	h.eq("switch: all T dead after plant -> CT win", c.reason, RC.Reason.T_ELIMINATED)

	# --- ROUND_END -> next round
	c = _new()
	_to_live(c)
	c.step(_wipe(T_SLOTS, 6))
	_run(c, 639)
	h.eq("ROUND_END at 639 ticks", c.phase, RC.Phase.ROUND_END)
	c.step()
	h.eq("ROUND_END 5.0 s -> FREEZE", c.phase, RC.Phase.FREEZE)
	h.eq("round number 2", c.round_number, 2)
	h.check("everyone alive again", c.players[1]["alive"] and c.players[5]["alive"])
	h.eq("score CT 1", c.score["CT"], 1)

	# --- Loss ladder across rounds (T loses on time 5 times, then wins)
	c = _new()
	var t_cash := [2200.0, 4100.0, 6500.0, 9400.0, 12800.0]
	for i in range(5):
		_to_live(c)
		_run(c, 12800)
		h.eq_f("T cash after loss %d (ladder)" % (i + 1), c.players[1]["cash"], t_cash[i])
		_run(c, 640)
	_to_live(c)
	c.step(_wipe(CT_SLOTS, 2))
	h.eq_f("T killer after first win: capped at 16000", c.players[2]["cash"], 16000.0)
	h.eq_f("CT after first loss (streak reset by wins): +1400", c.players[6]["cash"], 16000.0)
	h.eq("T loss streak reset on win", c.loss_streak["T"], 0)
	h.eq("CT loss streak 1", c.loss_streak["CT"], 1)
	c = _new({"loss_reset_mode": "decrement"})
	for i in range(3):
		_to_live(c)
		_run(c, 12800)
		_run(c, 640)
	_to_live(c)
	c.step(_wipe(CT_SLOTS, 2))
	h.eq("decrement mode: T streak 3 -> 2 on win", c.loss_streak["T"], 2)

	# --- Match over (MR12 default -> 13 wins; MR15 switch -> 16)
	for mr in [12, 15]:
		c = _new({"max_rounds_per_half": mr})
		var rounds := 0
		while not c.match_over and rounds < 40:
			_to_live(c)
			c.step(_wipe(T_SLOTS, 6))
			rounds += 1
			if not c.match_over:
				_run(c, 640)
		h.eq("MR%d: match over after %d CT wins" % [mr, mr + 1], rounds, mr + 1)
		_run(c, 2000)
		h.eq("MR%d: stays in ROUND_END after match over" % mr, c.phase, RC.Phase.ROUND_END)

	# --- Server-only events + snapshot fields
	c = _new()
	_to_live(c)
	_run(c, 410, {"plant_hold": 3})
	var phases := []
	for ev in c.events:
		if ev["type"] == "phase":
			phases.append(ev["to"])
	h.eq("event log: FREEZE, LIVE, PLANTED", phases, [RC.Phase.FREEZE, RC.Phase.LIVE, RC.Phase.PLANTED])
	var live_ev: Dictionary = {}
	for ev in c.events:
		if ev["type"] == "phase" and ev["to"] == RC.Phase.LIVE:
			live_ev = ev
	h.eq("LIVE transition stamped on server tick 1920", live_ev.get("tick", -1), 1920)
	var snap: Dictionary = c.get_snapshot_fields()
	h.eq("snapshot phase PLANTED", snap["phase"], RC.Phase.PLANTED)
	h.check("snapshot timer is a float", typeof(snap["time_left_s"]) == TYPE_FLOAT)
	h.eq("snapshot server_tick", snap["server_tick"], 2330)

	print("RESULT round_loop: %d passed, %d failed" % [h.passed, h.failed])
	quit(0 if h.failed == 0 else 1)
