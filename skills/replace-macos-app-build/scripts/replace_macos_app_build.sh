#!/usr/bin/env bash
set -euo pipefail

PROJECT=""
SCHEME=""
CONFIGURATION="Release"
DERIVED_DATA="build/DerivedData"
APP_NAME=""
INSTALL_NAME=""
BUNDLE_ID=""
CODE_SIGNING_ALLOWED_VALUE="NO"
KEEP_BUILD=0
RESTART_DOCK=0
OPEN_APP=0
DRY_RUN=0
ARTIFACT_NAMES=()
INVENTORY_OPTIONS=()
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat <<'USAGE'
Usage:
  replace_macos_app_build.sh --project App.xcodeproj --scheme Scheme --app-name "App Dev" [options]

Options:
  --project PATH          Xcode project to build.
  --scheme NAME           Xcode scheme to build.
  --configuration NAME    Build configuration. Default: Release.
  --derived-data PATH     DerivedData output. Default: build/DerivedData.
  --app-name NAME         Built app product name without .app.
  --install-name NAME     Installed app name in /Applications. Defaults to --app-name.
  --bundle-id ID          Expected bundle id. If omitted, read from built Info.plist.
  --artifact-name NAME    Extra app name to discover (never authorizes deletion). Repeatable.
  --cleanup-bundle-id ID  Explicitly allow cleanup of a preview/test app identity. Repeatable.
  --cleanup-root PATH     Also clean inside a Git worktree's build/ output. Repeatable.
  --preserve-app PATH     Explicitly retain a baseline or app used by another task. Repeatable.
  --code-signing VALUE    CODE_SIGNING_ALLOWED value. Default: NO.
  --clean-artifacts       Compatibility flag; duplicate cleanup is now the default.
  --keep-build            Explicitly retain the fresh build for debugging.
  --restart-dock          Restart Dock after registration.
  --open                  Open the installed app after replacement.
  --dry-run               Inventory filesystem, LaunchServices and Spotlight; print a nonmutating plan.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --scheme) SCHEME="$2"; shift 2 ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --derived-data) DERIVED_DATA="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --install-name) INSTALL_NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --artifact-name) ARTIFACT_NAMES+=("$2"); shift 2 ;;
    --cleanup-bundle-id|--cleanup-root|--preserve-app) INVENTORY_OPTIONS+=("$1" "$2"); shift 2 ;;
    --code-signing) CODE_SIGNING_ALLOWED_VALUE="$2"; shift 2 ;;
    --clean-artifacts) shift ;;
    --keep-build) KEEP_BUILD=1; shift ;;
    --restart-dock) RESTART_DOCK=1; shift ;;
    --open) OPEN_APP=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$PROJECT" || -z "$SCHEME" || -z "$APP_NAME" ]]; then
  usage >&2
  exit 2
fi

if [[ -z "$INSTALL_NAME" ]]; then
  INSTALL_NAME="$APP_NAME"
fi

ARTIFACT_NAMES+=("$APP_NAME")
if [[ "$INSTALL_NAME" != "$APP_NAME" ]]; then
  ARTIFACT_NAMES+=("$INSTALL_NAME")
fi

