// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// What pressing Update does for an app. The button label and Update All follow it.
enum UpdateCapability: String, Codable, Sendable {
  /// Updater replaces the bundle at the exact URL itself.
  case install
  /// Updater runs the vendor's own updater command and watches the result.
  case vendorTool
  /// Updater opens another app or page that performs the update.
  case handOff
  case unsupported

  /// Update All runs only actions Updater performs and verifies itself.
  var isAutomatic: Bool { self == .install || self == .vendorTool }
}

/// Where a hand-off sends the user, why, and whether Updater actually opened anything.
/// Kept with the outcome in history, so status and history say the same thing.
struct HandOffNote: Codable, Sendable, Equatable {
  let destination: String
  let reason: String
  let opened: Bool
  /// Something would have opened, but automation did not pass --allow-handoff.
  let blockedByPolicy: Bool
}

/// The durable result of one update action, decided by re-reading the bundle on disk.
enum UpdateOutcome: Codable, Equatable, Sendable {
  case updated(from: String, to: String)
  /// The version on disk is unchanged; `reason` says why when the action knows.
  case noChange(reason: String?)
  case needsPermission(kind: String)
  case needsQuit
  case failed(reason: String, logPath: String?)
  case handedOff
}

extension App {
  /// Source actions map onto capabilities: built-in actions write to this app's URL,
  /// external ones open another updater.
  var capability: UpdateCapability {
    guard let updateAction else { return .unsupported }
    if case .vendorTool = updateAction { return .vendorTool }
    return updateAction.installs ? .install : .handOff
  }
}
