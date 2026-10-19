#!/usr/bin/env python3
"""Independent offline reference for unsent-enemy and AIM_KIN review flags."""
import argparse
import json
import math
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.fpev_ref import FpevReader
from tools.hitreg_ref import _wire_pitch, _wire_yaw
from tools.hitreg_ref import RIFLES
from tools.lagcomp_ref import _sample_for_tick
from tools.ray_box_ref import skeleton_boxes

_SKELETON = json.loads((ROOT / "specs" / "skeleton_constants.json").read_text(encoding="utf-8"))
MOVE_NAMES = ["stand", "crouch", "air", "run"]
_RIFLE_TABLES_BY_ID = list(RIFLES.values())

DEFAULT_PARAMS = {
    "ENABLE_ANTICHEAT_REVIEW": False,
    "AIM_KIN_PROFILE": "default",
    "X_DEG": 2.0,
    "Y_MS": 250,
    "TRACKING_CORRELATION": 0.8,
    "JUST_LEFT_VIEW_MS": 500,
    "SOUND_EXPLAIN_MS": 2000,
    "SOUND_ANGLE_DEG": 4.0,
    "PREAIM_PERCENTILE": 90,
    "MIN_EPISODES": 3,
    "MIN_TARGET_SPEED": 30.0,
    "TEAM_INFO_WINDOW_MS": 3000,
    "TEAM_INFO_WEIGHT": 0.25,
    "UNSENT_HITS_REQUIRED": 2,
    "WINDOW_BEFORE_TICKS": 16,
    "WINDOW_AFTER_TICKS": 3,
    "SNAP_MIN_FIRE_DELTA_DEG": 3.0,
    "SNAPBACK_MIN_FRACTION": 0.70,
    "SNAPBACK_MAX_COS": -0.8,
    "PRE_FIRE_SPEED_MAX_FRACTION": 0.10,
    "FLICK_MIN_PEAK_ACCEL_DPS2": 200000.0,
    "FLICK_MAX_SETTLE_TICKS": 1,
    "SETTLE_FRACTION": 0.10,
    "N_AIM_KIN": 3,
    "EXCLUDE_AFTER_RESET_TICKS": 16,
    "MAX_VIEW_DELTA_DEG_PER_TICK": math.inf,
}

AIM_KIN_PROFILE_DEFAULTS = {
    "WINDOW_BEFORE_TICKS": 16,
    "WINDOW_AFTER_TICKS": 3,
    "SNAP_MIN_FIRE_DELTA_DEG": 3.0,
    "SNAPBACK_MIN_FRACTION": 0.70,
    "SNAPBACK_MAX_COS": -0.8,
    "PRE_FIRE_SPEED_MAX_FRACTION": 0.10,
    "FLICK_MIN_PEAK_ACCEL_DPS2": 200000.0,
    "FLICK_MAX_SETTLE_TICKS": 1,
    "SETTLE_FRACTION": 0.10,
    "N_AIM_KIN": 3,
    "EXCLUDE_AFTER_RESET_TICKS": 16,
}
# Surf thresholds remain provisional until telemetry exists.
AIM_KIN_PROFILE_SURF = dict(AIM_KIN_PROFILE_DEFAULTS)
AIM_KIN_PROFILES = {
    "default": AIM_KIN_PROFILE_DEFAULTS,
    "surf": AIM_KIN_PROFILE_SURF,
}


def _params_for_server_metadata(server_metadata=None, overrides=None):
    server_metadata = server_metadata or {}
    overrides = overrides or {}
    profile = "surf" if str(server_metadata.get("mode", "")) == "surf" else "default"
    params = dict(DEFAULT_PARAMS)
    params.update(AIM_KIN_PROFILES[profile])
    for key, value in overrides.items():
        if key != "AIM_KIN_PROFILE":
            params[key] = value
    if "X_DEG" in overrides and "SOUND_ANGLE_DEG" not in overrides:
        params["SOUND_ANGLE_DEG"] = 2.0 * float(params["X_DEG"])
    params["AIM_KIN_PROFILE"] = profile
    return params


