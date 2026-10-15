# Project context

## Product

Fair Play FPS is Joan Pujols' original competitive shooter and native fair-play
engine research project. The temporary name protects the unannounced identity.

## Experience goal

Create immediate control, readable spaces, learnable movement, high-impact
weapons, durable callouts, round tension, team knowledge, and outcomes a player
can understand and trust.

The project studies the history of classic competitive shooters, especially the
GoldSrc, Source, and Source 2 eras of Counter-Strike, without copying protected
material.

## Technical thesis

The game and fair-play system are one architecture:

- Fixed-tick authoritative simulation
- Predictive clients with reconciliation
- LAN as the engine baseline
- Regional dedicated online servers
- Deterministic evidence and compact replay
- Explainable invariant validators
- Adaptive research promoted only through reviewed versions
- Privacy, human review, reason categories, and appeals

## Engine strategy

The long-term direction is a Linux-first native simulation and game stack. The
first proof is not a general-purpose engine: it is a headless authoritative
arena with thin clients, one rifle, movement, replay, and evidence.

Battle-tested libraries may provide operating-system, graphics, input, audio,
network, compression, and cryptographic primitives. The project owns game rules
and authority rather than rebuilding every low-level dependency prematurely.

## Project separation

VEYR production patterns may inform repository discipline, evidence, asset
provenance, multiplayer validation, and native safety. VEYR code, assets,
survival scope, Unreal decisions, and private history do not transfer by default.

## Release direction

The project is intended to remain publicly auditable and open source. Code,
documentation, source assets, branding, and third-party dependencies need
explicit compatible terms before repository visibility changes.

## Current non-goals

- Public release before licensing and release gates pass
- Valve compatibility or replacement
- Kernel anti-cheat
- Hardware bans
- Marketplace or skins
- Ranked matchmaking
- Neural-network enforcement
- Full renderer or editor
- Production art
