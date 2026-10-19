# Prediction-loop prototype

One Godot 4.4.1 project, GDScript only, one process. Answers one question:
**does client prediction plus reconciliation feel instant and stay correct at 128 tick with 80 ms ping and 2% packet loss?**
Scope and locked decisions: `specs/prediction_loop_scope.md` (including "Decisions (Oct 17 2026, Joan)").
Out of scope: shooting, lag comp, snapshots/deltas, other players, culling, real sockets, Rust/C.

## Pinned Godot
Official **Godot 4.4.1-stable standard** Linux binary (not the distro package). See `../../movement_proto/README.md`
for the download commands. Below `godot` = `~/bin/godot-4.4.1`.

## Run (from this folder)
```bash
cd prototypes/prediction_loop
godot --headless --import                              # once

godot --headless --script res://tests/run_headless.gd              # all gates S1-S9 (~5 min)
godot --headless --script res://tests/run_headless.gd -- --quick   # short runs, ~30 s, for development

godot --path .                                         # play it (window)
```
Exit code is 1 if any gate fails. Every run is seeded, so the numbers repeat exactly (S8 timings vary with the machine).

## Playing it
WASD + mouse, Space / mouse wheel = jump (fresh press only). Debug keys:
`[` `]` ping 0/40/80/150/250 ms, `-` `=` loss 0/2/5/10%, `J` jitter on/off (**off by default**, turn on for the S4 playtest),
`K` flagged server teleport (client must snap), `G` 6-unit server shove (client must fade over ~100 ms),
`T` chase camera, `L` save recording + CSV to `recordings/`, `R` reset, `Esc` release mouse.
**RED** capsule = server, **BLUE** = client predicted, **GREEN** = the smoothed visual (what the camera follows; visible in chase cam).
The world is the floor, one tall box (x 300..364) and one 16-unit step (x -200..-104).

## How it fits together
```
../../movement_proto/movement.gd, input_cmd.gd, player_state.gd   the ONE shared sources (symlinked into scripts/)
scripts/ring_buffer.gd   256 entries of (seq, cmd, state), preallocated
scripts/fake_net.gd      40 ms each way, seeded 2% drop, optional +/-5 ms jitter, packet = current cmd + previous 2
scripts/fake_server.gd   runs each seq once in order, repeats the last cmd if all 3 copies are lost, state every 2nd tick
scripts/client.gd        predict -> reconcile (reset to server state for N, replay N+1..newest) -> ~100 ms smoothing
scripts/session.gd       THE tick: net -> server -> client predict/send -> client reconcile -> smoothing/CSV
scripts/main.gd          owns the 128 Hz tick, ghosts, HUD
scripts/recorder.gd      record (seed + commands + events) and replay
scripts/bots.gd          run, strafe, ideal bhop, sharp turns, wall hits, step hits, mixed
tests/run_headless.gd    the nine gates
tests/screenshot.gd      dev helper only (needs a display, e.g. xvfb-run): renders main.tscn to a PNG. Not a test.
```
`movement.gd` holds `step(state, cmd, world)` and the box/step collision (v1 = one box + one step, no slope), so the
client and the server call the same function. The symlinks keep it one file: **do not copy it**.

## Behaviours worth knowing
- Time is quantized to ticks. 40 ms one way is delivered on the first tick at or after 40 ms, i.e. 6 ticks (46.9 ms).
- The server does not step per wall-clock tick: it runs every consecutive command it holds (a burst after a late packet).
  The state after command N does not depend on when it ran, so a client that predicted N exactly matches the server's N.
- "Fully lost" = all 3 copies gone. The server notices when a newer packet arrives without it, repeats the last command in
  that slot, and the client corrects (that is the only normal source of a mismatch).
- Fresh-press jumping uses `prev_buttons` stored in the state, so replays and repeated commands never double-jump.
- Quantized yaw is 16 bits (about 0.0055 degrees per step).
- `sin`/`cos` are used for the wish direction. Same binary, same machine: identical. A future Rust/server build must
  prove the same numbers (parity test) or use a table.
