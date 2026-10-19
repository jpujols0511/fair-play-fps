#!/usr/bin/env python3
"""Independent Python oracle for server-side shot registration."""
import argparse
import json
import math
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from specs.goldsrc_recoil_spread_sim import RIFLES
from tools.lagcomp_ref import (
    choose as choose_rewind,
    max_rewind_ticks,
    sample_at,
    with_missing_history,
    _sample_for_tick,
)
from tools.ray_box_ref import (
    HITBOX_PADDING,
    NEAR_MISS_LOG_UNITS,
    normalize,
    skeleton_boxes,
    trace_target,
)


FLAG_REWIND_CLAMPED = 1 << 0
FLAG_CLAIMED_TIME_OUT_OF_WINDOW = 1 << 1
FLAG_NEGATIVE_REWIND = 1 << 4
FLAG_MISSING_HISTORY = 1 << 5
SHOT_FLAG_REWIND_CLAMPED = 1 << 0
SHOT_FLAG_CLAIMED_TIME_OUT_OF_WINDOW = 1 << 1
SHOT_FLAG_THROUGH_WORLD = 1 << 2
SHOT_FLAG_TARGET_NOT_SENT = 1 << 3
PARALLEL_EPS = 1e-12
PLAYER_HIT_TIE_EPS = 1e-6
RUN_SPEED_THRESHOLD = 140.0
ANGLE_STEPS = 65536.0

REGION_BY_BOX = {
    0: 0, 1: 1, 2: 2,
    3: 3, 4: 3, 5: 3, 6: 3,
    7: 4, 8: 4, 9: 4, 10: 4,
}

DEFAULT_CONFIG = {
    "KICK_PATTERN_MODE": "random_flip",
    "KICK_MOVING_BEFORE_AIR": True,
    "FLIP_ROLL_INCLUSIVE": True,
    "ACCURACY_RESET_ON_RECOVERY": False,
    "FIXED_FLIP_SEQUENCE": [False, True],
    "BURST_RECOVERY_FIRST_DROP_AFTER_PERIOD": True,
    "SHOTS_FIRED_RELEASE_CAP": 0.0,
    "RECOVERY_DELAY_FROM": "last_shot",
    "WEAPON_RANGE_UNITS": 8192.0,
    "PLAYER_PENETRATION": False,
    "WORLD_BLOCKS_SHOTS": True,
}


def _config(case):
    result = dict(DEFAULT_CONFIG)
    result.update(case.get("config", {}))
    return result


def _weapon_state(shooter, config):
    weapon_id = shooter["weapon_id"]
    table = RIFLES[weapon_id]
    state = {
        "weapon_id": weapon_id,
        "shots_in_burst": 0,
        "accuracy": table["start"],
        "px": 0.0,
        "py": 0.0,
        "side_dir": True,
        "next_fire_s": 0.0,
        "last_fire_s": -math.inf,
        "idle_time_s": 0.0,
        "next_recovery_s": math.inf,
        "silenced": True,
        "config": dict(config),
    }
    state.update(shooter.get("weapon_state", {}))
    state["config"] = dict(config)
    return state


def _spread_state(move_state):
    if move_state.get("in_air", False):
        return "air"
    if float(move_state.get("horizontal_speed", 0.0)) > RUN_SPEED_THRESHOLD:
        return "run"
    return "stand"


def _kick_state(move_state, config):
    in_air = bool(move_state.get("in_air", False))
    horizontal_speed = float(move_state.get("horizontal_speed", 0.0))
    if in_air and config["KICK_MOVING_BEFORE_AIR"] and horizontal_speed > 0.0:
        return "moving"
    if in_air:
        return "air"
    if horizontal_speed > 0.0:
        return "moving"
    if bool(move_state.get("crouched", False)):
        return "crouch"
    return "stand"


def recoil_fire(state, move_state, draws):
    """One P1 rifle shot with a strict replay of the supplied server draws."""
    weapon_id = state["weapon_id"]
    weapon = RIFLES[weapon_id]
    config = state["config"]
    state_name = _spread_state(move_state)
    spread_params = weapon["spread"][state_name]
    if weapon_id == "M4A1" and state_name == "stand" and not state.get("silenced", True):
        spread_params = weapon["spread"]["stand_unsilenced"]
    spread = float(spread_params[0]) + float(spread_params[1]) * float(state["accuracy"])

    if len(draws) != 5:
        raise ValueError("each shot must provide exactly five random draws")
    uniforms = []
    for draw in draws[:4]:
        if draw["kind"] != "uniform" or draw["args"] != [-0.5, 0.5]:
            raise ValueError("spread draw kind or bounds do not match")
        uniforms.append(float(draw["value"]))
    sx = (uniforms[0] + uniforms[1]) * spread
    sy = (uniforms[2] + uniforms[3]) * spread
    px, py = float(state["px"]), float(state["py"])
    kick_up, kick_side = -px, py
    aim_up = kick_up + math.degrees(math.atan(sy))
    aim_side = kick_side + math.degrees(math.atan(sx))

    shot_count = int(state["shots_in_burst"]) + 1
    profile = weapon["kick"][_kick_state(move_state, config)]
    up = float(profile[0])
    side = float(profile[1])
    if shot_count > 1:
        up += float(shot_count) * float(profile[2])
        side += float(shot_count) * float(profile[3])
    max_up, max_side = float(profile[4]), float(profile[5])
    if px > -max_up:
        px = max(px - up, -max_up)
    if abs(py) < max_side:
        py = min(py + side, max_side) if state["side_dir"] else max(py - side, -max_side)

    flip_min = 0 if config["FLIP_ROLL_INCLUSIVE"] else 1
    flip_max = int(profile[6])
    flip = draws[4]
    if flip["kind"] != "randint" or flip["args"] != [flip_min, flip_max]:
        raise ValueError("side-flip draw kind or bounds do not match")
    roll = int(flip["value"])
    should_flip = roll == flip_min
    if config["KICK_PATTERN_MODE"] == "fixed":
        sequence = config["FIXED_FLIP_SEQUENCE"]
        should_flip = bool(sequence[(shot_count - 1) % len(sequence)])

    next_state = dict(state)
    next_state["shots_in_burst"] = shot_count
    stepped_accuracy = math.floor(float(shot_count) ** 3 / float(weapon["div"]))
    next_state["accuracy"] = min(
        float(stepped_accuracy) + float(weapon["floor"]),
        float(weapon["cap"]),
    )
    next_state["px"] = px
    next_state["py"] = py
    next_state["side_dir"] = not bool(state["side_dir"]) if should_flip else bool(state["side_dir"])
    next_state["last_fire_s"] = float(state.get("fire_time_s", 0.0))

    return next_state, {
        "shot_index": shot_count,
        "spread": spread,
        "spread_x": sx,
        "spread_y": sy,
        "kick_up": kick_up,
        "kick_side": kick_side,
        "aim_up": aim_up,
        "aim_side": aim_side,
    }


