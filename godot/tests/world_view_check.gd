extends SceneTree
## Checks the world packet format and the client's drawing buffer.
## tests/test_godot_spike.py reads the JSON line.
##
## godot --headless --path godot --script res://tests/world_view_check.gd

const Protocol = preload("res://net/protocol.gd")
const WorldView = preload("res://net/world_view.gd")


func _initialize() -> void:
	var a := {"x": -5, "y": 7, "yaw_millidegrees": 90000, "health": 75}
	var two := Protocol.encode_world(12, {"b": a, "c": a})
	var dup := Protocol.encode_world(12, {"b": a})
	dup[6] = 2  # claims two players, then repeats the first
	dup.append_array(dup.slice(7))
	var oversized := Protocol.encode_world(1, {})
	oversized[6] = Protocol.MAX_WORLD_PLAYERS + 1
	var view = WorldView.new(1)
	view.add({"tick": 10, "players": {"b": {"x": 0, "y": 0, "yaw_millidegrees": 0, "health": 100}}})
	view.add({"tick": 12, "players": {"b": {"x": 200, "y": -100, "yaw_millidegrees": 0, "health": 50}}})
	print(JSON.stringify({
		"empty": Protocol.decode_world(Protocol.encode_world(3, {})),
		"two": Protocol.decode_world(two),
		"truncated": Protocol.decode_world(two.slice(0, two.size() - 1)),
		"extra": Protocol.decode_world(two + PackedByteArray([0])),
		"duplicate": Protocol.decode_world(dup),
		"oversized": Protocol.decode_world(oversized),
		"snapshot_is_not_world": Protocol.decode_world(Protocol.encode_snapshot(1, {
			"x": 0, "y": 0, "velocity_x": 0, "velocity_y": 0, "yaw_millidegrees": 0, "health": 100,
			"ammunition": 1, "next_fire_tick": 0, "last_sequence": 0})),
		"view_tick": view.view()["tick"],
		"sample_11": view.sample(11000),
		"sample_11_5": view.sample(11500),
	}, "", true))
	quit(0)
