class_name BotDriver
extends RefCounted
## Scripted-waypoint bot (Phase 8, specs/bot_spec_v0.0_skeleton.md rules 2, 3, 4, 8). One command per tick, fed to the
## SAME input queue as network INPUT through ClientSlot.enqueue_local(); nothing here moves a body.
## It reads only its OWN slot's PlayerState (a real client gets that in full) and its route. It holds no reference to
## the server or to other slots (test_bots.gd checks the property list).
## Deterministic: no randomness. Yaw convention as in Bots._aim (forward is -z at yaw 0).

var slot: ClientSlot
var route: Dictionary
var index := 0
var seq := 1
var wait_left := 0
var duck_held := false
var finished := false
var reached: PackedInt32Array = PackedInt32Array()      # waypoint index at each arrival (tests)
var arrived_total := 0
var last_yaw := 0.0
var commands_sent := 0
var record := false                                      # tests: keep every command made
var cmd_log: Array = []


func _init(p_slot: ClientSlot, p_route: Dictionary) -> void:
	slot = p_slot
	route = p_route
	var sp: Array = route["spawn"]
	# spawn placement is a server-side round-start action, the same as for a human slot; never a command
	slot.state.pos_x = sp[0]
	slot.state.pos_z = sp[1]


## Builds this tick's command from own state + route (no side effects on the slot).
func make_command(tick: int) -> InputCmd:
	var wps: Array = route["waypoints"]
	var p := slot.state
	var buttons := 0
	var jump_now := false
	if wps.is_empty() or finished:
		return _cmd(tick, _duck_bit())
	if wait_left > 0:
		wait_left -= 1
		return _cmd(tick, _duck_bit())
	var w: Dictionary = wps[index]
	var dx: float = w["x"] - p.pos_x
	var dz: float = w["z"] - p.pos_z
	if sqrt(dx * dx + dz * dz) <= w["arrive_radius"]:
		reached.append(index)
		arrived_total += 1
		duck_held = w["duck"]
		jump_now = w["jump"]
		wait_left = w["wait_ticks"]
		if index + 1 >= wps.size():
			if route["loop"]:
				index = 0
			else:
				finished = true
		else:
			index += 1
		if wait_left > 0 or finished:
			return _cmd(tick, _duck_bit() | (InputCmd.BTN_JUMP if jump_now else 0))
		w = wps[index]
		dx = w["x"] - p.pos_x
		dz = w["z"] - p.pos_z
	last_yaw = atan2(-dx, -dz)
	buttons = InputCmd.BTN_FORWARD | _duck_bit() | (InputCmd.BTN_JUMP if jump_now else 0)
	return _cmd(tick, buttons)


## Step 1 of the server tick: make this tick's command and enqueue it like a datagram's commands.
func drive(tick: int, evidence: EvidenceSink) -> void:
	slot.enqueue_local(make_command(tick), tick, evidence)


func _duck_bit() -> int:
	return InputCmd.BTN_DUCK if duck_held else 0


func _cmd(tick: int, buttons: int) -> InputCmd:
	var c := InputCmd.make(seq, tick, buttons, InputCmd.quantize_yaw(last_yaw), InputCmd.quantize_pitch(0.0))
	c.view_tick = float(tick)                    # no interpolation delay for a bot: it "saw" the current tick
	seq += 1
	commands_sent += 1
	if record:
		cmd_log.append(c)
	return c
