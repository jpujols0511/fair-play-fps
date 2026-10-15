# Godot in Fair Play FPS

Godot is the open-source game engine that runs the Fair Play FPS client and
dedicated server. The project currently pins Godot 4.4.1. Godot supplies the
editor, scene system, renderer, input, audio, platform exports, and low-level
networking interfaces. It does not define the game's authority or fair-play
policy; this repository does.

## Engine and language

Godot is the engine. GDScript is the Python-like language used for the current
Godot implementation.

A running Godot project is a tree of nodes. Each node has one bounded job. The
current graybox uses nodes for procedural room geometry, lighting, the camera,
the status interface, and the client session. Scripts attach behavior to those
nodes through lifecycle functions such as `_ready()` and `_process()`.

This structure lets the same project run in two important modes:

- **Rendered client:** opens a window, reads player input, draws the arena, and
  presents server-confirmed state.
- **Headless server:** runs without a window, renderer, or player interface so
  Linux servers can simulate matches efficiently.

Headless does not mean simplified authority. The same match rules, evidence,
and deterministic state still apply; only visual presentation is absent.

## What Godot owns

Godot owns engine services:

- Scene and node lifecycle
- Rendering, cameras, materials, lights, and interface controls
- Keyboard and mouse input collection
- UDP, DTLS, and multiplayer transport primitives
- Process startup, command-line arguments, file access, and platform exports

These are mechanisms, not gameplay truth. A rendered client may collect an
input or show a predicted result, but neither action makes that result real.

## What the Fair Play kernel owns

The authoritative kernel owns gameplay truth:

- Accepted movement and facing
- Legal firing cadence and ammunition
- Visibility, hits, damage, health, and elimination as those rules land
- Inventory, objectives, economy, and match result as later milestones land
- Deterministic state, demo records, and evidence

Clients send intent. They do not send authoritative position, health, damage,
ammunition, score, target identity, hit results, or match outcomes. The server
authenticates a session, validates intent, advances the kernel, and sends
confirmed snapshots back to clients.

The current graybox makes that boundary visible: local input can change view
direction and submit movement intent, but the camera rig's world position is
assigned only from an authenticated server snapshot.

## Why the kernel avoids engine physics for authority

Godot includes a capable physics engine, and the graybox already uses collision
shapes for authored geometry. The production authority kernel nevertheless
uses explicit integer rules for authoritative movement and firing.

That choice gives the project:

- Reproducible 64 and 128 tick profiles
- Identical replay results across the Python and GDScript implementations
- Stable digests for verification
- Explainable evidence when the server rejects an impossible action
- A bounded surface for network prediction and reconciliation

Godot physics may support presentation and future collision experiments, but
it cannot silently become the source of authoritative outcomes. Any collision
rule must first become an explicit, replayable kernel contract.

## Netfox and networking

Netfox is a vendored Godot networking add-on. Its intended role is clock
synchronization and network timing support. It does not replace the Fair Play
kernel, decide hits, classify cheating, or issue punishment.

The current `main` branch proves two authenticated graybox clients against one
authoritative DTLS server over loopback at both 64 and 128 tick. Separate
branches are evaluating ENet transport, prediction and reconciliation, and
bounded lag compensation. Those branches remain proposals until their
authority contracts survive review and integration on top of the current
graybox.

## Python as an independent oracle

Python is not the production game engine. It is the dependency-free reference
model used to specify rules, replay demos, and compare deterministic digests.

Maintaining the same rule in Python and GDScript gives reviewers an independent
way to detect an engine regression. Godot remains authoritative at runtime;
Python verifies that the authority behaves as documented.

## Open-source relationship

Godot provides the workshop. Fair Play FPS provides an original game and its
authority model. The project should contribute generally useful bug reports,
tests, documentation, or fixes upstream when appropriate rather than carrying
an unnecessary private engine fork.

Godot's open-source license does not automatically license this game's code,
art, audio, branding, or third-party dependencies. Each component still needs
clear provenance and its own compatible terms before the repository becomes
public.

## Current evidence and limits

Verified on Linux x86_64 with the official Godot 4.4.1 stable build:

- The project parses and runs headless.
- Python and GDScript kernel digests match at 64 and 128 tick.
- Two authenticated clients exchange intent and server snapshots over DTLS.
- Each graybox client's reported world position equals its last confirmed
  server snapshot.
- Recorded demos replay to the server digest.

Not yet verified:

- Human visual play and control feel
- Cross-machine LAN behavior
- Authoritative collision, jump, crouch, health, respawn, and complete combat
- Remote-player rendering
- Integrated prediction, reconciliation, interpolation, and lag compensation
- Performance under real network impairment or production load

Those distinctions are deliberate. Authored, parsed, compiled, run,
network-tested, and human-playtested are different evidence levels.
