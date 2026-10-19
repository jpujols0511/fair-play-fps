"""Independent GoldSrc/CS 1.6 movement behaviour sim (written from our own spec,
not from Valve code). Horizontal plane + simple vertical, flat floor, no walls."""
import math
GRAV, FRIC, STOP, ACC, AIRACC = 800.0, 4.0, 100.0, 10.0, 10.0
MAXSPEED = 250.0        # knife / most pistols in CS 1.6
AIRCAP = 30.0
JUMP_V = math.sqrt(2*GRAV*45.0)   # ~268.3 u/s
STAMINA_MS = 1315.789429
BHOP_FACTOR = 1.2

def friction(v, dt):
    if v <= 0: return 0.0
    drop = FRIC * max(v, STOP) * dt
    return max(v - drop, 0.0)

def air_gain(v, dt, wish=MAXSPEED):
    """Best-possible speed after one air tick with ideal mouse/keys."""
    a = AIRACC * wish * dt                   # raw accel this tick
    d = AIRCAP - a                           # ideal 'already-moving-that-way' amount
    if a >= AIRCAP:  # accel can't use more than 30; best you can do: add 30 sideways-ish
        best = max(v*v + 2*min(a, AIRCAP - dd)*dd + min(a, AIRCAP - dd)**2
                   for dd in [x*0.05 - 60 for x in range(1801)])
        return math.sqrt(best)
    return math.sqrt(v*v + 2*a*d + a*a)

def stamina_ratio(st): return (100 - st*0.001*19)*0.01 if st > 0 else 1.0

def airtime_ticks(tick, vz):
    dt = 1/tick; z, n = 0.0, 0
    while True:
        vz -= GRAV*dt/2; z += vz*dt; vz -= GRAV*dt/2; n += 1
        if z <= 0: return n

def bhop_chain(tick, jumps=20, start=MAXSPEED):
    dt = 1/tick; v = start; st = 0.0; peaks = []
    for j in range(jumps):
        # jump tick: cap check, then vertical launch (stamina-scaled)
        cap = BHOP_FACTOR*MAXSPEED
        if v > cap: v *= (cap/v)*0.8
        vz = JUMP_V*stamina_ratio(st); st = STAMINA_MS
        n = airtime_ticks(tick, vz)
        for _ in range(n):
            v = air_gain(v, dt); st = max(st - dt*1000, 0)
        peaks.append((round(v,1), round(vz,1), n))
    return peaks

def landing_loss(tick, v, ms=1000):
    dt = 1/tick; out = []
    for i in range(int(ms/1000*tick)):
        v = friction(v, dt); out.append(v)
        if v == 0: break
    return out

# ---------------------------------------------------------------------------
# Parity reference additions (movement.gd). Written from goldsrc_movement.md.
# The functions above are untouched, so sim_results.txt does not change.
# ---------------------------------------------------------------------------
def accel_gain(current_speed, cap_speed, wish_speed, accel, dt):
    """Speed added along wish_dir this tick: a slice of accel*wish_speed*dt,
    never more than the gap between cap_speed and the speed already going that way."""
    gap = cap_speed - current_speed
    if gap <= 0: return 0.0
    return min(accel * wish_speed * dt, gap)

def ground_accel(wish_dir, current_speed, top_speed, accel, dt):
    """Velocity delta on the ground. current_speed = dot(velocity, wish_dir)."""
    g = accel_gain(current_speed, top_speed, top_speed, accel, dt)
    return (wish_dir[0] * g, wish_dir[1] * g)

def air_accel(wish_dir, current_speed, top_speed, accel, dt):
    """Same as ground_accel, but the gap check uses min(top_speed, 30); the slice
    size still uses the full top_speed."""
    g = accel_gain(current_speed, min(top_speed, AIRCAP), top_speed, accel, dt)
    return (wish_dir[0] * g, wish_dir[1] * g)

def bhop_cap(v, maxspeed):
    cap = BHOP_FACTOR * maxspeed
    if v > cap: v *= (cap / v) * 0.8
    return v

def ideal_wish_dir(v, dt, wish=MAXSPEED):
    """Unit wish_dir (velocity along +x) that gives the best air gain: the
    projection of v on wish_dir is AIRCAP - a, or 0 when a >= AIRCAP."""
    a = AIRACC * wish * dt
    dd = max(AIRCAP - a, 0.0)
    return (dd / v, math.sqrt(1.0 - (dd / v) ** 2))

def air_step_ideal(v, dt):
    """One ideal air tick built from air_accel; speed after the tick."""
    w = ideal_wish_dir(v, dt)
    d = air_accel(w, v * w[0], MAXSPEED, AIRACC, dt)
    return math.hypot(v + d[0], d[1])

