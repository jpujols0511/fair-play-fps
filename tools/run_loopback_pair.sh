#!/usr/bin/env bash
# Two real processes on loopback: a headless dedicated server and a headless bot client (Phase 6).
#   tools/run_loopback_pair.sh <minutes> [--shim 80,0.02[,5]] [--transport enet|udp] [--port N] [--bot mixed]
# The handout's soak is 10 minutes (76,800 ticks): tools/run_loopback_pair.sh 10
# Nothing in this script uses sudo. Prints both exit codes, the stats lines, and the verdict from
# tests/soak_loopback.gd (exit 1 if a process or a criterion fails).
set -u
GODOT="${GODOT:-$HOME/bin/godot-4.4.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
P="$ROOT/prototypes/prediction_loop"
MIN="${1:-1}"; shift || true
SHIM=""; TRANSPORT="enet"; PORT=27015; BOT="mixed"; BOTS=0; WORLD="default"
while [ $# -gt 0 ]; do
  case "$1" in
    --shim) SHIM="$2"; shift 2;;
    --transport) TRANSPORT="$2"; shift 2;;
    --port) PORT="$2"; shift 2;;
    --bot) BOT="$2"; shift 2;;
    --bots) BOTS="$2"; shift 2;;       # N server-side bots (Phase 8); the client then runs in the crouch world
    --world) WORLD="$2"; shift 2;;
    *) echo "unknown option $1"; exit 2;;
  esac
done
[ "$BOTS" -gt 0 ] && WORLD="crouch"
TAG="${TRANSPORT}_${MIN}min${SHIM:+_shim}${BOTS:+_bots$BOTS}"
[ "$BOTS" -eq 0 ] && TAG="${TRANSPORT}_${MIN}min${SHIM:+_shim}"
LOGDIR="$P/tests/logs"; mkdir -p "$LOGDIR"
SLOG="$LOGDIR/soak_${TAG}_server.log"; CLOG="$LOGDIR/soak_${TAG}_client.log"
TICKS=$(( MIN * 7680 ))
( cd "$P" && "$GODOT" --headless --path . -- --server --port "$PORT" --transport "$TRANSPORT" --exit-on-bye ${BOTS:+--bots $BOTS} --max-seconds $(( MIN * 60 + 90 )) > "$SLOG" 2>&1 ) &
SPID=$!
for i in $(seq 1 100); do grep -q "SERVER listening" "$SLOG" 2>/dev/null && break; sleep 0.1; done
( cd "$P" && "$GODOT" --headless --path . -- --client --connect "127.0.0.1:$PORT" --transport "$TRANSPORT" --bot "$BOT" --world "$WORLD" --ticks "$TICKS" ${SHIM:+--shim "$SHIM"} > "$CLOG" 2>&1 ) &
CPID=$!
wait "$CPID"; CCODE=$?
wait "$SPID"; SCODE=$?
echo "server exit code: $SCODE    client exit code: $CCODE"
grep -h "SERVER_FINAL\|CLIENT_STATS" "$SLOG" "$CLOG"
MODE="clean"; [ -n "$SHIM" ] && MODE="shim"
( cd "$P" && "$GODOT" --headless --path . --script res://tests/soak_loopback.gd -- "$SLOG" "$CLOG" "$MODE" $([ "$BOTS" -gt 0 ] && echo bots) )
VCODE=$?
if [ "$SCODE" -ne 0 ] || [ "$CCODE" -ne 0 ]; then exit 1; fi
exit $VCODE
