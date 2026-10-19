# Hitbox spec v0.2 (PROPOSED)

*Written by Game Builder, October 17, 2026. Not public yet.*
*Built from `specs/hitbox_spec_v0.1.md`, which stays unchanged. v0.2 replaces v0.1 only after Joan approves.*

**Status: proposed — Joan to approve.** Devin builds hitbox code from this file only after Joan approves the items marked **DECISION FOR JOAN**.

---

## 0. Open assumptions (read first)

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §crouch (A2 15% crouch)

These are working assumptions, not settled facts. Each one is used in the numbers below. If Joan changes one, the numbers that depend on it change too.

| # | Assumption | Why we think so | Depends on it |
|---|---|---|---|
| **A1** | **Box width and depth = 2 × radius.** Box length along the bone = the length column. | v0.1 picks boxes (Section 1) but gives capsule sizes (radius + length). This is the plainest way to turn one into the other. | Every box size in Section 2 |
| **A2** | **Crouch = 15% height scale means 15% shorter** (heights × 0.85), not "scaled down to 15%" (× 0.15). | × 0.15 would make a crouched player about 11 units tall, which can't be meant. | Every crouched number in Section 3 |
| **A3** | **The standing body is 72 units tall, eye at 64.** | Our movement follows GoldSrc behavior, and the GoldSrc standing player is 72 units tall with the eye 64 above the feet. Hitboxes must sit inside the body that movement moves. | All heights |
| **A4** | **Non-head bone lengths are scaled by about 0.57** (rounded to whole units) so the skeleton fits 72 units. The head stays 12 tall. | The v0.1 lengths stacked up (shin 34 + thigh 32 + stomach 16 + chest 20 + head 12) come to **114 units**, which can't fit a 72-unit player. See Section 6. | All lengths in Section 2 |
| **A5** | **Limbs hang straight down in v1** (simple "A-pose" boxes). | We don't have a player model or a weapon-holding pose yet. | Arm placement |

**DECISION FOR JOAN:** approve A1–A5, or tell us what you meant. A4 is the big one: the v0.1 lengths don't fit a 72-unit player.

---

## 1. Philosophy (unchanged from v0.1)

- Boxes, not capsules, for v1. A box-ray test is just comparisons per axis. A capsule adds closest-point math.
- Boxes are a little bigger than the body, so near misses get logged instead of being silently wrong.
- One canonical skeleton file. Server and client load the same constants. If they differ, lag compensation lies.

## 2. Standing skeleton (11 boxes)

Coordinates are in the player's own frame: feet at z = 0, x points forward (where the player faces, yaw only), y points to the player's left. Units are game units (the same as movement). Boxes turn with the player's yaw only. Pitch doesn't tilt them in v1.

| # | Part | Size x × y × z (depth × width × length) | Center (x, y, z) | z range (bottom → top) | Bone anchor |
|---|---|---|---|---|---|
| 0 | Head | 8 × 8 × 12 | (0, 0, 66) | 60 → 72 | head bone, z 66 |
| 1 | Chest | 16 × 16 × 11 | (0, 0, 54.5) | 49 → 60 | sternum top, z 60 |
| 2 | Stomach | 14 × 14 × 9 | (0, 0, 44.5) | 40 → 49 | pelvis, z 40 |
| 3 | Upper arm L | 8 × 8 × 16 | (0, +12, 50) | 42 → 58 | shoulder L, z 58 |
| 4 | Upper arm R | 8 × 8 × 16 | (0, −12, 50) | 42 → 58 | shoulder R, z 58 |
| 5 | Forearm L | 7 × 7 × 15 | (0, +12, 34.5) | 27 → 42 | elbow L, z 42 |
| 6 | Forearm R | 7 × 7 × 15 | (0, −12, 34.5) | 27 → 42 | elbow R, z 42 |
| 7 | Thigh L | 11 × 11 × 19 | (0, +4, 30.5) | 21 → 40 | hip L, z 40 |
| 8 | Thigh R | 11 × 11 × 19 | (0, −4, 30.5) | 21 → 40 | hip R, z 40 |
| 9 | Shin L | 9 × 9 × 19 | (0, +4, 11.5) | 2 → 21 | knee L, z 21 |
| 10 | Shin R | 9 × 9 × 19 | (0, −4, 11.5) | 2 → 21 | knee R, z 21 |