def shot_direction(pitch_deg, yaw_deg, spread_x, spread_y):
    pitch, yaw = math.radians(pitch_deg), math.radians(yaw_deg)
    cp, sp = math.cos(pitch), math.sin(pitch)
    cy, sy = math.cos(yaw), math.sin(yaw)
    direction = (
        cp * cy - spread_x * sy + spread_y * sp * cy,
        cp * sy + spread_x * cy + spread_y * sp * sy,
        -sp + spread_y * cp,
    )
    magnitude = math.sqrt(sum(value * value for value in direction))
    return tuple(value / magnitude for value in direction)


def quantize_yaw_rad(yaw_rad):
    wrapped = yaw_rad % (2.0 * math.pi)
    return int(math.floor(wrapped / (2.0 * math.pi) * ANGLE_STEPS + 0.5)) & 0xFFFF


def dequantize_yaw_q(yaw_q):
    return float(yaw_q) * (2.0 * math.pi / ANGLE_STEPS)


def quantize_pitch_rad(pitch_rad):
    pitch = min(max(float(pitch_rad), -math.pi / 2.0), math.pi / 2.0)
    return int(math.floor((pitch + math.pi / 2.0) / math.pi * (ANGLE_STEPS - 1.0) + 0.5))


def dequantize_pitch_q(pitch_q):
    return float(pitch_q) / (ANGLE_STEPS - 1.0) * math.pi - math.pi / 2.0


def _wire_pitch(spec_pitch_deg):
    pitch_q = quantize_pitch_rad(math.radians(-float(spec_pitch_deg)))
    return pitch_q, -math.degrees(dequantize_pitch_q(pitch_q))


def _wire_yaw(spec_yaw_deg):
    game_yaw = math.radians((float(spec_yaw_deg) - 90.0) % 360.0)
    yaw_q = quantize_yaw_rad(game_yaw)
    return yaw_q, (math.degrees(dequantize_yaw_q(yaw_q)) + 90.0) % 360.0


def _quantized_spec_view(shooter):
    if "view_pitch_q" in shooter:
        pitch_q = int(shooter["view_pitch_q"])
        spec_pitch = -math.degrees(dequantize_pitch_q(pitch_q))
    else:
        pitch_q, spec_pitch = _wire_pitch(float(shooter["view_pitch"]))
    if "view_yaw_q" in shooter:
        yaw_q = int(shooter["view_yaw_q"])
        spec_yaw = (math.degrees(dequantize_yaw_q(yaw_q)) + 90.0) % 360.0
    else:
        yaw_q, spec_yaw = _wire_yaw(float(shooter["view_yaw"]))
    return pitch_q, spec_pitch, yaw_q, spec_yaw


def _world_aabb_entry(origin, direction, length, box):
    minimum, maximum = box["min64"], box["max64"]
    if all(minimum[i] <= origin[i] <= maximum[i] for i in range(3)):
        return 0.0
    enter, exit_ = -math.inf, math.inf
    for axis in range(3):
        o, d = origin[axis], direction[axis]
        if abs(d) < PARALLEL_EPS:
            if o < minimum[axis] or o > maximum[axis]:
                return math.inf
            continue
        t1 = (minimum[axis] - o) / d
        t2 = (maximum[axis] - o) / d
        enter = max(enter, min(t1, t2))
        exit_ = min(exit_, max(t1, t2))
        if enter > exit_:
            return math.inf
    if exit_ < 0.0 or enter > length:
        return math.inf
    distance = max(enter, 0.0)
    return distance if distance <= length else math.inf


def _team_for(teams, slot):
    return int(teams.get(str(slot), 0))


def _shot_flags(decision, through_world, target_not_sent):
    flags = 0
    if decision["flags"] & FLAG_REWIND_CLAMPED:
        flags |= SHOT_FLAG_REWIND_CLAMPED
    if decision["flags"] & FLAG_CLAIMED_TIME_OUT_OF_WINDOW:
        flags |= SHOT_FLAG_CLAIMED_TIME_OUT_OF_WINDOW
    if through_world:
        flags |= SHOT_FLAG_THROUGH_WORLD
    if target_not_sent:
        flags |= SHOT_FLAG_TARGET_NOT_SENT
    return flags


