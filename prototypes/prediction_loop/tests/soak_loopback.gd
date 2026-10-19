extends SceneTree
## Evaluates a two-process loopback run (Phase 6):
##   godot --headless --script res://tests/soak_loopback.gd -- <server.log> <client.log> <clean|shim> [bots]
## Called by tools/run_loopback_pair.sh. Criteria (handout Phase 6):
##   clean loopback: 0 unexplained corrections, 0 script errors in either log
##   shim 80 ms / 2%: the S3 lines hold: error p99 < 1.0 and max < 8.0, every correction explained by a fully lost command
##   both: server overruns <= 0.1% of ticks, memory growth after minute 1 <= 5 MB, no datagram over 1,200 bytes

var failed := 0


func _init() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 3:
		print("usage: -- <server.log> <client.log> <clean|shim>")
		quit(2)
		return
	var s_text := FileAccess.get_file_as_string(a[0])
	var c_text := FileAccess.get_file_as_string(a[1])
	var mode := a[2]
	var sf := _kv(s_text, "SERVER_FINAL")
	var cs := _kv(c_text, "CLIENT_STATS")
	if sf.is_empty() or cs.is_empty():
		print("FAIL  missing SERVER_FINAL or CLIENT_STATS (a process did not finish)")
		quit(1)
		return
	var errs := _count_errors(s_text) + _count_errors(c_text)
	_check("no script errors in either log", errs == 0, "%d error lines" % errs)
	var lost := _last_kv(s_text, "SERVER_STATS", "cmds_fully_lost")
	var corr := int(cs["corrections"])
	if mode == "clean":
		_check("clean loopback: 0 unexplained corrections", corr == 0 and lost == 0, "%d corrections, %d fully lost commands" % [corr, lost])
	else:
		_check("shim 80 ms / 2%: every correction is explained by a fully lost command", corr <= lost, "%d corrections, %d fully lost commands" % [corr, lost])
		_check("shim: error p99 < 1.0 unit", float(cs["error_p99"]) < 1.0, "p99 %.4f" % float(cs["error_p99"]))
		_check("shim: error max < 8.0 units", float(cs["error_max"]) < 8.0, "max %.4f" % float(cs["error_max"]))
	_check("server overruns <= 0.1% of ticks", float(sf["overrun_pct"]) <= 0.1, "%s%% (%s overruns in %s ticks)" % [sf["overrun_pct"], sf["overruns"], sf["ticks"]])
	_check("client overruns <= 0.1% of ticks", float(cs["overrun_pct"]) <= 0.1, "%s%% (%s ticks)" % [cs["overrun_pct"], cs["ticks"]])
	_check("client memory growth after minute 1 <= 5 MB", float(cs["mem_growth_after_minute_MB"]) <= 5.0, "%s MB (minute-1 %s MB, end %s MB)" % [cs["mem_growth_after_minute_MB"], cs["mem_minute_MB"], cs["mem_end_MB"]])
	var s_first := _first_mem_after(s_text, 60 * 128)
	var s_last := float(sf["mem_MB"])
	_check("server memory growth after minute 1 <= 5 MB", s_first < 0.0 or s_last - s_first <= 5.0, "%.2f MB -> %.2f MB" % [s_first, s_last])
	_check("no datagram over 1,200 bytes was sent (refusals: server %s, client 0 in this build)" % sf["oversize_refused"], int(sf["oversize_refused"]) == 0)
	_check("no malformed datagrams on a clean link", int(sf["malformed"]) == 0 and int(cs["malformed"]) == 0, "server %s, client %s" % [sf["malformed"], cs["malformed"]])
	if a.size() > 3 and a[3] == "bots":
		_bot_masks(s_text, c_text)
	print("REPORT  bytes/s: down (server -> client) %.0f, up (client -> server) %.0f; rtt %.1f ms; snapshots %s; snapshot loss %.3f" % [float(cs["rx_B_per_s"]), float(cs["tx_B_per_s"]), float(cs["rtt_ms"]), cs["snapshots"], float(cs["snapshot_loss"])])
	print("\n%s" % ("SOAK PASS" if failed == 0 else "SOAK FAIL (%d)" % failed))
	quit(1 if failed > 0 else 0)


func _check(name: String, ok: bool, detail: String = "") -> void:
	print("%s  %s  %s" % ["PASS" if ok else "FAIL", name, detail])
	if not ok:
		failed += 1


func _kv(text: String, key: String) -> Dictionary:
	for line in text.split("\n"):
		if line.begins_with(key + " "):
			var d := {}
			for part in line.split(" "):
				var kv := part.split("=")
				if kv.size() == 2:
					d[kv[0]] = kv[1]
			return d
	return {}


func _last_kv(text: String, key: String, field: String) -> int:
	var v := 0
	for line in text.split("\n"):
		if line.begins_with(key + " "):
			for part in line.split(" "):
				if part.begins_with(field + "="):
					v = int(part.substr(field.length() + 1))
	return v


func _first_mem_after(text: String, tick: int) -> float:
	for line in text.split("\n"):
		if line.begins_with("SERVER_STATS "):
			var t := -1
			var m := -1.0
			for part in line.split(" "):
				if part.begins_with("tick="):
					t = int(part.substr(5))
				elif part.begins_with("mem_MB="):
					m = float(part.substr(7))
			if t >= tick:
				return m
	return -1.0


func _count_errors(text: String) -> int:
	var n := 0
	for line in text.split("\n"):
		if line.begins_with("SCRIPT ERROR") or line.begins_with("ERROR:") or line.begins_with("CLIENT_ERROR") or line.begins_with("SERVER_ERROR"):
			n += 1
	return n


## Phase 8: what the client decoded must equal what the server decided to send, tick for tick.
func _bot_masks(s_text: String, c_text: String) -> void:
	var c := _kv(c_text, "CLIENT_MASKS")
	var slot := int(c.get("slot", "-1"))
	var s_changes := ""
	for line in s_text.split("\n"):
		if line.begins_with("SERVER_MASKS slot=%d " % slot):
			s_changes = line.split("changes=")[1]
	var server: Array = _parse(s_changes)
	var client: Array = _parse(c.get("changes", ""))
	var mismatches := 0
	var si := 0
	var cur := -1
	for rec in client:
		while si < server.size() and server[si][0] <= rec[0]:
			cur = server[si][1]
			si += 1
		if rec[1] != cur:
			mismatches += 1
	_check("bots: every mask the client decoded equals the server's sent mask at that tick", not client.is_empty() and mismatches == 0, "%d client records, %d server records, %d mismatches" % [client.size(), server.size(), mismatches])
	var flips := 0
	for i in range(1, client.size()):
		if (client[i][1] ^ client[i - 1][1]) & ((1 << 4) | (1 << 9)) != 0:
			flips += 1
	_check("bots: the client sees the cover_peek bots (slots 4 and 9) flip in and out", flips >= 10, "%d flips decoded, server made %d mask changes" % [flips, server.size()])


func _parse(text: String) -> Array:
	var out: Array = []
	if text.strip_edges() == "":
		return out
	for part in text.strip_edges().split(","):
		var kv := part.split(":")
		out.append([int(kv[0]), int(kv[1])])
	return out
