//
//  HomebrewCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 12.03.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import AppKit

/// Async update checking via Homebrew. The historical type name is retained to
/// avoid needless source churn, but checking is no longer an Operation.
final class HomebrewCheckerOperation: Sendable {

  private let bundle: App.Bundle
  private let repository: UpdateRepository?
  private let homebrew: Homebrew?
  private let catalogueCheck: CatalogueInstallCheck

  init(
    with bundle: App.Bundle, repository: UpdateRepository?, homebrew: Homebrew? = .shared,
    catalogueCheck: CatalogueInstallCheck = .live
  ) {
    self.catalogueCheck = catalogueCheck
    self.bundle = bundle
    self.repository = repository
    self.homebrew = homebrew
  }

  /// A cask owns the app only if its installed app artifact is exactly this bundle. Then
  /// brew is the update route, whatever other source the bundle has; Updater runs it only
  /// when the upgrade provably stays on this copy, and otherwise hands off with the command.
  static func ownedUpdate(
    for bundle: App.Bundle, homebrew: Homebrew?, scope: HomebrewScope = .live
  ) async -> App.Update? {
    guard let homebrew, let cask = try? await homebrew.owningCask(of: bundle.fileURL) else {
      return nil
    }
    let current = (try? await homebrew.outdatedVersion(of: cask.token)) ?? nil
    let remote = current.map(VersionParser.parse(combinedVersionNumber:)) ?? bundle.version
    let action: App.Update.Action
    // `version :latest` casks cannot be checked against a version afterwards.
    if current != "latest", scope.installs(cask, at: bundle.fileURL) {
      // Cask versions can carry a build suffix the bundle lacks; check the version number.
      let expected = Version(versionNumber: remote.versionNumber, buildNumber: nil)
      action = .builtIn { app in
        UpdateQueue.shared.addOperation(
          HomebrewUpgradeOperation(app: app, token: cask.token, expectedVersion: expected))
      }
    } else {
      // Anything outside the allow list (admin steps, scripts, several apps, hooks reaching
      // other copies, :latest): the user runs brew in Terminal with the command copied.
      let command = adminCommand(for: cask.token)
      action = .external(label: handOffLabel) { _ in
        Task { @MainActor in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(command, forType: .string)
          MacApplicationWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        }
      }
    }
    return App.Update(
      app: bundle, remoteVersion: remote, minimumOSVersion: nil, source: .homebrew, date: nil,
      releaseNotes: ReleaseNotesSourceCatalog.releaseNotes(for: bundle, remoteVersion: remote),
      updateAction: action)
  }

  /// Shown as "Open Terminal (brew command copied)".
  static let handOffLabel = "Terminal (brew command copied)"

  static func adminCommand(for token: String) -> String { "brew upgrade --cask \(token)" }

  func check() async throws -> App.Update {
    try Task.checkCancellation()
    if bundle.bundleIdentifier == "md.obsidian" {
      return try await ObsidianUpdate.check(bundle)
    }
    if bundle.bundleIdentifier == "com.zed-industries.delta" {
      let source = AppDownloadSource.delta
      let release = try await source.release()
      return App.Update(
        app: bundle, remoteVersion: release.version, minimumOSVersion: nil,
        source: .directDownload, date: nil,
        releaseNotes: .changelog(
          urls: [URL(string: "https://delta.dev/docs/whats-in-the-latest")!],
          versionPrefix: release.version.versionNumber, allowsLatestFallback: true,
          fallbackHTML: nil),
        updateAction: .builtIn { app in
          UpdateQueue.shared.addOperation(AppDownloadUpdateOperation(app: app, source: source))
        })
    }
    if let owned = await Self.ownedUpdate(for: bundle, homebrew: homebrew) { return owned }
    guard let repository else {
      throw LatestError.updateInfoUnavailable
    }

    guard let entry = await repository.entry(for: bundle) else {
      throw LatestError.updateInfoUnavailable
    }
    try Task.checkCancellation()
    let version = entry.version
    let releaseNotes =
      ReleaseNotesSourceCatalog.releaseNotes(
        for: bundle,
        remoteVersion: version,
        allowNameFallback: false
      ) ?? entry.releaseNotes
    // Round 5b: install from the catalogue only when identity, shape and scope all hold.
    let plan = await catalogueCheck.plan(
      for: bundle,
      candidateTokens: await repository.caskTokens(withBundleIdentifier: bundle.bundleIdentifier),
      matchedToken: entry.token, catalogueVersion: version)
    let action: App.Update.Action
    if let plan {
      let job = CatalogueJob(token: plan.token, minimumVersion: version, check: catalogueCheck)
      action = .builtIn { app in
        UpdateQueue.shared.addOperation(AppDownloadUpdateOperation(app: app, catalogue: job))
      }
    } else {
      action = .external(label: bundle.name) { app in
        Task { @MainActor in MacApplicationWorkspace.shared.openApplication(at: app.fileURL) }
      }
    }
    return App.Update(
      app: bundle,
      remoteVersion: version,
      minimumOSVersion: entry.minimumOSVersion,
      source: plan == nil ? .homebrew : .directDownload,
      date: nil,
      releaseNotes: releaseNotes,
      updateAction: action
    )
  }
}