def process_case(case, skeleton):
    context = case["context"]
    config = _config({"config": context.get("config", {})})
    shooter = context["shooter"]
    tick_rate = int(context["tick_rate"])
    now = float(context["now"])
    shooter_slot = int(shooter["slot"])
    weapon_id = shooter["weapon_id"]
    weapon_state = _weapon_state(shooter, config)
    move_state = shooter["move_state"]
    view_pitch_q, view_pitch, view_yaw_q, view_yaw = _quantized_spec_view(shooter)
    hitbox_config = dict(context.get("hitbox_config", {}))
    history_players = context["players"]

    histories = {}
    for player in history_players:
        slot = int(player["slot"])
        capacity = max_rewind_ticks(tick_rate) + 1
        first_tick = max(0, int(now) - capacity + 1)
        spawn_tick = int(player.get("spawn_tick", -1))
        if spawn_tick >= 0:
            first_tick = max(first_tick, spawn_tick)
        samples = [
            _sample_for_tick(
                player["path"],
                tick,
                tick_rate,
                int(player.get("stance_every_n_ticks", 0)),
                spawn_tick,
                int(player.get("death_tick", -1)),
            )
            for tick in range(first_tick, int(now) + 1)
        ]
        fixed_stance = int(player.get("stance", -1))
        if fixed_stance >= 0:
            for sample in samples:
                sample["stance"] = fixed_stance
                sample["duck_fraction"] = float(player.get(
                    "duck_fraction",
                    1.0 if fixed_stance in (1, 3) else 0.0,
                ))
        histories[slot] = samples

    decision = choose_rewind(
        now,
        float(context["rtt_ms"]),
        int(context["interp_ticks"]),
        float(shooter["claimed_view_tick"]),
        tick_rate,
    )
    chosen_view_tick = float(decision["chosen_view_tick"])
    targets = []
    rewound_mask = 0
    missing_count = 0
    for player in history_players:
        slot = int(player["slot"])
        if slot == shooter_slot:
            continue
        samples = histories[slot]
        if not samples:
            continue
        sample = sample_at(samples, chosen_view_tick)
        if sample["missing_history"]:
            missing_count += 1
        if not sample["alive"]:
            continue
        targets.append({"slot": slot, "team": int(player["team"]), "sample": sample})
        if not sample["missing_history"] and chosen_view_tick < float(samples[-1]["tick"]):
            rewound_mask |= 1 << slot
    decision = with_missing_history(decision, missing_count)
    decision.update({
        "shooter_slot": shooter_slot,
        "shot_index": int(shooter["shot_index"]),
        "cmd_seq": int(shooter["cmd_seq"]),
        "targets_rewound": rewound_mask.bit_count(),
        "rewound_mask": rewound_mask,
    })

    draws = case["draws"]
    weapon_state["fire_time_s"] = now / float(tick_rate)
    updated_weapon_state, shot = recoil_fire(weapon_state, move_state, draws)
    eye = tuple(float(value) for value in shooter["eye64"])
    direction = shot_direction(
        view_pitch + float(weapon_state["px"]),
        view_yaw + float(weapon_state["py"]),
        shot["spread_x"],
        shot["spread_y"],
    )
    world_boxes = context.get("world_boxes", [])
    weapon_range = float(config["WEAPON_RANGE_UNITS"])
    first_world_hit = min(
        (_world_aabb_entry(eye, direction, weapon_range, box) for box in world_boxes),
        default=math.inf,
    )
    has_world_hit = first_world_hit <= weapon_range
    segment_length = weapon_range
    if config["WORLD_BLOCKS_SHOTS"] and has_world_hit:
        segment_length = min(segment_length, first_world_hit)

    sent_mask = int(context.get("sent_mask", 0xFFFF))
    candidates = []
    for target in targets:
        sample = target["sample"]
        boxes = skeleton_boxes(
            sample["origin64"],
            float(sample["yaw_deg"]),
            int(sample["stance"]),
            skeleton,
            sample.get("duck_fraction"),
        )
        per_bone_padding = hitbox_config.get("HITBOX_PADDING_PER_BONE")
        padding = float(hitbox_config.get("HITBOX_PADDING", HITBOX_PADDING))
        padding_by_box = {
            int(box["id"]): float(per_bone_padding.get(str(box["id"]), per_bone_padding.get(int(box["id"]), padding)))
            if per_bone_padding is not None else padding
            for box in boxes
        }
        trace = trace_target(
            eye,
            direction,
            segment_length,
            boxes,
            padding_by_box,
            float(hitbox_config.get("NEAR_MISS_LOG_UNITS", NEAR_MISS_LOG_UNITS)),
        )
        candidates.append({
            "slot": target["slot"],
            "team": target["team"],
            "sample": sample,
            "trace": trace,
        })
    hits = [c for c in candidates if c["trace"]["outcome"] == "hit"]
    first_hit = None
    if hits:
        minimum = min(c["trace"]["dist"] for c in hits)
        eligible = [
            c for c in hits
            if c["trace"]["dist"] <= minimum + 1e-6
        ]
        first_hit = min(eligible, key=lambda c: c["slot"])
    if not config["PLAYER_PENETRATION"] and first_hit is not None:
        segment_length = min(segment_length, float(first_hit["trace"]["dist"]))

    records = []
    for target in candidates:
        sample = target["sample"]
        boxes = skeleton_boxes(
            sample["origin64"],
            float(sample["yaw_deg"]),
            int(sample["stance"]),
            skeleton,
            sample.get("duck_fraction"),
        )
        per_bone_padding = hitbox_config.get("HITBOX_PADDING_PER_BONE")
        padding = float(hitbox_config.get("HITBOX_PADDING", HITBOX_PADDING))
        padding_by_box = {
            int(box["id"]): float(per_bone_padding.get(str(box["id"]), per_bone_padding.get(int(box["id"]), padding)))
            if per_bone_padding is not None else padding
            for box in boxes
        }
        trace = trace_target(
            eye,
            direction,
            segment_length,
            boxes,
            padding_by_box,
            float(hitbox_config.get("NEAR_MISS_LOG_UNITS", NEAR_MISS_LOG_UNITS)),
        )
        if trace["outcome"] == "none":
            continue
        if not config["PLAYER_PENETRATION"] and trace["outcome"] == "hit" \
                and target["slot"] != first_hit["slot"]:
            continue
        through_world = False
        if not config["WORLD_BLOCKS_SHOTS"] and has_world_hit:
            along = sum((trace["ray_point"][i] - eye[i]) * direction[i] for i in range(3))
            through_world = along > first_world_hit + 1e-6
        target_team = target["team"]
        shooter_team = int(shooter["team"])
        same_team = shooter_team != 0 and shooter_team == target_team
        target_not_sent = (sent_mask & (1 << target["slot"])) == 0
        shot_flags = _shot_flags(decision, through_world, target_not_sent)
        outcome = 0 if trace["outcome"] == "hit" else 1
        box_id = int(trace["box_id"])
        records.append({
            "shooter_slot": shooter_slot,
            "target_slot": int(target["slot"]),
            "weapon_id": weapon_id,
            "part": box_id,
            "outcome": outcome,
            "target_stance": int(sample["stance"]),
            "trace_distance": float(trace["dist"]),
            "shot_index": int(shooter["shot_index"]),
            "eye_pos": eye,
            "view_pitch_q": view_pitch_q,
            "view_yaw_q": view_yaw_q,
            "spread_x": float(shot["spread_x"]),
            "spread_y": float(shot["spread_y"]),
            "kick_up": float(shot["kick_up"]),
            "kick_side": float(shot["kick_side"]),
            "rewind_ticks": int(decision["rewind_ticks"]),
            "rewind_frac": int(decision["rewind_frac"]),
            "server_time_s": float(decision["chosen_view_tick"]) / float(tick_rate),
            "client_claimed_time_s": float(shooter["claimed_view_tick"]) / float(tick_rate),
            "closest_dist": 0.0 if outcome == 0 else float(trace["dist"]),
            "ray_point": tuple(trace["ray_point"]),
            "box_point": tuple(trace["box_point"]),
            "target_origin": tuple(sample["origin64"]),
            "target_yaw": float(sample["yaw_deg"]),
            "region_id": REGION_BY_BOX[box_id],
            "damage": None,
            "same_team": same_team,
            "through_world": through_world,
            "flags": shot_flags,
        })
    for i in range(len(records)):
        for j in range(i + 1, len(records)):
            left, right = records[i], records[j]
            left_distance, right_distance = left["closest_dist"], right["closest_dist"]
            swap = right_distance < left_distance - PLAYER_HIT_TIE_EPS
            if abs(right_distance - left_distance) <= PLAYER_HIT_TIE_EPS:
                swap = right["target_slot"] < left["target_slot"]
            if swap:
                records[i], records[j] = right, left

    input_reject = None
    if decision["input_reject"]:
        input_reject = {
            "player_slot": shooter_slot,
            "reason": 1,
            "cmd_seq": int(shooter["cmd_seq"]),
            "claimed_time_s": float(shooter["claimed_view_tick"]) / float(tick_rate),
            "expected_time_s": float(decision["expected_view_tick"]) / float(tick_rate),
        }
    return {
        "records": records,
        "rewind_decision": decision,
        "input_reject": input_reject,
        "spread_at_fire": shot["spread"],
        "move_state": _snapshot_move_state(move_state),
        "shot_direction": direction,
    }


