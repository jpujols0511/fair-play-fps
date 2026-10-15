"""Godot spike checks (decision 0001). Skipped unless FAIRPLAY_GODOT names a
Godot 4 binary, so the default test run stays dependency-free.

    FAIRPLAY_GODOT=/path/to/Godot_v4.4.1-stable_linux.x86_64 \
        python3 -m unittest tests.test_godot_spike -v
"""
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "prototype"))

from fairplay_sim import (  # noqa: E402
    AuthoritativeServer,
    InputCommand,
    controlled_attacker_commands,
    honest_commands,
    run_commands,
)

GODOT = os.environ.get("FAIRPLAY_GODOT", "")
PROJECT = ROOT / "godot"


def setUpModule():
    """Godot must scan the project once so netfox's class names resolve."""
    if GODOT and Path(GODOT).is_file():
        subprocess.run([GODOT, "--headless", "--path", str(PROJECT), "--import"],
                       capture_output=True, text=True, timeout=300)


def _godot(script, *user_args, timeout=60):
    return subprocess.run(
        [GODOT, "--headless", "--path", str(PROJECT), "--script", script, "--", *user_args],
        capture_output=True, text=True, timeout=timeout,
    )


def _mixed(n):
    for t in range(n):
        yield {
            "honest": InputCommand(t, -700 if t % 3 else 0, 300, -45000 * t, t % 9 == 0),
            "attacker": InputCommand(t if t % 10 else t - 2, -6000, 2500, -400000, True),
        }


