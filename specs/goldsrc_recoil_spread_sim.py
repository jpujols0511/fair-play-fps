"""Independent recoil/spread sim written from the private behavior spec; no third-party source."""
import argparse
import json
import math
import random

# weapon params: (cycle_s, divisor, acc_floor, acc_cap, kick per state)
# kick = (up_base, lat_base, up_per_shot, lat_per_shot, up_max, lat_max, flip_chance_1_in)
RIFLES = {
 "AK47": dict(cycle=0.0955, div=200.0, floor=0.35, cap=1.25, start=0.2,
   spread=dict(air=(0.04,0.4), run=(0.04,0.07), stand=(0,0.0275), crouch=(0,0.0275)),
   kick=dict(moving=(1.5,.45,.225,.05,6.5,2.5,7), air=(2,1,.5,.35,9,6,5),
             crouch=(.9,.35,.15,.025,5.5,1.5,9), stand=(1,.375,.175,.0375,5.75,1.75,8))),
 "M4A1": dict(cycle=0.0875, div=220.0, floor=0.30, cap=1.0, start=0.2,
   spread=dict(air=(0.035,0.4), run=(0.035,0.07), stand=(0,0.025), crouch=(0,0.025)),
   kick=dict(moving=(1,.45,.28,.045,3.75,3,7), air=(1.2,.5,.23,.15,5.5,3.5,6),
             crouch=(.6,.3,.2,.0125,3.25,2,7), stand=(.65,.35,.25,.015,3.5,2.25,7))),
}

def decay(px, py, dt):
    """Shrink view-kick toward zero by (10 + half its size) degrees per second."""
    L = math.hypot(px, py)
    if L == 0: return 0.0, 0.0
    nl = max(L - (10 + 0.5*L)*dt, 0.0)
    return px*nl/L, py*nl/L

def source_decay(state, dt):
    """Source-style damped spring (damping 9, spring 65)."""
    p, v = state
    p += v*dt; v *= max(0, 1-9*dt); p += 0; v -= p*65*dt
    return [p, v]

class RecordingRandom(random.Random):
    """Seeded RNG that records the exact calls made by spray()."""
    def __init__(self, seed):
        super().__init__(seed)
        self.draws = []

    def uniform(self, a, b):
        value = super().uniform(a, b)
        self.draws.append({"kind": "uniform", "args": [a, b], "value": value})
        return value

    def randint(self, a, b):
        value = super().randint(a, b)
        self.draws.append({"kind": "randint", "args": [a, b], "value": value})
        return value


def accuracy_for_shots_smooth(weapon, shot_count):
    count = float(shot_count)
    return min(
        count * count * count / float(weapon["div"]) + float(weapon["floor"]),
        float(weapon["cap"]),
    )


def accuracy_for_shots_stock(weapon, shot_count):
    count = float(shot_count)
    stepped_increase = math.floor(count * count * count / float(weapon["div"]))
    return min(stepped_increase + float(weapon["floor"]), float(weapon["cap"]))


def accuracy_for_shots(weapon, shot_count, smooth=False):
    if smooth:
        return accuracy_for_shots_smooth(weapon, shot_count)
    return accuracy_for_shots_stock(weapon, shot_count)


def spray(
    name,
    tick,
    shots=30,
    state="stand",
    seed=1,
    rng=None,
    full_precision=False,
    smooth=False,
):
    w = RIFLES[name]
    rng = random.Random(seed) if rng is None else rng
    dt = 1.0 / float(tick)
    px = py = 0.0; acc = w["start"]; n = 0; dirn = 1; t = 0.0; next_fire = 0.0
    out = []
    while n < shots:
        if t + 1e-9 >= next_fire:          # can only fire on a tick boundary
            base, mul = w["spread"]["stand" if state in ("stand","crouch") else state]
            spread = base + mul*acc
            sx = (rng.uniform(-.5,.5)+rng.uniform(-.5,.5))*spread
            sy = (rng.uniform(-.5,.5)+rng.uniform(-.5,.5))*spread
            aim_up = -px + math.degrees(math.atan(sy)); aim_side = py + math.degrees(math.atan(sx))
            if full_precision:
                out.append({"n": n+1, "t": t, "spread": spread, "spread_x": sx, "spread_y": sy,
                            "kick_up": -px, "kick_side": py, "aim_up": aim_up, "aim_side": aim_side})
            else:
                out.append((n+1, round(t,4), round(spread,4), round(-px,3), round(py,3), round(aim_up,3), round(aim_side,3)))
            n += 1
            acc = accuracy_for_shots(w, n, smooth=smooth)
            k = w["kick"]["moving" if state=="run" else state]
            up = k[0] + (n*k[2] if n > 1 else 0); lat = k[1] + (n*k[3] if n > 1 else 0)
            if px > -k[4]: px = max(px-up, -k[4])
            if abs(py) < k[5]: py = min(py+lat, k[5]) if dirn else max(py-lat, -k[5])
            if rng.randint(0, k[6]) == 0: dirn ^= 1
            next_fire = next_fire + w["cycle"] if n > 1 else t + w["cycle"]
        px, py = decay(px, py, dt)
        t += dt
    return out

def _stock_counter_reset(tick, initial_shots):
    shot_count = min(float(initial_shots), 15.0)
    dt = 1.0 / float(tick)
    idle_time = 0.0
    next_drop = 0.4
    drop_ticks = []
    current_tick = 0
    while shot_count > 0.0:
        current_tick += 1
        idle_time += dt
        if idle_time > next_drop + 1e-9:
            shot_count -= 1.0
            drop_ticks.append(current_tick)
            next_drop = idle_time + 0.0225
    return {
        "tick": tick,
        "shots_before_release": initial_shots,
        "shots_after_release_cap": int(min(float(initial_shots), 15.0)),
        "first_drop_tick": drop_ticks[0],
        "first_drop_s": float(drop_ticks[0]) * dt,
        "reset_tick": drop_ticks[-1],
        "reset_s": float(drop_ticks[-1]) * dt,
    }