def _snapshot_move_state(move_state):
    if bool(move_state.get("in_air", False)):
        return 2
    if bool(move_state.get("crouched", False)):
        return 1
    if float(move_state.get("horizontal_speed", 0.0)) > RUN_SPEED_THRESHOLD:
        return 3
    return 0


def _sample_history(player, now, tick_rate):
    capacity = max_rewind_ticks(tick_rate) + 1
    first_tick = max(0, int(now) - capacity + 1)
    spawn_tick = int(player.get("spawn_tick", -1))
    if spawn_tick >= 0:
        first_tick = max(first_tick, spawn_tick)
    return [
        _sample_for_tick(
            player["path"],
            tick,
            tick_rate,
            int(player.get("stance_every_n_ticks", 0)),
            spawn_tick,
            int(player.get("death_tick", -1)),
        )
        for tick in range(first_tick, int(now) + 1)
    ]


def _aim_at(eye, point):
    dx, dy, dz = point[0] - eye[0], point[1] - eye[1], point[2] - eye[2]
    horizontal = math.sqrt(dx * dx + dy * dy)
    pitch = -math.degrees(math.atan2(dz, horizontal))
    yaw = math.degrees(math.atan2(dy, dx))
    pitch_q, pitch_wire = _wire_pitch(pitch)
    yaw_q, yaw_wire = _wire_yaw(yaw)
    return pitch_q, pitch_wire, yaw_q, yaw_wire


def _make_player(slot, team, path, stance_every=0, spawn_tick=-1, death_tick=-1):
    return {
        "slot": int(slot),
        "team": int(team),
        "path": path,
        "stance_every_n_ticks": int(stance_every),
        "spawn_tick": int(spawn_tick),
        "death_tick": int(death_tick),
    }


def _make_context(
        now,
        tick_rate,
        rtt_ms,
        interp_ticks,
        claimed_view_tick,
        eye,
        pitch,
        yaw,
        players,
        weapon_id="AK47",
        weapon_state=None,
        move_state=None,
        world_boxes=None,
        config=None,
        sent_mask=0xFFFF,
        shooter_team=1,
        shot_index=1,
        cmd_seq=1,
        teams=None
    ):
    if weapon_state is None:
        weapon_state = {}
    if move_state is None:
        move_state = {"in_air": False, "horizontal_speed": 0.0, "crouched": False}
    team_map = {"0": int(shooter_team)}
    for player in players:
        team_map[str(player["slot"])] = int(player["team"])
    if teams is not None:
        team_map.update({str(slot): int(team) for slot, team in teams.items()})
        shooter_team = int(team_map.get("0", shooter_team))
    return {
        "now": float(now),
        "tick_rate": int(tick_rate),
        "rtt_ms": float(rtt_ms),
        "interp_ticks": int(interp_ticks),
        "shooter": {
            "slot": 0,
            "team": int(shooter_team),
            "eye64": [float(value) for value in eye],
            "view_pitch": float(pitch),
            "view_yaw": float(yaw),
            "view_pitch_q": _wire_pitch(float(pitch))[0],
            "view_yaw_q": _wire_yaw(float(yaw))[0],
            "weapon_id": weapon_id,
            "weapon_state": dict(weapon_state),
            "move_state": dict(move_state),
            "cmd_seq": int(cmd_seq),
            "claimed_view_tick": float(claimed_view_tick),
            "shot_index": int(shot_index),
        },
        "players": players,
        "world_boxes": world_boxes or [],
        "config": config or {},
        "teams": team_map,
        "sent_mask": int(sent_mask),
    }


