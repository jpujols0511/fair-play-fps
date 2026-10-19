class_name Waypoints
extends RefCounted
## Route data for the bot driver (Phase 8). Game frame (x, z); one waypoint = {x, z, arrive_radius, jump, duck, wait_ticks}.
## A route = {name, world ("default" | "crouch"), spawn [x, z], loop, waypoints}. Built-in routes live in server/bots/routes/*.json.

const ROUTE_DIR := "res://server/bots/routes/"
const NAMES := ["step_loop", "box_circuit", "jump_onto_step", "crouch_overhang", "cover_peek"]
const DEFAULT_ARRIVE_RADIUS := 16.0


static func load_route(route_name: String) -> Dictionary:
	var f := FileAccess.open(ROUTE_DIR + route_name + ".json", FileAccess.READ)
	if f == null:
		return {}
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return normalize(parsed)


## Fills defaults so the driver never has to check for missing keys.
static func normalize(raw: Dictionary) -> Dictionary:
	var wps: Array = []
	for w in raw.get("waypoints", []):
		wps.append({
			"x": float(w["x"]),
			"z": float(w["z"]),
			"arrive_radius": float(w.get("arrive_radius", DEFAULT_ARRIVE_RADIUS)),
			"jump": bool(w.get("jump", false)),
			"duck": bool(w.get("duck", false)),
			"wait_ticks": int(w.get("wait_ticks", 0)),
		})
	var spawn: Array = raw.get("spawn", [0.0, 0.0])
	return {
		"name": String(raw.get("name", "")),
		"world": String(raw.get("world", "default")),
		"spawn": [float(spawn[0]), float(spawn[1])],
		"loop": bool(raw.get("loop", true)),
		"waypoints": wps,
	}


static func world_for(route: Dictionary) -> Array:
	return Movement.crouch_test_world() if route.get("world", "default") == "crouch" else Movement.default_world()
