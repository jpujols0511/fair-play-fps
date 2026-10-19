class_name WeaponStateProvider
extends RefCounted
## Seam D3: the own-player HUD block of a snapshot (accuracy, punch). Devin's `weapons/recoil.gd`
## (`spread_for_next_shot` + kick) implements `hud_fields` later.
## STUB until then: AK first-shot spread by move state from the recoil spec (stand and crouch 0.0055,
## run 0.0540, air 0.1200), punch 0.0. Labelled STUB here and in the README.

## Returns {"accuracy": float, "punch_pitch": float (deg, + = up), "punch_yaw": float (deg)}.
func hud_fields(_slot: int, move_state: int) -> Dictionary:
	var acc := 0.0055
	if move_state == 3:
		acc = 0.0540
	elif move_state == 2:
		acc = 0.1200
	return {"accuracy": acc, "punch_pitch": 0.0, "punch_yaw": 0.0}
