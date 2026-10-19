class_name LagCompSink
extends RefCounted
## Seam D1: the server pushes one sample per slot per tick (server tick step 4: after ALL movement of the tick,
## before any shot). Spec frame (z up, yaw in degrees, 0 = +x). Devin's `hitreg/lagcomp_history.gd` implements
## the same method. This file is the NULL stub; Recording keeps the last 26 samples per slot for tests (her ring
## holds the current tick plus 25 back).

func push_sample(_slot: int, _tick: int, _x: float, _y: float, _z: float, _yaw_deg: float, _stance: int, _alive: bool, _duck_fraction: float = 0.0) -> void:
	pass


class Recording extends LagCompSink:
	const KEEP := 26
	var samples: Dictionary = {}          # slot -> Array of {tick, x, y, z, yaw_deg, stance, alive}, oldest first
	var calls := 0
	var call_ticks: Array = []            # tick of every call, in order (order tests)

	func push_sample(slot: int, tick: int, x: float, y: float, z: float, yaw_deg: float, stance: int, alive: bool, duck_fraction: float = 0.0) -> void:
		calls += 1
		call_ticks.append(tick)
		var a: Array = samples.get(slot, [])
		a.append({"tick": tick, "x": x, "y": y, "z": z, "yaw_deg": yaw_deg, "stance": stance, "alive": alive, "duck_fraction": duck_fraction})
		if a.size() > KEEP:
			a.pop_front()
		samples[slot] = a
