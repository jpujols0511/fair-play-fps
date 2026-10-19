#!/usr/bin/env python3
"""Independent Python reference for the remote-player interpolation buffer (specs/remote_interp_v0.1.md).

  python3 tools/interp_ref.py --emit prototypes/prediction_loop/tests/golden

Seed 7101: 1,000 random event streams with loss, delay (reordering), teleports, spawns, removals.
Writes interp_cases.json.gz (standard gzip; Godot reads it with PackedByteArray.decompress_dynamic). Each stream = per client tick: events (sample inserts / slot removal),
the render tick (as an integer / 256), and the expected drawn pose + starved flag.
Samples carry the QUANTIZED wire values (positions as i16 of 1/8 unit, yaw/pitch as u16), so
GDScript and Python start from identical numbers.
"""
import json, math, os, random, sys

TAU = math.tau
RING = 16
SNAP_DIST = 64.0
BLEND_TICKS = 4


def deq_yaw(q): return q * (TAU / 65536.0)
def deq_pitch(q): return q / 65535.0 * math.pi - math.pi / 2.0


def dist(a, b):
    return math.sqrt((a['x'] - b['x']) ** 2 + (a['y'] - b['y']) ** 2 + (a['z'] - b['z']) ** 2)


def arc(a, b, t):
    d = math.fmod(math.fmod(b - a + math.pi, TAU) + TAU, TAU) - math.pi     # fposmod(b - a + PI, TAU) - PI
    return (a + d * t) % TAU


class Buf:
    def __init__(self, extrap):
        self.s = []
        self.extrap = extrap
        self.starving = False
        self.blend_left = 0
        self.blend_n = 0
        self.offset = (0.0, 0.0, 0.0)
        self.last = None

    def remove(self):
        self.s = []; self.starving = False; self.blend_left = 0; self.last = None

    def insert(self, smp):
        if self.s and smp['tick'] < self.s[0]['tick'] and len(self.s) >= RING:
            return
        for i, o in enumerate(self.s):
            if o['tick'] == smp['tick']:
                self.s[i] = smp; return
        self.s.append(smp)
        self.s.sort(key=lambda o: o['tick'])
        if len(self.s) > RING:
            self.s.pop(0)

    def sample(self, render):
        """-> (pose dict or None, starved)"""
        s = self.s
        if not s:
            self.last = None
            return None, False
        starved = False
        if render <= s[0]['tick']:
            raw = dict(s[0]); raw['yaw'] = deq_yaw(s[0]['yaw_q']); raw['pitch'] = deq_pitch(s[0]['pitch_q']); raw['duck'] = s[0]['duck']
        else:
            i = max(k for k in range(len(s)) if s[k]['tick'] <= render)
            a = s[i]
            raw = dict(a); raw['yaw'] = deq_yaw(a['yaw_q']); raw['pitch'] = deq_pitch(a['pitch_q']); raw['duck'] = a['duck']
            if i == len(s) - 1:
                if render > a['tick']:
                    starved = True
                    if self.extrap > 0.0 and len(s) >= 2 and not a['new'] and dist(s[i - 1], a) <= SNAP_DIST:
                        p = s[i - 1]
                        span = float(a['tick'] - p['tick'])
                        e = min(render - a['tick'], self.extrap)
                        raw['x'] = a['x'] + (a['x'] - p['x']) / span * e
                        raw['y'] = a['y'] + (a['y'] - p['y']) / span * e
                        raw['z'] = a['z'] + (a['z'] - p['z']) / span * e
            else:
                b = s[i + 1]
                if not (b['new'] or dist(a, b) > SNAP_DIST):
                    t = (render - a['tick']) / float(b['tick'] - a['tick'])
                    raw['x'] = a['x'] + (b['x'] - a['x']) * t
                    raw['y'] = a['y'] + (b['y'] - a['y']) * t
                    raw['z'] = a['z'] + (b['z'] - a['z']) * t
                    raw['yaw'] = arc(deq_yaw(a['yaw_q']), deq_yaw(b['yaw_q']), t)
                    pa, pb = deq_pitch(a['pitch_q']), deq_pitch(b['pitch_q'])
                    raw['pitch'] = pa + (pb - pa) * t          # plain lerp: pitch is signed and never wraps
                    raw['duck'] = a['duck'] + (b['duck'] - a['duck']) * t
        draw = dict(raw)
        if starved:
            self.starving = True
            self.blend_left = 0
        else:
            if self.starving:
                self.starving = False
                if self.last is not None:
                    off = (self.last[0] - raw['x'], self.last[1] - raw['y'], self.last[2] - raw['z'])
                    if math.sqrt(off[0] ** 2 + off[1] ** 2 + off[2] ** 2) > SNAP_DIST:
                        self.blend_left = 0
                    else:
                        self.offset = off; self.blend_left = BLEND_TICKS; self.blend_n = 0
            if self.blend_left > 0:
                self.blend_n += 1
                f = float(BLEND_TICKS - self.blend_n) / float(BLEND_TICKS)
                draw['x'] = raw['x'] + self.offset[0] * f
                draw['y'] = raw['y'] + self.offset[1] * f
                draw['z'] = raw['z'] + self.offset[2] * f
                self.blend_left -= 1
        self.last = (draw['x'], draw['y'], draw['z'])
        return draw, starved


