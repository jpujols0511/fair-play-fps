#!/usr/bin/env python3
"""Independent Python writer, verifier and JSONL exporter for .fpev evidence."""
import argparse
import copy
import hashlib
import json
import math
import struct
import sys
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TYPE_SHOT = 1
TYPE_VIS = 2
TYPE_INPUT_REJECT = 3
TYPE_CHECKPOINT = 4
TYPE_REWIND_DECISION = 5
TYPE_AIM_KIN = 6
ANGLE_STEPS = 65536.0
KNOWN_LENGTHS = {
    TYPE_SHOT: 108,
    TYPE_VIS: 12,
    TYPE_INPUT_REJECT: 26,
    TYPE_CHECKPOINT: 36,
    TYPE_REWIND_DECISION: 64,
    TYPE_AIM_KIN: 40,
}
WEAPON_NAMES = {1: "AK47", 2: "M4A1"}
WEAPON_IDS = {value: key for key, value in WEAPON_NAMES.items()}
PART_NAMES = [
    "head", "chest", "stomach", "upper_arm_l", "upper_arm_r",
    "forearm_l", "forearm_r", "thigh_l", "thigh_r", "shin_l", "shin_r",
]
STANCE_NAMES = ["stand", "crouch", "air", "crouch_air"]
MOVE_NAMES = ["stand", "crouch", "air", "run"]
REWIND_REASONS = [
    "none", "claimed_time_out_of_window", "over_rewind_cap",
    "claimed_time_and_cap", "negative_rewind", "claimed_time_and_negative",
    "missing_history", "reserved",
]
INPUT_REASONS = {
    1: "claimed_time_out_of_window",
    2: "view_angle_delta_too_large",
    3: "input_rate_off",
    4: "malformed",
}


def _as_bytes(value, expected_size):
    if isinstance(value, bytes):
        result = value
    elif isinstance(value, bytearray):
        result = bytes(value)
    else:
        text = str(value).replace("-", "").replace(" ", "")
        result = bytes.fromhex(text)
    if len(result) != expected_size:
        raise ValueError("expected %d bytes, got %d" % (expected_size, len(result)))
    return result


def _player_ref(slot, header):
    if "player_ref" in slot:
        return _as_bytes(slot["player_ref"], 32)
    salt_value = slot.get("salt", header.get("salt", ""))
    salt = salt_value.encode("utf-8") if isinstance(salt_value, str) else bytes(salt_value)
    return hashlib.sha256(str(slot["account_id"]).encode("utf-8") + salt).digest()


def build_header(header):
    map_bytes = str(header.get("map_name", "")).encode("utf-8")
    slots = header.get("slots", [])
    if len(map_bytes) > 255 or len(slots) > 16:
        raise ValueError("map name or slot count exceeds the file header limit")
    match_id = uuid.UUID(str(header["match_id"])).bytes
    kernel = _as_bytes(
        header.get("kernel_sha256", "00" * 32),
        32,
    )
    skeleton = _as_bytes(
        header.get(
            "skeleton_sha256",
            "8f404c7cf647b3d6d2acbb6e975ee6ebc1eb2ab1cc158a8a9f824b5fda43e031",
        ),
        32,
    )
    build_id = _as_bytes(header["build_id"], 20)
    output = bytearray(struct.pack(
        "<4sHH16sQ32s32s20sB",
        b"FPEV",
        int(header.get("format_version", 1)),
        int(header.get("tick_rate", 128)),
        match_id,
        int(header.get("start_unix_ms", 0)),
        kernel,
        skeleton,
        build_id,
        len(map_bytes),
    ))
    output.extend(map_bytes)
    output.extend(struct.pack("<B", len(slots)))
    for slot in slots:
        output.extend(_player_ref(slot, header))
        output.extend(struct.pack("<B", int(slot.get("team", 0))))
    return bytes(output)


