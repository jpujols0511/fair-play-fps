# Fair Play FPS - Weapons & Hitreg Prototype

P1 implements pure rifle accuracy, spread, recoil, kick decay and fire timing.
The Python simulator is the reference; tests replay its recorded random draws
in GDScript. Later hitbox, hit-registration and evidence phases extend this
same Godot project.

## Requirements and commands (Linux)

Use the official, standard (non-.NET) Godot **4.4.1-stable** binary and Python
3 with only the standard library. The parity runner checks its Godot version.
From the repository root:

```bash
python3 specs/goldsrc_recoil_spread_sim.py --emit-cases weapons_proto/tests/recoil_cases_cd9.json
python3 specs/goldsrc_recoil_spread_sim.py | diff - specs/sim_recoil_results_cd9.txt
python3 specs/goldsrc_recoil_spread_sim.py --smooth
python3 specs/goldsrc_movement_sim.py | diff - specs/sim_results.txt

cd weapons_proto
~/bin/godot-4.4.1 --version
~/bin/godot-4.4.1 --headless --import
~/bin/godot-4.4.1 --headless --script res://tests/test_recoil_parity.gd
```

The case generator writes all 16 shot-by-shot sprays (two weapons × stand,
crouch, run and air × 64/128 tick). The 12 extended cases are explicitly
labeled `extended (sim-generated, not in sim_recoil_results_cd9.txt)`. Each of
the 480 shots records four uniform draws followed by its inclusive side-flip
draw. The legacy `recoil_cases.json` and `sim_recoil_results.txt` remain
unchanged; the new default simulation uses the CD-r9 stepped accuracy.

## P1 API and behavior

`Recoil.initial_state(weapon_id)` creates a fresh rifle state. The pure
`spread_for_next_shot(weapon_state, move_state)` returns the final spread
displayed in snapshots and recorded as `spread_at_fire`; it is not the raw
accuracy value. A movement state is a dictionary with `in_air`,
`horizontal_speed` and `crouched` fields. Spread checks air first, then a
ground speed strictly above 140 units/s, then standing/crouched.

`fire_due(state, time_s)` implements tick-boundary firing. When it returns
true, `fire_shot(state, move_state, rng, time_s)` returns the next weapon
state and the pre-kick shot result. Call `finish_tick(state, 1.0 / tick_rate,
fired)` after the fire check; kick decay runs on every tick, including a fire
tick. Gameplay math uses fixed tick lengths, not frame delta, and creates no
nodes or physics bodies.

Recoil state stores `px` as negative-up pitch and `py` as positive-left yaw.
The shot output converts the pitch once (`kick_up = -px`); kick is applied
after the shot, and its additional per-shot amount starts at shot two.
Accuracy starts at 0.2 after a fresh state. After each shot, accuracy uses the
whole-number part of `n * n * n / divisor`, plus the weapon floor and capped.
AK accuracy is 0.35 after shots 1-5 and 1.25 from shot 6; M4A1 is 0.30 after
shots 1-6 and 1.00 from shot 7. The next shot uses the accuracy stored before
that shot, so the AK remains at the floor for shots 2-6 and the M4A1 for shots
2-7. `accuracy_for_shots_smooth()` remains available for reference but is not
used by default; the Python simulator exposes its old curve with `--smooth`.

CD-r9 recovery caps the burst counter at 15 on release, starts the 0.4s delay
at release, and drops once per tick when elapsed time is strictly greater than
the due time plus `1e-9`. Subsequent drops are due 0.0225s after the previous
drop. The old behavior remains configurable through the recovery switches.
Stored accuracy is not reset when the counter recovers (J4 remains false), and
fire-cycle timing is unchanged (OPEN 18).

## Randomness

Every random draw is supplied through the injected `uniform(a, b)` and
`randint(a, b)` interface. `ReplayRng` verifies draw kind, bounds and count,
and reports an error on a mismatch or exhaustion. `GodotRng` wraps a seeded
`RandomNumberGenerator`. Production hit registration must create/seed that
source on the server when it processes a shot; no seed or upcoming draw is
accepted from or disclosed to the client before firing.

## DECISION FOR JOAN switches

| ID | Switch | Default | Alternative |
|---|---|---|---|
| J1 | `KICK_PATTERN_MODE` | `random_flip` (stock 1.6 proposal) | `fixed` uses a repeating `[false, true]` deterministic test stub; it is not a CS2 spray pattern. |
| J2 | `KICK_MOVING_BEFORE_AIR` | `true` (stock moving-before-air behavior) | `false` uses air kick whenever airborne. |
| J3 | `FLIP_ROLL_INCLUSIVE` | `true`, roll `randint(0, k)` | `false`, roll `randint(1, k)`. |
| J4 | `ACCURACY_RESET_ON_RECOVERY` | `false` (stock stored-accuracy quirk) | `true` recomputes accuracy as the burst counter recovers and restores 0.2 at zero. |

