class_name LagCompHistory
extends RefCounted

class SlotRing extends RefCounted:
	var capacity: int
	var ticks: Array = []
	var origins: Array = []
	var yaws: Array = []
	var stances: Array = []
	var duck_fractions: Array = []
	var alive: Array = []
	var write_index := 0
	var count := 0
	var latest_tick := -1

	func _init(ring_capacity: int) -> void:
		capacity = ring_capacity
		ticks.resize(capacity)
		origins.resize(capacity * 3)
		yaws.resize(capacity)
		stances.resize(capacity)
		duck_fractions.resize(capacity)
		alive.resize(capacity)
		for i in range(capacity):
			ticks[i] = -1
			origins[i * 3] = 0.0
			origins[i * 3 + 1] = 0.0
			origins[i * 3 + 2] = 0.0
			yaws[i] = 0.0
			stances[i] = 0
			duck_fractions[i] = 0.0
			alive[i] = false


var tick_rate: int
var slot_count: int
var max_rewind_ticks: int
var capacity: int
var _slots: Array = []


func _init(p_tick_rate: int = 128, p_slot_count: int = 16) -> void:
	tick_rate = maxi(p_tick_rate, 1)
	slot_count = clampi(p_slot_count, 1, 16)
	max_rewind_ticks = max_rewind_for_rate(tick_rate)
	capacity = max_rewind_ticks + 1
	for _slot in range(slot_count):
		_slots.append(SlotRing.new(capacity))


static func max_rewind_for_rate(rate: int) -> int:
	return int(floor(0.2 * float(rate) + 1e-12))


func sample_count(slot: int) -> int:
	if not _valid_slot(slot):
		return 0
	return int(_slots[slot].count)


func latest_tick_for_slot(slot: int) -> int:
	if not _valid_slot(slot):
		return -1
	return int(_slots[slot].latest_tick)


func push_sample(slot: int, sample: Dictionary) -> bool:
	if not _valid_slot(slot):
		return false
	var ring: SlotRing = _slots[slot]
	var tick := int(sample.get("tick", -1))
	if tick < 0 or (ring.count > 0 and tick <= ring.latest_tick):
		return false
	var stance := int(sample.get("stance", -1))
	if stance < 0 or stance > 3:
		return false
	var duck_fraction := float(sample.get("duck_fraction", -1.0))
	if duck_fraction == -1.0:
		duck_fraction = 1.0 if stance == 1 or stance == 3 else 0.0
	elif not is_finite(duck_fraction) or duck_fraction < 0.0 or duck_fraction > 1.0:
		return false

	var origin_value: Variant = sample.get("origin64", sample.get("origin", null))
	var origin_x := 0.0
	var origin_y := 0.0
	var origin_z := 0.0
	match typeof(origin_value):
		TYPE_VECTOR3:
			origin_x = origin_value.x
			origin_y = origin_value.y
			origin_z = origin_value.z
		TYPE_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			if origin_value.size() != 3:
				return false
			origin_x = float(origin_value[0])
			origin_y = float(origin_value[1])
			origin_z = float(origin_value[2])
		_:
			return false

	var index := ring.write_index
	ring.ticks[index] = tick
	ring.origins[index * 3] = origin_x
	ring.origins[index * 3 + 1] = origin_y
	ring.origins[index * 3 + 2] = origin_z
	ring.yaws[index] = float(sample.get("yaw_deg", 0.0))
	ring.stances[index] = stance
	ring.duck_fractions[index] = duck_fraction
	ring.alive[index] = bool(sample.get("alive", true))
	ring.write_index = (index + 1) % capacity
	ring.count = mini(ring.count + 1, capacity)
	ring.latest_tick = tick
	return true