class FpevWriter:
    def __init__(self, header, config=None):
        self.header = build_header(header)
        self.config = {
            "ENABLE_AIM_KIN": True,
            "CHECKPOINT_INTERVAL_TICKS": 128,
            "WEAPON_ID_MAP": {"AK47": 1, "M4A1": 2},
        }
        if config:
            self.config.update(config)
        self.data = bytearray(self.header)
        self.bytes_since_checkpoint = bytearray()
        self.previous_chain = hashlib.sha256(self.header).digest()
        self.checkpoint_index = 0
        self.records_since_checkpoint = 0
        self.last_tick = 0
        self.closed = False

    def _record_header(self, record_type, flags, body_length, tick):
        return struct.pack("<BBHI", record_type, flags & 0xFF, body_length, tick)

    def _crc_record(self, record_type, flags, tick, body_without_crc):
        header = self._record_header(record_type, flags, len(body_without_crc) + 4, tick)
        crc = zlib.crc32(header + body_without_crc) & 0xFFFFFFFF
        return self._write_non_checkpoint(header, body_without_crc + struct.pack("<I", crc), tick)

    def _write_non_checkpoint(self, header, body, tick):
        record = header + body
        self.data.extend(record)
        self.bytes_since_checkpoint.extend(record)
        self.records_since_checkpoint += 1
        self.last_tick = int(tick)
        return record

    def write_shot(self, fields, tick):
        weapon_id = fields["weapon_id"]
        if isinstance(weapon_id, str):
            weapon_id = int(self.config["WEAPON_ID_MAP"][weapon_id])
        body = struct.pack(
            "<BBBBBBH3f2H2f2fBBHddf3f3f3ff",
            int(fields["shooter_slot"]),
            int(fields["target_slot"]),
            int(weapon_id),
            int(fields["part"]),
            int(fields["outcome"]),
            int(fields["target_stance"]),
            int(fields["shot_index"]),
            *[float(value) for value in fields["eye_pos"]],
            int(fields["view_pitch_q"]),
            int(fields["view_yaw_q"]),
            float(fields["spread_x"]),
            float(fields["spread_y"]),
            float(fields["kick_up"]),
            float(fields["kick_side"]),
            int(fields["rewind_ticks"]),
            0,
            int(fields["rewind_frac"]),
            float(fields["server_time_s"]),
            float(fields["client_claimed_time_s"]),
            float(fields["closest_dist"]),
            *[float(value) for value in fields["ray_point"]],
            *[float(value) for value in fields["box_point"]],
            *[float(value) for value in fields["target_origin"]],
            float(fields["target_yaw"]),
        )
        assert len(body) == 104
        return self._crc_record(TYPE_SHOT, int(fields.get("flags", 0)), tick, body)

    def write_vis(self, fields, tick):
        body = struct.pack(
            "<BBHHH",
            int(fields["viewer_slot"]),
            0,
            int(fields["sent_mask"]),
            int(fields["sound_only_mask"]),
            0,
        )
        flags = 1 if fields.get("keyframe", False) else 0
        return self._crc_record(TYPE_VIS, flags, tick, body)

    def write_input_reject(self, fields, tick):
        body = struct.pack(
            "<BBIdd",
            int(fields["player_slot"]),
            int(fields["reason"]),
            int(fields["cmd_seq"]),
            float(fields["claimed_time_s"]),
            float(fields["expected_time_s"]),
        )
        return self._crc_record(TYPE_INPUT_REJECT, int(fields.get("flags", 0)), tick, body)

    def write_rewind_decision(self, fields, tick):
        checkpoint_index = self.checkpoint_index
        chain_prefix = self.previous_chain[:8]
        body = struct.pack(
            "<BBBBBBHHHIdddffI8s",
            int(fields["shooter_slot"]),
            int(fields["reason"]),
            int(fields["interp_ticks"]),
            int(fields["targets_rewound"]),
            int(fields["rewind_ticks"]),
            int(fields["max_rewind_ticks"]),
            int(fields["rewind_frac"]),
            int(fields["shot_index"]),
            int(fields["rewound_mask"]),
            int(fields["cmd_seq"]),
            float(fields["claimed_view_tick"]),
            float(fields["expected_view_tick"]),
            float(fields["chosen_view_tick"]),
            float(fields["wanted_rewind_ticks"]),
            float(fields["rtt_ms"]),
            checkpoint_index,
            chain_prefix,
        )
        assert len(body) == 60
        return self._crc_record(TYPE_REWIND_DECISION, int(fields.get("flags", 0)), tick, body)

    def write_aim_kin(self, fields, tick):
        if not self.config["ENABLE_AIM_KIN"]:
            return None
        body = struct.pack(
            "<BBHBBfffffffBB",
            int(fields["shooter_slot"]),
            int(fields.get("window_ticks", 16)),
            int(fields["shot_index"]),
            int(fields["move_state"]),
            0,
            float(fields["spread_at_fire"]),
            float(fields["peak_ang_vel_dps"]),
            float(fields["peak_ang_accel_dps2"]),
            float(fields["fire_tick_delta_deg"]),
            float(fields["snapback_deg"]),
            float(fields["snapback_cos"]),
            float(fields["pre_fire_speed_dps"]),
            int(fields["settle_ticks"]),
            0,
        )
        assert len(body) == 36
        return self._crc_record(TYPE_AIM_KIN, int(fields.get("flags", 0)), tick, body)

    def write_checkpoint(self, tick):
        header = self._record_header(TYPE_CHECKPOINT, 0, 36, tick)
        count = struct.pack("<I", self.records_since_checkpoint)
        chain_input = (
            self.previous_chain
            + self.bytes_since_checkpoint
            + header
            + count
        )
        chain = hashlib.sha256(chain_input).digest()
        record = header + count + chain
        self.data.extend(record)
        self.previous_chain = chain
        self.bytes_since_checkpoint.clear()
        self.records_since_checkpoint = 0
        self.checkpoint_index += 1
        self.last_tick = int(tick)
        return record

    def end_tick(self, tick):
        self.last_tick = int(tick)
        interval = int(self.config["CHECKPOINT_INTERVAL_TICKS"])
        if interval <= 0:
            raise ValueError("checkpoint interval must be positive")
        if (int(tick) + 1) % interval == 0:
            return self.write_checkpoint(int(tick))
        return None

    def close(self, tick=None):
        if self.closed:
            raise ValueError("writer already closed")
        self.write_checkpoint(self.last_tick if tick is None else int(tick))
        self.closed = True
        return bytes(self.data)

    def final_chain_sha256(self):
        return self.previous_chain


