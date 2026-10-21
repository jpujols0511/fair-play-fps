# Movement parity prototype

Minimal Godot 4.4 project, GDScript only. `movement.gd` holds the pure movement math; the
Python reference sim in `../specs/goldsrc_movement_sim.py` produces the expected values.
Written from our own behaviour spec (`../specs/goldsrc_movement.md`), no Valve code.

Needs: **Godot 4.4.1-stable, standard (non-.NET) official Linux binary**, and Python 3.

## Get the pinned Godot (Linux)

Do not use the distro package: `pacman -S godot` installs the newest Arch build, which may not be 4.4.1.
Download the official binary from <https://github.com/godotengine/godot/releases> (tag `4.4.1-stable`,
file `Godot_v4.4.1-stable_linux.x86_64.zip`):

```bash
mkdir -p ~/bin && cd ~/bin
curl -LO https://github.com/godotengine/godot/releases/download/4.4.1-stable/Godot_v4.4.1-stable_linux.x86_64.zip
unzip Godot_v4.4.1-stable_linux.x86_64.zip
mv Godot_v4.4.1-stable_linux.x86_64 godot-4.4.1 && chmod +x godot-4.4.1
~/bin/godot-4.4.1 --version        # must start with 4.4.1.stable
```

## Run (Linux)

All commands from this folder (`movement_proto/`). Below, `godot` means `~/bin/godot-4.4.1`
(alias it, or put `~/bin` on your PATH as `godot`).

```bash
cd movement_proto

# 1. Import once (creates .godot/, needed before the first headless run)
godot --headless --import

# 2. Parity test: prints PASS/FAIL per case, exit code 1 on any failure
godot --headless --script res://tests/test_parity.gd

# 2b. Phase 3 parity (stamina also slows ground speed), separate from Phase 1/2
godot --headless --script res://tests/test_parity_phase3.gd

# 3. Playable-sim smoke test
godot --headless --script res://tests/test_player_step.gd

# 4. Play it (opens a window)
godot --path .
# or open the folder in the Godot editor and press F5
```

Controls: **Ctrl or C** duck (half-height crouch, Phase 1), **WASD** move, **mouse** look, **Space** or **mouse wheel** jump (fresh press only,
like the spec), **B** toggles hold-to-jump (**DEBUG ONLY**, stock behaviour is fresh-press only), **R** reset, **Esc** release mouse (click to recapture).
HUD shows horizontal speed, vertical speed, peak speed, tick rate (128 Hz), ground/air and the stamina multiplier.

To feel the 340 u/s bhop: jump, then in the air hold D while turning the mouse right (or A and left)
smoothly; time the next jump the tick you land. Landing late costs speed to friction.

## Regenerate the expected values

```bash
# from the repo root
python3 specs/goldsrc_movement_sim.py > /tmp/out.txt && diff /tmp/out.txt specs/sim_results.txt   # original output unchanged
python3 specs/goldsrc_movement_sim.py --emit-cases movement_proto/tests/reference_cases.json
python3 specs/goldsrc_movement_sim.py --emit-cases-phase3 movement_proto/tests/reference_cases_phase3.json
```

## What is tested

`tests/test_parity.gd`, tolerance 0.01 (units and u/s), at 64 / 100 / 128 tick:

- **Phase 1** (must pass first): friction, ground accel (incl. diagonal and opposing wish_dir),
  air accel with arbitrary wish_dir and the 30 cap, ideal strafe gain (128 tick @ 250 = 1.5758 u/tick = 201.71 u/s per second).
- **Phase 2** (only runs if phase 1 passed): stamina ratio, jump vz, bhop cap, and a 20-hop chain
  (128 tick top bhop = **340.72**, sim 340.7198; 100 tick 329.17; 64 tick 302.99).
  Strafe gain at 250 u/s, 128 tick: **201.71 u/s per second** (1.5758 u/s per tick).
- **Phase 3** (`test_parity_phase3.gd`, separate file and cases): jump stamina also slows ground speed.

## Notes / decisions to check

- `JUMP_SPEED` is `sqrt(2*800*45)` = 268.32816 as in the sim; the handoff's 268.33 is that rounded.
- Stamina ratio is `(100 - timer_ms*0.019)/100`, floored at 0 (1.0 when the timer is 0).
- `ground_accel` / `air_accel` return the **velocity delta**; callers pass `current_speed = velocity.dot(wish_dir)`.
  `friction_speed`, `bhop_cap_speed` and `accel_gain` are float64 scalar cores that the Vector2 functions wrap.
- **Phase 3 reading (DECISION FOR JOAN):** `goldsrc_movement.md` says ground speed is "scaled down by the same factor".
  We read it as: while the stamina timer runs, the ground top speed (speed cap and accel slice) is
  `maxspeed * stamina_ratio`. It never cuts speed you already have (friction does that), and it does not compound.
  Phase 1/2 chains have no ground ticks, so they are unaffected.
- Not modelled (the spec/sim do not model them either): edge friction, crouch, walls/slopes. Playable scene is a flat floor only.
- The window/visuals could only be checked headless in the build environment (scene loads clean, sim is tested);
  the on-screen look and feel is untested until you run it.

## License

SPDX-License-Identifier: AGPL-3.0-only. Full text in the repository root `LICENSE.txt`.
