#!/usr/bin/env python3
"""Independent Python reference for lag-comp history and rewind decisions."""
import argparse
import json
import math
import random
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MAX_REWIND_SECONDS = 0.2
INTERP_TICKS = 4
CLAIMED_TIME_WINDOW_EPS_TICKS = 1e-9
FLAG_REWIND_CLAMPED = 1 << 0
FLAG_CLAIMED_TIME_OUT_OF_WINDOW = 1 << 1
FLAG_NEGATIVE_REWIND = 1 << 4
FLAG_MISSING_HISTORY = 1 << 5
REASON_NONE = 0
REASON_CLAIM_OUT_OF_WINDOW = 1
REASON_OVER_CAP = 2
REASON_CLAIM_AND_CAP = 3
REASON_NEGATIVE = 4
REASON_CLAIM_AND_NEGATIVE = 5
REASON_MISSING_HISTORY = 6


def max_rewind_ticks(tick_rate):
    return math.floor(MAX_REWIND_SECONDS * float(tick_rate) + 1e-12)


def choose(now, rtt_ms, interp_ticks, claimed_view_tick, tick_rate):
    if int(tick_rate) <= 0:
        raise ValueError("tick_rate must be positive")
    now = float(now)
    if not math.isfinite(now):
        raise ValueError("now must be finite")
    rate = float(tick_rate)
    invalid_rtt = not math.isfinite(float(rtt_ms))
    invalid_claim = not math.isfinite(float(claimed_view_tick))
    safe_rtt_ms = 0.0 if invalid_rtt else float(rtt_ms)
    rtt_ticks = safe_rtt_ms * rate / 1000.0
    expected = now - rtt_ticks - float(interp_ticks)
    if not math.isfinite(rtt_ticks) or not math.isfinite(expected):
        invalid_rtt = True
        safe_rtt_ms = 0.0
        rtt_ticks = 0.0
        expected = now - float(interp_ticks)
    claim_delta = 0.0 if invalid_claim else float(claimed_view_tick) - expected
    invalid_delta = not math.isfinite(claim_delta)
    claim_out = (
        invalid_rtt
        or invalid_claim
        or invalid_delta
        or abs(claim_delta) > 1.0 + CLAIMED_TIME_WINDOW_EPS_TICKS
    )
    claim_after = (
        expected
        if invalid_rtt or invalid_claim or invalid_delta
        else float(claimed_view_tick)
    )
    flags = 0
    if claim_out:
        if not (invalid_rtt or invalid_claim or invalid_delta):
            claim_after = expected + (1.0 if claim_delta > 0.0 else -1.0)
        flags |= FLAG_CLAIMED_TIME_OUT_OF_WINDOW
    wanted = now - claim_after
    cap = max_rewind_ticks(tick_rate)
    over_cap = wanted > float(cap)
    negative = wanted < 0.0
    rewind = min(max(wanted, 0.0), float(cap))
    if over_cap:
        flags |= FLAG_REWIND_CLAMPED
    if negative:
        flags |= FLAG_NEGATIVE_REWIND

    ticks = math.floor(rewind)
    fraction = math.floor((rewind - ticks) * 65536.0 + 0.5)
    if fraction >= 65536:
        ticks += 1
        fraction = 0
    if ticks > cap:
        ticks, fraction = cap, 0
    if ticks == cap and over_cap:
        fraction = 0

    if claim_out and over_cap:
        reason = REASON_CLAIM_AND_CAP
    elif claim_out and negative:
        reason = REASON_CLAIM_AND_NEGATIVE
    elif claim_out:
        reason = REASON_CLAIM_OUT_OF_WINDOW
    elif over_cap:
        reason = REASON_OVER_CAP
    elif negative:
        reason = REASON_NEGATIVE
    else:
        reason = REASON_NONE
    quantized_rewind = float(ticks) + float(fraction) / 65536.0
    return {
        "now": now,
        "rtt_ms": safe_rtt_ms,
        "rtt_ticks": rtt_ticks,
        "interp_ticks": int(interp_ticks),
        "tick_rate": int(tick_rate),
        "claimed_view_tick": float(claimed_view_tick),
        "expected_view_tick": expected,
        "clamped_claimed_view_tick": claim_after,
        "chosen_view_tick": now - quantized_rewind,
        "wanted_rewind_ticks": wanted,
        "rewind_ticks": int(ticks),
        "rewind_frac": int(fraction),
        "rewind_ticks_float": quantized_rewind,
        "max_rewind_ticks": int(cap),
        "flags": int(flags),
        "reason": int(reason),
        "input_reject": bool(claim_out),
    }


