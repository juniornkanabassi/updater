#!/bin/zsh
# Signed Release build of Updater. Build products stay out of the iCloud-synced folder.
# Usage: zsh build.sh      Output: ../Outputs/Updater-<version>.zip
set -euo pipefail
SOURCE_ROOT="${0:A:h}"
DERIVED="${UPDATER_BUILD_DIR:-/private/tmp/updater-build}"
OUTPUT_ROOT="${UPDATER_OUTPUT_ROOT:-$SOURCE_ROOT/../Outputs}"
TEAM="M6L2VW4W5Z"
IDENTITY="${UPDATER_SIGN_IDENTITY:-Apple Development: Junior Nkana Bassi (SXSQY4JTTK)}"
APP_ID="com.juniornkanabassi.Updater"
HELPER_ID="$APP_ID.helper"
PRODUCTS="$DERIVED/Build/Products/Release"
APP="$PRODUCTS/Updater.app"
HELPER="$APP/Contents/Resources/UpdaterInstaller"
CLI="$APP/Contents/Helpers/updater"
MCP="$APP/Contents/Resources/mcp/updater-mcp.mjs"

# Stale products (an old App.icns, a renamed helper) must not end up in the zip.
/bin/rm -rf "$PRODUCTS"
/usr/bin/xcodebuild -project "$SOURCE_ROOT/Latest.xcodeproj" -scheme Updater -configuration Release \
  -derivedDataPath "$DERIVED" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" build

[[ -d "$APP" ]] || { print -u2 "Build did not produce $APP"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$APP"
/usr/bin/codesign --verify --strict "$HELPER"
/usr/bin/codesign --verify --strict "$CLI"
[[ -f "$MCP" ]] || { print -u2 "The MCP adapter is missing from $MCP."; exit 1; }

# Identity checks: bundle ID, helper signing identifier, and Junior's team on both binaries.
plist() { /usr/libexec/PlistBuddy -c "Print $2" "$1"; }
[[ "$(plist "$APP/Contents/Info.plist" CFBundleIdentifier)" == "$APP_ID" ]] || { print -u2 "Unexpected bundle identifier."; exit 1; }
[[ "$(plist "$APP/Contents/Info.plist" UpdaterTeamIdentifier)" == "$TEAM" ]] || { print -u2 "Info.plist team is not $TEAM."; exit 1; }
for binary in "$APP" "$HELPER" "$CLI"; do
  details="$(/usr/bin/codesign -dv "$binary" 2>&1)"
  [[ "$details" == *$'\n'"TeamIdentifier=$TEAM"$'\n'* ]] || { print -u2 "$binary is not signed by team $TEAM."; exit 1; }
done
details="$(/usr/bin/codesign -dv "$HELPER" 2>&1)"
[[ "$details" == *$'\n'"Identifier=$HELPER_ID"$'\n'* ]] || { print -u2 "Helper signing identifier is not $HELPER_ID."; exit 1; }
# Launch constraints cannot use build-setting substitution, so check them against the team here.
for daemon in "$APP"/Contents/Library/LaunchDaemons/*.plist; do
  [[ "$(plist "$daemon" :SpawnConstraint:team-identifier)" == "$TEAM" && "$(plist "$daemon" :SpawnConstraint:signing-identifier)" == "$HELPER_ID" ]] \
    || { print -u2 "$daemon launch constraint does not match $TEAM / $HELPER_ID."; exit 1; }
done

VERSION="$(plist "$APP/Contents/Info.plist" CFBundleShortVersionString)"
mkdir -p "$OUTPUT_ROOT"
ZIP="$OUTPUT_ROOT/Updater-$VERSION.zip"
/bin/rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
print "Built Updater $VERSION: $ZIP"
