# Docs gap analysis: threat model and engine architecture

Status: **Review for Joan**, October 16, 2026. Read `docs/THREAT_MODEL.md` and
`docs/FAIR_PLAY_ENGINE_ARCHITECTURE.md` against `docs/DESIGN.md`,
`docs/PROJECT_CONTEXT.md`, `docs/ROADMAP.md`, the decision records and the
code on the branches. Documentation only; no code was changed or run.

## Summary (read this first)

- The two documents are sound and agree with each other on the big things:
  the server decides, evidence comes before punishment, machine learning only
  ranks, unknown means observe not punish.
- They were written **before** the design thesis, the engine choice and most
  of the code. Several statements are now out of date or contradict each
  other (section 2).
- **Biggest gaps** (section 3 has the full list):
  1. **Who vouches for a demo?** Community servers send demos to review. A
     dishonest server owner could invent inputs and frame a player. Nothing
     in the docs covers this.
  2. **No number for "acceptable false positives."** Stage 0 promises one, the
     thesis says false positives are sacred, but no number exists.
  3. **Identity is undecided** (accounts, tokens, bans). Every anti-cheat piece
     leans on it.
  4. **Information leaks by design today:** other players are sent by
     distance only (no walls) and with their health.
  5. **The evidence the demo keeps is too thin** to tell a laggy honest player
     from a cheater.
  6. **One fairness flaw in the kernel:** same-tick duels are decided by
     player-name order (details in section 3, G5).
- **Do not rush the anti-cheat design.** This page lists what to settle first
  so that the design is built on settled ground. Section 5 is the short
  version.
- Items marked **DECISION FOR JOAN** need an answer; section 6 collects them.

## 1. How I did this

- Read both documents line by line, then the design thesis (six invariants),
  roadmap, status notes, decisions 0001 to 0003, `COMMUNITY_SERVERS.md`, and
  the kernel, protocol, detection and review code on `main` and the proposal
  branches.
- "Missing" means the documents do not mention it. "Inconsistent" means two
  documents say different things. "Undecided" means the documents list it as
  open or leave it out of any decision.
- The handout says Devin's work (PR #1, `m1-movement-combat`) is merged or
  ready. I could not see it, so anything about hits, movement and combat
  comes from the earlier branches and may already be answered by his code.

## 2. Inconsistencies and stale statements

| # | Where | What does not line up | Suggested fix |
| --- | --- | --- | --- |
| I1 | `ARCHITECTURE`: "Engine language and platform targets" open; "Immediate next step: write the threat model" | The engine is Godot 4.4 (accepted, decision 0001) and the threat model exists | Mark both done; update the "Open product decisions" list |
| I2 | `PROJECT_CONTEXT`: "long-term direction is a Linux-first native stack"; "language unselected" | Godot and GDScript are chosen | Update the engine strategy section |
| I3 | `THREAT_MODEL` says "Initial high-level model"; `STATUS` says "Threat model in progress" | Neither says it is accepted or what is still missing | State a version and status |
| I4 | **Three numbering schemes for the same plan**: `ARCHITECTURE` Stages 0 to 6, `ROADMAP` M0 to M5, decision 0001 "integration stages 1 to 3" | Stage 2 "Evidence and review" is roughly M3; "private human test" has no milestone | One scheme, or a table that maps them |
| I5 | `ARCHITECTURE`: "signed client protocol"; `THREAT_MODEL`: "signed server policy and detector configuration" | Built: DTLS plus per-player access tokens. Nothing is *signed* (policy, detectors, builds) and no one has chosen who holds the signing keys | Say "encrypted and authenticated" for the protocol; add a signing section (G10) |
| I6 | `PROJECT_CONTEXT` non-goal "Hardware bans", `THREAT_MODEL` "Hardware identity as sole proof" (anti-goal) and `ARCHITECTURE` "Hardware identity only as a supporting risk signal" and open "Whether trusted hardware attestation is justified" | Three different strengths: none, supporting, maybe attestation. Attestation also conflicts with invariant 4 (no kernel-level anti-cheat) on Linux-native play | Settle one line (U3) |
| I7 | `ARCHITECTURE`: "Ban waves may conceal individual detector triggers" vs `DESIGN`: explainable flags, blind review, and `THREAT_MODEL`: reason categories and appeals | A wave that hides which rule fired makes an appeal and an explanation harder | Decide whether waves are allowed at all, and what an appealing player is told (U6) |
| I8 | `ARCHITECTURE`/`THREAT_MODEL` ladders list slightly different steps (containment, matchmaking separation, disclosed observation) | Two lists, two orders | One ladder in one place; the other links to it |
| I9 | `ARCHITECTURE`: review by "human or reproducible-evidence" (`THREAT_MODEL`) vs `DESIGN`: blind community review with moderator sign-off | Can reproducible evidence alone ever act without a person? | Say no, or define exactly what an automatic action may be |
| I10 | "Evidence" is used for two things: kernel events including **network diagnostics** (`stale_input`, `rewind_limited`) and evidence **of cheating** | The code excludes the first from suspicion (`NEVER_SUSPICION`) but no document defines the split | Two terms: *diagnostics* and *signals*; define in the architecture |
| I11 | `ARCHITECTURE` lists "recoil, spread seed, economy, inventory, purchases" as server-computed | The kernel today has movement, one rifle, cadence, ammunition, and (on a branch) hits | Mark each as "built / branch / planned" |
| I12 | `STATUS`: AGPL etc. "selected direction"; `OPEN_SOURCE_READINESS`/`DESIGN`: not chosen | See `docs/LICENCE_SUMMARY.md` | One status |
| I13 | `THREAT_MODEL` trusts "Versioned dedicated server simulation" without saying whose | The community-server model (`COMMUNITY_SERVERS.md`) means servers are run by third parties | Split trust: *official* vs *community* servers (G1) |

