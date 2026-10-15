# Fair Play FPS — design thesis

Joan Pujols' design thesis, recorded October 15, 2026. Every session and sub-agent reads
this on entry. It states what the project is for and which rules nothing may
weaken. Implementation detail belongs in separate documents that cite this one.

## Thesis

An open-source, free, community-owned, fair competitive FPS.

**Fairness is the kernel, not a feature.** The kernel of fairness lives on the
server, never on the player's machine.

## Kernel invariants

These are the rules every change is checked against. A change that weakens
any of them is rejected, however popular the feature.

1. **The server is authoritative.** The client is never trusted on anything
   that matters. It sends inputs and renders server-confirmed truth.
2. **Traffic is encrypted and authenticated.** Client-server traffic blocks
   packet-sniffing wallhacks and spoofed messages.
3. **Feel comes from lag compensation, not from client trust.** The game
   feels instant while the server stays authoritative.
4. **No kernel-level anti-cheat, ever.** The game stays Linux-native and
   cross-platform.
5. **Detection never touches live performance.** It runs asynchronously, off
   recorded demos.
6. **False positives are sacred.** A wrongly flagged honest player is the
   worst outcome the system can produce. Every design trade favours avoiding
   it.

## Architecture

- **Server-authoritative simulation.** All outcomes that matter (movement
  validity, hits, damage, economy, match results) are decided on the server.
- **Client role.** Collect inputs, predict locally for responsiveness,
  reconcile to server state, render. Nothing the client says is accepted as a
  fact about the world.
- **Transport.** Encrypted and authenticated channel between client and
  server. Only data a player is entitled to see is sent to that player.
- **Lag compensation.** Server-side rewind for hit validation so shooting
  feels instant without trusting the shooter.

## Engine

**Godot** (MIT licence). Truly open, which matches the ownership thesis.

Do not rely on Godot's default multiplayer for competitive netcode. It lacks
native prediction and rollback. Build the fairness kernel on an existing
authoritative-server FPS framework or addon.

References named by the owner, to evaluate before choosing:

- Godot 4 Authoritative Server FPS framework (Godot Asset Library), which
  uses Quake, Overwatch and Valve methods.
- monke-net.
- Netfox.

Record the choice, its licence and the evaluation in a decision record before
building on it.

## Layered design and separation of powers

- **Kernel:** small, fixed, authoritative. Owns simulation truth, hit
  validation, transport and the invariants above.
- **Community surface:** moddable and community-owned. Maps, modes and
  weapons live here.
- **The rule between them:** nothing on the community surface can weaken the
  kernel. Mods describe content; the kernel decides outcomes.

The game evolves with the community, not with cheaters.

## Detection pipeline

A HAWK-style cyclical pipeline, entirely server-side.

1. Read demo replay files.
2. Extract temporal and behavioural features.
3. Flag anomalies.
4. Confirmed cheaters go into a banned database.
5. That database becomes new training data, and the cycle repeats.

Rules for the pipeline:

- **Asynchronous, off demos** (XGuardian-style), so it never affects live
  matches.
- **Explainable flags first.** A reviewer must be able to see why a player was
  flagged.
- **Context-aware weighting** by population, hour of day and live moderation
  coverage.
- A flag is a reason to review, never a verdict on its own.

References named by the owner: OACS, and LSTM aimbot detection on 128-tick
sequences reported at about 88% accuracy with under 1% false positives. These
figures are as supplied and not yet verified here. Re-measure on this
project's own data before relying on any threshold.

## Community review

Overwatch-style demo review, protected against untrustworthy reviewers by
three stacked defences:

1. **Blind review.** Reviewers see raw gameplay only: no names, ranks or
   friend links.
2. **Consensus.** Several independent reviewers per case. A reviewer's weight
   is earned by matching verified outcomes over time.
3. **Seeded ground truth.** Known-cheater and known-clean cases are mixed into
   the queue to audit the auditors.

## Sustainability

- Community-hosted dedicated servers.
- Open source, owned by everyone, built for the next generation of players.

## Relationship to the existing documents

This thesis arrived after the first architecture pass. Most of it agrees with
`FAIR_PLAY_ENGINE_ARCHITECTURE.md`, `THREAT_MODEL.md` and `AGENTS.md`:
server authority, no kernel anti-cheat, explainable validators, evidence
before punishment, machine learning only as ranked evidence with human
review. Three points differ and stay open until Joan decides them. Until
then, the existing file governs and nothing is changed silently.

| Topic | Existing repository | This thesis | Status |
| --- | --- | --- | --- |
| Licence and visibility | Proprietary, private by default (`LICENSE.txt`, `README.md`) | Open source, free, community-owned | Open. Joan chooses the licence; `LICENSE.txt` is unchanged until then. |
| Engine | Language and libraries unselected; "Linux-first native stack" | Godot 4 (MIT) | Proposed in `decisions/0001-engine-and-netcode.md`. |
| Learned detectors | Neural networks listed as a current non-goal | LSTM sequence detector as one research reference | Compatible only as offline, shadow-mode ranking with no punishment authority, per `AGENTS.md`. Promotion needs Joan's approval. |

## How sessions use this document

- Read it on entry, after `AGENTS.md`. `CLAUDE.md` lists the full read order.
- Any change that touches networking, authority, transport, detection or
  review states in its commit message which kernel invariants it touches and
  how it preserves them.
- Anything here that is not yet built is a target, not a claim. Report status
  by level: authored, statically checked, compiled, run, playtested, accepted.
