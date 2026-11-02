//
//  UpdateCheckingService.swift
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
final class UpdateCheckingService: NSObject, ObservableObject, UpdateCheckProgressReporting {
  private enum ExternalURL {
    static let updatesPage = URL(string: "macappstore://apps.apple.com/updates")
  }

  @Published private(set) var isRunning = false
  @Published private(set) var isIndeterminate = false
  @Published private(set) var checkedApps = 0
  @Published private(set) var totalApps = 0
  private var currentCheckingGeneration: Int?
  private var activeCheckingBatches = 0
  private let coordinator: any UpdateCheckCoordinating
  private let appStoreUpdateService: any AppStoreUpdateServicing
  private let updating: any AppUpdating
  private let helperAlert: UpdateInstallHelperAlert?

  init(
    coordinator: any UpdateCheckCoordinating = UpdateCheckCoordinator.shared,
    appStoreUpdateService: any AppStoreUpdateServicing = LiveAppStoreUpdateService.shared,
    updating: any AppUpdating = AppUpdateService.shared,
    helperAlert: UpdateInstallHelperAlert? = nil
  ) {
    self.helperAlert = helperAlert
    self.coordinator = coordinator
    self.appStoreUpdateService = appStoreUpdateService
    self.updating = updating
  }

  var progressFraction: Double? {
    guard !isIndeterminate, totalApps > 0 else { return nil }
    return Double(checkedApps) / Double(totalApps)
  }

  func startReportingProgress() {
    coordinator.progressDelegate = self
  }

  func stopReportingProgress() {
    if coordinator.progressDelegate === self {
      coordinator.progressDelegate = nil
    }
  }

  func checkForUpdates() {
    checkForUpdates(hardRefresh: true)
  }

  /// Startup can reuse short-lived App Store lookups; an explicit user refresh
  /// invalidates them so the command retains its expected force-refresh behavior.
  func checkForUpdates(hardRefresh: Bool, origin: UpdateCheckOrigin = .manual) {
    startReportingProgress()
    coordinator.run(hardRefresh: hardRefresh, origin: origin)
  }

  /// What Update All would start now; the window and the menu bar both ask this.
  var updateAllCandidates: [App] {
    Self.updateAllCandidates(
      from: coordinator.appProvider.updatableApps, isUpdating: updating.isUpdating,
      alwaysUsesManualAppStoreUpdates: appStoreUpdateService.alwaysUsesManualUpdates)
  }

  /// Update All runs only apps Updater installs itself (`install`/`vendorTool`); hand-offs
  /// such as the App Store page stay per-app actions.
  static func updateAllCandidates(
    from apps: [App], isUpdating: (App) -> Bool, alwaysUsesManualAppStoreUpdates: Bool
  ) -> [App] {
    apps.filter { app in
      // The manual-update preference turns App Store installs into a hand-off.
      app.capability.isAutomatic && !isUpdating(app)
        && !(app.bundle.source == .appStore && alwaysUsesManualAppStoreUpdates)
    }
  }

  func updateAll() {
    let apps = updateAllCandidates

    if apps.contains(where: { $0.bundle.source == .appStore }) {
      do {
        try appStoreUpdateService.verifyAvailability()
      } catch {
        guard let updatesPage = ExternalURL.updatesPage else { return }
        (helperAlert ?? .shared).prepare(fallbackURL: updatesPage, error: error) {
          [weak self] in
          self?.updateAll()
        }
        return
      }
    }

    apps.forEach { updating.update($0, isBulkUpdate: true) }
  }

  func updateCheckerDidStartScanningForApps(_ updateChecker: UpdateCheckCoordinator) {
    MigrationTelemetry.shared.scanStarted()
    isRunning = true
    isIndeterminate = true
    checkedApps = 0
    totalApps = 0
    currentCheckingGeneration = nil
    activeCheckingBatches = 0
  }

  func updateChecker(
    _ updateChecker: UpdateCheckCoordinator,
    didStartCheckingApps numberOfApps: Int,
    generation: Int
  ) {
    if currentCheckingGeneration != generation {
      currentCheckingGeneration = generation
      activeCheckingBatches = 0
      checkedApps = 0
      totalApps = 0
    }

    let isFirstBatch = activeCheckingBatches == 0
    activeCheckingBatches += 1
    isRunning = true
    isIndeterminate = false
    if isFirstBatch {
      checkedApps = 0
      totalApps = numberOfApps
    } else {
      totalApps += numberOfApps
    }
  }

  func updateChecker(_ updateChecker: UpdateCheckCoordinator, didCheckApp: App) {
    checkedApps += 1
  }

  func updateCheckerDidFinishCheckingForUpdates(
    _ updateChecker: UpdateCheckCoordinator, generation: Int
  ) {
    guard currentCheckingGeneration == generation else { return }
    activeCheckingBatches = max(0, activeCheckingBatches - 1)
    guard activeCheckingBatches == 0 else { return }
    currentCheckingGeneration = nil
    isRunning = false
    isIndeterminate = false
    MigrationTelemetry.shared.scanFinished(appCount: totalApps)
  }
}
