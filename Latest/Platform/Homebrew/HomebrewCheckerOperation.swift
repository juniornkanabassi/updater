//
//  HomebrewCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 12.03.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Foundation

/// Async update checking via Homebrew. The historical type name is retained to
/// avoid needless source churn, but checking is no longer an Operation.
final class HomebrewCheckerOperation: Sendable {

  private let bundle: App.Bundle
  private let repository: UpdateRepository?
  private let homebrew: Homebrew?

  init(with bundle: App.Bundle, repository: UpdateRepository?, homebrew: Homebrew? = .shared) {
    self.bundle = bundle
    self.repository = repository
    self.homebrew = homebrew
  }

  /// A cask owns the app only if its installed app artifact is exactly this bundle. Then
  /// Updater runs brew itself; otherwise the public catalogue route below applies.
  private func ownedUpdate() async -> App.Update? {
    guard let homebrew, let cask = try? await homebrew.owningCask(of: bundle.fileURL) else {
      return nil
    }
    let current = (try? await homebrew.outdatedVersion(of: cask.token)) ?? nil
    let remote = current.map(VersionParser.parse(combinedVersionNumber:)) ?? bundle.version
    let action: App.Update.Action
    if cask.apps.count == 1, !cask.needsAdministrator {
      // Cask versions can carry a build suffix the bundle lacks; check the version number.
      let expected = Version(versionNumber: remote.versionNumber, buildNumber: nil)
      action = .builtIn { app in
        UpdateQueue.shared.addOperation(
          HomebrewUpgradeOperation(app: app, token: cask.token, expectedVersion: expected))
      }
    } else {
      // Sudo casks and casks with several apps are not installed by Updater in this round.
      action = .external(label: "Terminal") { _ in
        Task { @MainActor in
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
    if let owned = await ownedUpdate() { return owned }
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
    let downloadSource = AppDownloadSource.homebrewSource(for: bundle, token: entry.token)
    let action: App.Update.Action
    if let downloadSource {
      action = .builtIn { app in
        UpdateQueue.shared.addOperation(
          AppDownloadUpdateOperation(app: app, source: downloadSource))
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
      source: downloadSource == nil ? .homebrew : .directDownload,
      date: nil,
      releaseNotes: releaseNotes,
      updateAction: action
    )
  }
}
