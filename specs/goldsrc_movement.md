# GoldSrc / CS 1.6 movement — behaviour spec (PRIVATE)

Written Oct 16 2026 in our own words from *reading* public sources (no code copied):
ValveSoftware/halflife `pm_shared/pm_shared.c`, s1lentq/ReGameDLL_CS `regamedll/pm_shared/pm_shared.cpp` + `pm_shared.h` + `dlls/game.cpp`,
rehlds/ReHLDS `engine/sv_user.cpp`, `sv_main.cpp`, `sv_phys.cpp`, and source-sdk-2013 `game/shared/gamemovement.cpp/.h`.
Units: 1 unit ≈ 1 inch. Speeds in units/second (u/s). Sim: `goldsrc_movement_sim.py`, output: `sim_results.txt`.

## Server settings (cvar) defaults — checked against the sources
| Setting | Default | Where confirmed | Matches what we assumed? |
|---|---|---|---|
| sv_airaccelerate | 10 | ReHLDS sv_main.cpp | ✅ yes |
| sv_friction | 4 | ReHLDS sv_phys.cpp | ✅ yes |
| sv_gravity | 800 | ReHLDS sv_phys.cpp | ✅ yes |
| sv_accelerate | 10 | ReHLDS sv_user.cpp | engine default is 10. (Many CS 1.6 servers run 5 by config — our choice.) |
| sv_stopspeed | 100 | ReHLDS sv_phys.cpp | — |
| sv_maxspeed | 320 | ReHLDS sv_user.cpp | server ceiling; your weapon sets real speed (knife 250) |
| edgefriction | 2 | ReHLDS sv_user.cpp | extra friction near ledges |
| sv_enablebunnyhopping / sv_autobunnyhopping | 0 / 0 | ReGameDLL game.cpp | ReGameDLL extras, not in stock 1.6 |
| sv_unlag / sv_maxunlag | 1 / 0.5 s | ReHLDS sv_user.cpp | lag compensation on, rewinds up to half a second |

## How it behaves, in plain words
**Ground speed-up (acceleration).** Each tick, the game asks "how much faster could you go in the direction you're pressing before you hit your top speed?" It then adds a slice of speed: accelerate × top speed × tick length, but never more than that remaining gap. At top speed pressing forward, you add nothing.

**Ground friction.** While on the ground, each tick you lose speed equal to friction × tick length × your speed — but if you're slower than 100 u/s it pretends you're at 100, so you stop crisply instead of sliding forever. Near a ledge, friction doubles. Friction is skipped on the tick you jump.

**The 30 u/s air cap (why air-strafing works).** In the air the same "add speed" rule runs, but the "how fast do you want to go" number is capped at 30 for the gap check — while the size of the slice still uses your full top speed. So the game only checks "are you already going 30 u/s *in the direction you're pressing*?" If you turn your mouse smoothly and hold the matching strafe key, the pressed direction is almost sideways to your motion, so you're always "under 30" that way and keep getting speed added at an angle. Adding sideways pushes over and over makes your total speed grow. There is no top-speed limit in the air. Source does the same thing (air cap 30, from `GetAirSpeedCap`).

