class_name RewindPolicy
extends RefCounted

const INTERP_TICKS := 4
const MAX_REWIND_SECONDS := 0.2
const CLAIMED_TIME_WINDOW_EPS_TICKS := 1e-9

const FLAG_REWIND_CLAMPED := 1 << 0
const FLAG_CLAIMED_TIME_OUT_OF_WINDOW := 1 << 1
const FLAG_NEGATIVE_REWIND := 1 << 4
const FLAG_MISSING_HISTORY := 1 << 5

const REASON_NONE := 0
const REASON_CLAIM_OUT_OF_WINDOW := 1
const REASON_OVER_CAP := 2
const REASON_CLAIM_AND_CAP := 3
const REASON_NEGATIVE := 4
const REASON_CLAIM_AND_NEGATIVE := 5
const REASON_MISSING_HISTORY := 6


static func max_rewind_ticks(tick_rate: int) -> int:
	return int(floor(MAX_REWIND_SECONDS * float(tick_rate) + 1e-12))


static func choose(
		now: float,
		rtt_ms: float,
		interp_ticks: int,
		claimed_view_tick: float,
		tick_rate: int
	) -> Dictionary:
	if tick_rate <= 0:
		return {"error": "tick_rate must be positive"}
	if not is_finite(now):
		return {"error": "now must be finite"}
	var rate := float(tick_rate)
	var invalid_rtt := not is_finite(rtt_ms)
	var invalid_claim := not is_finite(claimed_view_tick)
	var safe_rtt_ms := 0.0 if invalid_rtt else rtt_ms
	var rtt_ticks := safe_rtt_ms * rate / 1000.0
	var expected_view_tick := now - rtt_ticks - float(interp_ticks)
	if not is_finite(rtt_ticks) or not is_finite(expected_view_tick):
		invalid_rtt = true
		safe_rtt_ms = 0.0
		rtt_ticks = 0.0
		expected_view_tick = now - float(interp_ticks)
	var claim_delta := 0.0 if invalid_claim else claimed_view_tick - expected_view_tick
	var invalid_delta := not is_finite(claim_delta)
	var claim_out_of_window := invalid_rtt or invalid_claim or invalid_delta \
		or absf(claim_delta) > 1.0 + CLAIMED_TIME_WINDOW_EPS_TICKS
	var clamped_claim := expected_view_tick if invalid_rtt or invalid_claim or invalid_delta \
		else claimed_view_tick
	var flags := 0
	if claim_out_of_window:
		if not invalid_rtt and not invalid_claim and not invalid_delta:
			clamped_claim = expected_view_tick + (1.0 if claim_delta > 0.0 else -1.0)
		flags |= FLAG_CLAIMED_TIME_OUT_OF_WINDOW

	var wanted_rewind_ticks := now - clamped_claim
	var cap := max_rewind_ticks(tick_rate)
	var over_cap := wanted_rewind_ticks > float(cap)
	var negative := wanted_rewind_ticks < 0.0
	var rewind := clampf(wanted_rewind_ticks, 0.0, float(cap))
	if over_cap:
		flags |= FLAG_REWIND_CLAMPED
	if negative:
		flags |= FLAG_NEGATIVE_REWIND

	var rewind_ticks := int(floor(rewind))
	var rewind_frac := int(floor((rewind - float(rewind_ticks)) * 65536.0 + 0.5))
	if rewind_frac >= 65536:
		rewind_ticks += 1
		rewind_frac = 0
	if rewind_ticks > cap:
		rewind_ticks = cap
		rewind_frac = 0
	if rewind_ticks == cap and over_cap:
		rewind_frac = 0

	var reason := REASON_NONE
	if claim_out_of_window and over_cap:
		reason = REASON_CLAIM_AND_CAP
	elif claim_out_of_window and negative:
		reason = REASON_CLAIM_AND_NEGATIVE
	elif claim_out_of_window:
		reason = REASON_CLAIM_OUT_OF_WINDOW
	elif over_cap:
		reason = REASON_OVER_CAP
	elif negative:
		reason = REASON_NEGATIVE

	var chosen_view_tick := now - (float(rewind_ticks) + float(rewind_frac) / 65536.0)
	return {
		"now": now,
		"rtt_ms": safe_rtt_ms,
		"rtt_ticks": rtt_ticks,
		"interp_ticks": interp_ticks,
		"tick_rate": tick_rate,
		"claimed_view_tick": claimed_view_tick,
		"expected_view_tick": expected_view_tick,
		"clamped_claimed_view_tick": clamped_claim,
		"chosen_view_tick": chosen_view_tick,
		"wanted_rewind_ticks": wanted_rewind_ticks,
		"rewind_ticks": rewind_ticks,
		"rewind_frac": rewind_frac,
		"rewind_ticks_float": float(rewind_ticks) + float(rewind_frac) / 65536.0,
		"max_rewind_ticks": cap,
		"flags": flags,
		"reason": reason,
		"input_reject": claim_out_of_window,
	}


static func with_missing_history(decision: Dictionary, missing_count: int) -> Dictionary:
	var result: Dictionary = decision.duplicate(true)
	result["missing_history_count"] = maxi(missing_count, 0)
	if missing_count > 0:
		result["flags"] = int(result.get("flags", 0)) | FLAG_MISSING_HISTORY
		if int(result.get("reason", REASON_NONE)) == REASON_NONE:
			result["reason"] = REASON_MISSING_HISTORY
	return result
