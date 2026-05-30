#!/usr/bin/env bash
# scripts/run-tests.sh — fast-tier test runner wrapper.
#
# Looks for `bats` on PATH first, then falls back to the bats-core
# install at /tmp/bats-core/bin/bats. Use this from CI or local
# pre-commit checks so the entry-point stays stable across hosts.

set -euo pipefail

if command -v bats >/dev/null 2>&1; then
    exec bats tests/
elif [ -x /tmp/bats-core/bin/bats ]; then
    exec /tmp/bats-core/bin/bats tests/
else
    echo "bats not found. Install via your package manager (apt-get install bats)" >&2
    echo "or: git clone https://github.com/bats-core/bats-core /tmp/bats-core" >&2
    exit 127
fi
