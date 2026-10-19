extends SceneTree
## Headless: godot --headless --path . --script res://tests/test_economy.gd
## Every economy rule of round loop spec v0.1 Section 2, plus server-side buy validation.

const E = preload("res://economy.gd")
const W = preload("res://weapons_table.gd")
const H = preload("res://tests/harness.gd")


func _init() -> void:
	print("Godot ", Engine.get_version_info()["string"])
	var h = H.new()

	# Spec constants (Joan's numbers) and the float rule
	h.eq_f("start cash 800", E.START_CASH, 800.0)
	h.eq_f("kill reward 300", E.KILL_REWARD, 300.0)
	h.eq_f("plant planter 200", E.PLANT_PLANTER, 200.0)
	h.eq_f("plant team 300", E.PLANT_TEAM, 300.0)
	h.eq_f("defuse defuser 300", E.DEFUSE_DEFUSER, 300.0)
	h.eq_f("defuse team split 600", E.DEFUSE_TEAM_SPLIT, 600.0)
	h.eq_f("win bonus 3000", E.win_bonus(), 3000.0)
	h.eq_f("vest 650", E.ARMOR_VEST, 650.0)
	h.eq_f("vest + helmet 1000", E.ARMOR_HELMET, 1000.0)
	h.eq_f("vest table price 650", W.get_item("armor_vest")["price"], 650.0)
	h.eq_f("vest + helmet table price 1000", W.get_item("armor_helmet")["price"], 1000.0)
	var all_float := typeof(E.START_CASH) == TYPE_FLOAT and typeof(E.KILL_REWARD) == TYPE_FLOAT and typeof(E.WIN_BONUS) == TYPE_FLOAT
	for v in E.LOSS_LADDER:
		all_float = all_float and typeof(v) == TYPE_FLOAT
	for id in W.ITEMS:
		all_float = all_float and typeof(W.ITEMS[id]["price"]) == TYPE_FLOAT
	h.check("all money values are floats", all_float)

	# Kill reward
	h.eq_f("kill enemy T->CT", E.kill_reward("T", "CT"), 300.0)
	h.eq_f("kill enemy CT->T", E.kill_reward("CT", "T"), 300.0)
	h.eq_f("team kill pays 0 (PROPOSED)", E.kill_reward("T", "T"), 0.0)

	# Loss ladder 1400/1900/2400/2900/3400, 5th and beyond = 3400
	var want := [1400.0, 1900.0, 2400.0, 2900.0, 3400.0, 3400.0, 3400.0, 3400.0]
	for i in range(want.size()):
		h.eq_f("loss bonus after %d consecutive losses" % (i + 1), E.loss_bonus(i + 1), want[i])

	# Loss streak rules
	h.eq("streak +1 on loss", E.next_loss_streak(2, false), 3)
	h.eq("streak reset on win (default)", E.next_loss_streak(4, true), 0)
	h.eq("streak decrement on win (alt)", E.next_loss_streak(4, true, "decrement"), 3)
	h.eq("streak decrement floors at 0", E.next_loss_streak(0, true, "decrement"), 0)

	# Plant rewards
	var t := [1, 2, 3, 4, 5]
	var pr: Dictionary = E.plant_rewards(3, t)
	h.eq_f("plant each: planter 200 + 300", pr[3], 500.0)
	h.eq_f("plant each: teammate 300", pr[1], 300.0)
	var total := 0.0
	for s in pr:
		total += pr[s]
	h.eq_f("plant each: total 1700 for 5 T", total, 1700.0)
	var ps: Dictionary = E.plant_rewards(3, t, "split")
	h.eq_f("plant split: planter 200 + 60", ps[3], 260.0)
	h.eq_f("plant split: teammate 60", ps[1], 60.0)

	# Defuse rewards
	var ct := [6, 7, 8, 9, 10]
	var dr: Dictionary = E.defuse_rewards(7, ct, [7, 9])
	h.eq_f("defuse team split: defuser 300 + 120", dr[7], 420.0)
	h.eq_f("defuse team split: dead teammate 120", dr[6], 120.0)
	var da: Dictionary = E.defuse_rewards(7, ct, [7, 9], "alive")
	h.eq_f("defuse alive split: defuser 300 + 300", da[7], 600.0)
	h.eq_f("defuse alive split: alive teammate 300", da[9], 300.0)
	h.check("defuse alive split: dead teammate gets nothing", not da.has(6))
	var dsum := 0.0
	for s in dr:
		dsum += dr[s]
	h.eq_f("defuse total 900 (300 + 600)", dsum, 900.0)

	# Cash cap
	h.eq_f("credit under cap", E.credit(800.0, 300.0), 1100.0)
	h.eq_f("credit clamps at 16000 (PROPOSED)", E.credit(15900.0, 3000.0), 16000.0)

	# Buy validation (server-side)
	var ak := W.get_item("ak47")
	var m4 := W.get_item("m4a1")
	var r := E.validate_buy(2500.0, ak, "T", true)
	h.eq("AK by T with exact cash: OK", r["result"], E.BuyResult.OK)
	h.eq_f("AK by T: cash 2500 -> 0", r["new_cash"], 0.0)
	h.eq("AK by CT: WRONG_TEAM", E.validate_buy(5000.0, ak, "CT", true)["result"], E.BuyResult.WRONG_TEAM)
	h.eq("M4 by T: WRONG_TEAM", E.validate_buy(5000.0, m4, "T", true)["result"], E.BuyResult.WRONG_TEAM)
	h.eq("M4 by CT: OK", E.validate_buy(5000.0, m4, "CT", true)["result"], E.BuyResult.OK)
	var poor := E.validate_buy(2499.0, ak, "T", true)
	h.eq("AK with 2499: INSUFFICIENT_FUNDS", poor["result"], E.BuyResult.INSUFFICIENT_FUNDS)
	h.eq_f("rejected buy leaves cash unchanged", poor["new_cash"], 2499.0)
	h.eq("unknown item: UNKNOWN_ITEM", E.validate_buy(9000.0, W.get_item("raygun"), "T", true)["result"], E.BuyResult.UNKNOWN_ITEM)
	h.eq("buy closed: NOT_BUY_TIME", E.validate_buy(9000.0, ak, "T", false)["result"], E.BuyResult.NOT_BUY_TIME)
	h.eq("dead player: DEAD", E.validate_buy(9000.0, ak, "T", true, false)["result"], E.BuyResult.DEAD)
	h.eq("kit by T: WRONG_TEAM", E.validate_buy(9000.0, W.get_item("defuse_kit"), "T", true)["result"], E.BuyResult.WRONG_TEAM)
	h.eq("vest 650 with 800: OK", E.validate_buy(800.0, W.get_item("armor_vest"), "CT", true)["result"], E.BuyResult.OK)
	h.eq_f("vest leaves 150", E.validate_buy(800.0, W.get_item("armor_vest"), "CT", true)["new_cash"], 150.0)
	h.eq("vest + helmet with 800: INSUFFICIENT_FUNDS", E.validate_buy(800.0, W.get_item("armor_helmet"), "CT", true)["result"], E.BuyResult.INSUFFICIENT_FUNDS)
	h.eq("vest + helmet with 1000: OK", E.validate_buy(1000.0, W.get_item("armor_helmet"), "T", true)["result"], E.BuyResult.OK)
	h.eq_f("vest + helmet with 1000 leaves 0", E.validate_buy(1000.0, W.get_item("armor_helmet"), "T", true)["new_cash"], 0.0)

	# Every category from spec Section 3 has at least one item
	for cat in ["pistols", "heavies", "smgs", "rifles", "shotguns", "snipers", "grenades", "armor", "defuse_kit"]:
		var found := false
		for id in W.ITEMS:
			if W.ITEMS[id]["category"] == cat:
				found = true
		h.check("buy menu has category " + cat, found)

	print("RESULT economy: %d passed, %d failed" % [h.passed, h.failed])
	quit(0 if h.failed == 0 else 1)
