# Hard mode design doc v0.1

*Joan's dictation, October 17 2026, recorded by Game Builder. Not public yet.*
*Status: **Joan's doc**, Sections 1–10 kept faithful. The last section lists where it conflicts with already-locked specs; Joan resolves those. Items are also appended to `specs/SPEC_RECONCILIATION.md` (items 12–23).*

**Joan's instruction to Game Builder:** build in order, float literals only, private folder, no public commits.

---

## 1. Design philosophy

Hard is not unfair. Every penalty has a **readable cause** and a **learnable counter**. The player who dies should be able to **name why within one second**. If they can't, the difficulty is noise, not challenge.

## 2. Movement hardness

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §movement, §missed-hop

- **Air-strafe gain is the primary skill expression:** 128 tick gives **202 u/s per second** at 250 u/s; 64 tick gives **115**. That gap is the whole game.
- **Bhop cap at 1.2× maxspeed** crops you to **0.8**, so speed above 300 must be built inside a single hop.
- **Stamina timer 1315 ms** weakens the next jump by **up to 25%**.
- **Missing a hop by one tick costs 5–7% speed.**
- These numbers are not suggestions. They are the difficulty curve.

## 3. Information scarcity

- **Two-stage visibility culling:** a coarse **precomputed cell table** at map build time, then fine **line-of-sight rays** from the **predicted eye position** to **head, chest, feet and both shoulders**.
- A **safety margin** makes peekers appear **at least one frame early**.
- **Sound events** send **rounded positions**, within hearing range only.
- **Teammates are always sent.**
- **Spectators get a 90-second delay.**
- **Smoke blocks line of sight** once fully bloomed.
- **The client never receives what it cannot see.**

## 4. Combat hardness

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §hitbox

- **Hitboxes are boxes with two-unit padding, not capsules.** Generous errors feel fair; stingy ones feel like bullshit.
- **Near-misses within 1 unit** are logged with shooter angles, rewind amount and hit position.
- **Rewind cap 200 ms**, server-picked, clamped to **±1 tick**.
- The **crosshair mirrors server-side** accuracy, punch and movement state: **green standing, yellow running, red air.**
- A silent-aim cheat shows a mismatch: **tight crosshair, inhuman flick.**

## 5. Round hardness

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §round (armor)

Same numbers as `specs/round_loop_spec_v0.1.md`: freeze 15 s; free play until 1:40; plant 3.2 s; defuse 10 s with kit, 15 s without. Economy starts $800; kill $300; plant $200 + $300 team; defuse $300 + $600 split; loss bonus $1400 → $3400; win $3000; armor $455 with helmet. **Buy menu is server-validated:** the client sends requests, the server applies them.

## 6. Bot hardness

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §bots
> SUPERSEDED by CURRENT_DECISIONS.md CD-r3 §bots (bots DECIDED, build order; `bot_spec_v0.1.md`)

- **Five states:** idle, patrol, engage, retreat, flank.
- **Retreat** below **30% health** or when **outnumbered**.
- **Flank** uses the visibility table; **bots never path through culled space.**
- Comms: death call **"captain down"**; kill call on a **confirmed kill**.
- **Bots run as headless clients through identical netcode.**

## 7. Anti-cheat hardness

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §evidence

- **Rejected-input records:** tick, player ID, sequence, reason code, raw bytes.
- **Near-miss records: 24 bytes fixed.**
- **Rewind decision records: 20 bytes fixed.**
- **Ring buffer, 30-day retention, daily rotation.**
- A **Rust CLI exports CSV** for statistical analysis.

## 8. Implementation order

1. Round controller phase enum
2. Economy math
3. Buy menu
4. Bomb mechanics
5. Bot state machine skeleton
6. Radio commands
7. Voice triggers
8. Crosshair
9. Evidence log (waits on the Rust layer)

## 9. Success criteria

- **Movement parity S2** passes before any round code ships.
- **Prediction loop S1–S9** pass before netcode goes live.
- **Hitbox constants match on server and client**, or lag comp is thrown out.
- **Bot commands are indistinguishable from human input** at the anti-cheat layer.
- **Round state transitions are server-only events.**

