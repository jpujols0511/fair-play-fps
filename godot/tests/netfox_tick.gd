extends SceneTree
## Netfox's NetworkTime tick loop drives the fairness kernel.
##
## Netfox owns timing (and later prediction, rollback and synchronization);
## the kernel keeps every rule and outcome. Runs the same honest command
## stream as prototype/fairplay_sim.py, so the digest must match the oracle.
##
## godot --headless --path godot --script res://tests/netfox_tick.gd

const Kernel = preload("res://kernel/fairplay_kernel.gd")
const TICKS := 32

var kernel
var time_node: Node
var submitted := 0
var deadline := 0


func _initialize() -> void:
	deadline = Time.get_ticks_msec() + 10000
	_begin.call_deferred()


func _begin() -> void:
	time_node = root.get_node_or_null("NetworkTime")
	if time_node == null:
		_finish({"error": "NetworkTime autoload missing"}, 1)
		return
	kernel = Kernel.new(["honest"])
	time_node.on_tick.connect(_on_tick)
	time_node.start()


func _on_tick(_delta: float, _tick: int) -> void:
	if submitted >= TICKS:
		return
	var t := submitted
	kernel.submit("honest", Kernel.command(t, Kernel.INPUT_SCALE if t < TICKS / 2 else 0, 0, 90000,
		t % Kernel.FIRE_INTERVAL_TICKS == 0))
	kernel.step()
	submitted += 1
	if submitted == TICKS:
		_finish({"driver": "netfox NetworkTime", "tickrate": time_node.tickrate,
			"ticks": kernel.tick, "digest": kernel.digest()}, 0)


func _process(_delta: float) -> bool:
	if Time.get_ticks_msec() > deadline and submitted < TICKS:
		_finish({"error": "timed out", "ticks": submitted}, 1)
	return false


func _finish(report: Dictionary, code: int) -> void:
	print(JSON.stringify(report, "", true))
	quit(code)
