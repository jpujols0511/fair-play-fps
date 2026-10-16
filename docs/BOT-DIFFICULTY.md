# Bot difficulty

Status: **Proposal for Joan**, October 16, 2026. The handout asked to
*expand* this document. It did not exist in the repository (checked on `main`
and every branch), so this is the first version. There is no bot code yet. All
numbers are starting values to measure and tune, not facts.

## Summary (read this first)

- **Bots play by the same rules as people.** A bot is a player that connects
  like any other, sends the same intent messages, and is judged by the same
  server. It gets **no secret information and no shortcuts.**
- **Difficulty is made of three honest dials:** how fast it reacts, how
  accurate its aim is, and how much it notices. Four tiers set those dials:
  **Easy, Medium, Hard, Expert.**
- **Reaction time is delayed, not faked.** A bot's brain sees the world through
  the same delayed, partial view a human client gets, and then waits its
  tier's reaction time before acting on it.
- **Expert is still beatable by a person.** It is bounded by what a very good
  human can do (the reaction floor and turn speed in section 3). A bot that
  beats those limits would look like the aimbots the detection system hunts.
- **Bots are always labelled.** They are never hidden in public matches, never
  count in player statistics, and never become training data for cheater
  detection.
- **Red-team attacker bots are a different thing** (section 8). They are
  test tools in closed labs and are not a difficulty tier.
- Items marked **DECISION FOR JOAN** need your choice.

## 1. Why bots, and why fairness matters here

`docs/LINEAGE_MATRIX.md` keeps from the Condition Zero era the idea of
"named bots with skill, reaction, teamwork, and weapon profiles" and rejects
"bots that see or react through invalid information." The architecture also
says offline practice should "share the exact server rules used online." A bot
that cheats teaches players to expect a game that cheats, which is the
opposite of this project.

## 2. The rules every bot follows (how bots stay fair)

1. **A bot is a client, not part of the server.** It runs as its own process or
   as a bot-driver module that talks through the same protocol as a human
   client: it authenticates with a token, then sends **intent only**
   (sequence, move axes, yaw, `view_tick`, fire). It has no way to write to the
   kernel. Kernel invariant 1.
2. **The server treats its intents like anyone's.** Movement is clamped,
   fire is limited by the cadence and ammunition rules, hits go through the
   same lag compensation, and the same evidence is written. A correct bot
   produces **zero** rejection events (`fire_cadence_rejected`,
   `empty_fire_rejected`, `input_clamped`).
3. **It knows only what a human client would know.** Its inputs are:
   - its own confirmed state (the snapshot);
   - the world packets: only the players the kernel says it may see
     (`visible_to`), drawn at the same few ticks in the past as a human's
     client;
   - the static map (humans can learn the map too);
   - events the server broadcasts to everyone in range (when sounds exist).

   It never gets the server's full state, another player's view, the
   health or position of anyone not in its world packets, or the match seed.
4. **Reaction time is a queue, not a fudge.** What the bot "sees" enters a
   delay line. It may use an observation only after the tier's reaction time
   has passed. No peeking at a newer state to make a sharper decision.
5. **`view_tick` is honest.** When a bot fires it reports the tick it actually
   drew, exactly as a human client does, so lag compensation treats it like a
   player with a normal connection. A bot on the server machine has no network
   delay, so this rule is what prevents a zero-latency advantage. The delay
   line plus the draw delay already cover it.
6. **Same tick rate, same buffer.** Bots run at the match's 64 or 128 Hz and
   through the same input buffer. All times below are in **milliseconds**
   and are converted to ticks once at start so a bot behaves the same at both
   rates.
7. **Same speed limits.** A bot moves with the same maximum speed and
   acceleration, stops with the same friction, and turns no faster than the
   tier's turn limit (section 3). The kernel does not yet cap how fast a
   player may turn, so bots must limit themselves.
8. **Deterministic and replayable.** A bot's random choices use a seed written
   to the demo header. A recorded bot match replays to the same digest.
9. **Labelled everywhere.** The scoreboard shows a bot marker. The demo header
   and the match result list which players are bots and what tier. The
   protocol carries a bot flag set by the server at admission, not by the bot.
