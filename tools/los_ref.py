#!/usr/bin/env python3
"""Independent Python reference for visibility culling v0 (specs/visibility_culling_v0.md).

  python3 tools/los_ref.py --selfcheck
  python3 tools/los_ref.py --emit prototypes/prediction_loop/tests/golden

Seed 7501: 5,000 random viewer / target / box configurations (including grazing and corner
cases) -> los_cases.json.gz: whether the target is sent to the viewer and which ray cleared first.
Game frame (y up). Boxes: [min_x, min_z, max_x, max_z, top, bottom]; bottom defaults to 0.0.
All float64. A segment that only touches a face or an edge counts as CLEAR (sends on ties).
"""
import gzip, json, math, os, random, sys

HEAD, CHEST, FEET, SHOULDER, SHOULDER_SIDE = 'head', 'chest', 'feet', 'shoulder', 12.0
# heights above the target's feet (hitbox v0.2 section 2 + the half-height crouch note)
# CD-r2: head center + crown (top of the head box), no vertical margin
STAND_POINTS = [66.0, 72.0, 54.5, 2.0, 58.0, 58.0]       # head, crown, chest, feet, shoulder L, shoulder R
CROUCH_POINTS = [30.0, 36.0, 27.25, 1.0, 29.0, 29.0]
SIDE_SIGN = [0.0, 0.0, 0.0, 0.0, 1.0, -1.0]        # shoulders sit +-12.0 sideways
NP = 6
STAND_EYE, CROUCH_EYE = 64.0, 32.0
MARGIN = 8.0
RAYS_PER_PAIR = 2 * 2 * 6 * 3                      # eye candidates x target positions x points x lateral shifts
SHIFTS = [0.0, MARGIN, -MARGIN]


def segment_blocked(p0, p1, box):
    """Slab method, strict: blocked only if the segment passes through the OPEN interior."""
    mn = (box[0], box[5] if len(box) > 5 else 0.0, box[1])
    mx = (box[2], box[4], box[3])
    tmin, tmax = 0.0, 1.0
    for a in range(3):
        d = p1[a] - p0[a]
        if d == 0.0:
            if not (mn[a] < p0[a] < mx[a]):
                return False
            continue
        t1 = (mn[a] - p0[a]) / d
        t2 = (mx[a] - p0[a]) / d
        if t1 > t2:
            t1, t2 = t2, t1
        if t1 > tmin: tmin = t1
        if t2 < tmax: tmax = t2
        if not (tmin < tmax):
            return False
    return tmin < tmax


def ray_clear(p0, p1, boxes):
    for b in boxes:
        if segment_blocked(p0, p1, b):
            return False
    return True


def eye_candidates(v, lookahead_s):
    """Viewer eye at the current position and at the look-ahead position. v: dict(x,y,z,vx,vz,eye)."""
    e0 = (v['x'], v['y'] + v['eye'], v['z'])
    e1 = (v['x'] + v['vx'] * lookahead_s, v['y'] + v['eye'], v['z'] + v['vz'] * lookahead_s)
    return [e0, e1]


def target_positions(t, lookahead_s):
    return [(t['x'], t['y'], t['z']), (t['x'] + t['vx'] * lookahead_s, t['y'], t['z'] + t['vz'] * lookahead_s)]


def visible(v, t, boxes, lookahead_s):
    """-> (sent, ray_index). ray_index = ((eye * 2 + tpos) * 6 + point) * 3 + shift, or -1 if none cleared."""
    heights = CROUCH_POINTS if t['crouched'] else STAND_POINTS
    if t.get('duck') is not None:                      # blended sample heights (duck fraction 0.0 standing .. 1.0 crouched)
        heights = [s + (c - s) * t['duck'] for s, c in zip(STAND_POINTS, CROUCH_POINTS)]
    eyes = eye_candidates(v, lookahead_s)
    tps = target_positions(t, lookahead_s)
    for ei, e in enumerate(eyes):
        for ti, tp in enumerate(tps):
            dx, dz = tp[0] - e[0], tp[2] - e[2]
            ln = math.sqrt(dx * dx + dz * dz)
            ux, uz = (-dz / ln, dx / ln) if ln > 0.0 else (1.0, 0.0)       # horizontal, perpendicular to the view line
            for pi in range(NP):
                for si, sh in enumerate(SHIFTS):
                    lat = SIDE_SIGN[pi] * SHOULDER_SIDE + sh
                    p = (tp[0] + ux * lat, tp[1] + heights[pi], tp[2] + uz * lat)
                    if ray_clear(e, p, boxes):
                        return True, ((ei * 2 + ti) * NP + pi) * 3 + si
    return False, -1


def rnd(r, lo, hi, step=0.25):
    return round(r.uniform(lo, hi) / step) * step


def rand_box(r):
    x0 = rnd(r, -250.0, 250.0); z0 = rnd(r, -250.0, 250.0)
    w = rnd(r, 8.0, 200.0); d = rnd(r, 20.0, 260.0)
    top = rnd(r, 30.0, 200.0)
    box = [x0, z0, x0 + w, z0 + d, top]
    if r.random() < 0.3:
        box.append(rnd(r, 0.0, top - 4.0))
    return box


