# Crosshair spec v0.1

*Dictated by Joan, October 17, 2026. Written up by Game Builder. Public as of Oct 19 2026 (CD-r9).*

Sections 1–5 are Joan's spec, cleaned of transcription errors only. The review notes after them are **proposals, Joan to approve**. They don't change Sections 1–5.

---

## Section 1 — Philosophy

The crosshair is a **server-state mirror, not a client decoration**. It shows spread, kick and inaccuracy as the server computes them, never as the client predicts them. That means when your predicted position gets corrected, the crosshair doesn't lie to you about accuracy you don't have.

## Section 2 — Data flow

Each snapshot carries your own player's:
1. **accuracy value**,
2. **current punch angle**,
3. **movement state**: standing, running, crouching or air.

The client reads those three and renders the crosshair. **No local computation of spread.**

## Section 3 — Rendering

- The base crosshair is a simple **plus or dot**.
- **Size** scales with the accuracy value.
- **Punch angle** offsets the center.
- **Movement state** switches the color: **green** standing, **yellow** running, **red** air.
- Only those three states (colors) for v1.

## Section 4 — Anti-cheat tie-in

Because the crosshair only reflects server data, a silent-aim cheat that snaps your view without the server knowing shows a mismatch: your crosshair stays tight while your aim flick is inhuman. That gap is logged as evidence.

## Section 5 — Implementation

- One GDScript file, `crosshair.gd`: pure rendering from snapshot fields.
- No physics, no input reading.
- It subscribes to the NetClient snapshot stream like any other HUD element.
- Game Builder builds it in parallel with the prediction loop, since it doesn't depend on movement parity.

---

## Review notes (Game Builder, proposed, Joan to approve)

Checked against `specs/goldsrc_recoil_spread.md`, `specs/netcode_design.md`, `specs/prediction_loop_scope.md` and `specs/evidence_logging_spec.md`. Each note says what I checked and what I propose.

### (a) Latency: the crosshair shows the past

> SUPERSEDED by CURRENT_DECISIONS.md CD-r1 §OPEN (item 5, crosshair latency line)
>
> SUPERSEDED by CURRENT_DECISIONS.md CD-r8 §crosshair (latency stated as 2–3 ticks, not 0 ms)

**Checked:** netcode D2 (128 tick, 7.8125 ms), D4 (snapshot every 2nd tick, 64/sec), D8 and Section 9 (interpolation delay 2 snapshot intervals = 31.25 ms), scope Section 2.6 (40 ms each way at 80 ms ping).

A server-only crosshair can only change after a full round trip. At 80 ms ping:

| Step | Delay |
|---|---|
| Your command travels to the server | 40 ms |
| Waits for the next server tick | 0–7.8 ms |
| Waits for the next snapshot (every 2nd tick) | 0–7.8 ms |
| Snapshot travels back | 40 ms |
| Drawn on the next frame (240 FPS) | 0–4.2 ms |
| **Total if the HUD reads your own fields as soon as a snapshot lands** | **80–100 ms, about 90 ms typical** |
| Extra if the HUD reads through the 2-snapshot interpolation buffer | +31.25 ms → **about 120 ms** |
| A lost snapshot (2% of the time) | +15.6 ms that time |

What you'll see:
- **Bloom shows up about 90 ms after you start moving or fire.**
- **It stays wide about 90 ms after you stop.** Releasing W at 250 u/s already takes about 145 ms of friction to drop under the 140 u/s "running" line (recoil spec Section 3; friction 4, `ln(250/140)/4` = 0.145 s). That part is real. The netcode adds about 90 ms on top, so the crosshair turns tight about 235 ms after you let go.
- **Spraying, the kick is about one shot behind.** AK shots are 95.5 ms apart. The kick drawn when shot N fires is roughly the kick from shot N−1.

**Proposal:**
- The HUD reads **your own player's fields straight from the newest snapshot**, never through the interpolation buffer. D8 already limits interpolation to other players. This saves about 31 ms.
- This lag is **visual only**. It doesn't violate S5. S5 is about movement: the player visual answering the key on the same tick. Movement prediction is untouched.
- Re-check feel at 0, 40, 80 and 150 ms in the demo before locking it. If 80 ms feels too laggy, the fallback is a v0.2 decision for Joan (see (h)).

### (b) Crouch has no color

Section 2 has four movement states and Section 3 has three colors.

**Proposal:** **crouch = green, the same as standing.** It matches the recoil spec: for rifles, crouched spread is the same as standing (Section 3 table, "Crouch gives no extra rifle spread bonus in 1.6"). Crouch only gets less kick, and the punch offset already shows that. Walking (shift, at or under 140 u/s) also counts as standing, so it's green too.

Server rule for the state, in the recoil spec's order: **air → running (over 140 u/s) → crouched → standing.**

### (c) The anti-cheat section: what silent aim actually leaves behind

