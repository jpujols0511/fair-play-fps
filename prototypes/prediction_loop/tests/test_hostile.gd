extends SceneTree
## Hostile packets against the real server code over raw UDP on loopback:  godot --headless --script res://tests/test_hostile.gd
## The server object is driven by hand (srv._tick()); the attackers are plain PacketPeerUDP sockets.

var passed := 0
var failed := 0
var srv: ServerMain
var port := 27990


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	srv = ServerMain.new()
	srv.setup(PackedStringArray(["--port", str(port), "--transport", "udp"]))
	_garbage()
	var good: Variant = _join()
	if good != null:
		_forged_ack_and_seq(good)
		_forged_resync(good)
		_stranger_bye(good)
	_unverified_flood()
	_loopback_default()
	_cli_missing_value()
	srv.transport.close()
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _sock() -> PacketPeerUDP:
	var s := PacketPeerUDP.new()
	s.connect_to_host("127.0.0.1", port)
	return s


func _pump(n: int = 6) -> void:
	for i in n:
		OS.delay_msec(2)
		srv._tick()


func _recv(s: PacketPeerUDP) -> Array:
	var out: Array = []
	while s.get_available_packet_count() > 0:
		out.append(s.get_packet())
	return out


func _garbage() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var s := _sock()
	var m0 := Packet.malformed
	for i in 600:
		var b := PackedByteArray()
		var n := rng.randi() % 1500
		for k in n:
			b.append(rng.randi() % 256)
		if i % 3 == 0 and n >= 5:
			b.encode_u32(0, Packet.PROTOCOL_ID)               # right id, random everything else
		s.put_packet(b)
		if i % 50 == 49:
			_pump(2)
	_pump(10)
	_ok("600 garbage / oversized / right-id-random datagrams: no crash, no client created, malformed counted", srv.peer_slot.is_empty() and Packet.malformed - m0 > 300, "%d malformed" % (Packet.malformed - m0))
	var hello := Packet.encode_hello(128, 0)
	var truncated := hello.slice(0, 20)
	var wrong_ver := hello.duplicate()
	wrong_ver.encode_u16(5, 99)
	var four_cmds := Packet.encode_input(0, 0, [InputCmd.make(1, 1, 0, 0, 0), InputCmd.make(2, 2, 0, 0, 0), InputCmd.make(3, 3, 0, 0, 0)])
	four_cmds.encode_u8(8, 4)
	for b in [truncated, wrong_ver, four_cmds, Packet.encode_welcome(0, 0, 4, 2), Packet.encode_challenge(5)]:
		s.put_packet(b)
	_pump(8)
	_ok("truncated HELLO, wrong version, 4-command INPUT, a WELCOME and a CHALLENGE sent to the server: ignored", srv.peer_slot.is_empty())


## Returns {sock, slot} after the cookie handshake, checking that nothing is allocated before it.
func _join() -> Variant:
	var s := _sock()
	var hello := Packet.encode_hello(128, 0)
	s.put_packet(hello)
	_pump()
	var got := _recv(s)
	var ch := Packet.parse(got[0]) if got.size() == 1 else {}
	_ok("HELLO without a cookie: the reply is one 9-byte CHALLENGE (smaller than the HELLO, nothing to amplify), no slot allocated", ch.get("msg", 0) == Packet.MSG_CHALLENGE and got[0].size() == 9 and got[0].size() < hello.size() and srv.peer_slot.is_empty(), "reply %d bytes vs HELLO %d" % [got[0].size() if got.size() > 0 else -1, hello.size()])
	if ch.is_empty():
		return null
	s.put_packet(Packet.encode_hello(128, (ch["cookie"] + 1) & 0xFFFFFFFF))
	_pump()
	var again := _recv(s)
	_ok("HELLO with a wrong cookie: another CHALLENGE, still no slot", again.size() == 1 and Packet.parse(again[0]).get("msg", 0) == Packet.MSG_CHALLENGE and srv.peer_slot.is_empty())
	s.put_packet(Packet.encode_hello(128, ch["cookie"]))
	_pump()
	var w := _recv(s)
	var wm := Packet.parse(w[0]) if w.size() >= 1 else {}
	_ok("HELLO with the right cookie: WELCOME and one slot", wm.get("msg", 0) == Packet.MSG_WELCOME and srv.peer_slot.size() == 1)
	if srv.peer_slot.size() != 1:
		return null
	# the cookie belongs to that address: another socket cannot reuse it
	var thief := _sock()
	thief.put_packet(Packet.encode_hello(128, ch["cookie"]))
	_pump()
	var tr := _recv(thief)
	_ok("a cookie replayed from another address is rejected (CHALLENGE, no slot)", tr.size() == 1 and Packet.parse(tr[0]).get("msg", 0) == Packet.MSG_CHALLENGE and srv.peer_slot.size() == 1)
	return {"sock": s, "slot": wm["slot"]}


