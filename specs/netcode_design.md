# Fair Play FPS — Netcode Design (v0.1, private)

Status: design draft. Nothing here is built yet. Research was read-only on public sources; no Valve or GPL code was copied. Every idea below is described in my own words so we can write fresh code. PRIVATE — not for the public repo.

Read with: `specs/goldsrc_movement.md` (movement rules), `../PERF_OPTIMIZATION.md` (performance plan), `../REA_RE_WORKFLOW.md` (legal/RE rules).

---

## 0. The big picture in one paragraph

The **server is the only source of truth**. Players' computers send only *what buttons they pressed and where they aimed* (an "input command"), never "I am here" or "I hit him." The server runs the game at a fixed **128 ticks per second**, then sends each player a compact **snapshot** of only the things that player is allowed to see. The player's computer **predicts** its own movement instantly so it feels lag-free, and quietly **corrects** itself when the server disagrees. When someone shoots, the server **rewinds** the other players to where the shooter saw them and checks the hit. Because the server decides everything and hides what you can't see, the most common cheats (speedhacks, teleports, wallhacks, fake hits) have nothing to grab onto. That is the anti-cheat core.

---

## 1. Decisions at a glance

| # | Decision | Value |
|---|---|---|
| D1 | Authority | Server-authoritative for movement, shots, damage, economy, round state. Client is never trusted. |
| D2 | Simulation tick rate | **128 Hz fixed**, locked per server, not a player setting. |
| D3 | Client → server | Input commands every tick, each packet also repeats the last 2 commands (survives packet loss). |
| D4 | Server → client snapshot rate | **64/sec by default** (every 2nd tick), **128/sec** option for LAN/tournament servers. |
| D5 | Snapshot encoding | Quake 3–style delta against the last snapshot the client confirmed receiving; quantized numbers; bit-packing. |
| D6 | Movement | Our own deterministic movement code (from the GoldSrc spec), run identically on client and server. No Godot physics bodies for players. |
| D7 | Prediction | Client predicts its own player only; replays unconfirmed inputs after each correction. |
| D8 | Other players | Shown with interpolation, ~2 snapshots behind (~31 ms at 64/sec). No extrapolation. |
| D9 | Lag compensation | Server rewinds hitboxes to the shooter's view time. **Max rewind 200 ms** (not 1.6's 500 ms). |
| D10 | Visibility culling | Server sends an enemy only if a precomputed visibility check + line-of-sight test says they could be seen (with a small safety margin). |
| D11 | Demos | Server records authoritative demos of every match (our own format). Client POV demos are optional and can't be trusted for anti-cheat. |
| D12 | Languages | GDScript for gameplay/UI; **Rust (godot-rust/gdext)** for netcode core, snapshot encoding, lag comp, visibility, demos; C only behind Rust, only where a profiler proves it's needed. |
| D13 | Transport | UDP via ENet (ships with Godot) for v1; our own packet layer later only if measurements demand it. |

---

## 2. Tick rate: why 128

The movement spec showed that with the same mouse movement, **128 tick gives about 75% more air-strafe speed gained per second than 64 tick** (202 vs 115 u/s per second at 250 u/s). Top chained-bhop speed also rises (~341 vs ~303 u/s). So tick rate is not just "smoothness" — it changes how the game *plays*.

Why 128:
- **Skill expression.** Air-strafing and bhop are core to the 1.6 feel we want. 128 makes them rewarding and consistent. 1.6 servers really ran near 100 fps physics, so 128 is closer to the "real" feel than 64.
- **Fairness.** One locked rate means everyone plays the same physics. No "my server feels different" arguments.
- **Shot accuracy.** Each tick is 7.8 ms instead of 15.6 ms, so lag compensation can line up shots more precisely.
- **Anti-cheat.** Finer ticks = finer evidence. Impossible inputs (perfect strafes every tick, inhuman flicks) stand out more clearly.

Costs and how we handle them:
- Twice the server CPU of 64 tick → movement and lag comp are in Rust, and matches are small (5v5, max 12 players).
- More bandwidth → we *simulate* at 128 but *send* snapshots at 64/sec by default (D4). Delta compression keeps each snapshot small. Client inputs are tiny, so sending those at 128 is cheap.
- Requires high frame rates to feel right → the client runs physics at 128 regardless of frame rate, and draws smoothly in between (see PERF doc: interpolation toggle, FPS cap per refresh rate).