def _recorded_draws(rng, context):
    shooter = context["shooter"]
    config = _config({"config": context.get("config", {})})
    weapon_state = _weapon_state(shooter, config)
    profile = RIFLES[shooter["weapon_id"]]["kick"][_kick_state(shooter["move_state"], config)]
    flip_min = 0 if config["FLIP_ROLL_INCLUSIVE"] else 1
    flip_max = int(profile[6])
    draws = []
    for _ in range(4):
        draws.append({
            "kind": "uniform",
            "args": [-0.5, 0.5],
            "value": rng.uniform(-0.5, 0.5),
        })
    draws.append({
        "kind": "randint",
        "args": [flip_min, flip_max],
        "value": rng.randint(flip_min, flip_max),
    })
    return draws


def _make_case(name, scenario, context, skeleton, draws=None, seed=1):
    if draws is None:
        draws = _recorded_draws(random.Random(seed), context)
    case = {
        "name": name,
        "scenario": scenario,
        "context": context,
        "draws": draws,
    }
    case["expected"] = process_case(case, skeleton)
    return case


def _static_path(origin, yaw=0.0):
    return {
        "kind": "linear",
        "start": [float(value) for value in origin],
        "velocity_ups": [0.0, 0.0, 0.0],
        "yaw_deg": float(yaw),
    }


def _moving_path(anchor_tick, tick_rate=128, speed=250.0, x=500.0):
    return {
        "kind": "linear",
        "start": [float(x), -float(speed) * float(anchor_tick) / float(tick_rate), 0.0],
        "velocity_ups": [0.0, float(speed), 0.0],
        "yaw_deg": 0.0,
    }


def _context_aimed_at(
        skeleton,
        now,
        tick_rate,
        rtt_ms,
        interp_ticks,
        claimed_view_tick,
        eye,
        players,
        aim_slot,
        aim_box_id=0,
        aim_z=None,
        aim_tick=None,
        **kwargs
    ):
    decision = choose_rewind(now, rtt_ms, interp_ticks, claimed_view_tick, tick_rate)
    target_player = next(player for player in players if player["slot"] == aim_slot)
    samples = _sample_history(target_player, now, tick_rate)
    target_sample = sample_at(
        samples,
        float(decision["chosen_view_tick"]) if aim_tick is None else float(aim_tick)
    )
    boxes = skeleton_boxes(
        target_sample["origin64"],
        target_sample["yaw_deg"],
        target_sample["stance"],
        skeleton,
    )
    point = list(boxes[aim_box_id]["center64"])
    if aim_z is not None:
        point[2] = float(aim_z)
    pitch_q, pitch, yaw_q, yaw = _aim_at(eye, point)
    context = _make_context(
        now, tick_rate, rtt_ms, interp_ticks, claimed_view_tick, eye, pitch, yaw, players, **kwargs
    )
    context["shooter"]["view_pitch_q"] = pitch_q
    context["shooter"]["view_yaw_q"] = yaw_q
    return context


def _zero_draws(k=8, vertical=(-0.0, -0.0), horizontal=(0.0, 0.0), roll=1):
    return [
        {"kind": "uniform", "args": [-0.5, 0.5], "value": horizontal[0]},
        {"kind": "uniform", "args": [-0.5, 0.5], "value": horizontal[1]},
        {"kind": "uniform", "args": [-0.5, 0.5], "value": vertical[0]},
        {"kind": "uniform", "args": [-0.5, 0.5], "value": vertical[1]},
        {"kind": "randint", "args": [0, k], "value": roll},
    ]


def _named_case(name, scenario_id, context, skeleton, draws=None, seed=1, server_seed=None):
    case = _make_case(name, scenario_id, context, skeleton, draws, seed)
    case["scenario_id"] = int(scenario_id)
    if server_seed is not None:
        case["server_seed"] = int(server_seed)
    return case


