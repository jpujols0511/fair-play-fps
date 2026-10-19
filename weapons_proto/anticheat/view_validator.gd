class_name AntiCheatViewValidator
extends RefCounted

const ParamsData = preload("res://anticheat/anticheat_params.gd")


static func validate_view(
		previous_pitch: float,
		previous_yaw: float,
		pitch: float,
		yaw: float,
		params_overrides: Dictionary = {}
	) -> Dictionary:
	var params: Dictionary = ParamsData.with_overrides(params_overrides)
	if not is_finite(previous_pitch) or not is_finite(previous_yaw) \
			or not is_finite(pitch) or not is_finite(yaw):
		return {"ok": false, "reason": 4}
	if pitch < -89.0 or pitch > 89.0:
		return {"ok": false, "reason": 4}
	var delta := absf(fposmod(yaw - previous_yaw + 180.0, 360.0) - 180.0)
	var limit := float(params["MAX_VIEW_DELTA_DEG_PER_TICK"])
	if is_finite(limit) and delta > limit:
		return {"ok": false, "reason": 2, "yaw_delta_deg": delta}
	return {"ok": true, "reason": 0, "yaw_delta_deg": delta}