func sample_at(slot: int, target_tick: float) -> Dictionary:
	if not _valid_slot(slot):
		return _empty_sample(true)
	var ring: SlotRing = _slots[slot]
	if ring.count == 0:
		return _empty_sample(true)

	var oldest_index := _oldest_index(ring)
	var oldest_tick := int(ring.ticks[oldest_index])
	var newest_index := _newest_index(ring)
	var newest_tick := int(ring.ticks[newest_index])
	if target_tick < float(oldest_tick):
		return _read_sample(ring, oldest_index, true)
	if target_tick > float(newest_tick):
		return _read_sample(ring, newest_index, true)

	var lower_tick := int(floor(target_tick))
	var upper_tick := int(ceil(target_tick))
	var lower_index := _find_tick_index(ring, lower_tick)
	var upper_index := _find_tick_index(ring, upper_tick)
	if lower_index < 0 or upper_index < 0:
		return _read_sample(ring, oldest_index, true)

	var fraction := target_tick - float(lower_tick)
	var lower := _read_sample(ring, lower_index, false)
	var upper := _read_sample(ring, upper_index, false)
	var origin_lower: PackedFloat64Array = lower["origin64"]
	var origin_upper: PackedFloat64Array = upper["origin64"]
	var origin := PackedFloat64Array([
		origin_lower[0] + (origin_upper[0] - origin_lower[0]) * fraction,
		origin_lower[1] + (origin_upper[1] - origin_lower[1]) * fraction,
		origin_lower[2] + (origin_upper[2] - origin_lower[2]) * fraction,
	])
	var yaw_delta := fposmod(float(upper["yaw_deg"]) - float(lower["yaw_deg"]) + 180.0, 360.0) - 180.0
	var yaw := fposmod(float(lower["yaw_deg"]) + yaw_delta * fraction, 360.0)
	var duck_fraction := lerpf(
		float(lower["duck_fraction"]),
		float(upper["duck_fraction"]),
		fraction
	)
	return {
		"tick": target_tick,
		"origin64": origin,
		"origin": Vector3(origin[0], origin[1], origin[2]),
		"yaw_deg": yaw,
		"stance": int(lower["stance"]) if fraction <= 0.5 else int(upper["stance"]),
		"duck_fraction": duck_fraction,
		"alive": bool(lower["alive"]) and bool(upper["alive"]),
		"missing_history": false,
		"lower_tick": lower_tick,
		"upper_tick": upper_tick,
		"fraction": fraction,
	}


func rewind_targets(shooter_slot: int, chosen_view_tick: float) -> Dictionary:
	var targets: Array = []
	var rewound_mask := 0
	var targets_rewound := 0
	var missing_history_count := 0
	for slot in range(slot_count):
		if slot == shooter_slot:
			continue
		var ring: SlotRing = _slots[slot]
		if ring.count == 0:
			continue
		var sample := sample_at(slot, chosen_view_tick)
		if bool(sample["missing_history"]):
			missing_history_count += 1
		if not bool(sample["alive"]):
			continue
		targets.append({"slot": slot, "sample": sample})
		if not bool(sample["missing_history"]) and chosen_view_tick < float(ring.latest_tick):
			rewound_mask |= 1 << slot
			targets_rewound += 1
	return {
		"targets": targets,
		"rewound_mask": rewound_mask,
		"targets_rewound": targets_rewound,
		"missing_history_count": missing_history_count,
	}


func _find_tick_index(ring: SlotRing, tick: int) -> int:
	var first := _oldest_index(ring)
	for offset in range(ring.count):
		var index := (first + offset) % capacity
		if int(ring.ticks[index]) == tick:
			return index
	return -1


func _read_sample(ring: SlotRing, index: int, missing: bool) -> Dictionary:
	var origin := PackedFloat64Array([
		float(ring.origins[index * 3]),
		float(ring.origins[index * 3 + 1]),
		float(ring.origins[index * 3 + 2]),
	])
	return {
		"tick": int(ring.ticks[index]),
		"origin64": origin,
		"origin": Vector3(origin[0], origin[1], origin[2]),
		"yaw_deg": float(ring.yaws[index]),
		"stance": int(ring.stances[index]),
		"duck_fraction": float(ring.duck_fractions[index]),
		"alive": bool(ring.alive[index]),
		"missing_history": missing,
	}


func _empty_sample(missing: bool) -> Dictionary:
	return {
		"tick": -1.0,
		"origin64": PackedFloat64Array([0.0, 0.0, 0.0]),
		"origin": Vector3.ZERO,
		"yaw_deg": 0.0,
		"stance": 0,
		"duck_fraction": 0.0,
		"alive": false,
		"missing_history": missing,
	}


func _oldest_index(ring: SlotRing) -> int:
	return (ring.write_index - ring.count + capacity) % capacity


func _newest_index(ring: SlotRing) -> int:
	return (ring.write_index - 1 + capacity) % capacity


func _valid_slot(slot: int) -> bool:
	return slot >= 0 and slot < slot_count
