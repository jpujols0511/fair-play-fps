class_name HitboxConfig
extends RefCounted

# DECISION FOR JOAN J5 / A1: box width and depth are twice the listed radius.
const BOX_RADIUS_MULTIPLIER := 2.0
const BOX_WIDTH_DEPTH_MODE := "diameter"

# Addendum 2: crouch is half height. Transition blends use this as f = 1.0.
const CROUCH_SCALE := 0.5

# DECISION FOR JOAN J7 / A3: align hitboxes to the proposed standing body.
const STAND_HEIGHT := 72.0
const EYE_STAND := 64.0

# DECISION FOR JOAN J8 / A4: use the rounded v0.2 non-head lengths (~0.57 scale).
const NON_HEAD_LENGTH_SCALE := 0.57
const LENGTH_TABLE_MODE := "v0.2_rounded"

# DECISION FOR JOAN J9 / A5: keep limbs in the straight-down A-pose.
const ARM_POSE := "a_pose"
# DECISION FOR JOAN A2-b: the smallest entry distance wins by default.
const CROUCH_HEAD_OVERLAP_RULE := "entry_first"
const CROUCH_HEAD_OVERLAP_ENTRY_FIRST := "entry_first"
const CROUCH_HEAD_OVERLAP_HEAD_PRIORITY := "head_priority_in_overlap"
# PROVISIONAL per Addendum 4; padding changes hit tests, not skeleton geometry.
const HITBOX_PADDING := 2.0
const HITBOX_PADDING_PER_BONE := {
	0: 2.0, 1: 2.0, 2: 2.0, 3: 2.0, 4: 2.0, 5: 2.0,
	6: 2.0, 7: 2.0, 8: 2.0, 9: 2.0, 10: 2.0,
}
const NEAR_MISS_LOG_UNITS := 4.0


static func defaults() -> Dictionary:
	return {
		"BOX_RADIUS_MULTIPLIER": BOX_RADIUS_MULTIPLIER,
		"BOX_WIDTH_DEPTH_MODE": BOX_WIDTH_DEPTH_MODE,
		"CROUCH_SCALE": CROUCH_SCALE,
		"CROUCH_HEAD_OVERLAP_RULE": CROUCH_HEAD_OVERLAP_RULE,
		"STAND_HEIGHT": STAND_HEIGHT,
		"EYE_STAND": EYE_STAND,
		"NON_HEAD_LENGTH_SCALE": NON_HEAD_LENGTH_SCALE,
		"LENGTH_TABLE_MODE": LENGTH_TABLE_MODE,
		"ARM_POSE": ARM_POSE,
		"HITBOX_PADDING": HITBOX_PADDING,
		"HITBOX_PADDING_PER_BONE": HITBOX_PADDING_PER_BONE.duplicate(true),
		"NEAR_MISS_LOG_UNITS": NEAR_MISS_LOG_UNITS,
	}


static func with_overrides(overrides: Dictionary = {}) -> Dictionary:
	var result := defaults()
	for key in overrides:
		result[key] = overrides[key]
	return result