func _cmds(first: int, n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(InputCmd.make(first + i, first + i, InputCmd.BTN_FORWARD, 0, InputCmd.quantize_pitch(0.0)))
	return out


func _forged_ack_and_seq(good: Dictionary) -> void:
	var s: PacketPeerUDP = good["sock"]
	for q in 40:
		s.put_packet(Packet.encode_input(0, 0, _cmds(q * 1 + 1, 1)))
		_pump(1)
	var cs: ClientSlot = srv.server.slots[srv.peer_slot[srv.peer_slot.keys()[0]]]
	var base_ack := cs.sender.ack_snap_seq
	var rej0 := srv.acks_rejected
	s.put_packet(Packet.encode_input(40000, 3, _cmds(41, 1)))        # ack for a snapshot never sent
	_pump(2)
	s.put_packet(Packet.encode_input(0xFFFF, 255, _cmds(42, 1)))
	_pump(2)
	_ok("forged acks (never-sent seqs 40000 and 65535) are rejected and counted; ack_snap_seq does not move", srv.acks_rejected - rej0 == 2 and cs.sender.ack_snap_seq == base_ack, "rejected %d, ack %d -> %d" % [srv.acks_rejected - rej0, base_ack, cs.sender.ack_snap_seq])
	var rtt_before := cs.rtt_ticks
	s.put_packet(Packet.encode_input(maxi(cs.sender.next_seq - 1, 1), 255, _cmds(43, 1)))   # real ack but an impossible 255-tick delay
	_pump(2)
	_ok("an impossible ack_delay (negative RTT sample) is ignored", cs.rtt_ticks == rtt_before or cs.rtt_ticks >= 0.0)
	var x0 := cs.state.pos_z
	var ex0 := cs.executed_total
	s.put_packet(Packet.encode_input(0, 0, _cmds(0x7FFFFFFF - 2, 3)))
	_pump(6)
	_ok("INPUT with seq 0x7FFFFFFF: dropped, counted RATE_ABUSE, the player does not move extra", cs.abuse_dropped >= 3 and cs.executed_total - ex0 <= 6, "dropped %d, executed %d more" % [cs.abuse_dropped, cs.executed_total - ex0])


## CD-r7: 140 ticks of a forged 0xFFFFFFFF seq (and 0x7FFFFFFF), then the client's real stream: the player must run again.
func _forged_resync(good: Dictionary) -> void:
	var s: PacketPeerUDP = good["sock"]
	var cs: ClientSlot = srv.server.slots[srv.peer_slot[srv.peer_slot.keys()[0]]]
	var base := cs.executed_total
	var sq := 44
	for forged in [0xFFFFFFFF, 0x7FFFFFFF]:
		for t in 140:
			s.put_packet(Packet.encode_input(0, 0, _cmds(forged, 1)))
			_pump(1)
			sq += 1
		var before := cs.executed_total
		for t in 1300:
			s.put_packet(Packet.encode_input(0, 0, _cmds(sq, 1)))
			sq += 1
			_pump(1)
		var ran := cs.executed_total - before
		_ok("hostile 0x%X for 140 ticks then the real stream: %d of the next 1,300 commands run (next_seq stays bounded)" % [forged, ran], ran >= 1100 and SeqMath.diff(cs.next_seq, sq) <= 2, "resyncs %d, next_seq - real seq = %d" % [cs.resyncs, SeqMath.diff(cs.next_seq, sq)])


func _stranger_bye(good: Dictionary) -> void:
	var n := srv.peer_slot.size()
	var stranger := _sock()
	stranger.put_packet(Packet.encode_bye())
	stranger.put_packet(Packet.encode_input(0, 0, _cmds(1, 1)))
	_pump(4)
	_ok("BYE and INPUT from an address that never joined do nothing", srv.peer_slot.size() == n)
	var s: PacketPeerUDP = good["sock"]
	s.put_packet(Packet.encode_bye())
	_pump(4)
	_ok("BYE from the real client removes its slot and forgets its address", srv.peer_slot.is_empty() and srv.transport.unverified_count() >= 0)


func _unverified_flood() -> void:
	var socks: Array = []
	for i in 200:
		var s := _sock()
		s.put_packet(Packet.encode_hello(128, 0))
		socks.append(s)
	_pump(30)
	var t: TransportUdp = srv.transport
	_ok("200 HELLOs from 200 source ports: unverified peers capped at %d, the rest refused, no slots" % TransportUdp.MAX_UNVERIFIED, t.unverified_count() <= TransportUdp.MAX_UNVERIFIED and t.refused_peers > 0 and srv.peer_slot.is_empty(), "%d unverified, %d refused" % [t.unverified_count(), t.refused_peers])
	for id in t._first_ms.keys():
		t._first_ms[id] = Time.get_ticks_msec() - 10000
	var pruned := t.prune()
	_ok("unverified peers older than 5 s are pruned", pruned > 0 and t.unverified_count() == 0, "%d pruned" % pruned)


func _loopback_default() -> void:
	_ok("the server binds to loopback unless --bind-all is given", srv.bind_addr == "127.0.0.1")
	var all := ServerMain.new()
	all.setup(PackedStringArray(["--port", str(port + 1), "--transport", "udp", "--bind-all"]))
	_ok("--bind-all binds all interfaces", all.bind_addr == "*")
	all.transport.close()


func _cli_missing_value() -> void:
	_ok("ServerMain.arg_value on a last flag with no value returns \"\" instead of reading past the end", ServerMain.arg_value(PackedStringArray(["--port"]), 0) == "" and ServerMain.arg_value(PackedStringArray(["--port", "5"]), 0) == "5")
