#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

case "${1:-}" in
  ""|--check) ;;
  *) echo "Usage: $0 [--check]" >&2; exit 2 ;;
esac

# Restrict formatting to project-owned Swift files, excluding build outputs and dependencies.
files=()
while IFS= read -r -d '' file; do
  [[ -f "$file" ]] && files+=("$file")
done < <(git ls-files --cached --others --exclude-standard -z -- 'Latest/*.swift' 'Tests/*.swift' 'UpdateInstaller/*.swift' 'script/*.swift')

if [[ "${1:-}" != --check ]]; then
  xcrun swift-format format --configuration "$ROOT_DIR/.swift-format" --in-place --parallel "${files[@]}"
  exit 0
fi

# Compare formatter output instead of enforcing unrelated naming/refactoring lint rules.
formatted="$(mktemp "${TMPDIR:-/tmp}/latest-format.XXXXXX")"
trap 'rm -f "$formatted"' EXIT
status=0
for file in "${files[@]}"; do
  xcrun swift-format format --configuration "$ROOT_DIR/.swift-format" "$file" > "$formatted"
  if ! cmp -s "$file" "$formatted"; then
    echo "Needs formatting: $file" >&2
    status=1
  fi
done
if [[ "$status" == 0 ]]; then
  echo "Formatting check passed (${#files[@]} Swift files)."
fi
exit "$status"
