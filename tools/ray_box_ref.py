#!/usr/bin/env python3
"""Independent Python reference for segment/OBB hits and near misses."""
import argparse
import hashlib
import json
import math
import random
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SKELETON_PATH = ROOT / "specs" / "skeleton_constants.json"
BASE_CASES_PATH = ROOT / "weapons_proto" / "tests" / "ray_box_cases.json"
PARALLEL_EPS = 1e-12
DISTANCE_TIE_EPS = 1e-6
UNIT_DIRECTION_EPS = 1e-9
NEAR_MISS_UNITS = 1.0
HITBOX_PADDING = 2.0
NEAR_MISS_LOG_UNITS = 4.0
HASH_SCALE = 1_000_000_000
PARTS = [
    "head", "chest", "stomach", "upper_arm_l", "upper_arm_r",
    "forearm_l", "forearm_r", "thigh_l", "thigh_r", "shin_l", "shin_r",
]


def add(a, b):
    return tuple(a[i] + b[i] for i in range(3))


def sub(a, b):
    return tuple(a[i] - b[i] for i in range(3))


def scale(v, amount):
    return tuple(v[i] * amount for i in range(3))


def dot(a, b):
    return sum(a[i] * b[i] for i in range(3))


def length(v):
    return math.sqrt(dot(v, v))


def normalize(v):
    magnitude = length(v)
    if magnitude == 0.0:
        raise ValueError("cannot normalize a zero vector")
    return scale(v, 1.0 / magnitude)


def _valid_ray(origin, direction, segment_length):
    try:
        origin = tuple(float(value) for value in origin)
        direction = tuple(float(value) for value in direction)
        segment_length = float(segment_length)
    except (TypeError, ValueError, OverflowError):
        return False
    if len(origin) != 3 or len(direction) != 3:
        return False
    if not math.isfinite(segment_length) or segment_length < 0.0:
        return False
    if not all(math.isfinite(value) for value in (*origin, *direction)):
        return False
    direction_length_squared = dot(direction, direction)
    return (
        math.isfinite(direction_length_squared)
        and abs(direction_length_squared - 1.0) <= UNIT_DIRECTION_EPS
    )


def _valid_box(box):
    try:
        center = tuple(float(value) for value in box["center64"])
        half = tuple(float(value) for value in box["half64"])
        yaw = float(box["yaw_deg"])
        int(box["id"])
        str(box["part"])
    except (KeyError, TypeError, ValueError, OverflowError):
        return False
    return (
        len(center) == 3
        and len(half) == 3
        and math.isfinite(yaw)
        and all(math.isfinite(value) for value in (*center, *half))
        and all(value >= 0.0 for value in half)
    )


def _valid_boxes(boxes, padding_by_box=None, default_padding=0.0):
    try:
        for box in boxes:
            if not _valid_box(box):
                return False
            padding = _padding_for_box(box, padding_by_box, default_padding)
            if not math.isfinite(padding) or padding < 0.0:
                return False
    except (TypeError, ValueError, OverflowError):
        return False
    return True


def _miss_result():
    return {
        "outcome": "none",
        "box_id": -1,
        "part": "",
        "dist": math.inf,
        "ray_point": (0.0, 0.0, 0.0),
        "box_point": (0.0, 0.0, 0.0),
    }


def rotate_to_world(center, local, yaw_deg):
    angle = math.radians(yaw_deg)
    c, s = math.cos(angle), math.sin(angle)
    return (
        center[0] + c * local[0] - s * local[1],
        center[1] + s * local[0] + c * local[1],
        center[2] + local[2],
    )


def rotate_to_local(vector, yaw_deg):
    angle = math.radians(yaw_deg)
    c, s = math.cos(angle), math.sin(angle)
    return (
        c * vector[0] + s * vector[1],
        -s * vector[0] + c * vector[1],
        vector[2],
    )


def point_to_box_local(point, half):
    closest = tuple(min(max(point[i], -half[i]), half[i]) for i in range(3))
    difference = sub(point, closest)
    return dot(difference, difference), closest