- Live sessions keep the whole CSV in memory (about 13 KB per second).

## Crouch (Phase 1)
Duck key: **Ctrl or C** (hold). Half-height crouch, rules K1-K11 in `specs/goldsrc_movement.md` ("Crouch (PROPOSED, Oct 17 2026)"):
standing body 72.0 / eye 64.0, crouched body **36.0** / eye **32.0**. On the ground the duck takes 0.4 s (52 ticks at 128): the hull stays 72.0 and the eye
slides linearly 64.0 -> 32.0, then the hull drops to 36.0. In the air duck is instant and lifts the feet 18.0 (crouch-jump). Ducked speed is 0.333 of normal
(250.0 x 0.333 = 83.25 u/s). Unducking needs headroom (it waits under the overhang). The three tunable numbers are switches in `movement_proto/movement.gd`
(`DUCK_TIME_S`, `DUCK_SPEED_FACTOR`, `AIR_DUCK_LIFTS_FEET`); they are DECISION FOR JOAN items C6-C8.
`crouch_test_world()` (test-only) adds a 40.0-high overhang and 40.0-high cover; `default_world()` is unchanged. A "crouch" bot is in `bots.gd`.
Tests: `movement_proto/tests/test_parity_crouch.gd`, `test_crouch_step.gd`, and `tests/test_pre_crouch_identical.gd` here (no duck pressed = bit-identical to before).

## Remote players (Phase 3)
Other players arrive in snapshots and are drawn `INTERP_TICKS` behind (default **4** = 31.25 ms; keys **2 / 3 / 4** in the demo change it live). Rules: `specs/remote_interp_v0.1.md`.
- `scripts/net/interp_buffer.gd`: per-slot ring of 16 samples, linear position, shortest-arc angles, hold when starved (`EXTRAP_MAX_TICKS = 0.0`), 4-tick blend back, snap on respawn or a jump over 64 units, removal. Checked against an independent Python implementation (`tools/interp_ref.py`, 1,000 random streams).
- `scripts/net/remote_paths.gd`: scripted remotes (server side only): linear with smooth turns, circle, strafe jiggle, peek, crouch toggle, bhop chain (driven by `movement.gd`), teleport, spawn/despawn.
- The client clock: `server_tick_estimate = tick + offset`, offset moves at most 0.0625 tick per tick; `get_render_tick()` = estimate - `INTERP_TICKS` (seam D8; `Client.render_tick` for now).
- Demo (`godot --path .`): ORANGE capsules are the remotes as drawn; thin white ghosts are their true position now (key **X**); key **0** toggles the remotes.
- Measurements for Joan (options only): `research/interp_delay_measurements.md`. Run: `godot --headless --script res://tests/run_remote.gd` (about 15 min; `-- --quick` for a short run).

