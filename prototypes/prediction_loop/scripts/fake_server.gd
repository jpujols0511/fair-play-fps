class_name FakeServer
extends RefCounted
## Authoritative side. Runs each command sequence number exactly once, in order, through
## the same Movement.step the client predicts with.
## - Every received packet (current command + previous 2) fills a pending table by seq.
## - Each server tick it executes every consecutive command it has (a burst is normal after
##   a late or dropped packet: the resulting state for a given seq does not depend on when
##   it ran), paid for from the per-client budget (NetConfig.CMD_BURST, refilling CMD_REFILL per tick).
## - If the next seq is missing but a newer packet has arrived, all 3 copies were lost:
##   it repeats the last command in that slot and counts it (lost_seqs).
## - Every NetConfig.SNAPSHOT_EVERY_TICKS ticks (default 2 = 64/sec) it builds a real snapshot
##   (Phase 2: full or delta against the client's ack) and returns the bytes.

var world: Array
var state := PlayerState.new()
var next_seq := 1
var highest_recv := 0
var last_cmd: InputCmd = InputCmd.make(0, 0, 0, 0, 0)
var pending: Dictionary = {}
var sender := SnapshotSender.new()
var remotes: Array = []            # RemotePath entities (Phase 3), slots 1..15; never predicted by the client

# visibility culling v0 (Phase 5, specs/visibility_culling_v0.md). Off by default so the earlier gates see every remote.
var vis_enabled := false
var vis_rtt_ms := 80.0             # the viewer's measured round trip; feeds the look-ahead (C9)
var viewer_team := 1
var vis_history := Visibility.History.new(NetConfig.SENT_MASK_HISTORY_TICKS)
var evidence := EvidenceSink.new()
var snapshot_tap: Callable = Callable()   # tests: called with every snapshot's bytes as sent
var _logged_mask := -1
var _chain := PackedByteArray()     # running sha256 chain over every snapshot sent

var lost_seqs: Array = []          # seqs that were filled by repeating the last command
var disturbances: Array = []       # first seq affected by a lost command or a forced move
var executed_total := 0
var rate_flags := 0                # packets whose cmd claimed a different tick_hz
var keep_history := false
var history: Dictionary = {}       # seq -> PackedFloat64Array (debug oracle)
var executed_now: Array = []       # seqs executed on the latest tick
var tokens := NetConfig.CMD_BURST   # command budget (CD-r2): executing one command costs 1.0
var slot_id := 0                    # for evidence records
var abuse_dropped := 0              # commands dropped by the window (RATE_ABUSE)
var duplicates := 0
var resyncs := 0
var _tick := 0
var _last_abuse_log := -1
var _abuse_unlogged := 0
var _far_arrived := false
var _far_latest := 0
var _stalled_ticks := 0
var _idle_ticks := 0                # ticks since the last executed command


func _init(p_world: Array) -> void:
	world = p_world
	_chain.resize(32)


## sha256 chain over every snapshot byte sent so far (determinism checks): h = sha256(h || bytes).
func snap_hash() -> String:
	return _chain.hex_encode()


func _chain_in(bytes: PackedByteArray) -> void:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	h.update(_chain)
	h.update(bytes)
	_chain = h.finish()


func teleport(x: float, y: float, z: float, flag: bool, keep_velocity: bool = false) -> void:
	state.pos_x = x
	state.pos_y = y
	state.pos_z = z
	if not keep_velocity:
		state.vel_x = 0.0
		state.vel_z = 0.0
		state.vel_up = 0.0
	state.on_ground = y <= Movement.support_height(world, x, z)
	if flag:
		state.teleport_gen += 1
	disturbances.append(next_seq)


## packet = {"cmds": Array[InputCmd] (current + previous 2), "ack_snap_seq": int}
## CD-r2 command budget: a command more than NetConfig.CMD_WINDOW ahead of the next expected seq is dropped and counted,
## so a forged far-future seq neither moves the player nor buys filled-in ticks. Execution in step() spends the budget.
func receive(packet: Dictionary) -> void:
	sender.on_ack(packet["ack_snap_seq"])
	for c: InputCmd in packet["cmds"]:
		if c.tick_hz != InputCmd.TICK_HZ:
			rate_flags += 1
		var ahead := SeqMath.diff(c.seq, next_seq)
		if ahead < 0 or pending.has(c.seq):
			duplicates += 1
			continue
		if ahead >= NetConfig.CMD_WINDOW:
			_abuse(c.seq, "seq %d is more than %d ahead of the next expected %d" % [c.seq, NetConfig.CMD_WINDOW, next_seq])
			_far_arrived = true
			_far_latest = c.seq                  # the most recent far-ahead seq (a real stream's newest; a forger's last)
			continue
		pending[c.seq] = c
		if SeqMath.diff(c.seq, highest_recv) > 0:
			highest_recv = c.seq