## 3. Missing (not covered at all)

Severity is my judgement: **High** = needs a decision before the anti-cheat
design starts; **Med** = needed before a public test; **Low** = good practice.

| # | Gap | Why it matters | Sev | For anti-cheat? |
| --- | --- | --- | --- | --- |
| G1 | **Demo provenance and malicious server operators.** Community servers send flags and demos upstream. A dishonest operator can write a demo with invented inputs that replays cleanly to its digest, so a "valid" demo can still frame someone. Today the demo holds inputs the server says it received. | Invariant 6 (false positives are sacred). Evidence tampering is listed only for insiders. | **High** | **Yes, core.** Candidate controls to study: clients sign their own inputs, chained hashes, trust levels per operator, operator reputation, corroboration from two sources. |
| G2 | **Acceptable false-positive target.** Stage 0 promises one. Not defined. The thesis cites a detector with "under 1%" false positives (unverified). Worked example: 1,000 honest players, 10 cheaters, 88% found, 1% false alarms gives about 8.8 real and 9.9 false flags, so **about half the flags would be wrong.** Fine for review priority, never for punishment. | Sets the whole review load and decides what automation may do. | **High** | **Yes, core.** Pick a number per ladder step. |
| G3 | **Identity model** (accounts, tokens, bans, smurfs). Tokens are issued by the runner, have no expiry or revocation, and are not tied to a person. Open in the architecture. | A banned database is only meaningful if a ban attaches to something stable. Ban evasion, smurfing, boosting and report brigading (threat model) all need it. | **High** | **Yes, core.** |
| G4 | **Information leaks by design.** `visible_to` is distance-only (60 m), so every player in range is sent regardless of walls. The world packet also carries **enemy health**. There is no policy for the *margin* that must be added around line of sight so fast peekers do not pop in late, and none for sound events. | Until visibility is real, wall-hacks are "supported by the protocol." Margins decide how noisy any later wall-hack detector is. | **High** | **Yes.** |
| G5 | **Fair tie-breaking in the kernel.** In the hit-resolution code (decision 0003, branch), all players are processed in alphabetical order of id. If two shots land in the same tick, the earlier name kills first and the dead player's shot is discarded. Equal skill and equal lag do not give equal outcomes, and a player who controls their id can always win duels. | Fairness at the base of the game, and it would bias any "who shot first" evidence. Proposed fix in `docs/SCORE_AND_ROUND_RULES.md` section 6. | **High** | **Yes.** Detection that reads kill order would inherit the bias. |
| G6 | **Evidence is too thin to separate network from cheating.** The demo records every input the kernel received but not when each arrived, the measured round trip, loss, buffer fill, the draw delay, or any per-second summary. `result.json` has totals only. | `THREAT_MODEL` requires measuring "skilled-player and bad-network false positives." With the buffer hiding arrival jitter, a detector cannot tell. | **High** | **Yes, core.** |
| G7 | **Attacker tiers and capabilities.** Stage 0 promises "attacker capabilities"; the threat model lists classes only. No ranking of skill, cost, likelihood or impact. | A defence is judged against an attacker. Without tiers, there is nothing to test against. | Med | **Yes.** Suggest: casual script, paid software cheat, custom cheat, hardware assist (see G8). |
| G8 | **Residual risk we accept.** Invariant 4 (no kernel anti-cheat) means we cannot see the player's machine. Hardware aim assistance (an external device that moves the mouse) and screen-reading cheats leave nothing on the network. Only server-side behaviour can catch them. | Honest statement of what the system cannot stop. | Med | **Yes.** |
| G9 | **Policy for assistive and legitimate tools.** Open product decision "accessibility-tool policy." Also missing: controller aim assist, key remappers, one-handed setups, macro keyboards, high-DPI mice. All can resemble cheating and cause false positives. | Invariant 6. | **High** | **Yes.** |
| G10 | **Signing and release pipeline.** "Signed policy", "reviewed release pipeline" and "signed staged rollout" appear; there are no keys, builds or pipeline. | Trust anchor for everything marked "signed." | Med | Yes, later |
| G11 | **Retaining old kernels for appeals.** An appeal is re-run "under the original policy version", but the kernel hash changed at least twice on October 15 alone. Demos only replay on the kernel that wrote them. | You must keep every kernel that ever produced a punishable demo. | Med | **Yes.** |
| G12 | **Privacy and data inventory.** The threat model requires a "data inventory and retention record." None exists. Demos hold identifiable play; the banned database holds personal data; reviewers see demos. Legal basis, regions, deletion and age limits are open. | A prerequisite for any public test. | Med | **Yes.** |
| G13 | **Appeals and review ownership.** Both documents promise appeals and list "review and appeal ownership" as open. No process, timeline or role. | Appeals are the safety valve for G2. | Med | **Yes.** |
| G14 | **Bots.** The architecture covers *red-team* bots only. Missing: practice bots, bots filling empty slots, labelling, and keeping bot play out of detector baselines and any player statistics. (Covered in `docs/BOT-DIFFICULTY.md`.) | A bot that looks like a human would pollute training data. | Med | **Yes.** |
| G15 | **Spectators, replays and delayed feeds.** Listed as an information threat; nothing says what a spectator may see or how late (stream sniping, "ghosting"). Reviewer demos could also leak identity. | | Med | Yes |
| G16 | **Server-side denial of service and resource limits.** The threat model lists it; no requirement (packet rates, handshake cost, per-source limits). | | Med | No |
| G17 | **Community operator abuse.** The insiders section covers staff, not hosts: a host can edit mode settings, kick players, fake results, or run a modified kernel. | | Med | **Yes.** |
| G18 | **Griefing and non-cheat integrity**: team damage, intentional throwing, blocking, AFK, harassment, voice abuse. | Out of scope, or in scope? Not stated. | Low | Related |
| G19 | **Map and bug exploits.** The labels include "bugs" but no threat class covers out-of-bounds, clipping or glitch abuse, or the policy for using them. | | Low | Yes (false positives) |
| G20 | **The "tested network envelope" is never defined.** The prototype acceptance says honest clients stay playable "under the tested network envelope." No number is given. | Needed to test false positives on real networks. | **High** | **Yes.** Suggest a table: 0 / 50 / 100 / 150 ms round trip, 0 / 2 / 5% loss, 0 / 15 / 30 ms jitter. |
| G21 | **Skilled-human data does not exist.** The test suite wants skilled players; today there are only scripted fixtures. Bots cannot replace human skill data. | Without it, "no false flags" is only a statement about scripts. | **High** | **Yes.** |
| G22 | **Controls for time and rate abuse in the threat model.** The jitter buffer and `view_tick` bound already blunt timing manipulation and lag-switching (decisions 0002 and 0003), but the threat model still lists them as open. | Document what is done; leave the remainder visible. | Low | Yes |