**The problem with Section 4 as written:** the crosshair is drawn on the player's own PC, and a cheater controls that PC. The client never sends the server what it drew, and anything it did send could be faked. A cheat can also just hide or redraw the crosshair. So the client's crosshair **can't be evidence**. Section 4's idea is right, but the evidence has to come from the server.

**Why the server can do it:** the server already gets your view angles in every command, 128 times a second (netcode D3; 16-bit angles per Section 4). It also computes your spread and kick itself (recoil spec Section 7.3). So the server already holds both halves of the "tight crosshair, inhuman flick" gap.

**What silent aim actually leaves behind:**
- Silent aim changes the angles in the command **only on the tick you fire**. Your own screen never moves.
- So the server sees the view **jump toward the target on exactly the fire tick, then jump back 1–3 ticks later**, to where your mouse really was. There's no build-up before the jump and no settling after it.
- A real flick looks different. Speed builds over several ticks, slows down, often overshoots and corrects, and doesn't reverse right after the shot.
- Logging the server's **spread at fire time** next to that gives the reviewer the server-side version of Section 4: a tight-spread shot right at the end of a movement no hand makes.

**Measurement (server-side, from the angles in received commands):**
- For each tick t: the view direction comes from the quantized pitch and yaw (yaw wraps at 360°).
- δ(t) = angle between the directions at t−1 and t, in degrees. Angular velocity ω(t) = δ(t) × 128 (°/s). Angular acceleration α(t) = (ω(t) − ω(t−1)) × 128 (°/s²).
- Window: the **16 ticks (125 ms) before the shot**, plus **3 ticks after** to see the snap-back.
- Noise floor from 16-bit angles: 0.0055° per step → 0.70 °/s velocity and 90 °/s² acceleration. That's well below anything we'd flag.

