# Bots prototype (private)

Follows: CD-r3. Spec: `specs/bot_spec_v0.1.md`. Canonical values: `specs/CURRENT_DECISIONS.md` §bots.

**Step 2 (this branch): five-state brain, pure logic.** No scene, no physics bodies, no server access. GDScript, floats in math, seeded RNG.

| File | What |
|---|---|
| `bot_view.gd` | Per-slot view: own full state (health, ammo, position), teammates (always sent), **culled visible enemies only**. `from_server(players, slot, sent_mask)` is the only place that sees unsent players, and it drops them. |
| `bot_brain.gd` | IDLE / PATROL / ENGAGE / RETREAT / FLANK. `think(view, tick)` → `{state, state_name, intent}`; intent = `move_target`, `aim_target`, `aim_err_yaw_deg`, `aim_err_pitch_deg`, `fire`, `reload`, `radio` (text/sound event id). The Phase 8 controller (Claude's bot driver, step 1) turns intents into `InputCmd`s. |
| `tests/test_bot_brain.gd` | Every transition, unsent-enemy blindness, determinism, out-of-ammo and low-health cases, source rules. |

**Transitions** (PROPOSED thresholds, named constants, CURRENT_DECISIONS OPEN 12):
- any → IDLE: dead or round not live. IDLE → PATROL: round live (or straight to ENGAGE/RETREAT if an enemy was already reacted to; low health / empty magazine checked first).
- PATROL → ENGAGE: an enemy in view for `REACTION_DELAY_S` 0.45 (58 ticks at 128); → RETREAT instead if already low health or empty magazine.
- ENGAGE → RETREAT: health < 30% (`RETREAT_HEALTH_FRAC`), outnumbered (visible enemies > support; support = **the bot itself** + live teammates within `SUPPORT_RADIUS` 512.0, so a 1v1 isn't outnumbered), or empty magazine.
- ENGAGE → FLANK: enemy in view for `FLANK_AFTER_S` 3.0 **since entering ENGAGE** and a flank route exists (no FLANK/ENGAGE bounce). ENGAGE → PATROL: no contact for `LOSE_CONTACT_S` 2.0 (PROPOSED, not in the spec text).
- RETREAT → PATROL: no enemy in view for `RETREAT_CLEAR_S` 2.0 **and fully reloaded** (magazine full, or reserve empty with rounds in the magazine; no ammo at all = stays RETREAT).
- FLANK: moves to route point 0 (the flank start, behind cover by route design) and **keeps firing** at a visible enemy on the way; waits **at point 0** (never in the open) until the step 6 hook says go. FLANK → ENGAGE: an enemy within `FLANK_ENGAGE_RANGE` 1024.0 (PROPOSED) is seen (after the reaction delay) while waiting at the start, or re-seen after contact was lost. FLANK → PATROL: route finished. FLANK → RETREAT: low health or empty magazine.
- **Step 6 hook (stub):** `flank_coordination_hook(view) -> bool` gates leaving the flank start; default returns true.
- **Aim:** chest height blended by the enemy's snapshot duck fraction (`duck`, u8 / 255.0 in the view): 54.5 standing → 27.25 crouched.
- Radio: ENEMY_SPOTTED / NEED_BACKUP / FALLING_BACK / FLANKING on state entry, `RADIO_COOLDOWN_S` 2.0.

**Run (Godot 4.4.1 official):**
```
godot --headless --path prototypes/bots --import
godot --headless --path prototypes/bots --script res://tests/test_bot_brain.gd
```
