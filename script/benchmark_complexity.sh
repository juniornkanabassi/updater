#!/usr/bin/env bash
set -euo pipefail

PROJECT="Latest.xcodeproj"
SCHEME="Latest"
CONFIGURATION="Release"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
RESULT_BUNDLE="$BUILD_DIR/Latest-Complexity-Benchmark-$(date +%Y%m%d-%H%M%S).xcresult"
LOG_FILE="$BUILD_DIR/complexity-benchmark.log"
REPORT_FILE="$BUILD_DIR/complexity-benchmark.txt"
FLAG_FILE="$BUILD_DIR/run-complexity-benchmarks"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"

rm -f "$LOG_FILE" "$REPORT_FILE"
touch "$FLAG_FILE"
trap 'rm -f "$FLAG_FILE"' EXIT

xcodebuild \
  -project "$ROOT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  -testPlan LatestComplexityBenchmarks \
  -configuration "$CONFIGURATION" \
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
  -only-testing:"Latest Tests/ComplexityBenchmarkTest/testComplexityBenchmarks" \
  test 2>&1 | tee "$LOG_FILE"

grep "BENCHMARK" "$LOG_FILE" > "$REPORT_FILE"

echo
echo "Complexity benchmark summary:"
cat "$REPORT_FILE"

/usr/bin/python3 "$ROOT_DIR/script/check_benchmarks.py" complexity "$REPORT_FILE"
