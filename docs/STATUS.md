# Status

## October 15, 2026: missing input and jitter buffer (decision 0002, Proposed)

Branch `claude/jitter-buffer-v01`, not merged. Changes the kernel contract,
so it waits for Joan. Compiled, run and network-tested on loopback only,
Linux, Godot 4.4.1.

- **Root cause found:** the old `stale_input` finding came from the kernel.
  A missing input used the next sequence number and yaw 0, so the real input
  was discarded and the stream never caught up. With one input in eight held
  two ticks, 107 of 128 honest inputs went stale and 1 of 11 legal shots
  landed.
- **Detection was nearly blind to snaps:** the yaw-0 reset looked like snaps,
  so calibrating on clean, jittery play raised snap rate from 0.02 to 0.504
  and snap-then-fire from 2 to 6. With the fix they are back to 0.02 and 2.
- **Kernel (both implementations):** a missing input is now a neutral tick
  that consumes no sequence number. Parity with the Python oracle holds; the
  published kernel hash is updated to `f2310ee9…4c0d`.
- **Server:** per-player jitter buffer, `--jitter-ticks` (default 3), one
  release per tick in sequence order, bounded backlog, per-player buffer
  counts in `result.json`. The runner passes the flag through.
- **Measured:** with the same fault, a buffer of 3 gives zero stale inputs,
  zero underruns and 11 of 11 shots; 0 and 1 still lose 16. The table is in
  the decision record.
- **Checks:** `check_repo.py` passes; 30 tests pass three runs in a row with
  Godot (11 skip without it). New tests: neutral missing input (Python), the
  fault without and with a buffer (Godot), no honest `stale_input` on the
  loopback match.
- **Not done:** cross-machine or real-network test, client time dilation
  and clock sync (Netfox stage 2), prediction, per-player adaptive targets.
- **Next:** Joan accepts or amends 0002. Then Netfox stage 2.

## October 15, 2026: fairness thesis built end to end on one machine

All levels below are compiled, run and network-tested on loopback only, on
Linux with Godot 4.4.1. Not tested across machines, not rendered, not played.

- **Transport (invariant 2):** DTLS with a per-match server certificate and a
  per-player access token in HELLO. Refused before the kernel: wrong token,
  identity claimed inside another session, plaintext packets, forged
  positions.
- **Netfox (decision 0001, accepted):** vendored; its 64 Hz tick loop drives
  the kernel and reproduces the Python oracle digest.
- **Detection (offline):** features from replayed demos, four explainable
  rules, calibration that refuses to flag known-clean play, `stale_input`
  excluded from suspicion, context-weighted review priority. No false flags
  on 60 held-out clean matches.
- **Community review:** blind cases with no identities, consensus of at least
  three weighted reviewers, seeded ground truth that removes unreliable
  reviewers. Banned database writes need a final decision and a moderator.
- **Community servers:** `scripts/run_dedicated_server.py` runs a match,
  checks the published kernel hash, then runs detection as a separate
  process. End-to-end test flags only the attacker.
- **Checks:** 27 tests pass with Godot present (13 skip without it);
  `check_repo.py` passes and fails if the kernel hash, the session hook or the
  `CLAUDE.md` reference is broken.
- **Open:** licence (Joan), Netfox stage 2 across processes, prediction and
  jitter buffer, token service and certificate distribution, internet
  hosting, learned detectors (shadow mode only), anything playable.

## October 15, 2026: Godot headless spike

- `godot/`: GDScript fairness kernel, strict intent-only protocol, headless
  UDP server and client. Godot 4.4.1-stable, Linux, headless.
- Compiled and run; network-tested on loopback only. Kernel digests match the
  Python oracle; the server demo replays to the same digest; forged positions
  and spoofed identities never reached the kernel. `tests/test_godot_spike.py`
  passed three consecutive runs (skipped when Godot is absent).
- Finding: honest late inputs become `stale_input` (7 in 64 ticks under
  loopback jitter). Must never count toward suspicion; M2 needs a jitter
  buffer.
- Read-on-entry is now enforced: `.claude/settings.json` injects
  `docs/DESIGN.md` at every session start, and `scripts/check_repo.py` fails
  if the hook or the `CLAUDE.md` reference is removed.
- Not done: encryption and authentication (invariant 2), Netfox integration,
  Asset Library framework review, cross-machine LAN test, rendering.
- Next: Joan accepts or amends decision 0001 and chooses the licence.

## October 15, 2026: design thesis recorded

- Added `docs/DESIGN.md`: Joan's fairness thesis and six kernel invariants.
  Required reading on entry through the new `CLAUDE.md`.
- Added `docs/decisions/0001-engine-and-netcode.md`: Godot 4 proposed, three
  netcode candidates and a bounded spike plan. Status Proposed.
- Recorded three open decisions in `DESIGN.md` instead of changing them:
  licence (proprietary today, open source in the thesis), engine, and the
  role of learned detectors.
- Checks: `python3 scripts/check_repo.py` and the 6 prototype unit tests pass.
  Documentation only; no runtime, compiler or network claim.
- Next: Joan accepts or amends 0001 and chooses the licence; then the Godot
  headless spike from 0001.

## Verified

- Private GitHub repository exists under jpujols0511.
- Initial architecture is committed and pushed to main.
- Proprietary ownership notice names Joan Pujols.
- Project is separated from other repositories.

## Authored, not implemented

- Native fair-play engine architecture
- Product context
- Roadmap
- Repository rules
- Threat model in progress
- Competitive-shooter lineage matrix

## Executable reference

- Dependency-free Python fixed-tick authoritative simulation
- Client intent schema with no position, health, damage, ammunition, or score
- Server-owned movement limits, fire cadence, ammunition, and shot evidence
- Honest and controlled-attacker command fixtures
- Deterministic result digest and six focused unit tests

## Unverified

- Language, libraries, compiler, and build system
- Linux server or client compilation
- Native runtime simulation
- LAN multiplayer
- Prediction or reconciliation
- Weapons or maps
- Replay or validators
- Performance, security, privacy, or accessibility

## Current blocker

No runtime stack has been selected. Do not claim a playable game.

## Next step

Complete the threat model and bounded M1 technical proposal before writing the
native simulation kernel. Use the Python reference to settle contracts, not as a
claim of a production engine.