CD-r9 changes the recovery defaults to `SHOTS_FIRED_RELEASE_CAP=15.0`,
`RECOVERY_DELAY_FROM="release"`,
`BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD=false`, and
`RECOVERY_ONE_PER_TICK=true`. The alternate values remain in `WeaponConfig`.
The current golden and tests cover the strict first-drop rule and exact
64/100/128-tick reset counts; the 100 Hz case does not drop at tick 40 and
first drops at tick 41.

## Validation scope

`test_recoil_parity.gd` compares all ten shot outputs in all 16 30-shot sprays
(4,800 numeric comparisons), confirms that time, kicks and raw RNG draws are
unchanged from the legacy golden, and recomputes `spread_x`/`spread_y` from
the new spread and stored draws within `1e-9`. It also checks both weapon step
tables, pre-shot spread transitions, stored-accuracy recovery, stock release
defaults, exact reset ticks, the one-drop-per-tick rule, and the old recovery
switch combination.

AWP and Deagle are omitted because the reference simulator does not model
them. The unsilenced M4A1 standing multiplier is present as a table entry but
has no sim parity test. The precise spread-distribution shape remains
unverified, as noted in the behavior spec.

## P2: canonical hitbox geometry

The source of truth is `../specs/skeleton_constants.json`. Regenerate and
verify its GDScript constants from the repository root:

```bash
python3 tools/skeleton_sha256.py
python3 tools/gen_skeleton_constants.py
python3 tools/gen_skeleton_constants.py --check
```

The canonical SHA-256 is
`56db86a8d12c400f5149f7cfcbf17ec79dd662c93cc6a3d5f18d4d0c288f7aa0`.
The generated `shared/skeleton_constants.gd` is not hand-edited.

Gameplay coordinates use feet as the origin, **x forward, y left, z up**,
with yaw rotating counterclockwise around z. The stance enum is **0 stand,
1 crouch, 2 air, 3 crouch-air**. Air poses translate every box rigidly with
the origin. Crouch uses the approved half-height scale `0.5`: body 36, eye
32, head z-range 24..36. The transition uses one duck fraction `f` to blend
each box's stand/crouch bottom and top and the eye height; `-1.0` derives `f`
from the stance. At `f=0.5`, the head spans z=42..54 and the eye is z=48.
The raw crouched head/chest boxes overlap 5.5 units (z=24.5..30.0); the
head-only bands are 6.0 units above and 0.5 units below. Ray selection uses
`CROUCH_HEAD_OVERLAP_RULE="entry_first"` by default;
`"head_priority_in_overlap"` remains an alternative for review. With the
2.0-unit hit-test padding, the expanded boxes overlap 9.5 units.

Game-to-spec conversion has one source:
`prototypes/prediction_loop/scripts/net/frame.gd`, linked as
`shared/frame.gd`; the shared `InputCmd` angle quantizer is linked as
`shared/input_cmd.gd`. Use these instead of inline angle or coordinate
conversion in downstream scenes.

`Hitboxes.build_boxes(Vector3, yaw_deg, stance)` returns the proposed `center`,
`half`, `yaw_deg` and `[forward, left, up]` axes as `Vector3` convenience
values. Godot's official 4.4.1 `Vector3` components are float32 even though
GDScript scalar floats are float64. To preserve the spec's 1e-9 geometry
tolerance, each result also has `center64`, `half64` and `axes64` packed
float64 arrays. Server hit math must use these precise fields;
`build_boxes_precise(PackedFloat64Array, yaw_deg, stance, duck_fraction)`
also accepts a float64 origin without first quantizing it through `Vector3`.
The `Vector3` members are for visualization and compatibility with the
proposed box shape.

## DECISION FOR JOAN hitbox defaults

| ID | Config | Default | Alternative |
|---|---|---|---|
| J5 / A1 | `BOX_RADIUS_MULTIPLIER`, canonical JSON sizes | `2.0` (width/depth are 2x radius) | None specified. |
| J6 / A2 | `CROUCH_SCALE` | `0.5` (half height) | None; the old `0.8333` alternative is removed. |
| J7 / A3 | `STAND_HEIGHT`, `EYE_STAND` | `72.0`, `64.0` | None specified. |
| J8 / A4 | `NON_HEAD_LENGTH_SCALE`, `LENGTH_TABLE_MODE` | `0.57`, `v0.2_rounded` | v0.1 raw lengths only with a new JSON and SHA. |
| J9 / A5 | `ARM_POSE` | `a_pose` | None specified. |
| A2-b | `CROUCH_HEAD_OVERLAP_RULE` | `entry_first` | `head_priority_in_overlap` |
| A4-a | `HITBOX_PADDING`, `HITBOX_PADDING_PER_BONE` | `2.0` per bone (PROVISIONAL) | `0.0` regression set |
| A4-b | `NEAR_MISS_LOG_UNITS` | `4.0` from padded surface | `1.0` old-threshold regression |