def generate_named_cases(skeleton):
    cases = []
    teams = {0: 1, 1: 2, 2: 2}
    now = 1000

    cases.append(_named_case(
        "standing_headshot",
        1,
        _make_context(
            now, 128, 0.0, 0, float(now), [0.0, 0.0, 64.0], 0.0, 0.0,
            [_make_player(1, 2, _static_path([500.0, 0.0, 0.0], 180.0))],
            world_boxes=[], teams=teams,
        ),
        skeleton,
        _zero_draws(),
    ))

    expected_tick = now - 80.0 * 128.0 / 1000.0 - 4.0
    moving = _make_player(1, 2, _moving_path(expected_tick))
    moving_context = _context_aimed_at(
        skeleton, now, 128, 80.0, 4, expected_tick, [0.0, 0.0, 64.0],
        [moving], 1, aim_box_id=1, aim_z=57.0, world_boxes=[], shooter_team=1,
    )
    cases.append(_named_case("moving_target_rewind", 2, moving_context, skeleton, _zero_draws()))

    wall = [{"min64": [250.0, 16.0, 0.0], "max64": [260.0, 200.0, 128.0]}]
    open_peeker = _make_player(1, 2, {
        "kind": "peek", "cover_pos": [500.0, 60.0, 0.0], "open_pos": [500.0, 0.0, 0.0],
        "out_tick": 940, "back_tick": 987, "speed": 250.0, "yaw_deg": 0.0,
    })
    open_context = _context_aimed_at(
        skeleton, now, 128, 80.0, 4, expected_tick, [0.0, 0.0, 64.0],
        [open_peeker], 1, aim_box_id=1, aim_z=57.0, world_boxes=wall,
    )
    cases.append(_named_case("peek_open_world_clear", 3, open_context, skeleton, _zero_draws()))

    hidden_peeker = _make_player(1, 2, {
        "kind": "peek", "cover_pos": [500.0, 60.0, 0.0], "open_pos": [500.0, 0.0, 0.0],
        "out_tick": 980, "back_tick": 1100, "speed": 250.0, "yaw_deg": 0.0,
    })
    hidden_context = _context_aimed_at(
        skeleton, now, 128, 80.0, 4, expected_tick, [0.0, 0.0, 64.0],
        [hidden_peeker], 1, aim_box_id=1, aim_z=57.0, world_boxes=wall,
    )
    cases.append(_named_case("peek_hidden_world_blocked", 3, hidden_context, skeleton, _zero_draws()))
    unblocked_context = dict(hidden_context)
    unblocked_context["config"] = {"WORLD_BLOCKS_SHOTS": False}
    cases.append(_named_case("peek_hidden_wallbang_alt", 3, unblocked_context, skeleton, _zero_draws()))

    claimed = expected_tick - 5.0
    cheat_sample = sample_at(_sample_history(moving, now, 128), claimed)
    cheat_boxes = skeleton_boxes(cheat_sample["origin64"], 0.0, 0, skeleton)
    cheat_pitch_q, cheat_pitch_wire, cheat_yaw_q, cheat_yaw_wire = _aim_at(
        [0.0, 0.0, 64.0], cheat_boxes[0]["center64"]
    )
    cheat_context = _make_context(
        now, 128, 80.0, 4, claimed, [0.0, 0.0, 64.0],
        cheat_pitch_wire, cheat_yaw_wire, [moving], world_boxes=[], teams=teams,
    )
    cheat_context["shooter"]["view_pitch_q"] = cheat_pitch_q
    cheat_context["shooter"]["view_yaw_q"] = cheat_yaw_q
    cases.append(_named_case("backtrack_claim_clamped", 4, cheat_context, skeleton, _zero_draws()))

    for z in (74.5, 74.99, 75.0, 77.98, 78.000001):
        near_context = _make_context(
            now, 128, 0.0, 0, float(now), [0.0, 0.0, z], 0.0, 0.0,
            [_make_player(1, 2, _static_path([500.0, 0.0, 0.0], 180.0))],
            world_boxes=[], teams=teams,
        )
        cases.append(_named_case("near_miss_ladder_z_%s" % z, 5, near_context, skeleton, _zero_draws()))

    spread_context = _make_context(
        now, 128, 0.0, 0, float(now), [0.0, 0.0, 66.0], 0.0, 0.0,
        [_make_player(1, 2, _static_path([2000.0, 0.0, 0.0], 180.0))],
        weapon_state={"accuracy": 0.2}, world_boxes=[], teams=teams,
    )
    cases.append(_named_case(
        "spread_moves_head_to_chest", 6, spread_context, skeleton,
        _zero_draws(vertical=(-0.5, -0.5)),
    ))

    for z, name in ((33.0, "crouched_head"), (27.25, "crouched_overlap_chest")):
        crouch_context = _make_context(
            now, 128, 0.0, 0, float(now), [0.0, 0.0, z], 0.0, 0.0,
            [_make_player(1, 2, _static_path([500.0, 0.0, 0.0], 180.0))],
            world_boxes=[], teams=teams,
        )
        crouch_context["players"][0]["stance"] = 1
        cases.append(_named_case(name, 7, crouch_context, skeleton, _zero_draws()))

    behind_players = [
        _make_player(1, 2, _static_path([200.0, 0.0, 10.0], 180.0)),
        _make_player(2, 2, _static_path([400.0, 0.0, 0.0], 180.0)),
    ]
    behind_context = _make_context(
        now, 128, 0.0, 0, float(now), [0.0, 0.0, 73.0], 0.0, 0.0,
        behind_players, world_boxes=[], teams=teams,
    )
    cases.append(_named_case("penetration_off_rear_graze", 8, behind_context, skeleton, _zero_draws()))
    front_players = [
        _make_player(1, 2, _static_path([200.0, 0.0, 10.0], 180.0)),
        _make_player(2, 2, _static_path([100.0, 0.0, 0.0], 180.0)),
    ]
    front_context = _make_context(
        200, 128, 0.0, 0, 200.0, [0.0, 0.0, 74.5], 0.0, 0.0,
        front_players, world_boxes=[], teams=teams,
    )
    cases.append(_named_case("penetration_off_front_graze", 8, front_context, skeleton, _zero_draws()))
    penetrable_context = _make_context(
        now, 128, 0.0, 0, float(now), [0.0, 0.0, 73.0], 0.0, 0.0,
        [
            _make_player(1, 2, _static_path([200.0, 0.0, 10.0], 180.0)),
            _make_player(2, 2, _static_path([400.0, 0.0, 10.0], 180.0)),
        ],
        world_boxes=[], teams=teams, config={"PLAYER_PENETRATION": True},
    )
    cases.append(_named_case("penetration_on_two_hits", 8, penetrable_context, skeleton, _zero_draws()))

    teammate_context = _make_context(
        now, 128, 0.0, 0, float(now), [0.0, 0.0, 64.0], 0.0, 0.0,
        [_make_player(1, 1, _static_path([500.0, 0.0, 0.0], 180.0))],
        world_boxes=[], teams={0: 1, 1: 1},
    )
    cases.append(_named_case("teammate_traced", 9, teammate_context, skeleton, _zero_draws()))

    dead_context = _make_context(
        now, 128, 0.0, 0, float(now), [0.0, 0.0, 64.0], 0.0, 0.0,
        [_make_player(1, 2, _static_path([500.0, 0.0, 0.0], 180.0), death_tick=now)],
        world_boxes=[], teams=teams,
    )
    cases.append(_named_case("dead_target_ignored", 10, dead_context, skeleton, _zero_draws()))
    missing_context = _make_context(
        now, 128, 80.0, 4, expected_tick, [0.0, 0.0, 64.0], 0.0, 0.0,
        [_make_player(1, 2, _static_path([500.0, 0.0, 0.0], 180.0), spawn_tick=995)],
        world_boxes=[], teams=teams,
    )
    cases.append(_named_case("spawned_target_missing_history", 10, missing_context, skeleton, _zero_draws()))

    seed_context = _make_context(
        now, 128, 0.0, 0, float(now), [0.0, 0.0, 66.0], 0.0, 0.0,
        [_make_player(1, 2, _static_path([2000.0, 0.0, 0.0], 180.0))],
        weapon_state={"accuracy": 1.25}, world_boxes=[], teams=teams,
    )
    cases.append(_named_case("server_draw_baseline", 11, seed_context, skeleton, _zero_draws(), server_seed=1))
    cases.append(_named_case(
        "server_draw_changes_result", 11, seed_context, skeleton,
        _zero_draws(vertical=(-0.5, -0.5)), server_seed=2,
    ))
    return cases


