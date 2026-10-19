# CS 1.6 Recoil & Spread — Behavior Spec (private)

Written in plain language from reading public sources (s1lentq/ReGameDLL_CS `regamedll/dlls/wpn_shared/wpn_{ak47,m4a1,awp,deagle}.cpp`, `weapons.cpp`, `weapons.h`, `pm_shared.cpp`; ValveSoftware/source-sdk-2013 `src/game/shared/gamemovement.cpp`). No code copied. Sim: `goldsrc_recoil_spread_sim.py` (written from scratch), output: `sim_recoil_results.txt`.

## 1. Two separate things: spread and kick
- **Spread** = random cone around where you aim. A number like 0.03 means a bullet can land up to ~0.03 units sideways per 1 unit forward (~1.7°). The random offset is the sum of two random numbers per axis, so hits cluster toward the center (triangle-shaped, not flat). *(The two-random-numbers shape is from memory of the HL bullet code — verify in ReGameDLL `FireBullets3` before relying on it.)*
- **Kick (punch angle)** = your view gets shoved up/sideways after each shot, and **bullets go where your view + kick point**. This is the "spray pattern." It slowly returns to center on its own.

## 2. The "accuracy" number (rifles)
Each rifle keeps an inaccuracy value. It starts at 0.2 (fresh/after reload). After every shot it's recomputed as `shots_in_burst³ ÷ divisor + floor`, capped:
| Rifle | Divisor | Floor | Cap |
|---|---|---|---|
| AK47 | 200 | 0.35 | 1.25 |
| M4A1 | 220 | 0.30 | 1.00 |
> SUPERSEDED by CURRENT_DECISIONS.md CD-r9 §recoil: stock 1.6 stepped accuracy (integer division). AK: 0.35 after shots 1–5, cap 1.25 from shot 6; M4A1: 0.30 after shots 1–6, cap 1.00 from shot 7. Shot-counter recovery defaults also changed (release cap 15 on, delay from release). The sentence below describes the old smooth curve and is kept as history.

### CD-r9 active behavior
After each rifle shot, calculate `floor(n * n * n / divisor) + floor_value`, capped at the weapon cap; all gameplay math stays float-based. This gives AK accuracy 0.35 after shots 1–5 and 1.25 from shot 6, and M4A1 accuracy 0.30 after shots 1–6 and 1.00 from shot 7. Spread uses the accuracy stored before the shot: AK shots 2–6 and M4A1 shots 2–7 use their floor values. Shot 1 still uses the fresh value 0.2.

Shot-counter recovery uses the stock defaults: cap to 15 on trigger release, start the 0.4-second delay at release, drop on the first tick where elapsed time is strictly greater than the due time plus `1e-9`, then drop at most once per tick with the next drop due 0.0225 seconds after the prior drop. Stored accuracy remains unchanged by recovery. The previous smooth accuracy curve remains available only as a reference function; fire-cycle timing is unchanged and remains open under OPEN 18.

Cubic growth = first 3–4 shots stay tight, then it blows up fast (AK hits the cap at shot ~6–7).

**Burst counter recovery:** when you stop firing, after 0.4 s the shot counter drops by 1 every 0.0225 s. So a full 30-shot spray fully resets in ~0.4 + 0.67 s ≈ 1.1 s; a 3-shot tap resets in ~0.47 s. (Stock 1.6 quirk: the stored accuracy only re-computes on the next shot; ReGameDLL has an optional fix that resets it.)

## 3. Spread by movement state
Movement state is checked in this order: **in air → moving faster than 140 u/s → standing/crouched**. Note: walking (shift, ≤130 u/s) counts as *standing* for rifles. Crouch gives no extra rifle spread bonus in 1.6 (only less kick).

| Weapon | Air | Running (>140) | Standing/walking | Crouched |
|---|---|---|---|---|
| AK47 | 0.04 + 0.40×acc | 0.04 + 0.07×acc | 0.0275×acc | same as standing |
| M4A1 (silenced) | 0.035 + 0.40×acc | 0.035 + 0.07×acc | 0.025×acc | same |
| M4A1 (no silencer) | same | same | 0.020×acc | same |
| AWP (scoped) | 0.85 | 0.25 (>140) / 0.10 (>10) | 0.001 | 0.0 (perfect) |
| AWP unscoped | add +0.08 to all | | | |
| Deagle | 1.5×(1−acc) | 0.25×(1−acc) (any movement >0) | 0.13×(1−acc) | 0.115×(1−acc) |

Computed first-shot vs worst spread (rifles, acc 0.2 → cap):
| | Stand first shot | Stand max | Run first | Air first | Air max |
|---|---|---|---|---|---|
| AK47 | 0.0055 | 0.0344 | 0.054 | 0.120 | 0.540 |
| M4A1 (silenced) | 0.0050 | 0.0250 | 0.049 | 0.115 | 0.435 |
Takeaway: a standing AK first shot is ~10× tighter than running and ~22× tighter than jumping. That's the "stop to shoot" skill the game is built on.

