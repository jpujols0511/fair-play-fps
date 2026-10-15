# Devin Local handoff

This repository is dependency-free today. A local session needs Python 3.10 or
newer and a clean checkout of this repository. It does not need access to VEYR,
Data Haunt, Pocket Boo, Veridian, game installs, credentials, or private assets.

## Start the session

1. Open this repository as the only workspace in Devin Desktop.
2. Select **Devin Local** in the agent selector.
3. Prefer a **new worktree** so local changes cannot alter the main checkout.
4. Use Normal permissions for the first run. Do not use Bypass mode.
5. Give the local session this prompt:

       Read AGENTS.md, docs/PROJECT_CONTEXT.md, docs/STATUS.md, and
       docs/ROADMAP.md. Work only in fair-play-fps. Run
       `python3 scripts/local_verify.py` and report the exact result. Do not
       install dependencies, inspect other repositories, change visibility,
       push, or commit. If verification passes, review the Python authority
       contracts and identify one bounded M1 risk without editing files.

The session should ask before shell commands in Normal mode. Approve only the
repository-local Python verification command.

## Expected command

    python3 scripts/local_verify.py

It checks repository structure, runs the authoritative simulation unit tests,
and executes the honest and controlled-attacker scenarios. Any nonzero child
command stops the verification and returns failure.

## Troubleshooting

If Devin Local is absent, open the command palette, choose **Devin User
Settings**, enable **Devin Local** under **Agents**, and restart Devin Desktop.
Restricted Mode must be disabled for agents to run. These steps follow the
[official Devin Local documentation](https://docs.devin.ai/desktop/devin-local).
