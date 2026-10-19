# Remote-player interpolation v0.1 (PROPOSED)

*Written by Claude, Phase 3 of the mega handoff. PROPOSED; Joan and Game Builder have not approved it. Not public yet.*
Context: `specs/netcode_design.md` D8 and Section 9, `handouts/CLAUDE_MEGA_HANDOFF.md` Phase 3.

## Summary (plain words)
Other players arrive in snapshots 64 times a second. The client does not draw them at the newest snapshot (that would stutter). It draws them a few ticks in the past (`INTERP_TICKS`, default 4 = 31.25 ms) and slides smoothly between the two snapshots around that moment. If the snapshot it needs has not arrived (it was lost) the player simply freezes in place for a moment; nothing is guessed unless Joan turns extrapolation on. A player who respawns or teleports appears at the new place at once, never sliding across the map. A player the server stopped sending (culled, left, dead and hidden) disappears the same tick.

## Rules (everything here is PROPOSED unless it says netcode D8)
1. **Samples.** Per remote slot, a ring of **16** samples keyed by `server_tick` (ascending). A sample is the decoded snapshot entity: position (x, y, z at 1/8 unit), yaw and pitch (quantized, converted with `InputCmd.dequantize_yaw` and `dequantize_pitch`), stance (0 to 3), alive, duck fraction (`duck_q / 255.0`). Inserting an existing tick replaces it. A sample older than the oldest one in a full ring is ignored.
2. **Render tick.** `render_tick = server_tick_estimate - INTERP_TICKS` (a fractional server tick, C1). `server_tick_estimate(c) = c + offset`; `offset` is measured on each **newest** snapshot as `snapshot.server_tick - arrival_tick`, and moved toward the measured value by at most **0.0625 tick per tick**; the first measurement is taken exactly, and if the estimate is off by more than **8 ticks** it is reset. Exposed as `get_render_tick()` (seam D8).
3. **Interpolation.** At `render_tick`, find the last sample `a` with `a.tick <= render_tick` and the next one `b`:
   - position linear; **yaw** along the **shortest arc**; **pitch** a plain signed `lerpf` (it is clamped to [-PI/2, +PI/2], never wraps); the **duck fraction** is lerped like position (`out_duck`, remote crouch is DRAWN from it: eye `64.0 - 32.0 f`, head box `60.0 - 36.0 f` to `72.0 - 36.0 f`); stance and alive (evidence) come from `a` (the older sample) until `b` is reached.
   - If `render_tick` is at or before the oldest sample: hold the oldest sample.
4. **Teleport and respawn snap.** If `b` is marked **new** (the slot was absent from the previous snapshot) or the distance `a` to `b` is **more than 64.0 units**, do not interpolate: hold `a`, and draw `b` from the first tick `render_tick >= b.tick`.
5. **Starvation** (`render_tick` past the newest sample; exactly equal to the newest tick is not starved). With `EXTRAP_MAX_TICKS = 0.0` (C2, netcode D8 "no extrapolation") **hold** the newest pose and count the starved tick. With C2 greater than 0: extrapolate linearly from the last two samples for at most that many ticks, then hold (not across a respawn or a jump over 64 units).
6. **Blend back.** When samples resume after starvation the drawn pose does not jump: the offset (last drawn minus new pose) fades to zero over **4** ticks (factors 3/4, 2/4, 1/4, 0). If the offset is more than 64.0 units it snaps instead.
7. **Removal.** A REMOVED entity (or a slot that is gone) clears its buffer the same tick; it is no longer drawn.

## Switches (DECISION FOR JOAN, `scripts/net/net_config.gd`)
| ID | Switch | Default (proposal) | Alternatives |
|---|---|---|---|
| C1 | `INTERP_TICKS` | 4.0 (31.25 ms) | 2.0 (15.625 ms), 3.0 (23.4375 ms) |
| C2 | `EXTRAP_MAX_TICKS` | 0.0 (hold) | 2.0, 4.0 (measured, not enabled) |

## Reference and tests
`tools/interp_ref.py` is an independent Python implementation of rules 1, 3 to 7 (seed 7101, 1,000 random streams with loss, reordering, teleports, spawns and removals). `tests/test_interp.gd` checks the GDScript buffer against it (positions and angles within 1e-9, flags exact). Measurements for Joan: `research/interp_delay_measurements.md`.


## Gate (Addendum 3, adopted)
Max position error <= **1.0** on non-jump paths and <= **4.0** on jump / landing paths (BHOP_CHAIN is the jump / landing path in the runner), p99 <= **0.25** on every path kind.
