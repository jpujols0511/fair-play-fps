class_name RifleTables
extends RefCounted

const AK47 := "AK47"
const M4A1 := "M4A1"

const TABLES := {
	AK47: {
		"cycle_s": 0.0955,
		"accuracy_divisor": 200.0,
		"accuracy_floor": 0.35,
		"accuracy_cap": 1.25,
		"accuracy_start": 0.2,
		"spread": {
			"air": [0.04, 0.4],
			"run": [0.04, 0.07],
			"stand": [0.0, 0.0275],
			"crouch": [0.0, 0.0275],
		},
		"kick": {
			"moving": [1.5, 0.45, 0.225, 0.05, 6.5, 2.5, 7],
			"air": [2.0, 1.0, 0.5, 0.35, 9.0, 6.0, 5],
			"crouch": [0.9, 0.35, 0.15, 0.025, 5.5, 1.5, 9],
			"stand": [1.0, 0.375, 0.175, 0.0375, 5.75, 1.75, 8],
		},
	},
	M4A1: {
		"cycle_s": 0.0875,
		"accuracy_divisor": 220.0,
		"accuracy_floor": 0.30,
		"accuracy_cap": 1.0,
		"accuracy_start": 0.2,
		"spread": {
			"air": [0.035, 0.4],
			"run": [0.035, 0.07],
			"stand": [0.0, 0.025],
			"crouch": [0.0, 0.025],
			"stand_unsilenced": [0.0, 0.020],
		},
		"kick": {
			"moving": [1.0, 0.45, 0.28, 0.045, 3.75, 3.0, 7],
			"air": [1.2, 0.5, 0.23, 0.15, 5.5, 3.5, 6],
			"crouch": [0.6, 0.3, 0.2, 0.0125, 3.25, 2.0, 7],
			"stand": [0.65, 0.35, 0.25, 0.015, 3.5, 2.25, 7],
		},
	},
}


static func get_weapon(weapon_id: String) -> Dictionary:
	return TABLES.get(weapon_id, {}).duplicate(true)


static func accuracy_for_shots(weapon_id: String, shot_count: int) -> float:
	var weapon: Dictionary = TABLES.get(weapon_id, {})
	if weapon.is_empty():
		return NAN
	var count := float(shot_count)
	var cube := count * count * count
	var stepped_increase := floorf(cube / float(weapon["accuracy_divisor"]))
	return minf(
		stepped_increase + float(weapon["accuracy_floor"]),
		float(weapon["accuracy_cap"])
	)


static func accuracy_for_shots_smooth(weapon_id: String, shot_count: int) -> float:
	# Retained only as a legacy reference; stock accuracy uses the stepped function above.
	var weapon: Dictionary = TABLES.get(weapon_id, {})
	if weapon.is_empty():
		return NAN
	var count := float(shot_count)
	var cube := count * count * count
	return minf(
		cube / float(weapon["accuracy_divisor"]) + float(weapon["accuracy_floor"]),
		float(weapon["accuracy_cap"])
	)
