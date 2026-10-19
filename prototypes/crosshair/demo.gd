extends Control
## Demo wiring only. Keys pick the simulated delay; the crosshair itself reads no input.
## 0 = 0 ms, 1 = 40 ms, 2 = 80 ms, 3 = 150 ms. S switches plus/dot.

@onready var _src: Node = $FakeSnapshotSource
@onready var _xh: Control = $Crosshair
@onready var _label: Label = $Info


func _ready() -> void:
	_src.snapshot_received.connect(_on_snap)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed:
		return
	match k.keycode:
		KEY_0: _src.delay_ms = 0.0
		KEY_1: _src.delay_ms = 40.0
		KEY_2: _src.delay_ms = 80.0
		KEY_3: _src.delay_ms = 150.0
		KEY_S:
			_xh.style = 1 - _xh.style
			_xh.queue_redraw()


func _on_snap(snap: Dictionary) -> void:
	var names: Array[String] = ["stand", "crouch", "air", "run"]
	_label.text = "segment: %s\nmove_state: %s\naccuracy (spread): %.4f\npunch: up %.2f deg, side %.2f deg\ndelay: %d ms  (keys 0/1/2/3)\nstyle: S to toggle plus/dot" % [
		_src.segment, names[int(snap["move_state"])], float(snap["accuracy"]),
		float(snap["punch_pitch"]), float(snap["punch_yaw"]), int(_src.delay_ms)]