def rand_config(r):
    boxes = [rand_box(r) for _ in range(r.randint(2, 6))]
    # sometimes aim at a corner / face: put the target on a line through a box corner
    v = {'x': rnd(r, -350.0, 350.0), 'y': r.choice([0.0, 0.0, 16.0, 16.0, 40.0]), 'z': rnd(r, -350.0, 350.0),
         'vx': r.choice([0.0, 0.0, rnd(r, -300.0, 300.0)]), 'vz': r.choice([0.0, 0.0, rnd(r, -300.0, 300.0)]),
         'eye': r.choice([STAND_EYE, CROUCH_EYE, rnd(r, 32.0, 64.0)])}
    t = {'x': rnd(r, -350.0, 350.0), 'y': r.choice([0.0, 0.0, 16.0, 40.0]), 'z': rnd(r, -350.0, 350.0),
         'vx': r.choice([0.0, 0.0, rnd(r, -300.0, 300.0)]), 'vz': r.choice([0.0, 0.0, rnd(r, -300.0, 300.0)]),
         'crouched': r.random() < 0.4}
    if r.random() < 0.25:
        t['duck'] = r.choice([0.25, 0.5, 0.75, round(r.random(), 4)])
    la = r.choice([0.0, 0.0625, 0.0556, 0.09375])
    return {'viewer': v, 'target': t, 'boxes': boxes, 'lookahead_s': la}


def named_cases():
    out = []
    # segment exactly grazing a face: clear. Box x 10..20, z -5..5, y 0..40; ray at constant z = 5.0 (the face plane)
    box = [10.0, -5.0, 20.0, 5.0, 40.0]
    out.append(('graze face plane z = max', {'p0': (0.0, 10.0, 5.0), 'p1': (30.0, 10.0, 5.0), 'box': box}, False))
    out.append(('graze top face y = top', {'p0': (0.0, 40.0, 0.0), 'p1': (30.0, 40.0, 0.0), 'box': box}, False))
    out.append(('touches one corner edge only', {'p0': (10.0, 50.0, 5.0), 'p1': (10.0, 30.0, 5.0), 'box': box}, False))
    out.append(('ends exactly on the near face', {'p0': (0.0, 10.0, 0.0), 'p1': (10.0, 10.0, 0.0), 'box': box}, False))
    out.append(('passes through the interior', {'p0': (0.0, 10.0, 0.0), 'p1': (30.0, 10.0, 0.0), 'box': box}, True))
    out.append(('starts inside the box', {'p0': (15.0, 10.0, 0.0), 'p1': (30.0, 10.0, 0.0), 'box': box}, True))
    out.append(('passes just under the overhang bottom', {'p0': (0.0, 39.0, 0.0), 'p1': (30.0, 39.0, 0.0), 'box': [10.0, -5.0, 20.0, 5.0, 128.0, 40.0]}, False))
    out.append(('passes just above the overhang bottom', {'p0': (0.0, 41.0, 0.0), 'p1': (30.0, 41.0, 0.0), 'box': [10.0, -5.0, 20.0, 5.0, 128.0, 40.0]}, True))
    return out


def generate(outdir):
    r = random.Random(7501)
    cases = []
    sent_n = 0
    for _ in range(5000):
        c = rand_config(r)
        sent, ray = visible(c['viewer'], c['target'], c['boxes'], c['lookahead_s'])
        c['sent'] = sent; c['ray'] = ray
        sent_n += 1 if sent else 0
        cases.append(c)
    named = []
    for name, d, want in named_cases():
        got = segment_blocked(d['p0'], d['p1'], d['box'])
        assert got == want, (name, got, want)
        named.append({'name': name, 'p0': d['p0'], 'p1': d['p1'], 'box': d['box'], 'blocked': want})
    # the half-height payoff, from the handout: cover x 700..716 top 40, viewer at x = 0 eye 64
    cover = [[700.0, -100.0, 716.0, 100.0, 40.0]]
    v = {'x': 0.0, 'y': 0.0, 'z': 0.0, 'vx': 0.0, 'vz': 0.0, 'eye': 64.0}
    crouched = {'x': 732.0, 'y': 0.0, 'z': 0.0, 'vx': 0.0, 'vz': 0.0, 'crouched': True}
    standing = dict(crouched); standing['crouched'] = False
    assert visible(v, crouched, cover, 0.0) == (False, -1)
    assert visible(v, standing, cover, 0.0)[0] is True
    v16 = dict(v); v16['y'] = 16.0
    assert visible(v16, crouched, cover, 0.0) == (False, -1)
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, 'los_cases.json.gz')
    with gzip.GzipFile(path, 'wb', 9, None, 0) as gz:
        gz.write(json.dumps({'seed': 7501, 'rays_per_pair': RAYS_PER_PAIR, 'cases': cases, 'named': named}, separators=(',', ':')).encode())
    print('wrote', path, len(cases), 'cases,', sent_n, 'sent,', os.path.getsize(path), 'bytes')


def selfcheck():
    box = [10.0, -5.0, 20.0, 5.0, 40.0]
    assert not segment_blocked((0, 10, 5), (30, 10, 5), box)
    assert segment_blocked((0, 10, 0), (30, 10, 0), box)
    print('selfcheck ok; rays per pair worst case =', RAYS_PER_PAIR)


if __name__ == '__main__':
    if '--selfcheck' in sys.argv: selfcheck()
    elif '--emit' in sys.argv: generate(sys.argv[sys.argv.index('--emit') + 1])
    else: print(__doc__)
