#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-$ROOT_DIR/build/DerivedData/Build/Products/Release/Latest Dev.app}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

if [[ ! -d "$APP_PATH" || ! -f "$INFO_PLIST" ]]; then
  echo "error: release application not found at $APP_PATH" >&2
  exit 2
fi

EXECUTABLE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
if [[ ! -x "$EXECUTABLE_PATH" ]]; then
  echo "error: release executable not found at $EXECUTABLE_PATH" >&2
  exit 2
fi

failed=0
pass() {
  echo "RELEASE ARTIFACT PASS $1"
}
fail() {
  echo "RELEASE ARTIFACT FAIL $1" >&2
  failed=1
}

binary_bytes="$(stat -f '%z' "$EXECUTABLE_PATH")"
bundle_kib="$(du -sk "$APP_PATH" | awk '{print $1}')"
echo "RELEASE ARTIFACT SIZE binary_bytes=$binary_bytes bundle_kib=$bundle_kib"

if /usr/libexec/PlistBuddy -c 'Print :NSAppTransportSecurity:NSAllowsArbitraryLoads' "$INFO_PLIST" >/dev/null 2>&1; then
  fail "NSAllowsArbitraryLoads must not ship"
else
  pass "App Transport Security has no arbitrary-load override"
fi

if rg -q '___llvm_profile|__llvm_profile' < <(strings "$EXECUTABLE_PATH"); then
  fail "LLVM coverage instrumentation is present in the Release executable"
else
  pass "Release executable has no LLVM coverage instrumentation"
fi

if rg -q 'AppearanceFixture' < <(strings "$EXECUTABLE_PATH"); then
  fail "test-only AppearanceFixture is present in the Release executable"
else
  pass "test-only AppearanceFixture is absent from the Release executable"
fi

if rg -q 'LATEST_LOCAL_UAT_FIXTURE|Latest-UAT-' < <(strings "$EXECUTABLE_PATH"); then
	fail "debug-only local UAT fixture is present in the Release executable"
else
	pass "debug-only local UAT fixture is absent from the Release executable"
fi

allowed_bridges=(
	"Latest/Platform/AppKit/SidebarScrollConfiguration.swift"
	"Latest/Platform/AppKit/WindowAccessor.swift"
)

bridge_files=()
while IFS= read -r bridge_file; do
  bridge_files+=("${bridge_file#"$ROOT_DIR/"}")
done < <(rg -l 'NS(View|ViewController)Representable' "$ROOT_DIR/Latest" \
  --glob '*.swift' \
  --glob '!**/AppearanceFixtures.swift' \
  | sort)

unexpected_bridge_count=0
unexpected_bridge_list=""
for bridge_file in "${bridge_files[@]}"; do
  allowed=false
  for allowed_bridge in "${allowed_bridges[@]}"; do
    if [[ "$bridge_file" == "$allowed_bridge" ]]; then
      allowed=true
      break
    fi
  done
  if [[ "$allowed" == false ]]; then
    unexpected_bridge_count=$((unexpected_bridge_count + 1))
    unexpected_bridge_list="${unexpected_bridge_list}${unexpected_bridge_list:+, }$bridge_file"
  fi
done

if ((unexpected_bridge_count)); then
  fail "unexpected AppKit bridges: $unexpected_bridge_list"
else
  pass "production AppKit bridges are limited to ${#bridge_files[@]} reviewed capability boundaries"
fi

glass_bridge_files=()
while IFS= read -r glass_bridge_file; do
	glass_bridge_files+=("${glass_bridge_file#"$ROOT_DIR/"}")
done < <(rg -l 'NSGlassEffectView' "$ROOT_DIR/Latest" --glob '*.swift' | sort)

if ((${#glass_bridge_files[@]} == 0)); then
	pass "no Liquid Glass view bridge is present"
else
	fail "unexpected Liquid Glass view coupling: ${glass_bridge_files[*]}"
fi

if rg -q '_CFBundleFlushBundleCaches' < <(strings "$EXECUTABLE_PATH"); then
	fail "removed private bundle-cache hook remains in the Release executable"
else
	pass "removed private bundle-cache hook is absent"
fi

private_framework_files=()
while IFS= read -r private_framework_file; do
	private_framework_files+=("${private_framework_file#"$ROOT_DIR/"}")
done < <(rg -l '^import (CommerceKit|StoreFoundation)$' "$ROOT_DIR/Latest" --glob '*.swift' | sort)
if ((${#private_framework_files[@]} == 1)) && [[ "${private_framework_files[0]}" == "Latest/Platform/AppStore/AppStoreUpdateOperation.swift" ]]; then
	pass "private App Store updater frameworks remain isolated to one capability boundary"
else
	fail "private App Store updater framework imports escaped their reviewed boundary"
fi

exit "$failed"
