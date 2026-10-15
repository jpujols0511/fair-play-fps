#!/usr/bin/env python3
"""Launch an authoritative server and two rendered graybox clients.

Interactive loopback demo:

    python3 scripts/run_graybox_clients.py --godot /path/to/godot \
        --out matches/graybox-demo

Add ``--headless-proof`` for a bounded automated run. Use ``--bind 0.0.0.0``
on the server machine and ``--host <server-lan-ip>`` for remote clients once
certificate and token files have been distributed securely. Cross-machine
LAN behavior is enabled but is not claimed verified by this launcher.
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
PLAYERS = ("alpha", "bravo")


def _wait_for(path: Path, process: subprocess.Popen[str], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists() and time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"server stopped before creating {path.name}")
        time.sleep(0.05)
    if not path.exists():
        raise RuntimeError(f"timed out waiting for {path.name}")


def _stop(processes: list[subprocess.Popen[str]]) -> None:
    for process in processes:
        if process.poll() is None:
            process.terminate()
    for process in processes:
        if process.poll() is None:
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--tick-rate", type=int, choices=(64, 128), default=64)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--port", type=int, default=47921)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--jitter-ticks", type=int, default=3)
    parser.add_argument("--headless-proof", action="store_true")
    args = parser.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    tokens = {player: secrets.token_hex(32) for player in PLAYERS}
    token_path = args.out / "tokens.json"
    token_path.write_text(json.dumps(tokens), encoding="utf-8")
    os.chmod(token_path, 0o600)

    imported = subprocess.run(
        [args.godot, "--headless", "--path", str(PROJECT), "--import"],
        capture_output=True,
        text=True,
        timeout=300,
    )
    if imported.returncode:
        print(imported.stdout + imported.stderr, file=sys.stderr)
        return imported.returncode

    ticks = max(1, int(round(args.seconds * args.tick_rate)))
    server_log_path = args.out / "server.log"
    server_log = server_log_path.open("w", encoding="utf-8")
    server_cmd = [
        args.godot, "--headless", "--path", str(PROJECT),
        "--script", "res://net/server.gd", "--",
        "--port", str(args.port), "--bind", args.bind,
        "--ticks", str(ticks), "--tick-rate", str(args.tick_rate),
        "--tokens", str(token_path), "--out", str(args.out),
        "--jitter-ticks", str(args.jitter_ticks),
    ]
    server = subprocess.Popen(server_cmd, stdout=server_log, stderr=subprocess.STDOUT, text=True)
    processes = [server]
    client_logs = []
    try:
        cert_path = args.out / "server_cert.crt"
        _wait_for(cert_path, server, 30)
        time.sleep(0.15)
        for index, player in enumerate(PLAYERS):
            report_path = args.out / f"{player}.json"
            log = (args.out / f"{player}.log").open("w", encoding="utf-8")
            client_logs.append(log)
            client_cmd = [args.godot]
            if args.headless_proof:
                client_cmd.append("--headless")
            else:
                client_cmd.extend(["--position", f"{30 + index * 660},80"])
            client_cmd.extend([
                "--path", str(PROJECT), "--",
                "--host", args.host, "--port", str(args.port),
                "--player", player, "--token", tokens[player],
                "--cert", str(cert_path), "--tick-rate", str(args.tick_rate),
                "--report", str(report_path),
            ])
            if args.headless_proof:
                client_cmd.extend([
                    "--test-pattern", "forward" if index == 0 else "strafe",
                    "--exit-after-snapshots", "24",
                ])
            client = subprocess.Popen(client_cmd, stdout=log, stderr=subprocess.STDOUT, text=True)
            processes.append(client)

        server_timeout = args.seconds + 45
        server_code = server.wait(timeout=server_timeout)
        if not args.headless_proof:
            for client in processes[1:]:
                if client.poll() is None:
                    client.terminate()
            result = json.loads((args.out / "result.json").read_text(encoding="utf-8"))
            print(json.dumps({
                "ok": server_code == 0 and result.get("ok") is True,
                "engine": result.get("engine"),
                "topology": "two rendered clients -> one authoritative DTLS server",
                "network": "loopback" if args.host in ("127.0.0.1", "localhost") else "LAN",
                "tick_rate": args.tick_rate,
                "ticks": result.get("ticks"),
            }, indent=2))
            return 0 if server_code == 0 and result.get("ok") is True else 1
        client_codes = []
        for client in processes[1:]:
            try:
                client_codes.append(client.wait(timeout=10))
            except subprocess.TimeoutExpired:
                client.terminate()
                client_codes.append(client.wait(timeout=3))
        if server_code != 0 or any(code != 0 for code in client_codes):
            raise RuntimeError(f"process failure: server={server_code}, clients={client_codes}")

        result = json.loads((args.out / "result.json").read_text(encoding="utf-8"))
        clients = {}
        for player in PLAYERS:
            report = json.loads((args.out / f"{player}.json").read_text(encoding="utf-8"))
            confirmed = report["last_confirmed"]
            rendered = report["render_position"]
            world_scale = report["world_scale"]
            if (round(rendered["x"] * world_scale) != confirmed["x"]
                    or round(rendered["z"] * world_scale) != confirmed["y"]):
                raise RuntimeError(f"{player} rendered a position not present in its last server snapshot")
            clients[player] = report
        proof = {
            "ok": result.get("ok") is True,
            "engine": result.get("engine"),
            "topology": "two clients -> one authoritative DTLS server",
            "network": "loopback" if args.host in ("127.0.0.1", "localhost") else "LAN",
            "tick_rate": args.tick_rate,
            "ticks": result.get("ticks"),
            "jitter_ticks": result.get("jitter_ticks"),
            "authority": "intent-only clients; rendered positions equal server snapshots",
            "clients": clients,
            "server_digest": result.get("digest"),
        }
        (args.out / "graybox_proof.json").write_text(json.dumps(proof, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(proof, indent=2))
        return 0 if proof["ok"] else 1
    except (RuntimeError, subprocess.TimeoutExpired, OSError, KeyError, json.JSONDecodeError) as error:
        print(f"graybox launcher failed: {error}", file=sys.stderr)
        return 1
    finally:
        _stop(processes)
        server_log.close()
        for log in client_logs:
            log.close()


if __name__ == "__main__":
    raise SystemExit(main())
