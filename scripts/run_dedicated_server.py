#!/usr/bin/env python3
"""Run one community-hosted match, then analyse it offline.

    python3 scripts/run_dedicated_server.py --godot /path/to/Godot_v4.4.1 \
        --players alice,bob --ticks 640 --out matches/2026-10-15-a [--demo-clients]

1. Issues a random access token per player into <out>/tokens.json (mode 0600).
   Hand each player their own token; never publish the file.
2. Starts the headless authoritative server (DTLS, 64 Hz) and waits for it.
3. Verifies the server ran the published kernel (godot/kernel/KERNEL_SHA256).
4. Runs detection as a separate process on the recorded demo and writes
   <out>/detection.json. Detection never runs inside the live server.

--demo-clients starts one honest and one controlled attacker test client on
this machine, for a smoke test. Operators change maps, modes and weapons on
the community surface; they never change the kernel.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "godot"
PUBLISHED_KERNEL = (PROJECT / "kernel" / "KERNEL_SHA256").read_text().split()[0]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--players", default="attacker,honest")
    parser.add_argument("--ticks", type=int, default=640)
    parser.add_argument("--port", type=int, default=47911)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--population", type=int, default=0, help="for review priority; default: player count")
    parser.add_argument("--coverage", type=float, default=1.0, help="live moderation coverage 0..1")
    parser.add_argument("--demo-clients", action="store_true")
    args = parser.parse_args()

    players = sorted(p for p in args.players.split(",") if p)
    args.out.mkdir(parents=True, exist_ok=True)
    tokens = {p: secrets.token_hex(32) for p in players}
    token_file = args.out / "tokens.json"
    token_file.write_text(json.dumps(tokens))
    os.chmod(token_file, 0o600)

    subprocess.run([args.godot, "--headless", "--path", str(PROJECT), "--import"],
                   capture_output=True, text=True, timeout=300)
    base = [args.godot, "--headless", "--path", str(PROJECT), "--script"]
    server = subprocess.Popen(base + ["res://net/server.gd", "--", "--port", str(args.port),
                                      "--ticks", str(args.ticks), "--tokens", str(token_file),
                                      "--out", str(args.out)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(json.dumps({"server": "starting", "players": players, "tokens_file": str(token_file)}))

    clients = []
    if args.demo_clients:
        cert = args.out / "server_cert.crt"
        deadline = time.time() + 30
        while not cert.exists() and time.time() < deadline:
            time.sleep(0.1)
        time.sleep(0.2)
        seconds = str(args.ticks / 64 + 2)
        for player in players:
            role = "attacker" if player == "attacker" else "honest"
            clients.append(subprocess.Popen(
                base + ["res://net/client.gd", "--", "--port", str(args.port), "--player", player,
                        "--role", role, "--token", tokens[player], "--cert", str(cert), "--seconds", seconds],
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True))
    for proc in clients:
        proc.communicate(timeout=120)
    server.communicate(timeout=args.ticks / 64 + 120)

    result = json.loads((args.out / "result.json").read_text())
    if not result.get("ok"):
        print(json.dumps({"server": "failed", "result": result}))
        return 1
    if result["kernel_sha256"] != PUBLISHED_KERNEL:
        print(json.dumps({"server": "refused", "reason": "kernel does not match the published hash"}))
        return 2

    from datetime import datetime, timezone
    detection = subprocess.run(
        [sys.executable, "-m", "detection.run", "--match", str(args.out),
         "--population", str(args.population or len(players)),
         "--hour", str(datetime.now(timezone.utc).hour), "--coverage", str(args.coverage)],
        cwd=ROOT, capture_output=True, text=True, timeout=300)
    if detection.returncode != 0:
        print(detection.stderr)
        return 3
    (args.out / "detection.json").write_text(detection.stdout)
    report = json.loads(detection.stdout)
    print(json.dumps({
        "server": "done", "digest": result["digest"], "kernel_sha256": result["kernel_sha256"],
        "flags": {p: len(v["flags"]) for p, v in report["players"].items()},
        "priority": {p: v["priority"] for p, v in report["players"].items()},
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
