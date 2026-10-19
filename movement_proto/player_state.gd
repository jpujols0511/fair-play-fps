class_name PlayerState
extends RefCounted
## Everything movement.gd needs to step one player. Plain float64 fields (not Vector3,
## which is float32) so client and server can be compared bit for bit.

var pos_x := 0.0
var pos_y := 0.0      # feet height, up is +
var pos_z := 0.0
var vel_x := 0.0
var vel_z := 0.0
var vel_up := 0.0
var on_ground := true
var stamina_ms := 0.0
var prev_buttons := 0     # for "fresh press only" jumping
var teleport_gen := 0     # bumped by the server whenever it moves the player by force
var ducked := false       # hull is 36.0 high (K2); eye 32.0
var duck_ticks := 0       # integer tick counter of the ground duck transition (K4)
var in_duck := false      # ground transition in progress: hull still 72.0, eye sliding (K3)


func copy_from(o: PlayerState) -> void:
	pos_x = o.pos_x
	pos_y = o.pos_y
	pos_z = o.pos_z
	vel_x = o.vel_x
	vel_z = o.vel_z
	vel_up = o.vel_up
	on_ground = o.on_ground
	stamina_ms = o.stamina_ms
	prev_buttons = o.prev_buttons
	teleport_gen = o.teleport_gen
	ducked = o.ducked
	duck_ticks = o.duck_ticks
	in_duck = o.in_duck


func duplicate_state() -> PlayerState:
	var s := PlayerState.new()
	s.copy_from(self)
	return s


## Exact (bit-for-bit) equality of every field.
func equals(o: PlayerState) -> bool:
	return pos_x == o.pos_x and pos_y == o.pos_y and pos_z == o.pos_z \
		and vel_x == o.vel_x and vel_z == o.vel_z and vel_up == o.vel_up \
		and on_ground == o.on_ground and stamina_ms == o.stamina_ms \
		and prev_buttons == o.prev_buttons and teleport_gen == o.teleport_gen \
		and ducked == o.ducked and duck_ticks == o.duck_ticks and in_duck == o.in_duck


func to_packed() -> PackedFloat64Array:
	return PackedFloat64Array([pos_x, pos_y, pos_z, vel_x, vel_z, vel_up,
		1.0 if on_ground else 0.0, stamina_ms, float(prev_buttons), float(teleport_gen),
		1.0 if ducked else 0.0, float(duck_ticks), 1.0 if in_duck else 0.0])


## Inverse of to_packed() (same field order).
static func from_packed(p: PackedFloat64Array) -> PlayerState:
	var s := PlayerState.new()
	s.pos_x = p[0]
	s.pos_y = p[1]
	s.pos_z = p[2]
	s.vel_x = p[3]
	s.vel_z = p[4]
	s.vel_up = p[5]
	s.on_ground = p[6] != 0.0
	s.stamina_ms = p[7]
	s.prev_buttons = int(p[8])
	s.teleport_gen = int(p[9])
	s.ducked = p[10] != 0.0
	s.duck_ticks = int(p[11])
	s.in_duck = p[12] != 0.0
	return s


func hex() -> String:
	return to_packed().to_byte_array().hex_encode()


func distance_to(o: PlayerState) -> float:
	var dx := pos_x - o.pos_x
	var dy := pos_y - o.pos_y
	var dz := pos_z - o.pos_z
	return sqrt(dx * dx + dy * dy + dz * dz)


func speed() -> float:
	return sqrt(vel_x * vel_x + vel_z * vel_z)
