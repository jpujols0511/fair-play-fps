extends Control
## Fair Play FPS crosshair v0.1 (specs/crosshair_spec_v0.1.md).
## Pure rendering from snapshot fields. No physics, no input, no spread math.
## The server sends the finished spread as `accuracy`; this file only maps
## numbers to pixels and colors.

const STATE_STAND := 0
const STATE_CROUCH := 1
const STATE_AIR := 2
const STATE_RUN := 3

const STYLE_PLUS := 0
const STYLE_DOT := 1

const COLOR_GREEN := Color(0.2, 1.0, 0.2, 1.0)
const COLOR_YELLOW := Color(1.0, 0.9, 0.1, 1.0)
const COLOR_RED := Color(1.0, 0.2, 0.2, 1.0)

## Node that emits `snapshot_received(snap: Dictionary)` (FakeSnapshotSource now, NetClient later).
@export var source_path: NodePath
@export_enum("Plus", "Dot") var style: int = STYLE_PLUS
## Vertical FOV in degrees. 73.74 = 90 horizontal on 4:3 (classic CS).
@export var vertical_fov_deg: float = 73.74
## Sizes at 1080p, scaled by screen_height / 1080.
@export var arm_len_px: float = 6.0
@export var thickness_px: float = 2.0
@export var min_gap_px: float = 2.0
## Gap clamp as a fraction of screen height.
@export var max_gap_frac: float = 0.25

var _accuracy: float = 0.0
var _punch_pitch: float = 0.0
var _punch_yaw: float = 0.0
var _move_state: int = STATE_STAND


# ---------- pure mapping functions (tested headless) ----------

## Pixels per unit of tan(angle), from screen height and vertical FOV.
static func pixels_per_tan(screen_h: float, vfov_deg: float) -> float:
	return (screen_h * 0.5) / tan(deg_to_rad(vfov_deg) * 0.5)


## Crosshair gap (center to arm start) in pixels for a spread value.
## Spread = max sideways per 1 forward, so gap = largest possible miss on screen.
static func gap_px(accuracy: float, screen_h: float, vfov_deg: float,
		min_gap_1080: float = 2.0, max_frac: float = 0.25) -> float:
	var scale: float = screen_h / 1080.0
	var g: float = maxf(accuracy, 0.0) * pixels_per_tan(screen_h, vfov_deg)
	return clampf(g, min_gap_1080 * scale, max_frac * screen_h)


## Center offset from punch angle (degrees). Pitch positive = up = negative screen y.
static func punch_offset_px(punch_pitch_deg: float, punch_yaw_deg: float,
		screen_h: float, vfov_deg: float) -> Vector2:
	var k: float = pixels_per_tan(screen_h, vfov_deg)
	return Vector2(tan(deg_to_rad(punch_yaw_deg)) * k, -tan(deg_to_rad(punch_pitch_deg)) * k)


## Color per movement state. Crouch = green, same as standing (review note b).
static func color_for_state(move_state: int) -> Color:
	match move_state:
		STATE_RUN:
			return COLOR_YELLOW
		STATE_AIR:
			return COLOR_RED
		_:
			return COLOR_GREEN


# ---------- node wiring ----------

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if source_path != NodePath(""):
		var src: Node = get_node_or_null(source_path)
		if src != null and src.has_signal("snapshot_received"):
			src.snapshot_received.connect(_on_snapshot)


func _on_snapshot(snap: Dictionary) -> void:
	_accuracy = float(snap.get("accuracy", 0.0))
	_punch_pitch = float(snap.get("punch_pitch", 0.0))
	_punch_yaw = float(snap.get("punch_yaw", 0.0))
	_move_state = int(snap.get("move_state", STATE_STAND))
	queue_redraw()


func _draw() -> void:
	var h: float = size.y
	if h <= 0.0:
		return
	var s: float = h / 1080.0
	var col: Color = color_for_state(_move_state)
	var center: Vector2 = size * 0.5 + punch_offset_px(_punch_pitch, _punch_yaw, h, vertical_fov_deg)
	var gap: float = gap_px(_accuracy, h, vertical_fov_deg, min_gap_px, max_gap_frac)
	var arm: float = arm_len_px * s
	var w: float = maxf(thickness_px * s, 1.0)
	if style == STYLE_PLUS:
		draw_line(center + Vector2(gap, 0.0), center + Vector2(gap + arm, 0.0), col, w)
		draw_line(center - Vector2(gap, 0.0), center - Vector2(gap + arm, 0.0), col, w)
		draw_line(center + Vector2(0.0, gap), center + Vector2(0.0, gap + arm), col, w)
		draw_line(center - Vector2(0.0, gap), center - Vector2(0.0, gap + arm), col, w)
	else:
		draw_circle(center, maxf(w, 1.5), col)
		draw_arc(center, gap, 0.0, TAU, 48, Color(col, 0.5), maxf(w * 0.5, 1.0))
