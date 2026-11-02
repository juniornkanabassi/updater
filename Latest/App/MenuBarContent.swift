// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

/// The menu bar item's state: the waiting updates and what Update All would do.
@MainActor
final class MenuBarViewModel: ObservableObject {
  nonisolated static let showsItemKey = "ShowsMenuBarItem"

  @Published private(set) var updates = [App]()
  /// What the last check found, for the line shown when nothing is waiting.
  @Published private(set) var summary = UpdateStatusSummary()
  /// How many apps Update All would start now (the window's toolbar shows it too).
  @Published private(set) var updateAllCount = 0
  var canUpdateAll: Bool { updateAllCount > 0 }

  private let appProvider: any AppProviding
  private let settings: any AppListSettingsProviding
  private let updateAllCandidates: () -> [App]
  private var apps = [App]()
  private var observations = [Task<Void, Never>]()
  private var observers = [NSObjectProtocol]()
  private var manualAppStoreUpdates: Bool?

  init(
    appProvider: any AppProviding,
    settings: any AppListSettingsProviding,
    updateAllCandidates: @escaping () -> [App]
  ) {
    self.appProvider = appProvider
    self.settings = settings
    self.updateAllCandidates = updateAllCandidates
  }

  nonisolated static var showsItem: Bool {
    UserDefaults.standard.object(forKey: showsItemKey) as? Bool ?? true
  }

  /// Recomputes on new app lists, on preference changes and whenever a job starts or ends
  /// (cancelled and declined ones too), so the menu never needs a manual refresh.
  func startObserving() {
    guard observations.isEmpty else { return }
    observations = [
      Task { [weak self, appProvider] in
        for await update in appProvider.updates() {
          guard !Task.isCancelled, let self else { break }
          self.refresh(with: update.apps)
        }
      },
      Task { [weak self, settings] in
        for await _ in settings.updates() {
          guard !Task.isCancelled, let self else { break }
          self.refresh()
        }
      },
    ]
    let center = NotificationCenter.default
    observers = [
      center.addObserver(forName: .latestUpdateQueueDidChange, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
      },
      // "Always open App Store" (the helper sheet's toggle, reset when the helper is enabled)
      // decides whether App Store apps join Update All; it is a plain defaults key.
      center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.refreshIfManualPreferenceChanged() }
      },
    ]
    manualAppStoreUpdates = AppStoreUpdateSettings.alwaysPerformManualUpdates.active
  }

  func stopObserving() {
    observations.forEach { $0.cancel() }
    observations.removeAll()
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  private func refreshIfManualPreferenceChanged() {
    let current = AppStoreUpdateSettings.alwaysPerformManualUpdates.active
    guard current != manualAppStoreUpdates else { return }
    manualAppStoreUpdates = current
    refresh()
  }

  func refresh(with apps: [App]? = nil) {
    if let apps { self.apps = apps }
    updates = UpdateNotificationController.waitingUpdates(
      in: self.apps, includeExternal: settings.includeAppsWithLimitedSupport)
    updateAllCount = updateAllCandidates().count
    summary = UpdateStatusSummary(apps: self.apps)
  }
}

/// Opens the main window from places without a SwiftUI environment (notifications, menu).
@MainActor
enum MainWindow {
  static var openWindow: OpenWindowAction?

  static func show() {
    NSApp.activate()
    openWindow?(id: "main")
  }
}

/// Keeps the scene's `openWindow` action for `MainWindow`.
struct MainWindowOpenerCapture: ViewModifier {
  @Environment(\.openWindow) private var openWindow

  func body(content: Content) -> some View {
    content.onAppear { MainWindow.openWindow = openWindow }
  }
}

/// A status item draws only plain images and text, so the label stays one image or one
/// image-and-title Label, with no stacks or modifiers that could leave it empty.
struct MenuBarLabel: View {
  @ObservedObject var model: MenuBarViewModel

  var body: some View {
    let count = model.updates.count
    if count == 0 {
      Image("MenuBarIcon", label: Text("Updater"))
    } else {
      Label {
        Text("\(count)")
      } icon: {
        Image(
          "MenuBarIcon",
          label: Text(
            count == 1 ? "Updater, 1 update available" : "Updater, \(count) updates available"))
      }
      .labelStyle(.titleAndIcon)
    }
  }
}

struct MenuBarContentView: View {
  @ObservedObject var model: MenuBarViewModel
  @ObservedObject var checking: UpdateCheckingService
  let select: (App) -> Void

  var body: some View {
    Group {
      let ready = model.updates.filter { $0.capability.isAutomatic }
      let needsYou = model.updates.filter { !$0.capability.isAutomatic }
      if model.updates.isEmpty {
        Text(
          checking.isRunning
            ? "Checking for updates…"
            : model.summary.isAllCurrent ? "Everything is up to date" : model.summary.text)
      }
      // Plain headers keep the menu free of the extra separators SwiftUI adds around Sections.
      if !ready.isEmpty {
        Text("Ready to Update")
        rows(ready)
      }
      if !needsYou.isEmpty {
        if !ready.isEmpty { Divider() }
        Text("Needs You")
        rows(needsYou)
      }
      Divider()
      Button(model.updateAllCount > 0 ? "Update All (\(model.updateAllCount))" : "Update All") {
        checking.updateAll()
      }
      .disabled(!model.canUpdateAll)
      .accessibilityHint("Installs every update under Ready to Update")
      Button("Check Now") { checking.checkForUpdates() }
        .disabled(checking.isRunning)
      Divider()
      Button("Open Updater") { MainWindow.show() }
      Button("Quit Updater") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .modifier(MainWindowOpenerCapture())
  }

  private func rows(_ apps: [App]) -> some View {
    ForEach(apps, id: \.identifier) { app in
      Button(Self.title(for: app)) {
        select(app)
        MainWindow.show()
      }
      .accessibilityLabel(Self.title(for: app).replacingOccurrences(of: "→", with: "to"))
    }
  }

  /// "Goodnotes  7.1.32 → 7.1.34" for installs; hand-offs add where they go.
  static func title(for app: App) -> String {
    let versions = app.versionSummary
    let base = versions.isEmpty ? app.name : "\(app.name)  \(versions)"
    return app.capability.isAutomatic
      ? base : "\(base)  ·  \(SidebarUpdateActionTitle.text(for: app))"
  }
}

/// With the menu bar item showing, closing the last window leaves Updater running there.
final class UpdaterAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !MenuBarViewModel.showsItem
  }
}
