// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Chrome's available version from Google's version-history API. Updater does not run
/// GoogleUpdater (`--wake` updates every registered Google app, not just this copy); Chrome's
/// own updater stages the update, and "Relaunch Chrome" lets Chrome apply it.
actor GoogleChrome {
  static let bundleIdentifier = "com.google.Chrome"
  static let shared = GoogleChrome(releases: {
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

  struct Unreadable: LocalizedError {
    var errorDescription: String? { "Google's Chrome version list could not be read." }
  }

  private let releases: @Sendable () async throws -> Data
  private var cached: (date: Date, version: String)?
  /// Shared by concurrent checks; a generation bump keeps an older lookup from refilling.
  private var inFlight: (generation: Int, task: Task<String, Error>)?
  private var generation = 0

  init(releases: @escaping @Sendable () async throws -> Data) {
    self.releases = releases
  }

  func invalidate() {
    generation += 1
    cached = nil
    inFlight = nil
  }

  /// The stable release served to the largest share of Macs. Throws when the list cannot be
  /// read; failures are not cached.
  func availableVersion() async throws -> String {
    if let cached, Date().timeIntervalSince(cached.date) < 60 { return cached.version }
    if let inFlight, inFlight.generation == generation { return try await inFlight.task.value }
    let started = generation
    let task = Task { [releases] in
      guard let version = Self.parseServedVersion(try await releases()) else { throw Unreadable() }
      return version
    }
    inFlight = (started, task)
    defer { if inFlight?.generation == started { inFlight = nil } }
    let version = try await task.value
    if generation == started { cached = (Date(), version) }
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
}

/// "Relaunch Chrome", started only by the user: a clean quit if Chrome is running (with the
/// usual consent), then a launch that is awaited, so Chrome applies what its updater staged.
/// The version at the exact URL is watched briefly, then the scheduler reads it from disk.
/// Updater replaces nothing, so no clone is needed.
final class ChromeRelaunchOperation: UpdateOperation, @unchecked Sendable {
  var lifecycle = AppLifecycle.live
  /// How long to watch for Chrome finishing a staged update after it launched.
  var settleTime: Duration = .seconds(10)

  init(app: App.Bundle) {
    super.init(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
  }

  override func execute() {
    super.execute()
    Task { @MainActor in
      guard !self.isCancelled else { return self.finish() }
      let before = BundleCollector.collectBundle(at: self.appIdentifier)?.version
      do {
        _ = try await self.lifecycle.quit(
          at: self.appIdentifier, name: self.appIdentifier.deletingPathExtension().lastPathComponent
        )
      } catch is CancellationError {
        // A declined quit is a cancel: no outcome, and an earlier failure stays as it was.
        self.declineQuit()
        return self.finish()
      } catch {
        return self.finish(with: error)
      }
      do { try await self.lifecycle.launch(self.appIdentifier) } catch {
        return self.finish(with: error)
      }
      let deadline = ContinuousClock.now + self.settleTime
      while ContinuousClock.now < deadline,
        BundleCollector.collectBundle(at: self.appIdentifier)?.version == before
      {
        try? await Task.sleep(for: .milliseconds(250))
      }
      self.noChangeReason = "Chrome hasn't downloaded the update yet."
      self.finish()
    }
  }
}