**Jump and gravity.** A jump sets upward speed to about 268 u/s (enough for a 45-unit jump at gravity 800). Gravity is applied in two halves, one before moving and one after, so the jump arc comes out the same at any tick rate. You can only jump from the ground and only on a fresh press (holding jump does nothing — ReGameDLL's autobhop setting can change that).

**CS jump stamina.** Each jump starts a ~1.3 second "tired" timer. While it runs: your next jump is weaker (up to ~25% lower up-speed right after a jump) and your ground speed is scaled down by the same factor. It wears off linearly. This is why chained hops get lower and landing hurts.

**Bhop cap (anti mega-bunny).** At the moment you jump, if your speed is over 1.2 × your weapon's top speed (300 with a knife), your speed is cut to 80% of that limit (240 with a knife). This is a punishment, not a ceiling: going too fast and jumping drops you *below* the limit.

**Order inside one tick (CS 1.6)**
1. Count down timers (stamina, duck).
2. Handle crouching.
3. If jump pressed: on ground + fresh press → run the bhop cap check, set jump speed (weakened by stamina), restart stamina, leave the ground.
4. If still on ground → apply friction.
5. First half of gravity.
6. Move: ground rules (with stamina slow-down and step-up) or air rules (30 cap) — then slide along walls.
7. Second half of gravity, check if you landed, fall damage.

**Source (CS:S / CS:GO era) differences, briefly:** same accelerate/friction/30-cap model; jump uses `sqrt(2·800·57)`≈302 in HL2 but CS:S keeps CS-style numbers; bhop limiting is done differently (HL2 caps forward jump boost; CS:S used a cap similar to 1.6; CS:GO added velocity-based stamina instead of the 1.6 timer).

## Sim results (ideal player, knife 250 u/s, flat ground)

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §missed-hop, §movement (stamina)
| | 64 tick | 100 tick | 128 tick |
|---|---|---|---|
| Raw air push per tick | 39.1 (over the 30 cap) | 25.0 | 19.5 |
| Ideal strafe gain at 250 u/s | 1.79 u/s per tick (115 u/s/sec) | 1.74 (174/sec) | 1.58 (202/sec) |
| Ideal strafe gain at 400 u/s | 1.12 per tick (72/sec) | 1.09 (109/sec) | 0.99 (126/sec) |
| Ticks in air per jump | 43 | 68 | 86 |
| Top chained-bhop speed (end of each hop) | ~303 | ~329 | ~341 |
| Landing at 300 u/s, no keys: after 100 ms | ~204 | ~199 | ~205 |
| Full stop from 300 u/s | ~530 ms | ~520 ms | ~523 ms |

Takeaways:
- **Tick rate matters for strafing:** per *second*, 128 tick gives ~75% more air-strafe gain than 64 tick. Same mouse movement = more speed on 128. This is real 1.6 behaviour, and a design decision for us (locked tick rate per server).
- **Bhop is self-limiting:** with stock settings you hover around 300–340 u/s, because every jump over 300 drops you to 240. Speed above ~300 must be built inside one hop.
- **Landing slowdown** is about the same at every tick rate (≈⅓ of speed gone in 100 ms). Missing a hop by one tick costs ~5–7% speed.
- **Jump stamina:** a perfectly chained second jump has ~235 u/s up-speed vs 268 for a fresh jump (~12% lower).

## Caveats / still to verify
- The sim uses an idealised "perfect strafe" and flat ground; real players lose some gain. Walls, slopes, ducking, and edgefriction aren't modelled.
- 1.6 servers usually ran at ~100 fps physics (client-rate), not true 64/128 tick — the 100 column is the closest to how 1.6 actually felt.
- Next step: port this *spec* (not any code) to the Python reference sim in the repo's style and to GDScript, then check KERNEL_SHA256 parity.


---

## Crouch (PROPOSED, Oct 17 2026)

*Appended by Claude for Phase 1 of the mega handoff. Nothing above was changed. K1 and K2 are locked by the approved hitbox spec v0.2 (half-height crouch). K3 to K10 are PROPOSED and come from reading GoldSrc behaviour, not from this spec, so Joan can veto them. Each switch lives in `movement.gd` and defaults to the proposal.*

| # | Rule | Number | Status |
|---|---|---|---|
| K1 | Standing body height / eye | **72.0 / 64.0** | locked (hitbox A3) |
| K2 | Crouched body height / eye / head top | **36.0 / 32.0 / 36.0** (`0.5 x 72.0`, `0.5 x 64.0`) | **locked** (hitbox v0.2 APPROVED note) |
| K3 | Ground duck: hold duck, and after `DUCK_TIME_S` the hull switches to 36.0. During the transition the hull stays 72.0 and the eye moves **linearly** from 64.0 to 32.0 | `DUCK_TIME_S = 0.4` (C6) | PROPOSED (GoldSrc timing; the linear eye curve is our simplification) |
| K4 | The transition completes on the first tick where `float(duck_ticks) / tick_rate >= DUCK_TIME_S - 1e-9`. `duck_ticks` is an **integer tick counter**, never an accumulated float | **52** ticks at 128, **40** at 100, **26** at 64 | derived |
| K5 | Releasing duck mid-transition cancels it: eye back to 64.0 on that tick, counter reset | | PROPOSED |
| K6 | Duck pressed **in the air** is instant (no transition): hull 36.0, eye 32.0. With `AIR_DUCK_LIFTS_FEET` the feet move **up 18.0** (`(72.0 - 36.0) / 2.0`, the crouch-jump) | C8 | PROPOSED |
| K7 | Unduck (duck released while fully ducked) is instant **only if the standing hull fits**. In the air with C8 the feet go **down 18.0** if that space is free; feet that would end below the support height land on it instead. If there is no room the player stays ducked and retries every tick | | PROPOSED |
| K8 | Fully ducked: wish speed x `DUCK_SPEED_FACTOR` (ground top speed **and** the air slice size; the air gap cap stays 30.0). Ground, stamina 0: 250.0 x 0.333 = **83.25 u/s**. The stamina factor and the duck factor multiply. Not applied during the transition | `DUCK_SPEED_FACTOR = 0.333` (C7) | PROPOSED |
| K9 | Order inside a tick: timers (stamina, duck counter), crouch handling (K3 to K7), jump, friction, gravity half, accelerate + move, gravity half, land | | spec order above |
| K10 | Collision uses the **current hull height**: a box blocks if its vertical span `[bottom, top]` overlaps `[feet, feet + height]`. Boxes may carry an optional 6th value `bottom` (default 0.0, so every existing world behaves exactly as before). Step-up needs headroom. A box only supports the player (floor under the feet) if its top is at or below the feet | | PROPOSED, backward compatible |
| K11 | Pure helpers: `eye_height(state)`, `stance_for_hitbox(state)` (0 stand, 1 crouch, 2 air, 3 crouch-air; the transition counts as stand), `move_state_for_hud(state)` (0 stand, 1 crouch, 2 air, 3 run; checked air, then run when horizontal speed is **strictly greater** than 140.0, then crouched, then stand) | | seams D6 |

Two spec questions for Game Builder and Joan:
1. **Crouched eye.** GoldSrc's crouched eye is about 30 above the feet. Ours is **32.0** because the approved hitbox note locks `0.5 x 64.0`.
2. **Duck speed, duck timing and the air-duck lift** (K3, K6, K7, K8) are from reading GoldSrc behaviour. They are switches (`DUCK_TIME_S`, `DUCK_SPEED_FACTOR`, `AIR_DUCK_LIFTS_FEET`) so they can be changed without touching the rest.

Reference: `goldsrc_movement_sim.py --emit-crouch-cases` writes `movement_proto/tests/reference_cases_crouch.json`; `movement_proto/tests/test_parity_crouch.gd` checks it at 64, 100 and 128 tick (tolerance 0.01).
