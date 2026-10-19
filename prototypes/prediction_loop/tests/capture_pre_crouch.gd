extends SceneTree
## One-off capture (Phase 1): player states of every bot BEFORE crouch existed, so the
## crouch change can prove it is bit-identical when duck is never pressed.
## Format: bot, tick, hex of the first 10 PlayerState fields (to_packed()[0..9]).
func _init() -> void:
	var lines := PackedStringArray()
	for kind in Bots.KINDS + ["mixed"]:
		var s := Session.new(1, 0.0, 0.0, false, false, false)
		for t in 4001:
			var i := Bots.input(kind, t, s.client.predicted)
			s.tick_once(i[0], i[1], i[2])
			if t % 250 == 0:
				lines.append("%s %d %s" % [kind, t, s.client.predicted.hex().substr(0, 160)])
	var f := FileAccess.open("res://tests/golden/pre_crouch_states.txt", FileAccess.WRITE)
	f.store_string("\n".join(lines) + "\n")
	print("captured ", lines.size(), " lines")
	quit()
