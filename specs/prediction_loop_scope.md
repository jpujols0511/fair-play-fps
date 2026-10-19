# Prediction-Loop Prototype — Scope (private)

Status: scope only. No prototype code written yet. Private folder only; nothing goes in the public repo.
Context: `netcode_design.md` (step 1 of "next steps", decisions D2, D3, D7, D13) and `goldsrc_movement.md` (movement rules + Python reference sim).

## 1. What this prototype is for
One question: **does client prediction + reconciliation feel instant and stay correct at 128 tick with 80 ms ping and 2% packet loss?**
It's a single Godot project. A fake "server" and a "client" both run on one machine, in one process, joined by a fake network that adds delay and drops packets. No real networking, no other players, no shooting.

## 2. What it INCLUDES
1. **Input handling.** Every tick (128/sec, Godot physics tick set to 128) the client reads keys (forward/back/left/right, jump, duck) and mouse yaw/pitch into an **input command**: sequence number, client tick, buttons bitmask, view angles, tick length. Angles get quantized the same way they would be on the wire, so client and server see identical numbers.
2. **Shared movement code.** One GDScript file (`movement.gd`) holding the GoldSrc rules from `goldsrc_movement.md`: friction, ground accel, the 30 u/s air wish-speed cap, jump (~268 u/s), split-half gravity, jump stamina, bhop cap. Same function, called by both client and server: `step(state, cmd) -> state`. Pure function, no Godot physics bodies, no `delta` from the frame, only the fixed tick length. Flat floor plus one wall/step box for collision (simple custom box tests, not CharacterBody3D).
3. **Prediction.** Client applies each command to its local player at once and stores `(seq, cmd, resulting state)` in a ring buffer (256 entries, ~2 s).
4. **Reconciliation.** When a server state arrives, tagged "last processed input = N":
   - compare it to the client's stored state for N;
   - if they match within tolerance → drop entries ≤ N, done;
   - if not → reset to the server state, **replay every stored command after N** through `movement.gd`, then drop old entries. At 80 ms ping that's about 10–14 replayed ticks per correction.
5. **Smoothing.** The *visual* position is kept separate from the *simulated* position. After a correction, the visual offset (old minus new) fades out over ~100 ms (≈13 ticks). Errors over 64 units (or a teleport/respawn flag) snap at once instead.
6. **Simulated network layer** (`fake_net.gd`). Two one-way channels, client→server and server→client, each with:
   - 40 ms one-way delay (= 80 ms round trip), plus an optional ±5 ms jitter toggle;
   - 2% random drop, from a **seeded** random generator so runs repeat exactly;
   - client packets carry the current command + the previous 2 (design D3), so a single dropped packet loses nothing;
   - server sends its authoritative player state every 2nd tick (64/sec, design D4) — a plain full state, not a snapshot/delta.
   Settings exposed as sliders/presets: ping 0/40/80/150/250, loss 0/2/5/10%.
7. **Fake server** (`fake_server.gd`). Receives commands, executes each sequence number exactly once in order, runs `movement.gd`, records the result. If a command never arrives (all 3 copies lost) it repeats the last command for that tick — same rule the real server will use — and the client reconciles.
8. **Debug view.** Three markers: server position (red ghost), client predicted (blue ghost), smoothed visual (the player). On-screen: current error, corrections/sec, replay length, loss counters. Plus a CSV log per tick.
9. **Recording/replay.** Input commands + seed saved to a file so any run can be re-played headless and compared.

