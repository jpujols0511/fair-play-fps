class_name Bots
extends RefCounted
## Scripted inputs for the headless runner. A bot may look at the client's own predicted
## state (never at the server) so it can aim at the wall and the step. All deterministic.

const KINDS := ["run", "strafe", "bhop", "turns", "wall", "step"]   # "mixed" cycles these (unchanged: goldens depend on it)
const EXTRA := ["crouch"]                                            # added in Phase 1
const F := InputCmd.BTN_FORWARD
const B := InputCmd.BTN_BACK
const L := InputCmd.BTN_LEFT
const R := InputCmd.BTN_RIGHT
const J := InputCmd.BTN_JUMP
const D := InputCmd.BTN_DUCK


static func _aim(p: PlayerState, tx: float, tz: float) -> float:
	return atan2(-(tx - p.pos_x), -(tz - p.pos_z))


## Returns [buttons, yaw_q, pitch_q].
static func input(kind: String, tick: int, p: PlayerState) -> Array:
	var buttons := 0
	var yaw := 0.0
	var t := float(tick)
	match kind:
		"run":
			buttons = F
		"strafe":
			buttons = F | (R if cos(t * 0.05) > 0.0 else L)
			yaw = 0.9 * sin(t * 0.05)
		"bhop":
			# Ideal strafe: hold D and aim so the wish direction sits at the best angle to the velocity.
			var jb := J if tick % 2 == 0 else 0
			var sp := p.speed()
			if tick < 40 or sp < 200.0:
				buttons = F | jb
			else:
				var dd := maxf(Movement.AIR_CAP - Movement.AIR_ACCEL * Movement.MAX_SPEED / Movement.TICK_RATE, 0.0)
				var th := acos(clampf(dd / sp, -1.0, 1.0))
				yaw = -(atan2(p.vel_z, p.vel_x) + th)
				buttons = R | jb
		"turns":
			buttons = F | (J if tick % 70 == 0 else 0)
			yaw = float(tick / 48) * (PI / 2.0)
		"wall":
			var targets := [[332.0, 0.0], [332.0, 100.0], [0.0, 40.0]]
			var tg: Array = targets[(tick / 300) % 3]
			yaw = _aim(p, tg[0], tg[1])
			buttons = F | (J if tick % 90 == 0 else 0)
		"step":
			var targets2 := [[-152.0, 0.0], [-400.0, 0.0], [0.0, 60.0], [-152.0, 90.0]]
			var tg2: Array = targets2[(tick / 250) % 4]
			yaw = _aim(p, tg2[0], tg2[1])
			buttons = F | (J if tick % 120 == 0 else 0)
		"crouch":
			# duck-walks to the step, then a crouch-jump: jump, then duck in the air
			var targets3 := [[-152.0, 0.0], [-400.0, 0.0], [0.0, 60.0]]
			var tg3: Array = targets3[(tick / 250) % 3]
			yaw = _aim(p, tg3[0], tg3[1])
			buttons = F
			var ph := tick % 300
			if ph < 150:
				buttons |= D
			elif ph == 160:
				buttons |= J
			elif ph >= 162 and ph < 200:
				buttons |= D
		"peekview":
			# Phase 8 integration: walk to (400, -300) in the crouch world and watch the cover_peek bot at (740, 0)
			var dxv := 400.0 - p.pos_x
			var dzv := -300.0 - p.pos_z
			if dxv * dxv + dzv * dzv > 64.0:
				yaw = _aim(p, 400.0, -300.0)
				buttons = F
			else:
				yaw = _aim(p, 740.0, 0.0)
		"mixed":
			return input(KINDS[(tick / 1500) % KINDS.size()], tick, p)
		_:
			pass
	return [buttons, InputCmd.quantize_yaw(yaw), InputCmd.quantize_pitch(0.0)]
