#!/usr/bin/env bash
# Canonical project generation. XcodeGen (2.46) has no optional includes, so a missing
# per-machine signing.local.yml is stubbed with an empty spec that merges nothing.
# Real device signing: cp signing.local.yml.example signing.local.yml, fill in the team id.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f signing.local.yml ] || printf '{}\n' > signing.local.yml
exec xcodegen generate "$@"