def _report_params(params):
    return {
        "X_deg": float(params["X_DEG"]),
        "Y_ms": int(params["Y_MS"]),
        "C": float(params["TRACKING_CORRELATION"]),
        "G_ms": int(params["JUST_LEFT_VIEW_MS"]),
        "S_ms": int(params["SOUND_EXPLAIN_MS"]),
        "P": int(params["PREAIM_PERCENTILE"]),
        "N": int(params["MIN_EPISODES"]),
        "AIM_KIN_PROFILE": str(params["AIM_KIN_PROFILE"]),
    }


def _disabled_report(match_id, params, evidence_chain_ok=False):
    return {
        "match_id": match_id,
        "analyzer_version": "0.1",
        "params": _report_params(params),
        "evidence_chain_ok": bool(evidence_chain_ok),
        "players": [],
        "aim_kinematics": [],
        "auto_action": "NONE",
        "disabled": True,
    }

PART_HEAD = 0
PART_CHEST = 1
PART_NAMES = [
    "head", "chest", "stomach", "upper_arm_l", "upper_arm_r",
    "forearm_l", "forearm_r", "thigh_l", "thigh_r", "shin_l", "shin_r",
]
TYPE_SHOT = 1
TYPE_VIS = 2
TYPE_AIM_KIN = 6


def _round(value, places):
    scale = 10 ** places
    value = float(value)
    rounded = math.floor(value * scale + 0.5) if value >= 0 else math.ceil(value * scale - 0.5)
    result = rounded / scale
    return 0.0 if result == 0.0 else result


def _view_direction(pitch_deg, yaw_deg):
    pitch, yaw = math.radians(pitch_deg), math.radians(yaw_deg)
    cp, sp = math.cos(pitch), math.sin(pitch)
    return (
        cp * math.cos(yaw),
        cp * math.sin(yaw),
        -sp,
    )


def _angle_between(a, b):
    dot = max(-1.0, min(1.0, sum(a[i] * b[i] for i in range(3))))
    cross = (
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    )
    cross_length = math.sqrt(sum(value * value for value in cross))
    return math.degrees(math.atan2(cross_length, dot))


def _normalize(vector):
    length = math.sqrt(sum(value * value for value in vector))
    return tuple(value / length for value in vector) if length > 0 else (0.0, 0.0, 0.0)


def _eye_position(player, skeleton):
    origin = player.get("origin64", player.get("origin", [0.0, 0.0, 0.0]))
    stance = int(player.get("stance", 0))
    eye = float(skeleton["eye_stand"])
    if stance in (1, 3):
        eye *= float(skeleton["crouch_scale"])
    return tuple(float(origin[i]) + (eye if i == 2 else 0.0) for i in range(3))


