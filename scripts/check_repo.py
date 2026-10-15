#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = [
    'AGENTS.md',
    'README.md',
    'LICENSE.txt',
    'docs/PROJECT_CONTEXT.md',
    'docs/ROADMAP.md',
    'docs/STATUS.md',
    'docs/THREAT_MODEL.md',
    'docs/FAIR_PLAY_ENGINE_ARCHITECTURE.md',
    'docs/LINEAGE_MATRIX.md',
    'docs/DEVIN_LOCAL_HANDOFF.md',
    'docs/OPEN_SOURCE_READINESS.md',
    'prototype/README.md',
    'prototype/fairplay_sim.py',
    'scripts/audit_public_release.py',
    'scripts/local_verify.py',
    'tests/test_fairplay_sim.py',
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

if errors:
    for error in errors:
        print(f'FAIL {error}')
    sys.exit(1)

print(f'PASS repository structure ({len(REQUIRED)} required files)')
