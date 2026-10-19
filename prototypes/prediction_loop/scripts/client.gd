class_name Client
extends RefCounted
## Predicts its own player only. The server decides everything.
## tick step 3: predict(), step 4: reconcile(), step 5: smooth().

const FADE_TICKS := 13          # ~100 ms at 128 Hz
const SNAP_DISTANCE := 64.0     # bigger errors (or a teleport flag) snap instead of fading

var world: Array
var ring := RingBuffer.new()
var receiver := SnapshotReceiver.new()

# remote players (Phase 3)
var remotes: Array = []             # 16 InterpBuffer, indexed by slot
var remote_visible := PackedByteArray()
var clock_offset := 0.0             # server_tick_estimate(c) = c + clock_offset
var _clock_target := 0.0
var _clock_init := false
var cur_tick := 0
var render_tick := 0.0
var starved_log: Array = []         # [tick, slot] for every starved remote tick
var removed_tick := PackedInt32Array()   # per slot: server tick of the snapshot that removed it (-1 = never)

# NetClient hooks (Phase 4): called for the NEWEST decoded snapshot only / when a slot is removed
var mask_log: Array = []            # [server_tick, mask of present remotes] whenever the newest snapshot's mask changed
var on_newest: Callable = Callable()
var on_remote_removed: Callable = Callable()
# stats
var _rtt_acked_seq := 0                  # newest command seq that already gave an RTT sample
var sent_ticks := PackedInt32Array()      # client tick each command seq was sent (index seq & 255), for RTT
var rtt_ticks := -1.0                     # EWMA (alpha 0.125) of send -> acked-by-snapshot time, in ticks
var bytes_in := 0
var snapshots_seen := 0
var first_snap_seq := -1
var predicted := PlayerState.new()
var next_seq := 1
var acked_seq := 0
var _prev1: InputCmd = null
var _prev2: InputCmd = null
var _seen_teleport_gen := 0

# smoothing: visual = predicted + offset
var offset := Vector3.ZERO
var _fade_start := Vector3.ZERO
var _fade_left := 0
var visual := Vector3.ZERO
var _prev_visual := Vector3.ZERO
var step_delta := Vector3.ZERO      # this tick's own predicted motion
var snapped_now := false
var unexplained := 0.0              # |visual motion - predicted motion| this tick (S4)
var _flip_hist: Array = [PackedInt32Array(), PackedInt32Array()]
var max_flips := 0

# stats
var matches := 0
var corrections := 0
var stale_msgs := 0
var last_error := 0.0
var last_replay_len := 0
var reconcile_log: Array = []       # this tick: [N, error, corrected, ack_before]
var first_pred: Dictionary = {}     # seq -> PackedFloat64Array (debug oracle)
var keep_history := false


func _init(p_world: Array) -> void:
	world = p_world
	visual = _pos()
	for i in Snapshot.MAX_SLOTS:
		remotes.append(InterpBuffer.new(NetConfig.EXTRAP_MAX_TICKS))
	remote_visible.resize(Snapshot.MAX_SLOTS)
	removed_tick.resize(Snapshot.MAX_SLOTS)
	removed_tick.fill(-1)
	sent_ticks.resize(256)


func _pos() -> Vector3:
	return Vector3(predicted.pos_x, predicted.pos_y, predicted.pos_z)


## Step 3. Applies the input at once and returns the packet to send:
## {"cmds": current + previous 2, "ack_snap_seq": newest snapshot decoded (-1 = none)}.
func predict(buttons: int, yaw_q: int, pitch_q: int, tick: int) -> Dictionary:
	return predict_cmd(InputCmd.make(next_seq, tick, buttons, yaw_q, pitch_q))


## Same, from an InputCmd (the NetClient API). The client assigns seq (the cmd's own seq is ignored).
func predict_cmd(cmd: InputCmd) -> Dictionary:
	cur_tick = cmd.tick
	cmd.seq = next_seq
	sent_ticks[cmd.seq & 255] = cmd.tick
	var before := _pos()
	Movement.step(predicted, cmd, world)
	step_delta = _pos() - before
	ring.push(cmd.seq, cmd, predicted)
	if keep_history:
		first_pred[cmd.seq] = predicted.to_packed()
	var cmds: Array = []
	if _prev2 != null: cmds.append(_prev2)
	if _prev1 != null: cmds.append(_prev1)
	cmds.append(cmd)
	_prev2 = _prev1
	_prev1 = cmd
	next_seq += 1
	return {"cmds": cmds, "ack_snap_seq": receiver.newest_seq}


## Step 4. msgs: snapshot byte packets that arrived this tick, oldest first. Each is decoded
## against the ring of snapshots already decoded (a delta without its baseline is dropped and
## counted). Only a snapshot that is the newest so far feeds reconcile; an older one is decoded
## (the interpolation buffer wants it) but never rolls own-player state back.
func reconcile(msgs: Array) -> void:
	var states: Array = []
	for bytes in msgs:
		bytes_in += bytes.size()
		var s := receiver.receive(bytes)
		if s == null:
			continue
		snapshots_seen += 1
		if first_snap_seq < 0:
			first_snap_seq = s.snap_seq
		var newest := receiver.is_newest(s)
		_ingest_remotes(s, newest)
		if newest:
			var pm := 0
			for k in Snapshot.MAX_SLOTS:
				pm |= s.present[k] << k
			if (mask_log.is_empty() or mask_log[mask_log.size() - 1][1] != pm) and mask_log.size() < 20000:
				mask_log.append([s.server_tick, pm])
			# one RTT sample per command: a repeated ack of the same command is ignored, and so is an ack more than 255 commands
			# old (its slot in the 256-entry send-tick table has been reused)
			if s.ack_cmd_seq > 0 and ring.newest >= s.ack_cmd_seq and s.ack_cmd_seq > _rtt_acked_seq and ring.newest - s.ack_cmd_seq < 256:
				_rtt_acked_seq = s.ack_cmd_seq
				var sample := float(cur_tick - sent_ticks[s.ack_cmd_seq & 255])
				rtt_ticks = sample if rtt_ticks < 0.0 else rtt_ticks + 0.125 * (sample - rtt_ticks)
			if on_newest.is_valid():
				on_newest.call(s)
			_clock_target = float(s.server_tick) - float(cur_tick)
			if not _clock_init:
				clock_offset = _clock_target
				_clock_init = true
			states.append({"last_seq": s.ack_cmd_seq, "state": PlayerState.from_packed(s.own)})
	reconcile_states(states)


