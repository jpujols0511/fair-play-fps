# 0001 — Engine and netcode foundation

Status: **Accepted**, October 15, 2026. Joan's goal of that date directs
Godot and building the fairness kernel on an existing netcode addon; the
spike chose Netfox on evidence. See Results and Integration stages.
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

## Results, October 15, 2026

Full detail in `godot/README.md`. Godot 4.4.1-stable, Linux, headless,
loopback only.

- Steps 1 to 3 done. The GDScript kernel matches the Python oracle digest
  byte for byte. A real UDP server and two client processes ran a 64-tick
  match, and the server's demo log replays to the same digest. Forged
  positions and spoofed identities never reached the kernel.
- Step 4 done at metadata level only. Netfox is MIT, active and GDScript on
  stock Godot: the leading candidate. monke-net needs a custom Godot fork,
  is C#, and has no licence file: not suitable now. The Asset Library
  framework could not be reached from the cloud container.
- Open: invariant 2 (encryption and authentication), a jitter buffer so
  honest late inputs are not discarded, and a time-boxed Netfox integration.

Recommendation: accept Godot 4.4.x with Netfox as the first netcode
candidate, keeping the fairness kernel in our own code.

## Integration stages

1. **Done, October 15.** Netfox vendored (`docs/THIRD_PARTY.md`). Its
   `NetworkTime` loop at 64 Hz drives the kernel and reproduces the Python
   oracle digest (`godot/tests/netfox_tick.gd`). Transport is DTLS with
   per-player access tokens.
2. **Next.** Move the match onto `ENetMultiplayerPeer` with DTLS so
   Netfox's clock synchronization runs across processes; server stays the
   only place outcomes are decided.
3. **Then.** Client prediction and reconciliation with Netfox rollback for
   the local player only. The jitter buffer part is proposed separately in
   decision 0002 (branch `claude/jitter-buffer-v01`).

Accepting this record does not change the licence, which stays open.
