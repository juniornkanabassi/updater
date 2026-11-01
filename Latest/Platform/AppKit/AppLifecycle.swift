// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.
// Extracted from DownloadUpdateOperation so every installer Updater drives shares one quit path.

import AppKit

/// Quits the app at an exact URL before an install and reopens it afterwards if it was
/// running. Quit is a polite request: the app keeps its save prompts, and Updater never
/// force-kills. If it refuses or times out, nothing is installed.
struct AppLifecycle: Sendable {
  struct RunningApp: Sendable {
    let terminate: @MainActor @Sendable () -> Void
    let isTerminated: @MainActor @Sendable () -> Bool
  }

  var runningApps: @MainActor @Sendable (URL) -> [RunningApp]
  var confirmQuit: @MainActor @Sendable (_ appName: String) -> Bool
  var reopen: @MainActor @Sendable (URL) -> Void
  var timeout: Duration = .seconds(20)

  static let live = AppLifecycle(
    runningApps: { url in
      NSWorkspace.shared.runningApplications
        .filter { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        .map { app in
          RunningApp(terminate: { _ = app.terminate() }, isTerminated: { app.isTerminated })
        }
    },
    confirmQuit: { name in
      let alert = NSAlert()
      alert.messageText = "Quit \(name) to install its update?"
      alert.informativeText = "Save your work first. The app will reopen after the update."
      alert.addButton(withTitle: "Quit and Update")
      alert.addButton(withTitle: "Cancel")
      return alert.runModal() == .alertFirstButtonReturn
    },
    reopen: { MacApplicationWorkspace.shared.openApplication(at: $0) })

  @MainActor
  func withApplicationClosed(
    at url: URL, name: String, _ install: @Sendable () async throws -> Void
  ) async throws {
    try Task.checkCancellation()
    let running = runningApps(url)
    if !running.isEmpty, !confirmQuit(name) { throw CancellationError() }
    try await ApplicationQuitLifecycle.run(
      terminate: { running.forEach { $0.terminate() } },
      isTerminated: { running.allSatisfy { $0.isTerminated() } },
      reopen: {
        guard !running.isEmpty, FileManager.default.fileExists(atPath: url.path) else { return }
        reopen(url)
      },
      install: install,
      timeout: timeout)
  }
}

/// Quit cannot be recalled after sending terminate(). Wait for its outcome even
/// after cancellation, then reopen the surviving app without starting an install.
@MainActor
enum ApplicationQuitLifecycle {
  static func run(
    terminate: () -> Void,
    isTerminated: @escaping @MainActor @Sendable () -> Bool,
    reopen: () -> Void,
    install: @Sendable () async throws -> Void,
    timeout: Duration = .seconds(20)
  ) async throws {
    // Confirmation can run a nested event loop where cancellation is accepted.
    try Task.checkCancellation()
    defer { if isTerminated() { reopen() } }
    terminate()
    let terminated = await Task { @MainActor in
      let deadline = ContinuousClock.now + timeout
      while ContinuousClock.now < deadline {
        if isTerminated() { return true }
        try? await Task.sleep(for: .milliseconds(200))
      }
      return isTerminated()
    }.value
    guard terminated else { throw AppDownloadError.applicationStillRunning }
    try Task.checkCancellation()
    try await install()
  }
}
