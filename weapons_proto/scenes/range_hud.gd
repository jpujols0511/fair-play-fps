extends CanvasLayer

const INK := Color("#101819")
const PAPER := Color("#e8e2d3")
const ACID := Color("#d2ff6b")
const SIGNAL := Color("#ff8b45")
const MUTED := Color("#879595")

var _title: Label
var _telemetry: RichTextLabel
var _footer: Label
var _result_line: Label


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var panel := PanelContainer.new()
	panel.position = Vector2(24.0, 24.0)
	panel.custom_minimum_size = Vector2(470.0, 270.0)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(INK, 0.94)
	style.border_width_left = 3
	style.border_color = ACID
	style.corner_radius_top_left = 3
	style.corner_radius_bottom_left = 3
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 13.0
	style.content_margin_bottom = 13.0
	panel.add_theme_stylebox_override("panel", style)
	root.add_child(panel)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 5)
	panel.add_child(column)

	_title = Label.new()
	_title.text = "RANGE / SERVER SIM"
	_title.add_theme_color_override("font_color", ACID)
	_title.add_theme_font_size_override("font_size", 21)
	column.add_child(_title)

	var rule := ColorRect.new()
	rule.color = Color(ACID, 0.55)
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	column.add_child(rule)

	_result_line = Label.new()
	_result_line.text = "READY  //  NO SHOT"
	_result_line.add_theme_color_override("font_color", PAPER)
	_result_line.add_theme_font_size_override("font_size", 16)
	column.add_child(_result_line)

	_telemetry = RichTextLabel.new()
	_telemetry.bbcode_enabled = true
	_telemetry.fit_content = true
	_telemetry.scroll_active = false
	_telemetry.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_telemetry.add_theme_color_override("default_color", PAPER)
	_telemetry.add_theme_font_size_override("normal_font_size", 14)
	column.add_child(_telemetry)

	_footer = Label.new()
	_footer.add_theme_color_override("font_color", MUTED)
	_footer.add_theme_font_size_override("font_size", 12)
	_footer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_footer)

	var badge := Label.new()
	badge.text = "DEBUG CONTROLS  B BACKTRACK   N SNAPBACK   L VERIFY   K REVIEW"
	badge.position = Vector2(24.0, 314.0)
	badge.add_theme_color_override("font_color", SIGNAL)
	badge.add_theme_font_size_override("font_size", 12)
	root.add_child(badge)
	update_state({})


func update_state(state: Dictionary) -> void:
	if is_instance_valid(_title):
		_title.text = "RANGE / SERVER SIM   //   %s" % str(state.get("weapon_label", "RIFLE 01"))
	var shot_text := str(state.get("last_result", "NO SHOT"))
	var shot_color: Color = ACID if shot_text.begins_with("HIT") else SIGNAL if shot_text.begins_with("NEAR") else PAPER
	if is_instance_valid(_result_line):
		_result_line.text = "LAST SHOT  //  %s" % shot_text
		_result_line.add_theme_color_override("font_color", shot_color)
	if is_instance_valid(_telemetry):
		var ping := int(state.get("ping_ms", 0))
		var interp := int(state.get("interp_ticks", 4))
		var rewind_ticks := float(state.get("rewind_ticks", 0.0))
		var spread := float(state.get("spread_at_fire", 0.0))
		var reason := str(state.get("rewind_reason", "none"))
		var rewind_flags := str(state.get("rewind_flags", "none"))
		var aim_flags := str(state.get("aim_kin_flags", "none"))
		var records: Dictionary = state.get("record_counts", {})
		var debug_text := str(state.get("debug_modes", "none"))
		_telemetry.text = (
			"[color=#879595]SIMULATION[/color]   128 Hz     "
			+ "PING %d ms     INTERP %d ticks\n" % [ping, interp]
			+ "[color=#879595]REWIND[/color]       %.2f ticks (%.1f ms)    %s\n"
				% [rewind_ticks, rewind_ticks * 1000.0 / 128.0, reason]
			+ "[color=#879595]DECISION[/color]     %s\n" % rewind_flags
			+ "[color=#879595]SPREAD[/color]       %.4f    [color=#879595]AIM_KIN[/color] %s\n"
				% [spread, aim_flags]
			+ "[color=#879595]DEBUG[/color]         %s\n" % debug_text
			+ "[color=#879595]LEDGER[/color]        SHOT %d  VIS %d  REWIND %d  INPUT %d  AIM %d"
				% [
					int(records.get("shot", 0)),
					int(records.get("vis", 0)),
					int(records.get("rewind", 0)),
					int(records.get("input_reject", 0)),
					int(records.get("aim_kin", 0)),
				]
		)
	if is_instance_valid(_footer):
		var verify := str(state.get("verify_status", "EVIDENCE OPEN"))
		var review := str(state.get("review_status", ""))
		_footer.text = "%s%s" % [verify, "   //   " + review if not review.is_empty() else ""]
