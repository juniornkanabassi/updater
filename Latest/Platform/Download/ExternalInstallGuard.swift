// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import Synchronization

/// Protection for installers that replace the bundle themselves (Sparkle, CommerceKit):
/// an Updater-owned APFS clone of the exact target taken before they can commit, checked
/// against the shared ReplacementTransaction rules when they report, and put back on failure.
final class ExternalInstallGuard: Sendable {
  let target: URL
  private let clone = Mutex<Saved?>(nil)
  private struct Saved: Sendable {
    let directory: URL
    let original: BundleIdentity
    /// Records outside the bundle that must agree with it (Homebrew's Caskroom entry):
    /// live location and its clone.
    let companions: [(live: URL, saved: URL)]
  }
  private let quitByUpdater = Mutex(false)
  /// The one settlement every caller awaits, so a second finalizer cannot return while the
  /// first is still restoring.
  private let settlement = Mutex<Task<Error?, Never>?>(nil)

  init(target: URL) { self.target = target }

  /// Clones into a private folder on the target's volume. `companions` are cloned too and
  /// restored together with the app.
  func takeClone(companions: [URL] = []) throws {
    let directory = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    do {
      let original = try ReplacementTransaction.cloneOriginal(at: target, into: directory)
      var saved = [(live: URL, saved: URL)]()
      for (index, companion) in companions.enumerated()
      where FileManager.default.fileExists(atPath: companion.path) {
        let copy = directory.appendingPathComponent("companion-\(index)")
        try FileManager.default.copyItem(at: companion, to: copy)
        saved.append((companion, copy))
      }
      clone.withLock { $0 = Saved(directory: directory, original: original, companions: saved) }
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Records that Updater quit the app, so it is reopened however the attempt ends.
  func noteQuit(wasRunning: Bool) {
    if wasRunning { quitByUpdater.withLock { $0 = true } }
  }

  /// Hands the clone over to the user when the outcome is unknown: it is neither restored nor
  /// deleted, and the app is not reopened. Returns where the original was kept.
  func abandon() -> URL? {
    quitByUpdater.withLock { $0 = false }
    return takeSaved()?.directory.appendingPathComponent(ReplacementTransaction.backupName)
  }

  /// For exits before the installer could touch the bundle.
  func discard() {
    if let saved = takeSaved() { try? FileManager.default.removeItem(at: saved.directory) }
  }

  /// Verifies the destination; on failure closes the app if it is running (a relaunched bad
  /// version) and restores the clone. Reopens the app if Updater quit it and it is not
  /// running. Returns the error to report: the original one, a verification failure, or a
  /// restore failure naming where the clone was kept.
  /// `restoreOnInstallerFailure`: when the installer itself reported failure, the clone
  /// always goes back, whatever the bundle now looks like (brew exiting non-zero).
  @MainActor
  func settle(
    error: Error?, expected: Version?, requiresTeam: Bool, lifecycle: AppLifecycle,
    restoreOnInstallerFailure: Bool = false
  ) async -> Error? {
    let task = settlement.withLock { current -> Task<Error?, Never> in
      if let current { return current }
      let task = Task { @MainActor in
        await self.performSettle(
          error: error, expected: expected, requiresTeam: requiresTeam, lifecycle: lifecycle,
          restoreOnInstallerFailure: restoreOnInstallerFailure)
      }
      current = task
      return task
    }
    return await task.value
  }

  @MainActor
  private func performSettle(
    error: Error?, expected: Version?, requiresTeam: Bool, lifecycle: AppLifecycle,
    restoreOnInstallerFailure: Bool
  ) async -> Error? {
    var result = error
    if let saved = takeSaved() {
      do {
        if restoreOnInstallerFailure, let error { throw error }
        try ReplacementTransaction.verifyExternalInstall(
          at: target, original: saved.original, expected: expected, requiresTeam: requiresTeam)
        try? FileManager.default.removeItem(at: saved.directory)
      } catch let failure {
        do {
          try await lifecycle.quit(
            at: target, name: target.deletingPathExtension().lastPathComponent)
          try ReplacementTransaction.restore(
            target, backupDirectory: saved.directory, originalIdentity: saved.original)
          for (index, companion) in saved.companions.enumerated() {
            if FileManager.default.fileExists(atPath: companion.live.path) {
              try FileManager.default.moveItem(
                at: companion.live,
                to: saved.directory.appendingPathComponent("failed-companion-\(index)"))
            }
            try FileManager.default.moveItem(at: companion.saved, to: companion.live)
          }
          try? FileManager.default.removeItem(at: saved.directory)
          // The installer's own error (with its log) explains more than the check that caught it.
          result = error ?? failure
        } catch {
          result = ReplacementError.restoreFailed(
            saved.directory.appendingPathComponent(ReplacementTransaction.backupName).path)
        }
      }
    }
    reopenIfQuit(lifecycle)
    return result
  }

  @MainActor func reopenIfQuit(_ lifecycle: AppLifecycle) {
    guard quitByUpdater.withLock({ $0 }), lifecycle.runningApps(target).isEmpty,
      FileManager.default.fileExists(atPath: target.path)
    else { return }
    quitByUpdater.withLock { $0 = false }
    lifecycle.reopen(target)
  }

  private func takeSaved() -> Saved? {
    clone.withLock { value in
      defer { value = nil }
      return value
    }
  }
}
