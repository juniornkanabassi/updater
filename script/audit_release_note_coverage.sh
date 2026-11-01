#!/usr/bin/env bash
set -euo pipefail

if ! command -v jq >/dev/null 2>&1; then
	echo "error: jq is required" >&2
	exit 1
fi

CATALOG_PATH="${1:-}"
if [[ "$CATALOG_PATH" == "-" ]]; then
	CATALOG_PATH=/dev/stdin
elif [[ -z "$CATALOG_PATH" || ! -f "$CATALOG_PATH" ]]; then
	echo "usage: $0 /path/to/homebrew-cask.json|-" >&2
	echo "The input must be the public Homebrew cask API response; this script never scans installed apps." >&2
	exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_CATALOG="$ROOT_DIR/Latest/Resources/ReleaseNotesSources.json"
CATALOG_TOKENS="$(jq '[.[].homebrewTokens[]?] | unique' "$SOURCE_CATALOG")"
MINIMUM_HIGH_CONFIDENCE_PERCENT="${LATEST_MIN_RELEASE_NOTES_COVERAGE_PERCENT:-40}"
MINIMUM_CATALOG_UNIQUE="${LATEST_MIN_RELEASE_NOTES_CATALOG_UNIQUE:-110}"

REPORT="$(jq --argjson catalogTokens "$CATALOG_TOKENS" '
  [ .[] | select(any(.artifacts[]?; type == "object" and has("app"))) ] as $apps |

  def direct_tagged_github_release:
    (.url // "") | test("^https://github\\.com/[^/]+/[^/]+/releases/download/[^/]+/");

  def latest_github_download:
    (.url // "") | test("^https://github\\.com/[^/]+/[^/]+/releases/latest/download/");

  def exact_github_homepage:
    (.homepage // "") | test("^https://github\\.com/[^/]+/[^/]+(?:\\.git)?/?$");

  def catalog_source:
    (.token as $token | $catalogTokens | index($token)) != null;

  def high_confidence_source:
    direct_tagged_github_release or latest_github_download or catalog_source;

  def routed_candidate_source:
    high_confidence_source or exact_github_homepage;

  def homepage_host:
    (try ((.homepage // "") | capture("^https?://(?<host>[^/]+)").host) catch "unknown");

  ($apps | map(select(high_confidence_source))) as $covered |
  ($apps | map(select(routed_candidate_source))) as $candidateCovered |
  {
    app_casks: ($apps | length),
    direct_tagged_github_release: ($apps | map(select(direct_tagged_github_release)) | length),
    latest_github_download: ($apps | map(select(latest_github_download)) | length),
    exact_github_homepage: ($apps | map(select(exact_github_homepage)) | length),
    catalog_source: ($apps | map(select(catalog_source)) | length),
    catalog_unique_high_confidence: (
      $apps
      | map(select(catalog_source and ((direct_tagged_github_release or latest_github_download) | not)))
      | length
    ),
    high_confidence_union: ($covered | length),
    high_confidence_coverage_percent: (
      if ($apps | length) == 0 then 0
      else ((($covered | length) * 10000 / ($apps | length)) | round) / 100
      end
    ),
    routed_candidate_union: ($candidateCovered | length),
    routed_candidate_coverage_percent: (
      if ($apps | length) == 0 then 0
      else ((($candidateCovered | length) * 10000 / ($apps | length)) | round) / 100
      end
    ),
    github_homepage_unique_candidates: (
      $apps
      | map(select(exact_github_homepage and (high_confidence_source | not)))
      | length
    ),
    largest_uncovered_homepage_hosts: (
      $apps
      | map(select(routed_candidate_source | not) | homepage_host)
      | group_by(.)
      | map({ host: .[0], app_casks: length })
      | sort_by(-.app_casks, .host)
      | .[:25]
    )
  }
' "$CATALOG_PATH")"

echo "$REPORT"

high_confidence_percent="$(jq -r '.high_confidence_coverage_percent' <<<"$REPORT")"
catalog_unique="$(jq -r '.catalog_unique_high_confidence' <<<"$REPORT")"
failed=0
if awk -v observed="$high_confidence_percent" -v minimum="$MINIMUM_HIGH_CONFIDENCE_PERCENT" 'BEGIN { exit !(observed >= minimum) }'; then
	echo "RELEASE NOTES COVERAGE PASS high_confidence_percent=$high_confidence_percent minimum_percent=$MINIMUM_HIGH_CONFIDENCE_PERCENT"
else
	echo "RELEASE NOTES COVERAGE FAIL high_confidence_percent=$high_confidence_percent minimum_percent=$MINIMUM_HIGH_CONFIDENCE_PERCENT" >&2
	failed=1
fi
if ((catalog_unique >= MINIMUM_CATALOG_UNIQUE)); then
	echo "RELEASE NOTES COVERAGE PASS catalog_unique_high_confidence=$catalog_unique minimum=$MINIMUM_CATALOG_UNIQUE"
else
	echo "RELEASE NOTES COVERAGE FAIL catalog_unique_high_confidence=$catalog_unique minimum=$MINIMUM_CATALOG_UNIQUE" >&2
	failed=1
fi
exit "$failed"
