#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--uat] [--signed]"
}
if (($# > 2)); then
  usage >&2
  exit 2
fi
case "$MODE" in
  -h|--help) usage; exit 0 ;;
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--uat|uat) ;;
  *) usage >&2; exit 2 ;;
esac
APP_NAME="Latest Dev"
PROJECT="Latest.xcodeproj"
SCHEME="Latest"
CONFIGURATION="Debug"
BUNDLE_ID="com.max-langer.Latest.dev"
SIGNING_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="")
if [[ "${2:-}" == "--signed" ]]; then
  SIGNING_ARGS=(CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY="Apple Development")
elif [[ -n "${2:-}" ]]; then
  echo "error: second argument must be --signed" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
RESULT_BUNDLE="$BUILD_DIR/Latest.xcresult"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

rm -rf "$RESULT_BUNDLE"

xcodebuild \
  -project "$ROOT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  "${SIGNING_ARGS[@]}" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  --uat|uat)
    # UAT must exercise the same discovery and update-checking services as the
    # shipping app. Deterministic fixtures remain test-only.
    open_app
    sleep 4
    pgrep -x "$APP_NAME" >/dev/null
    ;;
esac
