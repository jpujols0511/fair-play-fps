#!/usr/bin/env python3
"""Independent Python codec for snapshot_format_v0.1 (written from the spec, not from the GDScript).

  python3 tools/snapshot_ref.py --selfcheck                  struct sizes + round trips
  python3 tools/snapshot_ref.py --emit prototypes/prediction_loop/tests/golden

Writes snapshot_cases.json (2,000 random pairs from seed 7001 + named cases, as hex) and a few .bin files.
Rounding: GDScript's round() rounds half AWAY from zero, Python's round() is banker's rounding.
Here: floor(x + 0.5) for x >= 0 and -floor(-x + 0.5) for x < 0 (half away from zero) in both languages.
"""
import json, math, os, random, struct, sys

OWN_FIELDS = 13                       # PlayerState.to_packed().size() after Phase 1 (f64 each)
HEADER = struct.Struct('<BHIHIB')     # kind, snap_seq, server_tick, base_seq, ack_cmd_seq, flags = 14 bytes
HUD = struct.Struct('<HhhB')          # accuracy u16, punch_pitch i16, punch_yaw i16, move_state u8 = 7 bytes
POS_MIN, POS_MAX = -32768, 32767      # i16 of 1/8 unit: [-4096.0, 4095.875]
NF = 7                                # entity fields
FIELD_FMT = ['<h', '<h', '<h', '<H', '<H', '<B', '<B']     # x, y, z, yaw, pitch, stance+alive, duck_q (f * 255.0)
F_ALL = 0x7F
F_REMOVED = 0x80
KIND_FULL, KIND_DELTA = 1, 2


def round_away(x):
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def qpos(v):
    """float position -> (i16, clamped?)"""
    q = round_away(v * 8.0)
    if q > POS_MAX: return POS_MAX, True
    if q < POS_MIN: return POS_MIN, True
    return q, False


def qacc(a):
    return int(round_away(min(max(a, 0.0), 2.0) * 65535.0 / 2.0))


def qang(deg):
    return min(max(int(round_away(deg * 65536.0 / 360.0)), -32768), 32767)


def seq_newer(a, b):
    return a != b and ((a - b) & 0xFFFF) < 0x8000


def encode(s, base=None):
    """s: dict(snap_seq, server_tick, ack_cmd_seq, flags, own[F floats], hud[4 ints], ents{slot: 7 ints}).
    base: previous snapshot dict (as sent) or None. Returns bytes."""
    kind = KIND_DELTA if base is not None else KIND_FULL
    base_seq = base['snap_seq'] if base is not None else s['snap_seq']
    out = bytearray(HEADER.pack(kind, s['snap_seq'], s['server_tick'], base_seq, s['ack_cmd_seq'], s['flags']))
    assert len(s['own']) == OWN_FIELDS
    out += struct.pack('<%dd' % OWN_FIELDS, *s['own'])
    out += HUD.pack(*s['hud'])
    recs = []
    if base is None:
        for slot in sorted(s['ents']):
            recs.append((slot, F_ALL, s['ents'][slot]))
    else:
        for slot in sorted(set(s['ents']) | set(base['ents'])):
            if slot in s['ents'] and slot not in base['ents']:
                recs.append((slot, F_ALL, s['ents'][slot]))
            elif slot in s['ents']:
                mask = 0
                for i in range(NF):
                    if s['ents'][slot][i] != base['ents'][slot][i]:
                        mask |= 1 << i
                if mask: recs.append((slot, mask, s['ents'][slot]))
            else:
                recs.append((slot, F_REMOVED, None))
    out += struct.pack('<B', len(recs))
    for slot, mask, vals in recs:
        out += struct.pack('<BB', slot, mask)
        if mask != F_REMOVED:
            for i in range(NF):
                if mask & (1 << i): out += struct.pack(FIELD_FMT[i], vals[i])
    return bytes(out)


def decode(data, base=None):
    kind, snap_seq, server_tick, base_seq, ack, flags = HEADER.unpack_from(data, 0)
    pos = HEADER.size
    own = list(struct.unpack_from('<%dd' % OWN_FIELDS, data, pos)); pos += 8 * OWN_FIELDS
    hud = list(HUD.unpack_from(data, pos)); pos += HUD.size
    if kind == KIND_DELTA:
        assert base is not None and base['snap_seq'] == base_seq, 'missing baseline'
        ents = {k: list(v) for k, v in base['ents'].items()}
    else:
        ents = {}
    (n,) = struct.unpack_from('<B', data, pos); pos += 1
    for _ in range(n):
        slot, mask = struct.unpack_from('<BB', data, pos); pos += 2
        if mask == F_REMOVED:
            ents.pop(slot, None); continue
        cur = ents.setdefault(slot, [0] * NF)
        for i in range(NF):
            if mask & (1 << i):
                (v,) = struct.unpack_from(FIELD_FMT[i], data, pos); pos += struct.calcsize(FIELD_FMT[i]); cur[i] = v
    assert pos == len(data), 'trailing bytes'
    return {'kind': kind, 'snap_seq': snap_seq, 'server_tick': server_tick, 'base_seq': base_seq,
            'ack_cmd_seq': ack, 'flags': flags, 'own': own, 'hud': hud, 'ents': {k: tuple(v) for k, v in ents.items()}}