def build_timeline(fixture, skeleton):
    players = fixture["players"]
    tick_rate = int(fixture["tick_rate"])
    end_tick = int(fixture["end_tick"])
    aim_windows = fixture.get("aim_windows", [])
    round_spans = fixture.get("round_spans", [])
    sound_events = fixture.get("sound_events", [])
    sounds_by_tick = {}
    for sound in sound_events:
        sounds_by_tick.setdefault(int(sound["tick"]), []).append(sound)

    states_by_tick = {}
    for player in players:
        slot = int(player["slot"])
        spawn_tick = int(player.get("spawn_tick", -1))
        death_tick = int(player.get("death_tick", -1))
        states_by_tick[slot] = {}
        for tick in range(end_tick + 1):
            state = _sample_for_tick(
                player["path"],
                tick,
                tick_rate,
                int(player.get("stance_every_n_ticks", 0)),
                spawn_tick,
                death_tick,
            )
            if "stance" in player:
                state["stance"] = int(player["stance"])
            state.update({
                "slot": slot,
                "team": int(player["team"]),
                "map_area": str(player.get("map_area", "")),
                "view_pitch": float(player.get("default_view_pitch", 0.0)),
                "view_yaw": float(player.get("default_view_yaw", 90.0)),
                "spectating": bool(player.get("spectating", False)),
                "in_menu": bool(player.get("in_menu", False)),
                "teleported": False,
                "respawned": False,
            })
            states_by_tick[slot][tick] = state

    for window in aim_windows:
        viewer_slot = int(window["viewer_slot"])
        target_slot = int(window["target_slot"])
        for tick in range(int(window["start_tick"]), int(window["end_tick"]) + 1):
            viewer = states_by_tick[viewer_slot][tick]
            target = states_by_tick[target_slot][tick]
            eye = _eye_position(viewer, skeleton)
            boxes = skeleton_boxes(
                target["origin64"], target["yaw_deg"], target["stance"], skeleton
            )
            part = int(window.get("part", PART_HEAD))
            point = boxes[part]["center64"]
            dx, dy, dz = point[0] - eye[0], point[1] - eye[1], point[2] - eye[2]
            horizontal = math.sqrt(dx * dx + dy * dy)
            pitch = -math.degrees(math.atan2(dz, horizontal))
            yaw = math.degrees(math.atan2(dy, dx))
            viewer["view_pitch"] = _wire_pitch(pitch)[1]
            viewer["view_yaw"] = _wire_yaw(yaw)[1]

    frames = []
    for tick in range(end_tick + 1):
        round_id = 0
        for span in round_spans:
            if int(span["start_tick"]) <= tick <= int(span["end_tick"]):
                round_id = int(span["round"])
                break
        frames.append({
            "tick": tick,
            "round": round_id,
            "players": [states_by_tick[slot][tick] for slot in sorted(states_by_tick)],
            "sound_events": sounds_by_tick.get(tick, []),
        })
    return frames


def run_fixture(
        fixture_path,
        evidence_path=None,
        enable_evidence_log=False,
        enable_review=False
    ):
    fixture_path = Path(fixture_path).resolve()
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    server_metadata = fixture.get("server_metadata", {})
    params_overrides = dict(fixture.get("params", {}))
    params_overrides["ENABLE_ANTICHEAT_REVIEW"] = bool(enable_review)
    params = _params_for_server_metadata(server_metadata, params_overrides)
    if not enable_evidence_log or not enable_review:
        return _disabled_report(fixture["match_id"], params)
    if evidence_path is None:
        evidence_path = fixture_path.parent / fixture["evidence_file"]
    evidence_path = Path(evidence_path).resolve()
    expected = fixture.get("expected_final_chain_sha256")
    expected_bytes = bytes.fromhex(expected) if expected else None
    evidence = FpevReader().read_file(evidence_path, expected_bytes)
    timeline = build_timeline(fixture, _SKELETON)
    return analyze(
        fixture["match_id"],
        timeline,
        evidence,
        _SKELETON,
        fixture.get("preaim_spots", []),
        params_overrides,
        server_metadata,
    )


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixture_json")
    parser.add_argument("--evidence")
    parser.add_argument("--output")
    parser.add_argument("--enable-evidence-log", action="store_true")
    parser.add_argument("--enable-review", action="store_true")
    args = parser.parse_args(argv)
    if not args.enable_evidence_log or not args.enable_review:
        parser.error("offline review is disabled by default; pass --enable-evidence-log and --enable-review")
    report = run_fixture(
        args.fixture_json,
        args.evidence,
        enable_evidence_log=args.enable_evidence_log,
        enable_review=args.enable_review,
    )
    text = json.dumps(report, indent="\t", ensure_ascii=False, sort_keys=True, allow_nan=False) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0 if report["evidence_chain_ok"] else 1




def _vis_at(vis, viewer, tick):
    current = {"sent_mask": 0, "sound_only_mask": 0}
    for event in vis.get(viewer, []):
        if event["tick"] > tick:
            break
        current = event
    return current


