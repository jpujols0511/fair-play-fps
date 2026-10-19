class_name InputCmd
extends RefCounted
## One input command as it travels on the wire. Angles are quantized to 16 bits, so the
## client and the server both step on exactly the same numbers.

const BTN_FORWARD := 1
const BTN_BACK := 2
const BTN_LEFT := 4
const BTN_RIGHT := 8
const BTN_JUMP := 16
const BTN_DUCK := 32
## Reserved bit for shooting (Phase 7): the server tick calls the shot processor (seam D2) for commands that carry it.
## Nothing in movement uses it. The client sets it on left mouse button.
const BTN_ATTACK := 64

const ANGLE_STEPS := 65536.0
const TICK_HZ := 128

var seq := 0
var tick := 0
var buttons := 0
var yaw_q := 0
var pitch_q := 0
## Logged and checked by the server; the server never uses it to time a step.
var tick_hz := TICK_HZ
## The fractional server tick the client was drawing remote players at when it made this command
## (NetClient.get_render_tick(), seam D8). Movement.step ignores it; the server uses it only as the
## CLAIMED view time for hit registration (Devin's +-1-tick rule).
var view_tick := 0.0


static func quantize_yaw(rad: float) -> int:
	return int(roundf(fposmod(rad, TAU) / TAU * ANGLE_STEPS)) & 0xFFFF


static func dequantize_yaw(q: int) -> float:
	return float(q) * (TAU / ANGLE_STEPS)


static func quantize_pitch(rad: float) -> int:
	var p := clampf(rad, -PI / 2.0, PI / 2.0)
	return int(roundf((p + PI / 2.0) / PI * (ANGLE_STEPS - 1.0)))


static func dequantize_pitch(q: int) -> float:
	return float(q) / (ANGLE_STEPS - 1.0) * PI - PI / 2.0


static func make(p_seq: int, p_tick: int, p_buttons: int, p_yaw_q: int, p_pitch_q: int) -> InputCmd:
	var c := InputCmd.new()
	c.seq = p_seq
	c.tick = p_tick
	c.buttons = p_buttons
	c.yaw_q = p_yaw_q
	c.pitch_q = p_pitch_q
	return c


## Same input, new sequence number: how the server fills a command that never arrived.
func repeated_as(p_seq: int) -> InputCmd:
	# a filled-in command never fires: ATTACK is cleared (a lost command must not shoot twice)
	var c := InputCmd.make(p_seq, tick, buttons & ~BTN_ATTACK, yaw_q, pitch_q)
	c.tick_hz = tick_hz
	c.view_tick = view_tick
	return c
