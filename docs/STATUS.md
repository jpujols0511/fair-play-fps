# Status

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
