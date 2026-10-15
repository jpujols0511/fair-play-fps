# Godot 4 headless spike (decision 0001)

October 15, 2026. Steps 1 to 3 of the spike in
`docs/decisions/0001-engine-and-netcode.md`, plus a metadata-level look at
step 4. Status levels reached: **compiled and run headless, network-tested on
loopback**. Not playtested, not rendered, not tested across machines.

## What it is

| File | Role |
| --- | --- |
| `kernel/fairplay_kernel.gd` | Integer-exact GDScript port of `prototype/fairplay_sim.py`: fixed tick, intent-only commands, movement limits, fire cadence, ammunition, evidence, digest. |
| `net/protocol.gd` | Strict binary wire format. Client to server carries intent only; there is no field for position, health, damage, ammunition or score. Wrong length or fields means malformed and dropped. |
| `net/server.gd` | Headless authoritative server over DTLS. Authenticates each player's access token, binds the identity to that encrypted session, runs 64 Hz, sends each client its confirmed state, writes a demo log of every submit, and records the kernel hash it ran. |
| `net/client.gd` | Thin headless client: sends one intent per tick and keeps the last server-confirmed state. Role `attacker` is a controlled test fixture, not a cheat. |
| `net/enet_server.gd`, `net/enet_client.gd` | Stage 2: the same match on ENet with DTLS. Tokens checked through SceneMultiplayer authentication; Netfox `NetworkTime` drives the tick and syncs each client's clock to the server. Default transport for the community runner. |
| `net/input_buffer.gd` | Per-player jitter buffer shared by both servers (decision 0002). |
| `net/prediction.gd` | Stage 3: the ENet client predicts its own player with the server's kernel code and reconciles to each snapshot. |
| `tests/netfox_tick.gd` | Netfox's tick loop driving the kernel; digest must match the oracle. |
| `addons/netfox*` | Vendored Netfox, MIT. Provenance in `docs/THIRD_PARTY.md`. |
| `tests/kernel_parity.gd` | Prints digests for the honest, attacker and mixed command streams. |
| `../tests/test_godot_spike.py` | Python checks; skipped unless `FAIRPLAY_GODOT` points to a Godot binary. |

## Run

```sh
# Godot 4.4.1-stable, Linux x86_64, official build 49a5bc7b6
# zip SHA-256 d6e382fb531019f85630c1f485a561a0d20c4a2344b6c3847735cfee7da812aa
export FAIRPLAY_GODOT=/path/to/Godot_v4.4.1-stable_linux.x86_64
python3 -m unittest tests.test_godot_spike -v
```

## Results (cloud container, Linux x86_64, loopback only)

- **Kernel parity:** honest, attacker and mixed scenarios produce the same
  SHA-256 digest in GDScript and Python, byte for byte.
- **Replay:** the server's demo log, replayed through the Python oracle,
  reproduces the server's digest exactly (invariant 5 foundation).
- **Authority:** in a 64-tick loopback match the attacker's movement was
  clamped every tick, 56 shots were rejected for cadence, 3 forged packets
  carrying a position were dropped as malformed, and 3 intents claiming the
  honest identity from the attacker's address were refused. None reached the
  kernel.
- **Server truth:** every state a client displays equals the oracle's state at
  that snapshot's tick.
- Test suite passed three consecutive runs.

## Findings to carry forward

1. **Honest late inputs: fixed on `claude/jitter-buffer-v01`, Proposed.**
   The kernel used to fill a missing input with the next sequence number and
   yaw 0, so the real packet was discarded as stale, the loss never healed,
   and the view snapped (7 stale in 64 loopback ticks; 107 in 128 with an
   injected two-tick delay). Decision 0002 makes a missing input a neutral
   tick that consumes no sequence, and adds a per-player server jitter buffer
   (`--jitter-ticks`, default 3). With the same injected fault: zero stale
   inputs and all 11 legal shots accepted. Still never counted as suspicion.
2. **Clients can miss the final snapshot.** UDP gives no delivery guarantee,
   so clients must interpolate and reconcile, never assume the latest state.
3. **Transport is now DTLS with per-player tokens** (invariant 2). The
   server makes a self-signed certificate per match; clients trust only that
   certificate and must present their access token in HELLO. Wrong tokens,
   identities claimed inside another session, plaintext packets and forged
   positions are all refused before the kernel. Certificate distribution and
   token issuing beyond one machine are open (`docs/COMMUNITY_SERVERS.md`).
4. **Netfox drives the tick.** `tests/netfox_tick.gd` runs the kernel from
   Netfox's `NetworkTime` loop at 64 Hz and matches the oracle digest. A
   fresh checkout must run `godot --headless --path godot --import` once so
   Netfox's class names resolve; the tests and the server runner do this.
6. **Stage 2: ENet with DTLS and Netfox clock sync across processes.**
   Server and two clients as separate processes on loopback: clients stamp
   each intent with their synced estimate of the server tick; intents arrive
   a median of 1 tick (max 3 with injected jitter) after the tick they name.
   Unsynced, they would be about 70 ticks off. With the honest client's
   input held two ticks every eight, no honest input was late or discarded.
   Netfox's own time messages are trusted for timing only: a client can
   claim to be synced (`_submit_sync_success` accepts any peer), which only
   affects when the match starts, never an outcome. ENet refuses plaintext
   packets in its DTLS layer; the server logs a handshake error but cannot
   count them, so the test checks they never reach the kernel instead.
7. **Stage 3: prediction and reconciliation for the local player.** The
   client applies each intent to its own copy of the kernel as it sends it,
   then on every snapshot restarts from the server state and replays the
   intents the server has not confirmed. Honest play with a two-tick fault
   and a three-tick buffer: 0 corrections in about 128 confirmed ticks. With
   no buffer: 12 corrections, each caused by a server neutral tick, largest
   error 48 units (one tick of movement). Tests require every correction to
   have a server-side cause (underrun, late or trimmed input). Snapshots now
   carry yaw, health and the next legal fire tick so replay is exact.
8. **Hits and bounded lag compensation (decision 0003, Proposed).** The
   kernel traces every accepted shot with integer rays, rewinds targets to
   the tick the shooter saw (at most 13 ticks) and applies damage and
   elimination. Python and GDScript agree on a three-player combat stream.
   Intents now carry `view_tick`; the attacker fixture claims tick 0 and is
   held to 13 ticks of rewind.
5. **The kernel is fingerprinted.** `kernel/KERNEL_SHA256` is published;
   every match records the hash it ran, and `scripts/check_repo.py` fails
   if the kernel changes without the published hash.

## Netcode candidates (October 15 assessment; Netfox chosen)

| Candidate | Licence | Version and activity | Fit |
| --- | --- | --- | --- |
| Netfox (`foxssake/netfox`) | MIT | 1.49.4, last commit 2026-09-26, Godot 4.1+ | Leading. GDScript on stock Godot; rollback and prediction plumbing under our kernel. |
| monke-net (`grazianobolla/godot-monke-net`) | No licence file at the repository root | 0.1.0, last commit 2026-04-02 | Poor fit now: C#, and requires a custom Godot fork for manual physics stepping. |
| Godot 4 Authoritative Server FPS framework (Asset Library) | Unknown | Unknown | Not evaluated: the Asset Library was not reachable from the cloud container. Check from the Mac. |
