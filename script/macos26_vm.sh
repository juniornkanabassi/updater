#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TART_HOME="${LATEST_VM_HOME:-$ROOT_DIR/build/macos26-vm/state}"
export TART_NO_AUTO_PRUNE=1
VM_NAME=latest-macos26
VM_IMAGE="${LATEST_VM_IMAGE:-ghcr.io/cirruslabs/macos-tahoe-xcode:26.5}"
TART="${TART_BINARY:-$(command -v tart || true)}"
if [[ -z "$TART" ]]; then
  TART="$ROOT_DIR/build/macos26-vm/tools/tart.app/Contents/MacOS/tart"
fi
if [[ ! -x "$TART" ]]; then
  echo "Install Tart with: brew install cirruslabs/cli/tart" >&2
  exit 1
fi

case "${1:---help}" in
  setup)
    echo "Downloading $VM_IMAGE (about 70 GB compressed with Xcode)."
    "$TART" clone "$VM_IMAGE" "$VM_NAME"
    "$TART" set "$VM_NAME" --cpu 4 --memory 8192 --display 1440x900px --no-display-refit
    ;;
  run)
    mkdir -p "$ROOT_DIR/build/macos26-vm/shared"
    exec "$TART" run "$VM_NAME" --no-audio --no-clipboard \
      --dir="latest:$ROOT_DIR:ro" \
      --dir="artifacts:$ROOT_DIR/build/macos26-vm/shared"
    ;;
  status) exec "$TART" list ;;
  exec)
    shift
    exec "$TART" exec "$VM_NAME" "$@"
    ;;
  --help)
    echo "Usage: $0 setup|run|status|exec COMMAND [ARGUMENTS...]"
    echo "Uses an isolated macOS 26 VM under build/macos26-vm."
    echo "LATEST_VM_IMAGE overrides the image; the public default has Xcode 26.5."
    ;;
  *) echo "Unknown command: $1" >&2; exit 2 ;;
esac
