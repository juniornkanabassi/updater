// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Runs `brew upgrade --cask <token>` for a cask that owns exactly this bundle, with the
/// same protection as Sparkle and the App Store: quit first, Updater's own clone, full
/// verification of the exact URL afterwards, and the clone restored on failure.
final class HomebrewUpgradeOperation: UpdateOperation, @unchecked Sendable {
  private let token: String
  private let protection: ExternalInstallGuard
  var homebrew = Homebrew.shared
  var lifecycle = AppLifecycle.live
  /// False only for ad-hoc signed test fixtures.
  var requiresTeam = true
  @MainActor private var published = false

  /// Every brew invocation shares one lock, whichever app it updates.
  override var lockKey: String { "homebrew" }

  init(app: App.Bundle, token: String, expectedVersion: Version?) {
    self.token = token
    protection = ExternalInstallGuard(target: app.fileURL)
    super.init(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
    self.expectedVersion = expectedVersion
  }

  override func execute() {
    super.execute()
    Task { @MainActor in
      guard !self.isCancelled else { return self.finish() }
      // Recheck ownership with a fresh brew scan: brew must still own exactly this URL and
      // nothing else, and must not need sudo.
      let cask = try? await self.homebrew.owningCask(of: self.appIdentifier, fresh: true)
      guard let cask, cask.token == self.token, cask.apps.count == 1, !cask.needsAdministrator
      else {
        self.outcomeOverride = .handedOff
        return self.finish()
      }
      guard !self.isCancelled else { return self.finish() }
      do {
        // The cask's own quit stanza may also run; Updater's bounded quit comes first.
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
      // From here brew may change the app: no cancel.
      do { try self.beginCommit() } catch { return await self.finalize(nil) }
      self.progressState = .installing
      do {
        _ = try await self.homebrew.upgrade(self.token)
        await self.finalize(nil)
      } catch {
        await self.finalize(error)
      }
    }
  }

  @MainActor func finalize(_ error: Error?) async {
    // A failed brew run is undone whatever it left behind.
    let result = await protection.settle(
      error: error, expected: expectedVersion, requiresTeam: requiresTeam, lifecycle: lifecycle,
      restoreIfChanged: true)
    guard !published else { return }
    published = true
    if let result { finish(with: result) } else { finish() }
  }

  override func finish() {
    // Exits before brew ran: the target is untouched.
    protection.discard()
    super.finish()
    Task { @MainActor in self.protection.reopenIfQuit(self.lifecycle) }
  }
}
