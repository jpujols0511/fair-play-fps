# Round loop spec v0.1

*Joan's dictation, October 17 2026, recorded by Game Builder. Not public yet.*
*Status: **Joan's spec** (Sections 1–5 are his words, kept faithful). Review notes at the end are Game Builder's and are **proposals** until Joan decides.*

**Supersedes `specs/round_loop_brief_v0.1.md` wherever they differ** (timers, plant/defuse times, state names, economy numbers, owner). The brief stays as history. Where this spec is silent, the brief's structure (server-authoritative, float timers, config switches) still applies.

**House rules:** floats everywhere (no int literals in timer or money math), GDScript first, server-authoritative.

---

## 1. Phases

- **Freeze time: 15 s** after buy. *(Joan: "Freeze time fifteen seconds after buy.")*
- Then **free movement** until the bomb plants or the round clock hits **1:40 (100 s)**.
- **Bomb plant: 3.2 s.** **Defuse: 10 s with a kit, 15 s without.**
- The round ends on: **elimination, bomb explosion, defuse, or clock zero.**
- **T wins** on explosion or elimination. **CT wins** on defuse or elimination.

Phase enum (implementation, Section 5): `WARMUP`, `FREEZE`, `LIVE`, `PLANTED`, `ROUND_END`.

## 2. Economy

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §round (armor)

| Item | Amount |
|---|---|
| Starting cash (both sides) | $800 |
| Kill reward | $300 |
| Bomb plant | $200 to the planter, plus $300 to the team |
| Bomb defuse | $300 to the defuser, plus $600 split |
| Loss bonus (consecutive losses) | 1st $1400, 2nd $1900, 3rd $2400, 4th $2900, 5th and beyond $3400 |
| Win bonus | $3000 |
| Armor | $455, helmet included |

## 3. Weapon buy menu

Categories: **pistols, heavies, SMGs, rifles, shotguns, snipers, grenades, armor, defuse kit.**
Each item maps to a **price** and a **team restriction**. **AK is T only. M4 is CT only.**

## 4. Anti-cheat hooks inside the loop

- **Buy commands are server-validated against current cash.** The client can't grant itself money.
- **Plant and defuse are server-timed actions**, not client-reported.
- **Round state transitions are server-only events.**

## 5. Implementation

- One GDScript file, **`round_controller.gd`**, owning a **phase enum** and a **tick-driven state machine**.
- The **buy menu is a UI layer** that sends purchase requests and **never applies them locally**.
- **Timers run on the server tick** and are **broadcast as snapshot fields**.
- **Build order:** (1) phase enum and transitions, (2) economy math, (3) buy menu, (4) bomb mechanics.
- **Owner: Game Builder.**

---

## Review notes (Game Builder, proposals — Joan to decide)

**(a) Clock zero with no plant = CT win.** Implied by Section 1 (T only wins on explosion or elimination) but not stated. Implemented that way; confirm.

**(b) Bomb timer after plant is not given. DECISION FOR JOAN.** CS values: 35 s (1.6 `mp_c4timer` common competitive setting), 40 s (CS:GO/CS2), 45 s (1.6 default). **Proposed default: 40.0 s**, switch `BOMB_TIMER_S`.

**(c) "$600 split": across the team or the remaining players?** Proposed default: split evenly across **every CT on the team** (alive or dead, including the defuser), so 5 CTs → $120 each. Switch `DEFUSE_TEAM_SPLIT_MODE` = `"team"` | `"alive"`. Plant's "$300 to the team" is read as **$300 to each T** (including the planter, so the planter gets $500 total). Switch `PLANT_TEAM_BONUS_MODE` = `"each"` | `"split"`. Both DECISION FOR JOAN.

**(d) Armor $455 with helmet is unusual.** CS: kevlar $650, kevlar + helmet $1000. Implemented as dictated ($455, helmet included); confirm it isn't meant as a different number.

**(e) Weapon prices are missing.** PROPOSED table below (CS 1.6 prices, team restrictions from 1.6 except AK/M4 which Joan locked). Nothing here is approved.

| Category | Item | PROPOSED price | Team |
|---|---|---|---|
| Pistols | Glock-18 | 400 | both (T default) |
| Pistols | USP | 500 | both (CT default) |
| Pistols | P228 | 600 | both |
| Pistols | Desert Eagle | 650 | both |
| Pistols | Dual Elites | 800 | T |
| Pistols | Five-SeveN | 750 | CT |
| Shotguns | M3 | 1700 | both |
| Shotguns | XM1014 | 3000 | both |
| SMGs | MAC-10 | 1400 | T |
| SMGs | TMP | 1250 | CT |
| SMGs | MP5 | 1500 | both |
| SMGs | UMP45 | 1700 | both |
| SMGs | P90 | 2350 | both |
| Rifles | Galil | 2000 | T |
| Rifles | FAMAS | 2250 | CT |
| Rifles | AK-47 | 2500 | **T (locked)** |
| Rifles | M4A1 | 3100 | **CT (locked)** |
| Rifles | SG 552 | 3500 | T |
| Rifles | AUG | 3500 | CT |
| Snipers | Scout | 2750 | both |
| Snipers | AWP | 4750 | both |
| Snipers | G3SG1 | 5000 | T |
| Snipers | SG 550 | 4200 | CT |
| Heavies | M249 | 5750 | both |
| Grenades | HE grenade | 300 | both |
| Grenades | Flashbang | 200 | both |
| Grenades | Smoke | 300 | both |
| Armor | Kevlar + helmet | **455 (Joan)** | both |
| Defuse kit | Defuse kit | 200 | CT |