The padding is applied at ray hit-test time only; it does not change the
canonical skeleton JSON or hash. The lag-comp sample must carry/interpolate
`duck_fraction` so rewound geometry uses the matching transition pose.

Run the P2 geometry test from `weapons_proto/`:

```bash
~/bin/godot-4.4.1 --headless --import
~/bin/godot-4.4.1 --headless --script res://tests/test_hitboxes.gd
```

The test checks all 11 parts and sizes, stand/half-crouch endpoints and the
half-duck pose, the eye strictly inside the blended head for 65 fractions,
all 11 boxes at yaw 0/90/180/270/37.5, jump translations, the generated SHA,
the shared frame/angle adapter, and config/data agreement.
## P3: ray vs oriented box

The ray is a **finite segment** in the game frame. Pass a unit float64
`PackedFloat64Array` direction and segment length already clipped to the
weapon range and first world hit. `RayBox.intersect_box` performs the slab
test in the box's yaw-local frame with signature
`intersect_box(origin, direction, length, box, padding=2.0)`; `trace_boxes`
selects the first hit, and
`trace_target` returns `hit`, `near_miss` or `none` with `box_id`, `dist`,
`ray_point` and `box_point`. A start inside or on a box is a hit at distance
zero. Parallel axes use the `1e-12` threshold; the segment endpoint is
inclusive. Hit tests expand each OBB by `HITBOX_PADDING_PER_BONE[box_id]`,
default `2.0`; callers can pass `0.0` per bone to replay the padding-zero
regression set. Padding is applied at hit time only, not in `build_boxes`.

When no box is hit, GDScript computes the closest points by partitioning
`[0, L]` at every slab crossing. On each interval the squared distance to the
box is quadratic, so its minimum is evaluated analytically; GDScript does not
sample or iterate. `tools/ray_box_ref.py` is independent and uses golden
section search to find the same closest segment/box points. Near-miss distance
is measured from the padded surface and logged when `0 < dist <= 4.0`;
exactly 4.0 counts. If box entries or near-miss distances differ by at most
`1e-6`, priority is head, chest, stomach, arms, forearms, thighs, shins.
`CROUCH_HEAD_OVERLAP_RULE` defaults to `entry_first`; the head-priority
alternative applies only when a crouched ray is inside both head and chest in
the overlap band.

`WEAPON_RANGE_UNITS` (J17) defaults to the proposed 8192.0 units. Callers
provide the clipped segment length; world collision is not implemented in
this phase.

The committed `ray_box_cases.json` is the original 20,012-case, padding-zero
regression set (expected-results SHA
`4b89531368bd3b0ca06068289b561027fc4cb32fdcc2ffea14fa5e5f99d9afb3`). Keep
its stored boxes intact as the slab/near-miss regression baseline. The
parallel `ray_box_padded_cases.json` reuses those exact inputs
with 2.0 padding and the 4.0 near-miss limit; its expected-results SHA is
`2d204cc4c424ffefc6682e6d17b10a1c6c0a551a6faa04ce1ca4fa9b2f273609`.
The padded golden set passes 20,012 cases with maximum absolute error
`1.2905e-8`. Direct CD-r2 tests use the new half-crouch boxes: z=33.0 selects
head, z=27.25 selects chest by entry distance; with padding their entry
distances are 494.0 and 490.0. The Python boundary self-test checks the current
CD-r2 geometry and padded 4.0 / 4.0+1e-6 boundaries.

Run the Python reference checks from the repository root:

```bash
python3 tools/ray_box_ref.py --self-test
python3 tools/ray_box_ref.py --emit-padded-cases weapons_proto/tests/ray_box_padded_cases.json
python3 tools/gen_skeleton_constants.py --check
python3 tools/skeleton_sha256.py
```

The random case mix is 6,000 aimed hits, 6,000 near-miss rays, 2,000 parallel
cases, 2,000 inside starts, 2,000 segment-limit cases and 2,000 multi-box
skeleton traces, plus 12 explicit input boundaries. The canonical
expected-results digest uses signed integers at 1e-9 scale, avoiding
Python/GDScript float-to-JSON formatting differences.

