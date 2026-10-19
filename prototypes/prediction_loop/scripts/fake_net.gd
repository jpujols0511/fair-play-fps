class_name FakeNet
extends RefCounted
## Two one-way channels (client->server, server->client) with delay, seeded random drop
## and optional jitter. Time is in milliseconds of tick time (tick * 1000 / 128).
## A packet is handed over on the first tick whose time is at or after its due time, so a
## 40 ms hop is really 6 ticks (46.9 ms) at 128 Hz.
## Drop and jitter use separate seeded generators per channel, so turning jitter on does
## not change which packets are dropped, and a 10% run drops a superset of a 2% run.

const C2S := 0
const S2C := 1

var one_way_ms := 40.0
var loss := 0.02
var jitter_on := false          # OFF by default (locked): turned on for the S4 playtest
var jitter_ms := 5.0

var _drop_rng: Array = [RandomNumberGenerator.new(), RandomNumberGenerator.new()]
var _jit_rng: Array = [RandomNumberGenerator.new(), RandomNumberGenerator.new()]
var _queue: Array = [[], []]    # per channel: [due_ms, order, payload]
var _order := 0

var sent := PackedInt64Array([0, 0])
var dropped := PackedInt64Array([0, 0])
var delivered := PackedInt64Array([0, 0])
var drop_log: Array = [[], []]      # send times (ms) of dropped packets, per channel


func _init(seed_value: int = 1, ping_ms: float = 80.0, p_loss: float = 0.02, p_jitter_on: bool = false) -> void:
	configure(seed_value, ping_ms, p_loss, p_jitter_on)


func configure(seed_value: int, ping_ms: float, p_loss: float, p_jitter_on: bool) -> void:
	one_way_ms = ping_ms / 2.0
	loss = p_loss
	jitter_on = p_jitter_on
	for ch in 2:
		(_drop_rng[ch] as RandomNumberGenerator).seed = seed_value * 4 + ch
		(_jit_rng[ch] as RandomNumberGenerator).seed = seed_value * 4 + 2 + ch


func send(channel: int, payload: Variant, now_ms: float) -> void:
	sent[channel] += 1
	var r: float = (_drop_rng[channel] as RandomNumberGenerator).randf()
	var j := 0.0
	if jitter_on:
		j = (_jit_rng[channel] as RandomNumberGenerator).randf_range(-jitter_ms, jitter_ms)
	if r < loss:
		dropped[channel] += 1
		(drop_log[channel] as Array).append(now_ms)
		return
	_order += 1
	(_queue[channel] as Array).append([now_ms + maxf(one_way_ms + j, 0.0), _order, payload])


## Payloads due at or before now_ms, oldest due time first.
func deliver(channel: int, now_ms: float) -> Array:
	var q: Array = _queue[channel]
	var out: Array = []
	var keep: Array = []
	for e in q:
		if e[0] <= now_ms:
			out.append(e)
		else:
			keep.append(e)
	_queue[channel] = keep
	out.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var payloads: Array = []
	for e in out:
		payloads.append(e[2])
	delivered[channel] += payloads.size()
	return payloads
