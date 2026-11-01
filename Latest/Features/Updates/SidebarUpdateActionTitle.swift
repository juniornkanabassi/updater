// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

@MainActor
enum SidebarUpdateActionTitle {
  static func text(for app: App) -> String {
    if let externalUpdater = app.externalUpdaterName {
      return String(
        format: NSLocalizedString(
          "ExternalUpdateAction",
          comment:
            "Action to update a given app outside of Latest. The placeholder is the external updater."
        ),
        externalUpdater
      )
    }

    return NSLocalizedString("UpdateAction", comment: "Action to update a given app.")
  }
}