Run the GDScript slab, boundary and golden tests from `weapons_proto/`:

```bash
~/bin/godot-4.4.1 --headless --import
~/bin/godot-4.4.1 --headless --script res://tests/test_ray_box.gd
```

The full regression suite passes P1 2977/2977, P2 492/492 and P3 143/143.
`tests/logs/test_ray_box_a4.log` has the combined output.

### CD-r7 follow-up: fail-closed inputs and current-skeleton goldens

`RayBox` now rejects non-finite origins, directions and segment lengths, plus
non-unit directions (squared-length tolerance `1e-9`), before slab or
near-miss math. `tools/ray_box_ref.py` mirrors the same contract. Its API
near-miss default is 4.0; only the frozen zero-padding baseline explicitly
uses the historical 1.0 threshold.

The original `ray_box_cases.json` and `ray_box_padded_cases.json` remain
untouched as legacy fixtures. New `ray_box_cases_cd7.json` and
`ray_box_padded_cases_cd7.json` identify skeleton SHA
`56db86a8d12c400f5149f7cfcbf17ec79dd662c93cc6a3d5f18d4d0c288f7aa0` and each
contain 20,015 cases. The new padded golden uses 2.0 padding and the inclusive
4.0 near-miss threshold. CD-r7 P3 passes 163/163 GDScript checks and 35 Python
boundary/fail-closed assertions; `tests/logs/test_ray_box_cd7.log` and
`tests/logs/test_ray_box_regressions_cd7.log` contain the output.
## P4: history and rewind policy

The server tick order is **move all players -> push every sample for tick T ->
process shot commands for T**. Thus rewind zero refers to positions at T.
`LagCompHistory` allocates a fixed ring per slot with
`floor(0.2 * tick_rate) + 1` samples: 13 at 64 tick, 21 at 100 and 26 at 128.
Pushes overwrite preallocated fields; they do not allocate a new sample each
tick.

Samples keep `tick`, float64 `origin64`, `yaw_deg`, stance, `duck_fraction` and
`alive`. The `Vector3` origin is a display convenience only. Legacy samples
without a fraction derive 0.0/1.0 from stance. `sample_at(slot, target_tick)`
linearly interpolates origin and duck fraction, follows the shortest yaw arc,
uses the nearer stance (older on an exact 0.5 tie), and marks the result dead
if either endpoint is dead. If an endpoint is outside available history, it
returns the oldest sample with `missing_history`. Rewound boxes and eye height
use the interpolated duck fraction, so a shot sees the same hybrid pose that
was present at that sub-tick.

`RewindPolicy.choose` computes
`expected_view_tick = now - rtt_ms * tick_rate / 1000 - interp_ticks`.
Claims at exactly +/-1.0 tick are accepted. A `1e-9`-tick numeric epsilon keeps
that inclusive boundary stable through float serialization. Outside that
window, the claim is clamped to its nearest edge and `input_reject` is set. The server then clamps
the wanted rewind to 0..`floor(0.2 * tick_rate)`, emits reason codes 0-5 and
flags for claim-window, over-cap and negative-rewind decisions. Missing target
history adds flag bit 5 and reason 6 when no other reason applies.

`rewind_targets` returns other living players only. It never rewinds the
shooter or accepts world objects; missing-history players use their oldest
sample and are omitted from the rewound mask. World geometry, doors and
grenades remain at current state.

## DECISION FOR JOAN: rewind defaults

| ID | Switch | Default | Alternative |
|---|---|---|---|
| J10 | `INTERP_TICKS` | `4` (31.25ms at 128 tick) | `2` or `3` |
| J11 | `MAX_REWIND_TICKS` | `floor(0.2 * tick_rate)` | None |

The 4-tick interpolation delay follows the written netcode spec; alternatives
2 and 3 remain testable. The history uses `origin64` so interpolation preserves
the P2 float64 geometry precision.

`tests/scripted_path.gd` provides deterministic linear, circular and peek
paths plus stance/spawn/death markers. The independent Python reference
generates 5,000 seeded random history/policy queries plus 15 named policy/path
cases:

```bash
# from the repository root
python3 tools/lagcomp_ref.py --self-test
python3 tools/lagcomp_ref.py --emit-cases weapons_proto/tests/lagcomp_cases.json --seed 4242 --count 5000

# from weapons_proto/
~/bin/godot-4.4.1 --headless --import
~/bin/godot-4.4.1 --headless --script res://tests/test_lagcomp.gd
```