def with_missing_history(decision, missing_count):
    result = dict(decision)
    result["missing_history_count"] = max(int(missing_count), 0)
    if missing_count > 0:
        result["flags"] |= FLAG_MISSING_HISTORY
        if result["reason"] == REASON_NONE:
            result["reason"] = REASON_MISSING_HISTORY
    return result


def _duck_fraction(sample):
    if "duck_fraction" in sample:
        fraction = float(sample["duck_fraction"])
        if not math.isfinite(fraction) or not 0.0 <= fraction <= 1.0:
            raise ValueError("duck_fraction must be finite and in [0.0, 1.0]")
        return fraction
    return 1.0 if int(sample.get("stance", 0)) in (1, 3) else 0.0


def sample_at(samples, target_tick):
    if not samples:
        return {
            "tick": -1.0,
            "origin64": [0.0, 0.0, 0.0],
            "yaw_deg": 0.0,
            "stance": 0,
            "duck_fraction": 0.0,
            "alive": False,
            "missing_history": True,
            "lower_tick": -1,
            "upper_tick": -1,
            "fraction": 0.0,
        }
    oldest, newest = samples[0], samples[-1]
    if target_tick < oldest["tick"]:
        result = dict(oldest)
        result["duck_fraction"] = _duck_fraction(oldest)
        result.update({"missing_history": True, "lower_tick": oldest["tick"],
                       "upper_tick": oldest["tick"], "fraction": 0.0})
        return result
    if target_tick > newest["tick"]:
        result = dict(newest)
        result["duck_fraction"] = _duck_fraction(newest)
        result.update({"missing_history": True, "lower_tick": newest["tick"],
                       "upper_tick": newest["tick"], "fraction": 0.0})
        return result

    lower_tick = math.floor(target_tick)
    upper_tick = math.ceil(target_tick)
    samples_by_tick = {sample["tick"]: sample for sample in samples}
    if lower_tick not in samples_by_tick or upper_tick not in samples_by_tick:
        result = dict(oldest)
        result["duck_fraction"] = _duck_fraction(oldest)
        result.update({"missing_history": True, "lower_tick": oldest["tick"],
                       "upper_tick": oldest["tick"], "fraction": 0.0})
        return result
    lower = samples_by_tick[lower_tick]
    upper = samples_by_tick[upper_tick]
    fraction = float(target_tick) - float(lower_tick)
    origin = [
        lower["origin64"][axis]
        + (upper["origin64"][axis] - lower["origin64"][axis]) * fraction
        for axis in range(3)
    ]
    yaw_delta = (upper["yaw_deg"] - lower["yaw_deg"] + 180.0) % 360.0 - 180.0
    yaw = (lower["yaw_deg"] + yaw_delta * fraction) % 360.0
    duck_fraction = (
        _duck_fraction(lower)
        + (_duck_fraction(upper) - _duck_fraction(lower)) * fraction
    )
    return {
        "tick": float(target_tick),
        "origin64": origin,
        "yaw_deg": yaw,
        "stance": lower["stance"] if fraction <= 0.5 else upper["stance"],
        "duck_fraction": duck_fraction,
        "alive": bool(lower["alive"] and upper["alive"]),
        "missing_history": False,
        "lower_tick": lower_tick,
        "upper_tick": upper_tick,
        "fraction": fraction,
    }


def _lerp(a, b, fraction):
    return [a[i] + (b[i] - a[i]) * fraction for i in range(3)]


