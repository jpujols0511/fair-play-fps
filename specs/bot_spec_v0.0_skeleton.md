# Bot spec v0.0 — skeleton only

> SUPERSEDED by CURRENT_DECISIONS.md CD-r3 §bots (filled into `specs/bot_spec_v0.1.md`)

*Game Builder, October 17 2026. Public as of Oct 19 2026 (CD-r9). Headings and TODOs — not a buildable spec yet.*
*Owner of this skeleton: Game Builder. Implementation owner: TBD (not Devin Phase 6; not blocked on Rust evidence).*

**Status:** skeleton. Fill sections when Joan asks. All gameplay math in **floats**. Bots are **server-side only**.

---

## 1. Purpose
TODO: Practice and fill bots for empty slots / offline practice / demo recordings.
- TODO: Ranked / matchmaking exclusion rules
- TODO: Whether bots appear in public server browser games
- TODO: Max bots per team / per server

## 2. Server-side only
TODO: Bots never run on the client. No bot AI DLL on the player PC.
- TODO: Client only sees them as ordinary remote players in snapshots
- TODO: No bot-specific HUD unless Joan wants a practice toggle

## 3. Same input-command path as players
TODO: Bots produce the same `InputCmd` / command stream the server already accepts from humans.
- TODO: Same fields: buttons, wish dir, view angles, `cmd_seq`, claimed time
- TODO: Same rejection / evidence rules when a command is illegal
- TODO: No backdoor that sets position or ammo directly

## 4. Movement via `movement.gd`
TODO: Every bot step calls the same pure `movement.gd` `step(state, cmd)` humans use.
- TODO: No CharacterBody3D, no separate nav-agent physics for the body
- TODO: Parity with S2 still gates bot movement weirdness
- TODO: Crouch / jump / ladder once those land in movement

## 5. Aim model
TODO: How bots pick view angles each tick (not hitscan cheats).
- TODO: Reaction delay distribution (floats, ms)
- TODO: Tracking vs flick vs spray control
- TODO: Recoil compensation skill by difficulty (uses Devin’s recoil.gd outputs, does not invent spread)
- TODO: Never reads enemy positions the visibility system would not send a human

## 6. Nav
TODO: How bots path through the map.
- TODO: Waypoint graph vs navmesh vs scripted routes for v0
- TODO: Cost of recomputing path at 128 tick (budget)
- TODO: Jump / crouch / drop links
- TODO: Bomb-site and buy-zone awareness (ties to round loop)

## 7. Difficulty
TODO: Named tiers (e.g. easy / normal / hard / expert) with numeric knobs.
- TODO: Aim error, reaction, eco sense, utility use — all floats
- TODO: Whether difficulty can change mid-match
- TODO: Practice-mode overrides

## 8. Anti-cheat note (hard rule)
**Bots never get hidden info beyond what a player would be sent.**
- TODO: Same PVS / visibility masks as a human on that team
- TODO: No wallhack-by-AI: aim model only uses snapshot-visible enemies (or sound-only cues the human would get)
- TODO: Bot actions still flow through hitreg / evidence on the server so demos stay honest
- TODO: Offline practice may relax this later — **DECISION FOR JOAN**; default = same rules as online

## 9. Out of scope for v0.0
> SUPERSEDED by CURRENT_DECISIONS.md CD-r3 §bots (radio/team calls are now in scope as text/sound events)
TODO: Voice lines, buy AI personality, team strat calls, learning / ML aim.

## 10. Done when (later)
- [ ] Every TODO above replaced with numbers or explicit “cut from v1”
- [ ] Joan signs off
- [ ] Implementation handoff written (owner named)