The GDScript suite compares exact rewind flags/reasons and encoded
ticks/fractions, plus interpolated origins, yaw and duck fraction to 1e-9.
It tests a mid-duck head-height shot at 64, 100 and 128 tick; the target is a
head at z=48 only at duck fraction 0.5. The A3 history suite passes 128/128,
and the Python reference self-test passes 13/13.
## P5: server-side hit registration

`HitReg.process_shot(context)` is a pure GDScript server module. A command
contains intent, `cmd_seq`, quantized view angles, timing and shot index only;
it cannot provide a hit, position, damage value or random seed. Angles are
quantized by the shared `input_cmd.gd` after conversion through `frame.gd`;
SHOT records retain those exact wire integers. The server injects its random
source into P1 recoil/spread, chooses the P4 rewind, then builds P2 boxes using
the interpolated `duck_fraction` and traces them with P3's padded float64
segment logic. Static world AABBs are supplied as `{min64, max64}`; no Godot
physics query is used.

Each hit/near-miss record carries its box/region, trace and closest distances,
points, target pose, spread/kick, rewind ticks/fraction, team marker and flags.
Evidence `closest_dist` remains 0 for a hit; `trace_distance` retains the
segment entry distance for scenario/debug verification. The returned decision
also includes `REWIND_DECISION` data; a claimed-time clamp yields an
`INPUT_REJECT` reason 1. If world clipping stops the shot before any player
trace, there is no SHOT record but the rewind decision is still returned.
Near misses use the padded surface and 4.0-unit limit from A4. The crouch
overlap test uses z=33.0 for head and z=27.25 for chest (entry-first).

CD-r7 fail-closed handling rejects non-finite claimed view ticks and RTT values
as `INPUT_REJECT` reason 1 with `CLAIMED_TIME_OUT_OF_WINDOW`. The server clamps
the rewind to a finite expected tick; a non-finite server RTT is sanitized to
0.0 for the decision. The Python lag-comp reference mirrors this behavior.

## DECISION FOR JOAN: hit registration defaults

| ID | Switch | Default | Alternative |
|---|---|---|---|
| J12 | `DAMAGE_TABLE` | Base damage 0.0, all region multipliers 1.0 placeholder | Real values await the weapons spec |
| J13 | `PLAYER_PENETRATION` | `false`; stop at first player hit | `true`; continue through players |
| J14 | `WORLD_BLOCKS_SHOTS` | `true`; clip at first world AABB | `false`; allow a wallbang and set `THROUGH_WORLD` |
| J17 | `WEAPON_RANGE_UNITS` | `8192.0` | None specified (added in P3) |

Damage is intentionally not applied in P5. Regions map head/chest/stomach/arms
and legs to IDs 0-4. Teammates are traced like other players and marked `same_team`;
friendly-fire behavior remains a game-mode decision. `DAMAGE_TABLE` is metadata
only and cannot cause health changes.

The independent Python oracle reuses the P3 ray/box and P4 rewind references,
plus the P1 weapon tables. It produces 22 named cases covering scenario groups
1-11 and 2,000 seeded random shots with 1-11 targets, random recorded draws,
RTT 0-250ms and interpolation 2/3/4. The GDScript replay compares record fields,
rewind decisions and input rejects; maximum recorded numeric difference is
`8.15252e-7`.

```bash
# from the repository root
python3 tools/hitreg_ref.py --self-test
python3 tools/hitreg_ref.py --emit-cases weapons_proto/tests/hitreg_cases.json --seed 4242 --count 2000

# from weapons_proto/
~/bin/godot-4.4.1 --headless --import
~/bin/godot-4.4.1 --headless --script res://tests/test_hitreg.gd
```

P5 Addendum 2/4 passes 106/106 Godot checks and 30/30 Python oracle
self-tests. The exact P1-P5 stacked regression run is recorded in
`tests/logs/test_hitreg_regressions_cd2.log`.

`tests/logs/test_hitreg.log` records the P5a, P5b and P5c suite outputs;
`tests/logs/hitreg_ref.log` records Python self-tests and deterministic case
regeneration. Addendum 2/4 output is in `tests/logs/test_hitreg_a4.log`;
`tests/logs/test_hitreg_regressions_cd2.log` contains the full P1-P5 regression
run and unchanged recoil/movement simulator diffs.

### CD-r7 fail-closed rewind validation

`RewindPolicy.choose` now treats a non-finite claimed view tick or RTT as an
out-of-window claim, sets `CLAIMED_TIME_OUT_OF_WINDOW`, returns an
`INPUT_REJECT` reason 1 and clamps to a finite expected tick. A non-finite RTT
is sanitized to 0.0 for the rewind calculation; a NaN claim is retained only
as the rejected input value. The Python lag-comp reference follows the same
policy. P5 now passes 114/114 Godot checks; the P4 policy/history suite passes
139/139 and Python self-tests pass 25/25 (lag-comp) and 30/30 (hitreg).
`tests/logs/test_hitreg_cd7.log` records the non-finite regression checks;
`tests/logs/test_hitreg_regressions_cd7.log` contains the complete P1-P5 run.
PR #9 remains dependent on Game Builder merging P3 follow-up PR #21 first.
## P6: append-only `.fpev` evidence ledger

