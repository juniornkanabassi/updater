#!/usr/bin/env bash
set -euo pipefail

export TEST_RUNNER_LATEST_UI_TESTS=1

LABEL="${1:-current}"
if (($# > 1)) || [[ ! "$LABEL" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Benchmark label must contain only letters, numbers, underscores, or hyphens." >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
RESULT_BUNDLE="$BUILD_DIR/Latest-App-Benchmark-$LABEL-$(date +%Y%m%d-%H%M%S).xcresult"
LOG_FILE="$BUILD_DIR/app-benchmark-$LABEL.log"
REPORT_FILE="$BUILD_DIR/app-benchmark-$LABEL.txt"
FLAG_FILE="$BUILD_DIR/run-app-benchmarks"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"
rm -f "$LOG_FILE" "$REPORT_FILE"
touch "$FLAG_FILE"
trap 'rm -f "$FLAG_FILE"' EXIT

xcodebuild \
  -project "$ROOT_DIR/Latest.xcodeproj" \
  -scheme Latest \
  -testPlan LatestAppBenchmarks \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  -enableCodeCoverage NO \
  ENABLE_TESTABILITY=YES \
  -only-testing:'Latest Tests/AppPerformanceTest' \
  test 2>&1 | tee "$LOG_FILE"

rg '^APP_(CONFIGURATION|BENCHMARK|MEMORY|HEAP)' "$LOG_FILE" > "$REPORT_FILE"

echo
echo "App benchmark summary ($LABEL):"
cat "$REPORT_FILE"

/usr/bin/python3 "$ROOT_DIR/script/check_benchmarks.py" app "$REPORT_FILE" "$LOG_FILE"
