class_name Frame
extends RefCounted
## The one place the game frame and the spec frame convert (seam D7, handoff Section 5.1).
##   game frame (Godot, y up): pos_x, pos_z horizontal, pos_y feet height. Yaw in radians:
##     yaw 0 faces -Z, forward = (-sin yaw, -cos yaw) in (x, z). Pitch in radians, positive = look up.
##   spec frame (z up, hitbox / evidence / Devin): x forward at yaw 0, y left, z up. Yaw in degrees,
##     0 = +x, counterclockwise toward +y. Pitch in degrees, positive = looking DOWN (Quake).
## PROPOSED derivation (proved by tests/test_frame.gd):
##   spec_x = pos_x, spec_y = -pos_z, spec_z = pos_y
##   spec_yaw_deg = fposmod(rad_to_deg(yaw) + 90.0, 360.0), spec_pitch_deg = -rad_to_deg(pitch)


static func to_spec_x(pos_x: float) -> float:
	return pos_x


static func to_spec_y(pos_z: float) -> float:
	return -pos_z


static func to_spec_z(pos_y: float) -> float:
	return pos_y


static func to_game_x(spec_x: float) -> float:
	return spec_x


static func to_game_z(spec_y: float) -> float:
	return -spec_y


static func to_game_y(spec_z: float) -> float:
	return spec_z


static func yaw_to_spec_deg(yaw_rad: float) -> float:
	return fposmod(rad_to_deg(yaw_rad) + 90.0, 360.0)


static func yaw_to_game_rad(spec_yaw_deg: float) -> float:
	return deg_to_rad(fposmod(spec_yaw_deg - 90.0, 360.0))


static func pitch_to_spec_deg(pitch_rad: float) -> float:
	return -rad_to_deg(pitch_rad)


static func pitch_to_game_rad(spec_pitch_deg: float) -> float:
	return deg_to_rad(-spec_pitch_deg)
