class_name SnapshotReceiver
extends RefCounted
## Client side: decodes snapshot bytes against the ring of snapshots it already decoded.
## A delta whose baseline it does not have is DROPPED and COUNTED, never guessed; the next
## full (or a delta against something it has) recovers. Older-than-newest snapshots are
## decoded and returned (the interpolation buffer wants them) but newest_seq never goes back.

var ring := BaselineRing.new()
var newest_seq := -1          # what the client acks
var decoded := 0
var dropped_missing_baseline := 0
var dropped_malformed := 0


## Returns the decoded Snapshot, or null if the packet was dropped.
func receive(bytes: PackedByteArray) -> Snapshot:
	var h := Snapshot.peek(bytes)
	if h.is_empty():
		dropped_malformed += 1
		return null
	var base: Snapshot = null
	if h["kind"] == Snapshot.KIND_DELTA:
		base = ring.get_snap(h["base_seq"])
	var s := Snapshot.decode(bytes, base)
	if s == null:
		if Snapshot.last_error == "missing_baseline":
			dropped_missing_baseline += 1
		else:
			dropped_malformed += 1
		return null
	ring.store(s)
	decoded += 1
	if newest_seq < 0 or Snapshot.seq_newer(s.snap_seq, newest_seq):
		newest_seq = s.snap_seq
	return s


func is_newest(s: Snapshot) -> bool:
	return s.snap_seq == newest_seq
