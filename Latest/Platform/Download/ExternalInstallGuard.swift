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
  private let journal: TransactionJournal
  /// The journal record while a clone exists.
  private let record = Mutex<TransactionRecord?>(nil)
  /// The one settlement every caller awaits, so a second finalizer cannot return while the
  /// first is still restoring.
  private let settlement = Mutex<Task<Error?, Never>?>(nil)

  /// Moves a companion record; injectable so tests can make either move fail.
  private let companionMove: @Sendable (URL, URL) throws -> Void

  init(
    target: URL, journal: TransactionJournal = .shared,
    companionMove: @escaping @Sendable (URL, URL) throws -> Void = {
      try FileManager.default.moveItem(at: $0, to: $1)
    }
  ) {
    self.target = target
    self.journal = journal
    self.companionMove = companionMove
  }

  /// Clones into Updater's backup folder on the target's volume and journals it, so an
  /// interruption is reconciled at the next launch. `companions` are cloned too and restored
  /// together with the app. `writer` is whoever may change the target from now on.
  func takeClone(
    companions: [URL] = [], mechanism: String = "external", lockKey: String = "",
    writer: TransactionRecord.Writer = TransactionJournal.writer(), expected: Version? = nil
  ) throws {
    let directory = try journal.backupDirectory(for: target, id: UUID().uuidString)
    do {
      let original = try ReplacementTransaction.cloneOriginal(at: target, into: directory)
      var saved = [(live: URL, saved: URL)]()
      for (index, companion) in companions.enumerated()
      where FileManager.default.fileExists(atPath: companion.path) {
        let copy = directory.appendingPathComponent("companion-\(index)")
        try FileManager.default.copyItem(at: companion, to: copy)
        saved.append((companion, copy))
      }
      let entry = TransactionRecord(
        id: directory.lastPathComponent, target: target.path,
        backup: directory.appendingPathComponent(ReplacementTransaction.backupName).path,
        companions: saved.map { .init(live: $0.live.path, saved: $0.saved.path) },
        bundleIdentifier: original.bundleIdentifier, teamIdentifier: original.teamIdentifier,
        originalVersion: original.shortVersion, originalBuild: original.bundleVersion,
        expectedVersion: expected?.versionNumber, expectedBuild: expected?.buildNumber,
        phase: .external, mechanism: "clone:" + mechanism, writer: writer,
        lockKey: lockKey.isEmpty ? "target:" + target.path : lockKey)
      try journal.write(entry)
      record.withLock { $0 = entry }
      clone.withLock { $0 = Saved(directory: directory, original: original, companions: saved) }
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  /// Records who now may change the target (the brew process that started, say). A failed
  /// write throws: the caller must not start that writer.
  func noteWriter(_ writer: TransactionRecord.Writer, started: Bool = true) throws {
    try update {
      $0.writer = writer
      $0.writerStarted = started
    }
  }

  /// The registered tool was resumed and may now change the target.
  func noteWriterStarted() {
    try? update { $0.writerStarted = true }
  }

  /// Records the version the installer promised once it is known (Sparkle's item), before
  /// the installer can change anything.
  func noteExpected(_ version: Version?) throws {
    try update {
      $0.expectedVersion = version?.versionNumber
      $0.expectedBuild = version?.buildNumber
    }
  }

  private func update(_ change: (inout TransactionRecord) -> Void) throws {
    guard var entry = record.withLock({ $0 }) else { return }
    change(&entry)
    try journal.write(entry)
    record.withLock { $0 = entry }
  }

  private func settled() {
    guard
      let entry = record.withLock({ value -> TransactionRecord? in
        defer { value = nil }
        return value
      })
    else { return }
    journal.remove(entry.id)
  }

  /// Records that Updater quit the app, so it is reopened however the attempt ends.
  func noteQuit(wasRunning: Bool) {
    if wasRunning { quitByUpdater.withLock { $0 = true } }
  }

  /// Hands the clone over to the user when the outcome is unknown: it is neither restored nor
  /// deleted, and the app is not reopened. Returns where the original was kept.
  func abandon() -> URL? {
    quitByUpdater.withLock { $0 = false }
    // The outcome is unknown: the journal stays, so the next launch reconciles it.
    record.withLock { $0 = nil }
    return takeSaved()?.directory.appendingPathComponent(ReplacementTransaction.backupName)
  }

  /// For exits before the installer could touch the bundle.
  func discard() {
    if let saved = takeSaved() { try? FileManager.default.removeItem(at: saved.directory) }
    settled()
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
    restoreOnInstallerFailure: Bool = false, acceptUnchanged: Bool = true
  ) async -> Error? {
    let task = settlement.withLock { current -> Task<Error?, Never> in
      if let current { return current }
      let task = Task { @MainActor in
        await self.performSettle(
          error: error, expected: expected, requiresTeam: requiresTeam, lifecycle: lifecycle,
          restoreOnInstallerFailure: restoreOnInstallerFailure, acceptUnchanged: acceptUnchanged)
      }
      current = task
      return task
    }
    return await task.value
  }

  @MainActor
  private func performSettle(
    error: Error?, expected: Version?, requiresTeam: Bool, lifecycle: AppLifecycle,
    restoreOnInstallerFailure: Bool, acceptUnchanged: Bool
  ) async -> Error? {
    var result = error
    if let saved = takeSaved() {
      do {
        if restoreOnInstallerFailure, let error { throw error }
        try ReplacementTransaction.verifyExternalInstall(
          at: target, original: saved.original, expected: expected, requiresTeam: requiresTeam,
          acceptUnchanged: acceptUnchanged)
        try? FileManager.default.removeItem(at: saved.directory)
      } catch let failure {
        // The app and each companion record are restored separately, so a failure reports
        // exactly what survived where.
        var appRestored = false
        do {
          try await lifecycle.quit(
            at: target, name: target.deletingPathExtension().lastPathComponent)
          try ReplacementTransaction.restore(
            target, backupDirectory: saved.directory, originalIdentity: saved.original)
          appRestored = true
          // Each step is journaled, so a later recovery resumes instead of starting over.
          try? update { $0.recovery = .init(appRestored: true) }
        } catch {}
        var incomplete = [String]()
        // Records are only put back with their app: if the app stays as the installer left
        // it, its records stay live too, and both saved copies are reported.
        for (index, companion) in saved.companions.enumerated() where appRestored {
          let aside = saved.directory.appendingPathComponent("failed-companion-\(index)")
          do {
            if FileManager.default.fileExists(atPath: companion.live.path) {
              try companionMove(companion.live, aside)
            }
            try companionMove(companion.saved, companion.live)
            try? update { $0.recovery?.companionsRestored.append(index) }
          } catch {
            incomplete.append(
              "\(companion.live.path) (previous record kept at \(companion.saved.path))")
          }
        }
        if !appRestored {
          result = ReplacementError.restoreFailed(
            ([saved.directory.appendingPathComponent(ReplacementTransaction.backupName).path]
              + saved.companions.map { "\($0.saved.path) (Homebrew's previous record)" })
              .joined(separator: "; "))
        } else if !incomplete.isEmpty {
          result = ReplacementError.incompleteRestore(incomplete.joined(separator: "; "))
        } else {
          try? FileManager.default.removeItem(at: saved.directory)
          // The installer's own error (with its log) explains more than the check that caught it.
          result = error ?? failure
        }
        // A bundle that could not be restored is not reopened.
        if !appRestored { quitByUpdater.withLock { $0 = false } }
      }
    }
    reopenIfQuit(lifecycle)
    // A failed restore keeps the record: the next launch tries again or keeps both copies.
    // Not settled while anything is still to put back (UPD-002).
    if case .restoreFailed? = result as? ReplacementError {
      record.withLock { $0 = nil }
    } else if case .incompleteRestore? = result as? ReplacementError {
      record.withLock { $0 = nil }
    } else {
      settled()
    }
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
