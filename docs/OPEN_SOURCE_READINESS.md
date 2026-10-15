# Open-source readiness

## Direction

Fair Play FPS is intended to remain publicly auditable and open source. The
repository stays private during the licensing transition so proprietary terms
are not confused with an open-source grant and no private or third-party
material is published accidentally.

Public visibility is a release operation, not a substitute for a license.

## Current audit

The tracked tree and complete four-commit history were inspected before this
document was added:

- 15 tracked files, all authored project text or Python source
- no tracked credential filenames or recognized credential patterns
- no binary tracked files
- no tracked blob larger than 8,405 bytes
- no art, audio, compiled game content, captures, or third-party source
- no material copied from installed games

The repository is technically small enough to audit, but public release remains
blocked by `LICENSE.txt`, which explicitly grants no open-source rights.

Run the repeatable working-tree gate with:

    python3 scripts/audit_public_release.py

It must fail while the proprietary notice remains. After a license decision,
it must pass before repository visibility changes.

## Required license decision

Recommended boundary:

- Engine, server, client, tools, and tests: **AGPL-3.0-only**
- Original documentation and distributable source assets: **CC BY-SA 4.0**
- Project name, logos, and release branding: reserved trademarks, not licensed
- Third-party dependencies: retained under their own compatible licenses

AGPL keeps modified network servers auditable, which best matches the native
fair-play goal. The tradeoff is stricter integration and distribution
compatibility. GPL-3.0-only is a less network-specific alternative. Apache-2.0
is the permissive alternative when broad proprietary reuse matters more than
requiring downstream source availability.

Joan Pujols must select the license boundary before the current proprietary
notice is replaced. No contributor agreement is needed for the current
single-owner history, but contribution terms are required before accepting
outside code.

## Public release gate

1. Select and commit code, documentation, asset, and trademark terms.
2. Add contribution and security-reporting policies before outside changes.
3. Run repository, unit, syntax, and public-release checks.
4. Review every tracked file and historical blob again.
5. Change visibility without transferring ownership or adding collaborators.
6. Verify anonymous read access and preserve the independent private backup.