**Deagle accuracy** works the other way (higher = better, starts 0.9, floor 0.55). Each shot it loses accuracy by `(0.4 − seconds since last shot) × 0.35`, so spamming faster than 0.4 s apart hurts; waiting ≥0.4 s fully restores it (clamped at 0.9). It's semi-auto (one shot per click). Cycle 0.225 s (0.3 − 0.075). Standing first shot = 0.013.

## 4. Kick (punch) per weapon
Rifles use 7 numbers per movement state: base up, base side, extra up per shot, extra side per shot, max up, max side, and a "1-in-N+1" chance each shot to flip side direction.
| AK47 | up | side | +up/shot | +side/shot | max up | max side | flip |
|---|---|---|---|---|---|---|---|
| moving (any speed) | 1.5 | 0.45 | 0.225 | 0.05 | 6.5 | 2.5 | 1/8 |
| air (only if not moving) | 2.0 | 1.0 | 0.5 | 0.35 | 9.0 | 6.0 | 1/6 |
| crouched | 0.9 | 0.35 | 0.15 | 0.025 | 5.5 | 1.5 | 1/10 |
| standing | 1.0 | 0.375 | 0.175 | 0.0375 | 5.75 | 1.75 | 1/9 |

| M4A1 | up | side | +up | +side | max up | max side | flip |
|---|---|---|---|---|---|---|---|
| moving | 1.0 | 0.45 | 0.28 | 0.045 | 3.75 | 3.0 | 1/8 |
| air | 1.2 | 0.5 | 0.23 | 0.15 | 5.5 | 3.5 | 1/7 |
| crouched | 0.6 | 0.3 | 0.2 | 0.0125 | 3.25 | 2.0 | 1/8 |
| standing | 0.65 | 0.35 | 0.25 | 0.015 | 3.5 | 2.25 | 1/8 |

Quirks: the per-shot extra only applies from shot 2; once kick exceeds the max it stops adding (doesn't clamp back). **1.6 bug:** "moving" is checked before "in air", so a jumping player who has any horizontal speed gets the *moving* kick, not the air kick. Decide whether to keep this.
- AWP and Deagle: a flat 2° up-kick per shot, no sideways.
- Fire rates: AK 0.0955 s (~628 RPM), M4A1 0.0875 s (~686 RPM), AWP 1.45 s, Deagle 0.225 s.

**Recovery:** every movement tick the kick shrinks toward zero by `(10 + half its size)` degrees per second. A 2° kick is gone in ~0.2 s; a 5° kick only drops to ~3.7° between AK shots, which is why sprays climb and then plateau.

## 5. Sim results (standing, 30-round spray, seeded RNG)
| | AK 64t | AK 128t | M4 64t | M4 128t |
|---|---|---|---|---|
| 30 shots duration | 2.781 s | 2.773 s | 2.547 s | 2.539 s |
| Peak upward kick | 4.61° | 4.61° | 2.72° | 2.64° |
| 2° kick full recovery | 0.203 s | 0.195 s | — | — |
Pattern: shots 1–2 land on the crosshair (kick is applied after the shot), climb steeply shots 3–7, then plateau at the cap with side-to-side wander.

**64 vs 128 tick:** recoil barely changes (<3% on peak kick, ~4 ms on recovery). The real difference is **fire timing**: at 64 tick a shot can only leave on a 15.6 ms boundary, so individual AK shot gaps jitter between 93.8 and 109 ms (vs 93.8–101.6 at 128). Average rate is preserved. So unlike movement (where 128 gave ~75% more strafe gain), recoil is nearly tick-independent — fine at 128.

## 6. Source comparison
- **Kick recovery is different:** Source (SDK 2013 `DecayPunchAngle`) uses a springy damped return (damping 9, spring 65) — kick velocity bounces back smoothly, taking ~0.9 s to settle a 2° kick in our approximation vs 1.6's ~0.2 s straight-line drop. 1.6 recoil feels snappier and more "linear."
- **Not verified from source:** CS:S/CS:GO weapon tables aren't in the public SDK 2013 (it ships HL2/HL2MP weapons). CS:GO/CS2 use fixed, learnable spray patterns plus separate per-state inaccuracy; 1.6 has semi-random patterns (random side flips). Treat that as general knowledge, not checked numbers.

## 7. Design choices for the fair-play FPS (to decide)
1. Keep 1.6's random side-flip (skill = control) or fixed CS2-style patterns (skill = memorization)? Fixed patterns are easier for anti-cheat to fingerprint no-recoil scripts against.
2. Fix or keep the moving-before-air kick bug.
3. Server-authoritative: the server computes spread with a shared random seed per shot, so clients can display predicted tracers but never decide hits — matches the netcode doc.
4. Define everything in seconds (already tick-independent), run at 128.

## Caveats
- Spread distribution shape and units (tan of angle) are from memory; confirm in ReGameDLL `player.cpp`/`FireBullets3`.
- Source spring sim is a simplified reconstruction; CS:S numbers not checked.
- Sim ignores the ReGameDLL vs stock difference in how the first shot's kick is counted (identical results in practice).
