extends SceneTree
## Runs the same honest and controlled-attacker command streams as
## prototype/fairplay_sim.py and prints one JSON line per scenario.
## tests/test_godot_spike.py compares the digests with the Python oracle.
##
## godot --headless --path godot --script res://tests/kernel_parity.gd

const Kernel = preload("res://kernel/fairplay_kernel.gd")


func _initialize() -> void:
	for tick_rate in Kernel.SUPPORTED_TICK_RATES:
		_report("honest_%d" % tick_rate, ["honest"],
			_honest(tick_rate, tick_rate), tick_rate)
		_report("attacker_%d" % tick_rate, ["attacker"],
			_attacker(tick_rate), tick_rate)
		_report("mixed_%d" % tick_rate, ["attacker", "honest"],
			_mixed(tick_rate), tick_rate)
	quit(0)


func _report(scenario: String, ids: Array, ticks: Array, tick_rate: int) -> void:
	var kernel = Kernel.new(ids, tick_rate)
	for commands in ticks:
		var keys: Array = commands.keys()
		keys.sort()
		for player_id in keys:
			kernel.submit(player_id, commands[player_id])
		kernel.step()
	print(JSON.stringify({"scenario": scenario, "digest": kernel.digest(),
		"ticks": kernel.tick, "tick_rate": kernel.tick_rate}, "", true))


func _honest(n: int, tick_rate: int, player_id: String = "honest") -> Array:
	var out := []
	var fire_interval: int = Kernel.FIRE_INTERVAL_TICKS * tick_rate / Kernel.TICK_RATE
	for t in n:
		out.append({player_id: Kernel.command(t, Kernel.INPUT_SCALE if t < n / 2 else 0, 0, 90000,
			t % fire_interval == 0)})
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