## 3. What it EXPLICITLY EXCLUDES
- Hit/damage prediction, weapons, recoil, shooting of any kind.
- Lag compensation / hitbox rewind.
- Snapshots, delta compression, bit-packing, snapshot history.
- Other players and interpolation of remote entities.
- Server-side culling / visibility.
- Rust, gdext, C — **GDScript only**. (The Rust port comes after we've measured.)
- Real ENet/UDP sockets, NAT, connection handling, encryption.
- Anti-cheat checks (input-rate flags etc.) beyond counting commands for the log.
- Real maps, slopes, crouch-jump edge cases, ladders, water, edge friction.
- Demo file format (the replay file here is a throwaway test format).

## 4. Proposed file/scene layout
Lives in the private folder, e.g. `/workspace/private/fair-play-fps/prototypes/prediction_loop/` (a standalone Godot 4 project — not the public repo).
```
project.godot              physics_ticks_per_second = 128, physics interpolation off
main.tscn                  root scene
  Main (Node3D)            main.gd: wires everything, owns the tick order
    World (Node3D)         floor + one box obstacle (just meshes; collision is in movement.gd)
    FakeServer (Node)      fake_server.gd
    FakeNet (Node)         fake_net.gd
    Client (Node)          client.gd: input → cmd → predict → reconcile → smooth
      PlayerVisual (Node3D) + Camera3D
    ServerGhost / PredictedGhost (MeshInstance3D)
    DebugHUD (CanvasLayer) debug_hud.gd
scripts/
  movement.gd              the shared pure movement step (GoldSrc rules)
  move_config.gd           cvars: sv_accelerate 10, sv_airaccelerate 10, sv_friction 4,
                           sv_gravity 800, sv_stopspeed 100, maxspeed 250 (knife), jump 268
  input_cmd.gd             command data + quantization
  player_state.gd          position, velocity, on-ground, stamina, flags
  ring_buffer.gd           fixed-size history
tests/
  run_headless.gd          seeded bot-input runs, prints pass/fail
  parity_check.gd          compares movement.gd against goldsrc_movement_sim.py outputs
recordings/                saved input+seed runs and CSV logs
```
Tick order each 128 Hz tick (owned by `main.gd`, never left to Godot's node order): FakeNet delivers due packets → FakeServer steps → Client reads input, predicts, sends → Client handles any arrived server state (reconcile) → smoothing → HUD.

## 5. Success criteria
Measured in headless seeded runs (scripted bot inputs: running, strafing, chained bhops, sharp turns, wall hits) plus a human playtest.

| # | Criterion | Pass if |
|---|---|---|
| S1 | Determinism | Same commands + same start → client and server states bit-identical, 0 ms ping, 10,000 ticks. Same seed → identical CSV twice. |
| S2 | Parity with reference sim | `movement.gd` matches `goldsrc_movement_sim.py` on its test cases within 0.01 units / 0.01 u/s (e.g. top bhop ~341 u/s at 128, strafe gain ~202 u/s/s at 250). |
| S3 | Accuracy under 80 ms / 2% loss | After each reconcile, predicted vs server position error is **0.0 when no command was fully lost**; overall 99th-percentile error < 1 unit; max < 8 units. |
| S4 | No visible jitter | Smoothed visual moves no more than 1 unit per tick beyond what the simulated motion explains; no oscillation (error never flips sign 3+ times in 100 ms); human playtest: no rubber-banding felt at 80/2%. |
| S5 | Input feels instant | Visual responds on the same tick the key is read (0 ticks added latency from netcode). |
| S6 | Loss handled | At 2% loss, fully lost commands (all 3 copies gone) ≈ 0.0008% of ticks; at 10% loss still stays stable, just more corrections. |
| S7 | Big corrections snap | A forced server teleport snaps within 1 tick, no 100 ms slide. |
| S8 | Cost | Replaying up to 32 ticks (250 ms ping) takes < 1 ms in GDScript on the dev machine; frame time stays flat at 240+ FPS. |
| S9 | Replay | A saved recording replays headless and reproduces the same final state exactly. |

If S8 fails, that's the measured evidence that triggers the Rust port (design doc build order).

## 6. Key decisions
- One process, fake network, seeded randomness — repeatable and debuggable before any real sockets.
- Movement is a pure, frame-rate-independent function shared by client and server; no Godot physics for the player.
- Server state every 2nd tick (64/sec), client sends current + 2 previous commands every tick, matching the design doc.
- 100 ms smoothing, snap above 64 units; simulated and visual position kept apart.
- Server fills missing commands by repeating the last one.
- GDScript only; Rust is chosen later by measurement (S8), not up front.
- Floating-point caveat: GDScript uses 64-bit floats; the Rust/server version must match, so the parity test (S2) is the gate before porting.

## 7. Open questions
- Collision: is one box enough, or add a step/slope to test step-up? (Default: one box + one step.)
- Should jitter be on by default? (Default: off for S1–S3, on for S4 playtest.)
- 64-unit snap threshold and 100 ms window are first guesses — tune in playtest.

---

## Decisions (Oct 17 2026, Joan)

*Appended by Game Builder on Joan's instruction. Nothing above was changed. These decisions are **locked**.*

**The one question (unchanged):** does client prediction plus reconciliation feel instant and stay correct at 128 tick with 80 ms ping and 2% packet loss?

**Setup (unchanged):** one process, a fake server (`fake_server.gd`), a fake network (`fake_net.gd`), and seeded randomness, so every run can be repeated exactly.

**Three ghost markers:**
- **Red:** server position.
- **Blue:** client predicted position.
- **The player itself:** the smoothed visual, which is what you see.

**Gates S1–S9.** The numbering is the same as the Section 5 table above, so no remapping is needed. The full pass lines in Section 5 still apply.

| Gate | Short name | Pass line (from Section 5) |
|---|---|---|
| S1 | Determinism | Bit-identical client and server over 10,000 ticks at 0 ms. Same seed gives the same CSV. |
| S2 | Parity with the Python sim | Within 0.01. Exact values: top bhop **340.72** at 128 tick, strafe gain **201.71** u/s per second at 250 (Section 5 shows these rounded as ~341 and ~202). |
| S3 | Accuracy | p99 error **< 1 unit**. Also: 0.0 after a reconcile when no command was fully lost, and max < 8. |
| S4 | No visible jitter | As in Section 5. |
| S5 | Zero added input latency | The visual responds on the same tick the key is read. |
| S6 | Loss stability | Stable at 2% and at 10% loss. |
| S7 | Snap on teleports | Within 1 tick, no 100 ms slide. |
| S8 | Replay cost | Replaying 32 ticks takes **< 1 ms** in GDScript. If it fails, that is the Rust trigger. |
| S9 | Headless replay | A recording replays headless to the same final state. |

**Fixed tick order (unchanged from Section 4).** `main.gd` owns the tick, not Godot's node order:
1. FakeNet delivers due packets.
2. FakeServer steps.
3. The client reads input, predicts and sends.
4. The client reconciles against any server state that arrived.
5. Then smoothing and the HUD.

**Decision 1: jitter.** FakeNet jitter (±5 ms) is **OFF by default** until gates S1–S3 pass. It is then turned **ON for the S4 playtest**. This closes open question 2 in Section 7.

**Decision 2: collision.** v1 collision is **one box plus one step, no slope**. This closes open question 1 in Section 7.

Still open from Section 7: the 64-unit snap threshold and the 100 ms smoothing window. They remain first guesses, to tune in the playtest.
