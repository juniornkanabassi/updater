// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import Synchronization

/// One finished update action for the app at `appPath`.
struct UpdateHistoryEntry: Codable, Equatable, Sendable {
  var date = Date()
  let appPath: String
  let bundleIdentifier: String
  /// The installed version and build when the action started, used to tell whether a
  /// recorded failure still describes the bundle on disk.
  let versionNumber: String?
  let buildNumber: String?
  let outcome: UpdateOutcome

  init(bundle: App.Bundle, outcome: UpdateOutcome) {
    appPath = bundle.fileURL.path
    bundleIdentifier = bundle.bundleIdentifier
    versionNumber = bundle.version.versionNumber
    buildNumber = bundle.version.buildNumber
    self.outcome = outcome
  }

  /// Same path, product and full version as the bundle the outcome was recorded for.
  func describes(_ bundle: App.Bundle) -> Bool {
    appPath == bundle.fileURL.path && bundleIdentifier == bundle.bundleIdentifier
      && versionNumber == bundle.version.versionNumber
      && buildNumber == bundle.version.buildNumber
  }
}

/// Append-only JSON lines in Application Support, so outcomes survive list reloads and relaunches.
final class UpdateHistoryStore: Sendable {
  static let shared = UpdateHistoryStore(
    fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Updater/history.jsonl"))

  let fileURL: URL
  /// Latest entry per app path, loaded from disk on first use.
  private let latest = Mutex<[String: UpdateHistoryEntry]?>(nil)

  init(fileURL: URL) { self.fileURL = fileURL }

  func record(_ entry: UpdateHistoryEntry) {
    latest.withLock { cache in
      if cache == nil { cache = Self.load(from: fileURL) }
      cache?[entry.appPath] = entry
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      guard var line = try? encoder.encode(entry) else { return }
      line.append(0x0A)
      try? FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      if let handle = try? FileHandle(forUpdating: fileURL) {
        defer { try? handle.close() }
        // Terminate a torn last line from a crash so this entry stays on its own line.
        if let end = try? handle.seekToEnd(), end > 0 {
          try? handle.seek(toOffset: end - 1)
          if (try? handle.read(upToCount: 1)) != Data([0x0A]) { line.insert(0x0A, at: 0) }
          _ = try? handle.seekToEnd()
        }
        try? handle.write(contentsOf: line)
      } else {
        try? line.write(to: fileURL)
      }
    }
  }

  func latestEntry(for appURL: URL) -> UpdateHistoryEntry? {
    latest.withLock { cache in
      if cache == nil { cache = Self.load(from: fileURL) }
      return cache?[appURL.path]
    }
  }

  private static func load(from url: URL) -> [String: UpdateHistoryEntry] {
    guard let data = try? Data(contentsOf: url) else { return [:] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var entries = [String: UpdateHistoryEntry]()
    // A torn final line from a crash is skipped rather than discarding the history.
    for line in data.split(separator: 0x0A) {
      if let entry = try? decoder.decode(UpdateHistoryEntry.self, from: line) {
        entries[entry.appPath] = entry
      }
    }
    return entries
  }
}

/// A recorded outcome that should keep showing as an error on the row.
struct UpdateOutcomeError: LocalizedError, Sendable {
  let outcome: UpdateOutcome

  init?(outcome: UpdateOutcome) {
    switch outcome {
    case .failed, .needsQuit, .needsPermission: self.outcome = outcome
    case .updated, .noChange, .handedOff: return nil
    }
  }

  var errorDescription: String? {
    switch outcome {
    case .failed(let reason, _): reason
    case .needsQuit: "The app did not quit, so it was not updated. Save your work and try again."
    case .needsPermission:
      "Updater needs App Management permission to replace this app. Allow it in System Settings → Privacy & Security → App Management."
    case .updated, .noChange, .handedOff: nil
    }
  }
}