## Feeds the entities of a decoded snapshot into the per-slot interpolation buffers. Older
## snapshots add samples too; only the newest one can remove a slot (REMOVED / not sent).
func _ingest_remotes(s: Snapshot, newest: bool) -> void:
	for slot in Snapshot.MAX_SLOTS:
		var b: InterpBuffer = remotes[slot]
		if s.present[slot] == 1:
			if s.server_tick <= removed_tick[slot]:
				continue            # a late older snapshot must not bring a removed player back
			var o := slot * Snapshot.FIELDS
			var sa := s.ent[o + Snapshot.E_SA]
			b.insert(s.server_tick, Quant.q_to_pos(s.ent[o]), Quant.q_to_pos(s.ent[o + 1]), Quant.q_to_pos(s.ent[o + 2]),
				s.ent[o + Snapshot.E_YAW], s.ent[o + Snapshot.E_PITCH], sa & 3, (sa >> 2) & 1, b.is_empty(), Quant.q_to_duck(s.ent[o + Snapshot.E_DUCK]))
		elif newest and not b.is_empty():
			b.remove()
			removed_tick[slot] = s.server_tick
			if on_remote_removed.is_valid():
				on_remote_removed.call(slot)


## Step 5 (after smooth): move the clock and draw every remote at render_tick.
func update_remotes(tick: int) -> void:
	if _clock_init:
		if absf(_clock_target - clock_offset) > 8.0:
			clock_offset = _clock_target
		else:
			clock_offset += clampf(_clock_target - clock_offset, -0.0625, 0.0625)
	render_tick = float(tick) + clock_offset - NetConfig.INTERP_TICKS
	for slot in Snapshot.MAX_SLOTS:
		var b: InterpBuffer = remotes[slot]
		var vis := b.sample(render_tick) if not b.is_empty() else false
		remote_visible[slot] = 1 if vis else 0
		if vis and b.out_starved:
			starved_log.append([tick, slot])


## Reconcile against already-decoded server states: [{"last_seq": N, "state": PlayerState}, ...].
func reconcile_states(msgs: Array) -> void:
	reconcile_log.clear()
	if msgs.is_empty():
		return
	var visual_before := _pos() + offset
	var corrected_any := false
	var snap := false
	for m in msgs:
		var n: int = m["last_seq"]
		if n <= acked_seq or n > ring.newest or not ring.has(n):
			stale_msgs += 1
			continue
		var server_state: PlayerState = m["state"]
		var ack_before := acked_seq
		var err := 0.0
		var corrected := false
		if not ring.get_state(n).equals(server_state):
			err = ring.get_state(n).distance_to(server_state)
			_replay_from(n, server_state)
			corrected = true
			corrected_any = true
			corrections += 1
			if server_state.teleport_gen != _seen_teleport_gen:
				snap = true
				_seen_teleport_gen = server_state.teleport_gen
		else:
			matches += 1
		ring.drop_through(n)
		acked_seq = n
		last_error = err
		reconcile_log.append([n, err, corrected, ack_before])
	if corrected_any:
		offset = visual_before - _pos()
		if snap or offset.length() > SNAP_DISTANCE:
			offset = Vector3.ZERO
			_fade_left = 0
			snapped_now = true
		else:
			_fade_start = offset
			_fade_left = FADE_TICKS


## Reset to the server state for N, then replay every stored command after N.
func _replay_from(n: int, server_state: PlayerState) -> void:
	predicted.copy_from(server_state)
	var len := 0
	for seq in range(n + 1, ring.newest + 1):
		Movement.step(predicted, ring.get_cmd(seq), world)
		ring.get_state(seq).copy_from(predicted)
		len += 1
	last_replay_len = len


## Step 5. The visual follows the simulated position the same tick; only the correction fades.
func smooth() -> void:
	if _fade_left > 0:
		_fade_left -= 1
		offset = _fade_start * (float(_fade_left) / float(FADE_TICKS))
	_prev_visual = visual
	visual = _pos() + offset
	unexplained = 0.0 if snapped_now else ((visual - _prev_visual) - step_delta).length()
	snapped_now = false
	_track_flips()


func _track_flips() -> void:
	var worst := 0
	for a in 2:
		var c := offset.x if a == 0 else offset.z
		var sgn := 0
		if c > 0.01: sgn = 1
		elif c < -0.01: sgn = -1
		var h: PackedInt32Array = _flip_hist[a]
		if sgn != 0:
			h.append(sgn)
			if h.size() > FADE_TICKS:
				h.remove_at(0)
		var flips := 0
		for i in range(1, h.size()):
			if h[i] != h[i - 1]:
				flips += 1
		worst = maxi(worst, flips)
	max_flips = maxi(max_flips, worst)
