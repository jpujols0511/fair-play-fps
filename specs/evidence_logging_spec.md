# Evidence logging spec v0.1 (PROPOSED)

*Written by Game Builder, October 17, 2026. Not public yet.*
*Covers two jobs in one file: (1) the near-miss and hit log, and (2) the "aimed at an enemy the server never sent" flag. It replaces the two separate files the old Game Builder handout planned (`evidence_log_v0.1.md` and `unsent_enemy_flag_v0.1.md`).*

**Status: proposed — Joan to approve.**

Builds on `specs/hitbox_spec_v0.2.md` (Section 5, near miss at 1.0 unit; Section 7, 25-tick rewind) and `specs/netcode_design.md` (Section 5 lag comp, Section 6 culling, Section 7 demos, Section 12.3 evidence logging).

---

## 0. The ground rules

1. **Evidence goes to human review. It never bans anyone automatically.** No flag, score or record in this spec can kick, ban or punish a player alone.
2. **Avoiding false positives comes first.** When in doubt, the analyzer doesn't flag.
3. **The server writes, the client never does.** Clients can't see, change or send any of this.
4. **Append-only and tamper-evident.** Records are only ever added. Checkpoints chain hashes, so any edit or deletion shows up.
5. **Plugins can't touch it.** This is a "zero-touch ledger" (`CS_REFERENCE.md` Section 5).

## 1. Files, one set per match