def _world_to_box(point, box):
    return rotate_to_local(sub(point, box["center64"]), box["yaw_deg"])


def _padding_for_box(box, padding_by_box=None, default_padding=0.0):
    if padding_by_box is None:
        return float(default_padding)
    box_id = int(box["id"])
    if box_id in padding_by_box:
        return float(padding_by_box[box_id])
    if str(box_id) in padding_by_box:
        return float(padding_by_box[str(box_id)])
    return float(default_padding)


def intersect_box(origin, direction, segment_length, box, padding=0.0):
    """Finite segment slab test in the box's yaw-local frame."""
    if (
        not _valid_ray(origin, direction, segment_length)
        or not _valid_box(box)
        or not math.isfinite(float(padding))
        or float(padding) < 0.0
    ):
        return None
    origin = tuple(float(value) for value in origin)
    direction = tuple(float(value) for value in direction)
    segment_length = float(segment_length)
    padding = float(padding)
    half = tuple(float(value) + padding for value in box["half64"])
    local_origin = _world_to_box(origin, box)
    local_direction = tuple(
        0.0 if abs(value) < PARALLEL_EPS else value
        for value in rotate_to_local(direction, box["yaw_deg"])
    )
    if all(abs(local_origin[i]) <= half[i] for i in range(3)):
        return {
            "box_id": box["id"],
            "part": box["part"],
            "dist": 0.0,
            "point": tuple(origin),
            "normal": (0.0, 0.0, 0.0),
        }

    t_enter = -math.inf
    t_exit = math.inf
    enter_axis = -1
    enter_sign = 0.0
    for axis in range(3):
        o, d, h = local_origin[axis], local_direction[axis], half[axis]
        if abs(d) < PARALLEL_EPS:
            if abs(o) > h:
                return None
            continue
        t1 = (-h - o) / d
        t2 = (h - o) / d
        near_t, far_t = min(t1, t2), max(t1, t2)
        if near_t > t_enter:
            t_enter = near_t
            enter_axis = axis
            enter_sign = -1.0 if d > 0.0 else 1.0
        t_exit = min(t_exit, far_t)
        if t_enter > t_exit:
            return None

    if t_exit < 0.0 or t_enter > segment_length:
        return None
    distance = max(t_enter, 0.0)
    if distance > segment_length:
        return None
    point = add(origin, scale(direction, distance))
    normal_local = [0.0, 0.0, 0.0]
    if enter_axis >= 0:
        normal_local[enter_axis] = enter_sign
    angle = math.radians(box["yaw_deg"])
    c, s = math.cos(angle), math.sin(angle)
    normal = (
        c * normal_local[0] - s * normal_local[1],
        s * normal_local[0] + c * normal_local[1],
        normal_local[2],
    )
    return {
        "box_id": box["id"],
        "part": box["part"],
        "dist": distance,
        "point": point,
        "normal": normal,
    }


def box_priority(box_id):
    if box_id == 0:
        return 0
    if box_id == 1:
        return 1
    if box_id == 2:
        return 2
    if box_id in (3, 4):
        return 3
    if box_id in (5, 6):
        return 4
    if box_id in (7, 8):
        return 5
    if box_id in (9, 10):
        return 6
    return 7


def select_distance_tie(candidates):
    minimum = min(item["dist"] for item in candidates)
    eligible = [
        item for item in candidates
        if item["dist"] <= minimum + DISTANCE_TIE_EPS
    ]
    return min(eligible, key=lambda item: (box_priority(item["box_id"]), item["box_id"]))


def trace_boxes(origin, direction, segment_length, boxes, padding_by_box=None, default_padding=0.0):
    if (
        not _valid_ray(origin, direction, segment_length)
        or not _valid_boxes(boxes, padding_by_box, default_padding)
    ):
        return None
    hits = [
        hit for box in boxes
        if (hit := intersect_box(
            origin,
            direction,
            segment_length,
            box,
            _padding_for_box(box, padding_by_box, default_padding),
        )) is not None
    ]
    return select_distance_tie(hits) if hits else None


