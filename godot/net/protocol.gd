extends RefCounted
## Wire format for the spike. Deliberately tiny and strict.
##
## Everything travels inside a DTLS session (encrypted and integrity-protected,
## invariant 2). The first packet a client sends is HELLO: player id plus the
## access token issued for that player. The server binds the identity to that
## DTLS session only if the token matches.
##
## After HELLO, client -> server carries intent only: sequence, two move axes,
## yaw, fire. There is no field for position, health, damage, ammunition or
## score, so a client cannot claim them (invariant 1). Any packet whose length
## or fields do not match exactly is rejected as malformed.

const VERSION := 2
const KIND_INTENT := 1
const KIND_SNAPSHOT := 2
const KIND_HELLO := 3
const MAX_ID := 32
const TOKEN_LEN := 64
const SERVER_NAME := "fairplay.local"


static func encode_hello(player_id: String, token: String) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(VERSION)
	b.put_u8(KIND_HELLO)
	var id_bytes := player_id.to_ascii_buffer()
	b.put_u8(id_bytes.size())
	b.put_data(id_bytes)
	var token_bytes := token.to_ascii_buffer()
	b.put_u8(token_bytes.size())
	b.put_data(token_bytes)
	return b.data_array


static func decode_hello(packet: PackedByteArray) -> Dictionary:
	if packet.size() < 4 or packet[0] != VERSION or packet[1] != KIND_HELLO:
		return {}
	var id_len: int = packet[2]
	if id_len < 1 or id_len > MAX_ID or packet.size() != 3 + id_len + 1 + TOKEN_LEN:
		return {}
	if packet[3 + id_len] != TOKEN_LEN:
		return {}
	var player_id := packet.slice(3, 3 + id_len).get_string_from_ascii()
	var token := packet.slice(4 + id_len).get_string_from_ascii()
	if player_id.length() != id_len or not _valid_id(player_id) or token.length() != TOKEN_LEN:
		return {}
	return {"player_id": player_id, "token": token}


## Compares every byte so the time taken does not reveal how much matched.
static func tokens_equal(a: String, b: String) -> bool:
	if a.length() != b.length():
		return false
	var diff := 0
	for i in a.length():
		diff |= a.unicode_at(i) ^ b.unicode_at(i)
	return diff == 0


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


## Server -> client: the player's own confirmed state after a kernel tick.
## Carries every field the client needs to replay its unconfirmed intents.
const SNAPSHOT_KEYS := ["tick", "x", "y", "velocity_x", "velocity_y", "yaw_millidegrees",
	"health", "ammunition", "next_fire_tick", "last_sequence", "remainder_x", "remainder_y"]


static func encode_snapshot(tick: int, state: Dictionary) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(VERSION)
	b.put_u8(KIND_SNAPSHOT)
	b.put_32(tick)
	for key in SNAPSHOT_KEYS.slice(1):
		b.put_32(state[key])
	return b.data_array


static func decode_snapshot(packet: PackedByteArray) -> Dictionary:
	if packet.size() != 2 + SNAPSHOT_KEYS.size() * 4 or packet[0] != VERSION or packet[1] != KIND_SNAPSHOT:
		return {}
	var b := StreamPeerBuffer.new()
	b.data_array = packet
	b.seek(2)
	var out := {}
	for key in SNAPSHOT_KEYS:
		out[key] = b.get_32()
	return out


static func _valid_id(player_id: String) -> bool:
	for c in player_id:
		if not (c >= "a" and c <= "z") and not (c >= "0" and c <= "9") and c != "_":
			return false
	return true
