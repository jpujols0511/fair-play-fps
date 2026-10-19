# Server tick v0.1 (PROPOSED)

*Written by Claude, Phase 7 of the build plan. PROPOSED; Joan and Game Builder have not approved it. Public as of Oct 19 2026 (CD-r9).*
Context: `specs/netcode_design.md` Sections 0, 3, 5, 6, 9, 12.3; `specs/prediction_loop_scope.md`; Devin's tick order (movement, then history, then shots).

## Summary (plain words)
The server runs one fixed tick, 128 times a second, and every tick does the same seven things in the same order. It reads each player's commands from a queue, runs them through the one shared movement code, tells the hit-registration side where everyone is, handles shots, and every second tick builds one snapshot per player (only what that player may see). Players and bots use the same queue and the same movement code; a bot is just a player with no network. Everything the shot code needs (the ctx dictionary) is filled by the server from its own state, never from what a client claims.

## The tick order (PROPOSED)
At server tick T (code: `server/server_tick.gd`, `step()`):

```text
   transport                     per-client input queues (client_slot.gd)
      |  1) DRAIN: dedupe by seq, drop seq <= last executed, queue cap 64,
      |            malformed -> INPUT_REJECT reason 4 (in memory)
      v
   2) EXECUTE commands, slots ascending: every consecutive command a slot holds, at most
      each executed command (real or filled-in) costs 1.0 from the per-client command budget: burst `CMD_BURST` = 8.0, refill `CMD_REFILL` = 1.0 per tick (C11, CD-r2). A missing seq with a newer one present -> repeat the last command
      (BTN_ATTACK stripped, counted). round_hooks.allow_movement(slot, T) gates movement.
      A command more than `CMD_WINDOW` = 64 ahead of the next expected seq is dropped and counted; logged RATE_ABUSE = INPUT_REJECT reason 3 (one stored record per second, never kick).
      v
   3) ROUND HOOKS  round_hooks.on_tick(T)                                   (null stub; the round loop plugs in)
      v
   4) PUSH LAG-COMP SAMPLES for EVERY slot (seam D1), after ALL movement, before ANY shot
      v
   5) SHOTS: for each command executed this tick that carries BTN_ATTACK (64),
      shot_processor.process_shot(ctx)  (seam D2; Devin's hitreg plugs in)
      v
   6) SNAPSHOTS, on snapshot ticks only (T % SNAPSHOT_EVERY_TICKS == 0, C4):
      visibility per viewer (Phase 5) -> per-client snapshot (delta vs the client's ack, Phase 2;
      HUD block from seam D3) -> handed to the transport
      v
   7) STATS: tick work time (microseconds), overruns, per-client rtt / loss / queue depth, a one-line summary every 10 s
```
`ServerTick.step()` does steps 2 to 6 and returns `{slot: snapshot bytes}`; its owner (`server_main.gd`) does step 1 (it feeds `enqueue_net` / `enqueue_local`) and step 7 (stats) and sends the snapshots. Real time only decides HOW MANY ticks run; every tick uses `1.0 / 128.0`.

## Seams (every one is an interface with a null or recording stub; the owner of the real module plugs in)
| # | Interface (file) | Called when | Stub | Owner of the real module |
|---|---|---|---|---|
| D1 | `server/interfaces/lagcomp_sink.gd` `push_sample(slot, tick, x, y, z, yaw_deg, stance, alive)` | step 4, every slot, every tick | records the last 26 samples per slot | Devin `hitreg/lagcomp_history.gd` |
| D2 | `server/interfaces/shot_processor.gd` `process_shot(ctx) -> Dictionary` | step 5, per executed ATTACK command | returns `{"stub": true}`, counts | Devin `hitreg/hitreg.gd` |
| D3 | `server/interfaces/weapon_state_provider.gd` `hud_fields(slot, move_state)` | step 6, own-player HUD block | **STUB**: AK first-shot spread by move state (stand / crouch 0.0055, run 0.0540, air 0.1200), punch 0.0 | Devin `weapons/recoil.gd` |
| D4 | `ServerTick.sent_mask_for(viewer, tick)`, `sound_only_mask_for` | Devin's hit registration and analyzer | **real** (Phase 5) | me (consumer: Devin) |
| D5 | `server/interfaces/evidence_sink.gd` `vis_change`, `input_reject` | steps 1, 2, 6 | in-memory lists only, no file | the Rust layer writes `.fpev` later |
| (round) | `server/interfaces/round_hooks.gd` `allow_movement`, `on_tick`, `on_round_start` | steps 2, 3 | always allow, nothing | the round loop (not mine) |
D6 (`movement.gd` stance / eye / move state), D7 (`frame.gd`), D8 (`get_render_tick()` travelling as `view_tick` in each command) are used by the tick but live elsewhere.

`ctx` for D2 has exactly: `now` (int tick), `tick_rate` (float), `shooter_slot`, `eye_x`, `eye_y`, `eye_z` (spec frame, from the shooter's server state AFTER this command, eye from `eye_height`), `view_pitch_q`, `view_yaw_q` (the command's values, unconverted) and `view_pitch_deg`, `view_yaw_deg` (spec frame via `frame.gd`), `cmd_seq`, `claimed_view_tick` (float, the command's `view_tick`), `rtt_ms` (float, server-measured), `teams` (Array of int per slot, 16 entries), `sent_mask_for` (a Callable to D4). **No seed, no spread, no client-claimed hit or position.** The spread seed is chosen by the server inside Devin's module when the shot is processed (crosshair note (g)).

## Reject reasons (evidence spec Section 2.5)
| Reason | Meaning | Who logs it |
|---|---|---|
| 1 | claimed time out of range | Devin (hit registration) |
| 2 | view change too large (J15) | Devin |
| **3** | **RATE_ABUSE** (input budget): a command more than 64 ahead of the next expected seq (forged or runaway seq, or a client sending far more than 1 command per tick) | server tick (this phase). Log only: **a client is never kicked for it** |
| **4** | **malformed** packet (bad protocol id, wrong size, cmd_count over 3) | server main (this phase) |
All in memory (`EvidenceSink.input_rejects`), no file. A client silent for 5 s is dropped (PROPOSED); that is not a reject.

## Switches
C11 command budget: `CMD_BURST` 8.0, `CMD_REFILL` 1.0 per tick (CURRENT_DECISIONS CD-r2); `CMD_WINDOW` 64 and `CMD_RESYNC_TICKS` 128 are PROPOSED. The old 64-entry queue cap and the 136 / 128 log-only rate limit are gone.

## Dedicated server
```bash
tools/run_dedicated_server.sh --port 27015 --interp 4 --bots 0
# = ~/bin/godot-4.4.1 --headless --path prototypes/prediction_loop -- --server --port 27015 --interp 4 --bots 0
```
Prints the Godot version, the switch values (C1 to C12) and a stats line every 10 s. The tick rate is fixed at 128 (`Movement.TICK_RATE`); there is no `--tick` flag. The server binds to loopback unless `--bind-all` is given. No sudo and no systemd install (a commented user-unit example is in the prototype README for Joan, if he wants it).
