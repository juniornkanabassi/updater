// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import Synchronization

/// Protection for installers that replace the bundle themselves (Sparkle, CommerceKit):
/// an Updater-owned APFS clone of the exact target taken before they can commit, checked
/// against the shared ReplacementTransaction rules when they report, and put back on failure.
final class ExternalInstallGuard: Sendable {
  let target: URL
  private let clone = Mutex<(directory: URL, original: BundleIdentity)?>(nil)
  private let quitByUpdater = Mutex(false)
  /// The one settlement every caller awaits, so a second finalizer cannot return while the
  /// first is still restoring.
  private let settlement = Mutex<Task<Error?, Never>?>(nil)

  init(target: URL) { self.target = target }

  /// Clones into a private folder on the target's volume.
  func takeClone() throws {
    let directory = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
    do {
      let original = try ReplacementTransaction.cloneOriginal(at: target, into: directory)
      clone.withLock { $0 = (directory, original) }
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
  /// `restoreIfChanged`: the installer reported failure, so any change it made is undone
  /// even if the result would verify (brew exiting non-zero mid-upgrade).
  @MainActor
  func settle(
    error: Error?, expected: Version?, requiresTeam: Bool, lifecycle: AppLifecycle,
    restoreIfChanged: Bool = false
  ) async -> Error? {
    let task = settlement.withLock { current -> Task<Error?, Never> in
      if let current { return current }
      let task = Task { @MainActor in
        await self.performSettle(
          error: error, expected: expected, requiresTeam: requiresTeam, lifecycle: lifecycle,
          restoreIfChanged: restoreIfChanged)
      }
      current = task
      return task
    }
    return await task.value
  }

  @MainActor
  private func performSettle(
    error: Error?, expected: Version?, requiresTeam: Bool, lifecycle: AppLifecycle,
    restoreIfChanged: Bool
  ) async -> Error? {
    var result = error
    if let saved = takeSaved() {
      do {
        if restoreIfChanged, let error,
          (try? BundleIdentity.read(at: target, validate: false)) != saved.original
        {
          throw error
        }
        try ReplacementTransaction.verifyExternalInstall(
          at: target, original: saved.original, expected: expected, requiresTeam: requiresTeam)
        try? FileManager.default.removeItem(at: saved.directory)
      } catch let failure {
        do {
          try await lifecycle.quit(
            at: target, name: target.deletingPathExtension().lastPathComponent)
          try ReplacementTransaction.restore(
            target, backupDirectory: saved.directory, originalIdentity: saved.original)
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

  private func takeSaved() -> (directory: URL, original: BundleIdentity)? {
    clone.withLock { value in
      defer { value = nil }
      return value
    }
  }
}
