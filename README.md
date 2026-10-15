# Fair Play FPS

Private pre-production research and engineering project owned by Joan Pujols.

Fair Play FPS is a temporary internal name for an original competitive
first-person shooter. The project studies the readable movement, map language,
weapon feedback, teamwork, and round structure that made classic tactical
shooters durable, while designing authoritative simulation and fair-play
enforcement as native engine systems.

## Boundaries

- Original code, art, maps, names, characters, audio, and game identity
- No Valve, Counter-Strike, or other third-party source code or assets
- Open-source direction with explicit code, asset, and trademark boundaries
- Separate from VEYR, Data Haunt, Pocket Boo, and Veridian
- Server-authoritative competitive simulation
- Evidence-based enforcement with privacy, review, and appeals
- Controlled adaptive learning, never unreviewed self-modifying production code

## Current phase

Architecture and threat-model definition. No playable build exists yet.

Start with [the design thesis](docs/DESIGN.md), then [the engine architecture](docs/FAIR_PLAY_ENGINE_ARCHITECTURE.md).
The [lineage matrix](docs/LINEAGE_MATRIX.md) records what to keep, reject,
modernize, and test across the major competitive-shooter eras.

The first executable work is a dependency-free
[headless authoritative arena reference](prototype/README.md). It is a simulation
and evidence laboratory, not a playable game or production engine.

Run every current check locally with:

    python3 scripts/local_verify.py

The [Devin Local handoff](docs/DEVIN_LOCAL_HANDOFF.md) provides a bounded first
session that works only in this repository and does not install dependencies.

The repository is still private under its existing proprietary notice while the
[open-source license boundary](docs/OPEN_SOURCE_READINESS.md) is selected and
audited. Public visibility will follow the license commit, not precede it.

## Ownership

Copyright (c) 2026 Joan Pujols. All rights reserved.

See [LICENSE.txt](LICENSE.txt).
