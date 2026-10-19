class_name DamageRegions
extends RefCounted

const REGION_HEAD := 0
const REGION_CHEST := 1
const REGION_STOMACH := 2
const REGION_ARM := 3
const REGION_LEG := 4

# DECISION FOR JOAN J12: placeholder only; real damage values await the weapons spec.
const DAMAGE_TABLE := {
	"base_damage": 0.0,
	"multipliers": {
		"head": 1.0,
		"chest": 1.0,
		"stomach": 1.0,
		"arm": 1.0,
		"leg": 1.0,
	},
}


static func region_for_box(box_id: int) -> int:
	if box_id == 0:
		return REGION_HEAD
	if box_id == 1:
		return REGION_CHEST
	if box_id == 2:
		return REGION_STOMACH
	if box_id >= 3 and box_id <= 6:
		return REGION_ARM
	if box_id >= 7 and box_id <= 10:
		return REGION_LEG
	return -1


static func region_name(region_id: int) -> String:
	match region_id:
		REGION_HEAD:
			return "head"
		REGION_CHEST:
			return "chest"
		REGION_STOMACH:
			return "stomach"
		REGION_ARM:
			return "arm"
		REGION_LEG:
			return "leg"
		_:
			return "unknown"
