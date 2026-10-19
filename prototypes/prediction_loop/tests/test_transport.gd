extends SceneTree
## Real transport (Phase 6), one process, REAL loopback sockets, both transports:
##   godot --headless --script res://tests/test_transport.gd
## The two-process 10-minute soak is tools/run_loopback_pair.sh.

var passed := 0
var failed := 0


func _init() -> void:
	if not Engine.get_version_info()["string"].begins_with("4.4.1"):
		print("FAIL  Godot version is not 4.4.1")
		quit(1)
		return
	_packets()
	_fuzz_parse()
	_oversize()
	var port := 28100
	for kind in ["enet", "udp"]:
		_sockets(kind, port)
		port += 3
		_rtt(kind, false, port)
		port += 1
		_rtt(kind, true, port)
		port += 1
	print("\n%d passed, %d failed" % [passed, failed])
	quit(1 if failed > 0 else 0)


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		passed += 1
		print("PASS  %s  %s" % [name, detail])
	else:
		failed += 1
		print("FAIL  %s  %s" % [name, detail])


func _cmd(seq: int, tick: int, buttons: int, yaw_q: int, pitch_q: int, view: float) -> InputCmd:
	var c := InputCmd.make(seq, tick, buttons, yaw_q, pitch_q)
	c.view_tick = view
	return c


