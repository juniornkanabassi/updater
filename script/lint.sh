#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  ""|--analyze) [[ "$#" -le 1 ]] || { echo "Usage: $0 [--analyze]" >&2; exit 2; } ;;
  --help) echo "Usage: $0 [--analyze]"; exit 0 ;;
  *) echo "Usage: $0 [--analyze]" >&2; exit 2 ;;
esac

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
SWIFTLINT_VERSION=0.65.1
SWIFTLINT_SHA256=c1e429b0599cf1b516f369a2d9ec04eaf0e436f3c12b637df8851fa52ff694d0
TOOL_DIR="$ROOT_DIR/build/tools/swiftlint-$SWIFTLINT_VERSION"
LINTER="$TOOL_DIR/swiftlint"

if [[ ! -x "$LINTER" ]]; then
  mkdir -p "$ROOT_DIR/build/tools"
  download="$(mktemp -d "$ROOT_DIR/build/tools/swiftlint-download.XXXXXX")"
  trap 'rm -rf "$download"' EXIT
  curl --fail --location --silent --show-error --retry 3 \
    "https://github.com/realm/SwiftLint/releases/download/$SWIFTLINT_VERSION/portable_swiftlint.zip" \
    --output "$download/portable_swiftlint.zip"
  printf '%s  %s\n' "$SWIFTLINT_SHA256" "$download/portable_swiftlint.zip" | shasum -a 256 --check
  mkdir -p "$TOOL_DIR"
  unzip -q -o "$download/portable_swiftlint.zip" -d "$TOOL_DIR"
fi

if [[ "$("$LINTER" version)" != "$SWIFTLINT_VERSION" ]]; then
  echo "Expected SwiftLint $SWIFTLINT_VERSION in $TOOL_DIR." >&2
  exit 1
fi

if [[ "${1:-}" != --analyze ]]; then
  "$LINTER" lint --config "$ROOT_DIR/.swiftlint.yml" --strict --no-cache \
    2>&1 | tee "$ROOT_DIR/build/lint.log"
  exit 0
fi

# Analyzer rules require a fresh compiler log. Keep their clean isolated from
# normal build products and compile opt-in audit callers without executing them.
BUILD_LOG="$ROOT_DIR/build/lint-build.log"
ANALYSIS_LOG="$ROOT_DIR/build/lint-analysis.log"
command -v rg >/dev/null || { echo "Declaration analysis requires ripgrep." >&2; exit 1; }
echo "Building for declaration analysis; log: $BUILD_LOG"
: > "$BUILD_LOG"
# Compile both modules so declaration analysis sees the callers moved out of
# the app-hosted bundle. Separate products keep the second graph from pruning
# frameworks needed by SourceKit when it analyzes the first graph.
for scheme in Latest 'Latest Unit Tests'; do
  derived_data="$ROOT_DIR/build/LintDerivedData"
  if [[ "$scheme" == 'Latest Unit Tests' ]]; then
    derived_data="$ROOT_DIR/build/LintUnitDerivedData"
  fi
  if ! xcodebuild -project Latest.xcodeproj -scheme "$scheme" -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$derived_data" \
    -clonedSourcePackagesDirPath "$ROOT_DIR/build/DerivedData/SourcePackages" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
    CLANG_MODULE_CACHE_PATH="$ROOT_DIR/build/LintModuleCache" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' \
    OTHER_SWIFT_FLAGS='$(inherited) -DLATEST_RELEASE_NOTES_AUDIT' \
    clean build-for-testing >> "$BUILD_LOG" 2>&1; then
    tail -n 60 "$BUILD_LOG" >&2
    exit 1
  fi
done
"$LINTER" analyze --config "$ROOT_DIR/.swiftlint.yml" \
  --compiler-log-path "$BUILD_LOG" 2>&1 | tee "$ANALYSIS_LOG"
# Some SourceKit failures leave the analyzer's exit status at zero. Findings
# remain advisory, but a broken analysis must be reported as a failed check.
if rg -n '(^|[[:space:]])error:|sourcekitd.*(failed|error)' "$ANALYSIS_LOG"; then
  echo "Declaration analysis failed; see $ANALYSIS_LOG." >&2
  exit 1
fi
