class_name Session
extends RefCounted
## One fake-network session: FakeNet + FakeServer + Client. tick_once() is THE tick
## (main.gd calls it from its 128 Hz physics tick; the headless runner calls the same one),
## in this fixed order, never left to Godot's node order:
##   1) FakeNet delivers due packets
##   2) FakeServer steps (and sends state every 2nd tick)
##   3) Client reads input, predicts, sends
##   4) Client reconciles against any server state that arrived
##   5) smoothing, then HUD / CSV

const CSV_HEADER := "tick,seq,cx,cy,cz,cspeed,sx,sy,sz,server_seq,rec,err,replay,vx,vy,vz,off,drop_c2s,drop_s2c,lost"

var tick := 0
var seed_value := 1
var world: Array = Movement.default_world()
var net: FakeNet
var server: FakeServer
var client: Client

var csv_on := false
var csv := PackedStringArray()
var oracle := false                 # compare every seq's first prediction with the server's result
var teleports: Array = []           # [tick, x, y, z, flag]
var config_log: Array = []          # [tick, ping_ms, loss, jitter_on]; replayed by Recorder
var ping_ms := 80.0
var loss := 0.02
var jitter_on := false
var start_ping := 80.0
var start_loss := 0.02
var start_jitter := false
var cmd_log: Array = []             # [buttons, yaw_q, pitch_q] per tick, for recordings

# oracle / gate stats
var seq_errors := PackedFloat64Array()
var seq_mismatches := 0
var unexplained_corrections := 0
var explained_corrections := 0
var reconcile_errors := PackedFloat64Array()   # error measured at each correction, before it is applied
var max_unexplained_visual := 0.0
var replay_lens := PackedInt32Array()

# remote-player measurements (Phase 3), only when measure_remotes is on
var measure_remotes := false
var e_interp := PackedFloat64Array()      # drawn pose vs the exact path at render_tick, outside snap windows
var e_interp_all := PackedFloat64Array()  # same, every tick (snaps included)
var e_bridged := PackedFloat64Array()     # error when the draw bridges a lost snapshot (bracketing samples more than 2 ticks apart)
var e_by_kind := {}                       # RemotePath.Kind -> PackedFloat64Array (clean + bridged samples)
var e_recovery := PackedFloat64Array()    # error on ticks that are starved or blending back (explained by 2+ lost snapshots)
var e_true := PackedFloat64Array()        # drawn pose vs the true pose now (what "behind" costs)
var latency_ticks := PackedFloat64Array() # tick - render_tick
var snap_window_ticks := 0
const WARMUP_TICKS := 48


func _init(p_seed: int = 1, ping_ms_in: float = 80.0, p_loss: float = 0.02, jitter_in: bool = false, p_oracle: bool = false, p_csv: bool = false) -> void:
	seed_value = p_seed
	ping_ms = ping_ms_in
	start_ping = ping_ms_in
	start_loss = p_loss
	start_jitter = jitter_in
	loss = p_loss
	jitter_on = jitter_in
	net = FakeNet.new(p_seed, ping_ms, p_loss, jitter_in)
	server = FakeServer.new(world)
	client = Client.new(world)
	oracle = p_oracle
	csv_on = p_csv
	server.keep_history = p_oracle
	client.keep_history = p_oracle
	if p_csv:
		csv.append(CSV_HEADER)


## Change the network mid-run (HUD presets). Logged so a recording can replay it.
func apply_config(p_ping_ms: float, p_loss: float, p_jitter_on: bool) -> void:
	ping_ms = p_ping_ms
	loss = p_loss
	jitter_on = p_jitter_on
	net.configure(seed_value, p_ping_ms, p_loss, p_jitter_on)
	config_log.append([tick, p_ping_ms, p_loss, p_jitter_on])


func schedule_teleport(at_tick: int, x: float, y: float, z: float, flag: bool = true) -> void:
	teleports.append([at_tick, x, y, z, flag])


