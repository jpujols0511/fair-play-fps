# Roadmap

## M0 — Foundation

- Repository boundaries and ownership
- Product context and lineage notes
- Threat model
- Native safety policy
- Validation script
- Decision record for prototype language and libraries (proposed: `decisions/0001-engine-and-netcode.md`)
- Design thesis and kernel invariants (`DESIGN.md`)

Exit: repository checks pass and Joan accepts the bounded prototype contract.

## M1 — Authoritative LAN arena

- Headless fixed-tick server
- Two thin clients
- Walk, strafe, stop, jump, crouch, and collision
- One original hitscan rifle
- Health and respawn
- Input and state recording

Exit: two real clients complete a LAN match with no client-authoritative outcome.

## M2 — Prediction, reconciliation, and network laboratory

- Client prediction
- Server correction
- Snapshot interpolation
- Synthetic latency, jitter, loss, duplication, and reordering
- Bounded lag compensation
- End-to-end latency measurements

Exit: honest clients remain playable in the approved envelope and high latency
does not grant unlimited rewind advantage.

## M3 — Evidence and fair-play validators

- Deterministic replay
- Movement, cadence, ammunition, shot-origin, and visibility validators
- Evidence viewer
- Policy and detector versions
- Controlled attacker bots

Exit: known attacks are reproducible and detected without flagging the clean
network and skill test suites.

## M4 — Original graybox competitive slice

- Two-room arena, corridor, close corner, and objective zone
- Visibility and dark-corner tests
- Original callout landmarks
- Grenade trajectory prototype
- Spectator and reviewer view

Exit: player tests validate readability, callouts, movement, and weapon timing.

## M5 — Adaptive research and shadow evaluation

- Labeled replay dataset
- Candidate statistical detectors
- Offline and adversarial evaluation
- Shadow scoring
- Drift and false-positive reporting

Exit: no model has punishment authority; promotion gates and rollback work.

## Later

Original art, audio, identity, matchmaking, ranks, progression, accessibility,
community servers, Linux client, additional platforms, and public licensing are
separate milestones after the core feel and trust model are proven.
