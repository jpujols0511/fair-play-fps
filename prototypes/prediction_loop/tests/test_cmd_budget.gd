extends SceneTree
## Per-client command budget (CURRENT_DECISIONS CD-r2: 1 per tick, burst 8, refill 1/tick, excess dropped and logged RATE_ABUSE):
##   godot --headless --script res://tests/test_cmd_budget.gd
## Includes the speedhack probe: a client that sends 8x the commands must not travel further than an honest one.

var passed := 0
var failed := 0
const F := InputCmd.BTN_FORWARD


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	_speedhack()
	_forged_future()
	_log_growth()
	_fills_spend_budget()
	_resync_after_outage()
	_attack_not_repeated()
	_honest_burst()
	_bounded_resync()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _cmd(seq: int, buttons: int = F) -> InputCmd:
	return InputCmd.make(seq, seq, buttons, 0, InputCmd.quantize_pitch(0.0))


func _pkt(seqs: Array, buttons: int = F) -> Dictionary:
	var cmds: Array = []
	for q in seqs:
		cmds.append(_cmd(q, buttons))
	return {"cmds": cmds, "ack_snap_seq": -1}


func _dist(s: FakeServer) -> float:
	return sqrt(s.state.pos_x * s.state.pos_x + s.state.pos_z * s.state.pos_z)


func _speedhack() -> void:
	var honest := FakeServer.new(Movement.default_world())
	var cheat := FakeServer.new(Movement.default_world())
	var ticks := 1280                              # 10 s
	var seq_c := 1
	for t in ticks:
		honest.receive(_pkt([maxi(t - 1, 1), maxi(t, 1), t + 1]))
		honest.step(t)
		# the cheater sends 8 new commands per tick, in 3 datagrams (3 + 3 + 2 commands), like a client with a fast clock
		cheat.receive(_pkt([seq_c, seq_c + 1, seq_c + 2]))
		cheat.receive(_pkt([seq_c + 3, seq_c + 4, seq_c + 5]))
		cheat.receive(_pkt([seq_c + 6, seq_c + 7]))
		seq_c += 8
		cheat.step(t)
	var dh := _dist(honest)
	var dc := _dist(cheat)
	_ok("speedhack probe: a client sending 8x the commands never travels further than the honest one (+1%); it only loses ticks", dc <= dh * 1.01 and dc > 0.0, "honest %.1f units, 8x sender %.1f units over %d ticks" % [dh, dc, ticks])
	_ok("speedhack probe: executed commands = honest + at most the burst allowance", cheat.executed_total <= honest.executed_total + int(NetConfig.CMD_BURST), "honest %d, 8x sender %d" % [honest.executed_total, cheat.executed_total])
	_ok("speedhack probe: the excess is dropped and counted as RATE_ABUSE", cheat.abuse_dropped > 8000 and cheat.evidence.count_rejects(EvidenceSink.REJECT_RATE_ABUSE) > 0 and honest.abuse_dropped == 0, "%d dropped, %d RATE_ABUSE evidence records (totals)" % [cheat.abuse_dropped, cheat.evidence.count_rejects(EvidenceSink.REJECT_RATE_ABUSE)])


func _forged_future() -> void:
	var control := FakeServer.new(Movement.default_world())
	var forged := FakeServer.new(Movement.default_world())
	for t in 640:
		control.receive(_pkt([maxi(t - 1, 1), maxi(t, 1), t + 1]))
		control.step(t)
		forged.receive(_pkt([maxi(t - 1, 1), maxi(t, 1), t + 1]))
		if t == 100:
			forged.receive(_pkt([0x7FFFFFFF, 0x7FFFFFFE, 0x7FFFFFFD]))     # one forged packet
		forged.step(t)
	_ok("one forged packet with seq 0x7FFFFFFF: position bit-identical to the control run", forged.state.equals(control.state) and forged.executed_total == control.executed_total, "executed %d vs %d" % [forged.executed_total, control.executed_total])
	_ok("... the three forged commands are dropped, counted, and logged once", forged.abuse_dropped == 3 and forged.evidence.count_rejects(EvidenceSink.REJECT_RATE_ABUSE) == 1 and forged.lost_seqs.is_empty() and forged.resyncs == 0)


func _log_growth() -> void:
	var s := FakeServer.new(Movement.default_world())
	for t in 3000:
		s.receive(_pkt([maxi(t, 1)]))
		s.receive(_pkt([0x7FFFFFFF - t, 0x7FFFFFF0 - t, 0x7FFFFFE0 - t]))
		s.step(t)
	var stored := s.evidence.input_rejects.size()
	_ok("flood of forged seqs: stored evidence stays tiny (one record per second), totals keep counting", stored <= 3000 / 128 + 2 and s.evidence.count_rejects(EvidenceSink.REJECT_RATE_ABUSE) == stored and s.abuse_dropped == 9000, "%d dropped, %d stored" % [s.abuse_dropped, stored])
	var sink := EvidenceSink.new()
	for i in 20000:
		sink.input_reject(i, 0, i, EvidenceSink.REJECT_MALFORMED, {})
	_ok("the evidence list itself is capped (%d) and counts what it did not store" % EvidenceSink.MAX_STORED_REJECTS, sink.input_rejects.size() == EvidenceSink.MAX_STORED_REJECTS and sink.count_rejects(EvidenceSink.REJECT_MALFORMED) == 20000 and sink.rejects_not_stored == 20000 - EvidenceSink.MAX_STORED_REJECTS)


