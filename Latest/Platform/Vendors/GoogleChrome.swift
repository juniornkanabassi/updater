// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Chrome through Google's own updater. The user-level GoogleUpdater maintains a Chrome the
/// user owns; a Chrome owned by another account (a system install) would need the root
/// updater, so it hands off. Availability comes from Google's version-history API.
actor GoogleChrome {
  static let bundleIdentifier = "com.google.Chrome"
  static let shared = GoogleChrome(
    updater: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/Google/GoogleUpdater/Current/GoogleUpdater.app/Contents/MacOS/GoogleUpdater"
    ),
    releases: {
      let url = URL(
        string:
          "https://versionhistory.googleapis.com/v1/chrome/platforms/mac/channels/stable/versions/all/releases?filter=endtime=none"
      )!
      var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
      request.timeoutInterval = 30
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
      }
      return data
    })

  let updater: URL
  private let releases: @Sendable () async throws -> Data
  private let logDirectory: URL
  private var cached: (date: Date, version: String?)?

  init(
    updater: URL, releases: @escaping @Sendable () async throws -> Data,
    logDirectory: URL = ToolProcess.defaultLogDirectory
  ) {
    self.updater = updater
    self.releases = releases
    self.logDirectory = logDirectory
  }

  /// The user-level updater exists and this Chrome belongs to the user.
  func canUpdate(_ app: URL) -> Bool {
    FileManager.default.isExecutableFile(atPath: updater.path)
      && (try? FileManager.default.attributesOfItem(atPath: app.path)[.ownerAccountID] as? NSNumber)?
        .uint32Value == getuid()
  }

  /// The stable release served to the largest share of Macs.
  func availableVersion() async -> String? {
    if let cached, Date().timeIntervalSince(cached.date) < 60 { return cached.version }
    let version = (try? await releases()).flatMap(Self.parseServedVersion)
    cached = (Date(), version)
    return version
  }

  static func parseServedVersion(_ data: Data) -> String? {
    let releases =
      (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["releases"]
      as? [[String: Any]] ?? []
    return releases.compactMap { release -> (String, Double)? in
      guard let version = release["version"] as? String else { return nil }
      return (version, release["fraction"] as? Double ?? 0)
    }
    .max { lhs, rhs in
      lhs.1 != rhs.1
        ? lhs.1 < rhs.1
        : Version(versionNumber: lhs.0, buildNumber: nil).comparisonForUpdate(
          to: Version(versionNumber: rhs.0, buildNumber: nil)) == .older
    }?.0
  }

  /// `GoogleUpdater --wake` runs one update cycle for the user's Google apps and exits.
  func install() async throws {
    let log = try ToolProcess.newLog(named: "googleupdater-wake", in: logDirectory)
    let status = try await ToolProcess.run(updater, ["--wake"], log: log)
    cached = nil
    guard status == 0 else {
      throw VendorToolError.failed(
        reason: "GoogleUpdater could not update Chrome (exit \(status)).", logPath: log.path)
    }
  }
}