def _aim(viewer, target, skeleton):
    eye = _eye_position(viewer, skeleton)
    boxes = skeleton_boxes(
        target.get("origin64", target.get("origin")),
        float(target.get("yaw_deg", target.get("yaw", 0.0))),
        int(target.get("stance", 0)),
        skeleton,
    )
    view = _view_direction(viewer["view_pitch"], viewer["view_yaw"])
    best_theta, best_point, best_bearing = math.inf, (0.0, 0.0, 0.0), 0.0
    for box_id in (0, 1):
        center = boxes[box_id]["center64"]
        direction = _normalize(tuple(center[i] - eye[i] for i in range(3)))
        theta = _angle_between(view, direction)
        if theta < best_theta:
            best_theta, best_point = theta, center
            best_bearing = math.degrees(math.atan2(center[1] - eye[1], center[0] - eye[0]))
    return best_theta, tuple(best_point), best_bearing


def _recently_sent(viewer, target, start, vis, tick_rate, params):
    grace = math.ceil(float(params["JUST_LEFT_VIEW_MS"]) * tick_rate / 1000.0)
    return any(
        _vis_at(vis, viewer, tick)["sent_mask"] & (1 << target)
        for tick in range(max(0, start - grace), start)
    )


def _sound_explains(viewer_slot, target_slot, start, first, frames, vis, tick_rate, params):
    window = math.ceil(float(params["SOUND_EXPLAIN_MS"]) * tick_rate / 1000.0)
    viewer = first["viewer"]
    eye = _eye_position(viewer, _SKELETON)
    view = _view_direction(viewer["view_pitch"], viewer["view_yaw"])
    for tick in range(max(0, start - window), start + 1):
        if not (_vis_at(vis, viewer_slot, tick)["sound_only_mask"] & (1 << target_slot)):
            continue
        frame = frames.get(tick)
        if frame is None:
            continue
        for sound in frame.get("sound_events", frame.get("sounds", [])):
            if int(sound.get("source_slot", -1)) != target_slot:
                continue
            if viewer_slot not in sound.get("heard_by", []):
                continue
            position = sound.get("rounded_pos", (0.0, 0.0, 0.0))
            direction = _normalize(tuple(float(position[i]) - eye[i] for i in range(3)))
            if _angle_between(view, direction) <= float(params["SOUND_ANGLE_DEG"]):
                return True
    return False


def _preaim_explains(point, map_area, spots):
    for spot in spots:
        if "map_area" in spot and spot["map_area"] != map_area:
            continue
        position = spot["point"]
        distance2 = sum((float(point[i]) - float(position[i])) ** 2 for i in range(3))
        if distance2 <= float(spot["radius"]) ** 2:
            return True
    return False


def _teammate_has_target_sent(viewer_slot, target_slot, start, ticks, frames, vis, teams, tick_rate, params):
    window = math.ceil(float(params["TEAM_INFO_WINDOW_MS"]) * tick_rate / 1000.0)
    for tick in ticks:
        if tick < start - window or tick > start:
            continue
        frame = frames[tick]
        for teammate in frame["players"]:
            slot = int(teammate["slot"])
            if slot == viewer_slot or teams.get(slot, 0) != teams.get(viewer_slot, -1):
                continue
            if not teammate.get("alive", True):
                continue
            if _vis_at(vis, slot, tick)["sent_mask"] & (1 << target_slot):
                return True
    return False


def _pearson(a, b):
    if len(a) < 2 or len(a) != len(b):
        return 0.0
    mean_a, mean_b = sum(a) / len(a), sum(b) / len(b)
    covariance = sum((x - mean_a) * (y - mean_b) for x, y in zip(a, b))
    variance_a = sum((x - mean_a) ** 2 for x in a)
    variance_b = sum((y - mean_b) ** 2 for y in b)
    if variance_a <= 0.0 or variance_b <= 0.0:
        return 0.0
    return covariance / math.sqrt(variance_a * variance_b)


def _angle_delta(a, b):
    return (float(b) - float(a) + 180.0) % 360.0 - 180.0


