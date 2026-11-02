//
//  AppEnvironment.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Combine
import Foundation

@MainActor
final class AppEnvironment: ObservableObject {
  let searchFocusController: SearchFocusController
  let updateCheckingService: UpdateCheckingService
  let updatesListViewModel: UpdatesListViewModel
  let settingsViewModel: SettingsViewModel
  let commands: AppCommands
  let menuBar: MenuBarViewModel
  private var startupTask: Task<Void, Never>?
  private var backgroundChecks: BackgroundCheckScheduler?
  private var notifications: UpdateNotificationController?
  private let coordinator: any UpdateCheckCoordinating
  private let settings: any AppListSettingsProviding
  private let updating: any AppUpdating
  private var control: (service: ControlService, server: ControlServer)?
  /// The first full check since launch has finished (automation waits for it).
  private var initialCheckFinished = false

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
    self.coordinator = coordinator
    self.updating = updating
    self.settings = settings
    self.updateCheckingService = updateCheckingService
    self.updatesListViewModel = updatesListViewModel
    self.settingsViewModel = settingsViewModel
    self.commands = AppCommands(
      updateCheckingService: updateCheckingService,
      updatesListViewModel: updatesListViewModel,
      searchFocusController: searchFocusController,
      settings: settings
    )
    self.menuBar = MenuBarViewModel(
      appProvider: coordinator.appProvider, settings: settings,
      updateAllCandidates: { [updateCheckingService] in updateCheckingService.updateAllCandidates })
  }

  private var launchObserver: NSObjectProtocol?
  private var volumeObserver: NSObjectProtocol?

  /// Background checks and the menu bar run whether or not the window opens or stays open.
  static func live() -> AppEnvironment {
    let environment = AppEnvironment()
    environment.launchObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
    ) { [weak environment] _ in MainActor.assumeIsolated { environment?.start() } }
    return environment
  }

  /// Runs once at launch; closing the window leaves it running for the menu bar.
  func start() {
    guard backgroundChecks == nil else { return }
    // Interrupted updates first: their targets and tools are held in the scheduler until put
    // right, before the window, the CLI or MCP can submit anything.
    RecoveryOperation.enqueuePending(from: .shared, into: .shared)
    // Records left unresolved (a volume that was not attached) are tried again when it is.
    volumeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didMountNotification, object: nil, queue: .main
    ) { _ in RecoveryOperation.enqueuePending(from: .shared, into: .shared) }
    MigrationTelemetry.shared.applicationStarted()
    updateCheckingService.startReportingProgress()
    updatesListViewModel.startObserving()
    let checks = BackgroundCheckScheduler(
      isChecking: { [updateCheckingService] in updateCheckingService.isRunning },
      check: { [updateCheckingService] _ in
        updateCheckingService.checkForUpdates(hardRefresh: false, origin: .background)
      })
    backgroundChecks = checks
    let notifications = UpdateNotificationController(
      notifier: LiveUpdateNotifier(open: { MainWindow.show() }))
    self.notifications = notifications
    coordinator.checkCompletion = { [weak self, settings] completion in
      self?.initialCheckFinished = true
      let includeExternal = settings.includeAppsWithLimitedSupport
      Task {
        await notifications.checkFinished(completion, includeExternal: includeExternal)
      }
    }
    menuBar.startObserving()
    checks.start()
    startControlServer()
    startupTask?.cancel()
    startupTask = Task {
      await AppStartupSequence.run(
        refreshCatalog: { await ReleaseNotesSourceCatalog.refresh() },
        checkForUpdates: { checks.fire(.launch) }
      )
    }
  }

  func stop() {
    startupTask?.cancel()
    startupTask = nil
    backgroundChecks?.stop()
    backgroundChecks = nil
    coordinator.checkCompletion = nil
    control?.server.stop()
    control = nil
    menuBar.stopObserving()
    updatesListViewModel.stopObserving()
    updateCheckingService.stopReportingProgress()
  }
}

extension AppEnvironment {
  /// The `updater` CLI and the MCP server talk to this socket; it reuses the window's services.
  fileprivate func startControlServer() {
    let checking = updateCheckingService
    let service = ControlService(
      .init(
        apps: { [coordinator] in coordinator.appProvider.apps },
        isChecking: { checking.isRunning },
        initialCheckFinished: { [weak self] in self?.initialCheckFinished ?? false },
        startCheck: { checking.checkForUpdates(hardRefresh: $0) },
        updateAllCandidates: { checking.updateAllCandidates },
        updateAll: { checking.updateAll() },
        updating: updating,
        history: .shared))
    do {
      let server = try ControlServer(path: ControlPaths.socket) { request in
        await service.handle(request)
      }
      control = (service, server)
    } catch {
      // Another copy already answers, or the folder is unusable; the window still works.
      NSLog("Updater control socket not started: \(error)")
    }
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
