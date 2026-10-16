# Client prediction with Netfox at 64 and 128 ticks

Status: **Explanation and proposal for Joan and Devin**, October 16, 2026.
Describes the design in decisions 0001 to 0003 and the branches that carry it.
Nothing here has been tested across machines or by players.

## Summary (read this first)

- **The problem:** your screen is always a bit behind the server. If the game
  waited for the server before moving you, every key press would feel
  sluggish (a delay of your ping).
- **The fix, "prediction":** your computer runs a copy of the movement rules
  on your own inputs and shows the result at once. This is a *guess* that is
  only drawn. It is never sent to the server and never counts.
- **The correction, "reconciliation":** every server update carries the truth.
  The client throws its guess away, starts from the server's state, and
  replays the inputs the server has not confirmed yet. If the guess was right
  (the usual case) nothing visibly changes. If not, the player is nudged.
- **What is predicted:** only *your own* movement, aim and the "you fired"
  feel. **Never** health, hits, damage, kills, score, round state or other
  players.
- **Lag compensation** is the other half. Prediction makes *you* feel
  instant. Lag compensation makes *your shots* land where you saw the target.
  They solve different problems and must not be mixed up (section 6).
- **64 vs 128 ticks:** the same rules and the same real-time behaviour, with
  half the gap between steps at 128. More steps to replay and about twice the
  packets, but each step is cheaper to get wrong. Details in section 5.
- **Two things to decide** (section 9): how the client smooths corrections, and
  whether the 200 ms rewind limit is big enough once the other delays are
  added up.

## 1. What is built today

Facts from the code and status notes on the branches (loopback, one Linux
machine, Godot 4.4.1). Not on `main` yet unless stated.

| Piece | Where | State |
| --- | --- | --- |
| Shared movement kernel (same code on server and client) | `godot/kernel/fairplay_kernel.gd` | On `main`. Matches the Python oracle at 64 and 128. |
| Intent-only protocol | `godot/net/protocol.gd` | On `main`. No field for position, health, damage, ammunition or score. |
| Server jitter buffer (3 ticks by default) | `godot/net/input_buffer.gd`, decision 0002 | On `main`. |
| ENet with DTLS and Netfox clock sync | `godot/net/enet_*.gd`, branch `claude/netfox-enet-v01` | Branch. Devin's staged branch has it as opt-in. |
| Predict own player, reconcile to snapshots | `godot/net/prediction.gd`, branch `claude/prediction-v01` | Branch. |
| Hits with bounded rewind | decision 0003, branch `claude/hits-lag-comp-v01` | Branch, **Proposed** (needs Joan). |
| Other players drawn in the past | `godot/net/world_view.gd`, branch `claude/world-view-v01` | Branch. |

The handout says Devin's PR #1 (lag compensation and prediction) is merged.
It does not appear in the repository I could see, so check the facts above
against `main` as it stands today.

Netfox is used for the **clock and tick timing**. The prediction and
reconciliation logic is project code in `prediction.gd` (`docs/THIRD_PARTY.md`
says Netfox "never" holds game rules). I did not find Netfox's own rollback
nodes in use, and recommend keeping it that way: they would put rollback logic
outside the kernel.

## 2. Plain-language walkthrough

Think of the server as a referee with the official film, and your client as a
spectator who draws a quick sketch of the next few seconds.

1. You press forward. The client makes an **intent**: "sequence 412, move
   forward, facing this way, fire: no". It sends it to the server and, in the
   same moment, applies it to its own copy of the movement rules, so you move
   on screen right away.
2. The client keeps the sent intents in a list: "sent but not confirmed".
3. The server buffers your intent for a few ticks (the jitter buffer, so
   late or reordered packets are not lost), applies it, and sends back a
   **snapshot**: "as of tick 9,000 I applied up to your intent 407, and your
   state is: x, y, speed, facing, ammunition, next legal shot".