| File | Written by | When | Format |
|---|---|---|---|
| `matches/<match_id>/evidence.fpev` | game server | live, during the match | binary, Sections 2–3 |
| `matches/<match_id>/server.demo` | game server | live | demo format (netcode Section 7; Devin's research) |
| `matches/<match_id>/evidence.jsonl` | `fpev export` tool | after the match, on request | JSON Lines, Section 4 |
| `review/<match_id>.flags.json` | offline analyzer | after the match | JSON, Section 6 |

Evidence and demo sit side by side and share the `match_id`, so a reviewer can replay exactly what the server saw.

## 2. Binary format: `evidence.fpev`

All numbers are little-endian and packed (no padding between fields). `f32`/`f64` are IEEE-754 floats.

### 2.1 File header

| Field | Type | Notes |
|---|---|---|
| magic | 4 bytes | ASCII `FPEV` |
| format_version | u16 | `1` |
| tick_rate | u16 | 128 (or 64/100) |
| match_id | 16 bytes | UUID v4 |
| start_unix_ms | u64 | server wall clock at match start |
| kernel_sha256 | 32 bytes | `KERNEL_SHA256` (definition in `specs/SPEC_RECONCILIATION.md`, item 5) |
| skeleton_sha256 | 32 bytes | `SKELETON_SHA256` (hitbox v0.2, Section 8) |
| build_id | 20 bytes | git commit (SHA-1) of the server build |
| map_name_len | u8 | then that many UTF-8 bytes of map name |
| slot_count | u8 | up to 16 |
| slots | slot_count × 33 bytes | per slot: `player_ref` (32-byte SHA-256 of the account id plus a per-server secret salt), `team` (u8: 0 = spectator, 1 = A, 2 = B) |

Player accounts never appear in clear. The salt and the mapping back to accounts stay in the server's account database.

### 2.2 Record header (every record)

| Field | Type | Notes |
|---|---|---|
| type | u8 | 1 SHOT, 2 VIS, 3 INPUT_REJECT, 4 CHECKPOINT |
| flags | u8 | per type, below |
| length | u16 | body length in bytes |
| tick | u32 | server tick the record belongs to |

8 bytes total.

### 2.3 SHOT record (type 1): hits and near misses

One record per **(shot, target)** pair where the shot **hit** the target, or passed **within 1.0 unit** of any of the target's boxes (hitbox v0.2 Section 5). A shot that hits one player and grazes another writes two records with the same `shot_index`. Shots that come nowhere near anyone write nothing (the demo still has the raw input).

| Field | Type | Notes |
|---|---|---|
| shooter_slot | u8 | |
| target_slot | u8 | |
| weapon_id | u8 | from the weapons table |
| part | u8 | box id 0–10 (hitbox v0.2 Section 2). For a near miss, the closest box. |
| outcome | u8 | 0 = hit, 1 = near miss |
| target_stance | u8 | 0 stand, 1 crouch, 2 air, 3 crouch-air |
| shot_index | u16 | per-shooter shot counter for the match |
| eye_pos | 3 × f32 | shooter eye, server-side |
| view_pitch_q, view_yaw_q | 2 × u16 | view angles **quantized exactly as on the wire** (16 bits each) |
| spread_x, spread_y | 2 × f32 | spread offsets applied to this shot |
| kick_up, kick_side | 2 × f32 | view kick (degrees) when the shot left |
| rewind_ticks | u8 | 0–25 at 128 tick |
| reserved | u8 | 0 |
| rewind_frac | u16 | fraction between stored ticks, value ÷ 65536 |
| server_time_s | f64 | the target time the server chose |
| client_claimed_time_s | f64 | the time in the client's command |
| closest_dist | f32 | 0.0 for a hit, (0, 1.0] for a near miss |
| ray_point | 3 × f32 | hit point, or the closest point on the shot ray |
| box_point | 3 × f32 | closest point on the box surface |
| target_origin | 3 × f32 | target origin **after rewind** |
| target_yaw | f32 | target yaw after rewind (degrees) |
| crc32 | u32 | CRC-32 of header + body up to here |

Body: 108 bytes. **Record: 116 bytes.**

SHOT flags (bits):
- 0 `REWIND_CLAMPED`: the wanted rewind was over 25 ticks and got clamped (hitbox v0.2 Section 7).
- 1 `CLAIMED_TIME_OUT_OF_WINDOW`: the client's claimed time was more than ±1 tick off from what the server expected (netcode Section 5).
- 2 `THROUGH_WORLD`: the ray crossed world geometry before the target (wallbang).
- 3 `TARGET_NOT_SENT`: at that tick, the target was **not** in the shooter's sent set (Section 2.4). This is an input to Section 5, never a verdict.

### 2.4 VIS record (type 2): the culling decision log

Records which enemies the server sent to each player. Without this, the "never sent" flag can't be checked.

| Field | Type | Notes |
|---|---|---|
| viewer_slot | u8 | |
| reserved | u8 | 0 |
| sent_mask | u16 | bit n = slot n was sent to this viewer as a full entity |
| sound_only_mask | u16 | bit n = slot n reached this viewer only as a rounded sound event (netcode Section 6.4) |
| reserved2 | u16 | 0 |
| crc32 | u32 | |

Body: 12 bytes. **Record: 20 bytes.**

Written only when a viewer's masks **change**, plus a full set (one record per viewer, flag bit 0 `KEYFRAME`) every 10 s and at the start of each round. Teammates are always sent, and their bits are always 1.

### 2.5 INPUT_REJECT record (type 3)

| Field | Type | Notes |
|---|---|---|
| player_slot | u8 | |
| reason | u8 | 1 claimed time out of window, 2 view angle change too large for one tick, 3 input rate off, 4 malformed |
| cmd_seq | u32 | |
| claimed_time_s | f64 | |
| expected_time_s | f64 | |
| crc32 | u32 | |

Body: 26 bytes. **Record: 34 bytes.**

### 2.6 CHECKPOINT record (type 4): tamper evidence

Written every 128 ticks (once a second at 128 tick), and once at the end of the file.

| Field | Type | Notes |
|---|---|---|
| record_count | u32 | records since the last checkpoint |
| chain_sha256 | 32 bytes | SHA-256(previous `chain_sha256` ‖ every byte written since the previous checkpoint). The first one chains from SHA-256 of the file header. |

**Record: 44 bytes.** The final checkpoint's hash is also stored in the match database row, so a swapped file is caught.

## 3. Size per match (estimate)

For a 5v5 match of about 40 minutes (2,400 s):

| Part | Estimate | Size |
|---|---|---|
| SHOT | ~2,500 shots, about 1 record each | ~290 KB |
| VIS changes | 10 viewers × ~2 changes/s × 2,400 s × 20 B | ~960 KB |
| VIS keyframes | 10 viewers × 240 × 20 B | ~48 KB |
| CHECKPOINT | 2,400 × 44 B | ~106 KB |
| INPUT_REJECT | rare | < 10 KB |
| **Total** | | **~1.4 MB uncompressed** (compressed with zstd when the match closes) |

Real numbers come from the first playtests. Update this table then.

## 4. JSON Lines export (for people and scripts)

`fpev export matches/<id>/evidence.fpev > evidence.jsonl` writes one JSON object per record. Angles are converted back to degrees. Example SHOT line (one line in the real file):

```json
{"type":"shot","tick":40211,"shooter":3,"target":7,"weapon":"AK47","part":"head","outcome":"near_miss",
 "stance":"stand","shot_index":118,"eye":[512.0,-230.5,64.0],"view":{"pitch":-1.2304,"yaw":87.4512},
 "spread":[0.0031,-0.0012],"kick":{"up":1.75,"side":0.375},"rewind":{"ticks":11,"frac":0.4375},
 "server_time":314.1484,"client_time":314.1406,"closest_dist":0.62,"ray_point":[518.3,-101.2,70.9],
 "box_point":[518.1,-100.6,70.9],"target_origin":[518.0,-104.0,0.0],"target_yaw":265.0,
 "flags":[]}
```

The export also checks every CRC and the checkpoint chain, and prints `CHAIN OK` or the first broken record.

## 5. The "aimed at an enemy the server never sent" flag

### 5.1 What it means

The server didn't send enemy E to player V, so V's game didn't know where E was. If V still keeps aiming right at E, or tracks E as E moves, V may be getting information some other way (a cheat, a stream, a teammate's screen). Or there may be an innocent reason. That's why this only sends the match to **human review**.