Rule: **all gameplay numbers are defined per second, never per tick**, except where the spec says the per-tick behavior is the point (air-strafe). If we ever change tick rate, the movement spec table is the reference for what changes.

---

## 3. Pillar 1 — Client prediction and reconciliation (QuakeWorld approach)

**The problem.** If your computer waited for the server before moving you, every key press would lag by your ping (e.g. 40 ms). It feels like moving through mud.

**The QuakeWorld idea (1996).** Carmack's QuakeWorld let the client run the *same movement code* as the server on its own inputs, immediately, and then correct itself when the server's answer arrived. Every modern shooter does a version of this.

**How ours works, step by step:**
1. Every tick the client reads input (keys, mouse angles) into an **input command** with a sequence number.
2. It sends that command (plus the previous 2, for loss protection) to the server.
3. It immediately runs our movement code on that command and draws the result. It saves the command in a "not yet confirmed" list.
4. Each snapshot from the server says: "the last command I processed from you was #N, and here's where you ended up."
5. The client throws away commands up to #N, **resets its player to the server's position**, then **replays every unconfirmed command** on top. If prediction was right (the usual case), nothing visibly changes.
6. If the result differs by a small amount, the client smooths the visual position over ~100 ms instead of snapping. Big differences (teleport, death) snap.

**Requirements this puts on the movement code:**
- Must be **deterministic**: same inputs + same start = same result on client and server. So: our own code, fixed tick, no Godot physics bodies for players, no frame-rate-dependent math.
- Must be cheap enough to replay ~10–30 ticks in one frame (ping 80–240 ms at 128 tick). Rust core makes this trivial.
- Our Python reference sim is the "truth" for testing: the GDScript/Rust version must match its numbers (the existing KERNEL_SHA256 parity check idea).

**What we predict:** your own movement, jump, crouch, your weapon animations/recoil view kick, and your shot sound/muzzle flash (cosmetic only). **What we never predict:** hits, damage, kills, other players. Hit markers come from the server.

**Anti-cheat value:** the server re-runs every input itself. A speedhack or teleport just gets corrected back. Input commands that arrive too fast (more than 128/sec over time) are flagged — classic speedhack signature.

---

## 4. Pillar 2 — Snapshots and delta compression (Quake 3 technique)

**The problem.** Sending the whole world to every player 64 times a second is wasteful. Most things don't change between snapshots.