4. The client compares: "did I predict that state after intent 407?" Then it
   deletes intents up to 407 from the list, **restarts from the server's
   state**, and replays intents 408, 409... on top of it.
5. If the replayed result is where you already are on screen, nothing
   changes. If not, you have a **correction** and the client smooths or snaps
   it (section 4).

This is already how `prediction.gd` works: it compares the fields `x`, `y`,
`velocity_x`, `velocity_y`, `yaw_millidegrees`, `ammunition` and
`next_fire_tick`, counts `corrections` and records the largest error.

## 3. What gets predicted, and what never does

| Thing | Predicted by the client? | Why |
| --- | --- | --- |
| Your position, speed and facing | **Yes** | Needs to feel instant. Same kernel code, so honest play predicts exactly. |
| Your ammunition and "can I fire yet" | **Yes** | So the trigger does not feel dead. The server's answer replaces it. |
| Muzzle flash, sound, recoil kick (drawn only) | **Yes, cosmetic** | Feel. Cosmetic effects must not claim a hit. |
| Hit marker, blood, damage numbers | **No** | A hit is a server fact. Show it when the server says so. |
| Your health and eliminations | **No** | Caused by other players' shots, which only the server resolves. |
| Kill credit, scoreboard, round winner | **No** | Server facts (see `docs/SCORE_AND_ROUND_RULES.md`). |
| Other players' positions | **No (drawn from the past)** | Predicting others means guessing their inputs. See `docs/REMOTE_PLAYER_SMOOTHING.md`. |
| Pickups, doors, objectives | **No** | Shared world state belongs to the server. |

Rule of thumb: **if another player could be affected, the client only draws
what the server told it.** If only *you* feel it, a drawn guess is allowed.

### Why the client cannot decide anything

- The prediction is stored in the client and *never travels*. The wire format
  has no place for it (`protocol.gd` strict length and field checks, kernel
  invariant 1).
- A tampered client that predicts wrong positions only hurts itself: the next
  snapshot overwrites them.
- Movement is clamped by the server (`input_clamped` evidence), so claiming a
  huge move does not move you.
- Inputs are applied one per tick, in sequence order, from a buffer
  (decision 0002), so sending faster buys nothing.

## 4. How the server corrects the client

Corrections come from four honest causes:

1. The server applied a **neutral tick** because your input had not arrived
   (decision 0002).
2. The server dropped an intent: too old, duplicate or beyond the buffer.
3. The server clamped or rejected something the client had assumed (for
   example a shot the cadence rule refused).
4. A **different server state** the client could not know: being teleported
   at round start, spawning, or (later) pushed by a collision with another
   player.

With no loss and no jitter, honest play predicts **exactly**, because both
sides run the same integer kernel. The status notes report this on loopback.
In real networks corrections will happen, mostly from cause 1.

### Smoothing a correction (visual only)

The client holds two positions: the **true predicted position** (used for
the next prediction step) and the **displayed position**. When they differ:

| Error (kernel units, 1 unit ≈ 1 mm) | What to draw |
| --- | --- |
| Under about 5 mm | Snap. Invisible. |
| About 5 mm to 500 mm | Blend the displayed position toward the true one over about 100 ms. |
| Over about 500 mm | Snap. The player was really moved (respawn, big error). |

These thresholds are my proposal, not measured. They must be tuned in a
playtest. **DECISION FOR JOAN** is in section 9. The smoothing never changes
what gets sent or what the server believes.

## 5. Netfox at 64 and 128 ticks

The kernel supports both profiles (`SUPPORTED_TICK_RATES = (64, 128)`). The
design rule is **define everything in milliseconds, convert to ticks once.**

| | 64 Hz | 128 Hz |
| --- | --- | --- |
| Time between ticks | 15.6 ms | 7.8 ms |
| Max rewind (200 ms) | 13 ticks | 26 ticks |
| Jitter buffer of 3 ticks | 47 ms | 23 ms |
| Inputs sent per second | 64 | 128 |
| Intent payload, 8-char id | 32 bytes × 64 ≈ 2 KB/s up | 32 bytes × 128 ≈ 4 KB/s up |