## Drop + count; at most one stored evidence entry per second (the totals keep counting) so logs cannot grow.
func _abuse(cmd_seq: int, why: String) -> void:
	abuse_dropped += 1
	_abuse_unlogged += 1
	if _tick - _last_abuse_log >= 128 or _last_abuse_log < 0:
		_last_abuse_log = _tick
		evidence.input_reject(_tick, slot_id, cmd_seq, EvidenceSink.REJECT_RATE_ABUSE, {"why": why, "dropped_since_last_log": _abuse_unlogged})
		_abuse_unlogged = 0


## Runs after FakeNet delivery. Returns the snapshot bytes to send this tick, or null.
func step(tick: int) -> Variant:
	_tick = tick
	executed_now.clear()
	tokens = minf(tokens + NetConfig.CMD_REFILL, NetConfig.CMD_BURST)
	while tokens >= 1.0:
		var cmd: InputCmd
		if pending.has(next_seq):
			cmd = pending[next_seq]
			pending.erase(next_seq)
		elif SeqMath.diff(highest_recv, next_seq) > 0:
			cmd = last_cmd.repeated_as(next_seq)         # fills cost the same budget as real commands
			lost_seqs.append(next_seq)
			disturbances.append(next_seq)
		else:
			break
		tokens -= 1.0
		Movement.step(state, cmd, world)
		last_cmd = cmd
		if keep_history:
			history[next_seq] = state.to_packed()
		executed_now.append(next_seq)
		executed_total += 1
		next_seq = SeqMath.add(next_seq, 1)
	# a real outage longer than the window: far-ahead commands keep arriving and nothing executes -> re-sync
	if not executed_now.is_empty():
		_idle_ticks = 0
	else:
		_idle_ticks += 1
	if not executed_now.is_empty() or not _far_arrived:
		_stalled_ticks = 0
	else:
		_stalled_ticks += 1
		if _stalled_ticks >= NetConfig.CMD_RESYNC_TICKS:
			next_seq = SeqMath.resync_target(next_seq, _far_latest, _idle_ticks, int(NetConfig.CMD_BURST))
			highest_recv = SeqMath.add(next_seq, -1)
			pending.clear()
			resyncs += 1
			disturbances.append(next_seq)
			_stalled_ticks = 0
	_far_arrived = false
	for r: RemotePath in remotes:
		if r.present(tick):
			r.pose(tick)            # stepped paths advance every tick, in order
	var snap_tick := tick % NetConfig.SNAPSHOT_EVERY_TICKS == 0
	var new_mask := -1
	if snap_tick:
		new_mask = _sent_mask(tick)
		_log_vis(tick, new_mask)
	vis_history.advance(tick, new_mask)
	if snap_tick:
		var sc := sender.scratch
		sc.clear_entities()
		for r: RemotePath in remotes:
			if r.present(tick) and (new_mask >> r.slot) & 1 == 1:
				var p := r.pose(tick)
				sc.set_entity(r.slot, p[0], p[1], p[2], InputCmd.quantize_yaw(p[3]), InputCmd.quantize_pitch(p[4]), int(p[5]), p[6] != 0.0, p[7])
		var bytes := sender.build(tick, next_seq - 1, state, SnapshotSender.stub_hud(state))
		_chain_in(bytes)
		if snapshot_tap.is_valid():
			snapshot_tap.call(bytes)
		return bytes
	return null


## Which remote slots this viewer is sent on a snapshot tick (u16 mask, bit n = slot n).
## Teammates always; everyone else only if a ray from the viewer's eyes to a body point is clear.
func _sent_mask(tick: int) -> int:
	var mask := 0
	var lookahead := vis_rtt_ms / 2000.0 + float(NetConfig.SNAPSHOT_EVERY_TICKS) / Movement.TICK_RATE
	var eye := Movement.eye_height(state)
	for r: RemotePath in remotes:
		if not r.present(tick):
			continue
		if not vis_enabled or r.team == viewer_team:
			mask |= 1 << r.slot
			continue
		var p := r.pose(tick)
		var v := r.vel(tick)
		if Visibility.target_visible(state.pos_x, state.pos_y, state.pos_z, state.vel_x, state.vel_z, eye,
				p[0], p[1], p[2], v.x, v.y, (int(p[5]) & 1) == 1, world, lookahead, NetConfig.VIS_LATERAL_MARGIN, p[7]) >= 0:
			mask |= 1 << r.slot
	return mask


## Evidence (in memory only): a change record when the mask changes, a keyframe at tick 0, every 1,280 ticks, and on request.
func _log_vis(tick: int, mask: int) -> void:
	if tick % 1280 == 0:
		evidence.vis_change(tick, 0, mask, 0, true)
	elif mask != _logged_mask:
		evidence.vis_change(tick, 0, mask, 0, false)
	_logged_mask = mask


## Round-start hook: a keyframe for the viewer right now.
func vis_round_start(tick: int) -> void:
	evidence.vis_change(tick, 0, _logged_mask if _logged_mask >= 0 else 0, 0, true)


## Seam D4 (Devin's hit registration and analyzer): the mask in force at `tick`, or -1 outside the history.
func sent_mask_for(viewer_slot: int, tick: int) -> int:
	return vis_history.mask_at(tick)


func sound_only_mask_for(_viewer_slot: int, _tick: int) -> int:
	return 0
