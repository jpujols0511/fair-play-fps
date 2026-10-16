# Score and round rules

Status: **Proposal for Joan**, October 16, 2026. Nothing here is built. Every
number is a starting value to test, not a final choice.

## Summary (read this first)

- A match is a race between two teams to win rounds. First team to **13 round
  wins** takes the match (the same length as the classic tactical shooters).
  A short **first to 7** format is proposed for early testing.
- A round ends when one team is eliminated, when the objective is completed
  (from milestone M4), or when the timer runs out.
- Ties at 12–12 go to **overtime**: blocks of 6 rounds, first to 4 wins a
  block. A hard cap and a single sudden-death decider round make sure a match
  always ends.
- The **server decides everything on this page.** The client never sends a
  score, a kill, a timer or a winner. It only sends movement, aim and
  fire-intent, as it does today. The scoreboard on your screen is what the
  server last told you.
- Rule numbers (how long a round is, how many rounds win) are **mode
  settings**. Who got the kill and who won the round are **kernel truth**.
  That keeps community modes possible without letting a mod rig a result.
- One real fairness problem found while writing this: when two players shoot
  each other in the same tick, the current code lets the player whose name
  sorts first win. This page proposes the fix (section 6).

Items marked **DECISION FOR JOAN** need your choice before Devin builds them.

## 1. What exists today, and what does not

Checked in the repository on `origin/main` and the proposal branches:

- The kernel steps players in a fixed order, accepts movement and fire intent,
  and (on the proposal branches, decision 0003) resolves hits, damage, health
  and elimination. See `prototype/fairplay_sim.py` and
  `godot/kernel/fairplay_kernel.gd`.
- There is **no round, no timer, no respawn rule, no team, no objective and no
  score** in the kernel. `docs/ROADMAP.md` lists "Health and respawn" for M1
  and the "objective zone" for M4.
- `docs/DESIGN.md` says the server owns "movement validity, hits, damage,
  economy, match results", and that mods "describe content; the kernel decides
  outcomes". These rules follow that.
- The handout says Devin's `m1-movement-combat` branch has score work in
  progress. I could not see that branch or PR #1 in the repository I was given
  (see the report at the end of the task), so these rules are written from the
  design docs, not from his code. Devin should compare them to what he has.

## 2. Vocabulary

- **Tick**: one step of the server's clock. 64 per second or 128 per second
  (the two supported profiles).
- **Round**: one short fight, from start to a winner.
- **Half**: the first 12 rounds. Teams swap sides after it.
- **Kernel**: the small fixed server-side rule book that nothing is allowed to
  weaken (invariants in `docs/DESIGN.md`).

## 3. Match structure

| Rule | Proposal |
| --- | --- |
| Teams | Two teams. Team size is a mode setting. **DECISION FOR JOAN:** 5 v 5 (classic) or smaller for early tests. The kernel should support any size from 1 v 1 up. |
| Sides | Two sides, **Attackers** and **Defenders**, once an objective exists. Before M4 (no objective), both teams are equal and rounds are pure elimination. |
| Match length | First to **13** round wins. 12 rounds per half. Sides swap after round 12. |
| Short format | First to **7**, 6 rounds per half, for testing and quick games. |
| Team assignment | The server assigns teams and sides at match start. Clients cannot choose their slot on the wire. A lobby can *ask* for a team; the server grants it. |
| Fixed loadout | One rifle, full ammunition, 100 health, every round. No buying until a separate economy decision (see section 9). |

## 4. Round structure

A round has three phases. The server keeps a **round state** and moves it only
on tick counts or kernel events.

| Phase | Length (proposal) | What the server enforces |
| --- | --- | --- |
| **Freeze** | 10 s | Everyone is placed at their spawn. Movement and fire intents are accepted but have **no effect** (neutral tick). Players can look around. |
| **Live** | 115 s | Normal play. The round ends early on a win condition. |
| **Round end** | 5 s | Outcome is shown. Fire and movement are ignored. Then the next round's freeze phase starts. |

Lengths are stored in **milliseconds** in the mode settings and converted to
ticks once, so a round lasts the same real time at 64 and 128 ticks:

| Length | Ticks at 64 Hz | Ticks at 128 Hz |
| --- | --- | --- |
| 10 s freeze | 640 | 1,280 |
| 115 s live | 7,360 | 14,720 |
| 5 s round end | 320 | 640 |

