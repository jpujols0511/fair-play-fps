# 0002 — Missing input and the server jitter buffer

Status: **Implemented on `main`; product acceptance pending**, October 15,
2026. The original work arrived on `claude/jitter-buffer-v01` and was merged
with the 64 and 128 tick profiles rather than replacing either history.

## Context

Decision 0001 left one finding open: honest late inputs were discarded as
`stale_input` (7 in 64 ticks on loopback). A bounded sweep on October 15
traced it to the kernel, not the network.

When a player's input had not arrived by its tick, the kernel applied a
default command with sequence `last_sequence + 1` and yaw 0. That had three
effects:

1. **The real input was then discarded.** Its sequence number was already
   used, so it was stale on arrival.
2. **The loss never healed.** Each gap used one sequence the client would
   still send, so the stream fell one tick further behind for good. With an
   input held two ticks every eight, 107 of 128 honest inputs became stale and
   only 1 of 11 legal shots was accepted. A server buffer alone could not fix
   it: buffers of 0 to 3 ticks all cascaded.
3. **The player's view snapped to yaw 0 and back.** Detection reads yaw from
   kernel state, so every gap looked like two snaps. Calibrating on clean play
   with 10% late packets raised the snap-rate threshold from 0.02 to 0.504
   and snap-then-fire from 2 to 6. The snap detector was close to blind.

It also made `last_sequence` in snapshots claim the server had applied an
input it never received, which would break client reconciliation in
integration stage 3.

## Proposal

1. **A missing input is a neutral tick.** No movement, no fire, same facing,
   and no sequence number consumed. The late input still counts when it
   arrives. Python oracle and GDScript kernel change together; parity holds
   and the published kernel hash is updated.
2. **The server holds a per-player jitter buffer.** Intents are released one
   per tick in sequence order after an initial fill of `--jitter-ticks`
   (default 3, 47 ms). A gap waits while the buffer is shallow and is skipped
   once it is deeper than the target. A buffer more than `2 × target + 4`
   behind drops its oldest intents so latency stays bounded. Release never
   depends on send rate, so sending faster buys nothing.
3. **Network evidence stays diagnosis only.** `stale_input` and
   `reordered_input` remain in `NEVER_SUSPICION`. The server reports underruns,
   late, trimmed, duplicate and overflow counts per player.

## Invariants touched

- 1 (server authoritative): unchanged. The kernel still decides every
  outcome, one command per player per tick.
- 5 (detection offline): the demo log records exactly what the kernel
  received, and replays to the server digest.
- 6 (false positives are sacred): the reason for this change. Network jitter
  no longer discards honest inputs or fakes snaps.

## Results, October 15, 2026 (loopback, Godot 4.4.1, Linux)

Honest client, 128 ticks, the intent for every eighth tick sent two ticks late
and after two newer ones (`--jitter hold2`), two runs per depth:

| Buffer (ticks) | Stale honest inputs | Underruns | Shots accepted |
| --- | --- | --- | --- |
| 0 | 16 | 17 | 11 of 11 |
| 1 | 16 | 16 | 11 of 11 |
| 2 | 0 | 1 | 11 of 11 |
| 3 | 0 | 0 | 11 of 11 |
| 4 | 0 | 0 | 11 of 11 |

Without the injected fault, every depth had zero stale inputs. Every run's
demo replayed to the server digest.

## Not decided here

- Client-side time dilation to refill the buffer, and clock sync: Netfox
  stage 2.
- Prediction and reconciliation: stage 3.
- Whether the buffer adapts its target per player. Today it is fixed per
  match and recorded in `result.json`.
