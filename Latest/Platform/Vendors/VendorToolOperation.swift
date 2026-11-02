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
  var lifecycle = AppLifecycle.live
  /// False only for ad-hoc signed test fixtures.
  var requiresTeam = true
  @MainActor private var published = false

  override var lockKey: String { lock }

  init(
    app: App.Bundle, lock: String, expectedVersion: Version?,
    inScope: @escaping @Sendable () async -> Bool,
    install: @escaping @Sendable () async throws -> Void
  ) {
    self.lock = lock
    self.inScope = inScope
    self.install = install
    protection = ExternalInstallGuard(target: app.fileURL)
    super.init(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
    self.expectedVersion = expectedVersion
  }

  override func execute() {
    super.execute()
    Task { @MainActor in
      guard !self.isCancelled else { return self.finish() }
      guard await self.inScope() else {
        self.outcomeOverride = .handedOff
        return self.finish()
      }
      do {
        self.protection.noteQuit(
          wasRunning: try await self.lifecycle.quit(
            at: self.appIdentifier,
            name: self.appIdentifier.deletingPathExtension().lastPathComponent))
      } catch is CancellationError {
        return self.finish()
      } catch {
        return self.finish(with: error)
      }
      do { try self.protection.takeClone() } catch {
        self.outcomeOverride = .handedOff
        return self.finish()
      }
      do { try self.beginCommit() } catch { return await self.finalize(nil) }
      self.progressState = .installing
      do {
        try await self.install()
        await self.finalize(nil)
      } catch VendorToolError.stillWorking {
        // Restoring now could race the vendor's installer: keep the original aside, change
        // nothing, and do not reopen.
        let kept = self.protection.abandon()
        self.published = true
        self.finish(with: ReplacementError.outcomeUnknown(kept?.path ?? self.appIdentifier.path))
      } catch {
        await self.finalize(error)
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
