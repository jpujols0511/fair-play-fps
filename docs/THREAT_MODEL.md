# Competitive integrity threat model

Status: Initial high-level model

## Protected outcomes

- A player position is legal under the same movement rules as every opponent.
- A shot obeys weapon state, cadence, recoil, spread, visibility, and ammunition.
- Damage and death follow authoritative evidence.
- Inventory and economy follow valid server events.
- Objectives, score, rank inputs, and match result cannot be client-forged.
- Skilled play remains possible without being treated as guilt.

## Trust boundaries

### Trusted for authority

- Versioned dedicated server simulation
- Signed server policy and detector configuration
- Server-generated evidence ledger
- Reviewed release pipeline

### Untrusted inputs

- Client process and memory
- Local files and configuration
- Input devices and automation
- Network timing and packet contents
- Displayed identity and hardware identifiers
- Player reports
- Machine-learning score without corroborating evidence

A client reports intent. It never reports authoritative truth.

## Threat classes

### Simulation manipulation

- Impossible movement, acceleration, collision, stance, or timing
- Fire-rate, ammunition, reload, recoil, or spread manipulation
- Invalid shot origin or view state
- Damage, health, inventory, economy, objective, or score forgery

### Information advantage

- Knowledge of opponents outside legitimate visibility or sound
- Hidden-state extraction
- Spectator, replay, or teammate information leakage

### Input assistance

- Aim or trigger automation
- Recoil compensation
- Movement scripting
- Assistance tuned to resemble skilled human behavior

### Network abuse

- Packet mutation, replay, duplication, withholding, or timing manipulation
- Artificial latency used to extend lag compensation
- Disconnect and reconnect abuse
- Server or matchmaking denial of service

### Identity and progression abuse

- Smurfing and deliberate rank manipulation
- Boosting, account sharing, farming, and collusion
- Ban evasion
- Report brigading

### Supply-chain and operator risk

- Compromised builds, dependencies, signing, servers, or reviewer accounts
- Insider abuse
- Unreviewed policy or model deployment
- Evidence tampering or retention beyond policy

## Defensive principles

1. Prevent invalid state from becoming authoritative.
2. Record compact evidence sufficient to reproduce disputed events.
3. Correct state before punishing identity.
4. Combine independent signals for serious enforcement.
5. Treat unknown cases as unknown.
6. Measure skilled-player and bad-network false positives explicitly.
7. Keep private device collection out of scope unless separately justified.
8. Version and roll back every detector and policy.
9. Provide reason categories and appeals.
10. Test defenses with isolated controlled bots, never unsuspecting players.

## Response ladder

- Reject or correct invalid state
- Increase disclosed evidence collection within existing policy
- Raise review priority
- Apply temporary containment when justified
- Human or reproducible-evidence review
- Temporary enforcement with reason category
- Permanent enforcement only at the approved evidence threshold
- Appeal evaluated under the policy and detector version used originally

## Anti-goals

- Secretly placing bots into public matches to fight suspects
- Permanent bans from one opaque score
- Guilt from high skill alone
- Unlimited client scanning
- Hardware identity as sole proof
- Security through client secrecy alone
- Publishing bypass techniques

## Required prototype evidence

- Honest baseline at zero, moderate, and poor network conditions
- Ground-truth attacker simulations
- Deterministic replay of every flagged event
- False-positive result for each validator
- Server correction behavior
- Policy-version and rollback test
- Data inventory and retention record