def _tracking_stats(run, tick_rate):
    yaw_rates, bearing_rates, speeds = [], [], []
    for before, after in zip(run, run[1:]):
        dt = int(after["tick"]) - int(before["tick"])
        if dt <= 0:
            continue
        yaw_rates.append(
            _angle_delta(before["viewer"]["view_yaw"], after["viewer"]["view_yaw"])
            * tick_rate / dt
        )
        bearing_rates.append(
            _angle_delta(before["bearing"], after["bearing"]) * tick_rate / dt
        )
        start = before["target"].get("origin64", before["target"].get("origin"))
        end = after["target"].get("origin64", after["target"].get("origin"))
        distance = math.sqrt(sum((float(end[i]) - float(start[i])) ** 2 for i in range(3)))
        speeds.append(distance * tick_rate / dt)
    speed = sum(speeds) / len(speeds) if speeds else 0.0
    return _pearson(yaw_rates, bearing_rates), speed


def _finish_run(run, viewer_slot, target_slot, ticks, frames, vis, spots, teams, tick_rate, params):
    minimum = math.ceil(float(params["Y_MS"]) * tick_rate / 1000.0)
    if len(run) < minimum:
        return None
    start = int(run[0]["tick"])
    end = int(run[-1]["tick"])
    drop_reasons = []
    checked = ["just_left_view", "sound", "preaim", "teammate", "dead", "same_team"]
    if _recently_sent(viewer_slot, target_slot, start, vis, tick_rate, params):
        drop_reasons.append("just_left_view")
    if _sound_explains(viewer_slot, target_slot, start, run[0], frames, vis, tick_rate, params):
        drop_reasons.append("sound")
    if _preaim_explains(run[0]["target_point"], run[0]["viewer"].get("map_area", ""), spots):
        drop_reasons.append("preaim")
    viewer = run[0]["viewer"]
    if not viewer.get("alive", True) or viewer.get("spectating", False) or viewer.get("in_menu", False):
        drop_reasons.append("dead")
    if teams.get(viewer_slot, 0) == teams.get(target_slot, -1):
        drop_reasons.append("same_team")
    correlation, speed = _tracking_stats(run, tick_rate)
    tracking = speed > float(params["MIN_TARGET_SPEED"]) \
        and correlation >= float(params["TRACKING_CORRELATION"])
    weight = 0.0 if drop_reasons else 1.0
    if weight > 0.0 and _teammate_has_target_sent(
            viewer_slot, target_slot, start, ticks, frames, vis, teams, tick_rate, params):
        weight = float(params["TEAM_INFO_WEIGHT"])
        drop_reasons.append("teammate")
    return {
        "kind": "tracking" if tracking else "aim",
        "target_slot": target_slot,
        "round": int(run[0]["round"]),
        "start_tick": start,
        "end_tick": end,
        "min_theta_deg": _round(min(item["theta_deg"] for item in run), 4),
        "tracking_correlation": _round(correlation, 4),
        "target_speed_ups": _round(speed, 3),
        "dropped_reasons_checked": checked,
        "dropped": weight == 0.0,
        "drop_reasons": drop_reasons,
        "weight": weight,
    }


def _pair_episodes(viewer_slot, target_slot, ticks, frames, vis, spots, teams, tick_rate, params):
    episodes, run = [], []
    for tick in ticks:
        frame = frames[tick]
        players = frame["players_by_slot"]
        if viewer_slot not in players or target_slot not in players:
            finished = _finish_run(run, viewer_slot, target_slot, ticks, frames, vis, spots, teams, tick_rate, params)
            if finished:
                episodes.append(finished)
            run = []
            continue
        viewer, target = players[viewer_slot], players[target_slot]
        active = viewer.get("alive", True) and not viewer.get("spectating", False) and not viewer.get("in_menu", False)
        target_sent = bool(_vis_at(vis, viewer_slot, tick)["sent_mask"] & (1 << target_slot))
        if not active or not target.get("alive", True) or target_sent:
            finished = _finish_run(run, viewer_slot, target_slot, ticks, frames, vis, spots, teams, tick_rate, params)
            if finished:
                episodes.append(finished)
            run = []
            continue
        theta, point, bearing = _aim(viewer, target, _SKELETON)
        if theta <= float(params["X_DEG"]):
            if run and tick != int(run[-1]["tick"]) + 1:
                finished = _finish_run(run, viewer_slot, target_slot, ticks, frames, vis, spots, teams, tick_rate, params)
                if finished:
                    episodes.append(finished)
                run = []
            run.append({
                "tick": tick,
                "theta_deg": theta,
                "viewer": viewer,
                "target": target,
                "target_point": point,
                "bearing": bearing,
                "round": int(frame.get("round", 0)),
            })
        else:
            finished = _finish_run(run, viewer_slot, target_slot, ticks, frames, vis, spots, teams, tick_rate, params)
            if finished:
                episodes.append(finished)
            run = []
    finished = _finish_run(run, viewer_slot, target_slot, ticks, frames, vis, spots, teams, tick_rate, params)
    if finished:
        episodes.append(finished)
    return episodes


