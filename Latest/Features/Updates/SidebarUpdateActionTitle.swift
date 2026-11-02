// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit

@MainActor
enum SidebarUpdateActionTitle {
  static func text(for app: App) -> String {
    if app.relaunchesToUpdate {
      return (isRunning(app) ? "Relaunch " : "Open ") + app.name
    }
    if let externalUpdater = app.externalUpdaterName {
      return String(
        format: NSLocalizedString(
          "ExternalUpdateAction",
          comment:
            "Action to update a given app outside of Updater. The placeholder is the external updater."
        ),
        externalUpdater
      )
    }

    return NSLocalizedString("UpdateAction", comment: "Action to update a given app.")
  }

  /// Whether the app at this exact path is running: Relaunch for a running app, Open for a
  /// closed one.
  static func isRunning(_ app: App) -> Bool {
    NSWorkspace.shared.runningApplications.contains {
      $0.bundleURL?.standardizedFileURL == app.fileURL.standardizedFileURL
    }
  }
}