func _fills_spend_budget() -> void:
	# seq 1, then seq 60: 58 commands in between are "lost" and would be filled by repeating; the fills cost the same budget
	var s := FakeServer.new(Movement.default_world())
	s.receive(_pkt([1]))
	s.receive(_pkt([60]))
	var per_tick: Array = []
	for t in 40:
		s.step(t)
		per_tick.append(s.executed_now.size())
	var total := 0
	for n in per_tick:
		total += n
	_ok("filled-in commands spend the budget: 40 ticks execute at most burst + 40", total <= int(NetConfig.CMD_BURST) + 40 and per_tick[0] <= int(NetConfig.CMD_BURST) and total >= 40, "first tick %d, total %d" % [per_tick[0], total])


func _resync_after_outage() -> void:
	var s := FakeServer.new(Movement.default_world())
	for t in 100:
		s.receive(_pkt([t + 1]))
		s.step(t)
	# a 3 s outage: nothing reaches the server for 384 ticks (the client keeps numbering), then seq 485+ arrive
	var n := 0
	for t in range(100, 484):
		s.step(t)
	for t in range(484, 784):
		s.receive(_pkt([485 + (t - 484)]))
		s.step(t)
		n += s.executed_now.size()
	_ok("a real outage longer than the window re-syncs once after %d ticks and execution resumes" % NetConfig.CMD_RESYNC_TICKS, s.resyncs == 1 and n > 100, "resyncs %d, executed %d of the next 300 ticks" % [s.resyncs, n])


func _attack_not_repeated() -> void:
	var c := InputCmd.make(5, 5, F | InputCmd.BTN_ATTACK | InputCmd.BTN_JUMP, 7, 9)
	var r := c.repeated_as(6)
	_ok("a filled-in command keeps movement buttons but never ATTACK", (r.buttons & InputCmd.BTN_ATTACK) == 0 and (r.buttons & F) != 0 and (r.buttons & InputCmd.BTN_JUMP) != 0 and r.seq == 6)


func _honest_burst() -> void:
	# a late packet: 6 commands arrive at once; an honest client is never throttled by the burst allowance
	var s := FakeServer.new(Movement.default_world())
	for t in 10:
		s.receive(_pkt([t + 1]))
		s.step(t)
	s.receive(_pkt([11, 12, 13]))
	s.receive(_pkt([14, 15, 16]))
	s.step(10)
	_ok("honest jitter burst (6 commands at once) executes in the same tick, nothing dropped", s.executed_now.size() == 6 and s.abuse_dropped == 0, "%d executed" % s.executed_now.size())


## CD-r7: a forged huge seq must not move next_seq to an arbitrary far-ahead value (it stranded the player for good).
func _bounded_resync() -> void:
	for forged_seq in [0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x80000001, 1000000]:
		var s := FakeServer.new(Movement.default_world())
		var control := FakeServer.new(Movement.default_world())
		var sq := 1
		# 100 ticks of honest play, then 140 ticks in which ONLY the forged seq arrives, then honest play again (the client
		# kept numbering: its real seq is now 240 + ...)
		for t in 100:
			s.receive(_pkt([sq]))
			s.step(t)
			control.receive(_pkt([sq]))
			control.step(t)
			sq += 1
		for t in range(100, 240):
			s.receive(_pkt([forged_seq]))
			s.step(t)
			sq += 1
			control.receive(_pkt([sq - 1]))
			control.step(t)
		var ran := 0
		var ran_control := 0
		for t in range(240, 1540):
			s.receive(_pkt([sq]))
			s.step(t)
			ran += s.executed_now.size()
			control.receive(_pkt([sq]))
			control.step(t)
			ran_control += control.executed_now.size()
			sq += 1
		var bound := s.next_seq - sq
		_ok("forged seq 0x%X for 140 ticks: after the attack the player runs again (%d of 1,300 commands vs %d for the control), next_seq stays within the honest stream" % [forged_seq, ran, ran_control], ran >= 1150 and s.resyncs <= 2 and SeqMath.diff(s.next_seq, sq) <= 2, "resyncs %d, next_seq - honest seq = %d" % [s.resyncs, SeqMath.diff(s.next_seq, sq)])
	# the bound itself, and the 32-bit wrap
	_ok("resync target is the newest far seq when it is within idle ticks + burst", SeqMath.resync_target(1000, 1100, 140, 8) == 1100)
	_ok("... and next_seq + that bound otherwise (never the forged value)", SeqMath.resync_target(1000, 0xFFFFFFFF, 140, 8) == 1148 and SeqMath.resync_target(1000, 0x7FFFFFFF, 140, 8) == 1148)
	_ok("SeqMath: diff and add wrap at 2^32", SeqMath.diff(2, 0xFFFFFFFE) == 4 and SeqMath.diff(0xFFFFFFFE, 2) == -4 and SeqMath.add(0xFFFFFFFF, 1) == 0 and SeqMath.diff(0x80000000, 0) < 0)
	# a stream that crosses the wrap executes normally
	var w := FakeServer.new(Movement.default_world())
	w.next_seq = 0xFFFFFFF0
	w.highest_recv = 0xFFFFFFEF
	var done := 0
	for t in 100:
		var q := SeqMath.add(0xFFFFFFF0, t)
		w.receive(_pkt([q]))
		w.step(t)
		done += w.executed_now.size()
	_ok("a command stream that crosses 2^32 executes every command exactly once", done == 100 and w.abuse_dropped == 0 and w.lost_seqs.is_empty() and w.next_seq == SeqMath.add(0xFFFFFFF0, 100), "%d executed, next_seq 0x%X" % [done, w.next_seq])
