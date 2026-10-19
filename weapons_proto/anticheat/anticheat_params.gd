class_name AntiCheatParams
extends RefCounted

const AIM_KIN_PROFILE_DEFAULTS := {
	"WINDOW_BEFORE_TICKS": 16,
	"WINDOW_AFTER_TICKS": 3,
	"SNAP_MIN_FIRE_DELTA_DEG": 3.0,
	"SNAPBACK_MIN_FRACTION": 0.70,
	"SNAPBACK_MAX_COS": -0.8,
	"PRE_FIRE_SPEED_MAX_FRACTION": 0.10,
	"FLICK_MIN_PEAK_ACCEL_DPS2": 200000.0,
	"FLICK_MAX_SETTLE_TICKS": 1,
	"SETTLE_FRACTION": 0.10,
	"N_AIM_KIN": 3,
	"EXCLUDE_AFTER_RESET_TICKS": 16,
}
# Surf thresholds stay provisional until match data is collected.
const AIM_KIN_PROFILE_SURF := {
	"WINDOW_BEFORE_TICKS": 16,
	"WINDOW_AFTER_TICKS": 3,
	"SNAP_MIN_FIRE_DELTA_DEG": 3.0,
	"SNAPBACK_MIN_FRACTION": 0.70,
	"SNAPBACK_MAX_COS": -0.8,
	"PRE_FIRE_SPEED_MAX_FRACTION": 0.10,
	"FLICK_MIN_PEAK_ACCEL_DPS2": 200000.0,
	"FLICK_MAX_SETTLE_TICKS": 1,
	"SETTLE_FRACTION": 0.10,
	"N_AIM_KIN": 3,
	"EXCLUDE_AFTER_RESET_TICKS": 16,
}
const AIM_KIN_PROFILES := {
	"default": AIM_KIN_PROFILE_DEFAULTS,
	"surf": AIM_KIN_PROFILE_SURF,
}

const DEFAULTS := {
	"ENABLE_ANTICHEAT_REVIEW": false,
	"AIM_KIN_PROFILE": "default",
	"X_DEG": 2.0,
	"Y_MS": 250,
	"TRACKING_CORRELATION": 0.8,
	"JUST_LEFT_VIEW_MS": 500,
	"SOUND_EXPLAIN_MS": 2000,
	"SOUND_ANGLE_DEG": 4.0,
	"PREAIM_PERCENTILE": 90,
	"MIN_EPISODES": 3,
	"MIN_TARGET_SPEED": 30.0,
	"TEAM_INFO_WINDOW_MS": 3000,
	"TEAM_INFO_WEIGHT": 0.25,
	"UNSENT_HITS_REQUIRED": 2,
	"WINDOW_BEFORE_TICKS": 16,
	"WINDOW_AFTER_TICKS": 3,
	"SNAP_MIN_FIRE_DELTA_DEG": 3.0,
	"SNAPBACK_MIN_FRACTION": 0.70,
	"SNAPBACK_MAX_COS": -0.8,
	"PRE_FIRE_SPEED_MAX_FRACTION": 0.10,
	"FLICK_MIN_PEAK_ACCEL_DPS2": 200000.0,
	"FLICK_MAX_SETTLE_TICKS": 1,
	"SETTLE_FRACTION": 0.10,
	"N_AIM_KIN": 3,
	"EXCLUDE_AFTER_RESET_TICKS": 16,
	# DECISION FOR JOAN J15: do not reject legal high-yaw flicks in v1.
	"MAX_VIEW_DELTA_DEG_PER_TICK": INF,
}


static func defaults() -> Dictionary:
	return DEFAULTS.duplicate(true)


static func with_overrides(overrides: Dictionary = {}) -> Dictionary:
	var result := defaults()
	for key in overrides:
		result[key] = overrides[key]
	if overrides.has("X_DEG") and not overrides.has("SOUND_ANGLE_DEG"):
		result["SOUND_ANGLE_DEG"] = 2.0 * float(result["X_DEG"])
	return result


static func for_server_metadata(
		server_metadata: Dictionary,
		overrides: Dictionary = {}
	) -> Dictionary:
	var profile := "surf" if str(server_metadata.get("mode", "")) == "surf" else "default"
	var result := with_overrides()
	var thresholds: Dictionary = AIM_KIN_PROFILES[profile]
	for key in thresholds:
		result[key] = thresholds[key]
	for key in overrides:
		if key != "AIM_KIN_PROFILE":
			result[key] = overrides[key]
	if overrides.has("X_DEG") and not overrides.has("SOUND_ANGLE_DEG"):
		result["SOUND_ANGLE_DEG"] = 2.0 * float(result["X_DEG"])
	result["AIM_KIN_PROFILE"] = profile
	return result


static func evidence_params(params: Dictionary) -> Dictionary:
	return {
		"X_deg": float(params["X_DEG"]),
		"Y_ms": int(params["Y_MS"]),
		"C": float(params["TRACKING_CORRELATION"]),
		"G_ms": int(params["JUST_LEFT_VIEW_MS"]),
		"S_ms": int(params["SOUND_EXPLAIN_MS"]),
		"P": int(params["PREAIM_PERCENTILE"]),
		"N": int(params["MIN_EPISODES"]),
		"AIM_KIN_PROFILE": str(params["AIM_KIN_PROFILE"]),
	}
