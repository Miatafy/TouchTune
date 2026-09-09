#!/bin/sh
# Compatibility entry point; release.py owns the inventory and manifest format.
set -eu
REPO_DIR=$(CDPATH='' cd "$(dirname "$0")/.." && pwd)
case "${1:---check}" in
    --check) exec python3 "$REPO_DIR/tools/release.py" check-manifest ;;
    --write) exec python3 "$REPO_DIR/tools/release.py" write-manifest ;;
    *) echo "Usage: $0 [--check|--write]" >&2; exit 2 ;;
esac