def write_match(match_input, config=None):
    writer = FpevWriter(match_input["header"], config)
    final_tick = int(match_input["final_tick"])
    events_by_tick = {}
    for event in match_input["events"]:
        write_tick = int(event.get("write_tick", event["tick"]))
        events_by_tick.setdefault(write_tick, []).append(event)
    for tick in range(final_tick + 1):
        for event in events_by_tick.get(tick, []):
            fields = event["fields"]
            kind = event["kind"]
            record_tick = int(event["tick"])
            if kind == "shot":
                writer.write_shot(fields, record_tick)
            elif kind == "vis":
                writer.write_vis(fields, record_tick)
            elif kind == "input_reject":
                writer.write_input_reject(fields, record_tick)
            elif kind == "rewind_decision":
                writer.write_rewind_decision(fields, record_tick)
            elif kind == "aim_kin":
                writer.write_aim_kin(fields, record_tick)
            else:
                raise ValueError("unknown event kind %r" % kind)
        writer.end_tick(tick)
    return writer.close(final_tick)


class FpevReader:
    def read_file(self, path, expected_final_hash=None):
        return self.read_bytes(Path(path).read_bytes(), expected_final_hash)

    def read_bytes(self, data, expected_final_hash=None):
        data = bytes(data)
        errors, warnings, records = [], [], []
        try:
            header, header_size = self._read_header(data)
        except ValueError as error:
            return self._result({}, records, [{"offset": 0, "record_index": 0, "kind": str(error)}],
                                warnings, b"", 0)

        previous_chain = hashlib.sha256(data[:header_size]).digest()
        bytes_since_checkpoint = bytearray()
        records_since_checkpoint = 0
        checkpoints_seen = 0
        offset, record_index, last_type = header_size, 0, 0
        while offset < len(data):
            if len(data) - offset < 8:
                errors.append(_error(offset, record_index, "truncated_record_header"))
                break
            record_type, flags, body_length, tick = struct.unpack_from("<BBHI", data, offset)
            record_length = 8 + body_length
            if record_length > len(data) - offset:
                errors.append(_error(offset, record_index, "truncated_record"))
                break
            raw_record = data[offset:offset + record_length]
            expected_length = KNOWN_LENGTHS.get(record_type)
            if expected_length is not None and body_length != expected_length:
                errors.append(_error(offset, record_index, "record_length"))
            fields = {}
            if expected_length == body_length:
                try:
                    fields = self._decode_fields(record_type, data, offset + 8)
                except (struct.error, ValueError, IndexError):
                    errors.append(_error(offset, record_index, "record_body"))

            if record_type in (
                    TYPE_SHOT, TYPE_VIS, TYPE_INPUT_REJECT, TYPE_REWIND_DECISION, TYPE_AIM_KIN
                ) and body_length >= 4:
                crc_offset = offset + record_length - 4
                calculated = zlib.crc32(data[offset:crc_offset]) & 0xFFFFFFFF
                stored = struct.unpack_from("<I", data, crc_offset)[0]
                fields["crc32"] = stored
                if calculated != stored:
                    errors.append(_error(offset, record_index, "crc32"))

            if record_type == TYPE_REWIND_DECISION and expected_length == body_length:
                if fields["checkpoint_index"] != checkpoints_seen \
                        or fields["chain_prefix"] != previous_chain[:8]:
                    errors.append(_error(offset, record_index, "rewind_checkpoint_link"))

            if record_type == TYPE_CHECKPOINT and body_length == 36:
                record_count, stored_chain = struct.unpack_from("<I32s", data, offset + 8)
                chain_input = previous_chain + bytes_since_checkpoint + data[offset:offset + 12]
                calculated_chain = hashlib.sha256(chain_input).digest()
                fields = {"record_count": record_count, "chain_sha256": stored_chain}
                if record_count != records_since_checkpoint:
                    errors.append(_error(offset, record_index, "checkpoint_record_count"))
                if calculated_chain != stored_chain:
                    errors.append(_error(offset, record_index, "checkpoint_chain"))
                previous_chain = stored_chain
                bytes_since_checkpoint.clear()
                records_since_checkpoint = 0
                checkpoints_seen += 1
            else:
                bytes_since_checkpoint.extend(raw_record)
                records_since_checkpoint += 1
                if expected_length is None:
                    warnings.append({
                        "offset": offset,
                        "record_index": record_index,
                        "kind": "unknown_record_type",
                        "type": record_type,
                    })
                    fields = {"raw_body": data[offset + 8:offset + record_length]}

            records.append({
                "type": record_type,
                "flags": flags,
                "length": body_length,
                "tick": tick,
                "offset": offset,
                "record_index": record_index,
                "fields": fields,
            })
            offset += record_length
            record_index += 1
            last_type = record_type

        if last_type != TYPE_CHECKPOINT:
            errors.append(_error(len(data), record_index, "missing_final_checkpoint"))
        if expected_final_hash is not None:
            expected = bytes.fromhex(expected_final_hash) if isinstance(expected_final_hash, str) else bytes(expected_final_hash)
            if expected != previous_chain:
                errors.append(_error(len(data), record_index, "final_hash_mismatch"))
        return self._result(header, records, errors, warnings, previous_chain, checkpoints_seen)

    @staticmethod
    def _read_header(data):
        if len(data) < 118:
            raise ValueError("truncated_file_header")
        magic, version, rate, match_id, start_ms, kernel, skeleton, build_id, map_length = struct.unpack_from(
            "<4sHH16sQ32s32s20sB", data, 0
        )
        if magic != b"FPEV":
            raise ValueError("bad_magic")
        slot_count_offset = 117 + map_length
        if len(data) < slot_count_offset + 1:
            raise ValueError("truncated_map_name")
        slot_count = data[slot_count_offset]
        header_size = 118 + map_length + slot_count * 33
        if len(data) < header_size:
            raise ValueError("truncated_slots")
        map_name = data[117:117 + map_length].decode("utf-8")
        slots, cursor = [], slot_count_offset + 1
        for slot_index in range(slot_count):
            player_ref = data[cursor:cursor + 32]
            team = data[cursor + 32]
            slots.append({"slot": slot_index, "player_ref": player_ref, "team": team})
            cursor += 33
        return {
            "magic": "FPEV",
            "format_version": version,
            "tick_rate": rate,
            "match_id": match_id,
            "start_unix_ms": start_ms,
            "kernel_sha256": kernel,
            "skeleton_sha256": skeleton,
            "build_id": build_id,
            "map_name": map_name,
            "slot_count": slot_count,
            "slots": slots,
        }, header_size

    @staticmethod
    def _decode_fields(record_type, data, start):
        if record_type == TYPE_SHOT:
            return {
                "shooter_slot": data[start],
                "target_slot": data[start + 1],
                "weapon_id": data[start + 2],
                "part": data[start + 3],
                "outcome": data[start + 4],
                "target_stance": data[start + 5],
                "shot_index": struct.unpack_from("<H", data, start + 6)[0],
                "eye_pos": struct.unpack_from("<3f", data, start + 8),
                "view_pitch_q": struct.unpack_from("<H", data, start + 20)[0],
                "view_yaw_q": struct.unpack_from("<H", data, start + 22)[0],
                "spread_x": struct.unpack_from("<f", data, start + 24)[0],
                "spread_y": struct.unpack_from("<f", data, start + 28)[0],
                "kick_up": struct.unpack_from("<f", data, start + 32)[0],
                "kick_side": struct.unpack_from("<f", data, start + 36)[0],
                "rewind_ticks": data[start + 40],
                "reserved": data[start + 41],
                "rewind_frac": struct.unpack_from("<H", data, start + 42)[0],
                "server_time_s": struct.unpack_from("<d", data, start + 44)[0],
                "client_claimed_time_s": struct.unpack_from("<d", data, start + 52)[0],
                "closest_dist": struct.unpack_from("<f", data, start + 60)[0],
                "ray_point": struct.unpack_from("<3f", data, start + 64),
                "box_point": struct.unpack_from("<3f", data, start + 76),
                "target_origin": struct.unpack_from("<3f", data, start + 88),
                "target_yaw": struct.unpack_from("<f", data, start + 100)[0],
            }
        if record_type == TYPE_VIS:
            return {
                "viewer_slot": data[start],
                "reserved": data[start + 1],
                "sent_mask": struct.unpack_from("<H", data, start + 2)[0],
                "sound_only_mask": struct.unpack_from("<H", data, start + 4)[0],
                "reserved2": struct.unpack_from("<H", data, start + 6)[0],
            }
        if record_type == TYPE_INPUT_REJECT:
            return {
                "player_slot": data[start],
                "reason": data[start + 1],
                "cmd_seq": struct.unpack_from("<I", data, start + 2)[0],
                "claimed_time_s": struct.unpack_from("<d", data, start + 6)[0],
                "expected_time_s": struct.unpack_from("<d", data, start + 14)[0],
            }
        if record_type == TYPE_REWIND_DECISION:
            values = struct.unpack_from("<BBBBBBHHHIdddffI8s", data, start)
            return {
                "shooter_slot": values[0], "reason": values[1], "interp_ticks": values[2],
                "targets_rewound": values[3], "rewind_ticks": values[4], "max_rewind_ticks": values[5],
                "rewind_frac": values[6], "shot_index": values[7], "rewound_mask": values[8],
                "cmd_seq": values[9], "claimed_view_tick": values[10], "expected_view_tick": values[11],
                "chosen_view_tick": values[12], "wanted_rewind_ticks": values[13], "rtt_ms": values[14],
                "checkpoint_index": values[15], "chain_prefix": values[16],
            }
        if record_type == TYPE_AIM_KIN:
            values = struct.unpack_from("<BBHBBfffffffBB", data, start)
            return {
                "shooter_slot": values[0], "window_ticks": values[1], "shot_index": values[2],
                "move_state": values[3], "reserved": values[4], "spread_at_fire": values[5],
                "peak_ang_vel_dps": values[6], "peak_ang_accel_dps2": values[7],
                "fire_tick_delta_deg": values[8], "snapback_deg": values[9],
                "snapback_cos": values[10], "pre_fire_speed_dps": values[11],
                "settle_ticks": values[12], "reserved2": values[13],
            }
        return {}

    @staticmethod
    def _result(header, records, errors, warnings, final_chain, checkpoint_count):
        return {
            "ok": not errors,
            "header": header,
            "records": records,
            "errors": errors,
            "first_error": errors[0] if errors else {},
            "warnings": warnings,
            "final_chain_sha256": final_chain,
            "checkpoint_count": checkpoint_count,
        }

    @staticmethod
    def chain_status(result):
        if result["ok"]:
            return "CHAIN OK"
        error = result["first_error"]
        return "CHAIN BROKEN at record %d (offset %d): %s" % (
            error["record_index"], error["offset"], error["kind"]
        )


