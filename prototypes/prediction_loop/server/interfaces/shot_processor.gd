class_name ShotProcessor
extends RefCounted
## Seam D2: called at server tick step 5 for each command executed this tick that carries BTN_ATTACK (64).
## Devin's `hitreg/hitreg.gd` implements `process_shot`. This is the NULL stub: it returns {"stub": true} and counts.
## ctx keys (spec frame floats, never Vector3 for math): now (int tick), tick_rate (float), shooter_slot, eye_x/eye_y/eye_z
## (from the shooter's server state AFTER this command, eye from eye_height), view_pitch_q, view_yaw_q (the command's
## InputCmd values, unconverted) AND view_pitch_deg, view_yaw_deg (spec frame via Frame), cmd_seq, claimed_view_tick
## (float, from the command), rtt_ms (float, server-measured), teams (Array of int per slot), sent_mask_for (Callable
## to seam D4). NO seed, NO spread, NO client-claimed hit or position: the spread seed is picked by the server inside
## her module at fire time (crosshair note (g)).

var calls := 0


func process_shot(_ctx: Dictionary) -> Dictionary:
	calls += 1
	return {"stub": true}


class Recording extends ShotProcessor:
	var contexts: Array = []
	var call_ticks: Array = []

	func process_shot(ctx: Dictionary) -> Dictionary:
		calls += 1
		contexts.append(ctx)
		call_ticks.append(ctx["now"])
		return {"stub": true}
