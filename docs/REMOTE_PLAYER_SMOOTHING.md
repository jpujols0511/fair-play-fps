# Remote player smoothing

Status: **Guide for Devin, with decisions for Joan**, October 16, 2026. Written
from the design docs and the `claude/world-view-v01` branch. I could not see
Devin's current smoothing work, so check each point against what he has.

## Summary (read this first)

- **Remote players look choppy** when the client draws each server update the
  moment it arrives. Updates come 64 or 128 times a second, but they arrive
  unevenly, and the screen refreshes at its own rate (60, 144 or more).
- **The cure** is to draw other players *a little in the past* and glide them
  between two real server updates. Because the client always has a
  newer update than the one it is drawing, there is nothing to guess.
- **Nobody sends their position to anyone else.** Every other player on your
  screen comes from one source: the server's world packet. Smoothing is pure
  drawing; it adds no trust in anyone.
- **The delay is a trade.** A longer delay hides more jitter and loss, but the
  shooter sees targets further in the past, so lag compensation has to rewind
  further. Both are spent from the same 200 ms budget (see
  `docs/CLIENT_PREDICTION.md`, section 6).
- **Aim for:** a draw delay of about **2 updates plus a jitter margin**, about
  **40 to 50 ms**, defined in milliseconds so 64 and 128 Hz look alike.
- **Four problems to fix first** (section 5): fractional render time, a
  render clock tied to the network clock, facing that snaps, and players that
  pop in and out.

## 1. How remote players get on your screen today

From `godot/net/world_view.gd` and `godot/net/protocol.gd` on the world-view
branch:

1. Each server tick, the server sends the client a **world packet**: the tick
   number and, for each *other* player the kernel says this client may see,
   `x`, `y`, `yaw_millidegrees` and `health`. Players outside what the client
   may see are not in the packet at all (`visible_to`, 60 m, distance only
   until maps land).
2. The client stores the packets by tick (`frames`, the last 64 ticks).
3. `view()` picks the newest stored frame at or before `newest - delay`.
   `delay` defaults to **2 ticks** (`--interp-ticks`).
4. `sample(millitick)` gives positions for a fractional tick by blending
   linearly between the two surrounding frames, using integers only.
5. Each shot's `view_tick` reports which tick was drawn, so the server can
   rewind to it (bounded by `MAX_REWIND_TICKS`).

Missing from this list, and a source of choppiness: nothing yet connects a
render clock to `sample()` (section 5.1) and facing is not blended.

## 2. Why it looks choppy: plain-language causes

| Cause | What you see | Fix |
| --- | --- | --- |
| Drawing at the tick, not at the screen refresh | Players move in steps at 64 steps a second; on a 144 Hz screen some frames repeat | Draw at the screen's own time, interpolated between two ticks |
| Uneven arrival (jitter) | A player pauses, then jumps | Draw further in the past than the worst usual jitter |
| A lost packet | A one-frame freeze or a jump | Interpolate across the gap; the delay gives enough spare frames |
| Several lost in a row | A longer freeze | Extrapolate a little, then hold (section 4) |
| Facing snaps | Heads and guns jitter | Blend facing as an angle, the short way round |
| A player entering or leaving view | Pop in, pop out | Section 5.4 |
| Delay changing every frame | Players speed up and slow down | Change delay slowly (section 3) |

## 3. The method: a render clock that runs behind the server

Think of a film that always plays about 45 ms behind a live camera. There is
always a later frame in hand, so you can slide between two real frames instead
of guessing.

