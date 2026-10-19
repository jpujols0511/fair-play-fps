class_name BaselineRing
extends RefCounted
## The last N snapshots, keyed by snap_seq (N = NetConfig.BASELINE_RING, default 32).
## Used on the server (snapshots as sent, per client) and on the client (decoded snapshots).
## Preallocated and overwritten: storing allocates nothing. N must divide 65536 so the
## index stays right across the u16 sequence wrap.

var size := 32
var snaps: Array = []
var seqs: PackedInt32Array = PackedInt32Array()


func _init(p_size: int = -1) -> void:
	size = NetConfig.BASELINE_RING if p_size < 0 else p_size
	assert(65536 % size == 0)
	snaps.resize(size)
	seqs.resize(size)
	for i in size:
		snaps[i] = Snapshot.new()
		seqs[i] = -1


func store(s: Snapshot) -> void:
	var i := s.snap_seq % size
	(snaps[i] as Snapshot).copy_from(s)
	seqs[i] = s.snap_seq


## The stored snapshot with this snap_seq, or null if it was never stored or has been overwritten.
func get_snap(seq: int) -> Snapshot:
	var i := seq % size
	if seqs[i] == seq:
		return snaps[i]
	return null
