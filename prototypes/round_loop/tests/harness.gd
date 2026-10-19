extends RefCounted
## Tiny shared check helper for the headless tests.

var passed: int = 0
var failed: int = 0


func check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		passed += 1
		print("PASS  ", name, ("  " + detail) if detail != "" else "")
	else:
		failed += 1
		print("FAIL  ", name, ("  " + detail) if detail != "" else "")


func eq_f(name: String, got: float, want: float, tol: float = 1e-9) -> void:
	check(name, absf(got - want) <= tol, "got %.6f want %.6f" % [got, want])


func eq(name: String, got, want) -> void:
	check(name, got == want, "got %s want %s" % [str(got), str(want)])
