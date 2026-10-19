class_name RoundHooks
extends RefCounted
## Round loop seam (not mine to build: see specs/round_loop_spec_v0.1.md, for whoever builds the round loop).
## NULL stub: movement always allowed, nothing happens on a tick.

## Server tick step 2: may this slot move at tick T? (freeze time: false). Commands are still consumed.
func allow_movement(_slot: int, _tick: int) -> bool:
	return true


## Server tick step 3, once per tick, after all commands have run.
func on_tick(_tick: int) -> void:
	pass


## A keyframe for the visibility evidence is written when a round starts.
func on_round_start(_tick: int) -> void:
	pass


class Recording extends RoundHooks:
	var tick_calls: Array = []
	var movement_checks := 0
	var allow := true

	func allow_movement(_slot: int, _tick: int) -> bool:
		movement_checks += 1
		return allow

	func on_tick(tick: int) -> void:
		tick_calls.append(tick)
