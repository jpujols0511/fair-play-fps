# Fair Play FPS — orientation for Claude Code

`AGENTS.md` is the working agreement and wins on any conflict with this file.
This file is the map. Keep it short and current.

## Read on entry, every session and sub-agent

1. `AGENTS.md`: ownership, boundaries, verification rules.
2. `docs/DESIGN.md`: the fairness thesis and the six kernel invariants.
   Required. Every change is checked against those invariants. A session
   start hook injects it automatically; when you start a sub-agent, tell it
   to read `docs/DESIGN.md` first.
3. `docs/PROJECT_CONTEXT.md`, then `docs/STATUS.md`, then the active
   milestone in `docs/ROADMAP.md`.
4. The relevant record in `docs/decisions/` before changing foundations.

## Map

| Area | Where | Notes |
| --- | --- | --- |
| Thesis and invariants | `docs/DESIGN.md` | Includes the open decisions table (licence, engine, learned detectors). |
| Architecture | `docs/FAIR_PLAY_ENGINE_ARCHITECTURE.md` | Authoritative simulation, validators, evidence ledger, adaptive pipeline, enforcement ladder. |
| Threats | `docs/THREAT_MODEL.md` | Protected outcomes, trust boundaries, threat classes, response ladder. |
| Design lineage | `docs/LINEAGE_MATRIX.md` | What to keep, reject, modernize and test from earlier shooter eras. Ideas only; no third-party code or assets. |
| Decisions | `docs/decisions/NNNN-*.md` | One record per foundational choice, with status Proposed, Accepted or Superseded. |
| Executable reference | `prototype/fairplay_sim.py`, `tests/` | Dependency-free Python fixed-tick authoritative simulation. Settles contracts; it is not the game. |
| Godot spike | `godot/` | Headless GDScript kernel, intent-only protocol, servers and clients on raw DTLS and on ENet with DTLS plus Netfox clock sync. See `godot/README.md`. |
| Detection | `detection/` | Offline, on recorded demos only. Features, explainable flags, calibration that refuses to flag clean play, context-weighted review priority, banned database. |
| Community review | `review/` | Blind cases, weighted consensus, seeded ground truth. Decisions are recommendations until a moderator signs off. |
| Community servers | `scripts/run_dedicated_server.py`, `docs/COMMUNITY_SERVERS.md` | One match plus offline detection. Kernel hash is published in `godot/kernel/KERNEL_SHA256`. |
| Third party | `docs/THIRD_PARTY.md` | Netfox and Godot provenance. Record anything new here first. |
| Session hook | `.claude/settings.json` | Injects `docs/DESIGN.md` at every session start. Do not remove. |
| Checks | `scripts/check_repo.py`, `python3 -m unittest discover -s tests` | Both run with only Python 3. Set `FAIRPLAY_GODOT` to a Godot 4.4.1 binary to run the Godot tests too (they run `--import` first). |

## Conventions

- Report status by level, never upward: authored, statically checked,
  compiled, run, network-tested, playtested, accepted by Joan.
- One small verified increment at a time. Update `docs/STATUS.md` with what
  was checked, what was not, blockers and the next step.
- Any change to networking, authority, transport, detection or review names
  the kernel invariants it touches in its commit message.
- Client messages carry intent only: never position, health, damage,
  ammunition, score or match result.
- Work on `claude/<topic>-vNN` branches. No pull requests or merges to
  `main` unless Joan asks.
- Original content only. No Valve or Counter-Strike code, maps, assets, names
  or sounds. Published techniques (lag compensation, snapshot interpolation)
  are fine; their source code is not.
- Keep this project separate from VEYR, Data Haunt, Pocket Boo and Veridian.

## Current milestone

M0 is complete apart from the licence decision; M1 groundwork is in place.
Built and tested on one Linux machine (loopback): DTLS transport with
per-player tokens, Netfox-driven kernel ticks, offline detection, community
review, and a community server runner. Proposed on `claude/jitter-buffer-v01`
(decision 0002, waits for Joan): missing input is a neutral tick, plus a server
jitter buffer. Built on top of it: `claude/netfox-enet-v01` (stage 2, ENet with DTLS and
Netfox clock sync across processes), then `claude/prediction-v01` (stage 3,
client prediction and reconciliation), then `claude/hits-lag-comp-v01`
(decision 0003, hits and bounded lag compensation, Proposed). Next: send
other players' positions to clients, with interpolation. No playable build
exists; nothing has been tested across machines or by players.
