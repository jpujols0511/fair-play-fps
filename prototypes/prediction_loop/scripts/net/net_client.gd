class_name NetClient
extends Node
## The one client-side network object the HUD and every other client system read from.
##
## HUD interface, exactly as the crosshair spec note (f) defines it:
##   signal snapshot_received(snap: Dictionary)      emitted once per NEWEST decoded snapshot
##   func get_latest() -> Dictionary                 {} until the first snapshot, then the 5 keys below
## Keys: server_tick (int), accuracy (float), punch_pitch (float, deg, + = up), punch_yaw (float, deg),
## move_state (int: 0 stand, 1 crouch, 2 air, 3 run). Values are the dequantized WIRE values (what the
## wire carries, nothing recomputed), straight from the own-player HUD block, never through the
## interpolation buffer. A late older snapshot updates the interpolation buffer but does not emit.
##
## Rest of the API (PROPOSED names): send_input(cmd), get_player_state(), get_visual_position(),
## get_remote_players(), get_render_tick() (seam D8), get_stats(), signal remote_removed(slot).
##
## Two ways to build it:
##   * standalone:  var nc := NetClient.new(); nc.setup(world, endpoint)  -> owns its Client and talks to the
##     endpoint with send(payload) / poll(). This is what a real client process does (Phase 6).
##   * adopt:  nc.adopt(session.client)  -> reads the Client that an in-process Session drives.

signal snapshot_received(snap: Dictionary)
signal remote_removed(slot: int)

var client: Client
var endpoint = null                # FakeEndpoint (in process) or NetEndpoint (real transport): send(payload) / poll()
var _latest: Dictionary = {}
var stale_snapshots := 0


func setup(world: Array, p_endpoint) -> void:
	endpoint = p_endpoint
	adopt(Client.new(world))


func adopt(p_client: Client) -> void:
	client = p_client
	client.on_newest = _on_newest
	client.on_remote_removed = _on_remote_removed


func _on_newest(s: Snapshot) -> void:
	_latest = {
		"server_tick": s.server_tick,
		"accuracy": Quant.q_to_accuracy(s.hud_acc),
		"punch_pitch": Quant.q_to_angle(s.hud_pp),
		"punch_yaw": Quant.q_to_angle(s.hud_py),
		"move_state": s.hud_ms,
	}
	snapshot_received.emit(_latest)


func _on_remote_removed(slot: int) -> void:
	remote_removed.emit(slot)


func get_latest() -> Dictionary:
	return _latest


## Standalone mode: predict this command now and send it. The client numbers the commands itself.
func send_input(cmd: InputCmd) -> void:
	if cmd.view_tick == 0.0:
		cmd.view_tick = maxf(client.render_tick, 0.0)       # seam D8: the claimed view time travels with the command
	endpoint.send(client.predict_cmd(cmd))


## Standalone mode, tick order steps 4 and 5: reconcile against what arrived, then smooth and draw remotes.
func poll_and_update(tick: int) -> void:
	client.reconcile(endpoint.poll())
	client.smooth()
	client.update_remotes(tick)


func get_player_state() -> PlayerState:
	return client.predicted


## Smoothed position of the own player (what the camera follows): [x, y, z].
func get_visual_position() -> PackedFloat64Array:
	return PackedFloat64Array([client.visual.x, client.visual.y, client.visual.z])


## Remote players drawn at get_render_tick(): Array of {slot, x, y, z, yaw, pitch, stance, duck, alive}; "duck" is the smooth crouch fraction 0.0..1.0 (draw the model and hitbox from it).
func get_remote_players() -> Array:
	var out: Array = []
	for slot in Snapshot.MAX_SLOTS:
		if client.remote_visible[slot] == 1:
			var b: InterpBuffer = client.remotes[slot]
			out.append({"slot": slot, "x": b.out_x, "y": b.out_y, "z": b.out_z, "yaw": b.out_yaw, "pitch": b.out_pitch,
				"stance": b.out_stance, "duck": b.out_duck, "alive": b.out_alive == 1})
	return out


## Fractional server tick the client is drawing remote players at (seam D8; feeds claimed_view_tick, Phase 7).
func get_render_tick() -> float:
	return client.render_tick


func get_stats() -> Dictionary:
	var seconds := maxf(float(client.cur_tick), 1.0) / Movement.TICK_RATE
	var expected := 0
	if client.first_snap_seq >= 0 and client.receiver.newest_seq >= 0:
		expected = ((client.receiver.newest_seq - client.first_snap_seq) & 0xFFFF) + 1
	var starved := 0
	for b: InterpBuffer in client.remotes:
		starved += b.starved_ticks
	return {
		"rtt_ms": client.rtt_ticks * 1000.0 / Movement.TICK_RATE if client.rtt_ticks >= 0.0 else -1.0,
		"snapshot_loss": 1.0 - float(client.snapshots_seen) / float(maxi(expected, 1)),
		"corrections": client.corrections,
		"starved_ticks": starved,
		"bytes_per_s": float(client.bytes_in) / seconds,
		"snapshots": client.snapshots_seen,
		"dropped_missing_baseline": client.receiver.dropped_missing_baseline,
	}
