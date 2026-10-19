extends SceneTree
## Headless test: godot --headless --path . --script res://tests/test_crosshair.gd
## Checks the pure mapping functions (size, color, offset) and wire quantization.

const XH = preload("res://crosshair.gd")
const SRC = preload("res://fake_snapshot_source.gd")

var _pass: int = 0
var _fail: int = 0


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS  ", name, ("  " + detail) if detail != "" else "")
	else:
		_fail += 1
		print("FAIL  ", name, ("  " + detail) if detail != "" else "")


func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _init() -> void:
	print("Godot ", Engine.get_version_info()["string"])
	var vf: float = 73.73979529168804  # 90 deg horizontal on 4:3
	var k: float = XH.pixels_per_tan(1080.0, vf)
	_check("k at 1080p, vfov 73.74", _near(k, 720.0, 1e-6), "k=%.6f" % k)
	_check("k at 1440p", _near(XH.pixels_per_tan(1440.0, vf), 960.0, 1e-6))

	# Size: gap = spread * k, clamped to [2 px * h/1080, 0.25 * h]
	var cases: Array = [
		["AK standing first shot", 0.0055, 3.96],
		["AK standing max", 0.0344, 24.768],
		["AK running", 0.054, 38.88],
		["AK air first shot", 0.12, 86.4],
	]
	for c in cases:
		var g: float = XH.gap_px(c[1], 1080.0, vf)
		_check("gap " + c[0], _near(g, c[2], 1e-3), "%.3f px" % g)
	_check("gap clamps to 25% of height (AK air max 0.54)", _near(XH.gap_px(0.54, 1080.0, vf), 270.0, 1e-6))
	_check("gap min 2 px at 0 spread", _near(XH.gap_px(0.0, 1080.0, vf), 2.0, 1e-6))
	_check("gap min scales at 1440p", _near(XH.gap_px(0.0, 1440.0, vf), 2.0 * 1440.0 / 1080.0, 1e-6))
	_check("negative spread treated as 0", _near(XH.gap_px(-0.1, 1080.0, vf), 2.0, 1e-6))
	_check("gap grows with accuracy value", XH.gap_px(0.02, 1080.0, vf) < XH.gap_px(0.03, 1080.0, vf))

	# Offset: punch up moves crosshair up (negative y); yaw right moves +x
	var o0: Vector2 = XH.punch_offset_px(0.0, 0.0, 1080.0, vf)
	_check("no punch, no offset", o0.length() < 1e-9)
	var o1: Vector2 = XH.punch_offset_px(4.61, 0.0, 1080.0, vf)
	_check("AK peak kick 4.61 deg up -> 58.06 px up", _near(o1.y, -58.0563, 1e-3) and _near(o1.x, 0.0, 1e-9), "y=%.4f" % o1.y)
	var o2: Vector2 = XH.punch_offset_px(0.0, 1.0, 1080.0, vf)
	_check("1 deg yaw -> 12.57 px right", _near(o2.x, 12.5676, 1e-3) and _near(o2.y, 0.0, 1e-9), "x=%.4f" % o2.x)
	var o3: Vector2 = XH.punch_offset_px(-1.0, -1.0, 1080.0, vf)
	_check("negative punch mirrors", _near(o3.x, -12.5676, 1e-3) and _near(o3.y, 12.5676, 1e-3))

	# Color: green stand, green crouch (note b), yellow run, red air
	_check("stand = green", XH.color_for_state(0) == XH.COLOR_GREEN)
	_check("crouch = green (note b)", XH.color_for_state(1) == XH.COLOR_GREEN)
	_check("air = red", XH.color_for_state(2) == XH.COLOR_RED)
	_check("run = yellow", XH.color_for_state(3) == XH.COLOR_YELLOW)

	# Wire quantization (note d)
	var qa: float = SRC.dequantize_accuracy(SRC.quantize_accuracy(0.0055))
	_check("accuracy u16 round trip within half a step", _near(qa, 0.0055, 1.0 / 65535.0), "%.7f" % qa)
	_check("accuracy clamps at 2.0", SRC.quantize_accuracy(5.0) == 65535)
	var qp: float = SRC.dequantize_angle(SRC.quantize_angle(4.61))
	_check("punch i16 round trip within half a step", _near(qp, 4.61, 360.0 / 65536.0 * 0.5), "%.5f" % qp)
	var snap: Dictionary = SRC.make_snapshot(10, 0.054, 1.0, -0.5, 3)
	_check("snapshot has the HUD interface keys",
		snap.has("server_tick") and snap.has("accuracy") and snap.has("punch_pitch")
		and snap.has("punch_yaw") and snap.has("move_state"))
	_check("snapshot values are floats", typeof(snap["accuracy"]) == TYPE_FLOAT and typeof(snap["punch_pitch"]) == TYPE_FLOAT)

	# Scripted source: run one full loop headless and check each segment shows up
	var src: Node = SRC.new()
	src.autorun = false
	src.reset()
	var seen: Dictionary = {}
	var max_punch: float = 0.0
	var sent: int = 0
	for i in range(int(9.0 * 128.0)):
		var s: Dictionary = src.step_tick()
		if s.is_empty():
			continue
		sent += 1
		seen[int(s["move_state"])] = true
		max_punch = maxf(max_punch, float(s["punch_pitch"]))
	_check("fake source sends every 2nd tick (576 per 9 s)", sent == 576, "sent=%d" % sent)
	_check("fake source covers stand, run, air", seen.has(0) and seen.has(2) and seen.has(3))
	_check("spray produces punch (3 < peak <= 5.75 deg)", max_punch > 3.0 and max_punch <= 5.75 + 0.01, "peak=%.2f deg" % max_punch)
	src.free()

	print("RESULT: %d passed, %d failed" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
