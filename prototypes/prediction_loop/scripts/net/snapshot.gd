class_name Snapshot
extends RefCounted
## Snapshot data + byte encoding (specs/snapshot_format_v0.1.md, PROPOSED). Full and delta.
## Entities are stored already quantized (ints), indexed by slot 0..15, so comparing a
## baseline with a target is exact integer comparison. The own-player block is f64 in
## PlayerState.to_packed() order. Independent Python codec: tools/snapshot_ref.py.

const MAX_SLOTS := 16
const KIND_FULL := 1
const KIND_DELTA := 2
const HEADER_SIZE := 14
const HUD_SIZE := 7
const F_ALL := 0x7F
const F_REMOVED := 0x80
const E_X := 0
const E_Y := 1
const E_Z := 2
const E_YAW := 3
const E_PITCH := 4
const E_SA := 5          # stance + alive
const E_DUCK := 6        # duck fraction f * 255.0 (u8)
const FIELDS := 7
const FIELD_BYTES := [2, 2, 2, 2, 2, 1, 1]

static var own_field_count := -1
## Why the last decode returned null: "", "short", "bad_kind", "missing_baseline", "malformed".
static var last_error := ""

var kind := KIND_FULL
var snap_seq := 0
var server_tick := 0
var base_seq := 0
var ack_cmd_seq := 0
var flags := 0
var own: PackedFloat64Array = PackedFloat64Array()
var hud_acc := 0
var hud_pp := 0
var hud_py := 0
var hud_ms := 0
var present: PackedByteArray = PackedByteArray()
var ent: PackedInt32Array = PackedInt32Array()


static func own_count() -> int:
	if own_field_count < 0:
		own_field_count = PlayerState.new().to_packed().size()
	return own_field_count


func _init() -> void:
	own.resize(own_count())
	present.resize(MAX_SLOTS)
	ent.resize(MAX_SLOTS * FIELDS)


func clear_entities() -> void:
	present.fill(0)
	ent.fill(0)


func set_entity(slot: int, x: float, y: float, z: float, yaw_q: int, pitch_q: int, stance: int, alive: bool, duck: float = 0.0) -> void:
	present[slot] = 1
	var o := slot * FIELDS
	ent[o + E_X] = Quant.pos_to_q(x)
	ent[o + E_Y] = Quant.pos_to_q(y)
	ent[o + E_Z] = Quant.pos_to_q(z)
	ent[o + E_YAW] = yaw_q
	ent[o + E_PITCH] = pitch_q
	ent[o + E_SA] = Quant.stance_alive(stance, alive)
	ent[o + E_DUCK] = Quant.duck_to_q(duck)


func set_entity_q(slot: int, v: Array) -> void:
	present[slot] = 1
	for i in FIELDS:
		ent[slot * FIELDS + i] = v[i]


func entity_count() -> int:
	var n := 0
	for s in MAX_SLOTS:
		n += present[s]
	return n


func copy_from(o: Snapshot) -> void:
	kind = o.kind
	snap_seq = o.snap_seq
	server_tick = o.server_tick
	base_seq = o.base_seq
	ack_cmd_seq = o.ack_cmd_seq
	flags = o.flags
	own = o.own.duplicate()
	hud_acc = o.hud_acc
	hud_pp = o.hud_pp
	hud_py = o.hud_py
	hud_ms = o.hud_ms
	present = o.present.duplicate()
	ent = o.ent.duplicate()


## Same content (header kind/base_seq excluded: a delta decodes to the same snapshot as the full).
func same_content(o: Snapshot) -> bool:
	return snap_seq == o.snap_seq and server_tick == o.server_tick and ack_cmd_seq == o.ack_cmd_seq \
		and flags == o.flags and own.to_byte_array() == o.own.to_byte_array() \
		and hud_acc == o.hud_acc and hud_pp == o.hud_pp and hud_py == o.hud_py and hud_ms == o.hud_ms \
		and present == o.present and ent == o.ent


## True if a is newer than b (u16 serial arithmetic).
static func seq_newer(a: int, b: int) -> bool:
	return a != b and ((a - b) & 0xFFFF) < 0x8000


