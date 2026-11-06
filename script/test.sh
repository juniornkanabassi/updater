#!/usr/bin/env bash
set -euo pipefail

MODE=unit
COVERAGE=NO
FILTERS=()
ONLY_TARGETS=()
for argument in "$@"; do
  case "$argument" in
    --integration) MODE=integration ;;
    --ui) MODE=ui ;;
    --all) MODE=all ;;
    --coverage) COVERAGE=YES ;;
    -only-testing:*|-skip-testing:*)
      target="${argument#*:}"
      target="${target%%/*}"
      case "$target" in
        'Latest Unit Tests'|'Latest Tests') ;;
        *) echo "Unknown test target: $target" >&2; exit 2 ;;
      esac
      FILTERS+=("$argument")
      [[ "$argument" != -only-testing:* ]] || ONLY_TARGETS+=("$target") ;;
    --help)
      echo "Usage: $0 [--integration|--ui|--all] [--coverage] [-only-testing:target/class/method]"
      echo "Default: unhosted unit tests. --integration: background app-hosted checks."
      echo "--ui: invisible app-hosted window/input checks. --all: all three, sequentially."
      exit 0 ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done

if [[ "$MODE" != all ]]; then
  expected_target='Latest Tests'
  [[ "$MODE" != unit ]] || expected_target='Latest Unit Tests'
  for filter in ${FILTERS[@]+"${FILTERS[@]}"}; do
    target="${filter#*:}"
    target="${target%%/*}"
    if [[ "$target" != "$expected_target" ]]; then
      echo "Target '$target' is outside the $MODE lane; choose --integration, --ui, or --all as appropriate." >&2
      exit 2
    fi
  done
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${UPDATER_BUILD_DIR:-$ROOT_DIR/build}" # override to keep build products out of iCloud-synced folders
DERIVED_DATA="$BUILD_DIR/DerivedData"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
export TEST_RUNNER_UPDATER_BUILD_DIR="$BUILD_DIR"
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$BUILD_DIR" "$MODULE_CACHE"

# cfprefsd can recreate empty plists as the test process exits. Remove only the
# UUID suites this invocation records, after every test writer has stopped.
DEFAULTS_MANIFEST="$(mktemp "$BUILD_DIR/test-defaults.XXXXXX")"
export UPDATER_TEST_DEFAULTS_MANIFEST="$DEFAULTS_MANIFEST"
export TEST_RUNNER_UPDATER_TEST_DEFAULTS_MANIFEST="$DEFAULTS_MANIFEST"
cleanup_test_defaults() {
  local result=$?
  /usr/bin/python3 - "$DEFAULTS_MANIFEST" <<'PY_CLEANUP' || result=1
from pathlib import Path
import subprocess
import sys
import uuid

manifest = Path(sys.argv[1])
for name in set(manifest.read_text().splitlines()):
    uuid.UUID(name.rsplit(".", 1)[-1])
    if "/" in name:
        raise ValueError("Invalid test defaults domain")
    subprocess.run(["/usr/bin/defaults", "delete", name], capture_output=True)
    (Path.home() / "Library/Preferences" / (name + ".plist")).unlink(missing_ok=True)
manifest.unlink()
PY_CLEANUP
  exit "$result"
}
trap cleanup_test_defaults EXIT

/usr/bin/python3 -m unittest discover -s "$ROOT_DIR/script/tests"
"$ROOT_DIR/script/check_structure.sh"
# The main list keeps its measured geometry; grid-check the migrated Settings views only.
"$ROOT_DIR/script/grid-lint.sh" "$ROOT_DIR/Latest/Features/Settings"

run_lane() {
  local lane="$1" scheme='Updater' target='Latest Tests'
  local arguments=() filter selected_target has_selection=false
  export TEST_RUNNER_LATEST_UI_TESTS=0
  export LATEST_UI_TESTS=0
  if [[ "$lane" == unit ]]; then
    scheme='Latest Unit Tests'
    target='Latest Unit Tests'
  else
    arguments+=(-testPlan LatestIntegration)
    if [[ "$lane" == ui ]]; then
      # Plan names use the acronym rather than title case.
      arguments=(-testPlan LatestUI)
      export TEST_RUNNER_LATEST_UI_TESTS=1
      export LATEST_UI_TESTS=1
    fi
  fi
  for selected_target in ${ONLY_TARGETS[@]+"${ONLY_TARGETS[@]}"}; do
    [[ "$selected_target" != "$target" ]] || has_selection=true
  done
  if [[ "${#ONLY_TARGETS[@]}" != 0 && "$has_selection" == false ]]; then
    return
  fi
  for filter in ${FILTERS[@]+"${FILTERS[@]}"}; do
    selected_target="${filter#*:}"
    selected_target="${selected_target%%/*}"
    [[ "$selected_target" != "$target" ]] || arguments+=("$filter")
  done
  echo "Running $lane tests (coverage=$COVERAGE)"

  xcodebuild \
    -project "$ROOT_DIR/Latest.xcodeproj" \
    -scheme "$scheme" \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$BUILD_DIR/Latest-Tests-$lane-$RUN_ID.xcresult" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    -enableCodeCoverage "$COVERAGE" \
    -parallel-testing-enabled NO \
    -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 60 \
    -maximum-test-execution-time-allowance 120 \
    ${arguments[@]+"${arguments[@]}"} \
    test
}

if [[ "$MODE" == all ]]; then
  run_lane unit
  run_lane integration
  run_lane ui
else
  run_lane "$MODE"
fi
