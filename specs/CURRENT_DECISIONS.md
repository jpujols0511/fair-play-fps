# CURRENT_DECISIONS: the one canonical source of truth

**Revision: CD-r9 (2026-10-17)**

**Rules**
1. **This file wins.** If anything else in the repo (specs, handoffs, addenda, reconciliation, PR text, code comments) conflicts with this file, this file is right and the other text is history.
2. **Changes happen only here, by bumping the revision** (CD-r2, CD-r3, ...) with an entry in the changelog at the bottom. No more amendments scattered across specs and handoffs. Older docs keep their text with a `> SUPERSEDED by CURRENT_DECISIONS.md CD-rN §<topic>` marker.
3. It holds **only Joan's latest calls**, plus Game Builder decisions made **under Joan's delegation** (marked **[GB, delegated]**). Anything not decided is under **OPEN**, not guessed.
4. **Branch/PR tagging:** every PR description and every branch must declare `Follows: CD-r1` (or later) and carry a `DECISIONS_REVISION` file at the repo root containing that revision.
5. Floats everywhere in code math (`250.0`, not `250`).

Sources: "Joan" = Joan Pujols's call on the date given. File references point to where the detail lives; the value here is the one that counts.

---

## §movement
- **S2 gate** (movement.gd parity) gates everything: top chained bhop **340.72 u/s @128**, ideal strafe gain **201.71 u/s per second @250** (114.8 @64), Python sim parity, `specs/sim_results.txt` byte-identical. *(Joan, locked; `prediction_loop_scope.md` locked decisions; PR #1 merged Oct 17 2026)*
- Tick **128 Hz** (7.8125 ms); 64/100 for testing. *(netcode D2)*
- **Stamina = real CS 1.6:** on every ground tick while the stamina timer runs, **multiply the current horizontal speed** by `stamina_ratio = (100.0 - timer_ms * 0.001 * 19.0) * 0.01` (ReGameDLL style), **not** a top-speed cap. `STAMINA_MS = 1315.789429`; jump `vz = 268.32816 × ratio`. **Tick-dependent on purpose** (landing at 250.0, 100 ms later: ~240 / ~190 / ~158 u/s at 64 / 100 / 128). **100 tick is the reference feel.** *(Joan, Oct 17 2026 03:22 UTC, final; supersedes "combine". Work: Claude `claude/stamina-tuning`)*

## §crouch
- **Half height: `CROUCH_SCALE = 0.5`.** Standing body / eye **72.0 / 64.0**; crouched body / eye / head top **36.0 / 32.0 / 36.0**. *(Joan, Oct 17 2026, hitbox v0.2 APPROVED note)*
- Collision hull 72.0 until fully `ducked`, then 36.0. *(PR #7, merged)*
- **Hybrid hitbox blend:** hitboxes and eye follow the same **duck fraction** `f` (0.0 standing → 1.0 ducked): eye `64.0 − 32.0 f`, head box `60.0 − 36.0 f` → `72.0 − 36.0 f`, every box z range lerped stand → crouch by `f`. *[GB, delegated by Joan Oct 17 2026]* (`hitbox_spec_v0.2.md` APPROVED AMENDMENT)
- **Duck fraction stored in lag comp** (history sample field, lerped, used on rewind) and **sent to remotes** (snapshot entity u8 `round(f × 255.0)`, lerped in InterpBuffer, remote crouch drawn from it). *[GB, delegated]* (Devin Addendum 3 A3-b; Claude Addendum 3 item 2)
- Duck time 0.4 s, ducked speed ×0.333, air-duck feet lift 18.0: PROPOSED switches C6–C8 (GoldSrc behavior), in code; not separately ruled by Joan.

## §hitbox
- **Hitbox v0.2 APPROVED** (boxes, 11 bones, A1/A3/A4/A5 as written, crouch per §crouch). *(Joan, Oct 17 2026)*
- **Rewind cap 25 ticks = 195.3125 ms** (under the 200 ms cap), server-picked. *(Joan, Oct 17 2026)*
- **`SKELETON_SHA256 = 56db86a8d12c400f5149f7cfcbf17ec79dd662c93cc6a3d5f18d4d0c288f7aa0`** (canonical JSON with `crouch_scale` 0.5, 1,537 bytes). *[GB, computed under Joan's 0.5 call]* (Devin Addendum 2 A2-a)
- **Padding 2.0 units per bone, applied at hit test only** (expanded box in the ray-vs-OBB test; skeleton geometry and SHA unchanged). **PROVISIONAL** pending near-miss data. *(Joan, Oct 17 2026 03:22 UTC)*
- **Near misses logged within 4.0 units** of the padded surface, for tuning (SHOT records). *(Joan, Oct 17 2026 03:22 UTC)*
  - **`HitboxConfig.NEAR_MISS_LOG_UNITS = 4.0` is the ONLY near-miss value.** `NEAR_MISS_UNITS = 1.0` in the generated `skeleton_constants.gd` (from the SHA-locked skeleton JSON `near_miss_units`) is **unused/legacy and must not be read**. Fix it the next time the skeleton hash is changed on purpose. *[GB, delegated; CD-r4]*
- GDScript first; Rust only after a benchmark proves a need. *(Joan)*
- **`ray_box` unit-direction check is strict:** it accepts a direction only if its squared length is within **1e-9** of 1.0 (`ray_box.gd` `UNIT_DIRECTION_EPS`), and otherwise fails closed as a miss. **Callers must normalize in 64-bit floats** (component-wise on `float`/`PackedFloat64Array`); a 32-bit `Vector3.normalized()` can land outside 1e-9 and will be rejected. *[GB, delegated; CD-r8]*
- **Frozen zero-padding baseline golden** may keep the **legacy 1.0 near-miss limit** (`tools/ray_box_ref.py` `_case` default `NEAR_MISS_UNITS`). That is allowed for that frozen file only; everything live uses `NEAR_MISS_LOG_UNITS = 4.0`. *[GB, delegated; CD-r8]*

## §recoil
- **Owner: Devin.** Recorded-draw parity against the Python sim. *(Joan)*
- **All 16 sprays tested shot by shot** (AK47 + M4A1 × stand/crouch/run/air × 64/128), exact recovery checks (tick count + 1e-9 seconds). *[GB, delegated]* (Devin Addendum 2 A2-c)
- **Stock CS 1.6 stepped accuracy, not ReGameDLL's smoothed fan.** After each rifle shot, accuracy = **whole-number part of (shots³ ÷ divisor)** + floor, capped (integer division, as in stock 1.6), **not** the smooth float cubic. AK47: **0.35 after shots 1–5, 1.25 (cap) from shot 6 on**; M4A1: **0.30 after shots 1–6, 1.00 (cap) from shot 7 on**. Spread still uses the accuracy stored **before** the shot, so an AK spray is tight (floor) for shots 2–6 and at the cap from shot 7; an M4 is tight for shots 2–7 and at the cap from shot 8. Shot 1 uses the stored value (0.2 fresh). Reason: documented stock behavior, and harder for cheaters. Code math stays in floats (`floor(n * n * n / divisor)`), no int literals. Task: `specs/tasks/DEVIN_STOCK_ACCURACY.md`. *(Joan, Oct 17 2026)* **Supersedes** the "smooth cubic / first 3–4 shots stay tight" wording in `goldsrc_recoil_spread.md` §2, `sim_recoil_results.txt` and `rifle_tables.gd`.
- **Shot-counter recovery follows stock 1.6** (part of the same stock call; closes OPEN 6): **15-shot release cap ON by default** (`SHOTS_FIRED_RELEASE_CAP = 15.0`; after release a 30-shot spray resets in ~0.84 s at 64 tick, ~0.83 s at 100 tick, ~0.73 s at 128 tick), **`RECOVERY_DELAY_FROM = "release"`** (the 0.4 s delay starts when the trigger is released, not at the last shot), **first drop on the first tick strictly after 0.4 s** (`BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD = false`; compare `> 0.4 + 1e-9`), and **at most one decrement per tick** (0.0225 s apart). The old values stay available as switches. Stored accuracy is still **not** reset when the counter recovers (J4 stock quirk kept). *[GB, delegated, applying Joan's stock call; Joan may override]* **Supersedes** "Default = current spec/sim behavior until Joan picks" (CD-r1…r8).
- Spread seed is chosen by the server at fire time. *(Joan)*

## §prediction
- **Owner: Claude.** *(Joan)*
- **Jitter OFF for S1–S3, ON for the S4 playtest.** *(Joan, Oct 17 2026; reconciliation R1)*
- **v1 collision = one box + one step**, custom box tests, no Godot physics bodies. *(Joan; R2)*
- **`main.gd` owns the tick.** *(Joan)*
- **Interp delay default 4 ticks** (31.25 ms) until Joan picks 2, 3 or 4 (see OPEN). *(Joan: "4 until I decide 2 or 3")*
- No extrapolation by default (hold the last pose). *(netcode D8, C2)*

## §snapshots
- **Own player in f64** (full precision). *(C3; PR #8 merged)*
- **64 Hz** (every 2nd tick); 128/s LAN option. *(netcode D4, C4)*
- **32 baselines per client.** *(netcode §4, C5)*
- **Split interp gate:** max position error **≤ 1.0** on non-jump paths, **≤ 4.0** on jump/landing paths, **p99 ≤ 0.25 overall (pooled across all path kinds); per-kind p99 is reported but not gating**. *[GB, delegated]* (Claude Addendum 3 item 6; wording clarified in CD-r5, this was always the intent of the split-gate ruling, p99 value unchanged)

## §visibility
- **C9: 8.0 units lateral margin, no vertical margin**; look-ahead RTT/2 + one snapshot interval; sample points include the **head center (66.0 standing / 30.0 crouched)** plus a **crown point at the top of the head box (72.0 standing / 36.0 crouched)**, with **no vertical margin**. *[GB, delegated; PR #13 review. C9 was PROPOSED in the Claude handoff]*
- **C12: sent-mask history 640 ticks** (5 s at 128). *[GB, delegated]*
- Teammates always sent; the client never receives what it can't see. *(Joan, hard mode §3)*

## §net-anticheat
- **Per-client command budget: 1 per tick, burst 8**; excess commands are **dropped and logged as RATE_ABUSE**. *[GB, delegated]* (Budget enforced in PR #15: 1 per tick, burst 8. *CD-r7*)
- **Drop command seqs more than 64 ahead** of the last executed seq. *[GB, delegated]*
- **`CMD_WINDOW = 64`** (drop seqs more than 64 ahead) and **`CMD_RESYNC_TICKS = 128`**: values from Claude's PR #15, adopted by Game Builder. **Resync after an outage must be bounded** and must not jump to an arbitrary far-ahead seq (today `fake_server.gd:145` sets `next_seq = _far_latest`). *[GB, delegated; CD-r7]*
- **Reject forged acks** (acks for snapshot seqs never sent, or newer than the newest sent); count `acks_rejected`. *[GB, delegated]* (Claude Addendum 1 A1-b.1 / Addendum 3 item 3)
- "Aimed at a never-sent enemy" is **review-only, never auto-bans**. The crosshair is never evidence. *(Joan)*

## §evidence
- **SHOT 116 B**, **REWIND_DECISION (type 5) 72 B**, **AIM_KIN (type 6) 48 B**, hash-chained. *(Joan, Oct 17 2026 03:22 UTC for 116/72; AIM_KIN 48 B per crosshair spec note (c))*
- **Retention 90 days.** *(Joan, Oct 17 2026 03:22 UTC)*
- **Writer/reader on hold** until the Rust layer (Devin Phase 6 ON HOLD). *(Joan)*

## §round
All values are **placeholders until the game is adapted toward Source / CZ / CS:GO / CS2**. *(Joan, Oct 17 2026)*
- Freeze **15.0 s**; round **100.0 s** (1:40); plant **3.2 s**; defuse **10.0 s with kit / 15.0 s without**. *(Joan, round_loop_spec §1)*
- Start **$800**; kill **$300**; plant **$200 planter + $300 team**; defuse **$300 defuser + $600 split**; loss bonus **$1400 / 1900 / 2400 / 2900 / 3400** (5th+); win **$3000**. *(Joan, round_loop_spec §2)*
- **Vest $650, vest + helmet $1000.** *(Joan, Oct 17 2026 03:22 UTC; $455 was wrong)*
- **Bomb timer 40.0 s, MR12, cash cap $16,000, CS 1.6 weapon prices** (table in round_loop_spec note (e), AK T-only, M4 CT-only). *(Joan, Oct 17 2026; accepted again 03:22 UTC)*
- Owner: Game Builder. Server-validated buys, server-timed plant/defuse.

## §surf
- **Opt-in** server config; **`sv_airaccelerate` 10.0–100.0, default 10.0.** *(Joan, surf_config §6/§7)*
- **Separate listing and browser tag.** *(Joan, surf_config §6)*
- **Limited-time event first.** *[GB recommendation; Joan: "queue it"]*
- **Claude's own task after the networking phases**, three sub-items: (a) `sv_airaccelerate` setting; (b) ramp slide physics (plane collision, ClipVelocity, steepness); (c) edge friction. *(Joan, Oct 17 2026 03:22 UTC)*
- **Surf servers flagged separately**; the **AIM_KIN flick detector uses a separate threshold profile** on them. *(Joan confirmed, Oct 17 2026)*

## §bots
- **DECIDED** *(Joan, Oct 17 2026)*: bots run **server-side**, through the **same input path** as players (same `InputCmd`, slot queue, validation, 1 cmd/tick budget, movement); **radio calls are text/sound events**, not voice files. **No hidden info:** a bot sees only what visibility culling would send to its slot. Spec: `specs/bot_spec_v0.1.md`.
- **Five states:** **IDLE, PATROL, ENGAGE, RETREAT, FLANK** *(Joan, hard_mode_design §6)*; retreat below 30% health or when outnumbered. **"Outnumbered" counts the bot itself as support, so a 1v1 is not outnumbered.** *[GB, delegated; CD-r5]*
- **Build order** *(Joan, Oct 17 2026; Game Builder starts at step 1)*:
  1. Server-side controller that reads snapshots and writes input commands, no special netcode path (overlaps Claude's Phase 8 bot driver: step 1 = review/merge her P8).
  2. Five-state machine; transitions from visible enemies, ammo, health, teammate positions.
  3. Radio as text and sound events, not voice files.
  4. Death-call ("captain down") and kill-call (confirmed kill) triggers.
  5. Aim Lab mode as a sixth config, random spawn targets.
  6. Team coordination: a flank waits for a teammate to draw fire.
  7. Difficulty dials (reaction delay, aim error), start casual, tighten until the player loses.

## §crosshair
- **Latency is stated honestly as 2–3 ticks**, not "0 ms": with the fixed tick order (packets sent in step 3 arrive in step 1 of the next tick), stand→run→crosshair takes **2–3 ticks even at 0 ms ping**; real ping adds the round trip on top (crosshair spec note (a)). The crosshair spec and HUD docs say 2–3 ticks. *[GB, delegated; closes OPEN 5; CD-r8]*

## §missed-hop
- Wording is **tick-dependent**: missing a hop by one tick costs **~6.25% at 64, ~4.0% at 100, ~3.1% at 128** (friction only, sim). Re-measure once the per-tick stamina slowdown lands. *[GB, delegated; reconciliation item 19]*

## §goldsrc-godot
- **Stay on Godot 4.4.1** (official binary). **References only** (no third-party code/binaries in the repo), **our own map reader**, **GoldSrc box hull** (not a capsule), **our own compiled test map**. *[GB default; Joan may override]* (`goldsrc_godot_pipeline_eval_v0.1.md`)

## §process
- **Floats only** in math (no int literals). **GDScript only** (Rust after a benchmark). **No Godot physics bodies.** **No Valve or GPL code**; Valve sources read-only; no reverse-engineering of Valve binaries. *(Joan)*
- **Nothing public until Joan signs off.** *(Joan)*
- **Game Builder reviews and merges Claude's and Devin's PRs when green** (all suites pass on Godot 4.4.1, sim byte-identical, no open blockers; merge commits, no squash, no force-push). *(Joan, Oct 17 2026)*
- Every PR/branch declares **`Follows: CD-rN`** and has a root **`DECISIONS_REVISION`** file. *(Joan approved, Oct 17 2026)*

---

## Known issues (must fix; tracked here until closed)
1. **CLOSED in CD-r8: fixed by PR #21 (merge `8e5db93`).** **PR #5 (P3 ray vs box, merged at `b12cd4f`) has two must-fix items** for a Devin follow-up PR **before P5 hit registration**. *[GB review; CD-r5]*
   - `ray_box.gd` must **fail closed**: reject non-finite origin/direction/length (NaN currently falls through the slab loop and returns a head hit at distance 0), and **require or normalize a unit direction** (a scaled direction currently extends range).
   - `ray_box_cases.json` and the padded golden use the **superseded 0.85 crouch geometry**; a **new golden from the current 0.5 skeleton** is needed (new file; the old one is marked legacy, not overwritten).
   - **P5 may not merge until both are fixed.**
2. **P5 hit registration (PR #9)** must **normalize the spread direction before calling `ray_box`**, or `ray_box` must reject non-unit vectors (item 1). *[GB review; CD-r5; label corrected in CD-r7: CD-r5 wrongly said PR #6, which is P4 lag-comp. PR #9 already normalizes.]*
3. **CLOSED in CD-r8: fixed by PR #21 (merge `8e5db93`); the frozen baseline keeping 1.0 is allowed (§hitbox).** **`tools/ray_box_ref.py` still defaults `near_miss_limit` to the legacy 1.0** (`NEAR_MISS_UNITS`). That default applies **only to the frozen baseline**; everything else uses `NEAR_MISS_LOG_UNITS = 4.0` (see §hitbox). *[GB review; CD-r5]*
4. **CLOSED in CD-r8: fixed by PR #9 (merge `c9867fe`).** **Lag-comp claim check lets NaN through** (PR #6 merged at `93361ef`): `weapons_proto/hitreg/rewind_policy.gd` lines 38-56 (and `tools/lagcomp_ref.py`) pass a **NaN `claimed_view_tick` or `rtt_ms`** through the window check (NaN comparisons are false), so `rewind_ticks` overflows to **INT64_MIN**. **Non-finite claims must fail closed:** `INPUT_REJECT`, flagged `CLAIMED_TIME_OUT_OF_WINDOW`, clamped to the expected tick. **P5 (PR #9) may not merge until this and Known issue 1 are fixed.** *[GB review; CD-r6]*
5. **Cross-platform golden checks compare within a tolerance of 1e-6**, not exact bytes or 1e-9 hashes, because Mac and Linux differ by up to ~1e-7. Existing exact/1e-9 goldens move to this tolerance compare when next touched. *[GB ruling, delegated; CD-r6]*
6. **CLOSED in CD-r8: fixed by PR #12 (merge `ba3165b`).** **P6 evidence exporter decodes view angles wrong** (PR #12): `fpev_jsonl.gd:96-97` and `tools/fpev_ref.py:589-590` use `q*360/65536`. They must use `InputCommand.dequantize_*` plus `FrameAdapter` (spec frame), and the `match_small` golden must be fixed. **P6 (PR #12) may not merge until that's done.** Non-blocking: the writer must refuse out-of-range u8 values instead of wrapping; the reader must cap `slot_count` at 16 and check `format_version` and the skeleton SHA. *[GB review; CD-r7]*

---

## OPEN (not decided; don't build as if decided)
1. **Interp delay 2 / 3 / 4 ticks** (default 4 until Joan picks; Game Builder leans 2–3).
2. **MR12 vs MR15**, if revisited (MR12 accepted for now).
3. **Launcher repo + Rust scope.**
4. **Hard mode remaining conflicts:** INPUT_REJECT raw bytes (item 14), bhop-crop wording (17), crosshair as evidence / AIM_KIN approval wording (21), crosshair "eighth" in the build order (22), bot states/comms/headless clients vs the skeleton (23).
5. ~~Crosshair latency line~~: **CLOSED in CD-r8** (see §crosshair). Was: a "0 ms" latency line vs the real 2–3 ticks (crosshair spec note (a), `prediction_loop_scope.md` S5 "0 ticks added latency"). Joan to confirm the wording.
6. ~~15-shot release cap default and `RECOVERY_DELAY_FROM`~~: **CLOSED in CD-r9** (see §recoil: cap 15 on, delay from release, stock recovery).
7. **Crouched head overlap** rule: `entry_first` (default) vs `head_priority_in_overlap` (Devin Addendum 2 A2-b).
8. **Stamina call on PR #1:** RESOLVED by §movement (kept here only so old references resolve).
9. **Round loop leftovers:** clock-zero = CT win (note a), note (c), loss-bonus reset rule (f3), T eliminated after plant (g3), team-kill reward (g7).
10. ~~Visibility crown sample~~: **CLOSED in CD-r2** (see §visibility).
11. **Surf:** permanent vs event after the first event; ClipVelocity overbounce, the 0.7 steepness threshold and test-ramp angles are PROPOSED.
12. Bots: thresholds in `bot_spec_v0.1.md` are PROPOSED (retreat "outnumbered" radius, flank timing, difficulty start/floor/step); "sixth config" read as a sixth bot mode, not a sixth state.
13. Reconciliation items still open and not covered above: 1 (platforms), 2 (Rust timing wording), 5 (KERNEL_SHA256), 9 (netcode §12 layout), 11 (crosshair review notes), 16 (strafe-gain rounding), 20 (culling, informational), 29 (GoldSrc-Godot §5).
14. **Weapon range:** `WEAPON_RANGE_UNITS = 8192.0` (CS 1.6 range, `weapon_config.gd`, J17) is a PROVISIONAL Game Builder default; Joan may override. *[GB, delegated; CD-r5]*
15. **J13 player penetration:** PROVISIONAL GB default **no player penetration in v1** (a bullet stops at the first player hit). Joan may override; CS 1.6 has penetration, so revisit. *[GB, delegated; CD-r6]*
16. **J14 wallbangs:** PROVISIONAL GB default **world geometry blocks shots, no wallbangs in v1**. Joan may override; CS 1.6 has wallbangs, so revisit. *[GB, delegated; CD-r6]*
17. **J12 `damage_regions` values are placeholders** until the weapons spec; don't tune or balance against them. *[GB, delegated; CD-r6]*
18. **Fire-cycle rounding:** stock 1.6 rounds each shot's cycle **up to whole ticks with no carry-over** (AK ≈ 549 / 600 / 591 RPM at 64 / 100 / 128 tick); our code carries the overshoot over to keep the exact average rate (AK 600 RPM at every tick). Current code stays as is until Joan picks. Not part of the CD-r9 accuracy task. *[GB; CD-r9]*

---

## Changelog
- **CD-r1 (2026-10-17):** first revision. Consolidates Joan's calls through Oct 17 2026 03:22 UTC (stamina final, padding, evidence sizes, armor, surf) and Game Builder's delegated decisions. Superseded markers added to the older docs.
- **CD-r2 (2026-10-17):** §visibility: crown sample defined (head center 66.0 / 30.0 plus crown at the head-box top 72.0 / 36.0, no vertical margin) [GB, delegated, PR #13 review]. OPEN item 10 closed. Branches made before CD-r2 only need to merge `main`.
- **CD-r3 (2026-10-17):** §bots DECIDED by Joan (server-side, same input path, radio as text/sound events) + 7-step build order; five states IDLE/PATROL/ENGAGE/RETREAT/FLANK recorded; `bot_spec_v0.1.md` added; OPEN 12 changed from "needs Joan's OK" to PROPOSED thresholds. Old bot sections marked superseded.
- **CD-r4 (2026-10-17):** §hitbox: `HitboxConfig.NEAR_MISS_LOG_UNITS = 4.0` is the only near-miss value; skeleton `NEAR_MISS_UNITS = 1.0` is legacy, must not be read, fix at the next deliberate SHA change.
- **CD-r5 (2026-10-17):** §snapshots: interp p99 gate reworded to "p99 ≤ 0.25 overall (pooled across all path kinds); per-kind p99 reported, not gating" (always the intent of the split-gate ruling; value unchanged). §bots: "outnumbered" counts the bot itself as support (1v1 is not outnumbered). New **Known issues** section: PR #5 must-fix items (fail closed on non-finite input / unit direction; new 0.5-skeleton golden) blocking P5; P4 (PR #6) must normalize spread direction; `ray_box_ref.py` legacy 1.0 near-miss default applies only to the frozen baseline. OPEN 14 added: `WEAPON_RANGE_UNITS = 8192.0` provisional GB default. [GB, delegated by Joan]
- **CD-r6 (2026-10-17):** Known issue 4: `rewind_policy.gd` 38-56 / `lagcomp_ref.py` let NaN `claimed_view_tick`/`rtt_ms` through (rewind_ticks overflows to INT64_MIN); non-finite claims must fail closed (INPUT_REJECT, CLAIMED_TIME_OUT_OF_WINDOW, clamp to expected tick); P5 (PR #9) blocked until this and Known issue 1 are fixed. Known issue 5: cross-platform golden checks use a 1e-6 tolerance compare (Mac vs Linux differ up to ~1e-7) [GB ruling]. OPEN 15/16: J13 no player penetration and J14 no wallbangs in v1, provisional GB defaults, revisit (CS 1.6 has both). OPEN 17: J12 `damage_regions` placeholders until the weapons spec. [GB, delegated by Joan]
- **CD-r7 (2026-10-17):** Known issue 2 label fixed: the spread-direction normalize rule applies to P5 hit registration (PR #9), not PR #6 (P4 lag-comp); PR #9 already normalizes. Known issue 6: P6 exporter (`fpev_jsonl.gd:96-97`, `fpev_ref.py:589-590`) must decode view angles via `InputCommand.dequantize_*` + `FrameAdapter` and fix the `match_small` golden; P6 (PR #12) blocked until done; non-blocking u8 range refusal, `slot_count` cap 16, `format_version` + skeleton SHA checks. §net-anticheat: `CMD_WINDOW = 64`, `CMD_RESYNC_TICKS = 128` adopted from PR #15; budget note now "enforced in PR #15 (1 per tick, burst 8)"; resync after outage must be bounded (`fake_server.gd:145`). [GB, delegated by Joan]
- **CD-r8 (2026-10-17):** OPEN 5 closed: new §crosshair, latency stated honestly as 2–3 ticks, not 0 ms [GB, delegated]. §hitbox: `ray_box` unit-direction check is strict (squared length within 1e-9), so callers must normalize in 64-bit (a 32-bit `Vector3` normalize can miss); the frozen zero-padding baseline golden may keep the legacy 1.0 near-miss limit. Known issues 1 and 3 closed (PR #21, `8e5db93`), 4 closed (PR #9, `c9867fe`), 6 closed (PR #12, `ba3165b`); issues 2 and 5 stay as standing rules. [GB, delegated by Joan]
- **CD-r9 (2026-10-17):** §recoil: **Joan's call: stock CS 1.6 stepped accuracy** (integer-division accuracy: AK 0.35 after shots 1–5, cap 1.25 from shot 6; M4A1 0.30 after shots 1–6, cap 1.00 from shot 7) replaces ReGameDLL's smoothed float cubic; reason: documented stock behavior, harder for cheaters. Shot-counter recovery set to stock defaults (release cap 15 on, delay from release, first drop strictly after 0.4 s, one decrement per tick) [GB, delegated, applying the stock call]; OPEN 6 closed. OPEN 18 added: fire-cycle rounding (stock whole-tick vs our carry-over), not decided. Devin task: `specs/tasks/DEVIN_STOCK_ACCURACY.md`. Smooth-cubic wording in `goldsrc_recoil_spread.md` marked superseded.
