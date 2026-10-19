class_name Packet
extends RefCounted
## Wire packets (specs/snapshot_format_v0.1.md "Packets", PROPOSED). Every datagram starts with
## protocol_id u32 = 0x31465046 ("FPF1" little-endian) and msg u8. Little-endian, byte-aligned.
##   1 HELLO    (c->s): protocol_version u16 = 1, tick_rate u16 = 128, cookie u32 (0 on the first try), kernel_sha256 32 bytes (ALL ZERO placeholder)
##   6 CHALLENGE (s->c): cookie u32 = first 4 bytes of sha256(server secret || peer address). The server keeps NO state for a HELLO whose
##                      cookie is wrong and answers with these 9 bytes only (smaller than the HELLO: nothing to reflect or amplify).
##   2 WELCOME  (s->c): slot u8, server_tick u32, interp_ticks u8 (C1: the SERVER dictates it), snapshot_every u8 (C4)
##   3 INPUT    (c->s): ack_snap_seq u16, ack_delay_ticks u8, cmd_count u8 (1..3), then per command 19 bytes:
##                      seq u32, tick u32, buttons u8, yaw_q u16, pitch_q u16, view_tick u32, view_tick_frac u16
##   4 SNAPSHOT (s->c): the snapshot bytes (snapshot_format_v0.1)
##   5 BYE      (either): none
## INPUT with 3 commands = 5 + 4 + 57 = 66 bytes. No datagram may exceed 1,200 bytes.

const PROTOCOL_ID := 0x31465046
const PROTOCOL_VERSION := 1
const MAX_DATAGRAM := 1200
const HEADER := 5

const MSG_HELLO := 1
const MSG_WELCOME := 2
const MSG_INPUT := 3
const MSG_SNAPSHOT := 4
const MSG_BYE := 5
const MSG_CHALLENGE := 6

const CMD_BYTES := 19
const MAX_CMDS := 3
const HELLO_SIZE := 5 + 2 + 2 + 4 + 32
const CHALLENGE_SIZE := 5 + 4
const WELCOME_SIZE := 5 + 1 + 4 + 1 + 1

## Counters for the "dropped and counted" rule (reset by the caller).
static var malformed := 0
static var oversize_refused := 0


static func _header(b: PackedByteArray, msg: int) -> void:
	b.encode_u32(0, PROTOCOL_ID)
	b.encode_u8(4, msg)


static func encode_hello(tick_rate: int = 128, cookie: int = 0) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(HELLO_SIZE)
	_header(b, MSG_HELLO)
	b.encode_u16(5, PROTOCOL_VERSION)
	b.encode_u16(7, tick_rate)
	b.encode_u32(9, cookie)
	return b          # kernel_sha256 stays 32 zero bytes until reconciliation item 5 is decided


static func encode_challenge(cookie: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(CHALLENGE_SIZE)
	_header(b, MSG_CHALLENGE)
	b.encode_u32(5, cookie)
	return b


static func encode_welcome(slot: int, server_tick: int, interp_ticks: int, snapshot_every: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(WELCOME_SIZE)
	_header(b, MSG_WELCOME)
	b.encode_u8(5, slot)
	b.encode_u32(6, server_tick)
	b.encode_u8(10, interp_ticks)
	b.encode_u8(11, snapshot_every)
	return b


static func encode_bye() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(HEADER)
	_header(b, MSG_BYE)
	return b


static func encode_snapshot(snap_bytes: PackedByteArray) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(HEADER)
	_header(b, MSG_SNAPSHOT)
	b.append_array(snap_bytes)
	return b


## cmds: 1 to 3 InputCmd, oldest first.
static func encode_input(ack_snap_seq: int, ack_delay_ticks: int, cmds: Array) -> PackedByteArray:
	var n := cmds.size()
	var b := PackedByteArray()
	b.resize(HEADER + 4 + CMD_BYTES * n)
	_header(b, MSG_INPUT)
	b.encode_u16(5, ack_snap_seq & 0xFFFF)
	b.encode_u8(7, clampi(ack_delay_ticks, 0, 255))
	b.encode_u8(8, n)
	var p := HEADER + 4
	for c: InputCmd in cmds:
		b.encode_u32(p, c.seq)
		b.encode_u32(p + 4, c.tick)
		b.encode_u8(p + 8, c.buttons)
		b.encode_u16(p + 9, c.yaw_q)
		b.encode_u16(p + 11, c.pitch_q)
		var whole := floorf(c.view_tick)
		b.encode_u32(p + 13, int(whole))
		b.encode_u16(p + 17, mini(int(roundf((c.view_tick - whole) * 65536.0)), 65535))
		p += CMD_BYTES
	return b


## Parses any datagram. Returns {} (and counts it) when it is malformed; otherwise {"msg": int, ...}.
## Unknown protocol id, wrong size, cmd_count over 3 or an unknown message are all malformed.
static func parse(b: PackedByteArray) -> Dictionary:
	if b.size() < HEADER or b.size() > MAX_DATAGRAM or b.decode_u32(0) != PROTOCOL_ID:
		malformed += 1
		return {}
	var msg := b.decode_u8(4)
	match msg:
		MSG_HELLO:
			if b.size() != HELLO_SIZE:
				malformed += 1
				return {}
			return {"msg": msg, "version": b.decode_u16(5), "tick_rate": b.decode_u16(7), "cookie": b.decode_u32(9), "kernel_sha256": b.slice(13, 45)}
		MSG_WELCOME:
			if b.size() != WELCOME_SIZE:
				malformed += 1
				return {}
			return {"msg": msg, "slot": b.decode_u8(5), "server_tick": b.decode_u32(6), "interp_ticks": b.decode_u8(10), "snapshot_every": b.decode_u8(11)}
		MSG_INPUT:
			if b.size() < HEADER + 4:
				malformed += 1
				return {}
			var n := b.decode_u8(8)
			if n < 1 or n > MAX_CMDS or b.size() != HEADER + 4 + CMD_BYTES * n:
				malformed += 1
				return {}
			var cmds: Array = []
			var p := HEADER + 4
			for i in n:
				var c := InputCmd.make(b.decode_u32(p), b.decode_u32(p + 4), b.decode_u8(p + 8), b.decode_u16(p + 9), b.decode_u16(p + 11))
				c.view_tick = float(b.decode_u32(p + 13)) + float(b.decode_u16(p + 17)) / 65536.0
				cmds.append(c)
				p += CMD_BYTES
			return {"msg": msg, "ack_snap_seq": b.decode_u16(5), "ack_delay_ticks": b.decode_u8(7), "cmds": cmds}
		MSG_SNAPSHOT:
			if b.size() <= HEADER:
				malformed += 1
				return {}
			return {"msg": msg, "snapshot": b.slice(HEADER)}
		MSG_CHALLENGE:
			if b.size() != CHALLENGE_SIZE:
				malformed += 1
				return {}
			return {"msg": msg, "cookie": b.decode_u32(5)}
		MSG_BYE:
			if b.size() != HEADER:
				malformed += 1
				return {}
			return {"msg": msg}
	malformed += 1
	return {}


## True if the datagram may be sent (<= 1,200 bytes); otherwise refuses and counts it.
static func may_send(b: PackedByteArray) -> bool:
	if b.size() > MAX_DATAGRAM:
		oversize_refused += 1
		return false
	return true
