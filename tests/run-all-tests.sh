#!/usr/bin/env bash
# ==============================================================================
# tests/run-all-tests.sh - Master entrypoint for running test suite
# ==============================================================================
set -euo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$TESTS_DIR/run-tests.sh" "$@"
