class_name Quant
extends RefCounted
## Wire quantization helpers (handoff Section 5.3). Ties round half AWAY from zero, like
## the Python reference (tools/snapshot_ref.py).

const POS_MIN := -32768    # i16 of 1/8 unit: -4096.0
const POS_MAX := 32767     # 4095.875

static var clamp_count := 0


static func pos_to_q(v: float) -> int:
	var q := int(round(v * 8.0))
	if q > POS_MAX:
		clamp_count += 1
		return POS_MAX
	if q < POS_MIN:
		clamp_count += 1
		return POS_MIN
	return q


static func q_to_pos(q: int) -> float:
	return float(q) / 8.0


## Same integers as prototypes/crosshair/fake_snapshot_source.gd (checked in Phase 4).
static func accuracy_to_q(a: float) -> int:
	return int(round(clampf(a, 0.0, 2.0) * 65535.0 / 2.0))


static func q_to_accuracy(q: int) -> float:
	return float(q) * 2.0 / 65535.0


static func angle_to_q(deg: float) -> int:
	return clampi(int(round(deg * 65536.0 / 360.0)), -32768, 32767)


static func q_to_angle(q: int) -> float:
	return float(q) * 360.0 / 65536.0


## stance (0..3, Movement.stance_for_hitbox) + alive bit in one byte.
static func stance_alive(stance: int, alive: bool) -> int:
	return (stance & 3) | (4 if alive else 0)


## Crouch fraction 0.0..1.0 in one byte (Addendum 3): int(round(f * 255.0)); round trip error <= 0.5 / 255.0.
static func duck_to_q(f: float) -> int:
	return int(round(clampf(f, 0.0, 1.0) * 255.0))


static func q_to_duck(q: int) -> float:
	return float(q) / 255.0
