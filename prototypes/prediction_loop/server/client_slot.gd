class_name ClientSlot
extends RefCounted
## One player's server-side slot: simulation state, input queue, snapshot sender, rtt, visibility history.
## The input queue is shared by humans and bots: network INPUT goes through enqueue_net(), a bot's command
## through enqueue_local(); both end up in _admit(), so there is no backdoor around dedupe, window,
## budget or execution (specs/bot_spec_v0.0_skeleton.md rule 3).

## CD-r2 command budget (NetConfig.CMD_BURST / CMD_REFILL / CMD_WINDOW): see execute() and _admit().

var slot := 0
var team := 1
var is_bot := false
var alive := true
var state := PlayerState.new()
var next_seq := 1
var highest_recv := 0
var pending: Dictionary = {}
var last_cmd: InputCmd = InputCmd.make(0, 0, 0, 0, 0)
var view_yaw_q := 0
var view_pitch_q := InputCmd.quantize_pitch(0.0)
var lost_seqs: Array = []            # seqs filled by repeating the last command (all 3 copies lost)
var executed_total := 0
var keep_log := false
var executed_log: PackedInt32Array = PackedInt32Array()      # tests: seqs in execution order
var sender := SnapshotSender.new()
var vis_history := Visibility.History.new(NetConfig.SENT_MASK_HISTORY_TICKS)
var logged_mask := -1
var mask_changes: Array = []         # [tick, mask] at every snapshot tick where this viewer's sent mask changed (integration check)
var last_heard := 0
var rtt_ticks := -1.0
var sent_tick := PackedInt32Array()
var duplicates := 0
var tokens := NetConfig.CMD_BURST    # command budget: executing one command costs 1.0
var abuse_dropped := 0               # commands dropped by the window (RATE_ABUSE)
var resyncs := 0
var _last_abuse_log := -1
var _abuse_unlogged := 0
var _far_arrived := false
var _far_latest := 0
var _stalled_ticks := 0
var _idle_ticks := 0


func _init(p_slot: int, p_team: int = 1) -> void:
	slot = p_slot
	team = p_team
	sent_tick.resize(65536)


## Network INPUT: the commands of one datagram plus the client's ack of the newest snapshot it decoded.
func enqueue_net(cmds: Array, ack_snap_seq: int, ack_delay_ticks: int, tick: int, evidence: EvidenceSink) -> void:
	last_heard = tick
	if sender.next_seq > 1:
		sender.on_ack(ack_snap_seq)
		# RTT (feeds Devin's rtt_ms): now - sent_tick(ack_snap_seq) - ack_delay_ticks, EWMA alpha 0.125
		if sent_tick[ack_snap_seq & 0xFFFF] > 0 and sender.ring.get_snap(ack_snap_seq) != null:
			var sample := float(tick - sent_tick[ack_snap_seq & 0xFFFF] - ack_delay_ticks)
			if sample >= 0.0 and sample <= 1280.0:           # a negative or over-10-s sample is impossible: ignored
				rtt_ticks = sample if rtt_ticks < 0.0 else rtt_ticks + 0.125 * (sample - rtt_ticks)
	for c: InputCmd in cmds:
		_admit(c, tick, evidence)


## A bot's command: the same queue, no transport.
func enqueue_local(cmd: InputCmd, tick: int, evidence: EvidenceSink) -> void:
	last_heard = tick
	_admit(cmd, tick, evidence)


func _admit(cmd: InputCmd, tick: int, evidence: EvidenceSink) -> void:
	var ahead := SeqMath.diff(cmd.seq, next_seq)
	if ahead < 0 or pending.has(cmd.seq):
		duplicates += 1
		return
	if ahead >= NetConfig.CMD_WINDOW:
		# a forged or runaway seq cannot buy ticks: dropped and counted; one stored evidence record per second
		abuse_dropped += 1
		_abuse_unlogged += 1
		_far_arrived = true
		_far_latest = cmd.seq                 # the most recent far-ahead seq
		if _last_abuse_log < 0 or tick - _last_abuse_log >= 128:
			_last_abuse_log = tick
			evidence.input_reject(tick, slot, cmd.seq, EvidenceSink.REJECT_RATE_ABUSE, {"why": "seq more than %d ahead of the next expected %d" % [NetConfig.CMD_WINDOW, next_seq], "dropped_since_last_log": _abuse_unlogged})
			_abuse_unlogged = 0
		return
	pending[cmd.seq] = cmd
	if SeqMath.diff(cmd.seq, highest_recv) > 0:
		highest_recv = cmd.seq


## Server tick step 2 for this slot. The budget refills CMD_REFILL per tick (up to CMD_BURST); every executed command,
## real or filled in for a lost seq, costs 1.0. Appends one entry per executed command to `out`:
## {slot, cmd, pos_x, pos_y, pos_z, eye, synthetic}.
func execute(tick: int, world: Array, hooks: RoundHooks, out: Array) -> void:
	tokens = minf(tokens + NetConfig.CMD_REFILL, NetConfig.CMD_BURST)
	var n := 0
	while tokens >= 1.0:
		var cmd: InputCmd
		var synthetic := false
		if pending.has(next_seq):
			cmd = pending[next_seq]
			pending.erase(next_seq)
		elif SeqMath.diff(highest_recv, next_seq) > 0:
			cmd = last_cmd.repeated_as(next_seq)          # repeats never carry ATTACK (InputCmd.repeated_as)
			lost_seqs.append(next_seq)
			synthetic = true
		else:
			break
		tokens -= 1.0
		if hooks.allow_movement(slot, tick):
			Movement.step(state, cmd, world)
		last_cmd = cmd
		view_yaw_q = cmd.yaw_q
		view_pitch_q = cmd.pitch_q
		executed_total += 1
		if keep_log:
			executed_log.append(next_seq)
		out.append({"slot": slot, "cmd": cmd, "pos_x": state.pos_x, "pos_y": state.pos_y, "pos_z": state.pos_z,
			"eye": Movement.eye_height(state), "synthetic": synthetic})
		next_seq = SeqMath.add(next_seq, 1)
		n += 1
	# a real outage longer than the window: far-ahead commands keep arriving and nothing executes -> re-sync
	_idle_ticks = 0 if n > 0 else _idle_ticks + 1
	if n > 0 or not _far_arrived:
		_stalled_ticks = 0
	else:
		_stalled_ticks += 1
		if _stalled_ticks >= NetConfig.CMD_RESYNC_TICKS:
			# bounded (CD-r7): the newest far seq only if within idle ticks + burst, else next_seq + that bound
			next_seq = SeqMath.resync_target(next_seq, _far_latest, _idle_ticks, int(NetConfig.CMD_BURST))
			highest_recv = SeqMath.add(next_seq, -1)
			pending.clear()
			resyncs += 1
			_stalled_ticks = 0
	_far_arrived = false


## Called on snapshot ticks with the mask just computed for this viewer.
func note_mask(tick: int, mask: int) -> void:
	if (mask_changes.is_empty() or mask_changes[mask_changes.size() - 1][1] != mask) and mask_changes.size() < 20000:
		mask_changes.append([tick, mask])
