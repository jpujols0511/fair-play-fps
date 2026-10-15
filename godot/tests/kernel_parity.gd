extends SceneTree
## Runs the same honest and controlled-attacker command streams as
## prototype/fairplay_sim.py and prints one JSON line per scenario.
## tests/test_godot_spike.py compares the digests with the Python oracle.
##
## godot --headless --path godot --script res://tests/kernel_parity.gd

const Kernel = preload("res://kernel/fairplay_kernel.gd")


func _initialize() -> void:
	_report("honest", ["honest"], _honest(32))
	_report("attacker", ["attacker"], _attacker(32))
	_report("mixed", ["attacker", "honest"], _mixed(48))
	_report("combat", ["a", "b", "c"], _combat(96))
	quit(0)


func _report(scenario: String, ids: Array, ticks: Array) -> void:
	var kernel = Kernel.new(ids)
	for commands in ticks:
		var keys: Array = commands.keys()
		keys.sort()
		for player_id in keys:
			kernel.submit(player_id, commands[player_id])
		kernel.step()
	print(JSON.stringify({"scenario": scenario, "digest": kernel.digest(), "ticks": kernel.tick}, "", true))


func _honest(n: int, player_id: String = "honest") -> Array:
	var out := []
	for t in n:
		out.append({player_id: Kernel.command(t, Kernel.INPUT_SCALE if t < n / 2 else 0, 0, 90000,
			t % Kernel.FIRE_INTERVAL_TICKS == 0)})
	return out


func _attacker(n: int, player_id: String = "attacker") -> Array:
	var out := []
	for t in n:
		out.append({player_id: Kernel.command(t, Kernel.INPUT_SCALE * 5, -Kernel.INPUT_SCALE * 4, 450000, true)})
	return out


## Both players, negative yaw, a duplicate and a stale sequence: exercises the
## floor-division, posmod and evidence paths the single-player scenarios miss.
func _mixed(n: int) -> Array:
	var out := []
	for t in n:
		var honest := Kernel.command(t, -700 if t % 3 else 0, 300, -45000 * t, t % 9 == 0)
		var attacker := Kernel.command(t if t % 10 else t - 2, -6000, 2500, -400000, true)
		out.append({"honest": honest, "attacker": attacker})
	return out


## Three players shooting at each other: hits, rewinds, a view from the
## future, rewinds past the limit, eliminations and every yaw quadrant.
func _combat(n: int) -> Array:
	var out := []
	for t in n:
		var a_view := t - 5
		if t % 24 == 8:
			a_view = t + 3
		elif t % 16 == 8:
			a_view = t - 40
		var a := Kernel.command(t, 0, 0, 0, t % 8 == 0, a_view)
		var b := Kernel.command(t, 1000 if t < 20 else 0, 0 if t < 20 else 1000, 180000, t % 8 == 4, t - 2)
		var c := Kernel.command(t if t % 7 else t - 1, -700, -700, -135000 + 1500 * t, t % 10 == 0, t - 1)
		out.append({"a": a, "b": b, "c": c})
	return out