## NetClient (Phase 4)
`scripts/net/net_client.gd` (`extends Node`) is the one client-side network object. The crosshair prototype from `gamebuilder/crosshair` is brought in **unchanged** (`prototypes/crosshair/`, never edit it) and used through symlinks in `scripts/hud/`.
| Call | What it gives |
|---|---|
| `signal snapshot_received(snap: Dictionary)` | once per NEWEST decoded snapshot; keys `server_tick` (int), `accuracy` (float), `punch_pitch` (float, deg, + = up), `punch_yaw` (float, deg), `move_state` (int 0 stand, 1 crouch, 2 air, 3 run). Dequantized wire values straight from the HUD block, never via interpolation. An older snapshot arriving late does not emit. |
| `get_latest() -> Dictionary` | the last emitted dictionary; `{}` before the first snapshot |
| `send_input(cmd: InputCmd)` | predict this command now and send it (standalone mode) |
| `get_player_state() -> PlayerState` | predicted own state (gameplay) |
| `get_visual_position() -> PackedFloat64Array` | smoothed own position `[x, y, z]` |
| `get_remote_players() -> Array` | `{slot, x, y, z, yaw, pitch, stance, duck, alive}` at the render tick |
| `get_render_tick() -> float` | fractional server tick remote players are drawn at (seam D8) |
| `get_stats() -> Dictionary` | `rtt_ms`, `snapshot_loss`, `corrections`, `starved_ticks`, `bytes_per_s`, `snapshots`, `dropped_missing_baseline` |
| `signal remote_removed(slot)` | a remote disappeared |
Two ways to build it: `setup(world, endpoint)` (standalone: owns a `Client`, talks to an endpoint with `send(payload)` / `poll()`; this is what a real client process does in Phase 6) or `adopt(client)` (reads the `Client` that an in-process `Session` drives; the demo does this). The server fills the HUD block from `SnapshotSender.stub_hud`: **STUB until Devin's `recoil.gd` plugs in (`spread_for_next_shot`)**: stand / crouch 0.0055, run 0.0540, air 0.1200, punch 0.0.
Latency stand -> run -> crosshair color at 80 ms (jitter off): 12 to 13 ticks (93.8 to 101.6 ms). At 0 ms the fixed tick order gives 2 to 3 ticks (the handout expected 0 to 2; see the progress log).
Demo: `godot --path .` now draws the crosshair from the NetClient's real snapshot fields.

