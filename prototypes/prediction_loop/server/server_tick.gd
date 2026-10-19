class_name ServerTick
extends RefCounted
## The server tick (specs/server_tick_v0.1.md, PROPOSED). One call to step() = one fixed 128 Hz tick, always
## 1.0 / 128.0 long, in this order:
##   1) drain transport -> per-client input queues     (the OWNER does this: enqueue_net / enqueue_local, then step())
##   2) execute commands, slots ascending, paid for from each client's command budget (CD-r2); a missing seq with a newer one present
##      repeats the last command; round_hooks.allow_movement gates movement
##   3) round_hooks.on_tick(T)
##   4) push lag-comp samples for EVERY slot (seam D1): after all movement, before any shot
##   5) shots: for each command executed this tick with BTN_ATTACK, shot_processor.process_shot(ctx) (seam D2)
##   6) on snapshot ticks: visibility per viewer -> per-client snapshot (delta vs ack, HUD block from seam D3) -> returned
##   7) stats
## Interfaces default to NULL stubs; tests and Devin's modules replace them.

var world: Array = Movement.default_world()
var slots: Array = []                              # 16 entries, ClientSlot or null
var tick := 0
var lagcomp: LagCompSink = LagCompSink.new()
var shots: ShotProcessor = ShotProcessor.new()
var weapons: WeaponStateProvider = WeaponStateProvider.new()
var round_hooks: RoundHooks = RoundHooks.new()
var evidence: EvidenceSink = EvidenceSink.new()
var vis_enabled := true
var bots: Array = []                               # BotDriver, driven in step 1 through enqueue_local
var order_log: Array = []                          # tests: the sequence of step markers of the latest tick
var log_order := false
var cmds_executed_last := 0
var _executed: Array = []
var stats_ticks := 0


func _init() -> void:
	slots.resize(16)


func add_client(slot_id: int, team: int = 1, bot: bool = false) -> ClientSlot:
	var c := ClientSlot.new(slot_id, team)
	c.is_bot = bot
	c.last_heard = tick
	slots[slot_id] = c
	return c


## A bot gets a real slot and team like anyone; its commands go through ClientSlot.enqueue_local (Phase 8).
func add_bot(slot_id: int, team: int, route: Dictionary) -> BotDriver:
	var cs := add_client(slot_id, team, true)
	var d := BotDriver.new(cs, route)
	bots.append(d)
	return d


func remove_client(slot_id: int) -> void:
	slots[slot_id] = null


func slot_count() -> int:
	var n := 0
	for s in slots:
		if s != null:
			n += 1
	return n


func free_slot() -> int:
	for i in 16:
		if slots[i] == null:
			return i
	return -1


func _mark(m: String) -> void:
	if log_order:
		order_log.append(m)


## Seam D4 for Devin's hit registration and analyzer.
func sent_mask_for(viewer_slot: int, t: int) -> int:
	var s: ClientSlot = slots[viewer_slot]
	return -1 if s == null else s.vis_history.mask_at(t)


func sound_only_mask_for(_viewer_slot: int, _t: int) -> int:
	return 0


func teams() -> Array:
	var out: Array = []
	for i in 16:
		out.append(0 if slots[i] == null else (slots[i] as ClientSlot).team)
	return out


## One tick. Returns {slot: snapshot bytes} for the clients that get a snapshot this tick.
func step() -> Dictionary:
	var t := tick
	if log_order:
		order_log.clear()
	for b: BotDriver in bots:
		b.drive(t, evidence)
	_mark("1_drain")
	# 2) execute commands
	_executed.clear()
	for i in 16:
		var s: ClientSlot = slots[i]
		if s != null:
			s.execute(t, world, round_hooks, _executed)
	cmds_executed_last = _executed.size()
	_mark("2_execute")
	# 3) round hooks
	round_hooks.on_tick(t)
	_mark("3_round")
	# 4) lag-comp samples for every slot
	for i in 16:
		var s: ClientSlot = slots[i]
		if s != null:
			var st := s.state
			lagcomp.push_sample(i, t, Frame.to_spec_x(st.pos_x), Frame.to_spec_y(st.pos_z), Frame.to_spec_z(st.pos_y),
				Frame.yaw_to_spec_deg(InputCmd.dequantize_yaw(s.view_yaw_q)), Movement.stance_for_hitbox(st), s.alive, Movement.duck_fraction(st))
	_mark("4_lagcomp")
	# 5) shots
	for e in _executed:
		var cmd: InputCmd = e["cmd"]
		if (cmd.buttons & InputCmd.BTN_ATTACK) != 0:
			shots.process_shot(_shot_ctx(e, t))
	_mark("5_shots")
	# 6) snapshots
	var out := {}
	var snap_tick := t % NetConfig.SNAPSHOT_EVERY_TICKS == 0
	for i in 16:
		var s: ClientSlot = slots[i]
		if s == null:
			continue
		var new_mask := -1
		if snap_tick:
			new_mask = _visible_mask(s, t)
			_log_vis(s, t, new_mask)
			s.note_mask(t, new_mask)
		s.vis_history.advance(t, new_mask)
		if snap_tick:
			out[i] = _build_snapshot(s, t, new_mask)
	_mark("6_snapshots")
	# 7) stats are kept by the caller (tick work time, overruns) and in the counters above
	stats_ticks += 1
	_mark("7_stats")
	tick += 1
	return out


