# Fair Play Engine Architecture

Status: Product and security architecture proposal  
Scope: Separate competitive-shooter project, not VEYR  
Owner: Joan Pujols

## Vision

Fair play is part of the game simulation, not a removable plugin. The engine,
server, replay format, matchmaking, evidence system, and enforcement pipeline
share one security contract.

The system evolves in two layers:

1. A stable, signed production authority that is deterministic and replayable.
2. An adaptive research layer that learns from telemetry and controlled attacks,
   proposes changes, and must pass shadow testing and review before promotion.

Production authority never rewrites its own enforcement code during a match.

## Non-negotiable rules

- The server is authoritative for movement, shots, recoil, spread, visibility,
  damage, inventory, economy, objectives, and match outcome.
- A client request expresses intent, never truth.
- Every punishment has reproducible evidence and a policy version.
- Machine learning ranks evidence; it does not issue irreversible bans alone.
- Unknown behavior increases observation, not punishment.
- Privacy collection is minimized and documented.
- Players can appeal meaningful enforcement.
- Detection changes are versioned, reversible, and measurable.
- False positives are a release blocker.
- Client secrecy is never the only defense.

## Runtime architecture

```text
Player input
  -> signed client protocol
  -> authoritative simulation
  -> invariant validators
  -> evidence event stream
  -> match replay ledger
  -> risk scoring
  -> bounded response policy
  -> review / appeal / enforcement
```

### Authoritative simulation

The server independently computes:

- Position, velocity, stance, collision, and legal acceleration
- Weapon state, fire cadence, ammunition, recoil, and spread seed
- Line of sight, lag-compensated hit validation, and damage
- Purchases, drops, trades, inventory, and round economy
- Objective state, timers, team state, and score

The client renders prediction for responsiveness, but the server corrects any
divergence and records material disagreement.

### Deterministic invariant validators

Start with explainable rules:

- Impossible displacement or acceleration
- Invalid firing cadence or ammunition state
- Shot origin outside legal player state
- Impossible view-angle change sequences
- Hits without plausible visibility after lag compensation
- Economy or inventory transitions without a valid server event
- Repeated prediction divergence
- Protocol mutation, replay, or timing anomalies

One anomaly does not equal cheating. Validators create evidence with severity,
confidence, context, and expected benign causes.

### Evidence ledger

Every match produces a compact server-side record containing:

- Build, map, ruleset, policy, and detector versions
- Input and authoritative-state deltas
- Shot, hit, visibility, economy, and objective events
- Network-quality context
- Detector outputs and confidence
- Server corrections

The ledger must support deterministic replay without recording voice chat,
private messages, unrelated processes, or broad device contents.

## Adaptive evolution

### Allowed live adaptation

The production system may adjust within signed bounds:

- Observation detail
- Evidence sampling rate
- Matchmaking trust confidence
- Review priority
- Challenge or verification frequency
- Temporary containment that does not assert guilt

### Prohibited live adaptation

The production system may not autonomously:

- Rewrite authoritative simulation code
- Invent a new bannable offense
- Expand data collection
- Deploy an unreviewed model
- Permanently ban based only on an opaque score
- Change appeal rights

### Learning pipeline

```text
Reviewed match evidence
  -> labeled research dataset
  -> controlled attacker bots
  -> candidate rules/models
  -> offline replay evaluation
  -> adversarial testing
  -> shadow production
  -> false-positive review
  -> signed staged rollout
  -> monitored promotion or rollback
```

Labels must distinguish confirmed cheating, suspicious behavior, skilled play,
network artifacts, accessibility tools, bugs, and unknown cases.

## Bot red team

Controlled bots simulate attacks in isolated environments:

- Aim assistance at varied strengths
- Trigger timing assistance
- Impossible movement requests
- Information advantage without visible targets
- Packet timing and replay anomalies
- Economy and inventory manipulation attempts
- Coordinated account behavior

Bots never enter public matches disguised as players. Their purpose is to test
detectors, produce known-ground-truth replays, and measure evasion resistance.

## Enforcement ladder

1. Record evidence.
2. Increase observation within the disclosed policy.
3. Correct invalid state server-side.
4. Separate high-risk matchmaking only when policy permits.
5. Queue review.
6. Apply temporary action with a reason category.
7. Apply permanent action only with sufficient reproducible evidence.
8. Accept appeal and rerun evidence under the original policy version.

Ban waves may conceal individual detector triggers, but internal evidence remains
traceable. Hardware identity is only a supporting risk signal because it can be
spoofed and may affect shared machines.

## Metrics

Track:

- Confirmed-cheater detection rate
- False-positive rate by detector and player cohort
- Time from first evidence to containment
- Appeal overturn rate
- Skilled-player escalation rate
- Network-condition error rate
- Detector drift
- Evasion success in red-team simulations
- Player-reported match quality

The primary goal is fair matches, not maximum bans.

## First bounded prototype

Build a headless two-player arena before a full shooter:

- Fixed-timestep authoritative server
- Thin predictive clients
- Movement, one hitscan weapon, health, and respawn
- Deterministic replay
- Movement, cadence, ammunition, origin, and visibility validators
- Synthetic latency, loss, and jitter
- Controlled attacker bot
- Evidence viewer
- No kernel driver, hardware ban, neural network, marketplace, or public release

Acceptance:

- Honest clients remain playable under the tested network envelope.
- Invalid state never becomes authoritative.
- Every detection can be replayed and explained.
- Known attacks are detected without flagging the clean test suite.
- Policy and detector versions reproduce the result.

## Staged roadmap

### Stage 0: Threat model

Define protected outcomes, trust boundaries, attacker capabilities, privacy
limits, and acceptable false-positive risk.

### Stage 1: Authoritative arena

Prove server authority, prediction, correction, replay, and baseline validators.

### Stage 2: Evidence and review

Build the replay viewer, policy ledger, reviewer workflow, and appeals model.

### Stage 3: Controlled bot laboratory

Generate attacks and network artifacts with ground-truth labels.

### Stage 4: Adaptive research

Evaluate candidate statistical models offline, then in shadow mode.

### Stage 5: Private human test

Measure play feel, skilled-player false positives, accessibility interactions,
privacy, and reviewer workload.

### Stage 6: Limited release

Use staged deployment, rollback, incident response, and published fair-play rules.

## Open product decisions

- Game identity, movement model, and round structure
- Engine language and platform targets
- Dedicated server hosting model
- Privacy regions and retention
- Review and appeal ownership
- Accessibility-tool policy
- Account and identity model
- Whether trusted hardware attestation is justified
- Public transparency level

## Immediate next step

Write the threat model before selecting a neural network, kernel component, or
hardware identity strategy. The first engineering proof is authoritative
simulation plus deterministic evidence, because every later detector depends on
that foundation.
