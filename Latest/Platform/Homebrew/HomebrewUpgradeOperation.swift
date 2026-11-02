// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit

/// Whether `brew upgrade` of a cask stays on the selected copy: both definitions are on the
/// allow list, the one app is this bundle, and `uninstall quit:` names only this bundle's ID,
/// which has no other copy on disk or running.
struct HomebrewScope: Sendable {
  var copies: @Sendable (String) throws -> Set<String> = { try AppStoreInstallGate.live.walk($0) }
  var runningPaths: @Sendable (String) -> [String] = { identifier in
    NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
      .compactMap { $0.bundleURL.map(Homebrew.canonical) }
  }
  static let live = HomebrewScope()

  func installs(_ cask: InstalledCask, at app: URL) -> Bool {
    let selected = Homebrew.canonical(app)
    // The upgrade removes the installed target and installs the current one: both must be
    // this bundle, so a moved target or an unresolvable one hands off.
    guard cask.allowListed, cask.apps == [selected], cask.installedApp == selected else {
      return false
    }
    guard !cask.quits.isEmpty else { return true }
    guard
      let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
      let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let identifier = info["CFBundleIdentifier"] as? String,
      cask.quits.allSatisfy({ $0 == identifier }),
      let found = try? copies(identifier)
    else { return false }
    return found.allSatisfy { Homebrew.canonical(URL(fileURLWithPath: $0)) == selected }
      && runningPaths(identifier).allSatisfy { $0 == selected }
  }
}

/// Runs `brew upgrade --cask <token>` for a cask that owns exactly this bundle, with the
/// same protection as Sparkle and the App Store: quit first, Updater's own clone, full
/// verification of the exact URL afterwards, and the clone restored on failure.
final class HomebrewUpgradeOperation: UpdateOperation, @unchecked Sendable {
  private let token: String
  private let protection: ExternalInstallGuard
  var homebrew = Homebrew.shared
  var scope = HomebrewScope.live
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
      guard await self.stillInScope() else { return self.handOffBeforeChanges() }
      guard !self.isCancelled else { return self.finish() }
      // Download first, with the app untouched and still usable; only then quit, so it
      // cannot be reopened during a long download before brew replaces it.
      do { try await self.homebrew.fetch(self.token) } catch { return self.finish(with: error) }
      // A download can take long: definitions, targets and other copies are checked again
      // right before anything changes.
      guard await self.stillInScope() else { return self.handOffBeforeChanges() }
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
      // brew's Caskroom record is cloned with the app so a rollback leaves them agreeing.
      let caskroom = await self.homebrew.caskroom(of: self.token)
      do { try self.protection.takeClone(companions: [caskroom].compactMap { $0 }) } catch {
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

  /// A fresh brew scan: brew still owns exactly this URL and the upgrade stays in scope.
  @MainActor private func stillInScope() async -> Bool {
    guard let cask = try? await homebrew.owningCask(of: appIdentifier, fresh: true) else {
      return false
    }
    return cask.token == token && scope.installs(cask, at: appIdentifier)
  }

  @MainActor private func handOffBeforeChanges() {
    outcomeOverride = .handedOff
    finish()
  }

  @MainActor func finalize(_ error: Error?) async {
    // A failed brew run is undone whatever it left behind.
    let result = await protection.settle(
      error: error, expected: expectedVersion, requiresTeam: requiresTeam, lifecycle: lifecycle,
      restoreOnInstallerFailure: true, acceptUnchanged: false)
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