1. **Render time.** Each rendered frame, compute:

   > render time = estimated server time (from Netfox's clock) − interpolation delay

   Use a continuous clock (milliseconds or thousandths of a tick), not whole
   ticks.
2. **Pick two frames.** The stored frames just before and just after render
   time. Blend with the fraction of the way between them. `sample()` already
   does this part.
3. **Interpolation delay** is the one setting to tune. Proposed:

   > delay = 2 update intervals + a jitter margin, with a floor and a ceiling

   | | 64 Hz | 128 Hz |
   | --- | --- | --- |
   | One update interval | 15.6 ms | 7.8 ms |
   | 2 intervals | 31 ms | 16 ms |
   | Proposed floor for the whole delay | 31 ms | 23 ms |
   | Proposed typical on a good connection | about 45 ms (3 ticks) | about 45 ms (6 ticks) |
   | Proposed ceiling | 100 ms | 100 ms |

   These are my starting values. They are not measured. **DECISION FOR JOAN:**
   the ceiling. A higher ceiling smooths bad connections more but costs more
   of the rewind budget.
4. **Adapt slowly.** Measure jitter in the arrival of world packets over the
   last few seconds. Raise the delay quickly when packets are late, lower it
   slowly when the connection is calm, and never change it within one frame
   by more than a small step. Players should never appear to speed up.
5. **Report what was drawn.** `view_tick` must be the tick of the frame the
   crosshair was actually looking at (round down to a whole tick, so the
   server never rewinds to a time later than what was drawn).

### Hand-off with lag compensation

What is drawn is what the server will check the shot against. That keeps the
rule simple: *you hit what you saw.* If the interpolation delay is larger, the
shot's `view_tick` is older and the rewind is larger. Never change the delay
without checking the rewind budget (`rewind_ticks` in the hit evidence).

## 4. Gaps: lost packets and what to do when there is nothing newer

With a 2 to 3 tick delay there is normally a newer frame. When there is not:

1. **Short gap (up to about 100 ms):** extrapolate using the last known
   velocity (from the last two frames), at most 100 ms, and slowly fade the
   guess back when the real frame arrives. The extrapolated position is only
   drawn; it is never sent back and never used for hits (hits use the server's
   own recorded history).
2. **Longer gap:** hold the last position and show a "connection problem"
   marker if it lasts more than about 250 ms. Do not slide a player onward
   through walls on a long guess.
3. **A late frame arrives:** blend toward it over a few frames. Do not snap
   unless the error is very large (a respawn).

Extrapolation is allowed because it is a drawing aid. It must stay out of the
kernel: the kernel's authoritative state never contains a guessed position.

## 5. Four concrete fixes for Devin

### 5.1 Drive `sample()` from a continuous render clock

`sample(millitick)` takes a fractional tick, but on the world-view branch only
a test calls it; the headless client uses `view()` and the rendered graybox
does not draw remote players yet (`docs/STATUS.md`: remote-player rendering is
unverified). Feed it `server_time_in_ticks × 1000 − delay`
once per rendered frame from the Netfox clock estimate. Keep `view()` for the
`view_tick` report only.

### 5.2 Blend facing as an angle

`sample()` currently copies the later frame's `yaw_millidegrees` without
blending (`"yaw_millidegrees": b["yaw_millidegrees"]`). Facing therefore jumps
a whole update at a time. Blend with the **shortest arc**: the difference
between 359° and 1° is 2°, not 358°. Use integers as the rest of the function
does. Health is a count and is fine to copy from the later frame.

### 5.3 Measure the delay in milliseconds

Express `--interp-ticks` as milliseconds and convert to ticks for the profile
in use. At 128 Hz the same 2 ticks is only 16 ms, which is too short to hide
normal jitter; at 64 Hz 3 ticks is 47 ms, about right.

### 5.4 Pop-in and pop-out at the edge of view

`sample()` draws a player missing from one of the two frames where the other
frame has them. That is right for a lost packet but wrong at the edge of
visibility: the player appears or disappears abruptly. Two rules:

- The **server** decides who is in the packet. A client must never try to
  guess who it "ought" to see.
- The client may fade a player in and out over about 100 ms when they enter or
  leave the packet. This hides nothing from the server and shows nothing the
  server did not send.

When walls exist, the server must send a player slightly *before* they come
into line of sight (a margin), or fast peeking players appear late. That
margin gives a small information leak by design. **DECISION FOR JOAN:** the
margin size (see `docs/DOCS_GAP_ANALYSIS.md`, information leaks).

## 6. Trusting nothing from other players

The rules that keep this safe, none of which need new code:

1. Clients **never** talk to each other. There is no peer-to-peer position.
2. The server builds each world packet from its own kernel state. A player's
   position is the one the kernel computed from that player's *clamped*
   intent, not a number the player sent.
3. A client only receives players the kernel says it is entitled to see
   (kernel invariant 1 and the threat model, "knowledge outside legitimate
   visibility").
4. Everything in the packet is encrypted and authenticated (invariant 2): no
   one on the network can inject or change a remote player.
5. Smoothing and extrapolation run on the receiving client and change only
   pixels. They never go back to the server except as the `view_tick` number.
6. A client that draws other players wrongly on purpose only hurts its own
   view. The server's hit check uses its own history, not the client's picture.

What a malicious *client* can still do is read data it was properly sent, for
example draw players through walls if the server sends them. That is why
visibility must be decided on the server (section 5.4) and why distance-only
visibility is a temporary stand-in.

## 7. What not to do

- Do not run a *second* physics simulation for remote players using guessed
  inputs ("dead reckoning" beyond the short extrapolation above). It diverges
  and tempts people to correct it with client data.
- Do not interpolate between a player's current position and a position
  reported by that player.
- Do not shorten the delay to "feel more responsive" without checking the
  rewind budget. Players feel their *own* movement through prediction, not
  through the delay on others.
- Do not smooth the server's recorded history. Smoothing is only for drawing.

## 8. Test plan (nothing here has been run)

1. **Record and replay a world feed** from a real match (the demo already
   replays). Draw it at 60, 144 and 240 Hz and check there are no repeated
   positions on screen.
2. **Fault injection** with the same tools as the jitter test: drop 1%, 5%
   and 10% of world packets and delay some by 30 and 80 ms. Record pop rate,
   longest freeze and the delay the adaptive logic picks.
3. **Same scene at 64 and 128 Hz:** the drawn path should look the same.
4. **Aim test:** the existing aimer-versus-strafer test must still hit where
   the target was drawn, with the new delay.
5. **Human test:** a player watches a strafing bot at 0, 50 and 100 ms of added
   latency and rates smoothness.

## 9. Open items

**DECISION FOR JOAN**

1. Maximum interpolation delay (proposed 100 ms).
2. Size of the visibility margin once walls exist.

**For Devin**

- Items 5.1 to 5.4.
- Make the jitter estimate part of the network diagnostics, recorded but never
  used as suspicion.

## 10. Notes for anti-cheat design later (not designed here)

- **A delayed view is a legitimate reason for misses.** Reviewers and
  detectors need the interpolation delay and `view_tick` for each shot to
  judge whether a hit or miss made sense. Record them.
- **Draw-delay cheating.** A client could choose an unusually small or large
  delay for advantage (for example, always rewinding the maximum). The
  server's rewind cap bounds the gain; a validator can compare `view_tick`
  with measured network delay (see `docs/CLIENT_PREDICTION.md`, section 10).
- **Pop-in and visibility margins** are exactly where wall-hack detection
  works: a player who turns toward an opponent who is in the packet but not
  yet visible by line of sight. The margin size sets how noisy that signal is.
- **Remote health in the world packet.** Today it is sent for every visible
  player. Whether enemies' health should be known is a design choice, and
  it is also information advantage data.