The timer is the **server's tick count**. No client clock is ever used.

**DECISION FOR JOAN:** 115 s per round is the classic length. Shorter rounds
(about 90 s) suit small arenas.

### Who wins a round

Checked in this order each tick, after all shots in that tick are resolved:

1. **Elimination.** All players on one team have 0 health. The other team
   wins.
2. **Objective** (from M4). The attackers complete the objective, or the
   defenders stop it. Details come with the M4 map work.
3. **Timer.** The live phase reaches its last tick with no winner. With an
   objective, the **defenders** win (the attackers failed to act). Before M4,
   the team with more total remaining health wins. If that is equal too, it
   is a **draw round**: nobody scores and the round is played again (it does
   not count toward the 12 rounds of a half).
4. **Both teams eliminated in the same tick.** See section 6. Proposed:
   the defending team wins when an objective exists; before M4, the round is
   a draw round as above.

**DECISION FOR JOAN:** is a draw round acceptable, or should the timer always
favour one named team?

### Respawn

None inside a round. A player eliminated stays out until the next round. This
is what gives rounds their tension (`docs/LINEAGE_MATRIX.md`, "round economy,
loss tension"). A separate **deathmatch mode** with respawn can be a
community mode; it is not scored by this page.

## 5. Scoring

### Team score (decides the match)

- A round win is **1 point**. Nothing else changes the match score. Kills,
  damage and objectives do not add team points; they only help win rounds.

### Player stats (shown on the scoreboard, never decide the match)

| Stat | Rule |
| --- | --- |
| Kills | The server credits the player whose **accepted shot** reduced the target to 0 health. |
| Deaths | Each elimination. |
| Assists | Damage of at least **40** (prototype) on a target who is then eliminated by a teammate within **5 s**. |
| Damage | Total health removed from enemies. |
| Team damage / team kills | Friendly fire is **off** at first, so there are none. **DECISION FOR JOAN.** |

Stats are produced by the kernel from kernel events. They are for display,
for review and for later detection. They are **not** used to pick the winner.

### Ranking players on a scoreboard

Sort by kills, then damage, then fewer deaths. If all three are equal, the
players are shown as **tied**. Never break a tie by player name, join order or
id. See section 6 for why.

## 6. Ties

### Match tied at 12–12 (overtime)

1. Overtime is played in **blocks of 6 rounds** (3 per side, then swap).
2. The first team to win **4 of the 6** takes the match.
3. If a block ends 3–3, play another block.
4. **Hard cap:** after **3 overtime blocks**, one **decider round** is played.
   Sides are chosen by the match seed (below). It cannot be drawn: if the
   timer runs out, the **defenders** win.

**DECISION FOR JOAN:** the cap exists so a server cannot be held for hours.
Is a decider round acceptable, or would you rather allow a drawn match?

### Same-tick trades (important)

Today, when two players both fire in the same tick, the kernel handles them
**in alphabetical order of player id**. The first one kills the second before
the second shot is even resolved, and the dead player's shot is thrown away
(`eliminated_fire_rejected`). Two players with the same aim and the same
network delay do not get the same result. The player whose id sorts first
always wins the duel, and a player who can influence their id could always
win it.

Proposed rule for the kernel (a change that needs Python and GDScript to
change together, and a new kernel hash):

> **Shots in one tick are all resolved against the same start-of-tick state.
> Damage is applied to everyone afterwards, together.** Two players can
> eliminate each other in the same tick (a **trade**). Neither shot is
> discarded.

This makes the duel depend only on skill and legitimate timing, which is what
invariant 6 ("false positives are sacred") and the fairness thesis ask for.
It also changes how the "both teams eliminated in the same tick" case above
arises: trades make it possible, so that case needs the rule above.

For anything that really must pick one thing out of equals (for example, which
side a decider round starts on), use a **match seed**: a random number the
server picks and **writes to the demo header before the match starts**. Anyone
can replay the draw and see it was not chosen after the fact. Never use a
name or id order.

### Decision rules in short

| Question | Answer |
| --- | --- |
| Same-tick trade | Both eliminations stand. |
| Tied scoreboard | Show as tied. No name-based tie-break. |
| Tied match | Overtime blocks, hard cap, decider round. |
| Anything needing a coin-flip | The match seed, written before play. |

## 7. How each rule stays decided on the server

For every rule above, this is what the client can do and what the server does.
The client sends only the intent fields it sends today: sequence, movement,
yaw, the tick it was drawing (`view_tick`) and fire.

| Rule | The server does | The client may do | The client can never |
| --- | --- | --- | --- |
| Round phase and timer | Counts ticks, moves the state | Show a countdown from the last server state | Start, stop or extend a round |
| Spawn and freeze | Places players, ignores intent during freeze | Show the freeze view | Move during freeze |
| Kill credit and damage | Resolves the shot with lag compensation (decision 0003) | Draw a muzzle flash and tracer at once | Claim a hit, a kill or damage |
| Round winner | Applies the order in section 4 after all shots | Show the result when told | Say who won |
| Match score | Adds 1 per round win | Display the server's last score | Send a score |
| Overtime and sides | Applies the schedule, uses the match seed | Display it | Choose its side after the match starts |
| Scoreboard stats | Computes from kernel events | Display | Edit a stat |
| Disconnects | Applies the policy in section 8 | Try to reconnect with the same token | Forfeit or "win by default" for anyone |

Every round event (round start, elimination, round win, overtime start, match
win) is a **kernel evidence event** written into the demo. The demo already
replays to the server's digest, so a replay re-derives the exact score. If a
score cannot be replayed from the demo, that is a bug.

Predicted score on a client (for example a kill counter that goes up the
instant you fire) is not allowed. Show the server's number only. A kill
**feel** effect (a sound or a flash) can be drawn at once, but the number
changes only when the server says so. See `docs/CLIENT_PREDICTION.md`.

### Mode settings versus kernel

| Lives in the mode settings (community surface) | Lives in the kernel (nobody can weaken) |
| --- | --- |
| Round length, freeze length, rounds to win, team size, overtime block size | Who is eliminated, who gets credit, who wins a round, the order of win checks, the match seed rule, same-tick trade handling |

Mode settings are loaded before the match, hashed, and **the hash is written to
`result.json` next to the kernel hash**, so anyone can see what rules a match
ran under (this extends `docs/COMMUNITY_SERVERS.md`). Settings have hard
bounds in the kernel (for example, rounds-to-win between 1 and 50) so a mode
cannot create an unwinnable or infinite match.

**DECISION FOR JOAN:** which settings may community servers change freely, and
which must stay fixed for a match to count as an "official ruleset" match?

## 8. Disconnects and leaving

- A dropped connection is **not** treated as guilt or forfeit. Network
  trouble is never suspicion (`stale_input` and related findings are already
  excluded in `detection/features.py`).
- A disconnected player's slot keeps the last facing and takes **neutral
  ticks**. They can rejoin with the same token for up to **60 seconds**
  (prototype). They come back at the next round's freeze phase; they are not
  respawned mid-round.
- A team that falls below a mode-set minimum for more than **120 seconds**
  forfeits the *match*, decided by the server.
- Leaving penalties belong to a later account and ranking system. This page
  does not design them. **DECISION FOR JOAN:** replace leavers with bots
  (labelled, see `docs/BOT-DIFFICULTY.md`), or play short-handed?

## 9. Not covered here

- **Economy and buying.** Listed in the lineage matrix as a "keep"; it needs
  its own proposal once the objective and weapons exist.
- **Objective details** (plant, defuse, hold zone): M4.
- **Grenades, reload, knife, crouch:** they change when and how a player can
  be eliminated and must be checked against the order in section 4 when they
  land.
- **Spectators and reviewers:** which events they may see, and when (see
  `docs/DOCS_GAP_ANALYSIS.md`).

## 10. Notes for anti-cheat design later (not designed here)

- Score-related cheating is only possible if a client can influence a score.
  Because only the kernel creates scoring events, the threats left are
  *indirect*: boosting, collusion and match-fixing (throwing rounds). Those
  need the stats above recorded per round in the demo.
- Round-by-round stats make an honest "hot streak" visible. Detection must
  not treat a high kill count alone as guilt (`docs/THREAT_MODEL.md`: "Guilt
  from high skill alone" is an anti-goal).
- Freeze-phase intent that "has no effect" must still be recorded, so a
  reviewer can see what a player tried to do.
- A decider round and the match seed are places where a dishonest server
  operator could cheat. Writing the seed before play, and having the demo
  replay, is the control. See the community-server trust gap in
  `docs/DOCS_GAP_ANALYSIS.md`.