The GDScript writer, reader and JSONL exporter are retained but gated by
`ENABLE_EVIDENCE_LOG=false` by default while the Rust-layer hold stands.
Production range sessions do not open or read evidence unless explicitly
opted in; tests pass `{"ENABLE_EVIDENCE_LOG": true}`. The Python reference CLI
also refuses access unless passed `--enable-evidence-log`.

`FpevWriter` writes the packed little-endian 8-byte record header plus the
specified type body and IEEE CRC-32. `FpevReader` validates record lengths,
CRCs, REWIND_DECISION checkpoint links and the SHA-256 chain. Unknown types are
length-skipped with a warning but remain part of the chain. Readers never
repair or rewrite bytes. `FpevJsonl` exports the verified records with stable
key ordering and reports `CHAIN OK` separately from the JSONL text.

The file header hashes UTF-8 account identifiers concatenated with a per-server
salt; raw accounts never enter `.fpev`. The kernel hash is currently 32 zero
bytes as an explicit placeholder. The skeleton hash uses P2's canonical SHA.
Checkpoints fire at `(tick + 1) % 128 == 0` and at close; their hash covers the
previous chain, all intervening record bytes, the current checkpoint header and
`record_count`, but not the checkpoint's own hash. REWIND_DECISION records link
to the preceding chain prefix. These cadence/chain details are proposed
readings of evidence spec Section 10.3.

When evidence is explicitly enabled, J19 `ENABLE_AIM_KIN` defaults to `true`
behind its own switch because type 6 is still proposed in crosshair review
note (c). `RETENTION_DAYS=90`,
`CHECKPOINT_INTERVAL_TICKS=128`, and the current AK47/M4A1 numeric ID mapping
are configurable proposals. AIM_KIN remains review-only; no evidence record
can punish a player.

`tests/golden/match_small.json` is a fixed 400-tick fixture with 10 slots, 20
hits, 20 near misses, input reject reasons 1-4, rewind reasons 0-6, 12 VIS
records, 20 AIM_KIN records and four checkpoints. Python writes
`tests/golden/match_small.fpev` and `tests/golden/match_small.jsonl`; the
GDScript suite verifies byte-for-byte parity, both readers, final chain and
JSONL output. The whole binary is 8,320 bytes; final chain SHA-256 is
`a32c1c8cc67c2a771b77790d3922a627c1603d1173aa4628cb184bc49f9876bb`.

```bash
# from the repository root
python3 tools/fpev_ref.py write --enable-evidence-log weapons_proto/tests/golden/match_small.json /tmp/match_small.fpev
python3 tools/fpev_ref.py verify --enable-evidence-log /tmp/match_small.fpev
python3 tools/fpev_ref.py export --enable-evidence-log /tmp/match_small.fpev

# from weapons_proto/
~/bin/godot-4.4.1 --headless --import
~/bin/godot-4.4.1 --headless --script res://tests/test_evidence.gd
```

`tests/logs/test_evidence_p6d.log` retains the original 100/100 writer, reader,
golden and tamper suite. `tests/logs/test_evidence_cd2_gate.log` contains the
historical CD-r2 108/108 suite, including disabled-by-default checks.
`tests/logs/fpev_ref_tamper.log` records both-reader
tamper results; `tests/logs/fpev_ref_cd2_final.log` records the current
explicitly enabled Python byte identity, chain verification and JSONL parity.
`fpev_ref_final.log` and `test_evidence.log` remain as historical runs. The
current P1-P6 regression is collected in
`tests/logs/test_evidence_regressions_cd2.log`.


### CD-r7 view-angle export correction

`FpevJsonl` now converts wire q values with `InputCommand.dequantize_*` and
`FrameAdapter` before emitting spec-frame degrees; `tools/fpev_ref.py` mirrors
that conversion. The old direct `q*360/65536` conversion was incorrect.
`match_small.jsonl` now reflects the corrected spec-frame angles (q=0 maps to
pitch/yaw 90.0/90.0). The CD-r7 P6 test passes 114/114, including default-OFF
checks and Python/GDScript JSONL parity. Output is in
`tests/logs/test_evidence_cd7_angle.log`; the full P1-P6 run is in
`tests/logs/test_evidence_regressions_cd7.log`. Production writer/reader/export
remains disabled by default under the Rust-layer hold.
## P7: offline review analysis