func _packets() -> void:
	var cmds := [_cmd(10, 100, 17, 65535, 0, 98.5), _cmd(11, 101, 33, 1234, 65535, 99.25), _cmd(12, 102, 0, 0, 32768, 100.0)]
	var inp := Packet.encode_input(777, 3, cmds)
	_ok("INPUT with 3 commands = 5 + 4 + 57 = 66 bytes", inp.size() == 66, "%d bytes" % inp.size())
	var m := Packet.parse(inp)
	var same: bool = m["msg"] == Packet.MSG_INPUT and m["ack_snap_seq"] == 777 and m["ack_delay_ticks"] == 3 and m["cmds"].size() == 3
	for i in 3:
		var a: InputCmd = cmds[i]
		var b: InputCmd = m["cmds"][i]
		same = same and a.seq == b.seq and a.tick == b.tick and a.buttons == b.buttons and a.yaw_q == b.yaw_q and a.pitch_q == b.pitch_q and absf(a.view_tick - b.view_tick) < 1.0 / 65536.0
	_ok("INPUT round trip: seq, tick, buttons (incl. duck 32), yaw, pitch and view_tick + fraction", same)
	var h := Packet.parse(Packet.encode_hello())
	_ok("HELLO is 45 bytes: version 1, tick rate 128, cookie u32, 32 zero bytes of kernel_sha256 (placeholder)", Packet.encode_hello().size() == 45 and h["version"] == 1 and h["tick_rate"] == 128 and h["kernel_sha256"] == PackedByteArray([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
	var w := Packet.parse(Packet.encode_welcome(5, 123456, 4, 2))
	_ok("WELCOME carries slot, server tick, interp ticks (server dictates C1) and snapshot_every (C4)", w["slot"] == 5 and w["server_tick"] == 123456 and w["interp_ticks"] == 4 and w["snapshot_every"] == 2 and Packet.encode_welcome(5, 1, 4, 2).size() == 12)
	var sp := Packet.encode_snapshot(PackedByteArray([1, 2, 3]))
	_ok("SNAPSHOT wraps the snapshot bytes; BYE is 5 bytes", Packet.parse(sp)["snapshot"] == PackedByteArray([1, 2, 3]) and Packet.encode_bye().size() == 5 and Packet.parse(Packet.encode_bye())["msg"] == Packet.MSG_BYE)
	# view_tick is ignored by movement: a command with a view_tick steps exactly like one without
	var s1 := PlayerState.new()
	var s2 := PlayerState.new()
	for i in 200:
		Movement.step(s1, _cmd(i, i, 1 | (16 if i % 7 == 0 else 0), 1000, 0, 0.0), [])
		Movement.step(s2, _cmd(i, i, 1 | (16 if i % 7 == 0 else 0), 1000, 0, 12345.678), [])
	_ok("view_tick is ignored by Movement.step (S1 unaffected)", s1.hex() == s2.hex())


func _fuzz_parse() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7601
	Packet.malformed = 0
	var rejected := 0
	var accepted := 0
	var valid_samples: Array = [Packet.encode_hello(), Packet.encode_welcome(1, 2, 4, 2), Packet.encode_bye(), Packet.encode_input(1, 0, [_cmd(1, 1, 1, 1, 1, 1.0)]), Packet.encode_snapshot(PackedByteArray([9, 9, 9]))]
	for i in 10000:
		var b := PackedByteArray()
		var mode := rng.randi() % 4
		if mode == 0:                                   # pure random bytes
			for k in rng.randi() % 300:
				b.append(rng.randi() % 256)
		elif mode == 1:                                 # truncated valid packet (incl. truncated headers)
			b = (valid_samples[rng.randi() % valid_samples.size()] as PackedByteArray).duplicate()
			b.resize(rng.randi() % (b.size() + 1))
		elif mode == 2:                                 # valid packet with a few corrupted bytes
			b = (valid_samples[rng.randi() % valid_samples.size()] as PackedByteArray).duplicate()
			for k in 1 + rng.randi() % 3:
				b[rng.randi() % b.size()] = rng.randi() % 256
		else:                                           # right protocol id, random message and size
			b.resize(5 + rng.randi() % 80)
			b.encode_u32(0, Packet.PROTOCOL_ID)
			b.encode_u8(4, rng.randi() % 9)
			for k in range(5, b.size()):
				b[k] = rng.randi() % 256
		if Packet.parse(b).is_empty():
			rejected += 1
		else:
			accepted += 1
	_ok("fuzz (seed 7601): 10,000 random / truncated / corrupted datagrams, 0 crashes, every rejected one counted", rejected + accepted == 10000 and Packet.malformed == rejected, "%d rejected and counted, %d still valid" % [rejected, accepted])
	var bad := Packet.encode_input(1, 0, [_cmd(1, 1, 1, 1, 1, 1.0)])
	bad.encode_u8(8, 4)
	_ok("cmd_count over 3 is malformed", Packet.parse(bad).is_empty())
	var wrong := Packet.encode_hello()
	wrong.encode_u32(0, 0xDEADBEEF)
	_ok("unknown protocol id is malformed", Packet.parse(wrong).is_empty())


func _oversize() -> void:
	Packet.oversize_refused = 0
	var big := PackedByteArray()
	big.resize(1201)
	var ok_max := PackedByteArray()
	ok_max.resize(1200)
	_ok("oversize send refused: 1,201 bytes refused and counted, 1,200 allowed", not Packet.may_send(big) and Packet.may_send(ok_max) and Packet.oversize_refused == 1)


## `clients` pump both ends until `cond` holds or the time runs out.
func _pump(server, client, srv_in: Array, cli_in: Array, cond: Callable, max_ms: int = 800) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < max_ms:
		for item in client.poll():
			cli_in.append(item)
		for item in server.poll():
			srv_in.append(item)
		if cond.call():
			return true
		OS.delay_usec(200)
	return false


func _sockets(kind: String, port: int) -> void:
	var server = TransportUdp.new() if kind == "udp" else TransportEnet.new()
	var client = TransportUdp.new() if kind == "udp" else TransportEnet.new()
	var e1: int = server.listen(port)
	var e2: int = client.connect_to("127.0.0.1", port)
	_ok("[%s] server listens, client connects" % kind, e1 == OK and e2 == OK)
	var srv_in: Array = []
	var cli_in: Array = []
	if kind == "enet":
		_pump(server, client, srv_in, cli_in, func(): return client.connected, 2000)
	client.send(Packet.encode_hello())
	var got_hello := _pump(server, client, srv_in, cli_in, func(): return srv_in.size() >= 1)
	var peer_id := -1
	if got_hello:
		peer_id = srv_in[0][0]
		var hm := Packet.parse(srv_in[0][1])
		server.send_to(peer_id, Packet.encode_welcome(0, 1, 4, 2))
		var got_welcome := _pump(server, client, srv_in, cli_in, func(): return cli_in.size() >= 1)
		var wm := Packet.parse(cli_in[0]) if got_welcome else {}
		_ok("[%s] handshake: HELLO then WELCOME" % kind, hm.get("msg", 0) == Packet.MSG_HELLO and wm.get("msg", 0) == Packet.MSG_WELCOME and wm["interp_ticks"] == 4)
	else:
		_ok("[%s] handshake: HELLO then WELCOME" % kind, false, "HELLO never arrived")
		return
	srv_in.clear()
	cli_in.clear()
	# 1,000 INPUT datagrams client -> server, byte-identical
	var sent := {}
	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	for i in 1000:
		var cmds: Array = []
		for k in 1 + rng.randi() % 3:
			cmds.append(_cmd(i * 3 + k, i, rng.randi() % 128, rng.randi() % 65536, rng.randi() % 65536, float(rng.randi() % 100000) / 4.0))
		var b := Packet.encode_input(rng.randi() % 65536, rng.randi() % 20, cmds)
		sent[b.hex_encode()] = true
		client.send(b)
		if i % 20 == 19:
			_pump(server, client, srv_in, cli_in, func(): return false, 3)
	_pump(server, client, srv_in, cli_in, func(): return srv_in.size() >= 1000, 1500)
	var all_match := srv_in.size() == 1000
	for item in srv_in:
		if not sent.has((item[1] as PackedByteArray).hex_encode()):
			all_match = false
	_ok("[%s] 1,000 INPUT datagrams round trip, byte-identical" % kind, all_match, "%d received" % srv_in.size())
	srv_in.clear()
	# 1,000 SNAPSHOT datagrams server -> client, byte-identical and decodable
	var sender := SnapshotSender.new()
	var st := PlayerState.new()
	var sent2 := {}
	for i in 1000:
		st.pos_x = float(i) * 1.25
		sender.scratch.clear_entities()
		sender.scratch.set_entity(1 + i % 5, float(i), 0.0, -float(i), i & 0xFFFF, 32768, i % 4, true)
		var snap := sender.build(i, i, st, SnapshotSender.stub_hud(st))
		var pkt := Packet.encode_snapshot(snap)
		sent2[pkt.hex_encode()] = true
		server.send_to(peer_id, pkt)
		if i % 20 == 19:
			_pump(server, client, srv_in, cli_in, func(): return false, 3)
	_pump(server, client, srv_in, cli_in, func(): return cli_in.size() >= 1000, 1500)
	var snap_match := cli_in.size() == 1000
	var decodable := 0
	for item in cli_in:
		if not sent2.has((item as PackedByteArray).hex_encode()):
			snap_match = false
		var pm := Packet.parse(item)
		if not pm.is_empty() and Snapshot.decode(pm["snapshot"], null) != null or (not pm.is_empty() and Snapshot.peek(pm["snapshot"]).get("kind", 0) == Snapshot.KIND_DELTA):
			decodable += 1
	_ok("[%s] 1,000 SNAPSHOT datagrams round trip, byte-identical" % kind, snap_match, "%d received, %d parse as snapshots" % [cli_in.size(), decodable])
	# a 1,200-byte datagram makes it
	cli_in.clear()
	var max_pkt := PackedByteArray()
	max_pkt.resize(1200)
	max_pkt.encode_u32(0, Packet.PROTOCOL_ID)
	max_pkt.encode_u8(4, Packet.MSG_SNAPSHOT)
	server.send_to(peer_id, max_pkt)
	_pump(server, client, srv_in, cli_in, func(): return cli_in.size() >= 1)
	_ok("[%s] a 1,200-byte datagram arrives whole" % kind, cli_in.size() == 1 and (cli_in[0] as PackedByteArray).size() == 1200)
	# garbage over the real socket: counted, the server survives, a valid packet still works afterwards
	srv_in.clear()
	Packet.malformed = 0
	var grng := RandomNumberGenerator.new()
	grng.seed = 7602
	var garbage := 200
	for i in garbage:
		var g := PackedByteArray()
		for k in 1 + grng.randi() % 100:
			g.append(grng.randi() % 256)
		client.send(g)
	_pump(server, client, srv_in, cli_in, func(): return false, 150)
	var counted := 0
	for item in srv_in:
		if Packet.parse(item[1]).is_empty():
			counted += 1
	client.send(Packet.encode_input(1, 0, [_cmd(1, 1, 1, 1, 1, 1.0)]))
	srv_in.clear()
	_pump(server, client, srv_in, cli_in, func(): return srv_in.size() >= 1)
	var alive := srv_in.size() >= 1 and not Packet.parse(srv_in[0][1]).is_empty()
	_ok("[%s] %d garbage datagrams over the real socket: all counted malformed (%d), server unharmed" % [kind, garbage, counted], counted > garbage - 5 and alive and Packet.malformed >= counted)
	client.close()
	server.close()


## Server (ServerMain._tick driven by hand) and a client in lockstep over a real socket; the server measures the RTT.
func _rtt(kind: String, shimmed: bool, port: int) -> void:
	var srv := ServerMain.new()
	srv.setup(PackedStringArray(["--port", str(port), "--transport", kind]))
	var inner = TransportUdp.new() if kind == "udp" else TransportEnet.new()
	inner.connect_to("127.0.0.1", port)
	var shim: TransportShim = null
	var tr = inner
	if shimmed:
		shim = TransportShim.new(inner, 3, 80.0, 0.0, 0.0)       # 80 ms, no loss (RTT check), jitter off
		tr = shim
	var ep := NetEndpoint.new(tr)
	var nc := NetClient.new()
	nc.setup(Movement.default_world(), ep)
	var hello_at := -999
	for i in 400:
		if shim != null:
			shim.now_ms = float(i) * (1000.0 / 128.0)
		if ep.welcome.is_empty():
			if i - hello_at > 10:
				hello_at = i
				ep.send_hello()
			for raw in tr.poll():
				var m := Packet.parse(raw)
				if not m.is_empty() and m["msg"] == Packet.MSG_WELCOME:
					ep.welcome = m
				elif not m.is_empty() and m["msg"] == Packet.MSG_CHALLENGE:
					ep.cookie = m["cookie"]
			OS.delay_usec(500)
			srv._tick()
		else:
			break
	var welcomed := not ep.welcome.is_empty()
	var start := 400 if not welcomed else 0
	var c := 0
	if welcomed:
		for k in 700:
			ep.tick = c
			if shim != null:
				shim.now_ms = float(1000 + c) * (1000.0 / 128.0)
			var i := Bots.input("run", c, nc.get_player_state())
			nc.send_input(InputCmd.make(0, c, i[0], i[1], i[2]))
			nc.poll_and_update(c)
			OS.delay_usec(500)
			srv._tick()
			c += 1
	var rtt := -1.0
	for sl in srv.server.slots:
		if sl != null:
			rtt = (sl as ClientSlot).rtt_ticks
	var label := "[%s] server-measured RTT on %s" % [kind, "the shim at 80 ms" if shimmed else "clean loopback"]
	if shimmed:
		_ok(label + " = 10 to 13 ticks (about 80 to 100 ms; the shim quantizes to 6 ticks each way)", welcomed and rtt >= 10.0 and rtt <= 13.0, "%.2f ticks = %.1f ms" % [rtt, rtt * 7.8125])
	else:
		_ok(label + " < 2 ticks", welcomed and rtt >= 0.0 and rtt < 2.0, "%.2f ticks = %.1f ms" % [rtt, rtt * 7.8125])
	nc.free()
	tr.close()
	srv.transport.close()
	srv.free()