**The Quake 3 technique (learned from reading, not copied):**
- The server keeps a short history of the snapshots it sent each client (we'll keep 32).
- The client tells the server, in each packet, the number of the **last snapshot it received**.
- The server builds the new snapshot as a **difference (delta) from that confirmed snapshot**: only fields that changed are sent, with a tiny "changed/unchanged" bit for each field.
- If a packet is lost, it doesn't matter — the next one is still a delta from something the client definitely has. No resending, no waiting. If the client falls too far behind (confirmed snapshot older than our history), the server sends a full snapshot.
- Numbers are **quantized** (rounded to just enough precision) and **bit-packed** (a 0–100 health value uses 7 bits, not 32).

**Our snapshot contents:**
- Header: snapshot number, server tick, last input command processed, base snapshot number.
- Your own player state (full precision: position, velocity, stamina timer, ducking, on-ground — everything prediction needs).
- Visible entities only (see Pillar 4): other players (position, view angles, animation state, weapon), grenades, dropped weapons, bomb.
- Events since last snapshot (sounds, gunshots, kills) — sent until confirmed.

**Precision plan (first guess, tune by testing):** positions to 1/8 unit, angles 16 bits, velocities to 1/8 u/s (own player only). Target size: under 400 bytes typical, under 1,200 bytes worst case (fits one UDP packet, no splitting).

**Anti-cheat value:** the client only ever gets a minimal, server-chosen view of the world. Fields the client doesn't need (enemy money, enemy health exact values, hidden enemies) are never sent.

---

## 5. Pillar 3 — Lag compensation (Source behavior)

**The problem.** With prediction and interpolation, you see enemies slightly in the past (your ping + the interpolation delay). If the server checked your shot against where enemies are *now*, you'd have to "lead" every shot by your ping. That feels broken.

**The Source / GoldSrc idea (from Valve's public docs and ReHLDS behavior):**
- The server stores, for every player, a history of their hitbox positions for each tick.
- When a shot command arrives, the server calculates **what moment that shooter was looking at** (the time in the command, minus their interpolation delay).
- It temporarily **moves every other player back** to where they were at that moment, checks the shot ray against their hitboxes, then puts everyone back.
- Result: if it was on the enemy on your screen, it hits. Downside known from every Source game: the victim sometimes dies "behind a wall" because on the shooter's screen they weren't behind it yet.

**Our decisions:**
- **History:** 200 ms at 128 tick = ~26 frames of hitbox data per player. Kept in a fixed-size ring buffer in Rust (no allocation during play).
- **Max rewind 200 ms.** 1.6/ReHLDS allow up to 0.5 s. We cap lower because a big rewind window is exactly what "backtrack" cheats exploit (lying about shot time). Players with ping above ~170 ms will need to lead slightly — acceptable for a hardcore competitive game; regional servers.
- **The server, not the client, picks the rewind time**, based on the measured ping and the client's interp setting (which the server knows, because we fix it). The command's claimed time is only accepted within ±1 tick of what the server expects. Anything else is clamped and logged.
- **Interpolate between stored ticks** when the target time falls between two (sub-tick accuracy).
- **Hitboxes, not models:** simplified capsules/boxes per bone, same on server and client. Headshot box is fixed size per stance.
- **Only player hitboxes rewind.** World geometry, doors, and grenades are not rewound.

**Anti-cheat value:** every shot is checked by the server against real (rewound) positions. "Silent aim" that claims hits that weren't possible fails. Every kill logs: shooter view angles, rewind amount, hit position — evidence for review and for statistical aimbot detection later.

---

## 6. Pillar 4 — Server-side visibility culling (anti-wallhack)

**The problem.** A wallhack works because the game sends every enemy's position to your computer even when they're behind a wall. The cheat just reads it and draws it.

**The fix:** don't send what you can't see. If the data never reaches the client, there's nothing for a wallhack to read.

**Background — PVS/BSP.** Quake, GoldSrc and Source split maps into regions (BSP) and precompute which regions can possibly see each other (the Potentially Visible Set). The engine uses it to skip work. Valve's own engines don't use it strictly against wallhacks — they send everything in the PVS, which is still a lot. We go further.

**Our design, two stages per enemy per snapshot:**
1. **Coarse (precomputed):** at map build time we divide the map into cells (Godot doesn't do BSP, so this is our own tool that runs on the map) and store which cells can see which. If the enemy's cell isn't visible from yours → **not sent**. Very cheap.
2. **Fine (line of sight):** if it passes, cast a few rays from your eye (and your eye's *predicted* position ~ one ping ahead) to points on the enemy's box (head, chest, feet, both shoulders). If any ray is clear → send. If not → not sent.
3. **Safety margin:** to avoid enemies "popping in" around corners, we treat enemies as slightly bigger than they are and look slightly ahead in time. Tuned so a peeker always appears at least a frame before they're actually visible.
4. **Sound leak control:** footsteps and gunshots still need a position for 3D audio. Send them as sound events with a **rounded position** for enemies you can't see, and only within hearing range. No continuous tracking.
5. **Teammates and spectators:** teammates always sent. Live spectators get a delay (e.g. 90 s) so they can't ghost.
6. **Smoke:** first version treats smoke as blocking line of sight once fully bloomed.

**Cost:** 128 ticks × up to 11 enemies × ~5 rays × ~10 players. Rays run only at snapshot rate (64/sec) and only after the coarse check passes. Done in Rust; estimated well under 1 ms per snapshot for 5v5.

**Anti-cheat value:** this is the single biggest server-side win. Wallhacks and radar hacks become nearly useless. It also feeds detection: if a player repeatedly aims at enemies *the server never sent them*, that's a red flag (it would mean they got info another way, e.g. a teammate leak or sound abuse).

---

## 7. Demo recording

**Reference:** demoinfocs-golang (a public parser for CS:GO/CS2 demos) and Valve's DEM format page show the classic design: a demo is a header + the stream of network messages the client received, plus periodic full-state "keyframes" so you can skip around.

**Our decisions:**
- **Our own format, not Valve's.** Same idea: a header (map, tick rate 128, version), then the per-tick stream, with a full keyframe every 10 seconds for seeking.
- **Server-side demos are the official record.** The server records the *complete* world (not the culled per-player view) plus every player's raw input commands. This is the anti-cheat evidence locker: you can replay exactly what any player saw (re-run culling) and exactly what they pressed.
- **Client POV demos** are optional and just save that client's received snapshots. Useful for players; never trusted as evidence.
- **Versioned and replayable:** because movement is deterministic, a demo of inputs can be re-simulated by future builds to check for desync bugs.
- **Parser** written in Rust (same code the server uses), with a small CLI for exporting stats (kills, positions, aim data) to CSV for anti-cheat analysis.
- **Privacy:** demos contain player names/IDs and inputs. Keep them server-side, set a retention period, publish only with consent.

---

## 8. Rust and C layers, and the bridges

| Layer | Language | What lives here | Why |
|---|---|---|---|
| Game & UI | GDScript | menus, HUD, round flow, weapons data, sounds, effects | easy to change, Godot-native |
| Netcode core | **Rust via godot-rust/gdext** | movement simulation, input buffer, prediction/replay, snapshot build + delta encode/decode, lag comp history, visibility checks, demo writer/reader | speed, no stalls, memory safety on untrusted network input |
| Hot paths (only if profiled) | C, called from Rust | e.g. SIMD bit-packing or a ray test kernel | only when Rust is measured too slow; most likely never needed |
| Transport | ENet (C, ships with Godot) | UDP packets, connection handling | already proven, free |
| Headless server | Godot headless build + same Rust library | the dedicated server | one codebase for client and server movement = determinism |

**Bridges:**
- **GDScript ↔ Rust:** gdext lets Rust code appear in Godot as normal nodes/classes. GDScript calls e.g. `NetClient.send_input(cmd)` and reads `NetClient.get_player_state()`. Data crosses in plain packed arrays, once per tick, not per field.
- **Rust ↔ C:** standard Rust FFI with a tiny, documented C header. Any C code gets fuzz-tested because it touches network data.
- **Rust core is also a standalone library** with no Godot dependency, so it can be unit-tested and run against the Python reference sim outputs in CI.

**Build order (don't over-engineer):** per the PERF doc, prototype the netcode in GDScript first to get the design right, measure, then move the core to Rust. Movement and snapshot encoding are expected to move first.

---

## 9. Fixed client settings (so they can't be abused)

- Interpolation delay: fixed at 2 snapshot intervals (~31 ms at 64/sec, ~16 ms at 128/sec). Not a player cvar (1.6's cl_interp/ex_interp abuse is why).
- Input rate: always 128/sec. Snapshot rate: server-chosen (64 or 128).
- No client-side hit detection, no client-reported positions, ever.

## 10. What the anti-cheat core gets from netcode (summary)
1. Movement re-simulated server-side → speedhack/teleport/fly impossible; input-rate anomalies flagged.
2. Snapshots carry only visible, needed data → wallhack/radar/ESP starved.
3. Shots validated with capped, server-chosen rewind → silent aim and backtrack blocked.
4. Full server demos with raw inputs → evidence and statistical aim analysis.

## 11. Open questions / next steps
1. Prototype input command + prediction loop in GDScript with the GoldSrc movement, 128 tick, simulated 80 ms ping and 2% loss.
2. Decide hitbox shapes per stance (needs player model).
3. Build the map visibility-cell tool and measure culling cost on one test map.
4. Measure real snapshot sizes; tune quantization.
5. Confirm 200 ms rewind cap against target regions' ping data.
6. Recoil/spread spec (next investigation) feeds the shot validation in Pillar 3.

---

## Sources (all checked live 2026-10-16)

- QuakeWorld/Quake source (GPL, read only): https://github.com/id-Software/Quake
- Quake network model explained: https://fabiensanglard.net/quakeSource/quakeSourceNetWork.php
- Quake 3 source (GPL, read only): https://github.com/id-Software/Quake-III-Arena
- Quake 3 network model / delta snapshots explained: https://fabiensanglard.net/quake3/network.php
- Snapshot compression technique: https://gafferongames.com/post/snapshot_compression/
- Valve — Source Multiplayer Networking (interp, lag comp, rates): https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking
- Valve (Yahn Bernier) — Latency Compensating Methods: https://developer.valvesoftware.com/wiki/Latency_Compensating_Methods_in_Client/Server_In-game_Protocol_Design_and_Optimization
- Valve — PVS: https://developer.valvesoftware.com/wiki/PVS
- Valve — DEM file format: https://developer.valvesoftware.com/wiki/DEM_%28file_format%29
- Half-Life SDK (behavior reference only): https://github.com/ValveSoftware/halflife
- Source SDK 2013 (behavior reference only): https://github.com/ValveSoftware/source-sdk-2013
- ReHLDS (behavior only, incl. 0.5 s max unlag default): https://github.com/rehlds/ReHLDS
- ReGameDLL_CS (behavior only): https://github.com/s1lentq/ReGameDLL_CS
- demoinfocs-golang (demo format reference): https://github.com/markus-wa/demoinfocs-golang
- godot-rust/gdext: https://github.com/godot-rust/gdext

Legal note: GPL (Quake) and Valve SDK code was read to understand techniques only. Nothing is copied; all implementation must be written fresh from this spec.

---

## 12. Where Rust goes beyond the netcode core (appended addendum)

This section adds to Section 8; it does not change any decision above. The netcode core stays the main Rust job. These are the other places Rust earns its spot, and the rule for when anything actually gets ported.

### 12.1 Memory-heavy systems
- Some systems hold a lot of data for a long time: the lag-comp history (every player's hitboxes for the last 200 ms), the 32-snapshot history per client, the visibility tables per map, and the server-side demo buffer.
- Rust's ownership rules decide, when the code is compiled, exactly who owns each piece of memory and when it is freed. There is no garbage collector and no background cleanup, so the cost at runtime is zero — no pauses, no surprise hitches mid-round.
- That fits the bare-metal goal: we can size these buffers up front (fixed-size ring buffers, allocated once at map load) and the compiler stops us from leaking them, reading freed memory, or two threads stepping on the same data.
- GDScript's reference counting is fine for gameplay objects, but for big, long-lived buffers that get touched every tick, Rust gives tighter memory layout (better cache use) and predictable memory use.

### 12.2 Demo parsing
- Section 7 already says the demo parser is in Rust. Why it fits:
  - Demos are untrusted files (especially client-side ones). A parser is exactly where bad input causes crashes or exploits in C/C++. Safe Rust turns a malformed file into an error, not a memory bug.
  - Parsing is a tight byte-reading loop over large files — Rust runs it at native speed, and can scan a whole match quickly for review tools.
  - The same parser can run in three places with one codebase: inside the server (writing/reading official demos), inside Godot via gdext (replay viewer), and as a standalone command-line tool for anti-cheat review.
- demoinfocs-golang remains a reference for how a demo format is structured, not code to copy; our format is our own.

### 12.3 Anti-cheat checks
- Everything a client sends is untrusted (Section 1: inputs only). The first code that touches those packets should be Rust: check sizes, ranges, and timing (e.g. claimed time only within ±1 tick, aim changes within possible limits, input rate as fixed in Section 9) before anything else sees the data.
- Rust is a good fit because a malformed or hostile packet can't overflow a buffer in safe Rust, and the checks run every tick for every player with no garbage-collection pauses.
- Server-side evidence logging (every kill's rewind data, culling decisions, rejected inputs) also goes in Rust: append-only, fixed-format records written alongside the official demo, so a review tool can replay exactly what the server saw and decided.
- This keeps the anti-cheat core on the server, where the client can't touch it — consistent with Section 10.

### 12.4 Build order: GDScript first, measure, then port
- Nothing moves to Rust because it "feels" like it should. The order is: build it in GDScript, measure it, and port only the parts that are proven too slow — through godot-rust/gdext so Godot calls the Rust code directly.
- The first measured trigger is already defined in the prediction-loop scope (prediction_loop_scope.md, criterion S8): replaying up to 32 ticks (about 250 ms of ping) must take under 1 ms in GDScript on the dev machine, with frame time staying flat at 240+ FPS. If S8 fails, that is the evidence to move the movement core to Rust.
- Before any port, the GDScript version and the Rust version must match the Python reference sim exactly (the parity test, S2), including using the same 64-bit float math. Parity first, then port.
- The same rule applies to the other areas above: demo parsing and input validation are expected to land in Rust, but each port still gets a benchmark before and after so we know it was worth it.
