#!/usr/bin/env bash
# Normal council gate: all correctness lanes, every light/dark surface, and the layout grid.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UPDATER_BUILD_DIR="${UPDATER_BUILD_DIR:-$ROOT_DIR/build}"
export UPDATER_SNAPSHOT_DIR="${UPDATER_SNAPSHOT_DIR:-$UPDATER_BUILD_DIR/snapshots}"
mkdir -p "$UPDATER_SNAPSHOT_DIR"
find "$UPDATER_SNAPSHOT_DIR" -maxdepth 1 -type f \( -name '*.png' -o -name 'menu-bar.txt' \) -delete
"$ROOT_DIR/script/test.sh" --all
/usr/bin/python3 "$ROOT_DIR/script/check_snapshots.py" "$UPDATER_SNAPSHOT_DIR"
