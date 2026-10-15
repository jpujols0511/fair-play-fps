# Headless authoritative arena prototype

This directory contains the first executable reference for Fair Play FPS. It is
not a playable game, renderer, network service, production engine, or anti-cheat
product.

The prototype proves five contracts with no external dependencies:

1. Clients submit bounded intent, never position, damage, ammunition, or score.
2. The server advances movement at an explicit 64 or 128 tick profile.
3. The server rejects fire-cadence and ammunition violations.
4. Every correction and shot becomes deterministic evidence.
5. Replaying the same command stream produces the same final state and evidence.

Run:

    python3 -m unittest discover -s tests -v
    python3 scripts/run_prototype.py

The controlled attacker is a test fixture. It does not contain a real-game cheat
or interact with another process.

The runner executes one simulated second at both supported rates. The honest
straight-line fixture preserves final position, ammunition, and accepted-shot
categories across both profiles. The controlled attacker remains intentionally
hostile input; its quantized diagonal path is evidence to compare, not a claim
that every discrete trajectory is identical across rates.
