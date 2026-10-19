# Crosshair prototype (private)

Godot **4.4.1-stable** project for `specs/crosshair_spec_v0.1.md`. Built by Game Builder. Branch `gamebuilder/crosshair`, not merged into main.

## What's here

| File | What it does |
|---|---|
| `crosshair.gd` | The crosshair. A `Control` that draws in `_draw()` from three snapshot fields: accuracy (spread), punch angle and movement state. No physics, no input, no spread math. |
| `fake_snapshot_source.gd` | Stand-in for NetClient. Same interface: `signal snapshot_received(snap)` and `get_latest()`. It plays a 9-second loop at 128 tick and sends every 2nd tick (64/sec) with an adjustable delay: standing still → running → air → landed → a 30-shot AK spray with kick → recovery. Values go through the wire quantization from review note (d). The curves are demo shapes, not the recoil sim. |
| `demo.tscn` / `demo.gd` | The demo scene. Keys **0 / 1 / 2 / 3** set the delay to 0 / 40 / 80 / 150 ms. **S** switches between plus and dot. |
| `tests/test_crosshair.gd` | Headless test of the size, color and offset mapping, the quantization round trip and the fake source. |

Colors: green standing, green crouching, yellow running, red air.
Size: `gap = spread × (screen_height/2) / tan(vfov/2)`, with a default vertical FOV of 73.74°.

## Run it on CachyOS

You need Godot 4.4.1 specifically. If `godot --version` doesn't start with `4.4.1.stable`, download the official binary:

```bash
mkdir -p ~/bin && cd ~/bin
curl -LO https://github.com/godotengine/godot/releases/download/4.4.1-stable/Godot_v4.4.1-stable_linux.x86_64.zip
unzip Godot_v4.4.1-stable_linux.x86_64.zip
mv Godot_v4.4.1-stable_linux.x86_64 godot-4.4.1
~/bin/godot-4.4.1 --version
```

Then:

```bash
cd ~/fair-play-fps
git fetch origin
git checkout gamebuilder/crosshair
git pull
cd prototypes/crosshair
~/bin/godot-4.4.1 --headless --path . --import
~/bin/godot-4.4.1 --headless --path . --script res://tests/test_crosshair.gd
~/bin/godot-4.4.1 --path .
```

The test prints PASS or FAIL per check and ends with `RESULT: N passed, 0 failed`. The last command opens the demo window.

## What to look for in the demo

- Press **2** (80 ms). Watch how late the crosshair turns yellow when "running" starts and how late it turns green after. That's the ~90 ms lag from review note (a).
- Press **0** and compare. That's what it looks like with no network.
- During the spray, the crosshair climbs (kick) and spreads (bloom), then settles back.
