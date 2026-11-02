// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Combine
import ServiceManagement
import SwiftUI
import UserNotifications

/// A macOS permission Updater can use, with the System Settings pane that grants it.
enum PermissionKind: String, CaseIterable, Identifiable {
  case appManagement
  case backgroundItem
  case notifications
  case fullDiskAccess

  var id: String { rawValue }

  /// The failed outcome's `needsPermission(kind:)` that this row fixes. "administrator" has no
  /// Settings pane: it stays the brew command hand-off.
  init?(outcomeKind: String) {
    guard outcomeKind == Self.appManagement.rawValue else { return nil }
    self = .appManagement
  }

  var title: String {
    switch self {
    case .appManagement: "App Management"
    case .backgroundItem: "Update helper"
    case .notifications: "Notifications"
    case .fullDiskAccess: "Full Disk Access (optional)"
    }
  }

  var explanation: String {
    switch self {
    case .appManagement:
      "Needed to replace apps from other developers. macOS doesn't report it, so it shows as not granted only after an update was refused."
    case .backgroundItem:
      "The background item that installs App Store updates. Approve it under Login Items."
    case .notifications:
      "Tells you when new updates appear. Updater asks after its first background check."
    case .fullDiskAccess:
      "Only needed to watch folders macOS protects, such as another user's Applications folder."
    }
  }

  var settingsURL: URL {
    let pane =
      switch self {
      case .appManagement: "com.apple.preference.security?Privacy_AppBundles"
      case .backgroundItem: "com.apple.LoginItems-Settings.extension"
      case .notifications:
        "com.apple.Notifications-Settings.extension?id="
          + (Foundation.Bundle.main.bundleIdentifier ?? "com.juniornkanabassi.Updater")
      case .fullDiskAccess: "com.apple.preference.security?Privacy_AllFiles"
      }
    return URL(string: "x-apple.systempreferences:" + pane)!
  }
}

enum PermissionState: Equatable {
  case granted
  case notGranted
  case unknown

  var title: String {
    switch self {
    case .granted: "Granted"
    case .notGranted: "Not granted"
    case .unknown: "Unknown"
    }
  }
}

/// Live permission states from injectable probes, so tests never touch the real system.
@MainActor
final class PermissionsViewModel: ObservableObject {
  typealias Probe = @MainActor () async -> PermissionState

  @Published private(set) var states = [PermissionKind: PermissionState]()
  private let probes: [PermissionKind: Probe]
  private let workspace: any ApplicationWorkspace

  init(
    probes: [PermissionKind: Probe] = PermissionsViewModel.liveProbes,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared
  ) {
    self.probes = probes
    self.workspace = workspace
  }

  func state(of kind: PermissionKind) -> PermissionState { states[kind] ?? .unknown }

  func refresh() async {
    for kind in PermissionKind.allCases {
      states[kind] = await probes[kind]?() ?? .unknown
    }
  }

  func openSettings(for kind: PermissionKind) {
    workspace.open(kind.settingsURL)
  }

  static let liveProbes: [PermissionKind: Probe] = [
    .appManagement: { appManagementState(latest: UpdateHistoryStore.shared.latestEntries()) },
    .backgroundItem: {
      helperState(SMAppService.daemon(plistName: UpdateInstallerIdentity.daemon + ".plist").status)
    },
    .notifications: {
      notificationState(
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    },
    .fullDiskAccess: {
      // TCC's own database opens only with Full Disk Access; nothing is read from it.
      let descriptor = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
      if descriptor >= 0 { close(descriptor) }
      return descriptor >= 0 ? .granted : .notGranted
    },
  ]

  /// macOS has no query for App Management; a refused replacement still on record says no.
  static func appManagementState(latest entries: [UpdateHistoryEntry]) -> PermissionState {
    entries.contains { $0.outcome == .needsPermission(kind: PermissionKind.appManagement.rawValue) }
      ? .notGranted : .unknown
  }

  static func helperState(_ status: SMAppService.Status) -> PermissionState {
    switch status {
    case .enabled: .granted
    case .requiresApproval, .notRegistered: .notGranted
    case .notFound: .unknown
    @unknown default: .unknown
    }
  }

  static func notificationState(_ status: UNAuthorizationStatus) -> PermissionState {
    switch status {
    case .authorized, .provisional, .ephemeral: .granted
    case .denied: .notGranted
    case .notDetermined: .unknown
    @unknown default: .unknown
    }
  }
}

struct PermissionsSettingsView: View {
  @StateObject private var model = PermissionsViewModel()

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element) { index, kind in
          if index > 0 { Divider() }
          row(for: kind)
        }
      }
      .padding(10)
    }
    .padding(20)
    .task { await model.refresh() }
    // States change in System Settings, so re-read them whenever Updater comes back.
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in Task { await model.refresh() } }
  }

  private func row(for kind: PermissionKind) -> some View {
    let state = model.state(of: kind)
    return HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Text(kind.title)
          Text(state.title)
            .font(.caption)
            .foregroundStyle(
              state == .granted ? .green : state == .notGranted ? .orange : .secondary)
        }
        Text(kind.explanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(kind.title), \(state.title)")
      .accessibilityHint(kind.explanation)

      Button("Open Settings") { model.openSettings(for: kind) }
        .accessibilityLabel("Open System Settings for \(kind.title)")
    }
  }
}
