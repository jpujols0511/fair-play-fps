extends RefCounted
## Wire format for the spike. Deliberately tiny and strict.
##
## Client -> server carries intent only: sequence, two move axes, yaw, fire.
## There is no field for position, health, damage, ammunition or score, so a
## client cannot claim them (invariant 1). Any packet whose length or fields
## do not match exactly is rejected as malformed.
##
## Not yet encrypted or authenticated (invariant 2 is open; see godot/README.md).

const VERSION := 1
const KIND_INTENT := 1
const KIND_SNAPSHOT := 2
const MAX_ID := 32


static func encode_intent(player_id: String, cmd: Dictionary) -> PackedByteArray:
	var id_bytes := player_id.to_ascii_buffer()
	var b := StreamPeerBuffer.new()
	b.put_u8(VERSION)
	b.put_u8(KIND_INTENT)
	b.put_u8(id_bytes.size())
	b.put_data(id_bytes)
	b.put_32(cmd["sequence"])
	b.put_32(cmd["move_x"])
	b.put_32(cmd["move_y"])
	b.put_32(cmd["yaw_millidegrees"])
	b.put_u8(1 if cmd["fire"] else 0)
	return b.data_array


## Returns {} for anything malformed.
static func decode_intent(packet: PackedByteArray) -> Dictionary:
	if packet.size() < 3 or packet[0] != VERSION or packet[1] != KIND_INTENT:
		return {}
	var id_len: int = packet[2]
	if id_len < 1 or id_len > MAX_ID or packet.size() != 3 + id_len + 17:
		return {}
	var player_id := packet.slice(3, 3 + id_len).get_string_from_ascii()
	if player_id.length() != id_len or not _valid_id(player_id):
		return {}
	var b := StreamPeerBuffer.new()
	b.data_array = packet
	b.seek(3 + id_len)
	var cmd := {
		"sequence": b.get_32(), "move_x": b.get_32(), "move_y": b.get_32(),
		"yaw_millidegrees": b.get_32(),
	}
	var fire_byte: int = b.get_u8()
	if fire_byte > 1:
		return {}
	cmd["fire"] = fire_byte == 1
	return {"player_id": player_id, "command": cmd}


static func encode_snapshot(tick: int, state: Dictionary) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(VERSION)
	b.put_u8(KIND_SNAPSHOT)
	for value in [tick, state["x"], state["y"], state["velocity_x"], state["velocity_y"],
			state["ammunition"], state["last_sequence"]]:
		b.put_32(value)
	return b.data_array


static func decode_snapshot(packet: PackedByteArray) -> Dictionary:
	if packet.size() != 2 + 7 * 4 or packet[0] != VERSION or packet[1] != KIND_SNAPSHOT:
		return {}
	var b := StreamPeerBuffer.new()
	b.data_array = packet
	b.seek(2)
	var keys := ["tick", "x", "y", "velocity_x", "velocity_y", "ammunition", "last_sequence"]
	var out := {}
	for key in keys:
		out[key] = b.get_32()
	return out


static func _valid_id(player_id: String) -> bool:
	for c in player_id:
		if not (c >= "a" and c <= "z") and not (c >= "0" and c <= "9") and c != "_":
			return false
	return true