**Proposed addition to `evidence_logging_spec.md`: record type 6, AIM_KIN** (proposal only. That file isn't edited until Joan approves. Type 6, because a separate proposed addendum, REWIND_DECISION, is taking type 5.)

Written for every shot that already writes a SHOT record (hit or near miss), at fire tick + 3 (it needs the 3 ticks after). `tick` in the header = the fire tick.

| Field | Type | Notes |
|---|---|---|
| shooter_slot | u8 | |
| window_ticks | u8 | 16 |
| shot_index | u16 | same as the SHOT record, links the two |
| move_state | u8 | 0 stand, 1 crouch, 2 air, 3 run (see (d)) |
| reserved | u8 | 0 |
| spread_at_fire | f32 | the server's spread for this shot (same number as the snapshot accuracy value) |
| peak_ang_vel_dps | f32 | max ω in the window (°/s) |
| peak_ang_accel_dps2 | f32 | max α in the window (°/s²) |
| fire_tick_delta_deg | f32 | δ on the fire tick |
| snapback_deg | f32 | largest move back toward the pre-fire view within 3 ticks after |
| snapback_cos | f32 | cosine between the fire-tick move and the move back (−1 = straight back) |
| pre_fire_speed_dps | f32 | mean ω over the 4 ticks before the fire tick |
| settle_ticks | u8 | ticks from peak ω until ω fell under 10% of the peak (255 = never settled) |
| reserved2 | u8 | 0 |
| crc32 | u32 | same rule as the other records |

Body: 40 bytes. **Record: 48 bytes.** About 2,500 records per match → about 120 KB, so the match total stays around 1.5 MB.

Flags (bits), placeholders to tune from real data, like Section 5.4 of the evidence spec:
- 0 `SNAPBACK`: fire_tick_delta ≥ 3.0°, snapback ≥ 70% of it, snapback_cos ≤ −0.8, and pre_fire_speed under 10% of the fire-tick speed.
- 1 `FLICK_STOP_AT_FIRE`: peak_ang_accel ≥ 200,000 °/s² and settle_ticks ≤ 1, ending on the fire tick.

**Same rules as the rest of the evidence spec:** the server writes it, the client never sees it. **Review-only, never auto-ban.** The offline analyzer adds an `aim_kinematics` list to `review/<match_id>.flags.json`, and a player only reaches `NEEDS_HUMAN_REVIEW` after several flagged shots across different rounds (proposed: 3). `auto_action` stays `"NONE"`. Pro flicks are fast, so speed alone never flags. The snap-back shape is the signal.

**Proposed rewording of Section 4** (for Joan): "The crosshair shows only server data. The evidence comes from the server too: it already has every view angle you send and the spread it computed. Silent aim leaves a view jump on the fire tick that snaps back within a few ticks, with no build-up. The server logs that shape and the spread at fire time for human review."

### (d) Snapshot fields: types and quantization

Only sent to **you** (and spectators of you, on the spectator delay). Never to enemies.

| Field | Wire type | Meaning and scale | Range | Step |
|---|---|---|---|---|
| `accuracy` | u16 | the **spread the server would give your next shot** (sideways units per 1 forward, recoil spec Section 1). value × 2/65535 | 0.0–2.0 | 0.0000305 |
| `punch_pitch`, `punch_yaw` | 2 × i16 | kick in degrees, same 16-bit angle encoding as view angles (netcode Section 4). value × 360/65536. Pitch **positive = up** | ±180° | 0.0055° |
| `move_state` | 2 bits (u8 in debug/JSON) | 0 stand, 1 crouch, 2 air, 3 run | 0–3 | — |

About 7 bytes before delta compression, often 0 bytes when nothing changed (D5).

Notes:
- **`accuracy` is the finished spread, not the raw per-weapon accuracy number.** Spread depends on weapon, movement state and the accuracy number (recoil spec Section 3), and the Deagle's accuracy runs backwards (higher = better). If the client got the raw number it would have to compute spread itself, and Section 2 forbids that. Sending the finished spread keeps Section 2 true. Largest real value: AWP unscoped in air, 0.93. The range of 2.0 leaves headroom. The standing AK first shot (0.0055) is about 180 steps, so the wire rounding is invisible.
- The `move_state` order puts 0–2 the same as `target_stance` in the evidence SHOT record (0 stand, 1 crouch, 2 air), so the tools share one table. Run is 3.
- The client dequantizes to floats. All rendering math is in floats.

### (e) From accuracy to pixels

The spread is "sideways per 1 forward", and the random offset per axis can reach ±1 × spread (two draws of ±0.5 added, recoil spec Section 1). So the crosshair gap is drawn at the **largest possible miss**:

`k = (screen_height / 2) / tan(vertical_fov / 2)` (pixels per unit of tan)
`gap_px = max(min_gap_px, accuracy × k)`
`punch offset: x_px = tan(punch_yaw) × k, y_px = −tan(punch_pitch) × k` (up kick moves the crosshair up; screen y grows downward)

Godot's camera FOV is vertical (keep height). Proposed default: **vertical FOV 73.74°**, which is 90° horizontal on a 4:3 screen, the classic CS view, and about 106° horizontal on 16:9. At 1080p, k = 720. At 1440p, k = 960.

| Case (AK, 1080p) | Spread | Gap |
|---|---|---|
| Standing, first shot | 0.0055 | 4.0 px |
| Standing, spread maxed | 0.0344 | 24.8 px |
| Running | 0.054 | 38.9 px |
| Air, first shot | 0.120 | 86.4 px |
| Air, maxed | 0.540 | 389 px → clamped |
| Kick 4.61° (AK peak) | — | 58 px up |

- Clamp: the gap stops at 25% of screen height (270 px at 1080p), so an air spray doesn't fill the screen.
- Arm length 6 px, thickness 2 px, min gap 2 px, all at 1080p, then multiplied by screen_height / 1080.
- **Camera rule:** if the punch offsets the crosshair, the camera must **not** also tilt by the punch, or it counts twice. Proposal for v0.1: the camera shows the view angles only, and the crosshair shows the punch. GoldSrc tilts the camera instead. That's a feel decision for Joan.

### (f) No NetClient yet: a fake snapshot source

NetClient doesn't exist yet (netcode Section 8 only names it). The prototype uses `fake_snapshot_source.gd`, which has the **same interface** the real NetClient will have for HUD elements:

- `signal snapshot_received(snap: Dictionary)`, with keys `server_tick` (int), `accuracy` (float), `punch_pitch` (float, degrees), `punch_yaw` (float, degrees), `move_state` (int).
- `func get_latest() -> Dictionary`.

The fake source runs every value through the (d) quantization, so the crosshair draws exactly what the wire would carry. It emits at 64/sec with an optional delay (0/40/80/150 ms) to feel note (a). Scripted segments: standing still, running, air, and an AK spray with punch. These are **made-up demo curves, not the recoil sim**. Swapping in the real NetClient later means pointing the crosshair at a different node and nothing else.

### (g) Extra: the shared spread seed

The recoil spec Section 7.3 says "the server computes spread with a shared random seed per shot, so clients can display predicted tracers." If the client knows the seed **before** it fires, a no-spread cheat can aim against the exact random offset and cancel it. **Proposal:** the server picks the seed when it processes the shot and tells the client afterward. Client tracers stay cosmetic. Added to the reconciliation list (item 11).

### (h) Extra: conflict with "we predict recoil view kick"

`netcode_design.md` Pillar 1 lists "your weapon animations/recoil view kick" as **predicted** on the client. This spec says the crosshair shows kick **only from the server**. These don't clash if the camera never shows kick (rule in (e)). They clash if the camera kicks from prediction while the crosshair waits about 90 ms for the server. **Proposal for v0.1:** follow this spec (server-only crosshair, camera without punch) and test the feel. If 90 ms feels bad, the v0.2 option is to draw the predicted value right away and correct it to the server's when the snapshot lands. Joan's call, after the demo. Added to the reconciliation list (item 11).