def _path_pose(path, tick, tick_rate):
    time_s = float(tick) / float(tick_rate)
    kind = path["kind"]
    if kind == "linear":
        origin = [
            path["start"][i] + path["velocity_ups"][i] * time_s
            for i in range(3)
        ]
        return origin, float(path.get("yaw_deg", 0.0))
    if kind == "circle":
        angle_deg = float(path["deg_per_s"]) * time_s
        angle = math.radians(angle_deg)
        center = path["center"]
        origin = [
            center[0] + float(path["radius"]) * math.cos(angle),
            center[1] + float(path["radius"]) * math.sin(angle),
            center[2],
        ]
        return origin, (angle_deg + 90.0) % 360.0
    if kind == "peek":
        cover = path["cover_pos"]
        opened = path["open_pos"]
        distance = math.sqrt(sum((opened[i] - cover[i]) ** 2 for i in range(3)))
        speed = float(path["speed"])
        move_ticks = distance / speed * float(tick_rate) if speed > 0.0 else math.inf
        out_tick, back_tick = int(path["out_tick"]), int(path["back_tick"])
        if tick >= out_tick and float(tick) < float(out_tick) + move_ticks:
            fraction = (float(tick) - float(out_tick)) / move_ticks
            origin = _lerp(cover, opened, fraction)
        elif float(tick) >= float(out_tick) + move_ticks and tick < back_tick:
            origin = list(opened)
        elif tick >= back_tick and float(tick) < float(back_tick) + move_ticks:
            fraction = (float(tick) - float(back_tick)) / move_ticks
            origin = _lerp(opened, cover, fraction)
        else:
            origin = list(cover)
        return origin, float(path.get("yaw_deg", 0.0))
    raise ValueError("unknown scripted path: %s" % kind)


