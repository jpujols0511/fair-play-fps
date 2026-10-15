# Fair Play FPS project instructions

Read docs/PROJECT_CONTEXT.md, docs/STATUS.md, and the active milestone in
docs/ROADMAP.md before changing foundations.

## Working agreement

- Joan Pujols owns product direction, creative acceptance, and final release.
- Fair Play FPS is a private temporary project name for an original competitive
  first-person shooter.
- Do not use Valve or Counter-Strike code, maps, assets, names, logos, sounds,
  characters, or branding.
- Keep this project separate from VEYR, Data Haunt, Pocket Boo, and Veridian.
- Fair play is a native simulation contract, not a detachable plugin.
- The authoritative server owns movement, shots, visibility, damage, inventory,
  economy, objectives, and match result.
- Deliver one small playable and verified increment at a time.
- LAN and two-client multiplayer evidence come before content expansion.
- Treat authored, statically checked, compiled, run, network-tested, and
  playtested as different states.
- Use original assets and record provenance before integration.
- Never commit credentials, caches, generated captures, licensed game content,
  personal chat history, or unrelated project context.
- Safe native code by default. Any unsafe operation needs a bounded proposal,
  exact contract, tests, rollback, and Joan's explicit approval before merge.
- Machine learning may rank evidence in research or shadow mode; it may not
  autonomously issue irreversible punishment or rewrite production authority.
- Unknown behavior increases observation, not guilt.
- Keep docs/STATUS.md current with evidence, blockers, and next step.

## Verification

Run:

    python3 scripts/check_repo.py

Runtime claims require the platform, compiler, build, server topology, network
conditions, and test procedure to be recorded.
