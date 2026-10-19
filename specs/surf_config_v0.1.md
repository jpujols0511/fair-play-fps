# Surf config v0.1

*Joan's dictation, October 17 2026, recorded by Game Builder. Public as of Oct 19 2026 (CD-r9).*
*Status: **Joan's doc** (Sections 1–8 are his words, kept faithful). Review notes at the end are Game Builder's, verified against code on Claude's branches; they are **proposals** until Joan decides.*

---

## 1. The question

Should Fair Play FPS offer surf maps with `sv_airaccelerate` raised from **10** to **100** as a server config toggle, or keep air accelerate locked at **10** across all modes?

## 2. What surf is

An angled ramp where air-strafe gain plus gravity creates a ride you can sustain indefinitely. At air accelerate **10**, most ramps are unrideable — you fall off. At **100**, the same strafe that gives **202 units per second** on a flat map becomes enough to stick to a **forty-five-degree** slope. The surf scene discovered this in **2004** when Charlie Joyce slid off a roof on `ka_killbox` and built `surf_the-gap`.

## 3. The mechanic dependency

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §surf

Your movement spec already has everything surf needs: the **thirty-unit** air wish-speed cap, air accelerate **10** default, and edge friction doubling near ledges. Surf doesn't require new code — it requires a **cvar change** and a **map**. That's the cheapest possible feature.

## 4. The anti-cheat angle

Raising air accelerate doesn't create a cheat vector because the server still simulates every input. A surf run is just a long chain of legitimate air-strafe commands. The anti-cheat sees normal inputs at normal rate. No new detection surface.

## 5. The competitive angle

Surf is a separate skill from dueling. It rewards the same air-strafe mastery but in a different context — **sustained** rather than **burst**. For a hardcore audience, that's a feature, not a distraction. But it splits the player base: duelists won't touch surf maps, surfers won't touch duel servers.

## 6. The recommendation

Ship it as an **opt-in server config**, not a default. Default stays **10**. Surf-enabled servers are a separate listing with their own browser tag. That keeps the core game pure while giving the movement scene somewhere to go.

## 7. Implementation

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §surf

One cvar, `sv_airaccelerate`, range **10** to **100**, default **10**. Server config file sets it per mode. **No code changes to `movement.gd`** — the function already reads the cvar. Map format: any Godot mesh with a collider works; the slope angle is the design variable.

## 8. Open question for you

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §surf

Do you want surf as a **permanent mode** or a **limited-time event** to test demand before committing server slots?

---

## Review notes (Game Builder, verified against code)

Checked on `origin/claude/elegant-keller-rspv71`, `origin/claude/elegant-keller-rspv71-prediction-loop`, and `origin/claude/pl` (prediction-loop and `pl` share the same collision/`AIR_ACCEL` shape). Specs on main: `specs/goldsrc_movement.md`, `specs/prediction_loop_scope.md`.

### (a) Does `movement.gd` read airaccelerate as a setting or as a hardcoded constant?

**Hardcoded constant.** It does **not** read a cvar.

From `movement_proto/movement.gd` on `claude/elegant-keller-rspv71-prediction-loop`:

```
120|const AIR_ACCEL := 10.0
...
243|				gain = air_accel_gain(cur, MAX_SPEED, AIR_ACCEL, dt)
```

`air_accel` / `air_accel_gain` take `accel` as a **function argument**, but `step()` always passes the compile-time `AIR_ACCEL` const (`10.0`). There is no `sv_airaccelerate` variable, config table, or server-mode switch. Same pattern on the movement-parity branch (`claude/elegant-keller-rspv71`): `AIR_ACCEL := 10.0` as a const.

**Correction to Section 7:** making the toggle real needs at least a float field (or argument) on the shared step — e.g. pass `air_accel` into `step(...)` from server config — not "the function already reads the cvar."

### (b) "No code changes" / "any mesh with a collider works" — FALSE against current code

**What's locked today (prediction loop Decision 2):** v1 collision is **one box plus one step, no slope**. Custom box tests in `movement.gd`; **no** Godot `CharacterBody3D` / physics bodies. Quote from `movement.gd` Phase 4 header:

```
113|## ---- Phase 4: collision v1 (one box + one step, no slope) and the shared step ----
115|## fixed tick length. Custom box tests, no Godot physics bodies.
```

World boxes are axis-aligned tops only (`[min_x, min_z, max_x, max_z, top]`). Move is axis-separated X then Z with optional step-up; land snaps to `support_height`. There is **no**:

- plane / triangle / slope collider
- `ClipVelocity` (project velocity onto the plane normal and keep the along-plane part)
- GoldSrc-style ground vs too-steep test (`normal.z < 0.7` ≈ steeper than ~45° is not walkable ground; surfing rides the "air" side of that)
- Python reference cases for ramp rides
- parity tests for slope stick / fall-off

`prediction_loop_scope.md` explicitly lists slopes and edge friction as **out of scope** for v1. Meshes in the scene are visual only; collision is the custom box list.

**What's missing for surf (precise):**