def full_size(f, e):
    return HEADER.size + (8 * f + HUD.size) + 1 + 14 * e


NICE_DOUBLES = [0.0, 1.0, -1.0, 250.0, 83.25, 268.32815729997475, 1315.789429, 0.5, -0.0, 340.7198, 1e-9, 4096.0, -4096.0]


def rand_own(r):
    own = []
    for i in range(OWN_FIELDS):
        c = r.random()
        if c < 0.3: own.append(r.choice(NICE_DOUBLES))
        elif c < 0.6: own.append(float(r.randint(-100, 100)))
        else: own.append(r.uniform(-5000.0, 5000.0))
    return own


def rand_ent(r):
    return (r.randint(-32768, 32767), r.randint(-32768, 32767), r.randint(-32768, 32767),
            r.randint(0, 65535), r.randint(0, 65535), r.randint(0, 7), r.randint(0, 255))


def rand_snap(r, seq, nmax=15):
    n = r.randint(1, nmax)
    slots = r.sample(range(16), n)
    return {'snap_seq': seq, 'server_tick': r.randint(0, 2 ** 32 - 1), 'ack_cmd_seq': r.randint(0, 2 ** 32 - 1),
            'flags': r.choice([0, 0, 0, 1]), 'own': rand_own(r),
            'hud': [r.randint(0, 65535), r.randint(-32768, 32767), r.randint(-32768, 32767), r.randint(0, 3)],
            'ents': {s: rand_ent(r) for s in slots}}


def mutate(r, base, seq):
    t = {'snap_seq': seq, 'server_tick': r.randint(0, 2 ** 32 - 1), 'ack_cmd_seq': r.randint(0, 2 ** 32 - 1),
         'flags': r.choice([0, 0, 0, 1]), 'own': rand_own(r) if r.random() < 0.8 else list(base['own']),
         'hud': [r.randint(0, 65535), r.randint(-32768, 32767), r.randint(-32768, 32767), r.randint(0, 3)],
         'ents': {}}
    for slot, v in base['ents'].items():
        c = r.random()
        if c < 0.45: t['ents'][slot] = v
        elif c < 0.8:
            nv = list(v)
            for i in r.sample(range(NF), r.randint(1, NF)):
                nv[i] = rand_ent(r)[i]
            t['ents'][slot] = tuple(nv)
        # else removed
    for slot in range(16):
        if slot not in base['ents'] and r.random() < 0.2:
            t['ents'][slot] = rand_ent(r)
    return t


def to_json_snap(s):
    d = dict(s); d['ents'] = {str(k): list(v) for k, v in s['ents'].items()}; return d


