#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    'AGENTS.md',
    'README.md',
    'CLAUDE.md',
    'docs/DESIGN.md',
    'docs/decisions/0001-engine-and-netcode.md',
    'docs/decisions/0002-missing-input-and-jitter-buffer.md',
    'docs/decisions/0003-hits-and-lag-compensation.md',
    'LICENSE.txt',
    'docs/PROJECT_CONTEXT.md',
    'docs/ROADMAP.md',
    'docs/STATUS.md',
    'docs/THREAT_MODEL.md',
    'docs/FAIR_PLAY_ENGINE_ARCHITECTURE.md',
    'docs/LINEAGE_MATRIX.md',
    'prototype/README.md',
    'prototype/fairplay_sim.py',
    'tests/test_fairplay_sim.py',
    'tests/test_godot_spike.py',
    'godot/README.md',
    'godot/project.godot',
    'godot/kernel/fairplay_kernel.gd',
    'godot/net/protocol.gd',
    'godot/net/server.gd',
    'godot/net/client.gd',
    'godot/net/input_buffer.gd',
    'godot/net/enet_server.gd',
    'godot/net/enet_client.gd',
    'godot/net/prediction.gd',
    'godot/net/world_view.gd',
    'godot/tests/kernel_parity.gd',
    '.claude/settings.json',
    'godot/kernel/KERNEL_SHA256',
    'scripts/run_dedicated_server.py',
    'docs/COMMUNITY_SERVERS.md',
    'docs/THIRD_PARTY.md',
    'godot/tests/netfox_tick.gd',
    'godot/addons/netfox/LICENSE',
    'godot/addons/netfox/plugin.cfg',
    'detection/features.py',
    'detection/pipeline.py',
    'detection/bans.py',
    'detection/run.py',
    'detection/fixtures.py',
    'review/cases.py',
    'review/consensus.py',
    'tests/test_detection_review.py',
]
FORBIDDEN_FILES = {'.env', 'id_rsa', 'id_ed25519'}

errors = []
for relative in REQUIRED:
    path = ROOT / relative
    if not path.is_file() or not path.read_text(errors='replace').strip():
        errors.append(f'missing or empty required file: {relative}')

for path in ROOT.rglob('*'):
    if '.git' in path.parts or not path.is_file():
        continue
    if path.name in FORBIDDEN_FILES:
        errors.append(f'forbidden sensitive file: {path.relative_to(ROOT)}')

readme = (ROOT / 'README.md').read_text(errors='replace')
license_text = (ROOT / 'LICENSE.txt').read_text(errors='replace')
if 'Joan Pujols' not in readme or 'Joan Pujols' not in license_text:
    errors.append('ownership text must name Joan Pujols')

claude_md = (ROOT / 'CLAUDE.md').read_text(errors='replace')
if 'docs/DESIGN.md' not in claude_md:
    errors.append('CLAUDE.md must require reading docs/DESIGN.md on entry')
import json
try:
    hooks = json.loads((ROOT / '.claude/settings.json').read_text())['hooks']['SessionStart']
    commands = [h['command'] for group in hooks for h in group['hooks']]
    if not any('docs/DESIGN.md' in c for c in commands):
        errors.append('SessionStart hook must inject docs/DESIGN.md')
except (KeyError, ValueError, TypeError):
    errors.append('.claude/settings.json must define a SessionStart hook')

import hashlib
kernel = ROOT / 'godot/kernel/fairplay_kernel.gd'
published = (ROOT / 'godot/kernel/KERNEL_SHA256').read_text().split()
if not published or hashlib.sha256(kernel.read_bytes()).hexdigest() != published[0]:
    errors.append('godot/kernel changed without updating godot/kernel/KERNEL_SHA256')

if errors:
    for error in errors:
        print(f'FAIL {error}')
    sys.exit(1)

print(f'PASS repository structure ({len(REQUIRED)} required files)')