- Widths and depths come from A1: head r 4 → 8, chest r 8 → 16, stomach r 7 → 14, upper arm r 4 → 8, forearm r 3.5 → 7, thigh r 5.5 → 11, shin r 4.5 → 9.
- Lengths come from A4: shin 34 → 19, thigh 32 → 19, stomach 16 → 9, chest 20 → 11, upper arm 28 → 16, forearm 26 → 15. The head stays 12.
- Stack check: 2 (ankle gap) + 19 + 19 + 9 + 11 + 12 = **72**. Eye at **64** is inside the head box (60–72).
- Arms sit beside the chest: the chest's half-width is 8, plus the arm's half-width of 4, gives y = ±12.
- The thighs overlap 3 units at the middle (each is 11 wide, centered at ±4). Overlap is allowed, see Section 5.
- No foot or hand boxes in v1 (v0.1 doesn't list any).
- **Fix to v0.1's wording:** v0.1 says chest = "spine base to sternum" and stomach = "sternum to pelvis". Since the spine base is at the pelvis, those two spans would cover the same stretch. v0.2 stacks them instead: stomach from pelvis up, chest above it, up to the sternum top.

## 3. Crouched pose (uses A2: 15% shorter)

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §crouch

Rule: every box's bottom and top z is multiplied by **0.85** around the feet (z = 0). Widths and depths don't change. **Exception: the head box keeps its size** (`netcode_design.md` Section 5: "Headshot box is fixed size per stance"). Its top goes to 0.85 × 72 = 61.2.

| Part | Crouched z range | Height |
|---|---|---|
| Head | 49.2 → 61.2 | 12 (fixed) |
| Chest | 41.65 → 51.0 | 9.35 |
| Stomach | 34.0 → 41.65 | 7.65 |
| Upper arms | 35.7 → 49.3 | 13.6 |
| Forearms | 22.95 → 35.7 | 12.75 |
| Thighs | 17.85 → 34.0 | 16.15 |
| Shins | 1.7 → 17.85 | 16.15 |

- Crouched eye: 0.85 × 64 = **54.4**, inside the crouched head box (49.2–61.2).
- The head overlaps the chest by 1.8 units (49.2–51.0). Section 5 settles which box a shot hits.

**Check against "the top of the head sits at standing chest height" (v0.1):**
- Standing chest top = 60. Crouched head top with 0.85 = 61.2. **Off by 1.2 units.**
- For an exact match, the scale would be 60 ÷ 72 = **0.8333** (16.7% shorter).

**DECISION FOR JOAN (crouch):**
- (a) Keep 0.85 and treat "head at chest height" as close enough (1.2 units off). **Recommended.** It keeps the number you wrote.
- (b) Use 0.8333 so the head top lands exactly at standing chest height.

**Warning, to settle before crouch is built:** in GoldSrc, a crouched player's collision body is 36 units tall (half of standing). Our movement spec and `movement.gd` don't model crouch yet. If our crouched body is anything like 36 tall, a 15% crouch puts the head box about 25 units above the body that walls and cover block. A player hiding behind waist-high cover would still be shootable over it, and could still see over it. The crouched hitbox, crouched eye height and crouched collision height must agree. **DECISION FOR JOAN:** either crouch really is a light 15% dip (and the crouched collision body is about 61 tall), or crouch should be deeper (closer to 50%), and the 15% number gets revisited.

## 4. Jump pose

- Every box moves up with the player's origin as one rigid body. No scaling, and no leg tuck in v1.
- Crouch-jump uses the crouched table, moved up the same way.
- v0.1 said "head and chest translate up with the pelvis as a rigid offset". In v0.2, all 11 boxes move together, so nothing tears apart in the air. A leg tuck can come later, once there's a model.

## 5. Hit test rules (so server and client agree exactly)

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §hitbox (padding 2.0 at hit test, near-miss 4.0)

1. **Test:** the "slab" ray–box test in the player's yaw frame, in 64-bit floats. The ray runs from the shooter's eye along the final shot direction (after spread), up to the weapon's range or the first world hit, whichever is closer.
2. **Overlapping boxes:** the box the ray enters first (smallest entry distance) wins. If two entry distances are within 1e-6 units of each other, the priority is head > chest > stomach > upper arms > forearms > thighs > shins.
3. **Ray starts inside a box:** counts as a hit on that box at distance 0.
4. **Near miss:** the shortest distance between the shot ray (the same clipped segment) and the box's surface is greater than 0 and **at most 1.0 unit** (1.0 itself counts). It is logged as described in `specs/evidence_logging_spec.md`. More than 1.0 is not logged.
5. Damage multipliers per part are **out of scope** here. They go in the weapons spec.

## 6. Why A4 (the length problem), in plain words

The v0.1 table says the shin is 34 long, the thigh 32, the stomach 16, the chest 20 and the head 12. Stacked on top of each other, that's a 114-unit-tall person. The movement code moves a 72-unit-tall person. Hitboxes taller than the body would stick out of walls and cover. So v0.2 keeps every **width** from v0.1 (via A1) and the **head** exactly as written, and shrinks the other lengths by the same factor (about 0.57) so the body is 72 tall.

**DECISION FOR JOAN:** if the v0.1 lengths were meant for a different scale (for example a taller player, or the numbers came from somewhere else), tell us and we'll redo Section 2.

## 7. Lag compensation numbers (lined up with `netcode_design.md`)

- `netcode_design.md` D9 caps rewind at **200 ms**. v0.1 said 26 frames, and 26 ÷ 128 s = **203.125 ms**, which is over the cap.
- **v0.2: max rewind = 25 ticks = 195.3125 ms at 128 tick.** That's under 200 ms, with whole ticks and no partial-frame clamp.
- History ring buffer: **26 samples per player** (the current tick plus 25 past ticks), so the server can interpolate anywhere in the 25-tick window.
- If the server-chosen rewind would be more than 25 ticks, it's clamped to 25, and the evidence log sets the `REWIND_CLAMPED` flag.
- Effect on players: with the fixed interpolation delay of 2 snapshots at 64/s (31.25 ms), latency is fully compensated up to about **164 ms** (before: about 169 ms). Above that, players lead slightly, which `netcode_design.md` already accepts.
- At 64 and 100 tick the cap stays in milliseconds: floor(0.2 × tick) ticks, which is 12 ticks (187.5 ms) at 64 and 20 ticks (200 ms) at 100.
- Benchmark target for Devin: one shot against 11 enemies × 11 boxes, interpolated within 26 samples of history.

## 8. One canonical constants file

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §hitbox (crouch_scale 0.5, SKELETON_SHA256)

- `shared/skeleton_constants.gd` (GDScript) holds Sections 2–4 and the 25-tick cap. It's generated from, or checked against, `specs/skeleton_constants.json`, which is the source of truth for every language.
- JSON shape (each box):
  ```json
  {"id": 0, "part": "head", "size": [8.0, 8.0, 12.0], "center_stand": [0.0, 0.0, 66.0],
   "anchor": "head", "fixed_size_in_crouch": true}
  ```
  The top level adds `"version": "0.2"`, `"stand_height": 72.0`, `"eye_stand": 64.0`, `"crouch_scale": 0.85`, `"max_rewind_ticks_128": 25` and `"near_miss_units": 1.0`.
- `SKELETON_SHA256` = the SHA-256 of that JSON file in canonical form (keys sorted, no extra spaces, LF line endings, UTF-8). It's written into every evidence log header and demo header, so a review always knows which skeleton was used.

## 9. Done when (for v0.2 sign-off)

- [ ] Joan approves or corrects A1–A5 and the two crouch decisions.
- [ ] All 11 boxes have a size, a bone anchor, and standing, crouched and jump placement (Sections 2–4). **Done in this draft.**
- [ ] The crouch numbers agree with each other (Section 3 decision).
- [ ] The rewind matches the 200 ms cap (Section 7). **Done: 25 ticks.**
- [ ] Game Builder sign-off, then Devin gets the go for hitbox code (`DEVIN_HANDOUT_v2.md` Task 2).

---

## APPROVED Oct 17 2026 (Joan)

**Status: APPROVED**, with one crouch override. Standing tables (Section 2), A1, A3, A4, A5, jump pose (Section 4), hit-test rules (Section 5), and rewind (Section 7: **25 ticks / 195.3125 ms at 128**, ring of 26 samples) are locked as written. **GDScript first** for all hitbox / lag-comp / hitreg code.

### Crouch override (replaces A2)

A2's **15% shorter (× 0.85)** is **rejected**. Joan locked **HALF-HEIGHT crouch**:

- `crouch_scale = 0.5`
- Crouched body height = **36.0** units (`0.5 × 72.0`)
- This matches GoldSrc crouched collision height (36) and closes the "head above waist-high cover" warning in Section 3

The × 0.85 tables and the 0.8333 alternative in Section 3 stay in this file as history. **Do not rewrite those tables.** New crouched numbers live in `specs/skeleton_constants.json` / `shared/skeleton_constants.gd` when Devin (or Game Builder) generates them under `CROUCH_SCALE = 0.5`.

### What must be recomputed for crouch (scale 0.5)

Recompute and regenerate; do not hand-edit the standing Section 2 table:

1. **Every non-head box:** bottom_z and top_z × 0.5 around the feet (same rule as Section 3, new scale). Width and depth unchanged.
2. **Head:** keeps size **8 × 8 × 12**. Top of head at `crouch_scale × stand_height` = **36.0**. Head center z = 36.0 − 6.0 = **30.0**. Crouched head z range **24.0 → 36.0**.
3. **Eye height crouched:** `0.5 × 64.0` = **32.0** (must sit inside the crouched head box: 24–36 ✓).
4. **Crouched collision body height:** **36.0** (must agree with movement when crouch is modeled in `movement.gd`).
5. **JSON top-level:** `"crouch_scale": 0.5` (was 0.85). Recompute `SKELETON_SHA256` after the change.
6. **Devin Phase 2:** default `CROUCH_SCALE = 0.5`. Drop or demote the 0.85 / 0.8333 alternative tests; keep one regression that 0.5 puts head top at 36.0 and eye at 32.0.
7. **Cover / visibility sanity:** with half-height crouch, a player behind ~36–40 unit cover is fully hidden and cannot see over it. That was the point of rejecting 15%.

### Still out of scope (unchanged)
Damage multipliers, player model / hold pose, limb tuck in jump, and crouch transition animation remain out of this spec.

---

## APPROVED AMENDMENT Oct 17 2026: crouch transition hitbox = hybrid blend

**Decided by:** Game Builder, on Joan's delegation ("I trust your judgement pick the best option, like the hybrid option you gave me for recoil").

**Problem:** on PR #7 the eye drops linearly (64.0 → 32.0 over `DUCK_TIME_S` 0.4 s) while `stance_for_hitbox` stays "stand" until `ducked`. For up to 52 ticks at 128 the eye sits below the standing head box (60.0–72.0). Not exploitable (the head is still exposed), but it breaks the "eye inside head box" rule and makes hitboxes disagree with what the model shows.

**Rule (hybrid):**
1. Duck fraction `f` in `[0.0, 1.0]`: `f = clamp((float(duck_ticks) / tick_rate) / DUCK_TIME_S, 0.0, 1.0)`; `f = 1.0` when `ducked`; `f = 0.0` when standing. Same `f` that drives `eye_height` (K3), so the two can never disagree.
2. **Every box's z range** is `lerp(stand_z, crouch_z, f)` for bottom and top separately. Crouched values are the scale-0.5 ones above (head 24.0–36.0, non-head boxes × 0.5 around the feet). Width/depth and x/y never change.
3. Head check, all f: head bottom = `60.0 − 36.0 f`, eye = `64.0 − 32.0 f`, head top = `72.0 − 36.0 f`. Eye − bottom = `4.0 + 4.0 f` > 0, top − eye = `8.0 − 4.0 f` > 0. **The eye is inside the head box at every tick.**
4. Hit tests stay **box-based** (Section 5 unchanged). No capsules, no animation-driven boxes.
5. **Lag comp:** the history ring stores `duck_fraction` (float) per sample (or `duck_ticks` + `ducked`, from which f is recomputed with the same formula). A rewind rebuilds mid-duck boxes from the stored value. Interpolating between two history samples lerps f too.
6. Air duck (instant in GoldSrc) and unduck (instant) are just f = 1.0 / f = 0.0 steps; no extra case.
7. The **collision hull** is unchanged (72.0 until `ducked`, then 36.0, as PR #7 does). Only hitboxes and eye blend.
8. `stance_for_hitbox` stays the coarse evidence stance code (0/1/2/3); the builder takes `f` in addition. Evidence records may log f quantized (proposal: u8, f × 255) when the record layout is next revised.

**Owners:** Claude (movement.gd: expose `duck_fraction(s)`, eye_height from the same f, tests). Devin (hitbox builder takes f, lag-comp history stores it). Both read the same formula; constants from `skeleton_constants`.

## AMENDMENT Oct 17 2026 (Joan, 03:22 UTC): hit-test padding = 2.0 units per bone (PROVISIONAL)

Joan's final answer: **keep 2 units.** This amends Section 5 (hit rules). It does **not** change the skeleton.

1. **Where it applies:** at hit test only. The ray-vs-OBB test grows each box by `HITBOX_PADDING = 2.0` units on every face (half extents `+ 2.0` on x, y and z, around the same center, same yaw), then runs the normal entry-distance rules on the grown box. The padding is **per bone** (a value per box id, all `2.0` for now) so it can be tuned bone by bone later.
2. **Not in the geometry:** `skeleton_constants.json`, the built boxes, `build_boxes(...)` output and **`SKELETON_SHA256` (`56db86a8…7aa0`) are unchanged.** The padding lives in hit-test config (`HitboxConfig` / hitreg), not in the canonical JSON. Debug drawing shows both the real box and the padded outline.
3. **Order of rules is unchanged:** a ray that enters any padded box is a hit on the box it enters first (entry distance first; the crouched head overlap rule `CROUCH_HEAD_OVERLAP_RULE` still applies to the padded boxes). Overlaps grow by the padding; tests must document the new head/chest overlap band at stand and crouch.
4. **Near misses for tuning:** a shot that hits no padded box but passes within **4.0 units** of a padded box surface is logged as a near miss (SHOT record, evidence spec). Name: `NEAR_MISS_LOG_UNITS = 4.0` in hit-test config. It replaces the 1.0 in Section 5 rule 4 for logging; the `near_miss_units: 1.0` field already in `skeleton_constants.json` is left as is (changing it would change the SHA) and should be dropped or updated at the next deliberate SHA revision.
5. **Status: PROVISIONAL** pending near-miss data. When there's data, Joan decides the per-bone values (can go to 0.0 for some bones).
6. Owner: Devin (`DEVIN_MEGA_HANDOFF.md` Addendum 4). Reconciliation item 12.
