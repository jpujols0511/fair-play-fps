# Snapshot format v0.1 (PROPOSED)

*Written by Claude, Phase 2 of the build plan. PROPOSED: Joan and Game Builder have not approved it. Public as of Oct 19 2026 (CD-r9).*
Context: `specs/netcode_design.md` Section 4 (D4, D5) and build plan Phase 2.

## Summary (plain words)
The server tells each player what is going on 64 times a second. A snapshot holds your own player in full precision, plus the other players you are allowed to see, rounded to 1/8 unit. To save bytes the server sends only what changed since the last snapshot you confirmed (a "delta"). If you have not confirmed one recently, it sends everything (a "full" snapshot). A lost snapshot costs nothing: the next one is still a delta from something you definitely have.

## Layout
Little-endian, byte-aligned. Bit-packing (netcode Section 4) is a later optimisation, used only if the size budget fails (it does not: see sizes below).

**Header, 14 bytes**
| Field | Type | Notes |
|---|---|---|
| kind | u8 | 1 = full, 2 = delta |
| snap_seq | u16 | wraps. `a` is newer than `b` if `a != b` and `(a - b) & 0xFFFF < 0x8000` |
| server_tick | u32 | |
| base_seq | u16 | the baseline of this delta; equals `snap_seq` for a full snapshot |
| ack_cmd_seq | u32 | last input command the server executed for this client (the reconcile point N) |
| flags | u8 | bit 0 = the own player was teleported since the previous snapshot built for this client (client snaps); other bits 0 |

**Own-player block (always full in v0; switch C3 = "f64").** Every `PlayerState` field as f64 in `to_packed()` order. After Phase 1 that is F = 13 fields = 104 bytes (the count is derived from `PlayerState.to_packed().size()`, never hard-coded). Then the HUD block, 7 bytes: `accuracy` u16 (value x 65535 / 2.0, range 0 to 2.0), `punch_pitch` i16 and `punch_yaw` i16 (degrees x 65536 / 360, pitch positive = up), `move_state` u8 (0 stand, 1 crouch, 2 air, 3 run).

**Entities.** `entity_count` u8, then per record: `slot` u8 (0 to 15), `change_mask` u8, then only the fields whose bit is set, in bit order:
| Bit | Field | Type |
|---|---|---|
| 0 | pos x (game frame) | i16, 1/8 unit |
| 1 | pos y (feet height) | i16, 1/8 unit |
| 2 | pos z | i16, 1/8 unit |
| 3 | yaw | u16, `InputCmd.quantize_yaw` |
| 4 | pitch | u16, `InputCmd.quantize_pitch` |
| 5 | stance + alive | u8: bits 0 to 1 = `stance_for_hitbox`, bit 2 = alive |
| 6 | duck fraction | u8 `duck_q = int(round(clampf(f, 0.0, 1.0) * 255.0))`, `f = Movement.duck_fraction(state)`; decoded as `duck_q / 255.0`; round-trip error <= 0.5 / 255.0 (Addendum 3, was a hard stance step) |
| 6 | REMOVED | no payload; the slot was in the baseline but is not sent now |
| 7 | reserved | 0 |

- **Full:** every sent entity has mask 0x7F.
- **Delta:** unchanged entity omitted; changed entity sends only changed fields (compared as **quantized** values, so float noise never sends a field); new entity (not in the baseline) sends mask 0x7F; entity in the baseline but not now sends mask 0x80 (REMOVED, bit 7; any other bit set with it is malformed).
- Position quantization: `q = round_away(v * 8.0)`, clamped to i16 (range -4096.0 to 4095.875). Ties round **away from zero** in both GDScript (`round`) and the Python reference (`floor(x + 0.5)` for positives, mirrored for negatives). A clamp is counted (`Quant.clamp_count`); in tests a clamp is a failure.

## Sizes (checked with Python `struct`, `tools/snapshot_ref.py --selfcheck`)
```
struct sizes: header 14 (want 14)  hud 7 (want 7)  entity full record 13 (want 13)
full snapshot, F=13, E=11: 280 bytes (14 + 111 + 1 + 154)
worst case, E=15 all fields: 336 bytes (limit 1,200)
selfcheck ok
```
Full snapshot size = 14 + (8 x F + 7) + 1 + 14 x E. 12 players (E = 11): **280 bytes**. Empty delta: **126 bytes**. Worst case (15 remotes, all fields): **336 bytes**. Targets from netcode Section 4: under 400 typical, under 1,200 worst.

## Sequence, ack and baselines
- **Baseline ring** (`baseline_ring.gd`): per client, the last `BASELINE_RING = 32` snapshots **as sent** (quantized), keyed by `snap_seq`. Preallocated and overwritten, no allocation per snapshot.
- Every client packet carries `ack_snap_seq`, the newest snapshot it decoded. The server builds a delta against it if it is still in the ring, otherwise a **full** snapshot. No ack yet means full.
- **Client decode:** keeps its own ring of decoded snapshots by `snap_seq`. A delta whose `base_seq` it does not have is **dropped and counted** (never guessed); the next full recovers. A snapshot older than the newest is decoded (for the interpolation buffer, Phase 3) but never rolls back own-player reconcile.