def generate(outdir):
    r = random.Random(7001)
    cases = []
    for i in range(2000):
        bseq = r.choice([r.randint(0, 65535), 65535 - r.randint(0, 3), r.randint(0, 5)])
        base = rand_snap(r, bseq)
        seq = (bseq + r.randint(1, 40)) & 0xFFFF          # includes sequence wraps across 65535 -> 0
        target = mutate(r, base, seq)
        bf, tf, td = encode(base), encode(target), encode(target, base)
        db, dt = decode(bf), decode(tf)
        dd = decode(td, db)
        assert all(dd[k] == dt[k] for k in ('snap_seq', 'server_tick', 'ack_cmd_seq', 'flags', 'own', 'hud', 'ents')), i
        assert db['ents'] == base['ents'] and dt['ents'] == target['ents']
        cases.append({'base_full': bf.hex(), 'target_full': tf.hex(), 'target_delta': td.hex()})
    # named cases
    base = rand_snap(random.Random(1), 100, 11)
    named = {}
    same = dict(base); same['snap_seq'] = 101
    named['empty_delta'] = (base, same)
    one = dict(base); one['snap_seq'] = 101
    slot0 = sorted(base['ents'])[0]
    e = list(base['ents'][slot0]); e[0] = (e[0] + 1) if e[0] < 32767 else e[0] - 1
    one['ents'] = dict(base['ents']); one['ents'][slot0] = tuple(e)
    named['one_entity_x_only'] = (base, one)
    addrm = dict(base); addrm['snap_seq'] = 101; addrm['ents'] = dict(base['ents'])
    removed = sorted(base['ents'])[1]; del addrm['ents'][removed]
    freeslot = next(s for s in range(16) if s not in base['ents']); addrm['ents'][freeslot] = (1, 2, 3, 4, 5, 6, 7)
    named['add_and_remove'] = (base, addrm)
    full15 = rand_snap(random.Random(2), 7, 15)
    full15['ents'] = {s: rand_ent(random.Random(s)) for s in range(15)}
    named['all_15_remote_slots'] = (None, full15)
    twelve = rand_snap(random.Random(3), 8, 11); twelve['ents'] = {s: rand_ent(random.Random(10 + s)) for s in range(1, 12)}
    named['full_12_players'] = (None, twelve)
    out = {'seed': 7001, 'own_fields': OWN_FIELDS, 'cases': cases, 'named': {}}
    os.makedirs(outdir, exist_ok=True)
    for name, (b, t) in named.items():
        entry = {'target_full': encode(t).hex(),
                 'expect': {'snap_seq': t['snap_seq'], 'server_tick': t['server_tick'], 'ack_cmd_seq': t['ack_cmd_seq'],
                            'flags': t['flags'], 'own_hex': struct.pack('<%dd' % OWN_FIELDS, *t['own']).hex(),
                            'hud': t['hud'], 'ents': {str(k): list(v) for k, v in t['ents'].items()}}}
        if b is not None:
            entry['base_full'] = encode(b).hex(); entry['target_delta'] = encode(t, b).hex()
            entry['size'] = len(encode(t, b))
            open(os.path.join(outdir, 'snapshot_%s.bin' % name), 'wb').write(encode(t, b))
        else:
            entry['size'] = len(encode(t))
            open(os.path.join(outdir, 'snapshot_%s.bin' % name), 'wb').write(encode(t))
        out['named'][name] = entry
    assert out['named']['full_12_players']['size'] == full_size(OWN_FIELDS, 11) == 280
    assert out['named']['empty_delta']['size'] == 126
    assert out['named']['one_entity_x_only']['size'] == 126 + 2 + 2
    # quantization cases: positions as integer k meaning k/32.0 (exact in binary), plus angles, accuracy
    q = []
    for k in list(range(-131072 - 40, -131072 + 41)) + list(range(131072 - 40, 131072 + 41)) + [r.randint(-140000, 140000) for _ in range(2000)]:
        v = k / 32.0
        qq, clamped = qpos(v)
        q.append([k, qq, clamped])
    out['pos_quant'] = q
    out['acc_quant'] = [[a, qacc(a)] for a in [0.0, 0.0055, 0.054, 0.12, 1.0, 2.0, 2.5, -1.0, 0.0000152590, 0.00003052] + [r.uniform(0, 2) for _ in range(500)]]
    out['ang_quant'] = [[d, qang(d)] for d in [0.0, 0.0054931640625, -0.0054931640625, 90.0, -90.0, 179.99, -180.0, 200.0, -200.0] + [r.uniform(-190, 190) for _ in range(500)]]
    json.dump(out, open(os.path.join(outdir, 'snapshot_cases.json'), 'w'))
    print('wrote', os.path.join(outdir, 'snapshot_cases.json'), len(cases), 'pairs, 12-player full =', out['named']['full_12_players']['size'], 'bytes')


def selfcheck():
    print('struct sizes: header', HEADER.size, '(want 14)  hud', HUD.size, '(want 7)  entity full record', 2 + sum(struct.calcsize(f) for f in FIELD_FMT), '(want 14)')
    assert HEADER.size == 14 and HUD.size == 7
    print('full snapshot, F=%d, E=11:' % OWN_FIELDS, full_size(OWN_FIELDS, 11), 'bytes (14 + %d + 1 + 154)' % (8 * OWN_FIELDS + 7))
    print('worst case, E=15 all fields:', full_size(OWN_FIELDS, 15), 'bytes (limit 1,200)')
    assert round_away(0.5) == 1 and round_away(-0.5) == -1 and round_away(2.5) == 3 and round_away(-2.5) == -3
    assert qpos(4095.875) == (32767, False) and qpos(-4096.0) == (-32768, False) and qpos(4096.0) == (32767, True)
    assert qpos(0.0625) == (1, False) and qpos(-0.0625) == (-1, False)
    assert seq_newer(0, 65535) and not seq_newer(65535, 0)
    print('selfcheck ok')


if __name__ == '__main__':
    if '--selfcheck' in sys.argv: selfcheck()
    elif '--emit' in sys.argv: generate(sys.argv[sys.argv.index('--emit') + 1])
    else: print(__doc__)
