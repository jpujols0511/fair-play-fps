class_name RingBuffer
extends RefCounted
## Fixed-size history of (seq, cmd, state after cmd). 256 entries (~2 s at 128 tick).
## State objects are preallocated and copied into, so pushing and replaying allocate nothing.

const SIZE := 256

var cmds: Array = []
var states: Array = []
var seqs: PackedInt64Array = PackedInt64Array()
var oldest := 1     # oldest seq still held
var newest := 0     # newest seq pushed (0 = none yet)
var overflows := 0  # times an unacknowledged entry was overwritten


func _init() -> void:
	cmds.resize(SIZE)
	states.resize(SIZE)
	seqs.resize(SIZE)
	for i in SIZE:
		states[i] = PlayerState.new()
		seqs[i] = -1


func count() -> int:
	return newest - oldest + 1


func has(seq: int) -> bool:
	return seq >= oldest and seq <= newest and seqs[seq & (SIZE - 1)] == seq


func push(seq: int, cmd: InputCmd, state: PlayerState) -> void:
	if count() >= SIZE:
		oldest += 1
		overflows += 1
	var i := seq & (SIZE - 1)
	seqs[i] = seq
	cmds[i] = cmd
	(states[i] as PlayerState).copy_from(state)
	newest = seq


func get_cmd(seq: int) -> InputCmd:
	return cmds[seq & (SIZE - 1)]


func get_state(seq: int) -> PlayerState:
	return states[seq & (SIZE - 1)]


## Forget everything up to and including seq (it has been confirmed by the server).
func drop_through(seq: int) -> void:
	if seq + 1 > oldest:
		oldest = mini(seq + 1, newest + 1)
