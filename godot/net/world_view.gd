extends RefCounted
## Other players as the server showed them, for drawing and aiming.
##
## World packets arrive every tick. The client draws other players `delay`
## ticks in the past, so it nearly always has a frame for that tick even when
## UDP drops or delays one, and can interpolate between frames for smooth
## drawing. It tells the server which tick it drew (`view_tick` in each
## intent), so lag compensation rewinds to exactly what the player saw, never
## more than MAX_REWIND_TICKS (decision 0003).

const KEEP_TICKS := 64

var delay: int
var frames := {}  # tick -> {player_id: {x, y, yaw_millidegrees, health}}
var newest := -1


func _init(p_delay: int) -> void:
	delay = maxi(0, p_delay)


func add(world: Dictionary) -> void:
	frames[world["tick"]] = world["players"]
	newest = maxi(newest, world["tick"])
	for tick in frames.keys():
		if tick < newest - KEEP_TICKS:
			frames.erase(tick)


## The frame drawn now: the newest one at or before `newest - delay`.
## Returns {"tick": -1, "players": {}} before any frame has arrived.
func view() -> Dictionary:
	var best := -1
	for tick in frames:
		if tick <= newest - delay and tick > best:
			best = tick
	if best < 0:
		return {"tick": -1, "players": {}}
	return {"tick": best, "players": frames[best]}


## Positions at a fractional tick (thousandths), interpolated linearly in
## integers between the two surrounding frames, for smooth drawing. A player
## missing from either frame is drawn where the other frame has it.
func sample(millitick: int) -> Dictionary:
	var before := -1
	var after := -1
	for tick in frames:
		if tick * 1000 <= millitick and tick > before:
			before = tick
		if tick * 1000 >= millitick and (after < 0 or tick < after):
			after = tick
	if before < 0 and after < 0:
		return {}
	if before < 0 or after < 0 or before == after:
		return frames[maxi(before, after)].duplicate(true)
	var fraction: int = (millitick - before * 1000) * 1000 / ((after - before) * 1000)
	var out := {}
	for player_id in frames[before]:
		var a: Dictionary = frames[before][player_id]
		var b: Dictionary = frames[after].get(player_id, a)
		out[player_id] = {
			"x": a["x"] + (b["x"] - a["x"]) * fraction / 1000,
			"y": a["y"] + (b["y"] - a["y"]) * fraction / 1000,
			"yaw_millidegrees": b["yaw_millidegrees"], "health": b["health"],
		}
	return out