func tick_once(buttons: int, yaw_q: int, pitch_q: int) -> void:
	var now := float(tick) * (1000.0 / Movement.TICK_RATE)
	cmd_log.append([buttons, yaw_q, pitch_q])

	# 1) network delivers
	var c2s := net.deliver(FakeNet.C2S, now)
	var s2c := net.deliver(FakeNet.S2C, now)

	# 2) server steps
	for ev in teleports:
		if ev[0] == tick:
			server.teleport(ev[1], ev[2], ev[3], ev[4])
	for packet in c2s:
		server.receive(packet)
	var snap: Variant = server.step(tick)
	if snap != null:
		net.send(FakeNet.S2C, snap, now)
	if oracle:
		for seq in server.executed_now:
			var sp: PackedFloat64Array = server.history[seq]
			var cp: PackedFloat64Array = client.first_pred[seq]
			if sp != cp:
				seq_mismatches += 1
			seq_errors.append(sqrt(pow(sp[0] - cp[0], 2.0) + pow(sp[1] - cp[1], 2.0) + pow(sp[2] - cp[2], 2.0)))

	# 3) client predicts and sends
	net.send(FakeNet.C2S, client.predict(buttons, yaw_q, pitch_q, tick), now)

	# 4) client reconciles
	client.reconcile(s2c)
	for e in client.reconcile_log:
		if e[2]:
			reconcile_errors.append(e[1])
			replay_lens.append(client.last_replay_len)
			var explained := false
			for key: int in server.disturbances:
				if key > e[3] and key <= e[0]:
					explained = true
					break
			if explained:
				explained_corrections += 1
			else:
				unexplained_corrections += 1

	# 5) smoothing, then HUD / CSV
	client.smooth()
	client.update_remotes(tick)
	if measure_remotes and tick >= WARMUP_TICKS:
		_measure_remotes()
	max_unexplained_visual = maxf(max_unexplained_visual, client.unexplained)
	if csv_on:
		_csv_row()
	tick += 1


func add_remote(r: RemotePath) -> void:
	server.remotes.append(r)


func _measure_remotes() -> void:
	var rt := client.render_tick
	latency_ticks.append(float(tick) - rt)
	for r: RemotePath in server.remotes:
		if client.remote_visible[r.slot] == 0:
			continue
		var b: InterpBuffer = client.remotes[r.slot]
		var truth := r.exact_at(rt)
		var d := sqrt(pow(b.out_x - truth[0], 2.0) + pow(b.out_y - truth[1], 2.0) + pow(b.out_z - truth[2], 2.0))
		var now_pose := r.exact_at(float(tick))
		e_true.append(sqrt(pow(b.out_x - now_pose[0], 2.0) + pow(b.out_y - now_pose[1], 2.0) + pow(b.out_z - now_pose[2], 2.0)))
		e_interp_all.append(d)
		var fl := int(floorf(rt))
		var in_window := false
		for tp in r.teleport_ticks:
			if tp >= fl - 2 and tp <= fl + 3:
				in_window = true
		if r.spawn_tick >= fl - 2 and r.spawn_tick <= fl + 3 and r.spawn_tick > 0:
			in_window = true
		if r.despawn_tick >= 0 and r.despawn_tick >= fl - 2 and r.despawn_tick <= fl + 3:
			in_window = true
		if in_window:
			snap_window_ticks += 1
		elif b.out_recovering:
			e_recovery.append(d)
		else:
			var ka: PackedFloat64Array = e_by_kind.get(r.kind, PackedFloat64Array())
			ka.append(d)
			e_by_kind[r.kind] = ka
			if b.out_gap > 2:
				e_bridged.append(d)
			else:
				e_interp.append(d)


func _csv_row() -> void:
	var rec := 0
	var err := 0.0
	for e in client.reconcile_log:
		rec = 2 if e[2] else maxi(rec, 1)
		err = maxf(err, e[1])
	var c := client.predicted
	var s := server.state
	csv.append("%d,%d,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d,%.6f,%d,%.6f,%.6f,%.6f,%.6f,%d,%d,%d" % [
		tick, client.next_seq - 1, c.pos_x, c.pos_y, c.pos_z, c.speed(), s.pos_x, s.pos_y, s.pos_z,
		server.next_seq - 1, rec, err, client.last_replay_len if rec == 2 else 0,
		client.visual.x, client.visual.y, client.visual.z, client.offset.length(),
		net.dropped[FakeNet.C2S], net.dropped[FakeNet.S2C], server.lost_seqs.size()])


func csv_sha256() -> String:
	return "\n".join(csv).sha256_text()


func final_hex() -> String:
	return server.state.hex() + "|" + client.predicted.hex()
