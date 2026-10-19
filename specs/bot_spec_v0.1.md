# Bot spec v0.1

*Game Builder, October 17 2026. Not public yet. Fills `specs/bot_spec_v0.0_skeleton.md` (kept as history).*
*Follows: CD-r3. Canonical values live in `specs/CURRENT_DECISIONS.md` §bots; if this file conflicts, CURRENT_DECISIONS wins.*

**Status:** DECIDED by Joan (Oct 17 2026): bots are **server-side**, use the **same input path** as players, and do **radio as text/sound events**. The **7-step build order** below is Joan's dictation. Numbers marked PROPOSED are Game Builder's until Joan or playtests change them. Floats everywhere in math.

---

## 0. Hard rules (apply to every step)
1. **Server-side only.** No bot code runs on a player's PC. Clients see bots as ordinary remote players in snapshots.
2. **Same input path.** A bot produces `InputCmd`s with the same constructor, fields (buttons, view angles quantized with `InputCmd.quantize_yaw/pitch`, `cmd_seq`, claimed time) and the same slot queue as network input (`client_slot.enqueue_local` → `_admit`): same dedupe, queue cap, **1 cmd per tick budget**, rejection and evidence rules. No backdoor that sets position, health or ammo.
3. **Movement through `movement.gd`** `step(state, cmd)` only. No physics bodies, no separate nav physics.
4. **No hidden info (anti-wallhack).** A bot sees **only what visibility culling would send to its slot**: its own full `PlayerState`, teammates (always sent), and enemies present in that slot's culled snapshot (same `sent_mask`, same C9 margin and samples). Sound cues only within the hearing range a human would get. It never reads server internals or unsent enemy positions. This also keeps bots honest against our anti-wallhack: a bot that "knows" an unsent enemy is a bug, and the evidence "aimed at a never-sent enemy" flag (review only) applies to bots too.
5. **Hitreg and evidence** run on bot shots exactly as on human shots (demos stay honest).
6. **Deterministic** for a given seed (seeded RNG per bot), so tests and demos replay.

## 1. Build order (Joan, Oct 17 2026)

### Step 1. Server-side controller: reads snapshots, writes input commands, no special netcode path
- Input: the **decoded snapshot view for its slot** (what a client would get after culling) + its own `PlayerState`. Output: exactly one `InputCmd` per tick via the slot's local enqueue.
- **Overlap:** Claude's mega handoff **Phase 8** ("bot input driver: same input path", `claude/bot-driver`, `server/bots/bot_driver.gd`, `enqueue_local`) already builds the controller/driver half (waypoint driving, same path, 0 rejects, same-path bit-identical proof). **Step 1 = review and merge Claude's P8** once her stack (P6 transport → P7 server tick) lands. The "reads the culled snapshot view" part is the seam for step 2: the driver exposes a per-slot `BotView` (own state + culled entities + teammates) built from the same data the snapshot encoder uses for that slot.

### Step 2. Five-state machine
- **States** (from `hard_mode_design_v0.1.md` §6): **IDLE, PATROL, ENGAGE, RETREAT, FLANK.**
- **Inputs (only from `BotView`):** visible enemies (in the culled view), own ammo (magazine + reserve), own health, teammate positions (always sent).
- **Transitions (PROPOSED thresholds, all switches):**
  - IDLE → PATROL: round goes LIVE (freeze over) or a patrol route is assigned.
  - PATROL → ENGAGE: an enemy is in the view and in line of sight (after the reaction delay, step 7).
  - ENGAGE → RETREAT: health **< 30.0%** (hard mode §6) **or outnumbered** (visible enemies > nearby teammates within `SUPPORT_RADIUS = 512.0`, PROPOSED) **or** magazine empty with no time to reload safely.
  - ENGAGE → FLANK: enemy held in view for `FLANK_AFTER_S = 3.0` (PROPOSED) without a kill and a flank route exists; waits for step 6 coordination.
  - RETREAT → PATROL: health doesn't come back mid-round, so retreat ends once no enemy has been in view for `RETREAT_CLEAR_S = 2.0` (PROPOSED) and the bot has reloaded; it then patrols toward its teammates.
  - FLANK → ENGAGE: enemy re-enters the view from the flank side. FLANK → PATROL: flank route finished with no contact.
  - Any → IDLE: dead, round end, or freeze.
