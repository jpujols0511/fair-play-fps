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
    HIT_RADIUS,
    MAX_RANGE,
    MAX_REWIND_TICKS,
    TRIG_SCALE,
    AuthoritativeServer,
    cos_scaled,
    sin_scaled,
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


def _combat(n):
    for t in range(n):
        a_view = t + 3 if t % 24 == 8 else (t - 40 if t % 16 == 8 else t - 5)
        yield {
            "a": InputCommand(t, 0, 0, 0, t % 8 == 0, a_view),
            "b": InputCommand(t, 1000 if t < 20 else 0, 0 if t < 20 else 1000, 180_000, t % 8 == 4, t - 2),
            "c": InputCommand(t if t % 7 else t - 1, -700, -700, -135_000 + 1500 * t, t % 10 == 0, t - 1),
        }


def _client_report(text):
    """The JSON line a client prints when it finishes."""
    for line in text.splitlines():
        if line.startswith("{"):
            report = json.loads(line)
            if "client" in report:
                return report
    raise AssertionError("client printed no report:\n" + text[-2000:])


def replay_demo(player_ids, demo):
    """Feed a server demo log (every submit, in order, per tick) to the oracle."""
    server = AuthoritativeServer(player_ids)
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
        expected = {
            "honest": run_commands(["honest"], honest_commands(32)).digest,
            "attacker": run_commands(["attacker"], controlled_attacker_commands(32)).digest,
            "mixed": run_commands(["attacker", "honest"], _mixed(48)).digest,
            "combat": run_commands(["a", "b", "c"], _combat(96)).digest,
        }
        for scenario, digest in expected.items():
            self.assertEqual(rows[scenario]["digest"], digest, scenario)

    def test_visibility_matches_python_oracle(self):
        proc = _godot("res://tests/kernel_parity.gd")
        row = next(r for r in (json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{"))
                   if r["scenario"] == "combat")
        server = AuthoritativeServer(["a", "b", "c"])
        expected = {}
        for commands in _combat(96):
            for player_id, command in sorted(commands.items()):
                server.submit(player_id, command)
            server.step()
            for player_id in ("a", "b", "c"):
                expected[f"{player_id}@{server.tick}"] = server.visible_to(player_id)
        self.assertEqual(row["visible"], expected)

    def test_view_range_boundary_matches_python_oracle(self):
        proc = _godot("res://tests/kernel_parity.gd")
        row = next(r for r in (json.loads(line) for line in proc.stdout.splitlines() if line.startswith("{"))
                   if r["scenario"] == "visibility")
        places = {"a": (0, 0), "b": (59_999, 0), "c": (42_427, 42_427), "d": (-60_000, 0), "e": (0, -60_001)}
        server = AuthoritativeServer(places)
        for player_id, (x, y) in places.items():
            server.players[player_id].x, server.players[player_id].y = x, y
        expected = {player_id: server.visible_to(player_id) for player_id in places}
        self.assertEqual(expected["a"], ["b", "d"])
        self.assertEqual(row["visible"], expected)


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
            cls.client_out[role] = _client_report(text)
        server.communicate(timeout=90)
        cls.result = json.loads((cls.out / "result.json").read_text())
        cls.demo = json.loads((cls.out / "demo.json").read_text())

    def test_server_completed_over_dtls(self):
        self.assertTrue(self.result["ok"], self.result)
        self.assertEqual(self.result["ticks"], 64)
        self.assertEqual(self.result["transport"], "DTLS")
        self.assertEqual(self.result["jitter_ticks"], 3)
        published = (PROJECT / "kernel" / "KERNEL_SHA256").read_text().split()[0]
        self.assertEqual(self.result["kernel_sha256"], published)

    def test_demo_replays_to_same_digest(self):
        replay = replay_demo(["attacker", "honest"], self.demo)
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
            truth = replay_demo(["attacker", "honest"], self.demo[:confirmed["tick"]]).players[role]
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
class EnetNetfoxMatch(unittest.TestCase):
    """Decision 0001 stage 2: ENet with DTLS, Netfox clock sync across three
    processes, the same intent-only rules and the same refusals."""

    @classmethod
    def setUpClass(cls):
        import secrets
        cls.out = Path(tempfile.mkdtemp(prefix="fairplay-enet-"))
        port = str(48300 + os.getpid() % 90)
        cls.tokens = {"honest": secrets.token_hex(32), "attacker": secrets.token_hex(32)}
        token_file = cls.out / "tokens.json"
        token_file.write_text(json.dumps(cls.tokens))
        token_file.chmod(0o600)
        base = [GODOT, "--headless", "--path", str(PROJECT), "--script"]
        server = subprocess.Popen(base + ["res://net/enet_server.gd", "--", "--port", port, "--ticks", "128",
                                          "--tokens", str(token_file), "--out", str(cls.out)],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        cert = cls.out / "server_cert.crt"
        deadline = time.time() + 30
        while not cert.exists() and time.time() < deadline:
            time.sleep(0.1)
        time.sleep(0.2)
        jitter = {"honest": "hold2", "attacker": "none"}
        clients = [subprocess.Popen(base + ["res://net/enet_client.gd", "--", "--port", port, "--player", role,
                                            "--role", role, "--token", cls.tokens[role], "--cert", str(cert),
                                            "--seconds", "4", "--jitter", jitter[role]],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                   for role in ("honest", "attacker")]
        cls.client_out = {}
        for role, proc in zip(("honest", "attacker"), clients):
            text, _ = proc.communicate(timeout=90)
            cls.client_out[role] = _client_report(text)
        server.communicate(timeout=90)
        cls.result = json.loads((cls.out / "result.json").read_text())
        cls.demo = json.loads((cls.out / "demo.json").read_text())

    def test_server_completed_over_enet_dtls_with_netfox_clock(self):
        self.assertTrue(self.result["ok"], self.result)
        self.assertEqual(self.result["ticks"], 128)
        self.assertEqual(self.result["transport"], "ENet+DTLS")
        self.assertEqual(self.result["clock"]["driver"], "netfox NetworkTime")
        published = (PROJECT / "kernel" / "KERNEL_SHA256").read_text().split()[0]
        self.assertEqual(self.result["kernel_sha256"], published)

    def test_client_clocks_follow_the_server(self):
        # Clients stamp intents with their synced estimate of the server tick.
        # Unsynced clocks would start at 0 and be start_tick ticks behind.
        self.assertGreater(self.result["clock"]["start_tick"], 16)
        for role in ("honest", "attacker"):
            arrival = self.result["arrival"][role]
            self.assertGreater(arrival["count"], 100, role)
            self.assertLessEqual(abs(arrival["median"]), 3, (role, arrival))
            self.assertGreater(self.client_out[role]["first_tick"], 0, role)

    def test_demo_replays_to_same_digest(self):
        self.assertEqual(replay_demo(["attacker", "honest"], self.demo).digest, self.result["digest"])

    def test_attacker_bounded_and_forgeries_refused(self):
        counts = self.result["evidence_counts"]["attacker"]
        self.assertGreater(counts.get("input_clamped", 0), 0)
        self.assertGreater(counts.get("fire_cadence_rejected", 0), 0)
        self.assertLessEqual(counts.get("shot_accepted", 0), 128 // 8 + 1)
        stats = self.result["stats"]
        self.assertGreater(stats["auth_failed"], 0, "HELLO as honest with a wrong token")
        self.assertGreater(stats["malformed"], 0, "forged position packets")
        self.assertGreater(stats["identity_mismatch"], 0, "intent claiming honest inside attacker session")
        applied = {pid for submits in self.demo for pid, cmd in submits if cmd["sequence"] >= 100000}
        self.assertEqual(applied, set(), "spoofed or plaintext intents reached the kernel")

    def test_forged_old_view_cannot_stretch_lag_compensation(self):
        # The attacker claims every shot was aimed at tick 0. Decision 0003:
        # rewind stops at MAX_REWIND_TICKS and every hit records its rewind.
        self.assertGreater(self.result["evidence_counts"]["attacker"].get("rewind_limited", 0), 0)
        server = AuthoritativeServer(["attacker", "honest"])
        for submits in self.demo:
            for player_id, command in submits:
                server.submit(player_id, InputCommand(**command))
            server.step()
        rewinds = [e.detail["rewind_ticks"] for e in server.evidence if e.category == "hit_confirmed"]
        self.assertTrue(all(r <= MAX_REWIND_TICKS for r in rewinds), rewinds)

    def test_honest_under_injected_jitter_keeps_every_input(self):
        counts = self.result["evidence_counts"]["honest"]
        for category in ("input_clamped", "fire_cadence_rejected", "stale_input", "reordered_input"):
            self.assertNotIn(category, counts)
        self.assertEqual(self.result["buffer"]["honest"]["late"], 0)

    def test_prediction_matches_server_and_corrections_have_causes(self):
        # Stage 3: the client predicts with the server's kernel code. Honest
        # play under absorbed jitter predicts exactly; any correction must be
        # explained by the server applying a neutral tick or dropping input.
        honest = self.client_out["honest"]["prediction"]
        self.assertGreater(honest["confirmed"], 100)
        self.assertEqual(honest["corrections"], 0)
        for role in ("honest", "attacker"):
            buffer = self.result["buffer"][role]
            causes = buffer["underruns"] + buffer["late"] + buffer["trimmed"]
            self.assertLessEqual(self.client_out[role]["prediction"]["corrections"], causes, role)

    def test_clients_render_only_server_truth(self):
        for role in ("honest", "attacker"):
            confirmed = self.client_out[role]["last_confirmed"]
            self.assertGreaterEqual(confirmed["tick"], 100, role)
            truth = replay_demo(["attacker", "honest"], self.demo[:confirmed["tick"]]).players[role]
            self.assertEqual(
                (confirmed["x"], confirmed["y"], confirmed["ammunition"], confirmed["last_sequence"]),
                (truth.x, truth.y, truth.ammunition, truth.last_sequence), role)


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class PredictionCorrects(unittest.TestCase):
    """Without a buffer the server applies neutral ticks the client did not
    predict. The client must correct to the server, never the other way."""

    def test_unbuffered_jitter_is_corrected_to_server_truth(self):
        import secrets
        out = Path(tempfile.mkdtemp(prefix="fairplay-predict-"))
        port = str(48500 + os.getpid() % 90)
        token = secrets.token_hex(32)
        token_file = out / "tokens.json"
        token_file.write_text(json.dumps({"honest": token}))
        token_file.chmod(0o600)
        base = [GODOT, "--headless", "--path", str(PROJECT), "--script"]
        server = subprocess.Popen(base + ["res://net/enet_server.gd", "--", "--port", port, "--ticks", "128",
                                          "--tokens", str(token_file), "--out", str(out), "--jitter-ticks", "0"],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        cert = out / "server_cert.crt"
        deadline = time.time() + 30
        while not cert.exists() and time.time() < deadline:
            time.sleep(0.1)
        time.sleep(0.2)
        client = subprocess.Popen(base + ["res://net/enet_client.gd", "--", "--port", port, "--player", "honest",
                                          "--role", "honest", "--token", token, "--cert", str(cert),
                                          "--seconds", "4", "--jitter", "hold2"],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        text, _ = client.communicate(timeout=90)
        server.communicate(timeout=90)
        report = _client_report(text)
        result = json.loads((out / "result.json").read_text())
        demo = json.loads((out / "demo.json").read_text())
        buffer = result["buffer"]["honest"]
        self.assertGreater(buffer["underruns"], 0)
        self.assertGreater(report["prediction"]["corrections"], 0)
        self.assertLessEqual(report["prediction"]["corrections"],
                             buffer["underruns"] + buffer["late"] + buffer["trimmed"])
        confirmed = report["last_confirmed"]
        truth = replay_demo(["honest"], demo[:confirmed["tick"]]).players["honest"]
        self.assertEqual((confirmed["x"], confirmed["y"], confirmed["last_sequence"]),
                         (truth.x, truth.y, truth.last_sequence))


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class WorldPacketsAndView(unittest.TestCase):
    def test_world_packets_are_strict_and_view_interpolates(self):
        proc = _godot("res://tests/world_view_check.gd")
        self.assertNotIn("SCRIPT ERROR", proc.stdout + proc.stderr)
        r = next(json.loads(l) for l in proc.stdout.splitlines() if l.startswith("{"))
        self.assertEqual(r["empty"], {"tick": 3, "players": {}})
        self.assertEqual(r["two"]["tick"], 12)
        self.assertEqual(r["two"]["players"]["c"], {"x": -5, "y": 7, "yaw_millidegrees": 90000, "health": 75})
        for malformed in ("truncated", "extra", "duplicate", "oversized", "snapshot_is_not_world"):
            self.assertEqual(r[malformed], {}, malformed)
        self.assertEqual(r["view_tick"], 10, "drawn one tick behind the newest frame, at a frame it has")
        self.assertEqual((r["sample_11"]["b"]["x"], r["sample_11"]["b"]["y"]), (100, -50))
        self.assertEqual((r["sample_11_5"]["b"]["x"], r["sample_11_5"]["b"]["y"]), (150, -75))


def _would_hit(origin, yaw, target):
    dx, dy = cos_scaled(yaw), sin_scaled(yaw)
    vx, vy = target[0] - origin[0], target[1] - origin[1]
    along = vx * dx + vy * dy
    return 0 <= along <= MAX_RANGE * TRIG_SCALE and abs(vx * dy - vy * dx) <= HIT_RADIUS * TRIG_SCALE


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class AimAtWhatYouSee(unittest.TestCase):
    """Decision 0003 end to end: a client draws the other player 6 ticks in
    the past from world packets and aims at what it draws. Every accepted
    shot must hit that drawn position, which for a moving target is not
    where it is at the server's current tick. Rewind stays within
    MAX_REWIND_TICKS. (Whether a shot would also hit unrewound depends on
    timing, so it is reported in STATUS, not asserted.)"""

    @classmethod
    def setUpClass(cls):
        import secrets
        out = Path(tempfile.mkdtemp(prefix="fairplay-aim-"))
        port = str(48600 + os.getpid() % 90)
        tokens = {"aimer": secrets.token_hex(32), "strafer": secrets.token_hex(32)}
        token_file = out / "tokens.json"
        token_file.write_text(json.dumps(tokens))
        token_file.chmod(0o600)
        base = [GODOT, "--headless", "--path", str(PROJECT), "--script"]
        server = subprocess.Popen(base + ["res://net/enet_server.gd", "--", "--port", port, "--ticks", "256",
                                          "--tokens", str(token_file), "--out", str(out)],
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        cert = out / "server_cert.crt"
        deadline = time.time() + 30
        while not cert.exists() and time.time() < deadline:
            time.sleep(0.1)
        time.sleep(0.2)
        clients = [subprocess.Popen(base + ["res://net/enet_client.gd", "--", "--port", port, "--player", role,
                                            "--role", role, "--token", tokens[role], "--cert", str(cert),
                                            "--seconds", "6", "--interp-ticks", "6"],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
                   for role in ("aimer", "strafer")]
        cls.client_text = {role: proc.communicate(timeout=120)[0] for role, proc in zip(("aimer", "strafer"), clients)}
        server.communicate(timeout=120)
        cls.result = json.loads((out / "result.json").read_text())
        cls.demo = json.loads((out / "demo.json").read_text())

    def test_every_shot_hits_what_the_shooter_drew(self):
        self.assertTrue(self.result["ok"], self.result)
        for role, text in self.client_text.items():
            self.assertNotIn("SCRIPT ERROR", text, role)
        server = AuthoritativeServer(["aimer", "strafer"])
        seen, shots, at_view, moved = {}, 0, 0, 0
        for tick, submits in enumerate(self.demo):
            seen[tick] = (server.players["strafer"].x, server.players["strafer"].y)
            last, applied = server.players["aimer"].last_sequence, None
            for player_id, command in submits:
                if player_id == "aimer" and command["sequence"] > last:
                    applied = command
                server.submit(player_id, InputCommand(**command))
            before = len(server.evidence)
            server.step()
            for event in server.evidence[before:]:
                if event.player_id == "aimer" and event.category == "shot_accepted":
                    origin, yaw = (event.detail["origin_x"], event.detail["origin_y"]), event.detail["yaw_millidegrees"]
                    self.assertLessEqual(tick - applied["view_tick"], MAX_REWIND_TICKS)
                    shots += 1
                    at_view += _would_hit(origin, yaw, seen[applied["view_tick"]])
                    moved += seen[applied["view_tick"]] != seen[tick]
        self.assertEqual(server.result().digest, self.result["digest"])
        self.assertGreaterEqual(shots, 8)
        self.assertEqual(at_view, shots, "every shot hits where the shooter drew the target")
        self.assertGreater(moved, shots // 2, "the server judged against the drawn, earlier position")
        hits = [e for e in server.evidence if e.category == "hit_confirmed"]
        self.assertGreater(len(hits), 0)
        self.assertTrue(all(0 < h.detail["rewind_ticks"] <= MAX_REWIND_TICKS for h in hits))


@unittest.skipUnless(GODOT and Path(GODOT).is_file(), "set FAIRPLAY_GODOT to a Godot 4 binary")
class CommunityServerRunner(unittest.TestCase):
    """scripts/run_dedicated_server.py: match, kernel check, offline detection."""

    def test_runner_flags_only_the_attacker(self):
        for transport, port in (("enet", 48000), ("dtls", 48400)):
            with self.subTest(transport=transport):
                self._run(transport, str(port + os.getpid() % 90))

    def _run(self, transport, port):
        out = Path(tempfile.mkdtemp(prefix="fairplay-community-"))
        proc = subprocess.run([sys.executable, str(ROOT / "scripts" / "run_dedicated_server.py"),
                               "--godot", GODOT, "--players", "attacker,honest", "--ticks", "128",
                               "--port", port, "--out", str(out), "--transport", transport, "--demo-clients"],
                              capture_output=True, text=True, timeout=300)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        summary = json.loads(proc.stdout.strip().splitlines()[-1])
        self.assertEqual(summary["server"], "done")
        self.assertGreater(summary["flags"]["attacker"], 0)
        self.assertEqual(summary["flags"]["honest"], 0)
        self.assertEqual(oct((out / "tokens.json").stat().st_mode & 0o777), "0o600")
        report = json.loads((out / "detection.json").read_text())
        self.assertIn("clamp_rate", {f["feature"] for f in report["players"]["attacker"]["flags"]})


if __name__ == "__main__":
    unittest.main()