def _shots_at_unsent(viewer_slot, records):
    shots = []
    for record in records:
        if int(record["type"]) != TYPE_SHOT or int(record["fields"]["shooter_slot"]) != viewer_slot:
            continue
        flags = int(record["flags"])
        if not flags & (1 << 3):
            continue
        fields = record["fields"]
        shots.append({
            "tick": int(record["tick"]),
            "target_slot": int(fields["target_slot"]),
            "outcome": "hit" if int(fields["outcome"]) == 0 else "near_miss",
            "through_world": bool(flags & (1 << 2)),
        })
    return shots


def _aim_kinematics(records, frames, shots_by_player):
    shot_lookup = {}
    for shooter, shots in shots_by_player.items():
        for shot in shots:
            fields = shot["fields"]
            if "shot_index" in fields:
                key = (int(shooter), int(fields["shot_index"]))
                previous = shot_lookup.get(key)
                if previous is None or (
                        int(previous["fields"]["outcome"]) != 0
                        and int(fields["outcome"]) == 0):
                    shot_lookup[key] = shot
    result = []
    flagged_rounds = {}
    for record in records:
        if int(record["type"]) != TYPE_AIM_KIN or int(record["flags"]) & 0x03 == 0:
            continue
        fields = record["fields"]
        shooter = int(fields["shooter_slot"])
        shot_index = int(fields["shot_index"])
        shot = shot_lookup.get((shooter, shot_index))
        if shot is None:
            continue
        tick = int(record["tick"])
        frame = frames.get(tick, {})
        round_id = int(frame.get("round", 0))
        flags = int(record["flags"])
        flag_names = []
        if flags & 1:
            flag_names.append("snapback")
        if flags & 2:
            flag_names.append("flick_stop_at_fire")
        shot_fields = shot["fields"]
        weapon_id = int(shot_fields["weapon_id"])
        weapon_index = weapon_id - 1
        if weapon_index < 0 or weapon_index >= len(_RIFLE_TABLES_BY_ID):
            continue
        weapon = _RIFLE_TABLES_BY_ID[weapon_index]
        move_state = int(fields["move_state"])
        move_name = MOVE_NAMES[move_state] if move_state < len(MOVE_NAMES) else "unknown"
        spread_state = "run" if move_state == 3 else move_name
        spread_table = weapon["spread"][spread_state]
        entry = {
            "tick": tick,
            "shooter_slot": shooter,
            "round": round_id,
            "shot_index": shot_index,
            "flags": flag_names,
            "move_state": move_name,
            "spread_at_fire": _round(fields["spread_at_fire"], 6),
            "spread_at_first_shot_minimum": float(fields["spread_at_fire"]) <= float(spread_table[0]) + 1e-6,
            "peak_ang_vel_dps": _round(fields["peak_ang_vel_dps"], 6),
            "peak_ang_accel_dps2": _round(fields["peak_ang_accel_dps2"], 6),
            "fire_tick_delta_deg": _round(fields["fire_tick_delta_deg"], 6),
            "snapback_deg": _round(fields["snapback_deg"], 6),
            "snapback_cos": _round(fields["snapback_cos"], 6),
            "pre_fire_speed_dps": _round(fields["pre_fire_speed_dps"], 6),
            "settle_ticks": int(fields["settle_ticks"]),
            "shot_outcome": "hit" if int(shot_fields["outcome"]) == 0 else "near_miss",
            "part": PART_NAMES[min(max(int(shot_fields["part"]), 0), len(PART_NAMES) - 1)],
        }
        result.append(entry)
        flagged_rounds.setdefault(shooter, set()).add(round_id)
    return result, flagged_rounds