The analyzer and `ReviewQueue` writer are held behind
`ENABLE_ANTICHEAT_REVIEW=false` by default. A disabled analyzer returns no
player statuses and `auto_action: "NONE"`; writing a review report requires an
explicit opt-in. The Python reference CLI likewise requires
`--enable-evidence-log --enable-review`.

P7 consumes only a verified P6 evidence file and a demo-like server timeline.
`UnsentAimAnalyzer` derives aim/tracking episodes from true P2 head/chest
centres, VIS masks, rounded sound events, teammate visibility and injected
pre-aim spots. J15's `MAX_VIEW_DELTA_DEG_PER_TICK` defaults to `INF` for yaw;
non-finite angles and pitch outside +/-89 degrees are malformed. A finite yaw
limit is an optional config override, not the default.

The analyzer follows the proposed thresholds in
`AntiCheatParams.DEFAULTS`: X=2 degrees, Y=250ms, C=0.8, G=500ms, S=2,000ms,
P=90, N=3, target speed=30 units/s and teammate window=3s with weight 0.25.
Each candidate episode lists checked explanations and any applied drop/weight.
An invalid P6 chain is exposed in `evidence_chain_ok` and cannot raise a
player's review status.

`AimKin.compute` processes the server-received angle samples in `cmd_seq`
order, wraps yaw, and computes the 16-before/3-after kinematics for type 6.
The selected `AIM_KIN_PROFILE` comes from server/match metadata `mode`, never
client or timeline fields. Surf has its own profile table; its thresholds
remain provisional and currently mirror the default J16 values until data
exists. `mode: "surf"` selects that profile; any client-provided profile field
is ignored. J16 keeps the crosshair note (c) proposals in one parameter dictionary:

| Parameter | Default |
|---|---:|
| `WINDOW_BEFORE_TICKS` / `WINDOW_AFTER_TICKS` | 16 / 3 |
| `SNAP_MIN_FIRE_DELTA_DEG` | 3.0 |
| `SNAPBACK_MIN_FRACTION` / `SNAPBACK_MAX_COS` | 0.70 / -0.8 |
| `PRE_FIRE_SPEED_MAX_FRACTION` | 0.10 |
| `FLICK_MIN_PEAK_ACCEL_DPS2` | 200,000 |
| `FLICK_MAX_SETTLE_TICKS` / `SETTLE_FRACTION` | 1 / 0.10 |
| `N_AIM_KIN` / `EXCLUDE_AFTER_RESET_TICKS` | 3 / 16 |

Reset, repeated-command, dead and spectating windows are excluded. Speed alone
is not a signal. AIM_KIN contributes to review status only after three flagged
shots in three distinct rounds.

`ReviewQueue` is the only GDScript writer for review JSON. It accepts only
`NO_FLAG` or `NEEDS_HUMAN_REVIEW` and writes `auto_action: "NONE"`; results are
offline review evidence and never affect a live match. A broken chain cannot
raise review status.

The deterministic 400-tick fixture is
`tests/fixtures/anticheat_match.timeline.json`; it joins to the checked P6
`match_small.fpev`. Python `tools/anticheat_ref.py` independently builds the
timeline, reads the ledger and writes
`tests/golden/anticheat_match.flags.json`. The GDScript report, guarded file
output and Python report must match that golden byte-for-byte.

```bash
# from the repository root
python3 tools/anticheat_ref.py weapons_proto/tests/fixtures/anticheat_match.timeline.json \
  --enable-evidence-log --enable-review \
  --output /tmp/anticheat_match.flags.json

# from weapons_proto/
~/bin/godot-4.4.1 --headless --import
~/bin/godot-4.4.1 --headless --script res://tests/test_anticheat.gd
```

The CD-r2 run passed 92/92 Godot checks; its logs remain historical. After the
CD-r7 P6 angle-export fix, P7 still passes 92/92 with Python golden parity,
server-selected surf profile, offline gates and review-only `auto_action`.
`tests/logs/test_anticheat_cd7.log` contains the focused run;
`tests/logs/test_anticheat_regressions_cd7.log` contains the full P1-P7 stack.
`test_anticheat_acceptance_final.log`, `anticheat_ref_acceptance.log` and
`test_anticheat.log` retain earlier runs.
## P8: shooting range integration demo