def _chain_raw(tick, jumps=20, start=MAXSPEED):
    dt = 1/tick; v = start; st = 0.0; out = []
    for j in range(jumps):
        v = bhop_cap(v, MAXSPEED)
        vz = JUMP_V*stamina_ratio(st); st = STAMINA_MS
        n = airtime_ticks(tick, vz)
        for _ in range(n):
            v = air_gain(v, dt); st = max(st - dt*1000, 0)
        out.append({"speed": v, "vz": vz, "ticks": n})
    return out

def reference_cases():
    """Expected values for tests/test_parity.gd. Phase 1 = friction, ground accel,
    air cap. Phase 2 = stamina, jump, bhop cap, chain (only run after phase 1 passes)."""
    ticks = (64, 100, 128)
    c = {"tolerance": 0.01, "phase1": {"friction": [], "ground_accel": [], "air_accel": [],
         "strafe_gain": []}, "phase2": {"stamina_ratio": [], "jump": [], "bhop_cap": [],
         "chain": []}}
    for t in ticks:
        dt = 1/t
        for v in (0.0, 50.0, 99.0, 100.0, 240.0, 300.0, 400.0):
            c["phase1"]["friction"].append({"tick": t, "speed": v, "expect": friction(v, dt)})
        for v0 in (240.0, 300.0, 400.0):
            l = landing_loss(t, v0); k = int(0.1*t)
            c["phase1"]["friction"].append({"tick": t, "speed": v0, "steps": k, "expect": l[k-1]})
    # ground accel: (velocity, wish_dir) pairs incl. diagonal and opposing wish_dir
    gv = [((0.0,0.0),(1.0,0.0)), ((100.0,0.0),(1.0,0.0)), ((240.0,0.0),(1.0,0.0)),
          ((250.0,0.0),(1.0,0.0)), ((300.0,0.0),(1.0,0.0)), ((100.0,50.0),(0.6,0.8)),
          ((200.0,0.0),(0.0,1.0)), ((200.0,0.0),(-1.0,0.0)), ((120.0,-30.0),(0.8,-0.6))]
    for t in ticks:
        dt = 1/t
        for vel, w in gv:
            cur = vel[0]*w[0] + vel[1]*w[1]
            d = ground_accel(w, cur, MAXSPEED, ACC, dt)
            nv = (vel[0]+d[0], vel[1]+d[1])
            c["phase1"]["ground_accel"].append({"tick": t, "vel": vel, "wish_dir": w,
                "delta": d, "speed_after": math.hypot(*nv)})
    # air accel with arbitrary wish_dir (incl. unit vectors at odd angles)
    av = [((250.0,0.0),(0.0,1.0)), ((250.0,0.0),(0.1,0.99498743710662)),
          ((300.0,0.0),(0.2,0.9797958971132712)), ((300.0,100.0),(0.6,0.8)),
          ((400.0,0.0),(0.05,0.9987492177719088)), ((20.0,0.0),(1.0,0.0)),
          ((29.0,0.0),(1.0,0.0)), ((250.0,0.0),(-0.5,0.8660254037844386)),
          ((250.0,0.0),(1.0,0.0)), ((-100.0,250.0),(0.8,0.6))]
    for t in ticks:
        dt = 1/t
        for vel, w in av:
            cur = vel[0]*w[0] + vel[1]*w[1]
            d = air_accel(w, cur, MAXSPEED, AIRACC, dt)
            nv = (vel[0]+d[0], vel[1]+d[1])
            c["phase1"]["air_accel"].append({"tick": t, "vel": vel, "wish_dir": w,
                "delta": d, "speed_after": math.hypot(*nv)})
    # strafe gain: ideal wish_dir through air_accel must equal the sim's air_gain
    for t in ticks:
        dt = 1/t
        for v0 in (250.0, 300.0, 400.0):
            g = air_gain(v0, dt) - v0
            assert abs(air_step_ideal(v0, dt) - v0 - g) < 0.01, (t, v0)
            c["phase1"]["strafe_gain"].append({"tick": t, "speed": v0, "gain_per_tick": g,
                                               "gain_per_sec": g*t})
    # phase 2
    for st in (0.0, 1.0, 100.0, 500.0, 1000.0, STAMINA_MS):
        c["phase2"]["stamina_ratio"].append({"timer_ms": st, "expect": stamina_ratio(st)})
        c["phase2"]["jump"].append({"timer_ms": st, "expect": JUMP_V*stamina_ratio(st)})
    for v in (0.0, 250.0, 299.0, 300.0, 301.0, 340.7198, 400.0, 1000.0):
        c["phase2"]["bhop_cap"].append({"speed": v, "maxspeed": MAXSPEED, "expect": bhop_cap(v, MAXSPEED)})
    for t in ticks:
        c["phase2"]["chain"].append({"tick": t, "hops": _chain_raw(t)})
    return c

