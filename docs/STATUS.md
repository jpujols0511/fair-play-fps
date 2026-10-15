# Status

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
- Twenty-nine passing Python, Godot, loopback, detection, and review tests on
  Linux x86_64 with the official Godot 4.4.1 stable headless build

## Open-source transition

- Public and open-source direction is recorded.
- Current tracked tree and Git history contain no known credentials, binaries,
  third-party game content, or large blobs.
- Repository remains private and proprietary until Joan selects code,
  documentation, asset, and trademark terms.

## Unverified

- Cross-machine LAN multiplayer
- Prediction or reconciliation
- Weapons or maps
- Rendered client or player input
- Performance under load, security audit, privacy audit, or accessibility

## Current blockers

- The current headless stack is not a playable game.
- The current proprietary notice cannot represent an open-source public release.
- Joan must select the license boundary before visibility changes.

## Next step

Build the bounded M1 graybox client around the authoritative kernel, then prove
two-client LAN behavior before expanding weapons, maps, or content.
