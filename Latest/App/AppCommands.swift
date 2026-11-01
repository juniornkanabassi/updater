//
//  AppCommands.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

@MainActor
protocol UpdateCheckingCommandHandling: AnyObject {
  func checkForUpdates()
  func updateAll()
}

extension UpdateCheckingService: UpdateCheckingCommandHandling {}

@MainActor
final class AppCommands {
  private enum ExternalURL {
    static let website = URL(string: "https://github.com/Ertyoii/Latest")
  }

  private let updateCheckingService: UpdateCheckingCommandHandling
  private let updatesListViewModel: UpdatesListViewModel
  private let searchFocusController: SearchFocusController
  private let settings: any AppListSettingsProviding
  private let workspace: any ApplicationWorkspace

  init(
    updateCheckingService: UpdateCheckingCommandHandling,
    updatesListViewModel: UpdatesListViewModel,
    searchFocusController: SearchFocusController,
    settings: any AppListSettingsProviding = AppListSettings.shared,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared
  ) {
    self.updateCheckingService = updateCheckingService
    self.updatesListViewModel = updatesListViewModel
    self.searchFocusController = searchFocusController
    self.settings = settings
    self.workspace = workspace
  }

  func reload() {
    updateCheckingService.checkForUpdates()
  }

  func updateAll() {
    updateCheckingService.updateAll()
  }

  var selectedApp: App? {
    updatesListViewModel.selectedApp
  }

  var canUpdateSelectedApp: Bool {
    guard let selectedApp else { return false }
    return selectedApp.updateAvailable && !updatesListViewModel.updating.isUpdating(selectedApp)
  }

  var canOpenSelectedApp: Bool {
    selectedApp != nil
  }

  func updateSelectedApp() {
    guard let selectedApp, canUpdateSelectedApp else { return }
    updatesListViewModel.update(selectedApp)
  }

  func openSelectedApp() {
    guard let selectedApp else { return }
    updatesListViewModel.open(selectedApp)
  }

  func revealSelectedAppInFinder() {
    guard let selectedApp else { return }
    updatesListViewModel.revealInFinder(selectedApp)
  }

  func focusSearch() {
    searchFocusController.focus()
  }

  func visitWebsite() {
    guard let url = ExternalURL.website else { return }
    workspace.open(url)
  }

  func changeSortOrder(_ order: AppListSettings.SortOptions) {
    settings.sortOrder = order
  }

  var sortOrder: AppListSettings.SortOptions {
    settings.sortOrder
  }

  var showInstalledUpdates: Bool {
    get { settings.showInstalledUpdates }
    set { settings.showInstalledUpdates = newValue }
  }

  var showIgnoredUpdates: Bool {
    get { settings.showIgnoredUpdates }
    set { settings.showIgnoredUpdates = newValue }
  }
}

struct LatestCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let appCommands: AppCommands
  @ObservedObject var updatesViewModel: UpdatesListViewModel
  @ObservedObject var updateCheckingService: UpdateCheckingService
  let appUpdateController: AppUpdateController

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button("About Latest") {
        openWindow(id: "about")
      }
    }

    CommandMenu("Updates") {
      Button("View Latest Releases…") {
        appUpdateController.checkForAppUpdates()
      }

      Divider()

      Button("Check Installed Apps") {
        appCommands.reload()
      }
      .keyboardShortcut("r")
      .disabled(updateCheckingService.isRunning)

      Button("Update All") {
        appCommands.updateAll()
      }
      .keyboardShortcut("u", modifiers: [.command, .shift])
      .disabled(!updatesViewModel.hasUpdatesAvailable)

      SelectedAppCommandButtons(appCommands: appCommands)
    }

    CommandGroup(after: .textEditing) {
      Button("Find…") {
        appCommands.focusSearch()
      }
      .keyboardShortcut("f")
    }

    CommandMenu("View Options") {
      Menu("Sort By") {
        ForEach(AppListSettings.SortOptions.allCases, id: \.rawValue) { order in
          Button {
            appCommands.changeSortOrder(order)
          } label: {
            if appCommands.sortOrder == order {
              Label(order.displayName, systemImage: "checkmark")
            } else {
              Text(order.displayName)
            }
          }
        }
      }

      Toggle("Show Installed Apps", isOn: showInstalledApps)
        .keyboardShortcut("i")
      Toggle("Show Ignored Apps", isOn: showIgnoredApps)
        .keyboardShortcut("i", modifiers: [.command, .shift])
    }

    CommandGroup(after: .help) {
      Button("Licenses…") {
        openWindow(id: "licenses")
      }

      Button("Latest on GitHub") {
        appCommands.visitWebsite()
      }
    }
  }

  private var showInstalledApps: Binding<Bool> {
    Binding(
      get: { appCommands.showInstalledUpdates },
      set: { appCommands.showInstalledUpdates = $0 }
    )
  }

  private var showIgnoredApps: Binding<Bool> {
    Binding(
      get: { appCommands.showIgnoredUpdates },
      set: { appCommands.showIgnoredUpdates = $0 }
    )
  }
}

/// Keep per-selection invalidation out of the other menus and commands.
private struct SelectedAppCommandButtons: View {
  let appCommands: AppCommands

  var body: some View {
    Button(updateSelectedTitle) {
      appCommands.updateSelectedApp()
    }
    .keyboardShortcut("u")
    .disabled(!appCommands.canUpdateSelectedApp)

    Divider()

    Button("Open") {
      appCommands.openSelectedApp()
    }
    .keyboardShortcut("o", modifiers: [.command, .shift])
    .disabled(!appCommands.canOpenSelectedApp)

    Button("Show in Finder") {
      appCommands.revealSelectedAppInFinder()
    }
    .keyboardShortcut("r", modifiers: [.command, .shift])
    .disabled(!appCommands.canOpenSelectedApp)
  }

  private var updateSelectedTitle: String {
    guard let app = appCommands.selectedApp else {
      return NSLocalizedString("UpdateAction", comment: "Action to update a given app.")
    }
    if let externalUpdater = app.externalUpdaterName {
      return String(
        format: NSLocalizedString(
          "ExternalUpdateAction",
          comment: "Action to update a given app outside of Latest."
        ),
        externalUpdater
      )
    }
    return NSLocalizedString("UpdateAction", comment: "Action to update a given app.")
  }

}
