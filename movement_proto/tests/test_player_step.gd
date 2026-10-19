extends SceneTree
## Smoke test for the playable sim:  godot --headless --script res://tests/test_player_step.gd

var failed := 0


func _expect(name: String, ok: bool, detail: String) -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", name, detail])
	if not ok:
		failed += 1


func _init() -> void:
	var p := PlayerSim.new()
	# Standing jump: 86 air ticks at 128 tick (matches the reference airtime).
	var n := 0
	p.tick(Vector2.ZERO, true)
	n += 1
	while not p.on_ground:
		p.tick(Vector2.ZERO, false)
		n += 1
	_expect("standing jump airtime", n == 86, "%d ticks (want 86)" % n)

	# Run forward 3 s from rest: speed settles at 250.
	p = PlayerSim.new()
	for i in 384:
		p.tick(Vector2(0.0, -1.0), false)
	_expect("ground accel tops out at 250", absf(p.speed() - 250.0) < 0.01, "%.3f u/s" % p.speed())

	# Release keys: friction stops from 250 within ~0.5 s.
	for i in 128:
		p.tick(Vector2.ZERO, false)
	_expect("friction stops the player", p.speed() == 0.0, "%.3f u/s" % p.speed())

	# Ideal air strafe from 250: gain per tick matches the reference at 128 tick.
	p = PlayerSim.new()
	p.velocity = Vector2(250.0, 0.0)
	p.on_ground = false
	p.vz = 268.0
	p.position.y = 1.0
	var dd := 30.0 - 10.0 * 250.0 / 128.0
	var w := Vector2(dd / 250.0, sqrt(1.0 - (dd / 250.0) * (dd / 250.0)))
	p.tick(w, false)
	_expect("air strafe gain", absf(p.speed() - 251.5758) < 0.01, "%.4f u/s (want 251.5758)" % p.speed())

	# Phase 3: running while the stamina timer is full tops out near 0.75 x 250.
	p = PlayerSim.new()
	p.stamina_ms = Movement.STAMINA_MS
	for i in 20:
		p.tick(Vector2(0.0, -1.0), false)
	_expect("stamina slows ground speed", p.speed() < 200.0, "%.3f u/s after 20 ticks (reference 194.92)" % p.speed())

	print("\nplayer step: %s" % ("OK" if failed == 0 else "FAILED"))
	quit(1 if failed > 0 else 0)
