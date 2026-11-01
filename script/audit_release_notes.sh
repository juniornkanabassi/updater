#!/usr/bin/env bash
set -euo pipefail

PROJECT="Latest.xcodeproj"
SCHEME="Latest"
CONFIGURATION="Debug"

RUN_INSTALLED_AUDIT=false
HOMEBREW_CASK_CATALOG=""
LIVE_CASK_CATALOG=""

usage() {
  cat <<'EOF'
usage: script/audit_release_notes.sh [--installed] [--homebrew-cask PATH|-] [--catalog PATH]

Runs deterministic release-note fixture tests by default.
  --catalog PATH        Check every mapped source with current versions from a public cask JSON file.
  --installed           Also inspect locally installed applications and perform network-backed checks.
  --homebrew-cask PATH  Measure public cask coverage without inspecting installed applications.
EOF
}

while (($#)); do
  case "$1" in
    --installed)
      RUN_INSTALLED_AUDIT=true
      shift
      ;;
    --catalog)
      if (($# < 2)); then echo "error: --catalog requires a JSON path" >&2; exit 2; fi
      LIVE_CASK_CATALOG="$2"
      shift 2
      ;;
    --homebrew-cask)
      if (($# < 2)); then
        echo "error: --homebrew-cask requires a path or -" >&2
        usage >&2
        exit 2
      fi
      HOMEBREW_CASK_CATALOG="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
MODULE_CACHE="$BUILD_DIR/ModuleCache"
RESULT_BUNDLE="$BUILD_DIR/Latest-ReleaseNotes-Audit-$(date +%Y%m%d-%H%M%S).xcresult"
AUDIT_REPORT="$BUILD_DIR/release-notes-audit.txt"

mkdir -p "$BUILD_DIR" "$MODULE_CACHE"

echo "Offline release-note fixture audit:"
echo "- AppCleaner: multi-release HTML is trimmed to the current version"
echo "- BetterDisplay-style blanks: empty output is rejected"
echo "- Bruno/Rectangle/Obsidian: version-only and link-only stubs are rejected or followed"
echo "- Cursor: plain-text and compact Sparkle changelog line breaks are preserved"
echo "- IINA: duplicate leading version titles are collapsed"
echo "- Notion-style website chrome is rejected instead of rendered"
echo "- Thunder-style binary/mojibake payloads and downloadable URLs are rejected"
echo "- CodexBar: markdown headings and bullets still render cleanly"
if [[ "$RUN_INSTALLED_AUDIT" == true ]]; then
  echo "- Installed-app audit: every discoverable app is checked through Latest's update and release-note pipeline"
else
  echo "- Installed-app audit: skipped (pass --installed to opt in)"
fi

only_testing=(
  "Latest Tests/ReleaseNotesMarkupTest"
  "Latest Tests/ReleaseNotesCatalogTest"
  "Latest Tests/ReleaseNotesProviderTest"
  "Latest Tests/ReleaseNotesPipelineTest"
)

swift_flags=""
if [[ -n "$LIVE_CASK_CATALOG" ]]; then
  only_testing+=("Latest Tests/ReleaseNotesAuditTest/testCatalogReleaseNotesAudit")
  swift_flags="-DLATEST_RELEASE_NOTES_AUDIT"
  export TEST_RUNNER_LATEST_RELEASE_NOTES_CASK_CATALOG="$LIVE_CASK_CATALOG"
  export TEST_RUNNER_LATEST_RELEASE_NOTES_CATALOG_REPORT="$BUILD_DIR/release-notes-catalog-audit.json"
fi
if [[ "$RUN_INSTALLED_AUDIT" == true ]]; then
  only_testing+=("Latest Tests/ReleaseNotesAuditTest/testInstalledApplicationReleaseNotesAudit")
  swift_flags="-DLATEST_RELEASE_NOTES_AUDIT"
  export TEST_RUNNER_LATEST_RELEASE_NOTES_AUDIT_REPORT="$AUDIT_REPORT"
fi

xcode_args=(
  -project "$ROOT_DIR/$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
  -resultBundlePath "$RESULT_BUNDLE"
  CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
  OTHER_SWIFT_FLAGS="$swift_flags"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
  -enableCodeCoverage NO
)

for test_name in "${only_testing[@]}"; do
  xcode_args+=("-only-testing:$test_name")
done

xcodebuild "${xcode_args[@]}" test

if [[ "$RUN_INSTALLED_AUDIT" == true ]]; then
  echo
  echo "Installed-app release-note audit report:"
  cat "$AUDIT_REPORT"
fi

if [[ -n "$HOMEBREW_CASK_CATALOG" ]]; then
  echo
  echo "Public Homebrew cask release-note coverage:"
  "$ROOT_DIR/script/audit_release_note_coverage.sh" "$HOMEBREW_CASK_CATALOG"
fi