## Switches (DECISION FOR JOAN, in `scripts/net/net_config.gd`)
| ID | Switch | Default (proposal) | Alternatives |
|---|---|---|---|
| C3 | `OWN_STATE_PRECISION` | "f64" (keeps S3's "error 0.0 after a reconcile" true) | "q8" (positions/velocities 1/8; reserved, not built: netcode Section 4 is ambiguous) |
| C4 | `SNAPSHOT_EVERY_TICKS` | 2 (64 per second) | 1 (128 per second, LAN) |
| C5 | `BASELINE_RING` | 32 | none |

## Frames (seam D7)
`scripts/net/frame.gd` is the only place the Godot game frame (y up, yaw 0 faces -Z, pitch positive = up, radians) and the spec frame (z up, yaw 0 faces +x, degrees, pitch positive = down) convert. Entities on the wire are in the **game frame**.

## Open points
- Own-state "q8" alternative (C3) is not implemented; only the switch name exists.
- HUD block values come from a STUB until Devin's recoil module plugs in (seam D3, Phase 4/7).

---

## Packets (appended, Phase 6, PROPOSED)

Every datagram starts with `protocol_id` u32 = **0x31465046** ("FPF1" little-endian) and `msg` u8. Little-endian, byte-aligned. Implemented in `scripts/net/packet.gd`.

| msg | Name | Payload |
|---|---|---|
| 1 | HELLO (client to server) | `protocol_version` u16 = 1, `tick_rate` u16 = 128, `cookie` u32 (0 on the first try), `kernel_sha256` 32 bytes (**all zero** placeholder until reconciliation item 5 is decided) |
| 2 | WELCOME (server to client) | `slot` u8, `server_tick` u32, `interp_ticks` u8 (C1: the **server** dictates it, netcode Section 9), `snapshot_every` u8 (C4) |
| 3 | INPUT (client to server) | `ack_snap_seq` u16, `ack_delay_ticks` u8 (ticks between decoding that snapshot and sending this packet; for RTT), `cmd_count` u8 (1 to 3, netcode D3), then per command **19 bytes**: `seq` u32, `tick` u32, `buttons` u8, `yaw_q` u16, `pitch_q` u16, `view_tick` u32, `view_tick_frac` u16 (fraction x 65536, from `get_render_tick()`, seam D8) |
| 4 | SNAPSHOT (server to client) | the snapshot bytes above |
| 5 | BYE | none |
| 6 | CHALLENGE (server to client) | `cookie` u32 = first 4 bytes of sha256(random server secret + the peer's address). Sent in answer to a HELLO whose cookie is wrong; the server keeps no state until a HELLO carries the right cookie, and the 9-byte reply is smaller than the 45-byte HELLO, so it cannot be used to reflect or amplify |

- INPUT with 3 commands = 5 + 4 + 57 = **66 bytes**; HELLO = 45; CHALLENGE = 9; WELCOME = 12; BYE = 5.
- **Hard limits:** no datagram over **1,200 bytes** (a send over the limit is refused and counted). An unknown `protocol_id`, a wrong size, `cmd_count` over 3 or an unknown message is **dropped and counted** (it becomes INPUT_REJECT reason 4 "malformed" in the in-memory EvidenceSink in Phase 7). A client silent for **5 s** is dropped (PROPOSED).
- **Server RTT** (feeds Devin's `rtt_ms`): `rtt_ticks = now - sent_tick(ack_snap_seq) - ack_delay_ticks`, smoothed with an EWMA, alpha = **0.125** (PROPOSED), reported in ms (x 1000.0 / 128.0).
- **Transport (C10):** default **ENet** (`ENetConnection` host with ONE channel, every packet sent unsequenced and unreliable: our own seq / ack logic does the rest, netcode D13). Alternative: raw `PacketPeerUDP`. Both sit behind `send(bytes)` / `poll()`.
- `view_tick` is ignored by `Movement.step`; the server uses it only as the CLAIMED view time (Devin's +-1-tick rule).

### Input command budget and hostile input (CURRENT_DECISIONS CD-r2)
- Per client: executing a command (a real one, or a lost one filled in by repeating the last) costs 1.0; the budget refills 1.0 per tick up to a burst of 8.0 (`NetConfig.CMD_BURST`, `CMD_REFILL`). A command more than `CMD_WINDOW` = 64 ahead of the next expected `seq` is dropped and counted; the dropped commands are logged as RATE_ABUSE (reason 3), at most one stored record per second per client (totals keep counting, the stored list is capped at 4,096). A real outage longer than the window re-syncs after `CMD_RESYNC_TICKS` = 128 ticks of far-ahead arrivals with no progress. **The re-sync is bounded (CD-r7):** the new next_seq is the most recent far-ahead seq only if it is within `idle_ticks + CMD_BURST` of the current next_seq (an honest client advances about one seq per tick); otherwise next_seq advances by exactly that bound. It is never set to an arbitrary far-ahead value, so a forged 0xFFFFFFFF or 0x7FFFFFFF cannot strand the player. All seq comparisons are modulo 2^32 (`SeqMath`).
- A filled-in command never carries ATTACK. Acks are accepted only for snapshot seqs still in the 32-snapshot sent window; an impossible `ack_delay_ticks` (negative or over 10 s RTT sample) is ignored.
- The server binds to **loopback** unless started with `--bind-all`. Raw UDP peers are unverified until the cookie check passes (at most 64 unverified, pruned after 5 s).
- **Encryption is deferred** pending DTLS research (ENet has none built in; Godot's `PacketPeerDTLS` is a candidate). Until then packets are readable and forgeable by anyone on the path; the cookie only stops address spoofing, not a man in the middle.