1. **Slope/plane collision** in `movement.gd` (or a shared collision module) that returns a hit plane normal, not just an AABB top.
2. **`ClipVelocity`** (GoldSrc/Quake-style) against that normal each move step, including overbounce behavior if we match 1.6.
3. **Ground classification** from the normal (walkable floor vs surfable/too-steep "air" plane). Without this, a 45° ramp is either ignored or treated as a flat step top.
4. **Python sim** extensions in `specs/goldsrc_movement_sim.py` for ramp + clip (today: "Horizontal plane + simple vertical, flat floor, no walls"; slopes/edgefriction "aren't modelled" — `goldsrc_movement.md` line 63).
5. **Parity / reference cases** for: stick at aa=100 on 45°, fall-off at aa=10, and a known GoldSrc overbounce edge case if we claim 1.6 match.
6. **Config plumbing:** `sv_airaccelerate` float on the server mode → into `step` (see (a)). Range 10–100, default 10.

Until those land, Section 3's "doesn't require new code" and Section 7's "no code changes to movement.gd" / "any Godot mesh with a collider works" are **incorrect**. Opt-in cvar + map listing is still the right product shape; the movement/collision work is not free.

### (c) Edge friction

- **Spec:** `specs/goldsrc_movement.md` table lists `edgefriction` **2** (ReHLDS `sv_user.cpp`, "extra friction near ledges"). Prose: "Near a ledge, friction doubles." Caveat line 63: edgefriction **isn't modelled** in the sim.
- **Code:** **not implemented** in `movement.gd` on any Claude branch checked. Friction uses only `FRICTION := 4.0` and `STOP_SPEED := 100.0`. No ledge probe, no ×2 near edges.
- Surf rides air / plane contact more than ledge friction, so this is a smaller gap than (b), but Section 3's claim that the movement spec "already has" edge friction doubling is only true as **documented intent**, not as shipped code or sim.

### (d) Does aa=100 stick on a 45° ramp?

**Unverified** (no ClipVelocity sim in-repo). A small continuous/tick sketch only:

- Down-slope gravity component at 45°: `800 × sin(45°) ≈ 565.7 u/s²`.
- Classic air bite: `min(aa × maxspeed × dt, 30 − current_along)`. At 128 tick, `maxspeed=250`: **aa=10 → max bite 19.531 u/s/tick**; **aa=100 → max bite 30.0 u/s/tick** (hits the air cap). Raising aa also fills the 30-gap from higher `current_along` (less-perfect strafe still gets a bite).
- That explains why aa=100 feels much stickier in GoldSrc surf culture, but it does **not** prove a 45° ramp ride without plane clip + a reference run. Mark Section 2's "sticks to a forty-five-degree slope" as **design intent / community knowledge, not yet parity-proven here**.

### (e) 2004 history (Charlie Joyce / `ka_killbox` / `surf_the-gap`)

**Not verified from in-repo sources.** A single quick web search (Eurogamer feature; Wikipedia "Counter-Strike surfing") attributes summer **2004**, Charlie "Mariowned" Joyce, `ka_killbox` roof slide → `surf_the-gap`, and later popularization with aa raised toward 100. Treat as **community history, not a locked engineering fact**. No further research done.

### (f) Anti-cheat

**Agree with Section 4's core point:** raising aa does not by itself open a new input forgery surface; the server still owns the sim. Addendum for Fair Play:

- Proposed **AIM_KIN** (evidence type 6, reserved; see `crosshair_spec_v0.1.md` review note (c) and reconciliation item 11) thresholds for flick / snap-back / view-angle velocity are tuned around duel sprays and peeks.
- Surf is **near-constant mouse + strafe** for long stretches. The same AIM_KIN cutoffs would **false-positive** hard on legitimate surf input.
- **Proposal:** keep one detection pipeline, but make AIM_KIN (and any related flick gates) **per-mode / per-`sv_airaccelerate` profile** — duel defaults at aa=10; a looser or disabled AIM_KIN profile when the server mode is tagged surf (aa≫10). Still log inputs; don't auto-flag from duel thresholds on a surf server. DECISION FOR JOAN when AIM_KIN is approved.

### Cross-links

- Hard mode design v0.1 open question 1 (`specs/hard_mode_design_v0.1.md` §10) is the same surf/aa question; this doc is Joan's fuller treatment.
- Reconciliation: item **24**.

---

## Decision (Oct 17 2026)

- **Queued:** Joan: "Yes, always all the time queue it". Work is Phase 11 of the build plan (airaccelerate setting 10.0–100.0 default 10.0, plane/slope collision with ClipVelocity, `normal.z < 0.7` = not ground (PROPOSED), edge friction 2, Python reference first, parity tests, 45° test ramp measurement, per-mode AIM_KIN note for Devin).
- **§8 answer (Game Builder recommendation, Joan said queue it):** surf launches as a **limited-time event first** to test demand before committing permanent server slots. Default `sv_airaccelerate` stays `10.0` everywhere else.
- §§3/7 "no code changes" remains superseded by the review notes above until Phase 11 lands.
