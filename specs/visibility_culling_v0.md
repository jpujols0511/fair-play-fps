# Visibility culling v0 (PROPOSED)

*Written by Claude, Phase 5 of the build plan. PROPOSED; Joan and Game Builder have not approved it. If Game Builder later adds `specs/visibility_culling_v0.1.md`, that file wins where it differs and the differences go in the progress log. Public as of Oct 19 2026 (CD-r9).*
Context: `specs/netcode_design.md` Section 6, `specs/evidence_logging_spec.md` Sections 2.4 and 5.3 to 5.5, `specs/hitbox_spec_v0.2.md` Section 2 and the approved half-height crouch note.

## Summary (plain words)
The server only sends you an enemy if you could plausibly see them. For every viewer and every enemy it draws straight lines from the viewer's eyes to a handful of points on the enemy's body; if at least one line is not blocked by a wall or box, the enemy is sent. Otherwise the enemy is simply **not in the bytes the viewer's PC receives**, so a wallhack has nothing to show. To avoid enemies popping into view late, the test also uses where the viewer and the enemy will be a moment from now, and tolerates 8 units of sideways slack. Teammates are always sent. The server also keeps a short memory of exactly who was sent to whom each tick, for the anti-cheat analyzer.

## v0 scope
Fine stage only (line of sight against box occluders). The precomputed cell/PVS stage of netcode Section 6.1 comes with real maps. Dead viewers and spectators are out of scope for v0 (nothing extra is sent to them; noted). Sound-only entries (Section 6.4) are later: `sound_only_mask` is always 0.

## Rules (all PROPOSED unless it says netcode / hitbox)
1. **Occluders:** the world boxes `[min_x, min_z, max_x, max_z, top, bottom]` (game frame, y up; `bottom` defaults to 0.0). The ray test is the slab method in float64, **strict**: a segment is blocked only if it passes through the open interior of a box. A segment that only touches a face or an edge counts as **clear** (so ties choose "send"). It is world occlusion only; it shares no code with Devin's hitbox ray-vs-box.
2. **Target sample points** (netcode 6.2: head, chest, feet, both shoulders), heights above the target's feet from hitbox v0.2:
   - standing: head center **66.0**, **crown 72.0** (top of the head box, CD-r2), chest center **54.5**, feet **2.0**, shoulders **58.0** at **+-12.0** sideways;
   - crouched (0.5): head center **30.0**, **crown 36.0**, chest center **27.25**, feet **1.0**, shoulders **29.0** at **+-12.0**.
   - With a duck fraction `f` (0.0 standing .. 1.0 crouched) every height is blended: `stand + (crouch - stand) * f`.
   Airborne uses the same heights as standing or crouched, at the airborne feet height. "Sideways" is horizontal and perpendicular to the line from the viewer's eye to the target.
3. **Viewer eye:** feet + `eye_height(state)` (64.0 standing, 32.0 ducked, the linear value in between), at the current position **and** at the look-ahead position `pos + vel x VIS_LOOKAHEAD_S`.
4. **Look-ahead and margin (C9):** each target point is tested at the target's current position and at its look-ahead position (`pos + vel x VIS_LOOKAHEAD_S`), and each is also shifted **+-8.0** units sideways (`VIS_LATERAL_MARGIN`). **No vertical margin** (`VIS_VERTICAL_MARGIN = 0.0`), and this matters: a vertical margin would let a crouched enemy's head "peek" over 40-unit cover that hides it, which is exactly what the half-height crouch is meant to stop. `VIS_LOOKAHEAD_S = rtt / 2 + one snapshot interval` (the server's measured round trip; in the fake net at 80 ms: 0.040 + 2 ticks of 1/128 = 0.055625 s).
5. **Rule:** enemy E is sent to viewer V if **any** ray from any eye candidate (2) to any target point candidate (2 positions x 6 points x 3 lateral shifts = 36) is clear: at most **72 rays per pair**. Ray order: `((eye * 2 + target_position) * 6 + point) * 3 + shift` with points `head, crown, chest, feet, shoulder L, shoulder R` with shifts `[0, +8, -8]`; the first clear one is recorded. Teammates and the viewer's own slot: always sent.
6. **Wiring:** runs on snapshot ticks only (every 2nd tick), before the snapshot is built. A culled enemy is simply **not in the entity list**; if it was in the baseline it gets the REMOVED bit (snapshot format v0.1), so it disappears from the client's interpolation buffer the same tick.
7. **Never-sent hook (seam D4, for Devin's hit registration and analyzer):** per viewer a ring of `sent_mask` for the last `SENT_MASK_HISTORY_TICKS = 640` ticks (C12). `sent_mask_for(viewer, tick)` returns the mask in force at that tick (the mask of the last snapshot tick at or before it), or **-1** outside the history. Bit n = slot n was sent as a full entity (u16). `sound_only_mask_for` always returns 0 in v0.
8. **Evidence (seam D5), in memory only:** `vis_change(tick, viewer, sent_mask, sound_only_mask, keyframe)` when a viewer's mask changes, plus a keyframe for every viewer at tick 0 and every **1,280 ticks (10 s)**, and a round-start hook. **No file is written**: the `.fpev` writer is the Rust layer's job (handoff 0.1 rule 5). Field names match `evidence_logging_spec.md` Section 2.4.

## Switches (DECISION FOR JOAN, `scripts/net/net_config.gd`)
| ID | Switch | Default (proposal) | Alternatives |
|---|---|---|---|
| C9 | `VIS_LATERAL_MARGIN`, `VIS_VERTICAL_MARGIN`, look-ahead = rtt / 2 + 1 snapshot interval | 8.0, 0.0 | tune from playtest |
| C12 | `SENT_MASK_HISTORY_TICKS` | 640 (5 s at 128) | none |

## Reference and tests
`tools/los_ref.py`: independent Python float64 implementation of rules 1 to 5 (seed 7501, 5,000 random configurations incl. grazing and corner cases, `los_cases.json.gz`). `tests/test_visibility.gd` checks the GDScript against it (sent flag and the first clearing ray index must match exactly). `tests/run_wallhack_bait.gd` proves "absent" from the decoded snapshot bytes.

## Known limits of v0
Box occluders only; no doors, glass, smoke; no per-viewer field of view (an enemy behind the viewer is still sent: culling is about walls, not about the camera); a viewer that peeks at 250 u/s is covered by the look-ahead, faster movement (bhop at 340 u/s) is covered at the same rule (the look-ahead scales with speed).