(The payload size is from the encoding in `protocol.gd`; real packets add
DTLS and UDP headers.)

What this means in practice:

- **Same behaviour, finer steps.** Speeds, acceleration and the fire interval
  are scaled so a player covers the same ground and fires at the same real
  rate at both profiles (the Python and GDScript kernels both do this).
- **Replay cost.** The client replays every unconfirmed intent after each
  snapshot. At 100 ms round trip plus a 47 ms buffer that is about 9 ticks at
  64 Hz and about 19 at 128 Hz. The kernel step is a few integer operations,
  so this is cheap. It should still be timed on the lowest hardware we care
  about.
- **Packet rate doubles.** 128 Hz means twice the packets up and down. Fine
  on a LAN; worth measuring on home connections. A cheap fix is to send the
  last few intents in every packet (section 9).
- **Buffer in ticks vs milliseconds.** The default buffer is **3 ticks**, so
  the same setting is twice as short in time at 128 Hz. Choose it in
  milliseconds. **DECISION FOR JOAN** (section 9).
- **Netfox clock sync.** The client estimates the server's tick and sends each
  intent stamped with it, aiming to arrive just in time to be at the front of
  the buffer. The server never takes a client's claimed tick as truth about
  the world: it releases one buffered intent per tick whatever the client
  says. A client with a fast or slow clock only hurts its own smoothness.
- **Not built yet:** client "time dilation" (the client gently speeding up or
  slowing down to keep the server buffer at its target). Decision 0002 lists
  it as open.

## 6. How prediction fits with lag compensation

Three different clocks are in play for one shot. This is the part that is
easiest to get wrong.

```text
            what the shooter sees           what the server judges
  you        PRESENT (predicted)             your position at your intent's tick
  target     PAST (interpolated, drawn       target's position at view_tick
             a few ticks behind)             (rewound, at most 13 ticks / 200 ms)
```

- **You are drawn in the present** because prediction shows your own input
  immediately.
- **Other players are drawn in the past** because the client only has
  snapshots that already travelled to it, and it draws a little further back
  to interpolate smoothly.
- When you fire, the intent carries `view_tick`: the tick whose picture of the
  world you were looking at. It is an **opinion about the past, never a
  position or a hit**.
- The server rewinds only the **other players** to `view_tick` (bounded to
  `MAX_REWIND_TICKS`), traces the shot from your position at that intent, and
  decides. A `view_tick` older than the limit is clamped and recorded as
  `rewind_limited`; one from the future is ignored (`view_tick_invalid`).
- **Prediction and lag compensation agree only if your predicted position
  matched the server's.** That is why exact, deterministic prediction matters.
  If a correction moved you, the shot is judged from where the server says you
  were.
- Health is not predicted, so the client never claims a kill. It draws the
  tracer at once and waits for the server's hit event.

### The rewind budget (a likely problem)

The distance between "what I saw" and "what the server judges" is roughly:

> round-trip time + how far behind the client draws others + the server jitter
> buffer

With the default draw delay of 2 ticks (`--interp-ticks`, `enet_client.gd` on
the world-view branch) and the 3-tick buffer at 64 Hz, that is about
**31 ms + 47 ms = 78 ms before any network at all**, leaving about **125 ms of
round trip** inside the 200 ms limit. But the status notes record a rewind of
**9 ticks (about 140 ms) on loopback**, where the network adds nothing. The
two extra ticks beyond my sum (2 + 3 = 5) are unexplained: they probably come
from clock-sync offset and snapshot timing. If 9 ticks is the true floor, the
room left for real network delay at 64 Hz is only about **4 ticks, or 62 ms of
round trip**. At 128 Hz the same tick counts use half the time, but the cap is
the same 200 ms, so the budget is looser.

