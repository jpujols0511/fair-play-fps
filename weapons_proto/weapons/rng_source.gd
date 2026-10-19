class_name RngSource
extends RefCounted

class ReplayRng extends RefCounted:
	var _draws: Array = []
	var _index := 0
	var _emit_errors := true
	var failed := false
	var failure_message := ""

	func _init(draws: Array, emit_errors: bool = true) -> void:
		_draws = draws.duplicate(true)
		_emit_errors = emit_errors

	func uniform(a: float, b: float) -> float:
		var value: Variant = _take("uniform", [a, b])
		return float(value)

	func randint(a: int, b: int) -> int:
		var value: Variant = _take("randint", [a, b])
		return int(value)

	func draws_consumed() -> int:
		return _index

	func remaining_count() -> int:
		return maxi(_draws.size() - _index, 0)

	func _take(kind: String, args: Array) -> Variant:
		if failed:
			return NAN if kind == "uniform" else -1
		if _index >= _draws.size():
			_fail("ReplayRng exhausted before %s draw %d" % [kind, _index + 1])
			return NAN if kind == "uniform" else -1

		var draw: Dictionary = _draws[_index]
		if draw.get("kind", "") != kind:
			_fail("ReplayRng expected %s draw %d, got %s" % [kind, _index + 1, draw.get("kind", "missing")])
			return NAN if kind == "uniform" else -1

		var expected_args: Array = draw.get("args", [])
		if expected_args.size() != args.size():
			_fail("ReplayRng %s draw %d has wrong argument count" % [kind, _index + 1])
			return NAN if kind == "uniform" else -1
		for i in range(args.size()):
			if kind == "uniform":
				if float(expected_args[i]) != float(args[i]):
					_fail("ReplayRng uniform draw %d has wrong bounds" % (_index + 1))
					return NAN
			elif int(expected_args[i]) != int(args[i]):
				_fail("ReplayRng randint draw %d has wrong bounds" % (_index + 1))
				return -1

		_index += 1
		return draw.get("value")

	func _fail(message: String) -> void:
		failed = true
		failure_message = message
		if _emit_errors:
			push_error(message)


class GodotRng extends RefCounted:
	var _rng := RandomNumberGenerator.new()

	func _init(seed_value: int = 1) -> void:
		_rng.seed = seed_value

	func uniform(a: float, b: float) -> float:
		return _rng.randf_range(a, b)

	func randint(a: int, b: int) -> int:
		return _rng.randi_range(a, b)
