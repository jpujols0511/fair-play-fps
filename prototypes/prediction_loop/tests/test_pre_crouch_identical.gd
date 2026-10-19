extends SceneTree
## Phase 1: with duck never pressed, every bot reproduces the pre-crouch player states
## bit for bit (tests/golden/pre_crouch_states.txt, captured before crouch existed).
##   godot --headless --script res://tests/test_pre_crouch_identical.gd

func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1: ", Engine.get_version_info()["string"])
		quit(1)
		return
	var f := FileAccess.open("res://tests/golden/pre_crouch_states.txt", FileAccess.READ)
	var want: Dictionary = {}
	for line in f.get_as_text().strip_edges().split("\n"):
		var p := line.split(" ")
		want["%s %s" % [p[0], p[1]]] = p[2]
	var passed := 0
	var failed := 0
	var per_bot := {}
	for kind in Bots.KINDS + ["mixed"]:
		var s := Session.new(1, 0.0, 0.0, false, false, false)
		var ok := 0
		var bad := 0
		for t in 4001:
			var i := Bots.input(kind, t, s.client.predicted)
			s.tick_once(i[0], i[1], i[2])
			if t % 250 == 0:
				if s.client.predicted.hex().substr(0, 160) == want["%s %d" % [kind, t]]:
					ok += 1
				else:
					bad += 1
		per_bot[kind] = [ok, bad]
		if bad == 0:
			passed += 1
		else:
			failed += 1
		print("%s  %-7s %d/%d sample ticks bit-identical" % ["PASS" if bad == 0 else "FAIL", kind, ok, ok + bad])
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)
