class_name SeqMath
extends RefCounted
## Command sequence numbers are u32 on the wire and wrap. Every comparison goes through diff(): the signed distance
## from b to a modulo 2^32 (positive = a is ahead of b, negative = a is behind, i.e. old or a duplicate).

const MASK := 0xFFFFFFFF
const HALF := 0x80000000


static func diff(a: int, b: int) -> int:
	var d := (a - b) & MASK
	return d - (MASK + 1) if d >= HALF else d


static func add(a: int, n: int) -> int:
	return (a + n) & MASK


## Bounded re-sync (CURRENT_DECISIONS CD-r7). After `idle_ticks` ticks without executing anything, a client that keeps its
## numbering can honestly be at most idle_ticks + burst seqs ahead of next_seq (one command per tick, plus the burst
## allowance). The new next_seq is the newest far-ahead seq seen if it is within that bound, otherwise next_seq plus the
## bound: never an arbitrary far-ahead value, so a forged 0xFFFFFFFF (or 0x7FFFFFFF) cannot strand the player.
static func resync_target(next_seq: int, far_latest: int, idle_ticks: int, burst: int) -> int:
	var allowed := idle_ticks + burst
	var d := diff(far_latest, next_seq)
	if d > 0 and d <= allowed:
		return far_latest
	return add(next_seq, allowed)