def replay_demo(player_ids, demo, tick_rate=64):
    """Feed a server demo log (every submit, in order, per tick) to the oracle."""
    server = AuthoritativeServer(player_ids, tick_rate=tick_rate)
    for submits in demo:
        for player_id, command in submits:
            server.submit(player_id, InputCommand(**command))
        server.step()
    return server.result()


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class GodotKernelParity(unittest.TestCase):
    def test_digests_match_python_oracle(self):
        proc = _godot("res://tests/kernel_parity.gd")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = {r["scenario"]: r for r in (json.loads(line) for line in proc.stdout.splitlines()
                                           if line.startswith("{"))}
        expected = {}
        for tick_rate in (64, 128):
            expected[f"honest_{tick_rate}"] = run_commands(
                ["honest"], honest_commands(tick_rate, tick_rate=tick_rate),
                tick_rate=tick_rate).digest
            expected[f"attacker_{tick_rate}"] = run_commands(
                ["attacker"], controlled_attacker_commands(tick_rate),
                tick_rate=tick_rate).digest
            expected[f"mixed_{tick_rate}"] = run_commands(
                ["attacker", "honest"], _mixed(tick_rate),
                tick_rate=tick_rate).digest
        for scenario, digest in expected.items():
            self.assertEqual(rows[scenario]["digest"], digest, scenario)


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class NetfoxDrivesKernel(unittest.TestCase):
    def test_netfox_tick_loop_reproduces_oracle(self):
        proc = _godot("res://tests/netfox_tick.gd")
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertNotIn("SCRIPT ERROR", proc.stdout + proc.stderr)
        report = next(json.loads(l) for l in proc.stdout.splitlines() if l.startswith("{"))
        self.assertEqual(report["driver"], "netfox NetworkTime")
        self.assertEqual(report["tickrate"], 64)
        self.assertEqual(report["digest"], run_commands(["honest"], honest_commands(32)).digest)


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class GodotLoopbackMatch(unittest.TestCase):
    """One server and two client processes over UDP on 127.0.0.1."""

    @classmethod
    def setUpClass(cls):
        import secrets
        cls.out = Path(tempfile.mkdtemp(prefix="fairplay-loopback-"))
        port = str(47900 + os.getpid() % 90)
        cls.tokens = {"honest": secrets.token_hex(32), "attacker": secrets.token_hex(32)}
        token_file = cls.out / "tokens.json"
        token_file.write_text(json.dumps(cls.tokens))
        token_file.chmod(0o600)
        base = [GODOT, "--headless", "--path", str(PROJECT), "--script"]
        server = subprocess.Popen(base + ["res://net/server.gd", "--", "--port", port, "--ticks", "64",
                                          "--tokens", str(token_file), "--out", str(cls.out)],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        cert = cls.out / "server_cert.crt"
        deadline = time.time() + 30
        while not cert.exists() and time.time() < deadline:
            time.sleep(0.1)
        time.sleep(0.2)
        clients = [subprocess.Popen(base + ["res://net/client.gd", "--", "--port", port, "--player", role,
                                            "--role", role, "--token", cls.tokens[role], "--cert", str(cert),
                                            "--seconds", "3"],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                   for role in ("honest", "attacker")]
        cls.client_out = {}
        for role, proc in zip(("honest", "attacker"), clients):
            text, _ = proc.communicate(timeout=90)
            cls.client_out[role] = next(json.loads(l) for l in text.splitlines() if l.startswith('{"client"'))
        server.communicate(timeout=90)
        cls.result = json.loads((cls.out / "result.json").read_text())
        cls.demo = json.loads((cls.out / "demo.json").read_text())

    def test_server_completed_over_dtls(self):
        self.assertTrue(self.result["ok"], self.result)
        self.assertEqual(self.result["ticks"], 64)
        self.assertEqual(self.result["tick_rate"], 64)
        self.assertEqual(self.result["transport"], "DTLS")
        self.assertEqual(self.result["jitter_ticks"], 3)
        published = (PROJECT / "kernel" / "KERNEL_SHA256").read_text().split()[0]
        self.assertEqual(self.result["kernel_sha256"], published)

    def test_demo_replays_to_same_digest(self):
        replay = replay_demo(
            ["attacker", "honest"], self.demo, self.result["tick_rate"])
        self.assertEqual(replay.digest, self.result["digest"])

    def test_attacker_intent_is_bounded_by_server(self):
        counts = self.result["evidence_counts"]["attacker"]
        self.assertGreater(counts.get("input_clamped", 0), 0)
        self.assertGreater(counts.get("fire_cadence_rejected", 0), 0)
        self.assertLessEqual(counts.get("shot_accepted", 0), 64 // 8 + 1)

    def test_forged_position_and_identity_never_applied(self):
        stats = self.result["stats"]
        self.assertGreater(stats["malformed"], 0, "forged position packets")
        self.assertGreater(stats["auth_failed"], 0, "HELLO as honest with a wrong token")
        self.assertGreater(stats["identity_mismatch"], 0, "intent claiming honest inside attacker session")
        self.assertGreater(stats["handshake_failed"], 0, "plaintext packets outside DTLS")
        applied = {pid for submits in self.demo for pid, cmd in submits if cmd["sequence"] >= 1000}
        self.assertEqual(applied, set(), "spoofed intents reached the kernel")

    def test_honest_is_never_clamped_or_cadence_rejected(self):
        counts = self.result["evidence_counts"]["honest"]
        self.assertNotIn("input_clamped", counts)
        self.assertNotIn("fire_cadence_rejected", counts)
        self.assertNotIn("stale_input", counts, "jitter buffer: honest inputs are never discarded")

    def test_clients_render_only_server_truth(self):
        # A client may miss the final snapshot (UDP), so compare what it shows
        # with the oracle's state at the tick that snapshot names.
        for role in ("honest", "attacker"):
            confirmed = self.client_out[role]["last_confirmed"]
            self.assertGreaterEqual(confirmed["tick"], 48, role)
            truth = replay_demo(
                ["attacker", "honest"], self.demo[:confirmed["tick"]],
                self.result["tick_rate"]).players[role]
            self.assertEqual(
                (confirmed["x"], confirmed["y"], confirmed["ammunition"], confirmed["last_sequence"]),
                (truth.x, truth.y, truth.ammunition, truth.last_sequence), role)


def _honest_match(jitter_ticks, jitter, port, ticks=128):
    """One honest client over DTLS with a repeatable network fault."""
    import secrets
    out = Path(tempfile.mkdtemp(prefix="fairplay-jitter-"))
    token = secrets.token_hex(32)
    token_file = out / "tokens.json"
    token_file.write_text(json.dumps({"honest": token}))
    token_file.chmod(0o600)
    base = [GODOT, "--headless", "--path", str(PROJECT), "--script"]
    server = subprocess.Popen(base + ["res://net/server.gd", "--", "--port", port, "--ticks", str(ticks),
                                      "--tokens", str(token_file), "--out", str(out),
                                      "--jitter-ticks", str(jitter_ticks)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    cert = out / "server_cert.crt"
    deadline = time.time() + 30
    while not cert.exists() and time.time() < deadline:
        time.sleep(0.1)
    time.sleep(0.2)
    client = subprocess.Popen(base + ["res://net/client.gd", "--", "--port", port, "--player", "honest",
                                      "--role", "honest", "--token", token, "--cert", str(cert),
                                      "--seconds", str(ticks / 64 + 2), "--jitter", jitter],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    client.communicate(timeout=90)
    server.communicate(timeout=90)
    return json.loads((out / "result.json").read_text()), json.loads((out / "demo.json").read_text())


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class JitterBuffer(unittest.TestCase):
    """Decision 0002: an honest intent two ticks late and out of order, every
    eight ticks. Without a buffer it is discarded; with three ticks it is not."""

    def test_unbuffered_fault_discards_honest_input(self):
        result, demo = _honest_match(0, "hold2", str(48100 + os.getpid() % 90))
        self.assertTrue(result["ok"], result)
        self.assertGreater(result["evidence_counts"]["honest"].get("stale_input", 0), 0)
        self.assertEqual(replay_demo(["honest"], demo).digest, result["digest"])

    def test_three_tick_buffer_keeps_every_honest_input(self):
        result, demo = _honest_match(3, "hold2", str(48200 + os.getpid() % 90))
        self.assertTrue(result["ok"], result)
        counts = result["evidence_counts"]["honest"]
        self.assertNotIn("stale_input", counts)
        self.assertNotIn("reordered_input", counts)
        self.assertEqual(result["stats"]["buffer"]["honest"]["late"], 0)
        self.assertEqual(result["stats"]["buffer"]["honest"]["trimmed"], 0)
        self.assertEqual(counts["shot_accepted"], 11)
        self.assertEqual(replay_demo(["honest"], demo).digest, result["digest"])


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class GrayboxClients(unittest.TestCase):
    """The main scene runs twice against one authoritative DTLS server."""

    def test_two_clients_render_server_confirmed_state_at_both_tick_rates(self):
        for index, tick_rate in enumerate((64, 128)):
            with self.subTest(tick_rate=tick_rate):
                out = Path(tempfile.mkdtemp(prefix=f"fairplay-graybox-{tick_rate}-"))
                port = str(48300 + (os.getpid() % 40) * 2 + index)
                proc = subprocess.run([
                    sys.executable, str(ROOT / "scripts" / "run_graybox_clients.py"),
                    "--godot", GODOT, "--out", str(out), "--seconds", "1",
                    "--port", port, "--tick-rate", str(tick_rate), "--headless-proof",
                ], capture_output=True, text=True, timeout=120)
                self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
                proof = json.loads((out / "graybox_proof.json").read_text())
                result = json.loads((out / "result.json").read_text())
                demo = json.loads((out / "demo.json").read_text())
                self.assertTrue(proof["ok"], proof)
                self.assertEqual(proof["network"], "loopback")
                self.assertEqual(proof["tick_rate"], tick_rate)
                self.assertEqual(set(proof["clients"]), {"alpha", "bravo"})
                self.assertEqual(
                    replay_demo(["alpha", "bravo"], demo, tick_rate).digest,
                    result["digest"],
                )
                for player, report in proof["clients"].items():
                    confirmed = report["last_confirmed"]
                    truth = replay_demo(
                        ["alpha", "bravo"], demo[:confirmed["tick"]], tick_rate
                    ).players[player]
                    self.assertEqual(report["authority"], "server_snapshots_only")
                    self.assertEqual(
                        (confirmed["x"], confirmed["y"], confirmed["last_sequence"]),
                        (truth.x, truth.y, truth.last_sequence),
                    )

@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class CommunityServerRunner(unittest.TestCase):
    """scripts/run_dedicated_server.py: match, kernel check, offline detection."""

    def test_runner_flags_only_the_attacker(self):
        out = Path(tempfile.mkdtemp(prefix="fairplay-community-"))
        port = str(48000 + os.getpid() % 90)
        proc = subprocess.run([sys.executable, str(ROOT / "scripts" / "run_dedicated_server.py"),
                               "--godot", GODOT, "--players", "attacker,honest", "--ticks", "128",
                               "--tick-rate", "128",
                               "--port", port, "--out", str(out), "--demo-clients"],
                              capture_output=True, text=True, timeout=300)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        summary = json.loads(proc.stdout.strip().splitlines()[-1])
        self.assertEqual(summary["server"], "done")
        self.assertEqual(summary["tick_rate"], 128)
        self.assertGreater(summary["flags"]["attacker"], 0)
        self.assertEqual(summary["flags"]["honest"], 0)
        self.assertEqual(oct((out / "tokens.json").stat().st_mode & 0o777), "0o600")
        report = json.loads((out / "detection.json").read_text())
        self.assertIn("clamp_rate", {f["feature"] for f in report["players"]["attacker"]["flags"]})


if __name__ == "__main__":
    unittest.main()