def _sample_for_tick(path, tick, tick_rate, stance_every, spawn_tick, death_tick):
    origin, yaw = _path_pose(path, tick, tick_rate)
    stance = 1 if stance_every > 0 and (tick // stance_every) % 2 == 1 else 0
    alive = tick >= spawn_tick and (death_tick < 0 or tick < death_tick)
    return {
        "tick": int(tick),
        "origin64": origin,
        "yaw_deg": yaw,
        "stance": stance,
        "duck_fraction": 1.0 if stance in (1, 3) else 0.0,
        "alive": alive,
    }


def _expected_decision_fields(decision):
    return {
        key: decision[key]
        for key in (
            "expected_view_tick", "clamped_claimed_view_tick", "chosen_view_tick",
            "wanted_rewind_ticks", "rewind_ticks", "rewind_frac",
            "rewind_ticks_float", "max_rewind_ticks", "flags", "reason",
            "input_reject", "rtt_ticks",
        )
    }


def make_case(
        category,
        path,
        tick_rate,
        now_tick,
        rtt_ms,
        interp_ticks,
        claim_offset,
        stance_every,
        spawn_tick,
        death_tick
    ):
    capacity = max_rewind_ticks(tick_rate) + 1
    first_tick = max(0, now_tick - capacity + 1)
    if spawn_tick >= 0:
        first_tick = max(first_tick, spawn_tick)
    samples = [
        _sample_for_tick(path, tick, tick_rate, stance_every, spawn_tick, death_tick)
        for tick in range(first_tick, now_tick + 1)
    ]
    expected_view_tick = (
        float(now_tick)
        - float(rtt_ms) * float(tick_rate) / 1000.0
        - float(interp_ticks)
    )
    claimed_view_tick = expected_view_tick + float(claim_offset)
    decision = choose(now_tick, rtt_ms, interp_ticks, claimed_view_tick, tick_rate)
    sample = sample_at(samples, decision["chosen_view_tick"])
    decision = with_missing_history(decision, 1 if sample["missing_history"] else 0)
    return {
        "category": category,
        "tick_rate": int(tick_rate),
        "now_tick": int(now_tick),
        "first_tick": int(first_tick),
        "rtt_ms": float(rtt_ms),
        "interp_ticks": int(interp_ticks),
        "claimed_view_tick": claimed_view_tick,
        "query_tick": decision["chosen_view_tick"],
        "path": path,
        "stance_every_n_ticks": int(stance_every),
        "spawn_tick": int(spawn_tick),
        "death_tick": int(death_tick),
        "expected_sample": sample,
        "expected_decision": _expected_decision_fields(decision),
    }


def _random_path(rng, now_tick, tick_rate):
    kind = rng.choice(("linear", "circle", "peek"))
    if kind == "linear":
        path = {
            "kind": "linear",
            "start": [rng.uniform(-100.0, 100.0) for _ in range(3)],
            "velocity_ups": [rng.uniform(-250.0, 250.0) for _ in range(3)],
            "yaw_deg": rng.uniform(0.0, 360.0),
        }
    elif kind == "circle":
        path = {
            "kind": "circle",
            "center": [rng.uniform(-100.0, 100.0) for _ in range(3)],
            "radius": rng.uniform(10.0, 100.0),
            "deg_per_s": rng.uniform(-180.0, 180.0),
        }
    else:
        cover = [rng.uniform(-100.0, 100.0) for _ in range(3)]
        open_pos = [cover[0] + rng.uniform(-100.0, 100.0),
                    cover[1] + rng.uniform(-100.0, 100.0),
                    cover[2]]
        path = {
            "kind": "peek",
            "cover_pos": cover,
            "open_pos": open_pos,
            "out_tick": rng.randint(max(0, now_tick - 100), now_tick),
            "back_tick": 0,
            "speed": rng.uniform(80.0, 300.0),
            "yaw_deg": rng.uniform(0.0, 360.0),
        }
        distance = math.sqrt(sum((open_pos[i] - cover[i]) ** 2 for i in range(3)))
        move_ticks = math.ceil(distance / path["speed"] * float(tick_rate))
        path["back_tick"] = path["out_tick"] + move_ticks + rng.randint(1, 50)
    return path


def generate_random_cases(seed=4242, count=5000):
    rng = random.Random(seed)
    cases = []
    for _ in range(count):
        rate = rng.choice((64, 100, 128))
        now_tick = rng.randint(40, 600)
        path = _random_path(rng, now_tick, rate)
        interp = rng.choice((2, 3, 4))
        rtt = rng.uniform(0.0, 250.0)
        expected = float(now_tick) - rtt * float(rate) / 1000.0 - float(interp)
        claim_offset = rng.choice((
            0.0,
            rng.uniform(-0.9, 0.9),
            1.0,
            -1.0,
            1.1,
            -1.1,
            rng.uniform(-5.0, 5.0),
        ))
        capacity = max_rewind_ticks(rate) + 1
        oldest_possible = max(0, now_tick - capacity + 1)
        spawn_tick = -1
        if rng.random() < 0.12:
            spawn_tick = rng.randint(oldest_possible, now_tick)
        death_tick = -1
        if rng.random() < 0.08:
            death_floor = max(spawn_tick, oldest_possible) if spawn_tick >= 0 else oldest_possible
            death_tick = rng.randint(death_floor, now_tick)
        stance_every = rng.choice((0, 0, 8, 16, 32, 64))
        category = "%s_rate_%d" % (path["kind"], rate)
        cases.append(make_case(
            category,
            path,
            rate,
            now_tick,
            rtt,
            interp,
            claim_offset,
            stance_every,
            spawn_tick,
            death_tick,
        ))
    return cases


def generate_named_cases():
    path_linear = {
        "kind": "linear",
        "start": [0.0, 0.0, 0.0],
        "velocity_ups": [250.0, 0.0, 0.0],
        "yaw_deg": 0.0,
    }
    named = []

    def add(name, now, rate, rtt, interp, offset, path=None, stance=0, spawn=-1, death=-1):
        item = make_case(
            name,
            path or path_linear,
            rate,
            now,
            rtt,
            interp,
            offset,
            stance,
            spawn,
            death,
        )
        item["name"] = name
        named.append(item)

    add("rtt_80_interp_4", 1000, 128, 80.0, 4, 0.0)
    add("claim_plus_0_9", 1000, 128, 80.0, 4, 0.9)
    add("claim_plus_1_0_inclusive", 1000, 128, 80.0, 4, 1.0)
    add("claim_plus_1_1", 1000, 128, 80.0, 4, 1.1)
    add("backtrack_minus_5", 1000, 128, 80.0, 4, -5.0)
    add("full_cap_164ms", 1000, 128, 164.0625, 4, 0.0)
    add("over_cap_170ms", 1000, 128, 170.0, 4, 0.0)
    add("reason_3_both_clamps", 1000, 128, 200.0, 4, -3.0)
    add("reason_4_negative_in_window", 1000, 128, 0.0, 0, 1.0)
    add("reason_5_claim_and_negative", 1000, 128, 0.0, 0, 3.0)
    add("reason_6_missing_history", 1000, 128, 80.0, 4, 0.0, spawn=995)
    add(
        "circle_shortest_yaw",
        128,
        128,
        0.0,
        2,
        0.0,
        path={"kind": "circle", "center": [0.0, 0.0, 0.0], "radius": 20.0, "deg_per_s": 180.0},
    )
    add(
        "peek_path",
        128,
        64,
        80.0,
        3,
        0.25,
        path={
            "kind": "peek", "cover_pos": [500.0, 60.0, 0.0],
            "open_pos": [500.0, 0.0, 0.0], "out_tick": 70,
            "back_tick": 110, "speed": 250.0, "yaw_deg": 90.0,
        },
    )
    add("stance_toggle_path", 128, 128, 80.0, 4, 0.0, stance=16)
    add("dead_target", 128, 128, 80.0, 4, 0.0, death=120)
    return named


def _case_counts(cases):
    counts = {}
    for case in cases:
        category = case["category"]
        counts[category] = counts.get(category, 0) + 1
    return counts


def generate_cases(seed=4242, count=5000):
    if count < 1:
        raise ValueError("count must be positive")
    random_cases = generate_random_cases(seed, count)
    named_cases = generate_named_cases()
    cases = random_cases + named_cases
    return {
        "generator": "tools/lagcomp_ref.py --emit-cases",
        "seed": seed,
        "random_case_count": count,
        "named_case_count": len(named_cases),
        "case_count": len(cases),
        "case_counts": _case_counts(cases),
        "cases": cases,
    }


def self_test():
    cases = generate_named_cases()
    by_name = {case["name"]: case for case in cases}
    expected_reasons = {
        "rtt_80_interp_4": 0,
        "claim_plus_1_1": 1,
        "over_cap_170ms": 2,
        "reason_3_both_clamps": 3,
        "reason_4_negative_in_window": 4,
        "reason_5_claim_and_negative": 5,
        "reason_6_missing_history": 6,
    }
    for name, reason in expected_reasons.items():
        assert by_name[name]["expected_decision"]["reason"] == reason, name
    assert by_name["rtt_80_interp_4"]["expected_decision"]["rewind_ticks"] == 14
    assert by_name["rtt_80_interp_4"]["expected_decision"]["rewind_frac"] == 15729
    assert by_name["reason_6_missing_history"]["expected_sample"]["missing_history"] is True
    for rate in (64, 100, 128):
        samples = [
            {"tick": 10, "origin64": [500.0, 0.0, 0.0], "yaw_deg": 180.0,
             "stance": 0, "duck_fraction": 0.0, "alive": True},
            {"tick": 11, "origin64": [500.0, 0.0, 0.0], "yaw_deg": 180.0,
             "stance": 1, "duck_fraction": 1.0, "alive": True},
        ]
        midpoint = sample_at(samples, 10.5)
        assert abs(midpoint["duck_fraction"] - 0.5) <= 1e-12, rate

    now = 1000.0
    expected = now - 80.0 * 128.0 / 1000.0 - 4.0
    nan_claim = choose(now, 80.0, 4, math.nan, 128)
    assert nan_claim["input_reject"] is True
    assert nan_claim["reason"] == REASON_CLAIM_OUT_OF_WINDOW
    assert nan_claim["flags"] & FLAG_CLAIMED_TIME_OUT_OF_WINDOW
    assert nan_claim["clamped_claimed_view_tick"] == expected
    assert math.isfinite(nan_claim["wanted_rewind_ticks"])

    nan_rtt = choose(now, math.nan, 4, expected, 128)
    assert nan_rtt["input_reject"] is True
    assert nan_rtt["reason"] == REASON_CLAIM_OUT_OF_WINDOW
    assert nan_rtt["flags"] & FLAG_CLAIMED_TIME_OUT_OF_WINDOW
    assert nan_rtt["rtt_ms"] == 0.0
    assert nan_rtt["expected_view_tick"] == now - 4.0
    assert nan_rtt["clamped_claimed_view_tick"] == now - 4.0
    assert math.isfinite(nan_rtt["wanted_rewind_ticks"])
    print("lagcomp_ref self-test passed %d named/policy/duck/nonfinite assertions" % (len(expected_reasons) + 18))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--emit-cases")
    parser.add_argument("--seed", type=int, default=4242)
    parser.add_argument("--count", type=int, default=5000)
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if not args.emit_cases:
        parser.error("use --self-test or --emit-cases PATH")
    cases = generate_cases(args.seed, args.count)
    output = Path(args.emit_cases)
    output.write_text(
        json.dumps(cases, separators=(",", ":"), ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print("wrote %s" % output)
    print("%d random + %d named cases" % (
        cases["random_case_count"],
        cases["named_case_count"],
    ))
    print("case counts %s" % cases["case_counts"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
