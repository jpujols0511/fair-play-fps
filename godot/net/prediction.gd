extends RefCounted
## Client-side prediction and reconciliation for the local player only
## (decision 0001, integration stage 3).
##
## The client runs the same kernel code as the server on its own intents, so
## it can show movement and ammunition before the server confirms them. Each
## server snapshot replaces the prediction: the client restarts from the
## confirmed state and replays the intents the server has not applied yet.
## The server stays the only authority (invariant 1). A prediction is a
## guess the client draws; it never travels to the server.
##
## A correction is a snapshot whose state differs from what the client had
## predicted for that same intent. With no lost or late input the kernel is
## deterministic, so honest play predicts exactly; corrections come from the
## server applying a neutral tick the client did not foresee, or dropping an
## intent. The first snapshot only sets the starting state: the server drops
## intents sent before the match starts.

const Kernel = preload("res://kernel/fairplay_kernel.gd")
const COMPARED := ["x", "y", "velocity_x", "velocity_y", "yaw_millidegrees", "health",
	"ammunition", "next_fire_tick"]

var player_id: String
var tick_rate: int
var pending := {}    # sequence -> intent sent but not yet confirmed
var predicted := {}  # sequence -> predicted state right after that intent
var confirmed_tick := -1
var confirmed := 0   # snapshots that confirmed an intent we had predicted
var corrections := 0
var max_error := 0   # largest position error at a correction, in kernel units
var _live          # kernel holding the current prediction


func _init(p_player_id: String, p_tick_rate: int) -> void:
	player_id = p_player_id
	tick_rate = p_tick_rate
	_live = Kernel.new([player_id], tick_rate)


## The intent just sent: apply it to the prediction straight away.
func send(cmd: Dictionary) -> void:
	pending[cmd["sequence"]] = cmd
	_apply(cmd)


## A server snapshot: compare, forget what it confirms, replay the rest.
## Older or duplicate snapshots (UDP) are ignored.
func reconcile(snapshot: Dictionary) -> void:
	if snapshot["tick"] <= confirmed_tick:
		return
	var first := confirmed_tick < 0
	confirmed_tick = snapshot["tick"]
	var last: int = snapshot["last_sequence"]
	if not first and predicted.has(last):
		confirmed += 1
		var guess: Dictionary = predicted[last]
		for key in COMPARED:
			if guess[key] != snapshot[key]:
				corrections += 1
				max_error = maxi(max_error, absi(guess["x"] - snapshot["x"]) + absi(guess["y"] - snapshot["y"]))
				break
	for sequence in pending.keys():
		if sequence <= last:
			pending.erase(sequence)
	predicted.clear()
	_live = Kernel.new([player_id], tick_rate)
	_live.tick = snapshot["tick"]
	_live.restore_snapshot(player_id, snapshot)
	var sequences: Array = pending.keys()
	sequences.sort()
	for sequence in sequences:
		_apply(pending[sequence])


## What the client draws now: confirmed state plus unconfirmed intents.
func display() -> Dictionary:
	return _live.players[player_id]


func report() -> Dictionary:
	return {"confirmed": confirmed, "corrections": corrections, "max_error": max_error,
		"unconfirmed": pending.size()}


func _apply(cmd: Dictionary) -> void:
	_live.submit(player_id, cmd)
	_live.step()
	predicted[cmd["sequence"]] = _live.players[player_id].duplicate()