def _error(offset, record_index, kind):
    return {"offset": offset, "record_index": record_index, "kind": kind}


def _round_float(value, digits):
    scale = 10 ** digits
    scaled = float(value) * scale
    rounded = math.floor(scaled + 0.5) if scaled >= 0.0 else math.ceil(scaled - 0.5)
    result = rounded / scale
    return 0.0 if result == 0.0 else result


def _vec(values, digits=6):
    return [_round_float(value, digits) for value in values]


def _mask_slots(mask):
    return [slot for slot in range(16) if mask & (1 << slot)]


def _spec_view_angles(pitch_q, yaw_q):
    # Mirror InputCmd dequantization followed by the shared Frame conversion.
    pitch_rad = float(pitch_q) / (ANGLE_STEPS - 1.0) * math.pi - math.pi / 2.0
    yaw_rad = float(yaw_q) * (2.0 * math.pi / ANGLE_STEPS)
    pitch_spec_deg = -math.degrees(pitch_rad)
    yaw_spec_deg = (math.degrees(yaw_rad) + 90.0) % 360.0
    return pitch_spec_deg, yaw_spec_deg


def _record_json(record):
    fields = record["fields"]
    tick = int(record["tick"])
    record_type = int(record["type"])
    flags = int(record["flags"])
    if record_type == TYPE_SHOT:
        pitch_deg, yaw_deg = _spec_view_angles(
            int(fields["view_pitch_q"]),
            int(fields["view_yaw_q"]),
        )
        shot_flags = []
        for bit, name in (
            (0, "rewind_clamped"),
            (1, "claimed_time_out_of_window"),
            (2, "through_world"),
            (3, "target_not_sent"),
        ):
            if flags & (1 << bit):
                shot_flags.append(name)
        return {
            "type": "shot",
            "tick": tick,
            "shooter": int(fields["shooter_slot"]),
            "target": int(fields["target_slot"]),
            "weapon": WEAPON_NAMES.get(int(fields["weapon_id"]), "unknown"),
            "part": PART_NAMES[int(fields["part"])] if int(fields["part"]) < len(PART_NAMES) else "unknown",
            "outcome": "hit" if int(fields["outcome"]) == 0 else "near_miss",
            "stance": STANCE_NAMES[int(fields["target_stance"])] if int(fields["target_stance"]) < len(STANCE_NAMES) else "unknown",
            "shot_index": int(fields["shot_index"]),
            "eye": _vec(fields["eye_pos"]),
            "view": {
                "pitch": _round_float(pitch_deg, 6),
                "yaw": _round_float(yaw_deg, 6),
            },
            "spread": [
                _round_float(fields["spread_x"], 6),
                _round_float(fields["spread_y"], 6),
            ],
            "kick": {
                "up": _round_float(fields["kick_up"], 6),
                "side": _round_float(fields["kick_side"], 6),
            },
            "rewind": {
                "ticks": int(fields["rewind_ticks"]),
                "frac": _round_float(int(fields["rewind_frac"]) / 65536.0, 9),
            },
            "server_time": _round_float(fields["server_time_s"], 9),
            "client_time": _round_float(fields["client_claimed_time_s"], 9),
            "closest_dist": _round_float(fields["closest_dist"], 6),
            "ray_point": _vec(fields["ray_point"]),
            "box_point": _vec(fields["box_point"]),
            "target_origin": _vec(fields["target_origin"]),
            "target_yaw": _round_float(fields["target_yaw"], 6),
            "flags": shot_flags,
        }
    if record_type == TYPE_VIS:
        return {
            "type": "vis",
            "tick": tick,
            "viewer": int(fields["viewer_slot"]),
            "sent": _mask_slots(int(fields["sent_mask"])),
            "sound_only": _mask_slots(int(fields["sound_only_mask"])),
            "keyframe": bool(flags & 1),
        }
    if record_type == TYPE_INPUT_REJECT:
        return {
            "type": "input_reject",
            "tick": tick,
            "player": int(fields["player_slot"]),
            "reason": INPUT_REASONS.get(int(fields["reason"]), "unknown"),
            "cmd_seq": int(fields["cmd_seq"]),
            "claimed_time": _round_float(fields["claimed_time_s"], 9),
            "expected_time": _round_float(fields["expected_time_s"], 9),
        }
    if record_type == TYPE_CHECKPOINT:
        return {
            "type": "checkpoint",
            "tick": tick,
            "record_count": int(fields["record_count"]),
            "chain": fields["chain_sha256"].hex(),
        }
    if record_type == TYPE_REWIND_DECISION:
        rewind_flags = []
        for bit, name in (
            (0, "rewind_clamped"),
            (1, "claimed_time_out_of_window"),
            (4, "negative_rewind"),
            (5, "missing_history"),
        ):
            if flags & (1 << bit):
                rewind_flags.append(name)
        reason = int(fields["reason"])
        return {
            "type": "rewind_decision",
            "tick": tick,
            "shooter": int(fields["shooter_slot"]),
            "shot_index": int(fields["shot_index"]),
            "cmd_seq": int(fields["cmd_seq"]),
            "reason": REWIND_REASONS[reason] if reason < len(REWIND_REASONS) else "unknown",
            "flags": rewind_flags,
            "interp_ticks": int(fields["interp_ticks"]),
            "rtt_ms": _round_float(fields["rtt_ms"], 6),
            "claimed_view_tick": _round_float(fields["claimed_view_tick"], 9),
            "expected_view_tick": _round_float(fields["expected_view_tick"], 9),
            "chosen_view_tick": _round_float(fields["chosen_view_tick"], 9),
            "wanted_rewind_ticks": _round_float(fields["wanted_rewind_ticks"], 6),
            "rewind": {
                "ticks": int(fields["rewind_ticks"]),
                "frac": _round_float(int(fields["rewind_frac"]) / 65536.0, 9),
            },
            "max_rewind_ticks": int(fields["max_rewind_ticks"]),
            "targets_rewound": int(fields["targets_rewound"]),
            "rewound": _mask_slots(int(fields["rewound_mask"])),
            "checkpoint_index": int(fields["checkpoint_index"]),
        }
    if record_type == TYPE_AIM_KIN:
        aim_flags = []
        for bit, name in ((0, "snapback"), (1, "flick_stop_at_fire")):
            if flags & (1 << bit):
                aim_flags.append(name)
        return {
            "type": "aim_kin",
            "tick": tick,
            "shooter": int(fields["shooter_slot"]),
            "shot_index": int(fields["shot_index"]),
            "window_ticks": int(fields["window_ticks"]),
            "move_state": MOVE_NAMES[int(fields["move_state"])] if int(fields["move_state"]) < len(MOVE_NAMES) else "unknown",
            "spread_at_fire": _round_float(fields["spread_at_fire"], 6),
            "peak_ang_vel_dps": _round_float(fields["peak_ang_vel_dps"], 6),
            "peak_ang_accel_dps2": _round_float(fields["peak_ang_accel_dps2"], 6),
            "fire_tick_delta_deg": _round_float(fields["fire_tick_delta_deg"], 6),
            "snapback_deg": _round_float(fields["snapback_deg"], 6),
            "snapback_cos": _round_float(fields["snapback_cos"], 6),
            "pre_fire_speed_dps": _round_float(fields["pre_fire_speed_dps"], 6),
            "settle_ticks": int(fields["settle_ticks"]),
            "flags": aim_flags,
        }
    return {}


