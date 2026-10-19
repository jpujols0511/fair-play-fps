class_name EvidenceConfig
extends RefCounted

# DECISION FOR JOAN: evidence writer, reader and offline review stay OFF until Rust.
const ENABLE_EVIDENCE_LOG := false
# DECISION FOR JOAN J19: type 6 is proposed; keep a reader/writer switch.
const ENABLE_AIM_KIN := true
# PROPOSED cadence from the evidence spec: one checkpoint every 128 server ticks.
const CHECKPOINT_INTERVAL_TICKS := 128
# DECISION FOR JOAN from evidence spec Section 7.
const RETENTION_DAYS := 90
# PROPOSED mapping until the weapons table assigns stable wire IDs.
const WEAPON_ID_MAP := {"AK47": 1, "M4A1": 2}
const MAX_SLOTS := 16
const FORMAT_VERSION := 1
const KERNEL_SHA256_PLACEHOLDER := "0000000000000000000000000000000000000000000000000000000000000000"
const SKELETON_SHA256 := "56db86a8d12c400f5149f7cfcbf17ec79dd662c93cc6a3d5f18d4d0c288f7aa0"


static func defaults() -> Dictionary:
	return {
		"ENABLE_EVIDENCE_LOG": ENABLE_EVIDENCE_LOG,
		"ENABLE_AIM_KIN": ENABLE_AIM_KIN,
		"CHECKPOINT_INTERVAL_TICKS": CHECKPOINT_INTERVAL_TICKS,
		"RETENTION_DAYS": RETENTION_DAYS,
		"WEAPON_ID_MAP": WEAPON_ID_MAP.duplicate(true),
		"MAX_SLOTS": MAX_SLOTS,
		"FORMAT_VERSION": FORMAT_VERSION,
		"KERNEL_SHA256_PLACEHOLDER": KERNEL_SHA256_PLACEHOLDER,
		"SKELETON_SHA256": SKELETON_SHA256,
	}


static func with_overrides(overrides: Dictionary = {}) -> Dictionary:
	var result := defaults()
	for key in overrides:
		result[key] = overrides[key]
	return result