`project.godot` opens `scenes/range.tscn`. The scene integrates the P1 weapon
math, P2 11-box poses, P3 segment tracing, P4 history/rewind, P5 server
hit-registration function, P6 evidence ledger and P7 offline review analyzer.
The headless and interactive runners share a fixed 128-tick order:
move/sample all players, push history, then process shots. No physics raycast
or client-supplied hit is used. Game coordinates stay x-forward/y-left/z-up;
the scene uses the shared `frame.gd` conversions to Godot's y-up frame, and
`TICK_RATE := 128.0` keeps gameplay timing in float arithmetic.

The range draws a floor grid, three static wall boxes, five scripted targets,
their current white box outlines, and per-shot rewind ghosts, a yellow segment,
green hit markers and orange near-miss markers. The HUD uses a high-contrast
field-console layout and shows simulated ping, interpolation, rewind reason and
flags, spread, AIM_KIN flags, last result and evidence counts.

Controls: WASD moves on the flat range; mouse looks; left mouse fires; `1`/`2`
select the two numeric rifle IDs; `F1`–`F5` set 0/40/80/150/250ms ping; `I`
cycles 2/3/4 interpolation ticks; `B` toggles the debug five-tick backtrack
claim; `N` toggles scripted snapback shots; `L` verifies `.fpev` and writes
JSONL; `K` writes the review-only flags JSON; `R` resets; `Esc` releases the
mouse. `L`/`K` remain disabled while the default evidence/review flags are off;
only the smoke test explicitly opts in. Debug modes are labeled on the HUD.

Explicitly enabled evidence goes under
`user://matches/<match_id>/evidence.fpev`, with `evidence.jsonl` and
`review/<match_id>.flags.json` alongside it. `FpevReader` verifies the chain
before export or review; invalid evidence cannot raise a review status. The
review queue always writes `auto_action: "NONE"`. Smoke-run artifacts use a
unique `user://smoke_runs/` directory.

```bash
# from weapons_proto/
~/bin/godot-4.4.1 --headless --import
~/bin/godot-4.4.1 --headless --script res://tests/test_range_smoke.gd
~/bin/godot-4.4.1 --path .   # interactive range

# from weapons_proto/ on Linux, substitute the match id from the HUD
python3 ../tools/fpev_ref.py verify \
  --enable-evidence-log \
  "$HOME/.local/share/godot/app_userdata/Fair Play FPS - Weapons & Hitreg Prototype/matches/<match_id>/evidence.fpev"
```

The smoke test explicitly opts in, then runs 2,000 ticks and 50 fixed-seed shots at 80ms ping and four
interpolation ticks, including five rejected backtrack claims and three
scripted snapbacks. It checks at least one hit/near miss, exactly five
`INPUT_REJECT` reason-1 records, one `REWIND_DECISION` per shot, an AIM_KIN
`SNAPBACK`, GDScript and Python `CHAIN OK`, and identical file SHA-256 on
repeat. The smoke passes 24/24 checks; each recorded shot command has one
AIM_KIN entry even when multiple target SHOT records share its `shot_index`.
After merging the CD-r7 P5-P7 stack, the P8 smoke still passes 24/24 and the
complete P1-P8 suite passes 2977/2977, 492/492, 163/163, 139/139, 114/114,
114/114, 92/92 and 24/24. `tests/logs/test_range_smoke_cd7.log` contains the
range run; `tests/logs/test_range_regressions_cd7.log` contains the full stack.
The older `*_cd2.log` files remain historical. This is a deterministic
headless prototype check, not LAN/two-client network testing or a playtest.
## P10: performance trigger

`tests/bench_hitreg.gd` ran 1,000 warm-ups and 10,000 timed shots for the
worst-case 11-target/121-box fixture, with 26-sample histories, three
off-ray world boxes and randomized fractional rewinds. On an Apple M2 Pro
(macOS 26.7.2 arm64), official Godot
`4.4.1.stable.official.49a5bc7b616bd04689a2c89e89bda41f50241464`, median was
4.212 ms, p99 4.559 ms and max 8.056 ms. All three proposed budgets failed:
0.10 ms median, 0.25 ms p99 and 1.0 ms max.

Rust-port trigger: `full_hitreg_shot`, measured median 4.212 ms vs 0.10 ms,
p99 4.559 ms vs 0.25 ms, max 8.056 ms vs 1.0 ms. Per the stop rule, no
breakdown profiling, evidence-writer benchmark, AIM_KIN benchmark, optimization
or Rust port was attempted after this failure. `bench_evidence.gd` is therefore
not implemented/run. P10 remains blocked pending Joan/Game Builder direction.
This measurement ran against P8 CD-r2 parent `1d71892`, before the CD-r7
hardening; no remeasurement was performed after the trigger.
Full output is in `tests/logs/bench_hitreg.log`.

## License

SPDX-License-Identifier: AGPL-3.0-only. Full text in the repository root `LICENSE.txt`.