# ---------------------------------------------------------------------------
# Phase 3 (separate from the cases above): jump stamina also slows GROUND speed.
# goldsrc_movement.md: "your ground speed is scaled down by the same factor".
# Our reading: while the stamina timer runs, the ground top speed (which sets both
# the speed cap and the accel slice) is maxspeed * stamina_ratio. Nothing here
# touches the functions above or sim_results.txt.
# ---------------------------------------------------------------------------
def ground_top_speed(maxspeed, timer_ms):
    return maxspeed * stamina_ratio(timer_ms)

def ground_run_with_stamina(tick, ticks, v0=0.0, timer_ms=STAMINA_MS):
    """Speed after each ground tick, running forward (1-D), timer counting down from timer_ms."""
    dt = 1/tick; st = timer_ms; v = v0; out = []
    for _ in range(ticks):
        st = max(st - dt*1000, 0)
        v = friction(v, dt)
        top = ground_top_speed(MAXSPEED, st)
        v += accel_gain(v, top, top, ACC, dt)
        out.append(v)
    return out

def reference_cases_phase3():
    c = {"tolerance": 0.01, "top_speed": [], "run": []}
    for st in (0.0, 1.0, 500.0, 1000.0, STAMINA_MS):
        c["top_speed"].append({"timer_ms": st, "expect": ground_top_speed(MAXSPEED, st)})
    for t in (64, 100, 128):
        for v0 in (0.0, 300.0):
            r = ground_run_with_stamina(t, 200, v0)
            c["run"].append({"tick": t, "v0": v0, "timer_ms": STAMINA_MS,
                             "samples": [{"after_ticks": k, "speed": r[k-1]} for k in (1, 5, 20, 50, 100, 200)]})
    return c

# ---------------------------------------------------------------------------
# Crouch reference (Phase 1 of the mega handoff). New functions only; nothing above is
# touched, so sim_results.txt and the older cases files stay byte-identical.
# Rules K1-K11: specs/goldsrc_movement.md "Crouch (PROPOSED, Oct 17 2026)".
# ---------------------------------------------------------------------------
CROUCH_SCALE = 0.5
STAND_BODY, STAND_EYE = 72.0, 64.0
DUCK_BODY, DUCK_EYE = CROUCH_SCALE * STAND_BODY, CROUCH_SCALE * STAND_EYE   # 36.0, 32.0
DUCK_TIME_S = 0.4
DUCK_SPEED_FACTOR = 0.333
AIR_DUCK_LIFT = (STAND_BODY - DUCK_BODY) / 2.0                               # 18.0
STEP_HEIGHT = 18.0

def duck_complete(duck_ticks, tick):
    return duck_ticks / tick >= DUCK_TIME_S - 1e-9

def duck_complete_tick(tick):
    n = 1
    while not duck_complete(n, tick): n += 1
    return n

def duck_eye(duck_ticks, tick):
    """Eye height after `duck_ticks` ticks of holding duck on the ground (linear 64 -> 32)."""
    if duck_complete(duck_ticks, tick): return DUCK_EYE
    return STAND_EYE - (STAND_EYE - DUCK_EYE) * ((duck_ticks / tick) / DUCK_TIME_S)

def ducked_run(tick, ticks, timer_ms=0.0):
    """1-D ground run, fully ducked, from standstill; timer_ms = stamina timer at the start."""
    dt = 1/tick; st = timer_ms; v = 0.0; out = []
    for _ in range(ticks):
        st = max(st - dt*1000, 0)
        v = friction(v, dt)
        top = ground_top_speed(MAXSPEED, st) * DUCK_SPEED_FACTOR
        v += accel_gain(v, top, top, ACC, dt)
        out.append(v)
    return out

def jump_apex(tick, duck_tick=None):
    """Highest feet height of one jump. duck_tick = tick index (0 = the jump tick) at whose
    start duck is pressed in the air, which lifts the feet by AIR_DUCK_LIFT."""
    dt = 1/tick; vz = JUMP_V; z = 0.0; best = 0.0; n = 0
    while True:
        if duck_tick is not None and n == duck_tick: z += AIR_DUCK_LIFT
        vz -= GRAV*dt/2; z += vz*dt; vz -= GRAV*dt/2; n += 1
        best = max(best, z)
        if z <= 0 and n > 1: return best

