#!/bin/zsh
# Installs the built Updater.app into the central JuniorOS Apps folder, keeping the previous copy
# until the new one verifies. Usage: zsh install.sh [path/to/Updater.app]
# UPDATER_INSTALL_ROOT overrides the destination (use it for disposable test installs only).
set -euo pipefail
INSTALL_ROOT="${UPDATER_INSTALL_ROOT:-/Applications/JuniorOS Apps}"
SOURCE_APP="${1:-${UPDATER_BUILD_DIR:-/private/tmp/updater-build}/Build/Products/Release/Updater.app}"
APP_ID="com.juniornkanabassi.Updater"
DEST="$INSTALL_ROOT/Updater.app"
(( $# <= 1 )) || { print -u2 "Usage: zsh install.sh [path/to/Updater.app]"; exit 2; }
[[ -d "$SOURCE_APP" ]] || { print -u2 "No built app at $SOURCE_APP. Run build.sh first."; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$SOURCE_APP/Contents/Info.plist")" == "$APP_ID" ]] || { print -u2 "Not an Updater build."; exit 1; }
TEAM="M6L2VW4W5Z"
# Junior's Apple-anchored signature on app and helper; an ad-hoc build would break the install helper.
verify_signed() {
  /usr/bin/codesign --verify --deep --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and identifier \"$APP_ID\"" "$1" &&
  /usr/bin/codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \"$TEAM\" and identifier \"$APP_ID.helper\"" "$1/Contents/Resources/UpdaterInstaller"
}
verify_signed "$SOURCE_APP" || { print -u2 "Source is not signed by team $TEAM. Run build.sh."; exit 1; }
mkdir -p "$INSTALL_ROOT"
[[ ! -L "$DEST" ]] || { print -u2 "Refusing to replace symlink $DEST."; exit 1; }
if [[ -e "$DEST" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null)" == "$APP_ID" ]] || { print -u2 "$DEST is not Updater; refusing to replace it."; exit 1; }
fi

# Quit a running copy cleanly (its own save prompts stay in charge); never kill it.
if /usr/bin/pgrep -f "$DEST/Contents/MacOS/Updater" > /dev/null; then
  /usr/bin/osascript -e "tell application id \"$APP_ID\" to quit" > /dev/null 2>&1 || true
  for _ in {1..30}; do /usr/bin/pgrep -f "$DEST/Contents/MacOS/Updater" > /dev/null || break; sleep 0.5; done
  ! /usr/bin/pgrep -f "$DEST/Contents/MacOS/Updater" > /dev/null || { print -u2 "Updater did not quit. Nothing was changed."; exit 1; }
fi

WORK=$(mktemp -d "$INSTALL_ROOT/.updater-install.XXXXXX")
STAGE="$WORK/Updater.app"; BACKUP="$INSTALL_ROOT/.Updater.app.previous.$RANDOM"
trap '/bin/rm -rf "$WORK"' EXIT
/usr/bin/ditto "$SOURCE_APP" "$STAGE"
verify_signed "$STAGE"
if [[ -e "$DEST" ]]; then /bin/mv "$DEST" "$BACKUP"; fi
if ! /bin/mv "$STAGE" "$DEST"; then
  if [[ -e "$BACKUP" ]] && /bin/mv "$BACKUP" "$DEST"; then print -u2 "Could not install $DEST; the previous app was restored."; else print -u2 "Could not install $DEST. A previous copy may remain at $BACKUP."; fi
  exit 1
fi
if ! verify_signed "$DEST"; then
  /bin/rm -rf "$DEST"
  if [[ -e "$BACKUP" ]] && /bin/mv "$BACKUP" "$DEST"; then print -u2 "Installed signature failed to verify; the previous app was restored."; else print -u2 "Installed signature failed to verify. A previous copy may remain at $BACKUP."; fi
  exit 1
fi
[[ ! -e "$BACKUP" ]] || /bin/rm -rf "$BACKUP"
print "Installed Updater $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist") at $DEST"
