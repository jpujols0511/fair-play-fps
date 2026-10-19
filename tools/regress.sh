#!/usr/bin/env bash
# Regression block (mega handoff Section 2.7): S2 parity + crouch + S1-S9 + sim diff.
# Usage: GODOT=~/bin/godot-4.4.1 tools/regress.sh [--quick]
# Writes captured output to movement_proto/tests/logs/ and prototypes/prediction_loop/tests/logs/.
set -u
GODOT="${GODOT:-$HOME/bin/godot-4.4.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QUICK=""
[ "${1:-}" = "--quick" ] && QUICK="-- --quick"
fail=0
run() { # name dir script logdir
  local name="$1" dir="$2" script="$3" log="$4"
  mkdir -p "$log"
  (cd "$dir" && "$GODOT" --headless --script "res://tests/$script.gd" ${5:-} > "$log/$name.log" 2>&1)
  local code=$?
  echo "$name exit=$code: $(grep -E 'passed|gates passed' "$log/$name.log" | tail -1)"
  [ $code -ne 0 ] && fail=1
}
"$GODOT" --version
(cd "$ROOT/movement_proto" && "$GODOT" --headless --import >/dev/null 2>&1)
M="$ROOT/movement_proto"; ML="$M/tests/logs"
for f in "$M"/tests/test_*.gd; do n="$(basename "$f" .gd)"; run "$n" "$M" "$n" "$ML"; done
P="$ROOT/prototypes/prediction_loop"; PL="$P/tests/logs"
(cd "$P" && "$GODOT" --headless --import >/dev/null 2>&1)
for f in "$P"/tests/test_*.gd; do n="$(basename "$f" .gd)"; run "$n" "$P" "$n" "$PL"; done
[ -f "$P/tests/run_wallhack_bait.gd" ] && run run_wallhack_bait "$P" run_wallhack_bait "$PL"
run run_headless "$P" run_headless "$PL" "$QUICK"
if [ -f "$P/scripts/net/remote_paths.gd" ]; then
  run run_headless_remotes10 "$P" run_headless "$PL" "-- ${QUICK#-- } --remotes 10"
fi
cd "$ROOT"
if python3 specs/goldsrc_movement_sim.py | diff - specs/sim_results.txt >/dev/null; then echo "movement sim unchanged"; else echo "FAIL: movement sim output changed"; fail=1; fi
python3 specs/goldsrc_movement_sim.py --emit-cases /tmp/_c1.json >/dev/null && cmp -s /tmp/_c1.json movement_proto/tests/reference_cases.json && echo "reference_cases.json identical" || { echo "FAIL: reference_cases.json changed"; fail=1; }
python3 specs/goldsrc_movement_sim.py --emit-cases-phase3 /tmp/_c2.json >/dev/null && cmp -s /tmp/_c2.json movement_proto/tests/reference_cases_phase3.json && echo "reference_cases_phase3.json identical" || { echo "FAIL: phase3 cases changed"; fail=1; }
exit $fail