def _golden_section_minimum(function, lower, upper):
    """Independent convex minimizer used instead of the GDScript breakpoints."""
    if upper <= lower:
        return lower
    ratio = (math.sqrt(5.0) - 1.0) * 0.5
    left = upper - ratio * (upper - lower)
    right = lower + ratio * (upper - lower)
    f_left, f_right = function(left), function(right)
    for _ in range(120):
        if f_left <= f_right:
            upper, right, f_right = right, left, f_left
            left = upper - ratio * (upper - lower)
            f_left = function(left)
        else:
            lower, left, f_left = left, right, f_right
            right = lower + ratio * (upper - lower)
            f_right = function(right)
    estimate = (lower + upper) * 0.5
    best_value = function(estimate)

    # Choose the earliest point on a flat minimum, matching the deterministic
    # tie convention without sharing the GDScript's piecewise-quadratic method.
    left, right = 0.0, estimate
    for _ in range(100):
        midpoint = (left + right) * 0.5
        if function(midpoint) <= best_value + 1e-24:
            right = midpoint
        else:
            left = midpoint
    return right


def closest_segment_box(origin, direction, segment_length, box, padding=0.0):
    if (
        not _valid_ray(origin, direction, segment_length)
        or not _valid_box(box)
        or not math.isfinite(float(padding))
        or float(padding) < 0.0
    ):
        return _miss_result()
    origin = tuple(float(value) for value in origin)
    direction = tuple(float(value) for value in direction)
    segment_length = float(segment_length)
    padding = float(padding)
    half = tuple(float(value) + padding for value in box["half64"])
    local_origin = _world_to_box(origin, box)
    local_direction = rotate_to_local(direction, box["yaw_deg"])
    local_direction = tuple(
        0.0 if abs(value) < PARALLEL_EPS else value
        for value in local_direction
    )

    def distance_squared(t):
        point = add(local_origin, scale(local_direction, t))
        return point_to_box_local(point, half)[0]

    t = _golden_section_minimum(distance_squared, 0.0, segment_length)
    local_ray_point = add(local_origin, scale(local_direction, t))
    _, local_box_point = point_to_box_local(local_ray_point, half)
    ray_point = add(origin, scale(direction, t))
    box_point = rotate_to_world(box["center64"], local_box_point, box["yaw_deg"])
    return {
        "box_id": box["id"],
        "part": box["part"],
        "dist": math.sqrt(distance_squared(t)),
        "ray_point": ray_point,
        "box_point": box_point,
    }


def trace_target(
    origin,
    direction,
    segment_length,
    boxes,
    padding_by_box=None,
    near_miss_limit=NEAR_MISS_LOG_UNITS,
    default_padding=0.0,
):
    if (
        not _valid_ray(origin, direction, segment_length)
        or not math.isfinite(float(near_miss_limit))
        or float(near_miss_limit) < 0.0
        or not _valid_boxes(boxes, padding_by_box, default_padding)
    ):
        return _miss_result()
    near_miss_limit = float(near_miss_limit)
    hit = trace_boxes(origin, direction, segment_length, boxes, padding_by_box, default_padding)
    if hit is not None:
        return {
            "outcome": "hit",
            "box_id": hit["box_id"],
            "part": hit["part"],
            "dist": hit["dist"],
            "ray_point": hit["point"],
            "box_point": hit["point"],
        }
    closest = [
        closest_segment_box(
            origin,
            direction,
            segment_length,
            box,
            _padding_for_box(box, padding_by_box, default_padding),
        )
        for box in boxes
    ]
    if not closest:
        return {
            "outcome": "none",
            "box_id": -1,
            "part": "",
            "dist": math.inf,
            "ray_point": (0.0, 0.0, 0.0),
            "box_point": (0.0, 0.0, 0.0),
        }
    best = select_distance_tie(closest)
    best["outcome"] = (
        "near_miss"
        if 0.0 < best["dist"] <= near_miss_limit
        else "none"
    )
    return best