func _shot_ctx(e: Dictionary, t: int) -> Dictionary:
	var s: ClientSlot = slots[e["slot"]]
	var cmd: InputCmd = e["cmd"]
	return {
		"now": t,
		"tick_rate": Movement.TICK_RATE,
		"shooter_slot": e["slot"],
		"eye_x": Frame.to_spec_x(e["pos_x"]),
		"eye_y": Frame.to_spec_y(e["pos_z"]),
		"eye_z": Frame.to_spec_z(e["pos_y"] + e["eye"]),
		"view_pitch_q": cmd.pitch_q,
		"view_yaw_q": cmd.yaw_q,
		"view_pitch_deg": Frame.pitch_to_spec_deg(InputCmd.dequantize_pitch(cmd.pitch_q)),
		"view_yaw_deg": Frame.yaw_to_spec_deg(InputCmd.dequantize_yaw(cmd.yaw_q)),
		"cmd_seq": cmd.seq,
		"claimed_view_tick": cmd.view_tick,
		"rtt_ms": s.rtt_ticks * 1000.0 / Movement.TICK_RATE if s.rtt_ticks >= 0.0 else -1.0,
		"teams": teams(),
		"sent_mask_for": sent_mask_for,
	}


## Which other slots this viewer is sent (u16 mask). Teammates always; enemies if a ray is clear.
func _visible_mask(viewer: ClientSlot, t: int) -> int:
	var mask := 0
	var rtt_ms := viewer.rtt_ticks * 1000.0 / Movement.TICK_RATE if viewer.rtt_ticks >= 0.0 else 0.0
	var lookahead := rtt_ms / 2000.0 + float(NetConfig.SNAPSHOT_EVERY_TICKS) / Movement.TICK_RATE
	var v := viewer.state
	var eye := Movement.eye_height(v)
	for i in 16:
		var o: ClientSlot = slots[i]
		if o == null or o == viewer or not o.alive:
			continue
		if not vis_enabled or o.team == viewer.team:
			mask |= 1 << i
			continue
		var os := o.state
		if Visibility.target_visible(v.pos_x, v.pos_y, v.pos_z, v.vel_x, v.vel_z, eye, os.pos_x, os.pos_y, os.pos_z, os.vel_x, os.vel_z,
				(Movement.stance_for_hitbox(os) & 1) == 1, world, lookahead, NetConfig.VIS_LATERAL_MARGIN, Movement.duck_fraction(os)) >= 0:
			mask |= 1 << i
	return mask


func _log_vis(viewer: ClientSlot, t: int, mask: int) -> void:
	if t % 1280 == 0:
		evidence.vis_change(t, viewer.slot, mask, 0, true)
	elif mask != viewer.logged_mask:
		evidence.vis_change(t, viewer.slot, mask, 0, false)
	viewer.logged_mask = mask


func vis_round_start(t: int) -> void:
	round_hooks.on_round_start(t)
	for i in 16:
		var s: ClientSlot = slots[i]
		if s != null:
			evidence.vis_change(t, i, maxi(s.logged_mask, 0), 0, true)


func _build_snapshot(viewer: ClientSlot, t: int, mask: int) -> PackedByteArray:
	var sc := viewer.sender.scratch
	sc.clear_entities()
	for i in 16:
		if (mask >> i) & 1 == 1:
			var o: ClientSlot = slots[i]
			var os := o.state
			sc.set_entity(i, os.pos_x, os.pos_y, os.pos_z, o.view_yaw_q, o.view_pitch_q, Movement.stance_for_hitbox(os), o.alive, Movement.duck_fraction(os))
	var hf := weapons.hud_fields(viewer.slot, Movement.move_state_for_hud(viewer.state))
	var hud := [Quant.accuracy_to_q(hf["accuracy"]), Quant.angle_to_q(hf["punch_pitch"]), Quant.angle_to_q(hf["punch_yaw"]), Movement.move_state_for_hud(viewer.state)]
	var bytes := viewer.sender.build(t, viewer.next_seq - 1, viewer.state, hud)
	viewer.sent_tick[Snapshot.peek(bytes)["snap_seq"]] = t
	return bytes
