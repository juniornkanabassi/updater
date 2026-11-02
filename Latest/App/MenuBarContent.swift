// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import SwiftUI

/// The menu bar item's state: the waiting updates and what Update All would do.
@MainActor
final class MenuBarViewModel: ObservableObject {
  nonisolated static let showsItemKey = "ShowsMenuBarItem"

  @Published private(set) var updates = [App]()
  @Published private(set) var canUpdateAll = false

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
    canUpdateAll = !updateAllCandidates().isEmpty
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
      if model.updates.isEmpty {
        Text(checking.isRunning ? "Checking for updates…" : "No updates available")
      } else {
        ForEach(model.updates, id: \.identifier) { app in
          Button(Self.title(for: app)) {
            select(app)
            MainWindow.show()
          }
          .accessibilityLabel(Self.title(for: app).replacingOccurrences(of: "→", with: "to"))
        }
      }
      Divider()
      Button("Update All") { checking.updateAll() }
        .disabled(!model.canUpdateAll)
        .accessibilityHint("Installs every update Updater can install itself")
      Button("Check Now") { checking.checkForUpdates() }
        .disabled(checking.isRunning)
      Divider()
      Button("Open Updater") { MainWindow.show() }
      Button("Quit Updater") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
    }
    .modifier(MainWindowOpenerCapture())
  }

  static func title(for app: App) -> String {
    guard let versions = app.localizedVersionInformation, let available = versions.rawNew else {
      return app.name
    }
    return "\(app.name)  \(versions.rawCurrent) → \(available)"
  }
}

/// With the menu bar item showing, closing the last window leaves Updater running there.
final class UpdaterAppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    !MenuBarViewModel.showsItem
  }
}