10. **No hidden bots.** Public matches never contain unlabeled bots. This is an
    anti-goal in `docs/THREAT_MODEL.md` ("secretly placing bots into public
    matches").
11. **Never in the evidence base.** Bots are excluded from detector
    calibration, banned-database training, reviewer queues and skill
    statistics, by label.

## 3. The four tiers

Numbers describe what the bot does, measured at the point where it shoots at
a stationary target. "Reaction time" is the time from a target first being in
the bot's world packet to the bot's first fire intent.

### 3.1 Summary table

| Setting | Easy | Medium | Hard | Expert |
| --- | --- | --- | --- | --- |
| **Reaction time**, average (ms) | 600 | 400 | 280 | 210 |
| Reaction time spread (± ms, one standard deviation) | 150 | 100 | 70 | 40 |
| Reaction time **floor**, never faster (ms) | 350 | 220 | 160 | 150 |
| **Aim error** when firing, one axis, 1σ (degrees) | 4.0 | 2.0 | 1.0 | 0.6 |
| **Turn speed limit** (degrees per second) | 120 | 220 | 360 | 540 |
| **Aim settle time** after a turn (ms) | 250 | 160 | 100 | 60 |
| **Awareness:** attention cone, full detail (degrees wide) | 60 | 80 | 100 | 120 |
| Awareness: outside the cone, extra delay (ms) | +300 | +200 | +120 | +60 |
| Awareness: view range (metres) | 25 | 35 | 50 | 50 |
| Awareness: hearing range for footsteps (metres) | 8 | 12 | 16 | 20 |
| Awareness: memory of a lost enemy (seconds) | 2 | 4 | 6 | 8 |
| Fire discipline: bursts of | 1 | 1–2 | 1–3 | 1–4 |
| Moves while shooting (strafe) | rarely | sometimes | often | almost always |
| Callout delay to teammates (seconds) | none | 2.5 | 1.5 | 1.0 |

Notes on the numbers:

- **Reaction times** are tied to what humans can do. Typical people react to
  something they see in roughly 200 to 300 ms; the very best in a simple
  test are somewhat quicker. Expert uses an average of 210 ms with a floor
  of 150 ms so that it is fast but not unnaturally so. (A rough human
  figure, not a measurement made for this project; check with playtests.)
- **Aim error** is the random miss of the aim direction at the moment of
  firing. For a person-sized target, the hit radius is 400 mm (a prototype
  value in decision 0003), so the angle that still hits is about 2.3° at 10 m,
  1.1° at 20 m and 0.6° at 40 m. Chance to hit a standing target with a
  single shot, one axis only, from the table above:

  | Distance | Easy | Medium | Hard | Expert |
  | --- | --- | --- | --- | --- |
  | 10 m | 43% | 75% | 98% | 100% |
  | 20 m | 23% | 43% | 75% | 94% |
  | 40 m | 11% | 23% | 43% | 66% |

  These come from a simple calculation (normal distribution, 400 mm radius),
  **not** from a played match. When pitch (up and down) aim exists, the bot
  has the same error on that axis too, so real figures will be lower. Moving
  targets and settling time reduce them again.
- **Turn limit** keeps bots from flicking faster than a good human can. Human
  flicks are fast; the limit here is a deliberate ceiling on Expert, not a
  statement of what a human can do.
- **Awareness** is about attention, not extra information. The cone and the
  extra delay stand for "I was looking the other way."
- **Memory** means the bot remembers the last place it saw an enemy and
  searches a growing area around it (no faster than the speed limit allows).
  It does not learn where the enemy moves unseen.
- **Callout delay** is how long before a bot shares *something it saw itself*
  with teammates, to stand in for speech. **DECISION FOR JOAN:** do bots
  communicate at all? Shared sightings make teams stronger and bots feel more
  like a team, but a delay of 0 would be a hive mind.

### 3.2 Reaction time in ticks

Reaction times are stored in milliseconds. Converted once:

| Tier (average) | Milliseconds | Ticks at 64 Hz | Ticks at 128 Hz |
| --- | --- | --- | --- |
| Easy | 600 | 38 | 77 |
| Medium | 400 | 26 | 51 |
| Hard | 280 | 18 | 36 |
| Expert | 210 | 13 | 27 |
| Expert floor | 150 | 10 | 19 |

### 3.3 What each tier feels like

- **Easy:** slow to notice you, misses a lot, stands still, forgets you
  quickly. A learning partner. Wins only by luck against a new player.
- **Medium:** reasonable aim, takes cover occasionally, reacts like a casual
  player.
- **Hard:** a competent player. Strafes, bursts, remembers where you were.
- **Expert:** as fast and accurate as the human limits above allow. Beats most
  people in a straight duel but not every skilled one, and can be out-played
  by position, because it still loses track of you when you leave its sight.

**DECISION FOR JOAN:** do you want a fifth, **Custom**, where a player edits
the dials (within the Expert limits), or only the four fixed tiers?
Also: should a tier adapt to the player during a match? I propose **no
adaptation** (predictable practice, easier to test, easier to keep fair).

## 4. What a bot is allowed to do each tick

In order, every tick, inside the bot driver:

1. **Read** new snapshot and world packets (what a human client reads).
2. **Delay** them by the reaction time, plus the extra delay for targets
   outside the attention cone.
3. **Choose** an action: move, aim at a remembered target, fire, or hold.
4. **Limit** the intended turn by the turn-speed limit and the settle time.
5. **Add** the tier's random aim error to the aim direction when it decides to
   fire, using the logged seed.
6. **Send** one intent: sequence, move axes in the legal range, yaw, the
   `view_tick` of the frame it was reasoning about, and the fire flag.

It does **not**: read the kernel's state, query another player's position
outside its packets, write any state, choose a team slot or ignore the
freeze phase (`docs/SCORE_AND_ROUND_RULES.md`).

## 5. How we prove a bot is fair (conformance tests)

Each tier should pass these before it is offered to a player. None has been
written.

| Test | Pass condition |
| --- | --- |
| Rule compliance | In 20 matches per tier at 64 and 128 Hz, zero `fire_cadence_rejected`, `empty_fire_rejected`, `input_clamped` or `view_tick_invalid` events. |
| No hidden information | Put an enemy just outside the bot's world packets. Over 100 trials the bot never turns toward it, fires at it, or paths to it faster than chance. |
| Reaction time | Median measured reaction within ±10% of the tier average; no reaction below the floor. |
| Aim accuracy | Hit rate on a standing target at 10, 20 and 40 m within ±5 percentage points of the table. |
| Turn limit | No tick turns faster than the tier limit. |
| Same at 64 and 128 | The above measures differ by no more than ±10% between profiles. |
| Replay | A recorded bot match replays to the server digest. |
| Labelling | Scoreboard, demo header and result list the bot and its tier. |
| Detector check | Run the existing offline detection on bot matches. Expert must **not** be flagged as cheating. If it is, either the detector thresholds are too tight (an important finding about false positives) or the bot is not human-bounded. Either way fix before shipping. |

The last row doubles as a useful false-positive test. The bot is not a
substitute for real skilled human demos (`docs/DOCS_GAP_ANALYSIS.md`, G21):
bots are consistent in ways humans are not, so passing it proves little about
people.

## 6. Bots in different places

| Where | Bots allowed? | Rules |
| --- | --- | --- |
| Offline practice | Yes | Same server rules, run locally. Shows the bot marker. |
| LAN or private match | Yes | Labelled, host adds them openly. |
| Community server | If the host enables it | Labelled in the scoreboard and the result. A host may fill empty slots with bots. Matches with bots are excluded from review and ban data. |
| Public official match | **Not secretly.** | Only an openly-labelled mode, if any. |
| Replacing a player who left | Only if the mode allows it, openly | **DECISION FOR JOAN** (see `docs/SCORE_AND_ROUND_RULES.md`, section 8). |

## 7. What is not covered

- **Navigation and teamwork logic** (where to go, who covers whom): needs maps
  and an objective (M4). This page covers perception, reaction and aim only.
- **Weapons beyond the first rifle**, grenades and the economy: a bot's
  weapon skill would extend the same dials.
- **Voice and text chat** by bots: none.
- **Learning bots** (machine learning that adapts from games): not proposed.
  `AGENTS.md` keeps machine learning to ranking evidence in research or
  shadow mode; the same caution applies here. A learning bot could slowly
  discover cheat-like behaviour, which would be hard to explain or bound.

## 8. Red-team attacker bots are separate

The architecture's "bot red team" (`FAIR_PLAY_ENGINE_ARCHITECTURE.md`)
simulates cheaters (assisted aim, impossible movement, information
advantage) to test detectors. The existing `controlled_attacker_commands`
fixture is a tiny example.

- They run **only in isolated labs** against closed servers, never in public
  matches or with real players.
- They are allowed to break the rules in this page's section 2 on purpose.
  That is their job.
- They are labelled with ground truth ("this one cheats at 30% strength") in
  the demo so detectors can be scored.
- They are never offered as difficulty tiers, and nothing in the practice-bot
  code path may be able to turn into one by a setting.

## 9. Notes for anti-cheat design later (not designed here)

- **Bots define the human-plausible envelope.** The Expert tier's limits
  (reaction floor 150 ms, turn speed 540°/s, aim error 0.6°) mark the edge of
  what we will treat as "human." Detection thresholds for reaction and aim
  should be set with real skilled-player data, not copied from these values.
- **Kernel gap:** the kernel does not limit how fast a player may turn or how
  quickly consecutive aim changes may occur. The threat model lists
  "impossible view-angle change sequences" as a validator. Bots limit
  themselves, but a human client can still send any yaw each tick.
- **Aim error is random.** A detector that looks for "too perfect" aim will
  see an Expert bot as a human-like outlier at 0.6°. Keep bot matches out of
  detection baselines by label (rule 11).
- **Bot flag trust.** The bot flag must be set by the server at admission, never
  claimed by a client, or a cheater would claim to be a bot to escape review.
- **Attacker bots as ground truth.** Section 8's labelled demos are the
  first dataset for any detector; they need the same demo format and a clear
  "synthetic" label so they never mix with real reviews.
