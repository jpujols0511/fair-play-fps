class_name Recorder
extends RefCounted
## Throwaway recording format (JSON): the seed, the starting network settings, every
## quantized command, mid-run network changes and forced teleports, plus the final state as
## exact hex. Floats in the final state are stored as hex bytes so they round-trip bit for bit.


static func to_dict(s: Session) -> Dictionary:
	return {
		"version": 1,
		"seed": s.seed_value,
		"start": {"ping_ms": s.start_ping, "loss": s.start_loss, "jitter": s.start_jitter},
		"ticks": s.tick,
		"cmds": s.cmd_log,
		"config": s.config_log,
		"teleports": s.teleports,
		"final": {"state_hex": s.final_hex(), "csv_sha256": s.csv_sha256() if s.csv_on else ""},
	}


static func save(path: String, d: Dictionary) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(d))
	return true


static func load_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


## Re-runs a recording headless (CSV on) and returns the finished Session.
static func replay(d: Dictionary) -> Session:
	var st: Dictionary = d["start"]
	var s := Session.new(int(d["seed"]), st["ping_ms"], st["loss"], st["jitter"], false, true)
	for tp in d["teleports"]:
		s.schedule_teleport(int(tp[0]), tp[1], tp[2], tp[3], tp[4])
	var cfg: Array = d["config"]
	var ci := 0
	var cmds: Array = d["cmds"]
	for t in int(d["ticks"]):
		while ci < cfg.size() and int(cfg[ci][0]) == t:
			s.apply_config(cfg[ci][1], cfg[ci][2], cfg[ci][3])
			ci += 1
		var c: Array = cmds[t]
		s.tick_once(int(c[0]), int(c[1]), int(c[2]))
	return s
