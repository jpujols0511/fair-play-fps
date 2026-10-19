# Fair Play FPS: Performance & Bare-Metal Optimization Research
*Research only. Nothing installed or configured. Written Oct 16, 2026. All links checked live.*

## 1. How much of CS2 is Rust? Basically none.
- Source 2, the engine CS2 runs on, is written in **C++** (Wikipedia: https://en.wikipedia.org/wiki/Source_2). Very old code from Quake/GoldSrc days is in C. CS2 also adds `cs_script` (TypeScript) for server-side map logic, and Valve uses Pulse node graphs (https://www.source2.wiki/Basics/what-is-source-2).
- There's **no public evidence that Valve wrote any part of CS2 or Source 2 in Rust.** Where you see Rust near CS2, it's **community/third-party tooling**: s2script (a Rust core plus a C++ Metamod shim, https://github.com/s2script/s2script/blob/main/docs/BUILDING.md) and s2binlib (a Rust library for scanning binaries, https://github.com/swiftly-solution/s2binlib).
- Bottom line: we're up against a mature, hand-tuned C++ engine. We won't beat it on raw engine speed. We win by keeping things simple: small maps, few draw calls, a tight netcode loop.

## 2. Bare-metal optimization for Godot on Linux
**Rendering**
- Use **Forward+ (Vulkan)** on desktop Linux. The Mobile renderer is lighter, but it's built for phones and tile GPUs, with fewer lights and effects. Compatibility (OpenGL) is for weak hardware. Renderer guide: https://docs.godotengine.org/en/stable/tutorials/rendering/renderers.html
- Keep draw calls down: share materials and texture atlases, use MultiMesh for repeated props, use occlusion culling and LODs, and keep CS-style lighting simple (baked lightmaps/LightmapGI, no fancy GI). Godot perf docs: https://docs.godotengine.org/en/stable/tutorials/performance/index.html
- **Hitches:** GDScript uses reference counting, not a stop-the-world garbage collector (https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html). So you don't get classic GC pauses, but creating lots of objects and Arrays/Dictionaries every frame still costs time. Pre-allocate, reuse, and use typed/Packed arrays. Shader-compile stutter is real, so warm shaders up during map load.
- Move hot loops (per-tick hitscan rewinds, packet encoding, demo parsing, anti-cheat checks) to a **GDExtension** in C++ or Rust. Keep gameplay glue in GDScript.

**Networking**
- Use a fixed server tick (64/100/128, as the movement spec showed). Clients predict their own movement, interpolate other players about 2 ticks behind, and the server rewinds for lag compensation.
- **Netfox** (https://foxssake.github.io/netfox/latest/) gives Godot rollback/prediction nodes. Caveat: stock Godot can't manually step physics, so physics rollback needs a fork or Rapier (https://foxssake.github.io/netfox/latest/netfox.extras/guides/physics/). For a CS-style game, write player movement as our own kinematic code (the spec we already have), not RigidBody physics. That sidesteps the stepping problem.
- Packets: UDP, delta-compress against the last snapshot the client acknowledged (Quake 3 style), quantize floats, and keep a fixed per-tick budget.

**Memory**
- Use object pools for bullets, decals, and particles. Store per-player history in flat ring buffers. In GDExtension code, use structs-of-arrays so the CPU cache stays happy. Don't allocate anything in the tick loop.

**Input latency & refresh rate**
- Godot runs physics at a fixed tick and renders separately. Physics interpolation smooths visuals but **adds input lag**. Godot's own advice is to raise the physics tick (120/180/240) to compensate (https://docs.godotengine.org/en/stable/tutorials/rendering/jitter_stutter.html).
- With VRR (FreeSync/G-Sync): V-Sync on, FPS cap just under refresh. Godot's formula is `r - r*r/3600` (≈138 at 144 Hz, ≈224 at 240 Hz) (https://docs.godotengine.org/en/4.6/classes/class_engine.html). Set swapchain image count to 2. For competitive players, offer V-Sync off with a stable FPS cap. That cap only lowers latency when the GPU is the bottleneck.
- Idea: read mouse input and apply view rotation every render frame (not just per physics tick), and send it to the server with each tick command. That's how CS feels responsive at high FPS.
- Jolt physics is built into Godot 4.4+ (still experimental): https://docs.godotengine.org/en/4.4/tutorials/physics/using_jolt_physics.html

## 3. Where Rust fits
- **godot-rust / gdext** (https://github.com/godot-rust/gdext): Rust bindings for Godot 4. You can mix it with GDScript, and GDScript can call it. The project calls itself usable for games, with occasional breaking changes.
- **Good fit:** server-authoritative netcode core (snapshot/delta encoding, lag comp ring buffers), anti-cheat validation logic (memory safety matters where you parse hostile input), demo recording/parsing, and a headless dedicated server sim.
- **Overkill:** UI, menus, weapon/round logic, map scripting, prototyping. Keep those in GDScript. Joan is new to coding, so start everything in GDScript, profile it, and port only the hotspots the profiler proves are slow.

## 4. "Bootstrap engines from history": concrete study order
1. **QuakeWorld (1996): client-side prediction.** Fabien Sanglard's review: https://fabiensanglard.net/quakeSource/quakeSourceNetWork.php. Borrow: predict local movement and correct on server update.
2. **GoldSrc / CS 1.6 movement.** Already done in `specs/goldsrc_movement.md`. Borrow: air-strafe, bhop, and stamina behavior.
3. **Quake 3: snapshot + delta netcode.** https://fabiensanglard.net/quake3/network.php, code at https://github.com/ioquake/ioq3/blob/master/code/server/sv_snapshot.c (GPL; read it to learn, don't copy into our repo if licenses conflict). Borrow: the server keeps the last 32 snapshots per client and sends deltas against the last acknowledged one. No resends needed. Also Unlagged, the early lag comp mod: https://ra.is/unlagged/network.html
4. **Source: lag compensation + interpolation.** Valve wiki (archived): https://web.archive.org/web/20200910022723/developer.valvesoftware.com/wiki/Source_Multiplayer_Networking. Borrow: keep about 1s of player position history and rewind to `server time − latency − interp` when checking a shot.
5. **BSP/PVS visibility (Quake → GoldSrc → Source).** Borrow the *idea*: precompute which areas can see which, skip what's hidden, and use it server-side to **not send enemy positions a player can't see**. That's an anti-wallhack win that fits the anti-cheat core. In Godot, use occlusion culling plus our own area/portal visibility table.

## 5. CachyOS tuning (for players and devs)
- Default kernel `linux-cachyos`: EEVDF scheduler, PREEMPT_DYNAMIC, 1000 Hz timer, ThinLTO/AutoFDO, x86-64-v3/v4/Zen4 builds, and **sched-ext** support (https://wiki.cachyos.org/features/kernel/, https://github.com/CachyOS/linux-cachyos). BORE comes as the separate `linux-cachyos-bore` package.
- sched-ext lets you swap schedulers at runtime with no reboot (for example `scx_lavd`, built with gaming in mind, or `scx_bpfland` with a Gaming profile). Use the Kernel Manager GUI (https://wiki.cachyos.org/features/kernel_manager/, tutorial https://discuss.cachyos.org/t/tutorial-using-sched-ext-and-its-schedulers/158). Benchmark rather than assume.
- Don't use the RT kernel for gaming. CachyOS's wiki says real-time preemption hurts throughput.
- **GameMode** (https://github.com/FeralInteractive/gamemode): sets the CPU governor to performance while the game runs. We can call it from the game. CachyOS gaming guide: https://wiki.cachyos.org/configuration/gaming/
- GPU: use Mesa RADV (AMD/Intel Vulkan) or NVIDIA's proprietary/open kernel modules, keep them current, and force max performance for lowest latency.
- Turning off CPU security mitigations gains a little but costs security. **Don't recommend it** for an anti-cheat-centred game.
- Our own builds: compile Godot export templates and GDExtensions with LTO and a modern target (`x86-64-v3` is a safe baseline). Avoid `-march=native` for anything we ship, because it can crash on other CPUs.

## Suggested next steps
1. Set the project baseline: Forward+, physics tick 128, physics interpolation compared on vs off, VRR cap formula in settings.
2. Write the netcode design doc (prediction + Q3 deltas + Source lag comp + PVS-based enemy culling).
3. Profile a GDScript prototype, then decide which Rust gdext modules to write.
