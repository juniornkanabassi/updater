// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Vendor routes come first when the vendor manages this exact app: Microsoft AutoUpdate,
/// "Relaunch Chrome" for Chrome, and a Creative Cloud check for Adobe apps.
struct VendorAdapters: Sendable {
  var microsoft: MicrosoftAutoUpdate?
  var google: GoogleChrome?
  var adobe: AdobeCreativeCloud?
  static let live = VendorAdapters(microsoft: .shared, google: .shared, adobe: .live)
  static let none = VendorAdapters()

  /// nil when no vendor tool manages this app. Throws when the vendor's own source could not
  /// be read, so the row shows a check failure instead of pretending the app is current.
  func update(for bundle: App.Bundle) async throws -> App.Update? {
    if let microsoft, await microsoft.isInstalled {
      let appID: String?
      do {
        appID = try await microsoft.appID(for: bundle.fileURL)
      } catch {
        // Unreadable MAU: a Microsoft app outside the App Store reports it; others go on.
        if bundle.bundleIdentifier.hasPrefix("com.microsoft."), bundle.source != .appStore {
          throw error
        }
        appID = nil
      }
      if let appID {
        let remote = try await microsoft.availableVersion(of: appID)
        return Self.vendorUpdate(
          bundle, remote: remote, lock: "msupdate",
          waitingStatus: "Waiting for Microsoft AutoUpdate to finish",
          vendorIsIdle: { await microsoft.assistantIsIdle() }
        ) { app in
          (try? await microsoft.appID(for: app, fresh: true)) == appID
        } install: {
          try await microsoft.install(appID)
        }
      }
    }
    if let google, bundle.bundleIdentifier == GoogleChrome.bundleIdentifier {
      let remote = try await google.availableVersion()
      return App.Update(
        app: bundle, remoteVersion: Version(versionNumber: remote, buildNumber: nil),
        minimumOSVersion: nil, source: .vendor, date: nil, releaseNotes: nil,
        updateAction: .relaunch { app in
          UpdateQueue.shared.addOperation(ChromeRelaunchOperation(app: app))
        })
    }
    if let adobe, adobe.manages(bundle) {
      // Whether an update exists is only known to Creative Cloud: offer the check, claim none.
      return App.Update(
        app: bundle, remoteVersion: bundle.version, minimumOSVersion: nil, source: .vendor,
        date: nil, releaseNotes: nil,
        updateAction: .external(label: "Creative Cloud") { _ in
          Task { @MainActor in adobe.open(adobe.app) }
        }, availabilityUnknown: true)
    }
    return nil
  }

  /// The vendor's own version claim is not used to accept the result: vendors stage
  /// rollouts, so success is a newer, verified bundle on disk.
  private static func vendorUpdate(
    _ bundle: App.Bundle, remote: String?, lock: String, waitingStatus: String,
    vendorIsIdle: @escaping @Sendable () async -> Bool,
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
            install: install, vendorIsIdle: vendorIsIdle, waitingStatus: waitingStatus))
      })
  }
}