### 5.2 It runs offline, after the match

The analyzer reads `server.demo` (true positions of everyone, every player's raw view angles each tick) and the VIS records. It never runs on the live server's tick path, and it never touches a player's game.

### 5.3 What counts as "aimed at"

For each viewer V, enemy E and tick t where E's bit is **0** in V's `sent_mask`:
- Take V's view direction from the demo's input at tick t.
- Take the direction from V's eye to the nearer of E's head center or chest center (hitbox v0.2 boxes at E's true position).
- θ = the angle between the two, in degrees.

An **aim episode** is when θ ≤ **X** for at least **Y** ms in a row.
A **tracking episode** is an aim episode where E is moving (over 30 u/s) and the correlation between V's yaw rate and the rate of change of E's bearing is at least **C**.
A **shot at unsent** is any SHOT record with flag `TARGET_NOT_SENT`.

### 5.4 Tunable values (placeholders, tune from real data)

| Name | Starting value | Meaning |
|---|---|---|
| X | 2.0° | how close the crosshair must be |
| Y | 250 ms | how long it must stay there |
| C | 0.8 | tracking correlation |
| G | 500 ms | grace period after E was last sent ("just left view") |
| S | 2,000 ms | how long after a sound event from E the aim counts as explained |
| P | 90th percentile | pre-aim spots: places that 10% or more of all players aim at from that map area |
| N | 3 | distinct episodes (different enemies or rounds) per match before a review flag |

### 5.5 Innocent explanations, ruled out before anything counts

An episode is **dropped** if any of these is true:
1. **Just left view:** E was sent to V within the last G ms.
2. **Sound:** E's bit was set in V's `sound_only_mask` within the last S ms, and the rounded sound position is within 2X of the aim.
3. **Pre-aiming common angles:** the aim point is a common pre-aim spot on that map (percentile P, built from all matches on the map).
4. **Teammate info:** a living teammate of V had E sent in the last 3 s. That doesn't drop the episode, but it gets weight 0.25 (callouts are normal).
5. **V is dead, spectating or in a menu.**
6. **E is on V's team.**

### 5.6 What the analyzer outputs: `review/<match_id>.flags.json`

```json
{
  "match_id": "6f1c2b0e-8a43-4d7e-9c1a-2f0b9d3e5a71",
  "analyzer_version": "0.1",
  "params": {"X_deg": 2.0, "Y_ms": 250, "C": 0.8, "G_ms": 500, "S_ms": 2000, "P": 90, "N": 3},
  "evidence_chain_ok": true,
  "players": [
    {
      "slot": 3,
      "player_ref": "9b2e…(64 hex)",
      "weighted_episodes": 4.25,
      "episodes": [
        {"kind": "tracking", "target_slot": 7, "round": 12,
         "start_tick": 40100, "end_tick": 40180, "min_theta_deg": 0.6,
         "dropped_reasons_checked": ["just_left_view","sound","preaim","teammate","dead","same_team"],
         "weight": 1.0}
      ],
      "shots_at_unsent": [{"tick": 40211, "target_slot": 7, "outcome": "near_miss", "through_world": true}],
      "status": "NEEDS_HUMAN_REVIEW"
    }
  ],
  "auto_action": "NONE"
}
```

- `status` can only be `NO_FLAG` or `NEEDS_HUMAN_REVIEW`.
- `auto_action` is always `"NONE"`. Any tool that reads this file must not act on it by itself.
- A player becomes `NEEDS_HUMAN_REVIEW` only when `weighted_episodes ≥ N`, or when there are 2 or more `shots_at_unsent` hits (not near misses) that are not `THROUGH_WORLD`.

### 5.7 What the reviewer does

Replay `server.demo` from V's point of view, with culling re-run, so the reviewer sees only what V's game knew. Check each episode against the sound events and teammate positions. The reviewer decides. Their decision and reason go into the match database, never into the `.fpev` file.

## 6. Using the log to tune box sizes

- Per part and stance, look at where near misses land (`box_point` relative to the box) and how far off they are (`closest_dist`).
- If near misses pile up on one face (for example above the head) much more than on the others, that box may be too small on that side.
- Starting rule: change a size only after **at least 1,000 near misses for that part and stance**, in steps of **0.5 unit or less**, tested on test servers first. Every change bumps `SKELETON_SHA256`.

## 7. Privacy and retention

- The logs hold player references, aim and positions. They stay server-side and are published only with consent.
- **Retention (DECISION FOR JOAN): 90 days**, then deleted, unless the match is under review or appeal.
- Players can ask for their own exported JSON lines.

## 8. Who builds what

- **Devin:** the SHOT record writer inside the hitbox code (`DEVIN_HANDOUT_v2.md` Task 2), first in GDScript as JSON Lines with the same fields, then binary.
- **Game Builder:** the culling design that fills VIS records (`specs/visibility_culling_v0.1.md`, coming).
- **Later (whoever owns the anti-cheat tools):** the `fpev export` tool and the offline analyzer.

## 9. Open questions

- Is a 16-player slot limit enough for every mode (spectators aren't in the masks)?
- Should a real-time "soft" signal exist (for example, to raise the review priority of a live match)? It's not in v0.1. Anything like that is still review-only.

---

## 10. Addendum (Oct 17 2026): REWIND_DECISION record, implementer notes, coverage (PROPOSED)

*Appended by Game Builder. Nothing above was changed. Status: proposed, Joan to approve, like the rest of this file.*

### 10.1 New record type

This adds one value to the `type` list in Section 2.2: **5 = REWIND_DECISION**. Types 1–4 keep their meaning. **Type 6 is reserved for AIM_KIN** (view-angle kinematics around each logged shot, 48-byte record), which is proposed in `specs/crosshair_spec_v0.1.md` review note (c) and `SPEC_RECONCILIATION.md` item 11. It isn't defined in this file until Joan approves it.

### 10.2 REWIND_DECISION record (type 5)

The server writes **one record for every shot command it lag-compensates**, whether the shot hits, near-misses or misses everyone. This also covers shots that hit nobody, so it's the only record that shows the server's rewind choice for every shot. If no enemy is alive, the record is still written with `targets_rewound = 0`. The record header's `tick` is the server tick the shot was processed on ("now").

| Field | Type | Notes |
|---|---|---|
| shooter_slot | u8 | |
| reason | u8 | clamp reason code, table below. 0 = nothing clamped |
| interp_ticks | u8 | the fixed interpolation delay the server used, in ticks (netcode Section 9) |
| targets_rewound | u8 | how many players were moved back for this shot |
| rewind_ticks | u8 | whole part of the final rewind, 0–25 at 128 tick |
| max_rewind_ticks | u8 | the cap in force: 25 at 128, 20 at 100, 12 at 64 (hitbox v0.2 Section 7) |
| rewind_frac | u16 | fractional part of the final rewind, value ÷ 65536 (same encoding as SHOT) |
| shot_index | u16 | the shooter's shot counter, same value as any SHOT records for this shot |
| rewound_mask | u16 | bit n = slot n was rewound |
| cmd_seq | u32 | sequence number of the shooter's input command |
| claimed_view_tick | f64 | the view tick the client claimed in its command (may be fractional) |
| expected_view_tick | f64 | what the server expected: `now − RTT_ticks − interp_ticks`, where `RTT_ticks = rtt_ms × tick_rate ÷ 1000` |
| chosen_view_tick | f64 | the view tick the server actually used, after the ±1-tick rule and the cap |
| wanted_rewind_ticks | f32 | `now − (claimed tick after the ±1 clamp)`, **before** the cap. Can be over 25 or below 0 |
| rtt_ms | f32 | the shooter's measured (smoothed) round-trip time the server used |
| checkpoint_index | u32 | how many CHECKPOINT records come before this record in the file (0 before the first one) |
| chain_prefix | 8 bytes | the first 8 bytes of the most recent `chain_sha256`, or of SHA-256(file header) before the first checkpoint |
| crc32 | u32 | CRC-32 of header + body up to here |

Body: **64 bytes. Record: 72 bytes.** Python `struct` format (little-endian, packed): header `<BBHI` (8 bytes), body `<BBBBBBHHHIdddffI8sI` (64 bytes). Checked with `struct.calcsize`.

The final rewind is `rewind_ticks + rewind_frac ÷ 65536` and is never more than `max_rewind_ticks`. At exactly 25 ticks, `rewind_frac` = 0.

**Header flags for type 5** (the same meaning as the SHOT bits with the same numbers):
- bit 0 `REWIND_CLAMPED`: the wanted rewind was over the cap and got clamped to it.
- bit 1 `CLAIMED_TIME_OUT_OF_WINDOW`: the claimed view tick was more than ±1 tick from `expected_view_tick` and got clamped to the window edge. An INPUT_REJECT record with reason 1 is written for the same `cmd_seq`.
- bit 4 `NEGATIVE_REWIND`: the result pointed into the future and was clamped to 0.
- bit 5 `MISSING_HISTORY`: at least one target didn't have a sample for the chosen tick (just spawned or reconnected). That target is tested at its oldest available sample and isn't counted in `rewound_mask`.

**Reason codes:**

| Code | Meaning |
|---|---|
| 0 | none: the claim was inside ±1 tick and the rewind was within 0…cap |
| 1 | claimed time out of window (clamped to expected ± 1 tick) |
| 2 | over the rewind cap (clamped to `max_rewind_ticks`) |
| 3 | both 1 and 2 |
| 4 | negative rewind (clamped to 0) |
| 5 | 1 and 4 |
| 6 | missing history for at least one target (more detail in flag bit 5) |
| 255 | other / reserved |

When several apply, use the code that names them together (3 or 5). Code 6 is used only when nothing else applies. The flags always carry the full detail.

**Hash-chain link.** `checkpoint_index` and `chain_prefix` tie each decision to its place in the chain. If someone moves, removes or inserts a record, it no longer matches the checkpoint it claims to follow. This adds to the Section 2.6 chain and doesn't replace it. A REWIND_DECISION's bytes are hashed into the next CHECKPOINT the same way as every other record's.

**Size impact** (Section 3 estimate): ~2,500 shots × 72 B ≈ **+180 KB** per 40-minute match. The new estimated total is about 1.6 MB uncompressed.

### 10.3 Implementer notes (PROPOSED clarifications, to confirm with Joan)

These settle wording that two coders could read two ways. They don't change any layout above.
1. **What a checkpoint hashes.** "Every byte written since the previous checkpoint" means every byte after the end of the previous CHECKPOINT record (or after the file header, for the first one), **up to and including this checkpoint's 8-byte header and its `record_count`**, and not its own `chain_sha256`. That way `record_count` is tamper-evident too.
2. **`record_count`** counts the records between the two checkpoints. It doesn't count the checkpoint itself.
3. **CRC-32** is the standard IEEE CRC-32 (reflected polynomial 0xEDB88320, init 0xFFFFFFFF, final XOR 0xFFFFFFFF), the same as Python `zlib.crc32`. Test vector: `"123456789"` → `0xCBF43926`.
4. **Rewind encoding** (SHOT and REWIND_DECISION): the target is interpolated between the samples at `now − ceil(r)` and `now − floor(r)`, where `r = rewind_ticks + rewind_frac ÷ 65536`.
5. **The ±1-tick window is inclusive.** A claim exactly 1.0 tick off is accepted.

### 10.4 Coverage

With this addendum, the records cover everything the server decides about shots and inputs:
- **Every rejected input** writes an INPUT_REJECT record (type 3, reasons 1–4, with 255 reserved for any future reason). That includes a claimed time outside the ±1-tick window, which is clamped and logged, never silently fixed.
- **Every near miss** (shot within 1.0 unit of a target's box, hitbox v0.2 Section 5) and **every hit** writes a SHOT record (type 1, outcome 1 or 0), one per (shot, target) pair.
- **Every rewind decision**, one per lag-compensated shot, including shots that miss everyone, writes a REWIND_DECISION record (type 5). It has the claimed, expected and chosen view tick, the measured RTT, the interpolation delay, the cap and any clamp with its reason.
- **How the view moved around each logged shot** (snap-back, flick-stop) will be in AIM_KIN records (type 6, reserved, proposed in the crosshair spec). Until that's approved, the server demo's raw view angles hold the same information.
- **What each player was sent** is in VIS records (type 2), and **tamper evidence** is in CHECKPOINT records (type 4), which chain every byte of every record type above.

Shots that come nowhere near anyone still get a REWIND_DECISION record but no SHOT record. Their raw input is in the server demo.
