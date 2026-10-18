#!/usr/bin/env bash
# Wrapper di compatibilità alla radice del repository
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec "$SCRIPT_DIR/bin/fix_ps5_boot.sh" "$@"