def _random_player(rng, slot, now, tick_rate):
    kind = rng.choice(("linear", "circle", "peek"))
    if kind == "linear":
        position = [rng.uniform(250.0, 3000.0), rng.uniform(-600.0, 600.0), 0.0]
        velocity = [rng.uniform(-200.0, 200.0), rng.uniform(-250.0, 250.0), 0.0]
        path = {
            "kind": "linear",
            "start": [
                position[axis] - velocity[axis] * float(now) / float(tick_rate)
                for axis in range(3)
            ],
            "velocity_ups": velocity,
            "yaw_deg": rng.uniform(0.0, 360.0),
        }
    elif kind == "circle":
        path = {
            "kind": "circle",
            "center": [rng.uniform(250.0, 2500.0), rng.uniform(-500.0, 500.0), 0.0],
            "radius": rng.uniform(10.0, 100.0),
            "deg_per_s": rng.uniform(-120.0, 120.0),
        }
    else:
        cover = [rng.uniform(250.0, 2500.0), rng.uniform(20.0, 100.0), 0.0]
        opened = [cover[0] + rng.uniform(-60.0, 60.0), cover[1] - rng.uniform(20.0, 100.0), 0.0]
        speed = rng.uniform(100.0, 300.0)
        out_tick = rng.randint(max(0, now - 120), now)
        distance = math.sqrt(sum((opened[i] - cover[i]) ** 2 for i in range(3)))
        move_ticks = math.ceil(distance / speed * float(tick_rate))
        path = {
            "kind": "peek",
            "cover_pos": cover,
            "open_pos": opened,
            "out_tick": out_tick,
            "back_tick": out_tick + move_ticks + rng.randint(1, 50),
            "speed": speed,
            "yaw_deg": rng.uniform(0.0, 360.0),
        }

    capacity = max_rewind_ticks(tick_rate) + 1
    oldest = max(0, now - capacity + 1)
    spawn_tick = -1
    if rng.random() < 0.08:
        spawn_tick = rng.randint(max(oldest, now - 12), now)
    death_tick = -1
    if rng.random() < 0.08:
        death_min = max(oldest, spawn_tick) if spawn_tick >= 0 else oldest
        death_tick = rng.randint(death_min, now)
    return _make_player(
        slot,
        rng.choice((1, 2)),
        path,
        stance_every=rng.choice((0, 0, 8, 16, 32)),
        spawn_tick=spawn_tick,
        death_tick=death_tick,
    )


def generate_random_cases(seed=9001, count=2000, skeleton=None):
    if skeleton is None:
        skeleton = json.loads((ROOT / "specs/skeleton_constants.json").read_text(encoding="utf-8"))
    rng = random.Random(seed)
    cases = []
    for index in range(count):
        rate = 128
        now = rng.randint(100, 600)
        target_count = rng.randint(1, 11)
        players = [_random_player(rng, slot, now, rate) for slot in range(1, target_count + 1)]
        rtt_ms = rng.uniform(0.0, 250.0)
        interp_ticks = rng.choice((2, 3, 4))
        expected_view = float(now) - rtt_ms * float(rate) / 1000.0 - float(interp_ticks)
        claim_offset = rng.choice((
            rng.uniform(-0.9, 0.9),
            rng.uniform(-0.9, 0.9),
            1.0,
            -1.0,
            rng.uniform(-5.0, 5.0),
            rng.uniform(-5.0, 5.0),
        ))
        claimed = expected_view + claim_offset
        eye = [rng.uniform(-100.0, 100.0), rng.uniform(-100.0, 100.0), 64.0]
        shooter_team = 1
        sent_mask = rng.getrandbits(16)
        for player in players:
            if player["team"] == shooter_team:
                sent_mask |= 1 << int(player["slot"])

        move_choice = rng.choice(("stand", "crouch", "run", "air"))
        move_state = {
            "in_air": move_choice == "air",
            "horizontal_speed": (
                0.0 if move_choice in ("stand", "crouch")
                else rng.uniform(141.0, 300.0) if move_choice == "run"
                else rng.uniform(0.0, 200.0)
            ),
            "crouched": move_choice == "crouch",
        }
        weapon_id = rng.choice(("AK47", "M4A1"))
        weapon = RIFLES[weapon_id]
        weapon_state = {
            "shots_in_burst": rng.randint(0, 8),
            "accuracy": rng.uniform(float(weapon["start"]), float(weapon["cap"])),
            "px": rng.uniform(-3.0, 0.0),
            "py": rng.uniform(-2.0, 2.0),
            "side_dir": bool(rng.getrandbits(1)),
            "silenced": True,
        }
        config = {
            "PLAYER_PENETRATION": rng.random() < 0.12,
            "WORLD_BLOCKS_SHOTS": rng.random() >= 0.05,
        }

        aim_tick = claimed if abs(claim_offset) > 1.0 else expected_view
        aim_point = None
        possible_targets = list(players)
        rng.shuffle(possible_targets)
        for player in possible_targets:
            samples = _sample_history(player, now, rate)
            sample = sample_at(samples, aim_tick)
            if not sample["alive"]:
                continue
            boxes = skeleton_boxes(
                sample["origin64"], sample["yaw_deg"], sample["stance"], skeleton
            )
            box_id = rng.choice((0, 0, 1, 2))
            aim_point = boxes[box_id]["center64"]
            break
        if aim_point is None:
            pitch = rng.uniform(-30.0, 30.0)
            yaw = rng.uniform(-180.0, 180.0)
        else:
            _, pitch, _, yaw = _aim_at(eye, aim_point)

        world_boxes = []
        if aim_point is not None and rng.random() < 0.18:
            vector = [aim_point[i] - eye[i] for i in range(3)]
            distance = math.sqrt(sum(component * component for component in vector))
            if distance > 100.0:
                fraction = rng.uniform(0.15, 0.85)
                center = [eye[i] + vector[i] * fraction for i in range(3)]
                half = [rng.uniform(3.0, 18.0) for _ in range(3)]
                world_boxes.append({
                    "min64": [center[i] - half[i] for i in range(3)],
                    "max64": [center[i] + half[i] for i in range(3)],
                })

        context = _make_context(
            now,
            rate,
            rtt_ms,
            interp_ticks,
            claimed,
            eye,
            pitch,
            yaw,
            players,
            weapon_id=weapon_id,
            weapon_state=weapon_state,
            move_state=move_state,
            world_boxes=world_boxes,
            config=config,
            sent_mask=sent_mask,
            shooter_team=shooter_team,
            shot_index=rng.randint(1, 32),
            cmd_seq=rng.randint(1, 100000),
        )
        draw_seed = rng.randrange(1 << 30)
        case = _named_case(
            "random_%04d" % index,
            0,
            context,
            skeleton,
            seed=draw_seed,
        )
        case["category"] = "random"
        case["server_seed"] = draw_seed
        cases.append(case)
    return cases