def make_box(box_id, part, center, half, yaw_deg):
    return {
        "id": int(box_id),
        "part": part,
        "center64": [float(value) for value in center],
        "half64": [float(value) for value in half],
        "yaw_deg": float(yaw_deg),
    }


def skeleton_boxes(origin, yaw_deg, stance, skeleton, duck_fraction=None):
    fraction = (1.0 if stance in (1, 3) else 0.0) if duck_fraction is None else float(duck_fraction)
    if not math.isfinite(fraction) or not 0.0 <= fraction <= 1.0:
        raise ValueError("duck_fraction must be finite and in [0.0, 1.0]")
    boxes = []
    for source in skeleton["boxes"]:
        center = list(source["center_stand"])
        size = source["size"]
        half = [value * 0.5 for value in size]
        stand_bottom = center[2] - half[2]
        stand_top = center[2] + half[2]
        if source["fixed_size_in_crouch"]:
            crouch_top = skeleton["crouch_scale"] * skeleton["stand_height"]
            crouch_bottom = crouch_top - size[2]
        else:
            crouch_bottom = stand_bottom * skeleton["crouch_scale"]
            crouch_top = stand_top * skeleton["crouch_scale"]
        bottom = stand_bottom + (crouch_bottom - stand_bottom) * fraction
        top = stand_top + (crouch_top - stand_top) * fraction
        center[2] = (bottom + top) * 0.5
        half[2] = (top - bottom) * 0.5
        world_center = rotate_to_world(origin, center, yaw_deg)
        boxes.append(make_box(source["id"], source["part"], world_center, half, yaw_deg))
    return boxes


def _case(
    category,
    origin,
    direction,
    segment_length,
    boxes,
    near_miss_limit=NEAR_MISS_UNITS,
):
    expected = trace_target(
        origin,
        direction,
        segment_length,
        boxes,
        near_miss_limit=near_miss_limit,
    )
    return {
        "category": category,
        "origin": [float(value) for value in origin],
        "direction": [float(value) for value in direction],
        "length": float(segment_length),
        "near_miss_limit": float(near_miss_limit),
        "boxes": boxes,
        "expected": {
            "outcome": expected["outcome"],
            "box_id": int(expected["box_id"]),
            "part": expected["part"],
            "dist": float(expected["dist"]),
            "ray_point": [float(value) for value in expected["ray_point"]],
            "box_point": [float(value) for value in expected["box_point"]],
        },
    }


def _random_box(rng, box_id=None):
    if box_id is None:
        box_id = rng.randrange(11)
    center = (
        rng.uniform(-1000.0, 1000.0),
        rng.uniform(-1000.0, 1000.0),
        rng.uniform(-64.0, 160.0),
    )
    half = (
        rng.uniform(3.0, 12.0),
        rng.uniform(3.0, 12.0),
        rng.uniform(4.0, 14.0),
    )
    yaw = rng.uniform(-180.0, 180.0)
    return make_box(box_id, PARTS[box_id], center, half, yaw)


def _aimed_hit_case(rng):
    box = _random_box(rng)
    half = box["half64"]
    local_target = tuple(rng.uniform(-0.8 * half[i], 0.8 * half[i]) for i in range(3))
    target = rotate_to_world(box["center64"], local_target, box["yaw_deg"])
    distance = rng.uniform(20.0, 1000.0)
    local_origin = (
        -distance,
        rng.uniform(-20.0, 20.0),
        rng.uniform(-12.0, 12.0),
    )
    origin = rotate_to_world(box["center64"], local_origin, box["yaw_deg"])
    direction = normalize(sub(target, origin))
    segment_length = length(sub(target, origin)) + rng.uniform(0.0, 100.0)
    return _case("aimed_hit", origin, direction, segment_length, [box])


def _near_miss_case(rng):
    box = _random_box(rng)
    half = box["half64"]
    gap = rng.uniform(1e-5, 3.0)
    distance = rng.uniform(20.0, 1000.0)
    local_origin = (
        -distance,
        half[1] + gap,
        rng.uniform(-0.5 * half[2], 0.5 * half[2]),
    )
    origin = rotate_to_world(box["center64"], local_origin, box["yaw_deg"])
    direction = rotate_to_local((1.0, 0.0, 0.0), -box["yaw_deg"])
    return _case("near_miss", origin, direction, 2.0 * distance, [box])


