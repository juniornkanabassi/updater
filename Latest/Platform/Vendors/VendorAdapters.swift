// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Vendor routes come first when the vendor manages this exact app: Microsoft AutoUpdate,
/// "Relaunch Chrome" for Chrome, and a Creative Cloud check for Adobe apps.
struct VendorAdapters: Sendable {
  var microsoft: MicrosoftAutoUpdate?
  var google: GoogleChrome?
  var adobe: AdobeCreativeCloud?
  /// The shared folder walk for other copies of a bundle ID.
  var copies: @Sendable (String) throws -> Set<String> = { try AppStoreInstallGate.live.walk($0) }
  /// The walk's time limit; past it the app is treated as unsafe and handed off.
  var copiesDeadline: Duration = .seconds(10)
  static let live = VendorAdapters(microsoft: .shared, google: .shared, adobe: .live)
  static let none = VendorAdapters()

  /// nil when no vendor tool manages this app. Throws when the vendor's own source could not
  /// be read, so the row shows a check failure instead of pretending the app is current.
  func update(for bundle: App.Bundle) async throws -> App.Update? {
    if let microsoft, await microsoft.isInstalled {
      let registration: MicrosoftAutoUpdate.Registration?
      do {
        registration = try await microsoft.registration(for: bundle.fileURL)
      } catch {
        // Unreadable MAU: a Microsoft app outside the App Store reports it; others go on.
        if bundle.bundleIdentifier.hasPrefix("com.microsoft."), bundle.source != .appStore {
          throw error
        }
        registration = nil
      }
      if let registration {
        let remote = try await microsoft.availableVersion(of: registration.identifier)
        guard case .unique(let appID) = registration,
          await Self.isOnlyCopy(
            bundle.fileURL, bundleIdentifier: bundle.bundleIdentifier, copies: copies,
            deadline: copiesDeadline)
        else {
          // `msupdate --install --apps <ID>` has no path: with two copies it could update either.
          return Self.handOff(bundle, remote: remote, label: "Microsoft AutoUpdate") {
            Task { @MainActor in
              MacApplicationWorkspace.shared.openApplication(
                at: microsoft.tool.deletingLastPathComponent().deletingLastPathComponent()
                  .deletingLastPathComponent())
            }
          }
        }
        return Self.vendorUpdate(
          bundle, remote: remote, lock: "msupdate",
          waitingStatus: "Waiting for Microsoft AutoUpdate to finish",
          vendorIsIdle: { await microsoft.assistantIsIdle() }
        ) { [copies, copiesDeadline] app in
          await Self.microsoftScope(
            microsoft, appID: appID, app: app, bundleIdentifier: bundle.bundleIdentifier,
            copies: copies, deadline: copiesDeadline)
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
        // A user-initiated hand-off: never part of Update All.
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

  /// Checked when the capability is decided, and again after the quit and the clone, right
  /// before msupdate runs.
  static func microsoftScope(
    _ microsoft: MicrosoftAutoUpdate, appID: String, app: URL, bundleIdentifier: String,
    copies: @escaping @Sendable (String) throws -> Set<String>, deadline: Duration = .seconds(10)
  ) async -> Bool {
    guard (try? await microsoft.registration(for: app, fresh: true)) == .unique(appID) else {
      return false
    }
    return await isOnlyCopy(
      app, bundleIdentifier: bundleIdentifier, copies: copies, deadline: deadline)
  }

  /// No other copy of the bundle ID on disk. The walk runs on its own thread under the
  /// shared bounded wrapper: unreadable or too slow means unsafe.
  static func isOnlyCopy(
    _ app: URL, bundleIdentifier: String,
    copies: @escaping @Sendable (String) throws -> Set<String>,
    deadline: Duration
  ) async -> Bool {
    let selected = Homebrew.canonical(app)
    return await AppStoreInstallGate.answer(within: deadline) { answer in
      DispatchQueue.global(qos: .userInitiated).async {
        guard let found = try? copies(bundleIdentifier) else { return answer(false) }
        answer(found.allSatisfy { Homebrew.canonical(URL(fileURLWithPath: $0)) == selected })
      }
    }
  }

  private static func handOff(
    _ bundle: App.Bundle, remote: String?, label: String, open: @escaping @Sendable () -> Void
  ) -> App.Update {
    App.Update(
      app: bundle,
      remoteVersion: remote.map { Version(versionNumber: $0, buildNumber: nil) } ?? bundle.version,
      minimumOSVersion: nil, source: .vendor, date: nil, releaseNotes: nil,
      updateAction: .external(label: label) { _ in open() })
  }
}
