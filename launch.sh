#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "launch.sh is kept for compatibility. Use ./script/build_and_run.sh for the standard macOS run loop." >&2
exec "$ROOT_DIR/script/build_and_run.sh" "${1:-run}"