def _parallel_case(rng):
    box_id = rng.randrange(11)
    half = (
        rng.uniform(3.0, 12.0),
        rng.uniform(3.0, 12.0),
        rng.uniform(4.0, 14.0),
    )
    box = make_box(box_id, PARTS[box_id], (0.0, 0.0, 0.0), half, 0.0)
    distance = rng.uniform(20.0, 1000.0)
    offset = rng.choice([0.0, 1e-9, 0.25, 0.99, 1.01])
    if rng.randrange(2) == 0:
        origin = (-distance, half[1] + offset, rng.uniform(-half[2], half[2]))
    else:
        origin = (-distance, rng.uniform(-half[1], half[1]), half[2] + offset)
    direction = (1.0, 0.0, 0.0)
    return _case("parallel", origin, direction, 2.0 * distance, [box])


def _inside_case(rng):
    box = _random_box(rng)
    half = box["half64"]
    local_origin = tuple(rng.uniform(-0.8 * half[i], 0.8 * half[i]) for i in range(3))
    local_direction = normalize(tuple(rng.uniform(-1.0, 1.0) for _ in range(3)))
    origin = rotate_to_world(box["center64"], local_origin, box["yaw_deg"])
    direction = rotate_to_local(local_direction, -box["yaw_deg"])
    return _case("inside", origin, direction, rng.uniform(0.0, 100.0), [box])


def _segment_short_case(rng):
    box = _random_box(rng)
    half = box["half64"]
    distance = rng.uniform(50.0, 500.0)
    gap = rng.uniform(1.0, 10.0)
    local_origin = (-distance, 0.0, 0.0)
    origin = rotate_to_world(box["center64"], local_origin, box["yaw_deg"])
    direction = rotate_to_local((1.0, 0.0, 0.0), -box["yaw_deg"])
    segment_length = distance - half[0] - gap
    return _case("segment_short", origin, direction, segment_length, [box])


def _box_behind_case(rng):
    box = _random_box(rng)
    distance = rng.uniform(50.0, 500.0)
    local_origin = (distance, 0.0, 0.0)
    origin = rotate_to_world(box["center64"], local_origin, box["yaw_deg"])
    direction = rotate_to_local((1.0, 0.0, 0.0), -box["yaw_deg"])
    return _case("box_behind", origin, direction, rng.uniform(10.0, 1000.0), [box])


def _multi_box_case(rng, skeleton):
    target_origin = (
        rng.uniform(-1000.0, 1000.0),
        rng.uniform(-1000.0, 1000.0),
        0.0,
    )
    yaw = rng.uniform(-180.0, 180.0)
    stance = rng.randrange(4)
    boxes = skeleton_boxes(target_origin, yaw, stance, skeleton)
    target_box = rng.choice(boxes)
    half = target_box["half64"]
    local_point = tuple(rng.uniform(-0.6 * half[i], 0.6 * half[i]) for i in range(3))
    target = rotate_to_world(target_box["center64"], local_point, yaw)
    direction = normalize(tuple(rng.uniform(-1.0, 1.0) for _ in range(3)))
    distance = rng.uniform(100.0, 1500.0)
    origin = sub(target, scale(direction, distance))
    return _case("multi_box", origin, direction, distance + rng.uniform(0.0, 500.0), boxes)


def generate_random_cases(seed, count, skeleton):
    rng = random.Random(seed)
    counts = {
        "aimed_hit": count * 3 // 10,
        "near_miss": count * 3 // 10,
        "parallel": count // 10,
        "inside": count // 10,
        "segment_short": count // 20,
        "box_behind": count // 20,
    }
    counts["multi_box"] = count - sum(counts.values())
    generators = {
        "aimed_hit": lambda: _aimed_hit_case(rng),
        "near_miss": lambda: _near_miss_case(rng),
        "parallel": lambda: _parallel_case(rng),
        "inside": lambda: _inside_case(rng),
        "segment_short": lambda: _segment_short_case(rng),
        "box_behind": lambda: _box_behind_case(rng),
        "multi_box": lambda: _multi_box_case(rng, skeleton),
    }
    cases = []
    for category, category_count in counts.items():
        for _ in range(category_count):
            cases.append(generators[category]())
    return cases, counts