def make_sample(tick, q, stance, alive, new, duck_q=0):
    return {'duck': duck_q / 255.0, 'tick': tick, 'x': q[0] / 8.0, 'y': q[1] / 8.0, 'z': q[2] / 8.0, 'yaw_q': q[3], 'pitch_q': q[4],
            'stance': stance, 'alive': alive, 'new': new}


def gen_stream(r, n_ticks=100):
    extrap = r.choice([0.0, 0.0, 2.0, 4.0])
    pos = [r.randint(-4000, 4000) * 1, 0, r.randint(-4000, 4000)]
    vel = [r.randint(-30, 30), 0, r.randint(-30, 30)]
    yaw = r.randint(0, 65535); pitch = r.randint(0, 65535)
    present = True
    events = {c: [] for c in range(n_ticks)}
    stance, alive, duck = 0, 1, 0
    for st in range(0, n_ticks, 2):                    # a snapshot every 2nd server tick
        new = False
        c = r.random()
        if c < 0.02:                                   # teleport
            pos = [r.randint(-4000, 4000), 0, r.randint(-4000, 4000)]
        elif c < 0.04:                                 # despawn
            present = False
        elif c < 0.06 and not present:                 # respawn
            present = True; new = True
            pos = [r.randint(-4000, 4000), 0, r.randint(-4000, 4000)]
        for k in range(3):
            pos[k] = max(-32768, min(32767, pos[k] + vel[k] + r.randint(-5, 5)))
        pos[1] = max(0, pos[1] + r.randint(-20, 20))
        yaw = (yaw + r.randint(-3000, 3000)) & 0xFFFF
        pitch = max(0, min(65535, pitch + r.randint(-500, 500)))
        if r.random() < 0.05: stance = r.randint(0, 3)
        if r.random() < 0.02: alive = 1 - alive
        duck = max(0, min(255, duck + r.randint(-60, 60))) if r.random() < 0.5 else duck
        if r.random() < 0.25: continue                  # lost on the way
        delay = r.randint(4, 10)                        # different delays reorder arrivals
        c_arr = st + delay
        if c_arr >= n_ticks: continue
        if present:
            events[c_arr].append(['s', st, pos[0], pos[1], pos[2], yaw, pitch, stance, alive, 1 if new else 0, duck])
        else:
            events[c_arr].append(['r', st])
    return extrap, events


def generate(outdir):
    r = random.Random(7101)
    out = {'seed': 7101, 'streams': []}
    n_ticks = 100
    for _ in range(1000):
        extrap, events = gen_stream(r, n_ticks)
        buf = Buf(extrap)
        removed_at = -1
        ticks = []
        for c in range(n_ticks):
            for e in events[c]:
                if e[0] == 's':
                    if e[1] <= removed_at: continue
                    buf.insert(make_sample(e[1], e[2:7], e[7], e[8], bool(e[9]), e[10]))
                else:
                    removed_at = max(removed_at, e[1]); buf.remove()
            rq = c * 256 - 10 * 256 + r.randint(-64, 64)
            pose, starved = buf.sample(rq / 256.0)
            rec = {'render_q': rq, 'events': events[c]}
            if pose is None:
                rec['present'] = False
            else:
                rec['present'] = True
                rec.update({'x': round(pose['x'], 10), 'y': round(pose['y'], 10), 'z': round(pose['z'], 10), 'yaw': round(pose['yaw'], 10), 'pitch': round(pose['pitch'], 10),
                            'duck': round(pose['duck'], 10), 'stance': pose['stance'], 'alive': pose['alive'], 'starved': starved})
            ticks.append(rec)
        out['streams'].append({'extrap': extrap, 'ticks': ticks})
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, 'interp_cases.json.gz')
    import gzip
    with gzip.open(path, 'wt', compresslevel=9, mtime=0) if False else gzip.GzipFile(path, 'wb', 9, None, 0) as gz:
        gz.write(json.dumps(out, separators=(',', ':')).encode())
    starved = sum(1 for s in out['streams'] for t in s['ticks'] if t.get('starved'))
    print('wrote', path, '1000 streams,', starved, 'starved ticks,', os.path.getsize(path), 'bytes')


if __name__ == '__main__':
    if '--emit' in sys.argv: generate(sys.argv[sys.argv.index('--emit') + 1])
    else: print(__doc__)