PROJECT_ROOT="$(pwd -P)"
for name in "$CONFIGURATION" "$APP_NAME" "$INSTALL_NAME" "${ARTIFACT_NAMES[@]}"; do
  if [[ -z "$name" || "$name" == */* || "$name" == . || "$name" == .. ]]; then
    echo "Expected a plain app product name, not a path: $name" >&2
    exit 2
  fi
done
# Limit both the source and cleanup to build-output trees, never source folders.
DERIVED_DATA="$(/usr/bin/python3 - "$PROJECT_ROOT" "$DERIVED_DATA" <<'PYTHON'
from pathlib import Path
import sys
root, supplied = sys.argv[1:]
path = Path(supplied).resolve()
allowed = [Path(root) / 'build', Path.home() / 'Library/Developer/Xcode/DerivedData']
if not any(path == base or base in path.parents for base in allowed):
    sys.exit('DerivedData must be inside this repository/build or Xcode DerivedData.')
print(path)
PYTHON
)"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALLED_APP="/Applications/$INSTALL_NAME.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -L "$INSTALLED_APP" ]]; then
  echo "Refusing to replace a symlink at $INSTALLED_APP" >&2
  exit 1
fi
inventory() {
  local arguments=(inventory --project-root "$PROJECT_ROOT" --installed-app "$INSTALLED_APP" --built-app "$BUILT_APP" --bundle-id "$BUNDLE_ID")
  local name
  for name in "${ARTIFACT_NAMES[@]}"; do arguments+=(--artifact-name "$name"); done
  [[ "$KEEP_BUILD" -eq 0 ]] || arguments+=(--keep-build)
  # Bash 3.2 with nounset rejects expansion of an empty array.
  if [[ ${#INVENTORY_OPTIONS[@]} -gt 0 ]]; then arguments+=("${INVENTORY_OPTIONS[@]}"); fi
  /usr/bin/python3 "$SCRIPT_DIR/app_inventory.py" "${arguments[@]}" "$@"
}
if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ -z "$BUNDLE_ID" && -f "$INSTALLED_APP/Contents/Info.plist" ]]; then
    BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist")"
  fi
  echo "Plan: build $PROJECT / $SCHEME ($CONFIGURATION) at $BUILT_APP"
  echo "Plan: verify identity, stop the matching app, copy to $INSTALLED_APP, and verify all copied content"
  inventory
  echo "Plan: cleanup requires exact allowed identifiers and output roots; keep fresh build=$KEEP_BUILD; open=$OPEN_APP"
  exit 0
fi

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild build \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CLANG_ENABLE_CODE_COVERAGE=NO \
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED_VALUE"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$BUILT_APP/Contents/Info.plist")"
if [[ -n "$BUNDLE_ID" && "$ACTUAL_BUNDLE_ID" != "$BUNDLE_ID" ]]; then
  echo "Built bundle identifier does not match --bundle-id" >&2
  exit 1
fi
BUNDLE_ID="$ACTUAL_BUNDLE_ID"
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "Invalid bundle identifier" >&2
  exit 1
fi
if [[ -d "$INSTALLED_APP" ]]; then
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist")"
  if [[ "$installed_id" != "$BUNDLE_ID" ]]; then
    echo "Refusing to overwrite a different app at $INSTALLED_APP" >&2
    exit 1
  fi
fi

MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"

echo "Built app: $BUILT_APP"
echo "Install target: $INSTALLED_APP"
echo "Bundle id: $BUNDLE_ID"
echo "Version: $MARKETING_VERSION ($BUILD_VERSION)"

# Fail discovery before touching the installed copy; a failed query is not an empty inventory.
inventory

echo "Stopping the matching running app..."
osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit"
for attempt in {1..20}; do
  running="$(osascript -e "application id \"$BUNDLE_ID\" is running")"
  [[ "$running" == false ]] && break
  sleep 0.2
done
if [[ "$running" != false ]]; then
  echo "App did not quit; leaving installed and built bundles intact." >&2
  exit 1
fi

echo "Replacing installed app..."
rsync -a --delete "$BUILT_APP/" "$INSTALLED_APP/"
# Verify the complete bundle, including Debug implementation dylibs, before
# deleting the source. A launcher-stub hash alone does not verify app code.
differences="$(rsync -a --delete --checksum --dry-run --itemize-changes "$BUILT_APP/" "$INSTALLED_APP/")"
if [[ -n "$differences" ]]; then
  echo "Installed bundle differs from the build; preserving source for recovery." >&2
  printf '%s\n' "$differences" >&2
  exit 1
fi

echo "Cleaning authorized duplicate app products, including the fresh build..."
inventory --remove

echo "Registering the installed app and refreshing Spotlight..."
"$LSREGISTER" -f -R -trusted "$INSTALLED_APP"
mdimport "$INSTALLED_APP"

if [[ "$RESTART_DOCK" -eq 1 ]]; then
  echo "Restarting Dock..."
  killall Dock
fi

if [[ "$OPEN_APP" -eq 1 ]]; then
  echo "Opening installed app..."
  open -a "$INSTALLED_APP"
fi

echo "Verifying installed identity, LaunchServices and running path..."
VERIFY_ARGUMENTS=(verify-launch --installed-app "$INSTALLED_APP" --bundle-id "$BUNDLE_ID" --version "$MARKETING_VERSION" --build "$BUILD_VERSION")
[[ "$OPEN_APP" -eq 0 ]] || VERIFY_ARGUMENTS+=(--require-running)
verified=0
for attempt in {1..5}; do
  if /usr/bin/python3 "$SCRIPT_DIR/app_inventory.py" "${VERIFY_ARGUMENTS[@]}"; then verified=1; break; fi
  sleep 1
done
[[ "$verified" -eq 1 ]] || exit 1

echo "Verifying remaining app products and Spotlight results..."
verified=0
for attempt in {1..3}; do
  if inventory --verify; then verified=1; break; fi
  sleep 1
done
[[ "$verified" -eq 1 ]] || exit 1
echo "Replacement verified: $INSTALLED_APP — $MARKETING_VERSION ($BUILD_VERSION)"
