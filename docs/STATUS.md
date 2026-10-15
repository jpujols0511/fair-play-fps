# Status

## October 15, 2026: authoritative Godot graybox client

- **Authored:** original procedural room, first-person camera, lighting,
  crosshair and server-confirmation HUD in the Godot 4.4.1 main scene.
- **Authority:** clients serialize only movement, yaw and fire intent through
  the existing strict protocol. The camera rig's position is assigned only
  from authenticated DTLS snapshots; there is no local movement prediction.
- **Two-client proof:** two main-scene processes authenticated to one headless
  server over Linux loopback at 64 and 128 Hz. Each moved independently, each
  scene position equaled its last server snapshot, and both demos replayed to
  the server digest.
- **Procedure:** `scripts/run_graybox_clients.py --headless-proof`, one second
  per profile, default three-tick jitter buffer, no injected loss or latency.
- **Not yet verified:** pixels and controls by a human, cross-machine LAN,
  collision, jumping, crouching, weapons, remote-player rendering, prediction
  and reconciliation.

## October 15, 2026: missing input and jitter buffer (decision 0002)

Integrated with the 64 and 128 tick profiles on `main`; product acceptance is
pending. Compiled, run and network-tested on loopback only, Linux, Godot
4.4.1.

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
  published kernel hash is updated to `b4aabbf9…6ef1`.
- **Server:** per-player jitter buffer, `--jitter-ticks` (default 3), one
  release per tick in sequence order, bounded backlog, per-player buffer
  counts in `result.json`. The runner passes the flag through.
- **Measured:** with the same fault, a buffer of 3 gives zero stale inputs,
  zero underruns and 11 of 11 shots; 0 and 1 still lose 16. The table is in
  the decision record.
- **Checks:** the integrated 33-test suite passes with Godot. New tests:
  neutral missing input (Python), the
  fault without and with a buffer (Godot), no honest `stale_input` on the
  loopback match.
- **Not done:** cross-machine or real-network test, client time dilation
  and clock sync (Netfox stage 2), prediction, per-player adaptive targets.
- **Next:** render the authoritative graybox client, then Netfox stage 2.

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

## Authored, not yet playable

- Fair-play engine architecture
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
- Deterministic result digest and eight focused unit tests
- Explicit 64 and 128 tick profiles with elapsed-time-normalized honest fixtures
- One-command dependency-free local verification and Devin Local handoff
- Python and Godot kernel parity at 64 and 128 Hz for honest, attacker, and
  mixed one-second fixtures
- Godot 4.4.1 headless authoritative kernel with Netfox-driven 64 Hz timing
- DTLS loopback server and thin clients at both 64 and 128 Hz
- Deterministic demo replay, asynchronous detection, and blind community review
- Thirty-three passing Python, Godot, loopback, detection, and review tests on
  Linux x86_64 with the official Godot 4.4.1 stable headless build
- Render-capable first-person graybox and two-client launcher; scene instances
  verified against server-confirmed snapshots at 64 and 128 Hz

## Open-source transition

- Public and open-source direction is recorded.
- Current tracked tree and Git history contain no known credentials, binaries,
  third-party game content, or large blobs.
- AGPL-3.0-only code, CC BY-SA 4.0 original assets and documentation, and a
  reserved project trademark are the selected direction; applying the terms
  and changing visibility are deferred by Joan.

## Unverified

- Cross-machine LAN multiplayer
- Prediction or reconciliation
- Weapons or maps
- Visual presentation and controls by a human playtester
- Remote-player rendering, collision, jump, crouch, health and respawn
- Performance under load, security audit, privacy audit, or accessibility

## Current blockers

- The graybox lacks the remaining M1 gameplay rules and has not been played.
- The current proprietary notice cannot represent an open-source public release.
- The selected license boundary must be applied before visibility changes.

## Next step

Verify the two-client scene visually and across two LAN machines, then add the
remaining server-owned M1 movement and combat rules.
