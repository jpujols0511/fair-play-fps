extends RefCounted
## Per-slot bot view (bot_spec_v0.1 §0 rule 4). Follows: CD-r3.
## Holds ONLY what the server would send this slot: own full state, teammates (always sent),
## and enemies that passed visibility culling for this slot. The brain reads nothing else.

# Own state (a real client receives its own state in full).
var slot: int = -1
var team: String = ""
var alive: bool = true
var health: float = 100.0          # 0.0 .. 100.0
var max_health: float = 100.0
var mag: float = 30.0              # rounds in the magazine (float, house rule)
var mag_size: float = 30.0
var reserve: float = 90.0
var x: float = 0.0
var y: float = 0.0
var z: float = 0.0
var round_live: bool = true        # round phase LIVE or PLANTED (not WARMUP/FREEZE/ROUND_END)

const _Self = preload("bot_view.gd")   # relative to this script, no res:// path

# Teammates: Array of {slot, x, y, z, alive}. Always sent.
var teammates: Array = []
# Enemies in THIS slot's culled snapshot only: Array of {slot, x, y, z, duck}.
# `duck` = remote duck fraction 0.0..1.0 as the snapshot sends it (u8, f x 255.0; CURRENT_DECISIONS §crouch).
var enemies: Array = []


## Build a view the way the snapshot encoder would for `self_slot`: enemies only if their bit
## is set in that slot's sent_mask (bit = enemy slot). `players` is a server-side list of
## {slot, team, alive, health, mag, mag_size, reserve, x, y, z, duck_fraction (optional, default 0.0)}. This function is the ONLY
## place that sees unsent players, and it drops them.
static func from_server(players: Array, self_slot: int, sent_mask: int, round_live: bool = true):
	var v = _Self.new()
	v.round_live = round_live
	var me: Dictionary = {}
	for p in players:
		if int(p["slot"]) == self_slot:
			me = p
	if me.is_empty():
		return v
	v.slot = self_slot
	v.team = str(me["team"])
	v.alive = bool(me["alive"])
	v.health = float(me["health"])
	v.mag = float(me["mag"])
	v.mag_size = float(me.get("mag_size", 30.0))
	v.reserve = float(me["reserve"])
	v.x = float(me["x"]); v.y = float(me["y"]); v.z = float(me["z"])
	for p in players:
		var s := int(p["slot"])
		if s == self_slot:
			continue
		if str(p["team"]) == v.team:
			v.teammates.append({"slot": s, "x": float(p["x"]), "y": float(p["y"]), "z": float(p["z"]), "alive": bool(p["alive"])})
		elif bool(p["alive"]) and (sent_mask >> s) & 1 == 1:
			v.enemies.append({"slot": s, "x": float(p["x"]), "y": float(p["y"]), "z": float(p["z"]),
				"duck": quantize_duck(float(p.get("duck_fraction", 0.0)))})
	return v


## Duck fraction exactly as the snapshot carries it: u8 = round(clamp(f) x 255.0), decoded / 255.0.
static func quantize_duck(f: float) -> float:
	return roundf(clampf(f, 0.0, 1.0) * 255.0) / 255.0
