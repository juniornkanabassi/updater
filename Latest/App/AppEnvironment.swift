//
//  AppEnvironment.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
  let searchFocusController: SearchFocusController
  let updateCheckingService: UpdateCheckingService
  let updatesListViewModel: UpdatesListViewModel
  let settingsViewModel: SettingsViewModel
  let commands: AppCommands
  private var startupTask: Task<Void, Never>?

  init(
    searchFocusController: SearchFocusController = SearchFocusController(),
    settings: any AppListSettingsProviding = AppListSettings.shared,
    coordinator: any UpdateCheckCoordinating = UpdateCheckCoordinator.shared,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared,
    updating: any AppUpdating = AppUpdateService.shared,
    appStoreUpdateService: any AppStoreUpdateServicing = LiveAppStoreUpdateService.shared,
    installHelperService: any InstallHelperServicing = LiveInstallHelperService.shared,
    directoryStoreFactory: @escaping SettingsViewModel.DirectoryStoreFactory = {
      AppDirectoryStore(updateHandler: $0)
    },
    updateCheckingService: UpdateCheckingService? = nil,
    updatesListViewModel: UpdatesListViewModel? = nil,
    settingsViewModel: SettingsViewModel? = nil
  ) {
    let updateCheckingService =
      updateCheckingService
      ?? UpdateCheckingService(
        coordinator: coordinator,
        appStoreUpdateService: appStoreUpdateService,
        workspace: workspace,
        updating: updating
      )
    let updatesListViewModel =
      updatesListViewModel
      ?? UpdatesListViewModel(
        settings: settings,
        appProvider: coordinator.appProvider,
        workspace: workspace,
        updating: updating
      )
    let settingsViewModel =
      settingsViewModel
      ?? SettingsViewModel(
        settings: settings,
        installHelperService: installHelperService,
        directoryStoreFactory: directoryStoreFactory
      )

    self.searchFocusController = searchFocusController
    self.updateCheckingService = updateCheckingService
    self.updatesListViewModel = updatesListViewModel
    self.settingsViewModel = settingsViewModel
    self.commands = AppCommands(
      updateCheckingService: updateCheckingService,
      updatesListViewModel: updatesListViewModel,
      searchFocusController: searchFocusController,
      settings: settings,
      workspace: workspace
    )
  }

  static func live() -> AppEnvironment {
    AppEnvironment()
  }

  func start() {
    MigrationTelemetry.shared.applicationStarted()
    updateCheckingService.startReportingProgress()
    updatesListViewModel.startObserving()
    startupTask?.cancel()
    startupTask = Task { [weak self] in
      await AppStartupSequence.run(
        refreshCatalog: { await ReleaseNotesSourceCatalog.refresh() },
        checkForUpdates: { [weak self] in
          self?.updateCheckingService.checkForUpdates(hardRefresh: false)
        }
      )
    }
  }

  func stop() {
    startupTask?.cancel()
    startupTask = nil
    updatesListViewModel.stopObserving()
    updateCheckingService.stopReportingProgress()
  }
}

/// Discovery uses the bundled catalog immediately. Remote catalog refresh must
/// not gate app visibility; release-note lookups already track catalog revisions.
@MainActor
enum AppStartupSequence {
  static func run(
    refreshCatalog: () async -> Void,
    checkForUpdates: () -> Void
  ) async {
    guard !Task.isCancelled else { return }
    checkForUpdates()
    await refreshCatalog()
  }
}