def generate_boundary_cases(skeleton):
    cases = []
    target_origin = (500.0, 0.0, 0.0)
    target_boxes = skeleton_boxes(target_origin, 180.0, 0, skeleton)
    for z, category in (
        (72.5, "boundary_near_0_5"),
        (72.99, "boundary_near_0_99"),
        (73.0, "boundary_near_1_0"),
        (73.01, "boundary_near_1_01"),
    ):
        cases.append(_case(
            category,
            (0.0, 0.0, z),
            (1.0, 0.0, 0.0),
            8192.0,
            target_boxes,
        ))

    edge_box = make_box(0, "head", (0.0, 0.0, 0.0), (1.0, 1.0, 1.0), 0.0)
    diagonal = math.sqrt(0.5)
    cases.append(_case(
        "boundary_edge_graze",
        (-2.0, 0.0, 0.0),
        (diagonal, diagonal, 0.0),
        10.0,
        [edge_box],
    ))

    standing_boxes = skeleton_boxes(target_origin, 180.0, 0, skeleton)
    cases.append(_case(
        "boundary_thigh_overlap",
        (0.0, 0.0, 30.5),
        (1.0, 0.0, 0.0),
        8192.0,
        standing_boxes,
    ))

    crouched_boxes = skeleton_boxes(target_origin, 180.0, 1, skeleton)
    cases.append(_case(
        "boundary_crouched_head",
        (0.0, 0.0, 33.0),
        (1.0, 0.0, 0.0),
        8192.0,
        crouched_boxes,
    ))
    cases.append(_case(
        "boundary_crouched_chest_overlap",
        (0.0, 0.0, 27.25),
        (1.0, 0.0, 0.0),
        8192.0,
        crouched_boxes,
    ))

    cases.append(_case(
        "boundary_pad_near_4",
        (0.0, 0.0, 78.0),
        (1.0, 0.0, 0.0),
        8192.0,
        target_boxes,
    ))
    cases.append(_case(
        "boundary_pad_near_over_4",
        (0.0, 0.0, 78.000001),
        (1.0, 0.0, 0.0),
        8192.0,
        target_boxes,
    ))

    for yaw in (0.0, 90.0, 180.0, 270.0, 359.999):
        yaw_boxes = skeleton_boxes(target_origin, yaw, 0, skeleton)
        cases.append(_case(
            "boundary_yaw_%s" % str(yaw),
            (0.0, 0.0, 66.0),
            (1.0, 0.0, 0.0),
            8192.0,
            yaw_boxes,
        ))
    return cases


def quantize_hash_value(value):
    scaled = float(value) * HASH_SCALE
    if scaled >= 0.0:
        return int(math.floor(scaled + 0.5))
    return int(math.ceil(scaled - 0.5))


def canonical_expected_rows(cases):
    rows = []
    for case in cases:
        expected = case["expected"]
        rows.append({
            "box_id": int(expected["box_id"]),
            "box_point_q": [quantize_hash_value(v) for v in expected["box_point"]],
            "dist_q": quantize_hash_value(expected["dist"]),
            "outcome": expected["outcome"],
            "part": expected["part"],
            "ray_point_q": [quantize_hash_value(v) for v in expected["ray_point"]],
        })
    return rows