This is my reading of the numbers and has **not been measured over a real
network.** It matters because a player over the budget would find shots
missing on moving targets, while a bigger cap lets a high-ping player shoot
players who already moved behind cover. That trade-off is the one the roadmap
M2 exit names ("high latency does not grant unlimited rewind advantage").

## 7. Failure cases to design for

| Situation | What happens | What the player sees |
| --- | --- | --- |
| A single packet lost | Server uses a neutral tick, or the buffer hides it | Tiny correction |
| Burst of loss (100+ ms) | Several neutral ticks, then input resumes | A pull-back, then smooth |
| Jitter within the buffer | Nothing | Nothing |
| Jitter beyond the buffer | Neutral ticks, `stale_input` and `underrun` counts | Small corrections |
| Client sends too fast | Buffer releases one per tick; backlog is trimmed | Nothing gained |
| Client clock wrong | Netfox adjusts; if it cannot, intents arrive early or late | Stutter on that client only |
| Client claims a huge move | Server clamps, writes `input_clamped` | Corrected next snapshot |
| Client edits its predicted state | Nothing is sent | Overwritten at the next snapshot |
| Client claims an old `view_tick` | Clamped to 13 ticks, `rewind_limited` | Gains at most 200 ms |
| Snapshot lost or reordered | Older or duplicate snapshots are ignored | A slightly later correction |
| Server restart | Connection ends | Reconnect, as in `docs/SCORE_AND_ROUND_RULES.md` |

## 8. Test plan (nothing here has been run)

1. **Deterministic match:** with no loss, prediction error is 0 over a full
   round at both profiles. (Passing today on loopback.)
2. **Injected jitter:** extend the existing `hold2` fault to loss, reordering
   and duplication at 0, 50, 100 and 150 ms round trip. Record corrections per
   minute and largest error.
3. **Rewind budget:** record `rewind_ticks` per accepted shot at each latency,
   at both profiles, with the real draw delay and buffer. Find the round trip
   at which shots start hitting the cap.
4. **Replay cost:** time a replay of 40 unconfirmed ticks on the lowest target
   machine.
5. **Cross-machine LAN**, then a real home connection. Both are untested.

## 9. Open items

**DECISION FOR JOAN**

1. Correction smoothing: the thresholds in section 4 (5 mm, 500 mm, 100 ms).
   The principle (snap big errors, blend small ones) is not a rules question;
   the numbers are feel and need a playtest.
2. Rewind cap: keep 200 ms, or raise it (for example to 250 ms) if the budget
   in section 6 proves too tight. This is a fairness trade-off and is already
   open in decision 0003.
3. Buffer and draw delay in **milliseconds** instead of ticks, so 64 and 128
   behave alike.

**For Devin** (technical, not a rules decision)

- Send the last 2 to 3 intents in each packet, so one lost packet costs
  nothing. This is a protocol change (version bump).
- Build client time dilation (Netfox clock) to hold the server buffer at its
  target.
- Keep the client prediction kernel free of any hit or health authority; the
  existing guard (health shown from the snapshot) is correct.

## 10. Notes for anti-cheat design later (not designed here)

- **Prediction divergence is a signal, but a weak one.** The architecture
  lists "repeated prediction divergence" as a validator. Honest corrections
  come from loss and jitter, so any use must be weighted by network quality
  and never count toward suspicion on its own. The demo today records inputs
  but not per-player arrival times or round trips; without those, a detector
  cannot tell a laggy honest player from a dishonest one.
- **`view_tick` is the lag-compensation attack surface.** The attacker test
  fixture already claims the maximum rewind on every shot. The server could
  check each claimed `view_tick` against the delay it measured for that
  player and flag claims no honest client could make. Not built.
- **Time-based abuse.** Lag switches (cutting the connection to cause
  neutral ticks) and clock manipulation need server-side counters per player
  per minute; the counters exist, the thresholds do not.
- **Do not log predicted state as truth.** The demo must continue to hold
  only what the server received and decided.
