#!/bin/zsh
# Installs the built Updater.app into the central JuniorOS Apps folder, keeping the previous copy
# until the new one verifies. Usage: zsh install.sh [path/to/Updater.app]
# UPDATER_INSTALL_ROOT overrides the destination (use it for disposable test installs only).
# UPDATER_BIN_DIR is where the `updater` command is linked (default ~/.local/bin; a test install
# with UPDATER_INSTALL_ROOT and no UPDATER_BIN_DIR links nothing).
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


# One install at a time for this destination. shlock writes our pid atomically and
# only replaces a lock whose recorded owner is no longer running.
LOCK="$INSTALL_ROOT/.updater-install.lock"
[[ -d "$LOCK" ]] && ! kill -0 "$(<"$LOCK/pid" 2>/dev/null)" 2>/dev/null && /bin/rm -rf "$LOCK"  # lock folder from install.sh before 0.8.2
/usr/bin/shlock -f "$LOCK" -p $$ || { print -u2 "Another Updater install is running (pid $(<"$LOCK" 2>/dev/null))."; exit 1; }
for old in "$INSTALL_ROOT"/.updater-install.*(N/); do print -u2 "Left from an earlier run (not removed): $old"; done
WORK=$(mktemp -d "$INSTALL_ROOT/.updater-install.XXXXXX")
STAGE="$WORK/Updater.app"; BACKUP="$WORK/previous/Updater.app"; mkdir "$WORK/previous"
VERIFIED=0
cleanup() {
  # The original lives in BACKUP from the move until the new copy verifies: never delete it before then.
  if [[ -e "$BACKUP" ]] && (( ! VERIFIED )); then
    if [[ ! -e "$DEST" ]] && /bin/mv "$BACKUP" "$DEST"; then
      print -u2 "Interrupted: the previous Updater was put back."
    else
      print -u2 "Interrupted: the previous Updater is kept at $BACKUP."
      [[ "$(<"$LOCK" 2>/dev/null)" == "$$" ]] && /bin/rm -f "$LOCK"
      return
    fi
  fi
  /bin/rm -rf "$WORK"
  [[ "$(<"$LOCK" 2>/dev/null)" == "$$" ]] && /bin/rm -f "$LOCK"  # release only our own lock
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP PIPE  # signals still run the EXIT cleanup

# Quit a running copy cleanly (its own save prompts stay in charge); never kill it.
if /usr/bin/pgrep -f "$DEST/Contents/MacOS/Updater" > /dev/null; then
  /usr/bin/osascript -e "tell application id \"$APP_ID\" to quit" > /dev/null 2>&1 || true
  for _ in {1..30}; do /usr/bin/pgrep -f "$DEST/Contents/MacOS/Updater" > /dev/null || break; sleep 0.5; done
  ! /usr/bin/pgrep -f "$DEST/Contents/MacOS/Updater" > /dev/null || { print -u2 "Updater did not quit. Nothing was changed."; exit 1; }
fi

/usr/bin/ditto "$SOURCE_APP" "$STAGE"
verify_signed "$STAGE"
if [[ -e "$DEST" ]]; then /bin/mv "$DEST" "$BACKUP"; fi
[[ -n "${UPDATER_INSTALL_ROOT:-}" && -n "${UPDATER_INSTALL_TEST_PAUSE:-}" ]] && sleep "$UPDATER_INSTALL_TEST_PAUSE"  # test installs only: window to interrupt mid-replace
if ! /bin/mv "$STAGE" "$DEST"; then print -u2 "Could not install $DEST."; exit 1; fi
if ! verify_signed "$DEST"; then /bin/rm -rf "$DEST"; print -u2 "Installed signature failed to verify."; exit 1; fi
VERIFIED=1
print "Installed Updater $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist") at $DEST"

# The CLI lives in the app; link it onto PATH as Talk & Read does.
if [[ -n "${UPDATER_BIN_DIR:-}" || -z "${UPDATER_INSTALL_ROOT:-}" ]]; then
  BIN_DIR="${UPDATER_BIN_DIR:-$HOME/.local/bin}"
  LINK="$BIN_DIR/updater"
  mkdir -p "$BIN_DIR"
  if [[ -e "$LINK" && ! -L "$LINK" ]]; then
    print -u2 "$LINK exists and is not a link; leaving it alone."
  else
    ln -sfn "$DEST/Contents/Helpers/updater" "$LINK"
    print "Linked $LINK. If \`updater\` is not found, add $BIN_DIR to PATH."
  fi
else
  print "Test install: no CLI link."
fi
SHIM="$DEST/Contents/Resources/mcp/updater-mcp.mjs"
print "MCP for Claude Code: claude mcp add updater -- node \"$SHIM\""
print 'MCP for Codex (~/.codex/config.toml):'
print '[mcp_servers.updater]'
print 'command = "node"'
print "args = [\"$SHIM\"]"