## Encodes `s`. With a baseline it writes a delta against it, otherwise a full snapshot.
func encode(baseline: Snapshot = null) -> PackedByteArray:
	var delta := baseline != null
	var f := own.size()
	var masks := PackedByteArray()
	masks.resize(MAX_SLOTS)
	var recs := 0
	var size := HEADER_SIZE + 8 * f + HUD_SIZE + 1
	for slot in MAX_SLOTS:
		var m := 0
		if not delta:
			m = F_ALL if present[slot] == 1 else 0
		elif present[slot] == 1 and baseline.present[slot] == 0:
			m = F_ALL
		elif present[slot] == 1:
			var o := slot * FIELDS
			for i in FIELDS:
				if ent[o + i] != baseline.ent[o + i]:
					m |= 1 << i
		elif baseline.present[slot] == 1:
			m = F_REMOVED
		masks[slot] = m
		if m != 0:
			recs += 1
			size += 2
			if m != F_REMOVED:
				for i in FIELDS:
					if m & (1 << i):
						size += FIELD_BYTES[i]
	var b := PackedByteArray()
	b.resize(size)
	b.encode_u8(0, KIND_DELTA if delta else KIND_FULL)
	b.encode_u16(1, snap_seq)
	b.encode_u32(3, server_tick)
	b.encode_u16(7, baseline.snap_seq if delta else snap_seq)
	b.encode_u32(9, ack_cmd_seq)
	b.encode_u8(13, flags)
	var p := HEADER_SIZE
	for i in f:
		b.encode_double(p, own[i])
		p += 8
	b.encode_u16(p, hud_acc)
	b.encode_s16(p + 2, hud_pp)
	b.encode_s16(p + 4, hud_py)
	b.encode_u8(p + 6, hud_ms)
	p += HUD_SIZE
	b.encode_u8(p, recs)
	p += 1
	for slot in MAX_SLOTS:
		var m2: int = masks[slot]
		if m2 == 0:
			continue
		b.encode_u8(p, slot)
		b.encode_u8(p + 1, m2)
		p += 2
		if m2 == F_REMOVED:
			continue
		var o2 := slot * FIELDS
		for i in FIELDS:
			if m2 & (1 << i):
				var v := ent[o2 + i]
				match i:
					E_X, E_Y, E_Z:
						b.encode_s16(p, v)
						p += 2
					E_YAW, E_PITCH:
						b.encode_u16(p, v)
						p += 2
					_:
						b.encode_u8(p, v)
						p += 1
	return b


## Decodes. Returns null on error and sets last_error. A delta needs its baseline (the
## snapshot whose snap_seq equals the header's base_seq); without it the packet is dropped.
static func decode(b: PackedByteArray, baseline: Snapshot = null) -> Snapshot:
	last_error = ""
	var f := own_count()
	var fixed := HEADER_SIZE + 8 * f + HUD_SIZE + 1
	if b.size() < fixed:
		last_error = "short"
		return null
	var k := b.decode_u8(0)
	if k != KIND_FULL and k != KIND_DELTA:
		last_error = "bad_kind"
		return null
	var s := Snapshot.new()
	s.kind = k
	s.snap_seq = b.decode_u16(1)
	s.server_tick = b.decode_u32(3)
	s.base_seq = b.decode_u16(7)
	s.ack_cmd_seq = b.decode_u32(9)
	s.flags = b.decode_u8(13)
	if k == KIND_DELTA:
		if baseline == null or baseline.snap_seq != s.base_seq:
			last_error = "missing_baseline"
			return null
		s.present = baseline.present.duplicate()
		s.ent = baseline.ent.duplicate()
	elif s.base_seq != s.snap_seq:
		last_error = "malformed"
		return null
	var p := HEADER_SIZE
	for i in f:
		s.own[i] = b.decode_double(p)
		p += 8
	s.hud_acc = b.decode_u16(p)
	s.hud_pp = b.decode_s16(p + 2)
	s.hud_py = b.decode_s16(p + 4)
	s.hud_ms = b.decode_u8(p + 6)
	p += HUD_SIZE
	var n := b.decode_u8(p)
	p += 1
	for r in n:
		if p + 2 > b.size():
			last_error = "malformed"
			return null
		var slot := b.decode_u8(p)
		var m := b.decode_u8(p + 1)
		p += 2
		if slot >= MAX_SLOTS or m == 0:
			last_error = "malformed"
			return null
		if m == F_REMOVED:
			s.present[slot] = 0
			for i in FIELDS:
				s.ent[slot * FIELDS + i] = 0
			continue
		if m & F_REMOVED:
			last_error = "malformed"
			return null
		if s.present[slot] == 0:
			if m != F_ALL:
				last_error = "malformed"
				return null
			s.present[slot] = 1
		var o := slot * FIELDS
		for i in FIELDS:
			if m & (1 << i):
				if p + FIELD_BYTES[i] > b.size():
					last_error = "malformed"
					return null
				match i:
					E_X, E_Y, E_Z:
						s.ent[o + i] = b.decode_s16(p)
					E_YAW, E_PITCH:
						s.ent[o + i] = b.decode_u16(p)
					_:
						s.ent[o + i] = b.decode_u8(p)
				p += FIELD_BYTES[i]
	if p != b.size():
		last_error = "malformed"
		return null
	return s


## Peek at the header without decoding (to find the baseline). Empty dictionary if too short.
static func peek(b: PackedByteArray) -> Dictionary:
	if b.size() < HEADER_SIZE:
		return {}
	return {"kind": b.decode_u8(0), "snap_seq": b.decode_u16(1), "base_seq": b.decode_u16(7)}