def generate_cases(seed=9001, count=2000):
    if count < 1:
        raise ValueError("count must be positive")
    skeleton = json.loads((ROOT / "specs/skeleton_constants.json").read_text(encoding="utf-8"))
    named_cases = generate_named_cases(skeleton)
    random_cases = generate_random_cases(seed, count, skeleton)
    scenario_counts = {}
    for case in named_cases:
        key = str(case["scenario_id"])
        scenario_counts[key] = scenario_counts.get(key, 0) + 1
    return {
        "generator": "tools/hitreg_ref.py --emit-cases",
        "seed": int(seed),
        "scenario_count": 11,
        "scenario_ids": list(range(1, 12)),
        "named_case_count": len(named_cases),
        "random_case_count": len(random_cases),
        "case_count": len(named_cases) + len(random_cases),
        "case_counts": {"named": len(named_cases), "random": len(random_cases)},
        "scenario_counts": scenario_counts,
        "named_cases": named_cases,
        "random_cases": random_cases,
    }


def self_test():
    skeleton = json.loads((ROOT / "specs/skeleton_constants.json").read_text(encoding="utf-8"))
    cases = generate_named_cases(skeleton)
    by_name = {case["name"]: case for case in cases}
    assert {case["scenario_id"] for case in cases} == set(range(1, 12))
    assert len(cases) == 22
    assert by_name["standing_headshot"]["expected"]["records"][0]["part"] == 0
    assert abs(by_name["standing_headshot"]["expected"]["records"][0]["trace_distance"] - 494.0) <= 1e-6
    assert by_name["moving_target_rewind"]["expected"]["records"][0]["part"] == 1
    assert by_name["peek_open_world_clear"]["expected"]["records"]
    assert not by_name["peek_hidden_world_blocked"]["expected"]["records"]
    assert by_name["peek_hidden_wallbang_alt"]["expected"]["records"][0]["flags"] & SHOT_FLAG_THROUGH_WORLD
    assert by_name["backtrack_claim_clamped"]["expected"]["rewind_decision"]["reason"] == 1
    assert len(by_name["backtrack_claim_clamped"]["expected"]["records"]) == 1
    assert by_name["backtrack_claim_clamped"]["expected"]["records"][0]["outcome"] == 1
    assert by_name["backtrack_claim_clamped"]["expected"]["records"][0]["closest_dist"] <= NEAR_MISS_LOG_UNITS
    assert abs(by_name["near_miss_ladder_z_75.0"]["expected"]["records"][0]["closest_dist"] - 1.0) < 0.02
    assert by_name["near_miss_ladder_z_77.98"]["expected"]["records"][0]["closest_dist"] < 4.0
    assert not by_name["near_miss_ladder_z_78.000001"]["expected"]["records"]
    assert by_name["spread_moves_head_to_chest"]["expected"]["records"][0]["part"] == 1
    assert by_name["crouched_head"]["expected"]["records"][0]["part"] == 0
    assert abs(by_name["crouched_head"]["expected"]["records"][0]["trace_distance"] - 494.0) <= 1e-6
    assert by_name["crouched_overlap_chest"]["expected"]["records"][0]["part"] == 1
    assert abs(by_name["crouched_overlap_chest"]["expected"]["records"][0]["trace_distance"] - 490.0) <= 1e-6
    assert len(by_name["penetration_off_front_graze"]["expected"]["records"]) == 2
    assert len(by_name["penetration_on_two_hits"]["expected"]["records"]) == 2
    assert by_name["teammate_traced"]["expected"]["records"][0]["same_team"]
    assert not by_name["dead_target_ignored"]["expected"]["records"]
    assert by_name["spawned_target_missing_history"]["expected"]["rewind_decision"]["reason"] == 6
    baseline_draw = by_name["server_draw_baseline"]["expected"]["records"][0]
    changed_draw = by_name["server_draw_changes_result"]["expected"]["records"][0]
    assert (
        baseline_draw["outcome"], baseline_draw["part"], baseline_draw["region_id"]
    ) != (
        changed_draw["outcome"], changed_draw["part"], changed_draw["region_id"]
    )
    small = generate_random_cases(4242, 25, skeleton)
    assert len(small) == 25
    assert all(1 <= len(case["context"]["players"]) <= 11 for case in small)
    assert all(len(case["draws"]) == 5 for case in small)
    assert all("seed" not in case["context"]["shooter"] for case in small)
    assertions = 30
    print("hitreg_ref self-test passed %d named/random assertions" % assertions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--emit-cases")
    parser.add_argument("--seed", type=int, default=9001)
    parser.add_argument("--count", type=int, default=2000)
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
    print("%d named scenario cases; %d seeded random shots" % (
        cases["named_case_count"],
        cases["random_case_count"],
    ))
    print("scenario counts %s" % cases["scenario_counts"])
    print("case counts %s" % cases["case_counts"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