def expected_sha256(cases):
    canonical = json.dumps(
        canonical_expected_rows(cases),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def canonical_skeleton_sha256(skeleton):
    canonical = json.dumps(
        skeleton,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def count_categories(cases):
    counts = {}
    for case in cases:
        category = case["category"]
        counts[category] = counts.get(category, 0) + 1
    return counts


def generate_cases(seed=1337, count=20000):
    if count < 1:
        raise ValueError("count must be positive")
    skeleton = json.loads(SKELETON_PATH.read_text(encoding="utf-8"))
    random_cases, random_counts = generate_random_cases(seed, count, skeleton)
    cases = random_cases + generate_boundary_cases(skeleton)
    return {
        "generator": "tools/ray_box_ref.py --emit-cases",
        "fixture_scope": "legacy zero-padding baseline; per-case near-miss limit is explicit",
        "skeleton_sha256": canonical_skeleton_sha256(skeleton),
        "near_miss_limit": NEAR_MISS_UNITS,
        "seed": seed,
        "random_case_count": count,
        "case_count": len(cases),
        "random_case_counts": random_counts,
        "case_counts": count_categories(cases),
        "expected_sha256": expected_sha256(cases),
        "cases": cases,
    }


def generate_padded_cases(base_cases_path=BASE_CASES_PATH):
    data = json.loads(Path(base_cases_path).read_text(encoding="utf-8"))
    for case in data["cases"]:
        padding_by_box = {int(box["id"]): HITBOX_PADDING for box in case["boxes"]}
        result = trace_target(
            case["origin"],
            case["direction"],
            case["length"],
            case["boxes"],
            padding_by_box,
            NEAR_MISS_LOG_UNITS,
        )
        case["padding_by_box"] = {str(key): value for key, value in padding_by_box.items()}
        case["near_miss_limit"] = NEAR_MISS_LOG_UNITS
        case["expected"] = {
            "outcome": result["outcome"],
            "box_id": int(result["box_id"]),
            "part": result["part"],
            "dist": float(result["dist"]),
            "ray_point": [float(value) for value in result["ray_point"]],
            "box_point": [float(value) for value in result["box_point"]],
        }
    data["generator"] = "tools/ray_box_ref.py --emit-padded-cases"
    data["fixture_scope"] = "CD-r7 padded trace; current skeleton geometry"
    data["padding"] = HITBOX_PADDING
    data["near_miss_limit"] = NEAR_MISS_LOG_UNITS
    data["expected_sha256"] = expected_sha256(data["cases"])
    return data


def self_test():
    skeleton = json.loads(SKELETON_PATH.read_text(encoding="utf-8"))
    cases = generate_boundary_cases(skeleton)
    expected = [
        ("boundary_near_0_5", "near_miss", 0.5),
        ("boundary_near_0_99", "near_miss", 0.99),
        ("boundary_near_1_0", "near_miss", 1.0),
        ("boundary_near_1_01", "none", 1.01),
        ("boundary_edge_graze", "hit", math.sqrt(2.0)),
        ("boundary_thigh_overlap", "hit", 494.5),
        ("boundary_crouched_head", "hit", 496.0),
        ("boundary_crouched_chest_overlap", "hit", 492.0),
        ("boundary_pad_near_4", "none", 6.0),
        ("boundary_pad_near_over_4", "none", 6.000001),
    ]
    for category, outcome, distance in expected:
        case = next(item for item in cases if item["category"] == category)
        got = case["expected"]
        assert got["outcome"] == outcome, (category, got, outcome)
        assert abs(got["dist"] - distance) <= 1e-9, (category, got, distance)
    assert len([case for case in cases if case["category"].startswith("boundary_yaw_")]) == 5
    box = make_box(0, "head", (0.0, 0.0, 0.0), (1.0, 1.0, 1.0), 0.0)
    edge = intersect_box((-5.0, 3.0, 0.0), (1.0, 0.0, 0.0), 10.0, box, HITBOX_PADDING)
    assert edge is not None and abs(edge["dist"] - 2.0) <= 1e-9
    raw_front = intersect_box((-5.0, 0.0, 0.0), (1.0, 0.0, 0.0), 10.0, box, 0.0)
    padded_front = intersect_box(
        (-5.0, 0.0, 0.0),
        (1.0, 0.0, 0.0),
        10.0,
        box,
        HITBOX_PADDING,
    )
    assert raw_front is not None and padded_front is not None
    assert abs(raw_front["dist"] - padded_front["dist"] - HITBOX_PADDING) <= 1e-9
    outside = trace_target(
        (-5.0, 3.000001, 0.0),
        (1.0, 0.0, 0.0),
        10.0,
        [box],
        {0: HITBOX_PADDING},
        NEAR_MISS_LOG_UNITS,
    )
    assert outside["outcome"] == "near_miss" and abs(outside["dist"] - 1e-6) <= 1e-9
    within_padding = intersect_box((-5.0, 2.0, 0.0), (1.0, 0.0, 0.0), 10.0, box, HITBOX_PADDING)
    assert within_padding is not None
    threshold = trace_target(
        (-5.0, 0.0, 7.0),
        (1.0, 0.0, 0.0),
        10.0,
        [box],
        {0: HITBOX_PADDING},
        NEAR_MISS_LOG_UNITS,
    )
    assert threshold["outcome"] == "near_miss" and abs(threshold["dist"] - 4.0) <= 1e-9
    over_threshold = trace_target(
        (-5.0, 0.0, 7.000001),
        (1.0, 0.0, 0.0),
        10.0,
        [box],
        {0: HITBOX_PADDING},
        NEAR_MISS_LOG_UNITS,
    )
    assert over_threshold["outcome"] == "none" and abs(over_threshold["dist"] - 4.000001) <= 1e-9
    default_threshold = trace_target(
        (-5.0, 0.0, 7.0),
        (1.0, 0.0, 0.0),
        10.0,
        [box],
        {0: HITBOX_PADDING},
    )
    assert default_threshold["outcome"] == "near_miss" and abs(default_threshold["dist"] - 4.0) <= 1e-9
    legacy_threshold = trace_target(
        (-5.0, 0.0, 7.0),
        (1.0, 0.0, 0.0),
        10.0,
        [box],
        {0: HITBOX_PADDING},
        NEAR_MISS_UNITS,
    )
    assert legacy_threshold["outcome"] == "none" and abs(legacy_threshold["dist"] - 4.0) <= 1e-9
    assert intersect_box((math.nan, 0.0, 0.0), (1.0, 0.0, 0.0), 10.0, box) is None
    assert intersect_box((-5.0, 0.0, 0.0), (2.0, 0.0, 0.0), 10.0, box) is None
    assert intersect_box((-5.0, 0.0, 0.0), (1.0, 0.0, 0.0), math.nan, box) is None
    assert trace_target(
        (math.nan, 0.0, 0.0),
        (1.0, 0.0, 0.0),
        10.0,
        [box],
    )["outcome"] == "none"
    assert trace_target(
        (-5.0, 0.0, 0.0),
        (2.0, 0.0, 0.0),
        10.0,
        [box],
    )["outcome"] == "none"
    print("ray_box_ref self-test passed 35 boundary and fail-closed assertions")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--emit-cases")
    parser.add_argument("--emit-padded-cases")
    parser.add_argument("--base-cases", default=str(BASE_CASES_PATH))
    parser.add_argument("--seed", type=int, default=1337)
    parser.add_argument("--count", type=int, default=20000)
    args = parser.parse_args()

    if args.self_test:
        self_test()
        return 0
    if args.emit_cases and args.emit_padded_cases:
        parser.error("choose either --emit-cases or --emit-padded-cases")
    if not args.emit_cases and not args.emit_padded_cases:
        parser.error("use --self-test, --emit-cases PATH or --emit-padded-cases PATH")

    if args.emit_padded_cases:
        cases = generate_padded_cases(args.base_cases)
        output = Path(args.emit_padded_cases)
    else:
        cases = generate_cases(args.seed, args.count)
        output = Path(args.emit_cases)
    output.write_text(
        json.dumps(cases, separators=(",", ":"), ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print("wrote %s" % output)
    print("%d random + %d boundary cases" % (
        cases["random_case_count"],
        cases["case_count"] - cases["random_case_count"],
    ))
    print("expected SHA-256 %s" % cases["expected_sha256"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