## 10. Open questions

1. Should surf maps raise `sv_airaccelerate` to **100** as a server config option?
2. Is the **two-unit padding** enough, or does it need **per-bone tuning** from near-miss data?
3. Should the **moving-before-air kick bug** from 1.6 be kept or fixed?
4. **Fixed random side-flip recoil** or **CS2-style learnable patterns**?
5. **Subtick timestamps** as a later upgrade path, or **locked 128 tick forever**?

---

## Conflicts with locked specs (Game Builder, Joan to resolve)

Each item was checked against the actual files on `main` (Oct 17 2026). Nothing above was changed; these are flags only. Reconciliation item numbers in brackets.

1. **[12] 2-unit hitbox padding is not in hitbox v0.2.** `hitbox_spec_v0.2.md` (APPROVED) has box width = 2 × radius (A1), no padding, and a separate 1.0-unit near-miss band. Padding every box by 2 units would change every size and `SKELETON_SHA256` (`56db86a8…7aa0` at crouch 0.5), and the evidence spec (Section 6) says sizes only change from near-miss data in ≤ 0.5-unit steps after ≥ 1,000 near misses per part/stance. Options: (a) padding = 0 (as approved), (b) 2.0 on every box, (c) a `HITBOX_PADDING` config fed into the skeleton JSON (bumps the hash).
2. **[13] Record sizes.** Doc: near-miss 24 B, rewind decision 20 B. `evidence_logging_spec.md`: near misses are **SHOT records (type 1), 116 B** (108 body + 8 header); **REWIND_DECISION (type 5), 72 B** (64 body + 8 header). 24 B can't hold eye position, two angles, rewind, hit point and distance in the agreed precision; 20 B can't hold claimed/expected/chosen view ticks as f64. Proposed: keep 116/72 (the doc's "fixed size" principle holds; the numbers don't).
3. **[14] Rejected-input record.** Doc: tick, player ID, seq, reason, **raw bytes**. Spec INPUT_REJECT (type 3, 34 B): tick (header), player_slot, reason, cmd_seq, claimed/expected time, **no raw bytes**. Proposed: add a variable-length raw-bytes tail only for reason 4 (malformed), or rely on the server demo's raw input.
4. **[15] Retention and storage.** Doc: **30 days**, ring buffer, daily rotation, Rust CLI → **CSV**. Spec: **90 days** (DECISION FOR JOAN), one append-only hash-chained `.fpev` file per match (not a ring buffer, which would break the chain), `fpev export` → **JSON Lines**. Proposed: per-match files kept 30 or 90 days with daily deletion of expired matches; CSV as an extra export format.
5. **[16] Strafe gain numbers.** `sim_results.txt`: 128 tick **201.7** u/s per second at 250 (doc's "202" is the rounded value; tests use 201.7/1.576 per tick); 64 tick **114.8** (doc's 115 matches when rounded). ✓ consistent, keep exact values in tests.
6. **[17] Bhop cap wording.** Sim/movement spec: above 1.2 × 250 = **300 u/s**, a jump crops you to **240 u/s** (= 0.8 × the 300 cap, i.e. 0.96 × maxspeed), not 0.8 × maxspeed (200). The doc's "crops you to 0.8" should read "0.8 × the cap". ✓ otherwise consistent.
7. **[18] Stamina "up to 25%".** Formula `ratio = (100 − timer_ms × 0.019) / 100` with timer 1315.79 ms: at a fresh timer 100 − 25.0 = **75% → 25% weaker**. ✓ verified as the maximum. But a perfectly chained bhop lands after the airtime (86 ticks ≈ 672 ms at 128), so the real chained penalty is **~12%** (sim: vz 235.5 vs 268.3). The doc's "1315 ms" is the rounded 1315.789429. Also: stamina's **ground-speed slowdown** is still unmodelled (reconciliation item 10, Claude's PR #1 stamina call pending). **Update (Oct 17 2026): no longer pending. Joan DECIDED to combine: Claude's tick-independent top-speed cap × stamina ratio, with its recovery curve tuned to ReGameDLL's 100-tick feel (~188 u/s at 100 ms after a 250 landing), the same value at every tick rate. See reconciliation item 10 and `CLAUDE_MEGA_HANDOFF.md` Addendum 2.** **Update (Joan, Oct 17 2026, 03:22 UTC): the combine decision above is REVERSED. Final: match real CS 1.6, slow the current speed every tick (velocity × stamina factor per ground tick, ReGameDLL style), not a top-speed cap. Values differ by tick rate (~240 / ~190 / ~158 u/s at 64 / 100 / 128, 100 ms after landing at 250); 100 tick is the reference feel. Reconciliation item 10; `CLAUDE_MEGA_HANDOFF.md` Addendum 4.**
8. **[19] "Missing a hop by one tick costs 5–7%".** From `sim_results.txt` (one ground tick of friction, no acceleration, no stamina slowdown): **6.25% at 64 tick** (240 → 225.0, 300 → 281.2), **4.0% at 100**, **3.1% at 128** (240 → 232.5). The 5–7% (also in `goldsrc_movement.md` line 59) matches **64 tick only**; at our locked 128 tick it's ~3%. Partly verified; the stamina ground slowdown (unmodelled) would add to it.
9. **[20] Culling margin and LOS points.** Netcode §6.3 says "at least a frame before"; `CLAUDE_MEGA_HANDOFF.md` P5 is stricter: sent **≥ 2 ticks (one snapshot interval)** before the first clear margin-free ray, 8.0-unit lateral margin, **no vertical margin** (so a crouched head can't peek over cover). ✓ compatible (P5 meets "≥ 1 frame"). LOS points: P5 already uses head, chest, feet and both shoulders (stand 66/54.5/2/58 ±12; crouch 30/27.25/1/29 ±12) from the current and look-ahead eye. ✓ matches. Gap: P5 is **fine stage only**; the coarse cell table is deferred until real maps.
10. **[21] Crosshair anti-cheat wording.** Doc §4 "tight crosshair, inhuman flick" restates crosshair spec §4, which review note (c) already flagged: the client crosshair can't be evidence. Evidence must be **server-side** (AIM_KIN, type 6, proposed: view-angle velocity/acceleration/snap-back around each shot + server spread at fire). Proposed: read §4's last line as "the server sees tight spread at fire plus an inhuman flick".
11. **[22] "Crosshair eighth" in the order.** The crosshair prototype is **already built** (`gamebuilder/crosshair`, 27/27 tests on Godot 4.4.1, not merged). Proposed: step 8 = "wire the crosshair to the real NetClient" (Claude P4), not "build".
12. **[23] Bot comms and states vs the bot skeleton.** `bot_spec_v0.0_skeleton.md` has no state list, puts voice lines and team calls **out of scope for v0.0** (§9), and says bots are **server-side only** with no client. The doc adds 5 states, retreat rules, flank via the visibility table, "captain down" / kill calls, and "headless clients through identical netcode". Proposed: fold the 5 states and comms into bot spec v0.1; read "headless client" as "server-side bot that emits the same `InputCmd` stream through the same validation path" (Claude P8), unless Joan wants a separate process. Also: "never path through culled space" needs a definition (the visibility table is per viewer, not per path).

## Clarifications (appended, Joan, Oct 17 2026, 03:22 UTC)

- **Evidence record sizes and retention (§7):** the "near-miss records: 24 bytes", "rewind decision records: 20 bytes" and "30-day retention" above were Joan compressing for brevity, **not a spec change**. The evidence spec stands: **SHOT 116 B** (near misses are SHOT records), **REWIND_DECISION 72 B**, **90-day retention**. Reconciliation items 13 and 15 closed.
- **Hitbox padding (§4, open question 2):** **2 units kept**, applied at hit test only (skeleton geometry and SKELETON_SHA256 unchanged), **PROVISIONAL** pending near-miss data; near misses within 4.0 units are logged for per-bone tuning. See the `hitbox_spec_v0.2.md` amendment.
