// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Vendor tools come first when the vendor's tool manages this exact app: Microsoft
/// AutoUpdate, Google's updater for Chrome, and Creative Cloud (hand-off) for Adobe apps.
struct VendorAdapters: Sendable {
  var microsoft: MicrosoftAutoUpdate?
  var google: GoogleChrome?
  var adobe: AdobeCreativeCloud?
  static let live = VendorAdapters(microsoft: .shared, google: .shared, adobe: .live)
  static let none = VendorAdapters()

  func update(for bundle: App.Bundle) async -> App.Update? {
    if let microsoft, let appID = await microsoft.appID(for: bundle.fileURL) {
      let remote = await microsoft.availableVersion(of: appID)
      return Self.vendorUpdate(bundle, remote: remote, lock: "msupdate") { app in
        await microsoft.appID(for: app, fresh: true) == appID
      } install: {
        try await microsoft.install(appID)
      }
    }
    if let google, bundle.bundleIdentifier == GoogleChrome.bundleIdentifier {
      let remote = await google.availableVersion()
      guard await google.canUpdate(bundle.fileURL) else {
        return Self.handOff(bundle, remote: remote, label: bundle.name) {
          Task { @MainActor in MacApplicationWorkspace.shared.openApplication(at: bundle.fileURL) }
        }
      }
      return Self.vendorUpdate(bundle, remote: remote, lock: "googleUpdater") { app in
        await google.canUpdate(app)
      } install: {
        try await google.install()
      }
    }
    if let adobe, adobe.manages(bundle) {
      // No local record of the version Creative Cloud would offer: no version is invented.
      return Self.handOff(bundle, remote: nil, label: "Creative Cloud") {
        Task { @MainActor in MacApplicationWorkspace.shared.openApplication(at: adobe.app) }
      }
    }
    return nil
  }

  /// The vendor's own version claim is not used to accept the result: vendors stage
  /// rollouts, so success is a newer, verified bundle on disk.
  private static func vendorUpdate(
    _ bundle: App.Bundle, remote: String?, lock: String,
    inScope: @escaping @Sendable (URL) async -> Bool,
    install: @escaping @Sendable () async throws -> Void
  ) -> App.Update {
    App.Update(
      app: bundle,
      remoteVersion: remote.map { Version(versionNumber: $0, buildNumber: nil) } ?? bundle.version,
      minimumOSVersion: nil, source: .vendor, date: nil,
      releaseNotes: nil,
      updateAction: .vendorTool { app in
        UpdateQueue.shared.addOperation(
          VendorToolOperation(
            app: app, lock: lock, expectedVersion: nil, inScope: { await inScope(app.fileURL) },
            install: install))
      })
  }

  private static func handOff(
    _ bundle: App.Bundle, remote: String?, label: String,
    open: @escaping @Sendable () -> Void
  ) -> App.Update {
    App.Update(
      app: bundle,
      remoteVersion: remote.map { Version(versionNumber: $0, buildNumber: nil) } ?? bundle.version,
      minimumOSVersion: nil, source: .vendor, date: nil, releaseNotes: nil,
      updateAction: .external(label: label) { _ in open() })
  }
}