## 4. Undecided (listed as open, or implied)

| # | Question | Where it is raised | Why it blocks |
| --- | --- | --- | --- |
| U1 | Identity and account model | ARCHITECTURE | G3 |
| U2 | Privacy region, retention, who reviews, who hears appeals | ARCHITECTURE | G12, G13 |
| U3 | Hardware identity: none, supporting, or attestation | ARCHITECTURE, PROJECT_CONTEXT | I6 |
| U4 | Accessibility and assistive-tool policy | ARCHITECTURE | G9 |
| U5 | Learned detectors (LSTM etc.): shadow-only, with Joan's approval to promote | DESIGN, AGENTS.md | Compatible; needs a promotion gate written down |
| U6 | Ban waves yes/no and what a player is told | ARCHITECTURE | I7 |
| U7 | Transparency level: what of the detector design is public | ARCHITECTURE | Licence boundary (`docs/LICENCE_SUMMARY.md`) |
| U8 | Official vs community servers (and "ranked" later) | LINEAGE, COMMUNITY_SERVERS | I13, G1, G17 |
| U9 | Hosting model for tokens and certificates | COMMUNITY_SERVERS ("Open") | G3 |
| U10 | Whether detection training data from community servers is accepted | DESIGN (pipeline) | G1 |

## 5. What matters most for the anti-cheat design later

