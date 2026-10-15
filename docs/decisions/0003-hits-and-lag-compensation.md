# 0003 — Hit validation and bounded lag compensation

Status: **Proposed**, October 15, 2026. Adds rules to the kernel and
prototype values Joan has not chosen, so it waits for her. Implemented on
branch `claude/hits-lag-comp-v01`, on top of 0002 and integration stages 2
and 3. Not on `main`.

## Context

Invariant 3 says hits are judged by the server with lag compensation, never
by the client. Before this record the kernel accepted shots but never
resolved them, so there was nothing to compensate.

## Proposal

1. **The server traces every accepted shot.** A straight ray from the
   shooter's position along its yaw. The closest living player whose centre
   is within `HIT_RADIUS` of the ray and within `MAX_RANGE` takes `DAMAGE`.
   At 0 health a player is eliminated: they cannot be hit or fire again.
   There is no map or cover yet, so nothing blocks a ray.
2. **Intents name what the client saw.** Each intent carries `view_tick`,
   the server tick of the last snapshot the client was showing (-1 for
   now). It is never a position or a claim of a hit (invariant 1).
3. **Bounded rewind.** The server keeps every player's start-of-tick
   position for the last `MAX_REWIND_TICKS` ticks and judges the shot
   against the positions at `view_tick`. A view older than the limit is
   clamped and recorded as `rewind_limited` (network evidence, never
   suspicion). A view from the future is not used and is recorded as
   `view_tick_invalid`.
4. **Integer rays.** Direction comes from a fixed 91-entry integer sine
   table with linear interpolation, written into both the Python oracle and
   the GDScript kernel, so both decide every hit identically. Maximum error
   is about 2 mm at 50 m.

## Prototype values (Joan to choose)

| Constant | Value | Meaning |
| --- | --- | --- |
| `HIT_RADIUS` | 400 | Player radius in millimetres |
| `MAX_RANGE` | 50,000 | 50 metres |
| `DAMAGE` | 25 | Four hits eliminate |
| `MAX_REWIND_TICKS` | 13 | About 200 ms at 64 Hz |

Movement units were already millimetres in effect: `MAX_SPEED` 48 per tick
is about 3 m/s.

## Invariants touched

- 1: the client sends only intent and the tick it saw; the server decides
  every hit.
- 3: lag compensation is server-side and bounded; a forged old view buys at
  most 13 ticks.
- 5: hits are deterministic from the demo log, so replays reproduce them.
- 6: `rewind_limited` is caused by distance from the server and never
  counts toward suspicion.

## Results, October 15, 2026

- Oracle tests: straight-ahead hit, side miss, closest target wins, a
  rewound shot hits what the shooter saw and the same shot without rewind
  misses, a 38-tick claim rewinds only 13 and misses, a future view is not
  used, elimination stops hits and fire.
- Parity: a three-player combat stream with hits, an elimination, rewinds
  past the limit, views from the future and every yaw quadrant produces the
  same digest in GDScript and Python.
- Network (loopback, ENet with DTLS): the attacker fixture claims every shot
  was aimed at tick 0; its rewinds are recorded as limited and every hit in
  the match rewinds 13 ticks or fewer.

## Not decided here

- Maps, cover and line of sight; hit zones; weapons beyond the one rifle.
- Respawn and match rules (game modes live on the community surface).
- Detection features from hits (accuracy, aim before visibility).
- Sending other players' positions to clients so they can aim (interest
  management and interpolation).
