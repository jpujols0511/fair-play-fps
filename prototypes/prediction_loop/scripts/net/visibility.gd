class_name Visibility
extends RefCounted
## Server-side visibility culling v0 (specs/visibility_culling_v0.md, PROPOSED): send an enemy to a
## viewer only if a ray from the viewer's eyes to a point on the enemy is not blocked by a box.
## Pure functions (float64) + VisibilityManager-style history for Devin's "never sent" hook (seam D4).
## Game frame (y up). Boxes: [min_x, min_z, max_x, max_z, top, bottom] (bottom optional, default 0.0).
## Independent Python reference: tools/los_ref.py (seed 7501, 5,000 configurations).

## CD-r2: head center (66.0 / 30.0) plus a crown point at the top of the head box (72.0 / 36.0), no vertical margin, so a
## sliver of head above a wall edge is still sent.
const STAND_HEIGHTS := [66.0, 72.0, 54.5, 2.0, 58.0, 58.0]    # head, crown, chest, feet, shoulder L, shoulder R
const CROUCH_HEIGHTS := [30.0, 36.0, 27.25, 1.0, 29.0, 29.0]
const SIDE_SIGN := [0.0, 0.0, 0.0, 0.0, 1.0, -1.0]
const SHOULDER_SIDE := 12.0
const POINTS := 6
const RAYS_PER_PAIR := 72                                # 2 eyes x 2 target positions x 6 points x 3 lateral shifts


## Strict slab test: blocked only if the segment passes through the OPEN interior of the box.
## Touching a face or an edge counts as clear.
static func segment_blocked(p0x: float, p0y: float, p0z: float, p1x: float, p1y: float, p1z: float, box: PackedFloat64Array) -> bool:
	var tmin := 0.0
	var tmax := 1.0
	var bottom := box[5] if box.size() > 5 else 0.0
	# x
	var d := p1x - p0x
	if d == 0.0:
		if not (box[0] < p0x and p0x < box[2]):
			return false
	else:
		var t1 := (box[0] - p0x) / d
		var t2 := (box[2] - p0x) / d
		if t1 > t2:
			var tmp := t1
			t1 = t2
			t2 = tmp
		if t1 > tmin: tmin = t1
		if t2 < tmax: tmax = t2
		if not (tmin < tmax):
			return false
	# y
	d = p1y - p0y
	if d == 0.0:
		if not (bottom < p0y and p0y < box[4]):
			return false
	else:
		var t1y := (bottom - p0y) / d
		var t2y := (box[4] - p0y) / d
		if t1y > t2y:
			var tmpy := t1y
			t1y = t2y
			t2y = tmpy
		if t1y > tmin: tmin = t1y
		if t2y < tmax: tmax = t2y
		if not (tmin < tmax):
			return false
	# z
	d = p1z - p0z
	if d == 0.0:
		if not (box[1] < p0z and p0z < box[3]):
			return false
	else:
		var t1z := (box[1] - p0z) / d
		var t2z := (box[3] - p0z) / d
		if t1z > t2z:
			var tmpz := t1z
			t1z = t2z
			t2z = tmpz
		if t1z > tmin: tmin = t1z
		if t2z < tmax: tmax = t2z
		if not (tmin < tmax):
			return false
	return tmin < tmax


static func ray_clear(p0x: float, p0y: float, p0z: float, p1x: float, p1y: float, p1z: float, boxes: Array) -> bool:
	for i in boxes.size():
		if segment_blocked(p0x, p0y, p0z, p1x, p1y, p1z, boxes[i]):
			return false
	return true


## Returns the index of the first clear ray, or -1 if the target is hidden (not sent).
## index = ((eye * 2 + target_position) * 6 + point) * 3 + shift, shifts [0, +margin, -margin].
## v* = viewer feet position / horizontal velocity / eye height; t* = target feet position / velocity.
static func target_visible(vx: float, vy: float, vz: float, vvx: float, vvz: float, eye: float,
		tx: float, ty: float, tz: float, tvx: float, tvz: float, crouched: bool,
		boxes: Array, lookahead_s: float, margin: float = 8.0, duck_fraction: float = -1.0) -> int:
	# duck_fraction >= 0.0 blends the sample heights between standing (0.0) and crouched (1.0) like the blended hitbox;
	# without it the bool picks one of the two sets
	var heights: Array = CROUCH_HEIGHTS if crouched else STAND_HEIGHTS
	if duck_fraction >= 0.0:
		heights = []
		for k in POINTS:
			heights.append(STAND_HEIGHTS[k] + (CROUCH_HEIGHTS[k] - STAND_HEIGHTS[k]) * duck_fraction)
	for ei in 2:
		var ex := vx
		var ez := vz
		if ei == 1:
			ex = vx + vvx * lookahead_s
			ez = vz + vvz * lookahead_s
		var ey := vy + eye
		for ti in 2:
			var px := tx
			var pz := tz
			if ti == 1:
				px = tx + tvx * lookahead_s
				pz = tz + tvz * lookahead_s
			var dx := px - ex
			var dz := pz - ez
			var ln := sqrt(dx * dx + dz * dz)
			var ux := 1.0
			var uz := 0.0
			if ln > 0.0:
				ux = -dz / ln
				uz = dx / ln
			for pi in POINTS:
				var h: float = heights[pi]
				var side: float = SIDE_SIGN[pi]
				for si in 3:
					var sh := 0.0
					if si == 1:
						sh = margin
					elif si == 2:
						sh = -margin
					var lat := side * SHOULDER_SIDE + sh
					if ray_clear(ex, ey, ez, px + ux * lat, ty + h, pz + uz * lat, boxes):
						return ((ei * 2 + ti) * POINTS + pi) * 3 + si
	return -1


## Per-viewer history of the mask in force each tick (seam D4). Preallocated ring.
class History extends RefCounted:
	var size := 640
	var masks := PackedInt32Array()
	var ticks := PackedInt32Array()
	var latest := -1
	var current := 0

	func _init(p_size: int = 640) -> void:
		size = p_size
		masks.resize(size)
		ticks.resize(size)
		ticks.fill(-1)

	## Call once per server tick. new_mask >= 0 on a snapshot tick (the mask just decided), -1 otherwise.
	func advance(tick: int, new_mask: int) -> void:
		if new_mask >= 0:
			current = new_mask
		masks[tick % size] = current
		ticks[tick % size] = tick
		latest = tick

	## The mask in force at `tick`, or -1 if the tick is outside the history.
	func mask_at(tick: int) -> int:
		if tick < 0 or latest < 0 or tick > latest or latest - tick >= size or ticks[tick % size] != tick:
			return -1
		return masks[tick % size]