Grenade carry limits (1.6: 1 HE, 2 flash, 1 smoke) aren't in the spec. PROPOSED to copy 1.6.

**(f) DECISIONS FOR JOAN:**
1. **MR12 vs MR15** (first to 13 vs first to 16). Config `MAX_ROUNDS_PER_HALF`, proposed 12.
2. **Max cash cap.** CS: $16000. Proposed `MAX_CASH = 16000.0`.
3. **Loss-bonus reset rule.** 1.6-style: a win resets the loss count to 0. CS:GO-style: a win lowers it by 1. Proposed `"reset"`, switch `LOSS_RESET_MODE`.

**(g) Other gaps found while building (proposed defaults, all switches):**
1. "Freeze 15 s **after buy**": read as "the buy window opens at round start and freeze runs 15 s from round start; buying is allowed during freeze." Buy window into LIVE (CS `mp_buytime`): proposed **0.0 s** (freeze only), switch `BUY_WINDOW_INTO_LIVE_S`.
2. Movement during freeze: "then free movement" implies **no movement during freeze** (CS behavior). Proposed.
3. **T eliminated after the plant:** Section 1 says CT wins on elimination. CS rule: once planted, CTs must still defuse. Proposed default **CS rule** (round continues until defuse or explosion), switch `T_ELIM_AFTER_PLANT_ENDS_ROUND` (default false). DECISION FOR JOAN.
4. Interrupted plant or defuse restarts from 0 (CS). The kit/no-kit time is fixed when the defuse starts.
5. A plant still in progress at clock zero loses (CS): CT wins on time.
6. Same-tick ties: defuse completing on the explosion tick → **defuse wins**; both teams eliminated on the same tick → CT wins in LIVE, T wins in PLANTED.
7. Team-kill reward: proposed **$0** (CS 1.6 fines $3300). DECISION FOR JOAN later.
8. Round-end display: proposed **5.0 s**, then the next round's FREEZE. Warmup: ends on a server `start_match` call.
9. Timer resolution: 128 Hz, `1.0 / 128.0` per tick (exact in binary). A duration ends on the first tick at or after it, so 3.2 s plant completes on tick 410 (3.203125 s); 15.0, 100.0, 10.0 and 15.0 s land exactly.

---

## Joan decisions (Oct 17 2026): round defaults LOCKED for now

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §round (armor)

Joan: "Yes let's keep it that way for now between those prices until we adapt source or cz or csgo cs2 etc."

| Setting | Locked value | Config |
|---|---|---|
| Bomb timer after plant | **40.0 s** | `BOMB_TIMER_S = 40.0` |
| Match length | **MR12** (first to 13) | `MAX_ROUNDS_PER_HALF = 12.0` |
| Cash cap | **$16,000** | `MAX_CASH = 16000.0` |
| Weapon prices + team restrictions | **CS 1.6 table in review note (e)** (AK T-only, M4 CT-only) | price table |
| Armor | **$455, helmet included** (Joan's number, on purpose) | `ARMOR_HELMET_PRICE = 455.0` |

- These are **placeholders**, not final balance. They get revisited when the game is adapted toward Source / CZ / CS:GO / CS2 numbers.
- Review notes (b), (d), (e) and (f)1–2 are therefore **closed as locked**. Still open: (a), (c), (f)3, (g)3, (g)7.
- Floats in code (`455.0`, `16000.0`), per the all-agent rule.

## AMENDMENT Oct 17 2026 (Joan, 03:22 UTC): armor corrected, defaults accepted

- **Armor:** Joan's $455 was wrong. Use CS values: **vest (kevlar) $650** and **vest + helmet $1000**. Two buy items: `armor_vest` (`650.0`) and `armor_helmet` (`1000.0`), category armor, both teams. This replaces the "$455, helmet included" lines above (Section 3 table, note (d), the review table and the locked-defaults table) and `ARMOR_HELMET_PRICE = 455.0`, which becomes `ARMOR_VEST_PRICE = 650.0` and `ARMOR_HELMET_PRICE = 1000.0`. Review note (d) is closed.
- **Accepted:** bomb timer **40.0 s**, **MR12**, cash cap **$16,000**.
- Prototype updated on `gamebuilder/round-loop` (`prototypes/round_loop/`: `weapons_table.gd`, `economy.gd`, `round_controller.gd` tracks a `helmet` flag; tests pass on Godot 4.4.1). Floats in code (`650.0`, `1000.0`, `16000.0`).
- Reconciliation item 25.
