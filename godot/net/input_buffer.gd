extends RefCounted
## Per-player jitter buffer (decision 0002), shared by every server transport.
##
## Intents wait here and are released one per tick in sequence order. After
## the initial fill (`primed`), a gap waits while the buffer is shallow and is
## skipped once it is deeper than the target. A buffer more than
## 2 * target + 4 behind drops its oldest intents so latency stays bounded.
## Release never depends on send rate: one command per player per tick.

const MAX_BUFFER := 64

var target: int
var pending := {}   # player_id -> {sequence: command}
var counters := {}  # player_id -> buffer counts reported in result.json


func _init(player_ids: Array, jitter_ticks: int) -> void:
	target = clampi(jitter_ticks, 0, MAX_BUFFER / 2)
	for player_id in player_ids:
		pending[player_id] = {}
		counters[player_id] = {"underruns": 0, "late": 0, "trimmed": 0, "duplicate": 0,
			"overflow": 0, "max_depth": 0}


func primed() -> bool:
	return pending.values().all(func(queue): return queue.size() >= target)


## Before the first tick: keeps only each player's newest `count` intents so a
## player who connected early does not start the match with extra latency.
## Returns how many were dropped.
func keep_newest(count: int) -> int:
	var dropped := 0
	for queue in pending.values():
		var sequences: Array = queue.keys()
		sequences.sort()
		while sequences.size() > count:
			queue.erase(sequences.pop_front())
			dropped += 1
	return dropped


func add(player_id: String, cmd: Dictionary) -> void:
	var queue: Dictionary = pending[player_id]
	var counts: Dictionary = counters[player_id]
	if queue.has(cmd["sequence"]):
		counts["duplicate"] += 1
	elif queue.size() >= MAX_BUFFER:
		counts["overflow"] += 1
	else:
		queue[cmd["sequence"]] = cmd
		counts["max_depth"] = maxi(counts["max_depth"], queue.size())


## For each player in sorted order:
## 1. If the buffer is far behind, drop the oldest intents.
## 2. Submit intents the kernel has already passed. They are recorded as
##    stale_input, which never counts toward suspicion.
## 3. Submit the next intent if it is the first, next in sequence, or the
##    buffer is deeper than the target (a gap that waiting will not fill).
## Otherwise it is an underrun: the kernel applies a neutral tick and consumes
## no sequence number, so the late intent still counts when it arrives.
## Returns the submits in order for the demo log.
func release(kernel) -> Array:
	var submits: Array = []
	var ids: Array = pending.keys()
	ids.sort()
	for player_id in ids:
		var queue: Dictionary = pending[player_id]
		var counts: Dictionary = counters[player_id]
		var last: int = kernel.players[player_id]["last_sequence"]
		var sequences: Array = queue.keys()
		sequences.sort()
		while sequences.size() > 2 * target + 4:
			queue.erase(sequences.pop_front())
			counts["trimmed"] += 1
		while not sequences.is_empty() and sequences[0] <= last:
			var stale: Dictionary = queue[sequences[0]]
			queue.erase(sequences.pop_front())
			kernel.submit(player_id, stale)
			submits.append([player_id, stale])
			counts["late"] += 1
		if not sequences.is_empty() and (last < 0 or sequences[0] == last + 1 or sequences.size() > target):
			var cmd: Dictionary = queue[sequences[0]]
			queue.erase(sequences[0])
			kernel.submit(player_id, cmd)
			submits.append([player_id, cmd])
		else:
			counts["underruns"] += 1
	return submits
