# Round loop prototype (step 1: phases + economy)

*Game Builder, Oct 17 2026. Not public yet. Branch `gamebuilder/round-loop`, not merged.*
Builds `specs/round_loop_spec_v0.1.md` (Joan) in his order: **(1) phase enum + transitions, (2) economy math.** Buy menu UI (3) and bomb-site geometry (4) come next; the server-side buy validation and plant/defuse timing they need are already here.

## Files
| File | What |
|---|---|
| `round_controller.gd` | Phase enum `WARMUP, FREEZE, LIVE, PLANTED, ROUND_END`; tick-driven state machine at 128 Hz; win conditions; plant/defuse timing; server-side `request_buy`; `get_snapshot_fields()` |
| `economy.gd` | Pure functions: kill, plant, defuse, loss ladder, win bonus, cash cap, `validate_buy` |
| `weapons_table.gd` | Buy-menu items: category, price (PROPOSED except armor: vest $650, vest + helmet $1000 (Joan, Oct 17 2026)), team (AK T only, M4 CT only) |
| `tests/test_round_loop.gd` | Every transition and win condition (100 checks) |
| `tests/test_economy.gd` | Every economy rule and buy check (60 checks) |

## Run on CachyOS (Godot 4.4.1 exactly)
```bash
cd ~/fair-play-fps
git fetch origin && git checkout gamebuilder/round-loop && git pull
cd prototypes/round_loop
godot --version            # must print 4.4.1.stable...; otherwise use the 4.4.1 binary
godot --headless --path . --import
godot --headless --path . --script res://tests/test_economy.gd
godot --headless --path . --script res://tests/test_round_loop.gd
```
Each prints `PASS`/`FAIL` lines and a `RESULT` line; exit code 0 = all passed. No-window prototype (nothing to look at yet).

## Rules this follows
- **Timers:** float seconds, `+= 1.0 / 128.0` per tick (exact in binary). A duration ends on the **first tick at or after** it: freeze 15.0 s = tick 1920, round 100.0 s = 12800, plant 3.2 s = 410 (3.203125 s), defuse 10.0/15.0 s = 1280/1920, bomb 40.0 s = 5120.
- **Server-only:** `step()` and every transition run on the server. Clients read `get_snapshot_fields()` (phase, `time_left_s`, plant/defuse progress, score, winner) from snapshots and send `request_buy(slot, item_id)`; price and team come from the server table, never the client.
- **Floats:** all money and time math in floats; ints only for tick counters, round counts and the loss-streak index.

## Win conditions (spec Section 1 + review notes)
- LIVE: all T dead → CT; all CT dead → T; clock zero with no plant → CT (note (a)).
- PLANTED: defuse → CT; bomb timer → T; all CT dead → T. All T dead → round continues, CT must defuse (CS rule, switch `t_elim_after_plant_ends_round`, DECISION FOR JOAN).
- Ties (PROPOSED): plant completing on the clock-zero tick plants; defuse completing on the explosion tick wins; same-tick double wipe → CT in LIVE, T in PLANTED.

## DECISION FOR JOAN switches (`round_controller.gd` `DEFAULTS`)
| Key | Default | Alternatives |
|---|---|---|
| `bomb_timer_s` | 40.0 | 35.0, 45.0 |
| `max_rounds_per_half` | 12 (MR12) | 15 (MR15) |
| `max_cash` | 16000.0 | any |
| `loss_reset_mode` | `"reset"` | `"decrement"` |
| `plant_team_bonus_mode` | `"each"` ($300 per T) | `"split"` |
| `defuse_team_split_mode` | `"team"` ($600 / all CTs) | `"alive"` |
| `t_elim_after_plant_ends_round` | false | true |
| `buy_window_into_live_s` | 0.0 | e.g. 20.0 |
| `round_end_s` | 5.0 | any |