def box_blocks(feet, height, bottom, top):
    return top > feet and bottom < feet + height

def can_stand(feet, bottom, top):
    """Does the standing hull fit at `feet` against a box spanning [bottom, top]?"""
    return not box_blocks(feet, STAND_BODY, bottom, top)

def reference_cases_crouch():
    c = {"tolerance": 0.01,
         "constants": {"crouch_scale": CROUCH_SCALE, "duck_time_s": DUCK_TIME_S,
                       "duck_speed_factor": DUCK_SPEED_FACTOR, "air_duck_lift": AIR_DUCK_LIFT,
                       "stand_body": STAND_BODY, "stand_eye": STAND_EYE,
                       "duck_body": DUCK_BODY, "duck_eye": DUCK_EYE},
         "transition": [], "ducked_run": [], "stamina_duck": [], "crouch_jump": [],
         "cancel": [], "headroom": []}
    for t in (64, 100, 128):
        n = duck_complete_tick(t)
        c["transition"].append({"tick": t, "complete_tick": n,
                                "eye": [duck_eye(k, t) for k in range(0, n + 3)]})
        r = ducked_run(t, 200)
        first = next(i + 1 for i, v in enumerate(r) if v >= DUCK_SPEED_FACTOR * MAXSPEED - 1e-9)
        c["ducked_run"].append({"tick": t, "first_reached_tick": first, "steady": r[-1],
                                "samples": [{"after_ticks": k, "speed": r[k-1]} for k in (1, 5, 10, 20, 50, 100, 200)]})
        rs = ducked_run(t, 200, STAMINA_MS)
        c["stamina_duck"].append({"tick": t, "timer_ms": STAMINA_MS,
                                  "samples": [{"after_ticks": k, "speed": rs[k-1]} for k in (1, 5, 10, 20, 50, 100, 200)]})
        c["crouch_jump"].append({"tick": t, "plain_apex": jump_apex(t), "crouch_apex": jump_apex(t, 1),
                                 "duck_tick": 1})
        k = max(n // 2, 2)
        c["cancel"].append({"tick": t, "hold_ticks": k, "eye_before_release": duck_eye(k, t),
                            "eye_on_release": STAND_EYE})
    # (feet, box bottom, box top, does the 72-high standing hull fit?)
    for feet, bottom, top, want in ((0.0, 40.0, 128.0, False), (0.0, 30.0, 128.0, False),
                                    (4.0, 72.0, 128.0, False), (0.0, 72.0, 128.0, True),
                                    (0.0, 71.9, 128.0, False), (50.0, 0.0, 40.0, True)):
        assert can_stand(feet, bottom, top) == want
        c["headroom"].append({"feet": feet, "bottom": bottom, "top": top, "fits": want})
    return c

if __name__ == "__main__":
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == "--emit-cases":
        import json
        json.dump(reference_cases(), open(sys.argv[2], "w"), indent=1)
        print("wrote", sys.argv[2]); sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == "--emit-crouch-cases":
        import json
        json.dump(reference_cases_crouch(), open(sys.argv[2], "w"), indent=1)
        print("wrote", sys.argv[2]); sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == "--emit-cases-phase3":
        import json
        json.dump(reference_cases_phase3(), open(sys.argv[2], "w"), indent=1)
        print("wrote", sys.argv[2]); sys.exit(0)
    for tick in (64, 100, 128):
        dt = 1/tick
        print(f"\n=== {tick} tick (dt={dt*1000:.2f} ms) ===")
        a = AIRACC*MAXSPEED*dt
        print(f"raw air accel per tick: {a:.2f} u/s (cap 30)")
        for v0 in (250, 300, 400):
            g = air_gain(v0, dt) - v0
            print(f"  ideal strafe gain at {v0} u/s: {g:.3f} u/s/tick = {g*tick:.1f} u/s per second")
        ch = bhop_chain(tick)
        print(f"jump airtime: {ch[0][2]} ticks; first jump vz {ch[0][1]}, chained vz {ch[1][1]}")
        print("speed at end of each air phase (first 6):", [p[0] for p in ch[:6]])
        print(f"steady top chained-bhop speed: {ch[-1][0]} u/s (cropped back to "
              f"{0.8*BHOP_FACTOR*MAXSPEED:.0f} on each jump while >300)")
        for v0 in (240, 300, 400):
            l = landing_loss(tick, v0)
            print(f"  landing at {v0}: after 1 ground tick {l[0]:.1f}, after 100 ms {l[int(0.1*tick)-1]:.1f}, "
                  f"stop in {len(l)} ticks ({len(l)/tick*1000:.0f} ms)")