def export_bytes(data, expected_final_hash=None):
    verification = FpevReader().read_bytes(data, expected_final_hash)
    lines = []
    for record in verification["records"]:
        row = _record_json(record)
        if row:
            lines.append(json.dumps(row, separators=(",", ":"), ensure_ascii=False, sort_keys=True))
    text = "\n".join(lines)
    if text:
        text += "\n"
    return {
        "ok": verification["ok"],
        "text": text,
        "status": FpevReader.chain_status(verification),
        "verification": verification,
    }


def tamper_test_cases(data, expected_final_hash, alternate_data):
    baseline = FpevReader().read_bytes(data)
    records = baseline["records"]
    first_checkpoint = next(record for record in records if record["type"] == TYPE_CHECKPOINT)
    final_checkpoint = [record for record in records if record["type"] == TYPE_CHECKPOINT][-1]

    def first_record(record_type):
        return next(record for record in records if record["type"] == record_type)

    def flip(offset):
        altered = bytearray(data)
        altered[offset] ^= 1
        return bytes(altered)

    def remove(record):
        start = int(record["offset"])
        end = start + 8 + int(record["length"])
        return data[:start] + data[end:]

    shot_records = [
        record for record in records
        if record["type"] == TYPE_SHOT and record["offset"] < first_checkpoint["offset"]
    ]
    shot_a, shot_b = shot_records[:2]
    a0, a1 = shot_a["offset"], shot_a["offset"] + 8 + shot_a["length"]
    b0, b1 = shot_b["offset"], shot_b["offset"] + 8 + shot_b["length"]
    if a0 > b0:
        a0, b0, a1, b1 = b0, a0, b1, a1
        shot_a, shot_b = shot_b, shot_a
    swapped = data[:a0] + data[b0:b1] + data[a1:b0] + data[a0:a1] + data[b1:]

    rewind = next(
        record for record in records
        if record["type"] == TYPE_REWIND_DECISION and record["offset"] < first_checkpoint["offset"]
    )
    rewind_start = int(rewind["offset"])
    rewind_end = rewind_start + 8 + int(rewind["length"])
    rewind_record = data[rewind_start:rewind_end]
    without_rewind = data[:rewind_start] + data[rewind_end:]
    shifted_checkpoint = int(first_checkpoint["offset"]) - len(rewind_record)
    checkpoint_end = shifted_checkpoint + 8 + int(first_checkpoint["length"])
    moved_rewind = (
        without_rewind[:checkpoint_end]
        + rewind_record
        + without_rewind[checkpoint_end:]
    )

    cases = [
        ("shot_body", flip(first_record(TYPE_SHOT)["offset"] + 8 + 24)),
        ("vis_body", flip(first_record(TYPE_VIS)["offset"] + 8 + 2)),
        ("input_reject_body", flip(first_record(TYPE_INPUT_REJECT)["offset"] + 8 + 2)),
        ("rewind_body", flip(first_record(TYPE_REWIND_DECISION)["offset"] + 8 + 12)),
        ("aim_kin_body", flip(first_record(TYPE_AIM_KIN)["offset"] + 8 + 6)),
        (
            "shot_crc",
            flip(first_record(TYPE_SHOT)["offset"] + 8 + first_record(TYPE_SHOT)["length"] - 1),
        ),
        ("checkpoint_record_count", flip(first_checkpoint["offset"] + 8)),
        ("delete_record", remove(first_record(TYPE_VIS))),
        ("swap_records", swapped),
        ("move_rewind_interval", moved_rewind),
        ("truncate_final_interval", data[:int(final_checkpoint["offset"])]),
        ("replace_with_other_valid_match", alternate_data),
        ("file_header", flip(32)),
    ]
    output = []
    for name, altered in cases:
        result = FpevReader().read_bytes(altered, expected_final_hash)
        output.append({
            "name": name,
            "ok": result["ok"],
            "first_error": result["first_error"],
            "errors": result["errors"],
        })
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    write_parser = subparsers.add_parser("write")
    write_parser.add_argument("input_json")
    write_parser.add_argument("output_fpev")
    write_parser.add_argument("--enable-evidence-log", action="store_true")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("fpev_file")
    verify_parser.add_argument("--expected-final-hash")
    verify_parser.add_argument("--enable-evidence-log", action="store_true")
    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("fpev_file")
    export_parser.add_argument("--expected-final-hash")
    export_parser.add_argument("--jsonl-out")
    export_parser.add_argument("--quiet", action="store_true")
    export_parser.add_argument("--enable-evidence-log", action="store_true")
    tamper_parser = subparsers.add_parser("tamper-test", help="run the golden tamper suite")
    tamper_parser.add_argument("fpev_file")
    tamper_parser.add_argument("--fixture", required=True)
    tamper_parser.add_argument("--expected-final-hash")
    tamper_parser.add_argument("--enable-evidence-log", action="store_true")
    args = parser.parse_args(argv)
    if not args.enable_evidence_log:
        parser.error("evidence logging is disabled by default; pass --enable-evidence-log for explicit testing")

    if args.command == "write":
        match_input = json.loads(Path(args.input_json).read_text(encoding="utf-8"))
        data = write_match(match_input)
        Path(args.output_fpev).write_bytes(data)
        verified = FpevReader().read_bytes(data)
        print("wrote %s (%d bytes)" % (args.output_fpev, len(data)))
        print("final_chain_sha256=%s" % verified["final_chain_sha256"].hex())
        print(FpevReader.chain_status(verified))
        return 0 if verified["ok"] else 1

    expected = (
        bytes.fromhex(args.expected_final_hash)
        if args.expected_final_hash
        else None
    )
    data = Path(args.fpev_file).read_bytes()
    if args.command == "tamper-test":
        fixture = json.loads(Path(args.fixture).read_text(encoding="utf-8"))
        if expected is None:
            expected = bytes.fromhex(fixture["expected_final_chain_sha256"])
        alternate = copy.deepcopy(fixture)
        alternate["header"]["start_unix_ms"] = int(alternate["header"]["start_unix_ms"]) + 1
        alternate_bytes = write_match(alternate)
        if not FpevReader().read_bytes(alternate_bytes)["ok"]:
            parser.error("alternate match fixture failed its own chain")
        cases = tamper_test_cases(data, expected, alternate_bytes)
        summary = {"case_count": len(cases), "cases": cases}
        print(json.dumps(summary, separators=(",", ":"), sort_keys=True))
        return 0 if all(not case["ok"] for case in cases) else 1
    if args.command == "verify":
        verified = FpevReader().read_bytes(data, expected)
        print(FpevReader.chain_status(verified))
        return 0 if verified["ok"] else 1
    exported = export_bytes(data, expected)
    if args.jsonl_out:
        Path(args.jsonl_out).write_text(exported["text"], encoding="utf-8")
    if exported["text"] and not args.quiet:
        sys.stdout.write(exported["text"])
    print(exported["status"])
    return 0 if exported["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