In the order I would settle them. None needs code.

1. **Decide the acceptable false-positive target per ladder step (G2).** Every
   other choice (what to automate, how many reviewers) follows from it.
2. **Decide what makes a demo trustworthy (G1, G17).** The whole pipeline
   starts from "read demo files." Define the trust chain first.
3. **Decide identity (G3, U1).** Bans, smurfs, boosts and appeals all need it.
4. **Define the attacker tiers and what we accept not catching (G7, G8).**
5. **Fix the kernel evidence format (G6, G11).** Add network context and keep
   old kernels so the demo can answer "was this a laggy player?" Do this
   before collecting data you will want to keep.
6. **Fix the visibility policy (G4).** It decides how wall-hack evidence looks.
7. **Remove the duel-order bias (G5)** so "who shot first" means something.
8. **Write the assistive-tool and skilled-player policy (G9, G21).** Collect
   skilled human demos on purpose, with consent.
9. **Write the privacy record and appeal process (G12, G13)** before any
   public test.
10. **Keep bots out of the data (G14)** by label from day one.

## 6. Decisions for Joan, collected

1. **DECISION FOR JOAN:** What is the largest false-positive rate you would
   accept for: (a) putting a player in the review queue, (b) a temporary
   restriction, (c) a permanent ban? (G2)
2. **DECISION FOR JOAN:** Should a demo from a community server count as
   evidence on its own, or only when backed by a second source? (G1)
3. **DECISION FOR JOAN:** Account model: anonymous tokens, linked accounts, or
   accounts with a verified email? (G3)
4. **DECISION FOR JOAN:** Is hardware identity ever allowed? (I6, U3)
5. **DECISION FOR JOAN:** Ban waves allowed or not? (I7, U6)
6. **DECISION FOR JOAN:** Should enemy health be sent to clients, and how big
   a visibility margin is acceptable? (G4)
7. **DECISION FOR JOAN:** Is controller aim assist allowed, and which
   assistive tools are explicitly welcome? (G9, U4)
8. **DECISION FOR JOAN:** Who hears appeals (moderators, a panel, community
   reviewers)? (G13)
9. **DECISION FOR JOAN:** Which stage numbering is the real one: M0 to M5 or
   Stages 0 to 6? (I4)
10. **DECISION FOR JOAN:** Is griefing (team damage, throwing) part of this
    system? (G18)

## 7. Cheap fixes I would make now (documentation only)

These need no decision and should be one small commit when Joan agrees:

- Update the open-decisions list and "immediate next step" in the architecture
  (I1), the engine paragraph in `PROJECT_CONTEXT` (I2), and the status line in
  `THREAT_MODEL` (I3).
- Add a status marker (built / branch / planned) next to each server-side item
  in the architecture (I11).
- Add a mapping table between the stage numbers and milestones (I4).
- Define *diagnostic* versus *signal* in one paragraph of the architecture
  (I10).
- Add a one-line `NEVER_SUSPICION` rule to the threat model: network
  diagnostics never raise suspicion on their own (they already do not in
  code).

## 8. What is already handled well

For balance, these threat-model items are covered by built work, on `main` or
a branch (all loopback, one machine):

- Forged positions and spoofed identities are refused before the kernel; the
  protocol has no field for outcomes.
- Plain-text packets and wrong tokens are refused (DTLS with per-player tokens).
- A missing input no longer creates false snaps or discards honest input
  (decision 0002).
- Lag-compensation abuse is bounded to 13 ticks (decision 0003, proposed).
- Demos replay to the server digest, so a flagged event can be reproduced.
- Detection runs offline in a separate process, does not use network
  diagnostics as suspicion, and flagged nothing on the 60 clean test matches
  (scripted fixtures, not skilled humans: see G21).