def recoil_cases(smooth=False):
    """Build full-precision parity cases plus the recoil spot-check values."""
    sprays = []
    for name in RIFLES:
        for state in ("stand", "crouch", "run", "air"):
            for tick in (64, 128):
                rng = RecordingRandom(1)
                rows = spray(
                    name,
                    tick,
                    state=state,
                    seed=1,
                    rng=rng,
                    full_precision=True,
                    smooth=smooth,
                )
                for i, row in enumerate(rows):
                    row["draws"] = rng.draws[i*5:(i+1)*5]
                sprays.append({
                    "weapon": name,
                    "tick": tick,
                    "state": state,
                    "seed": 1,
                    "source": "sim_recoil_results_cd9.txt" if state == "stand" else
                              "extended (sim-generated, not in sim_recoil_results_cd9.txt)",
                    "shots": rows,
                })

    spread_table = []
    for name, weapon in RIFLES.items():
        for state in ("stand", "crouch", "run", "air"):
            spread_state = "stand" if state == "crouch" else state
            base, multiplier = weapon["spread"][spread_state]
            spread_table.append({
                "weapon": name,
                "state": state,
                "first": base + multiplier * weapon["start"],
                "max": base + multiplier * weapon["cap"],
            })

    recovery = []
    for tick in (64, 100, 128):
        seconds = recovery_time(2.0, tick)
        recovery.append({
            "tick": tick,
            "kick": 2.0,
            "seconds": seconds,
            "steps": int(round(seconds * float(tick))),
        })
    decay_between_shots = []
    for tick in (64, 128):
        dt = 1.0 / float(tick)
        px = -5.0
        elapsed = 0.0
        while elapsed < 0.0955 - 1e-9:
            px, _ = decay(px, 0.0, dt)
            elapsed += dt
        decay_between_shots.append({
            "tick": tick,
            "start": 5.0,
            "after_s": elapsed,
            "value": abs(px),
        })

    return {
        "generator": "specs/goldsrc_recoil_spread_sim.py --emit-cases",
        "accuracy_mode": "legacy_smooth_reference" if smooth else "stock_stepped",
        "tolerances": {"time_s": 1e-6, "spread": 1e-6, "deg": 1e-6},
        "sprays": sprays,
        "spread_table": spread_table,
        "recovery": recovery,
        "shot_counter_recovery": [
            {
                "tick": tick,
                "30_shot_spray": _stock_counter_reset(tick, 30),
                "3_shot_tap": _stock_counter_reset(tick, 3),
            }
            for tick in (64, 100, 128)
        ],
        "decay_between_shots": decay_between_shots,
    }

def recovery_time(kick, tick, src=False):
    dt = 1.0/float(tick); t = 0.0
    if src:
        s = [kick, 0.0]
        while abs(s[0]) > 0.05 or abs(s[1]) > 0.05: s = source_decay(s, dt); t += dt
        return t
    px = kick
    while px > 0.0001: px, _ = decay(px, 0, dt); t += dt
    return t

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--emit-cases")
    parser.add_argument(
        "--smooth",
        action="store_true",
        help="Use the retained legacy smooth accuracy formula for reference.",
    )
    args = parser.parse_args()
    if args.emit_cases:
        with open(args.emit_cases, "w", encoding="utf-8") as out:
            json.dump(recoil_cases(smooth=args.smooth), out, indent=2)
            out.write("\n")
        print("wrote", args.emit_cases)
        raise SystemExit(0)
    print("Accuracy mode: %s" % ("legacy smooth reference" if args.smooth else "stock stepped"))
    for name in RIFLES:
        for tick in (64, 128):
            r = spray(name, tick, smooth=args.smooth)
            print(f"\n== {name} standing spray, {tick} tick ==")
            print("shot  time_s  spread  kick_up  kick_side  aim_up  aim_side")
            for row in r[:12] + r[-3:]: print("  ".join(f"{v:>6}" for v in row))
            print(f"30 shots took {r[-1][1]:.3f}s; peak kick up {max(x[3] for x in r):.2f} deg")
        for st in ("stand","crouch","run","air"):
            w = RIFLES[name]; b,m = w["spread"]["stand" if st=="crouch" else st]
            print(f"{name} {st}: first-shot spread {b+m*w['start']:.4f}  max {b+m*w['cap']:.4f}")
    print("\nPunch recovery (2 deg kick -> 0):")
    for tick in (64,100,128):
        print(f"  GoldSrc {tick} tick: {recovery_time(2,tick):.3f}s   Source spring: {recovery_time(2,tick,True):.3f}s")
    print("\nShot-counter recovery after release (stock defaults):")
    for tick in (64, 100, 128):
        for shots in (30, 3):
            result = _stock_counter_reset(tick, shots)
            print(
                "  %d tick, %d shots: first drop tick %d (%.6f s), reset tick %d (%.6f s)"
                % (
                    tick,
                    shots,
                    result["first_drop_tick"],
                    result["first_drop_s"],
                    result["reset_tick"],
                    result["reset_s"],
                )
            )
    print("Max recoverable kick between AK shots (0.0955s):")
    for tick in (64,128):
        dt=1/tick; px=-5.0; t=0
        while t<0.0955-1e-9: px,_=decay(px,0,dt); t+=dt
        print(f"  {tick} tick: 5.0 deg decays to {abs(px):.3f} after {t:.4f}s")
