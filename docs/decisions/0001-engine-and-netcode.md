# 0001 — Engine and netcode foundation

Status: **Proposed**, October 15, 2026. Awaiting Joan's acceptance.
Fills the M0 roadmap item "Decision record for prototype language and
libraries".

## Context

`docs/DESIGN.md` names Godot as the engine because its MIT licence matches
the ownership thesis. It also warns that Godot's built-in high-level
multiplayer has no native prediction or rollback, so it is not enough for
competitive netcode on its own.

`docs/PROJECT_CONTEXT.md` says the project owns game rules and authority and
may use battle-tested libraries for platform, graphics, input, audio, network,
compression and cryptography.

## Proposal

1. **Godot 4** for the client and for a headless dedicated server build, on
   Linux first. Pin the exact version after the spike below.
2. **The kernel stays ours.** Tick loop, intent schema, movement limits, fire
   cadence, ammunition, hit validation and evidence follow the contracts
   already proven in `prototype/fairplay_sim.py`. A netcode addon may supply
   transport, prediction, reconciliation and rollback plumbing, but never game
   rules or authority.
3. **Choose one netcode foundation** from the three named in `DESIGN.md`
   after a bounded spike, not by reputation.

## Candidates

| Candidate | What it is | What to confirm in the spike |
| --- | --- | --- |
| Netfox | Godot addon for rollback, prediction and timing | Licence, Godot 4 version supported, server-authoritative mode, maintenance activity |
| monke-net | Godot addon for client prediction and server reconciliation | Licence, scope, maintenance activity, how it handles hit validation |
| Godot 4 Authoritative Server FPS framework (Asset Library) | Complete FPS template using Quake, Overwatch and Valve-era methods | Licence, whether it can be used as a library rather than forked whole, lag-compensation approach |

All three are as named by Joan and not yet verified here.

## Acceptance criteria for the choice

Each criterion maps to a kernel invariant in `docs/DESIGN.md`.

- Client sends inputs only; server decides outcomes (invariant 1).
- Transport can be wrapped in encryption and authentication, or already is
  (invariant 2).
- Prediction and reconciliation for the local player, with bounded server-side
  rewind for hits (invariant 3).
- No kernel components and runs on Linux (invariant 4).
- Server can record inputs and snapshots for asynchronous demo analysis
  (invariant 5).
- Licence compatible with an open-source release.
- Headless server runs in CI without a GPU.

## Spike plan (next bounded batch)

1. Download the pinned Godot 4 Linux headless binary and record its version
   and hash.
2. One minimal project: headless server plus two headless clients on
   loopback, one moving capsule each, inputs only from clients.
3. Port the prototype's intent schema and movement limit into that server and
   show the same rejection the Python tests show.
4. Try each candidate addon against steps 2 and 3 for no more than a fixed
   time box each; record what worked and what did not.
5. Write the result here and change the status to Accepted or Superseded.

## Consequences

- Rendering, input and audio come from Godot. The fairness kernel stays
  small, owned and testable outside the renderer.
- The Python reference remains the contract oracle: the Godot server must
  reproduce its results for the same command stream.
- Accepting this record does not change the licence. That is a separate
  decision for Joan (see the open decisions table in `docs/DESIGN.md`).
