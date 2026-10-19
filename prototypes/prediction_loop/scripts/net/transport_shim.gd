class_name TransportShim
extends RefCounted
## Wraps any transport with the FakeNet delay / loss / jitter (seeded), so automated tests can run
## 80 ms / 2% over REAL sockets without root. The caller sets now_ms each tick (tick * 1000 / 128);
## a packet is delivered on the first tick whose time is at or after its due time, so a 40 ms hop is
## 6 ticks (46.875 ms), exactly like FakeNet. Both directions are shimmed on the side that owns it.
## Client use: send(bytes) / poll(). Server use: send_to(id, bytes) / poll() -> [id, bytes] pairs.

var inner                                    # TransportEnet or TransportUdp
var now_ms := 0.0
var one_way_ms := 40.0
var loss := 0.02
var jitter_ms := 0.0
var _drop := RandomNumberGenerator.new()
var _jit := RandomNumberGenerator.new()
var _out_q: Array = []                       # [due_ms, order, peer_id or -1, bytes]
var _in_q: Array = []
var _order := 0
var dropped := 0
var passed := 0


func _init(p_inner, p_seed: int = 1, ping_ms: float = 80.0, p_loss: float = 0.02, p_jitter_ms: float = 0.0) -> void:
	inner = p_inner
	one_way_ms = ping_ms / 2.0
	loss = p_loss
	jitter_ms = p_jitter_ms
	_drop.seed = p_seed * 4 + 100
	_jit.seed = p_seed * 4 + 101


func _admit(q: Array, peer_id: int, bytes: PackedByteArray) -> void:
	var r := _drop.randf()
	var j := _jit.randf_range(-jitter_ms, jitter_ms) if jitter_ms > 0.0 else 0.0
	if r < loss:
		dropped += 1
		return
	passed += 1
	_order += 1
	q.append([now_ms + maxf(one_way_ms + j, 0.0), _order, peer_id, bytes])


func send(bytes: PackedByteArray) -> void:
	_admit(_out_q, -1, bytes)


func send_to(peer_id: int, bytes: PackedByteArray) -> void:
	_admit(_out_q, peer_id, bytes)


func _due(q: Array) -> Array:
	var due: Array = []
	var keep: Array = []
	for e in q:
		if e[0] <= now_ms:
			due.append(e)
		else:
			keep.append(e)
	q.clear()
	q.append_array(keep)
	due.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	return due


## Pump the inner socket, then deliver what is due. Client: Array of bytes. Server: Array of [id, bytes].
func poll() -> Array:
	# outgoing first: anything due goes to the real socket now
	for e in _due(_out_q):
		if e[2] < 0:
			inner.send(e[3])
		else:
			inner.send_to(e[2], e[3])
	# incoming: everything the socket has is admitted into the delay line
	for item in inner.poll():
		if item is Array:
			_admit(_in_q, item[0], item[1])
		else:
			_admit(_in_q, -1, item)
	var out: Array = []
	for e in _due(_in_q):
		if e[2] < 0:
			out.append(e[3])
		else:
			out.append([e[2], e[3]])
	return out


func close() -> void:
	inner.close()