def analyze(
        match_id,
        timeline,
        evidence,
        skeleton,
        preaim_spots=None,
        params_overrides=None,
        server_metadata=None
    ):
    params = _params_for_server_metadata(server_metadata, params_overrides)
    if not bool(params["ENABLE_ANTICHEAT_REVIEW"]):
        return _disabled_report(match_id, params, bool(evidence.get("ok", False)))
    frames = {}
    for source in timeline:
        frame = dict(source)
        frame["players_by_slot"] = {int(player["slot"]): player for player in source["players"]}
        frames[int(frame["tick"])] = frame
    ticks = sorted(frames)
    header = evidence.get("header", {})
    slots = header.get("slots", [])
    teams = {int(slot["slot"]): int(slot["team"]) for slot in slots}
    refs = {int(slot["slot"]): bytes(slot["player_ref"]).hex() for slot in slots}
    records = evidence.get("records", [])
    vis = _vis_by_viewer(records)
    shots_by_player = {}
    for record in records:
        if int(record["type"]) == TYPE_SHOT:
            slot = int(record["fields"]["shooter_slot"])
            shots_by_player.setdefault(slot, []).append(record)
    for shots in shots_by_player.values():
        shots.sort(key=lambda record: (int(record["tick"]), int(record["fields"].get("shot_index", 0))))

    aim_kinematics, flagged_rounds = _aim_kinematics(records, frames, shots_by_player)
    output_players = []
    for viewer in range(len(slots)):
        episodes = []
        for target in range(len(slots)):
            if target == viewer or teams[target] == teams[viewer]:
                continue
            episodes.extend(_pair_episodes(
                viewer, target, ticks, frames, vis, preaim_spots or [], teams,
                int(header.get("tick_rate", 128)), params
            ))
        episodes.sort(key=lambda episode: (episode["start_tick"], episode["target_slot"]))
        weighted = sum(float(episode["weight"]) for episode in episodes)
        shots = _shots_at_unsent(viewer, shots_by_player.get(viewer, []))
        clean_hits = sum(
            1 for shot in shots
            if shot["outcome"] == "hit" and not shot["through_world"]
        )
        aim_rounds = flagged_rounds.get(viewer, set())
        needs_review = (
            bool(evidence.get("ok", False))
            and (
                weighted >= float(params["MIN_EPISODES"])
                or clean_hits >= int(params["UNSENT_HITS_REQUIRED"])
                or len(aim_rounds) >= int(params["N_AIM_KIN"])
            )
        )
        output_players.append({
            "slot": viewer,
            "player_ref": refs.get(viewer, ""),
            "weighted_episodes": _round(weighted, 4),
            "episodes": episodes,
            "shots_at_unsent": shots,
            "status": "NEEDS_HUMAN_REVIEW" if needs_review else "NO_FLAG",
        })
    return {
        "match_id": match_id,
        "analyzer_version": "0.1",
        "params": _report_params(params),
        "evidence_chain_ok": bool(evidence.get("ok", False)),
        "players": output_players,
        "aim_kinematics": aim_kinematics,
        "auto_action": "NONE",
    }


def _vis_by_viewer(records):
    result = {}
    for record in records:
        if int(record["type"]) != TYPE_VIS:
            continue
        fields = record["fields"]
        result.setdefault(int(fields["viewer_slot"]), []).append({
            "tick": int(record["tick"]),
            "sent_mask": int(fields["sent_mask"]),
            "sound_only_mask": int(fields["sound_only_mask"]),
        })
    for events in result.values():
        events.sort(key=lambda event: event["tick"])
    return result

if __name__ == "__main__":
    raise SystemExit(main())
