// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum VendorToolError: LocalizedError, Equatable {
  case failed(reason: String, logPath: String)
  /// The tool returned while its own background installer may still be working.
  case stillWorking(logPath: String)

  var errorDescription: String? {
    switch self {
    case .failed(let reason, _): reason
    case .stillWorking(let log): "The vendor's updater was still working. Its log: \(log)."
    }
  }
}

/// Runs a vendor's updater command for one app with Updater's protection: the exact app is
/// still the vendor tool's target, it is quit first, Updater takes its own clone, the result
/// is verified on disk and the clone restored on failure. Jobs share the tool's lock.
final class VendorToolOperation: UpdateOperation, @unchecked Sendable {
  private let lock: String
  private let protection: ExternalInstallGuard
  private let inScope: @Sendable () async -> Bool
  private let install: @Sendable () async throws -> Void
  /// Whether the vendor's own installer is idle; nothing is judged or restored before it is.
  private let vendorIsIdle: @Sendable () async -> Bool
  private let waitingStatus: String
  var pollInterval: Duration = .seconds(10)
  var lifecycle = AppLifecycle.live
  /// False only for ad-hoc signed test fixtures.
  var requiresTeam = true
  @MainActor private var published = false

  override var lockKey: String { lock }

  init(
    app: App.Bundle, lock: String, expectedVersion: Version?,
    inScope: @escaping @Sendable () async -> Bool,
    install: @escaping @Sendable () async throws -> Void,
    vendorIsIdle: @escaping @Sendable () async -> Bool = { true },
    waitingStatus: String = "Waiting for the vendor's updater to finish"
  ) {
    self.lock = lock
    self.inScope = inScope
    self.install = install
    self.vendorIsIdle = vendorIsIdle
    self.waitingStatus = waitingStatus
    protection = ExternalInstallGuard(target: app.fileURL)
    super.init(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
    self.expectedVersion = expectedVersion
  }

  private static let outOfScope =
    "The vendor's updater would not update only this copy, so Updater does not run it."
  /// Where the user updates it instead (the vendor's own app, Microsoft AutoUpdate say).
  private var vendorUpdater: String { "the vendor's updater (\(lock))" }

  override func execute() {
    super.execute()
    Task { @MainActor in
      guard !self.isCancelled else { return self.finish() }
      guard await self.inScope() else {
        self.recordHandOff(to: self.vendorUpdater, because: Self.outOfScope)
        return self.finish()
      }
      do {
        self.protection.noteQuit(
          wasRunning: try await self.lifecycle.quit(
            at: self.appIdentifier,
            name: self.appIdentifier.deletingPathExtension().lastPathComponent))
      } catch is CancellationError {
        // A declined quit is a cancel: nothing is recorded.
        self.declineQuit()
        return self.finish()
      } catch {
        return self.finish(with: error)
      }
      let writer: TransactionRecord.Writer =
        self.lock == "msupdate"
        ? .named(["msupdate", "Microsoft Update Assistant", "Microsoft AutoUpdate"])
        : TransactionJournal.writer()
      do {
        try self.protection.takeClone(
          mechanism: "vendorTool:" + self.lock, lockKey: self.lock, writer: writer,
          expected: self.expectedVersion)
      } catch {
        self.recordHandOff(
          to: self.vendorUpdater, because: "Updater could not make its safety copy of the app.")
        return self.finish()
      }
      // The quit prompt can wait on the user for a long time: check the target again right
      // before the vendor tool runs. finish() discards the clone and reopens the app.
      guard await self.inScope() else {
        self.recordHandOff(to: self.vendorUpdater, because: Self.outOfScope)
        return self.finish()
      }
      do { try self.beginCommit() } catch { return await self.finalize(nil) }
      self.progressState = .installing
      do {
        try await self.install()
        await self.finalize(nil)
      } catch {
        // The vendor's installer may still be writing (it said so, or it exited non-zero).
        // The job keeps its lock and its target and waits, without a time limit, until the
        // vendor is idle; only then is the result verified or the original restored.
        if error is VendorToolError {
          self.progressState = .waitingForVendor(self.waitingStatus)
          while !(await self.vendorIsIdle()) { try? await Task.sleep(for: self.pollInterval) }
        }
        if case VendorToolError.stillWorking = error {
          await self.finalize(nil)
        } else {
          await self.finalize(error)
        }
      }
    }
  }

  /// A vendor tool may legitimately install nothing (a staged rollout), so an unchanged app
  /// is accepted and reads as no change; a failed run is always undone.
  @MainActor func finalize(_ error: Error?) async {
    let result = await protection.settle(
      error: error, expected: expectedVersion, requiresTeam: requiresTeam, lifecycle: lifecycle,
      restoreOnInstallerFailure: true)
    guard !published else { return }
    published = true
    if let result { finish(with: result) } else { finish() }
  }

  override func finish() {
    protection.discard()
    super.finish()
    Task { @MainActor in self.protection.reopenIfQuit(self.lifecycle) }
  }
}