- **"Bots never path through culled space"** (hard mode §6) is read as: the planner never uses the position of an enemy it can't see; routes come from map data (waypoints/visibility table), not from hidden enemy state.
- Pure logic module first (no scene): `state_for(view, memory, cfg) -> state`, tested with constructed views.

### Step 3. Radio as text and sound events, not voice files
- A radio call is a server event `{tick, slot, call_id, team}` sent to that team like chat; the client shows text and may play a short generic sound cue. **No voice files.** Call ids: `ENEMY_SPOTTED`, `NEED_BACKUP`, `FALLING_BACK`, `FLANKING`, `CAPTAIN_DOWN`, `ENEMY_DOWN` (PROPOSED list; the last two are step 4).
- Rate limit per bot (PROPOSED: one call per `RADIO_COOLDOWN_S = 2.0`).

### Step 4. Death-call and kill-call triggers
- **Death call "captain down"** when a bot dies (hard mode §6).
- **Kill call on a confirmed kill** (server-confirmed by hitreg, not by the bot's guess).
- Both go out as step-3 radio events.

### Step 5. Aim Lab mode (sixth config) with random spawn targets
- A separate bot **config/mode** "aim_lab": target bots spawn at **random points** (seeded) and stand/strafe for the player to shoot; they don't use the state machine. Spawn area, target count and lifetime are PROPOSED switches (`AIMLAB_TARGETS = 1.0`, `AIMLAB_LIFETIME_S = 3.0`).
- Same server, same hitreg and evidence path (a practice server is still honest).

### Step 6. Team coordination: a flank waits for a teammate to draw fire
- A FLANK bot holds at the flank start until a teammate is in ENGAGE (the teammate has drawn fire: has an enemy in view or has taken damage within `DRAW_FIRE_WINDOW_S = 1.5`, PROPOSED), then goes. Coordination uses only teammate data (always sent) and radio events. No shared hidden enemy info between bots beyond what each one sees or a radio call would tell a human (e.g. `ENEMY_SPOTTED` carries a rounded position, like a human callout).

### Step 7. Difficulty dials: reaction delay and aim error, casual first, tightening until the player loses
- **Dials:** `REACTION_DELAY_S` (time from an enemy first entering the view to the first aim adjustment) and `AIM_ERROR_DEG` (angular error on the aim target, seeded). Both floats.
- **Start casual** (PROPOSED: 0.45 s reaction, 4.0° error) and **tighten after each round the player wins** (PROPOSED: reaction × 0.9, error × 0.85 per player round win) down to a floor (PROPOSED 0.15 s, 0.5°), **until the player loses**; then hold (or ease one step after two losses in a row, PROPOSED).
- Aim moves the view through normal `InputCmd` angles at human-plausible turn rates (bots must not trip our own AIM_KIN flick detector; if they do, the dials are wrong).
- Recoil compensation uses Devin's `recoil.gd` outputs (never invents spread).

## 2. Out of scope for v0.1
Voice files, buy personality, learned/ML aim, offline relaxation of the no-hidden-info rule (DECISION FOR JOAN; default = same rules as online).

## 3. Open (see CURRENT_DECISIONS OPEN)
- "Sixth config" for Aim Lab is read as a sixth bot **mode/config** next to the five states, not a sixth state.
- All PROPOSED thresholds above.
- Ranked/matchmaking exclusion, bots in public browser games, max bots per team (skeleton §1).

## 4. Done when
- Step 1: Claude P8 merged (tests: same path, 0 rejects, determinism).
- Steps 2–7: each with headless tests (constructed views; never reads unsent enemies; deterministic per seed; commands pass the same server validation), floats only, on Godot 4.4.1.
