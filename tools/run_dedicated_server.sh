#!/usr/bin/env bash
# Start the headless dedicated server (Phase 7). Extra args are passed through, e.g. --port 27015 --transport enet --interp 4
#   GODOT=~/bin/godot-4.4.1 tools/run_dedicated_server.sh [--port N] [--transport enet|udp] [--bots N] [--max-seconds N]
# Nothing here uses sudo.
set -u
GODOT="${GODOT:-$HOME/bin/godot-4.4.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/prototypes/prediction_loop" && exec "$GODOT" --headless --path . -- --server "$@"
