class_name WeaponConfig
extends RefCounted

const KICK_PATTERN_RANDOM_FLIP := "random_flip"
const KICK_PATTERN_FIXED := "fixed"

# DECISION FOR JOAN J1: keep stock 1.6 side flips; "fixed" is a deterministic stub.
const KICK_PATTERN_MODE := KICK_PATTERN_RANDOM_FLIP
# DECISION FOR JOAN J2: preserve the stock moving-before-air kick selection.
const KICK_MOVING_BEFORE_AIR := true
# DECISION FOR JOAN J3: randint(0, k) is inclusive, matching the sim and spec table.
const FLIP_ROLL_INCLUSIVE := true
# DECISION FOR JOAN J4: retain the stock stored-accuracy recovery quirk.
const ACCURACY_RESET_ON_RECOVERY := false
const FIXED_FLIP_SEQUENCE := [false, true]
const SHOTS_FIRED_RELEASE_CAP := 15.0
const RECOVERY_DELAY_FROM_LAST_SHOT := "last_shot"
const RECOVERY_DELAY_FROM_RELEASE := "release"
const RECOVERY_DELAY_FROM := RECOVERY_DELAY_FROM_RELEASE

# DECISION FOR JOAN J17: use the proposed finite weapon segment length.
const WEAPON_RANGE_UNITS := 8192.0
# DECISION FOR JOAN J13: stop at the first player hit by default.
const PLAYER_PENETRATION := false
# DECISION FOR JOAN J14: world geometry blocks shots; no wallbangs in v1.
const WORLD_BLOCKS_SHOTS := true

# CD-r9 stock recovery defaults: the first drop follows release, then drops are
# strictly spaced and limited to one per tick. The old alternatives remain configurable.
const BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD := false
const RECOVERY_ONE_PER_TICK := true

static func defaults() -> Dictionary:
	return {
		"KICK_PATTERN_MODE": KICK_PATTERN_MODE,
		"KICK_MOVING_BEFORE_AIR": KICK_MOVING_BEFORE_AIR,
		"FLIP_ROLL_INCLUSIVE": FLIP_ROLL_INCLUSIVE,
		"ACCURACY_RESET_ON_RECOVERY": ACCURACY_RESET_ON_RECOVERY,
		"FIXED_FLIP_SEQUENCE": FIXED_FLIP_SEQUENCE.duplicate(),
		"WEAPON_RANGE_UNITS": WEAPON_RANGE_UNITS,
		"PLAYER_PENETRATION": PLAYER_PENETRATION,
		"WORLD_BLOCKS_SHOTS": WORLD_BLOCKS_SHOTS,
		"SHOTS_FIRED_RELEASE_CAP": SHOTS_FIRED_RELEASE_CAP,
		"RECOVERY_DELAY_FROM": RECOVERY_DELAY_FROM,
		"BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD": BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD,
		"RECOVERY_ONE_PER_TICK": RECOVERY_ONE_PER_TICK,
	}


static func with_overrides(overrides: Dictionary = {}) -> Dictionary:
	var result := defaults()
	for key in overrides:
		result[key] = overrides[key]
	return result
