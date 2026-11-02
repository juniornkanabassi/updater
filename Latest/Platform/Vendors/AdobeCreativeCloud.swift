// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import SQLite3

/// Adobe apps are updated by the Creative Cloud app. Its package database (pim.db) shows
/// Creative Cloud is installed and managing packages, but neither it nor any other documented
/// local file says which app version Creative Cloud would offer, so Adobe apps hand off to
/// Creative Cloud ("Check in Creative Cloud") with availability unknown. RemoteUpdateManager is
/// deferred; see PLAN.md, Round 3.
struct AdobeCreativeCloud: Sendable {
  var database = URL(
    fileURLWithPath: "/Library/Application Support/Adobe/Adobe Desktop Common/pim.db")
  var app = URL(
    fileURLWithPath: "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app")
  /// Current installs keep the app under Utilities; "/Applications/Adobe Creative Cloud" holds
  /// only an alias to it.
  /// Opens Creative Cloud; injectable so tests open nothing.
  var open: @MainActor @Sendable (URL) -> Void = {
    MacApplicationWorkspace.shared.openApplication(at: $0)
  }
  static let live = AdobeCreativeCloud(
    app: [
      "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app",
      "/Applications/Adobe Creative Cloud/Adobe Creative Cloud.app",
    ].map(URL.init(fileURLWithPath:)).first { FileManager.default.fileExists(atPath: $0.path) }
      ?? URL(fileURLWithPath: "/Applications/Utilities/Adobe Creative Cloud/ACC/Creative Cloud.app")
  )

  func manages(_ bundle: App.Bundle) -> Bool {
    bundle.bundleIdentifier.hasPrefix("com.adobe.")
      // Creative Cloud's own components update themselves.
      && !bundle.fileURL.path.hasPrefix(app.deletingLastPathComponent().path + "/")
      && !bundle.bundleIdentifier.hasPrefix("com.adobe.acc")
      && FileManager.default.fileExists(atPath: app.path) && packageCount() > 0
  }

  /// Reads a copy of pim.db, opened read-only, so Creative Cloud's own file is never locked
  /// or written.
  func packageCount() -> Int {
    let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pim-\(UUID().uuidString).db")
    guard (try? FileManager.default.copyItem(at: database, to: copy)) != nil else { return 0 }
    defer { try? FileManager.default.removeItem(at: copy) }
    var db: OpaquePointer?
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return 0
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "SELECT count(*) FROM package_installation_info", -1, &statement, nil)
        == SQLITE_OK
    else { return 0 }
    defer { sqlite3_finalize(statement) }
    return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
  }
}
