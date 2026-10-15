# Fair Play FPS — orientation for Claude Code

`AGENTS.md` is the working agreement and wins on any conflict with this file.
This file is the map. Keep it short and current.

## Read on entry, every session and sub-agent

1. `AGENTS.md`: ownership, boundaries, verification rules.
2. `docs/DESIGN.md`: the fairness thesis and the six kernel invariants.
   Required. Every change is checked against those invariants.
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
| Checks | `scripts/check_repo.py`, `python3 -m unittest discover -s tests` | Both run with only Python 3. |

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

M0, Foundation. Remaining: Joan's decisions on licence and engine
(`docs/decisions/0001-engine-and-netcode.md`), then the engine spike
described there. No playable build exists.