## Visibility culling (Phase 5)
The server sends an enemy to a viewer only if a ray from the viewer's eyes to a point on the enemy is not blocked by a box (rules and every PROPOSED choice: `specs/visibility_culling_v0.md`). Hidden enemies are simply not in the snapshot bytes. Teammates are always sent.
- `scripts/net/visibility.gd`: strict slab ray test (touching a face or edge counts as clear), target points per stance (stand head 66.0 / chest 54.5 / feet 2.0 / shoulders 58.0 at +-12.0; crouched 30.0 / 27.25 / 1.0 / 29.0), margin **8.0 sideways, 0 vertical** (a vertical margin would let a crouched head peek over 40-unit cover), look-ahead = rtt / 2 + one snapshot interval, at most 60 rays per pair. Independent Python reference `tools/los_ref.py` (seed 7501, 5,000 configurations).
- Seam D4 (Devin's hit registration and analyzer): `server.sent_mask_for(viewer_slot, tick)` = u16 mask in force at that tick (bit n = slot n was sent), **-1** outside the last `SENT_MASK_HISTORY_TICKS = 640` ticks; `sound_only_mask_for` is 0 in v0.
- Seam D5: `server/interfaces/evidence_sink.gd` keeps `vis_change(...)` records IN MEMORY ONLY (a change record when a mask changes, keyframes at tick 0 and every 1,280 ticks and at round start). No file is written; the `.fpev` writer belongs to the Rust layer later.
- Off by default in the headless harness (`server.vis_enabled = false`) so the earlier gates see every remote; on in the demo. Demo key **V** toggles culling and the overlay labels each remote **sent** or **CULLED**. Two stand-ins sit behind the tall box (slot 11 enemy, slot 12 teammate).
- Tests: `tests/test_visibility.gd`, `tests/run_wallhack_bait.gd`.

## Two processes (Phase 6)
The same server and `NetClient` over REAL sockets, as two OS processes. Packet layout: `specs/snapshot_format_v0.1.md` "Packets". Default transport is **ENet** (C10: one channel, unsequenced unreliable); `--transport udp` selects raw `PacketPeerUDP`.
```bash
cd prototypes/prediction_loop
godot --headless --path . -- --server --port 27015                      # terminal 1: headless server
godot --path . -- --client --connect 127.0.0.1:27015                    # terminal 2: client window
godot --headless --path . -- --client --connect 127.0.0.1:27015 --bot mixed --ticks 7680   # headless bot client (1 minute)
../../tools/run_loopback_pair.sh 1        # spawns both headless, 1 minute, prints both exit codes, stats and the verdict
../../tools/run_loopback_pair.sh 10       # the 10-minute soak (76,800 ticks)
../../tools/run_loopback_pair.sh 10 --shim 80,0.02      # 80 ms / 2% over REAL sockets, no root (in-app shim)
```
Options: client `--shim PING_MS,LOSS[,JITTER_MS]` (seeded; the shim delivers on the first tick at or after the delay, so 40 ms each way = 6 ticks), `--transport enet|udp`. Server `--interp N` (the server dictates C1 to the client in WELCOME), `--exit-on-bye`, `--max-seconds N`. The server prints its switch values (C1 to C12) at start and a `SERVER_STATS` line every 10 s.
Real time only decides HOW MANY ticks run (an accumulator on `Time.get_ticks_usec()`; more than 8 ticks behind drops the backlog and counts an overrun); every tick still uses `1.0 / 128.0`.

Security notes: the server binds to **127.0.0.1** by default; `--bind-all` opens it to the network (LAN playtest). A HELLO must carry a cookie from the server's CHALLENGE before a slot exists. Each client has a command budget (1 per tick, burst 8; excess dropped and logged RATE_ABUSE), so a client that sends 8x the commands gains nothing. Packets are **not encrypted yet** (deferred pending DTLS research). Tests: `tests/test_cmd_budget.gd` (speedhack probe), `tests/test_hostile.gd`.

### netem recipe (Joan runs it himself; nothing in this repo runs sudo)
```bash
sudo tc qdisc add dev lo root netem delay 40ms loss 2%            # loopback: 40 ms each way = 80 ms RTT, 2% loss each way
sudo tc qdisc change dev lo root netem delay 40ms 5ms loss 2%     # add +-5 ms jitter (S4 playtest)
tc qdisc show dev lo                                              # check
sudo tc qdisc del dev lo root                                     # ALWAYS remove when done
```
**Warning, in plain words:** this slows ALL loopback traffic on the machine (not only this game) until you remove it, and jitter can reorder packets (a good test). **Always run the last line when you are done.** On a LAN, apply it to ONE machine's real interface (`ip -br link` shows the name, for example `enp5s0`): `sudo tc qdisc add dev enp5s0 root netem delay 80ms loss 2%` adds 80 ms to that machine's outgoing packets only; remove it with `sudo tc qdisc del dev enp5s0 root`.

## Dedicated server (Phase 7)
`tools/run_dedicated_server.sh --port 27015` starts the headless server. It runs `server/server_tick.gd`: one
128 Hz tick in the fixed order of `specs/server_tick_v0.1.md` (drain, execute commands, round hooks, lag-comp
samples, shots, per-viewer snapshots, stats). Up to 16 clients; each gets its own culled snapshot. Devin's
modules plug in through `server/interfaces/` (lag-comp sink, shot processor, weapon state, round hooks,
evidence sink); defaults are stubs. `tools/run_loopback_pair.sh 2` runs the server and a bot client for 2 minutes.
Tests: `tests/test_server_tick.gd`.

## Bots (Phase 8)
`--bots N` on the dedicated server spawns N server-side bots (slots 0 to N-1, team 2; humans are team 1) on the built-in
routes in `server/bots/routes/*.json`, cycling: `step_loop` (on and off the 16-unit step), `box_circuit` (around the tall
box), `jump_onto_step` (fresh jump press before the step), `crouch_overhang` (duck under the 40-high overhang and unduck),
`cover_peek` (stand / duck behind the 40-unit cover every 64 ticks, so culling flips). With bots the server world is
`crouch_test_world()`; a client that wants to walk there runs `--world crouch`.
A waypoint is `{x, z, arrive_radius (16.0), jump, duck, wait_ticks}`; a route is a list plus `loop`. The driver
(`server/bots/bot_driver.gd`) only reads its own `PlayerState` and its route and feeds `ClientSlot.enqueue_local()`, the
queue that network INPUT feeds too. No aim, no shooting, no decisions. Tests: `tests/test_bots.gd`. Two-process run:
`tools/run_loopback_pair.sh 2 --bots 10 --bot peekview --shim 80,0.02`.
