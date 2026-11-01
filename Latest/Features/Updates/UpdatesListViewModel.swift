//
//  UpdatesListViewModel.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import Foundation
import Observation

/// Selection changes should invalidate only views that read the selection.
@MainActor
@Observable
private final class UpdatesSelection {
  // App equality compares identifiers and versions. A refreshed object with that same
  // identifier must still invalidate its notes and metadata.
  private struct Value {
    let app: App?
    var isKeyboardSelection = false
  }
  private var value = Value(app: nil)
  var app: App? {
    get { value.app }
    set { set(newValue, isKeyboardSelection: false) }
  }
  var isKeyboardSelection: Bool { value.isKeyboardSelection }

  func set(_ app: App?, isKeyboardSelection: Bool) {
    guard value.app !== app || value.isKeyboardSelection != isKeyboardSelection else { return }
    value = Value(app: app, isKeyboardSelection: isKeyboardSelection)
  }
}

@MainActor
final class UpdatesListViewModel: ObservableObject {
  private static let badgeNumberFormatter = NumberFormatter()

  @Published private(set) var snapshot: AppListSnapshot
  private(set) var snapshotRevision = 0
  private let selection = UpdatesSelection()
  var selectedApp: App? {
    get { selection.app }
    set { selection.app = newValue }
  }
  var isKeyboardSelection: Bool { selection.isKeyboardSelection }
  @Published private(set) var searchQuery = ""

  private struct ListPreferences: Equatable {
    let sortOrder: AppListSettings.SortOptions
    let showInstalled: Bool
    let showIgnored: Bool
    let includeUnsupported: Bool
    let includeLimited: Bool

    @MainActor
    init(_ settings: any AppListSettingsProviding) {
      sortOrder = settings.sortOrder
      showInstalled = settings.showInstalledUpdates
      showIgnored = settings.showIgnoredUpdates
      includeUnsupported = settings.includeUnsupportedApps
      includeLimited = settings.includeAppsWithLimitedSupport
    }
  }

  private var observedPreferences: ListPreferences
  private var observationTasks = [Task<Void, Never>]()
  private let settings: any AppListSettingsProviding
  private let appProvider: any AppProviding
  private let workspace: any ApplicationWorkspace
  let updating: any AppUpdating

  init(
    snapshot: AppListSnapshot? = nil,
    settings: any AppListSettingsProviding = AppListSettings.shared,
    appProvider: any AppProviding = UpdateCheckCoordinator.shared.appProvider,
    workspace: any ApplicationWorkspace = MacApplicationWorkspace.shared,
    updating: any AppUpdating = AppUpdateService.shared
  ) {
    self.settings = settings
    self.observedPreferences = ListPreferences(settings)
    self.appProvider = appProvider
    self.workspace = workspace
    self.updating = updating
    self.snapshot =
      snapshot
      ?? AppListSnapshot(
        withApps: [],
        filterQuery: nil,
        settings: settings
      )
    updateDockBadge()
  }

  func startObserving() {
    guard observationTasks.isEmpty else { return }
    let settings = settings
    let appProvider = appProvider

    observationTasks = [
      Task { [weak self] in
        for await _ in settings.updates() {
          guard !Task.isCancelled, let self else { break }
          let preferences = ListPreferences(settings)
          guard preferences != self.observedPreferences else { continue }
          self.observedPreferences = preferences
          self.refreshSnapshot()
        }
      },
      Task { [weak self] in
        for await update in appProvider.updates() {
          guard !Task.isCancelled, let self else { break }
          self.replaceSnapshot(
            with: AppListSnapshot(
              withApps: update.apps,
              filterQuery: self.normalizedSearchQuery,
              settings: self.settings,
              checkingGeneration: update.checkingGeneration, previous: self.snapshot
            ))
          self.maintainSelectionAfterSnapshotChange()
          self.updateDockBadge()
        }
      },
    ]
  }

  func stopObserving() {
    observationTasks.forEach { $0.cancel() }
    observationTasks.removeAll()
  }

  func setSearchQuery(_ query: String) {
    guard query != searchQuery else { return }
    searchQuery = query
    let filteredSnapshot = MigrationTelemetry.shared.measureFilter(rowCount: snapshot.entries.count)
    {
      snapshot.refiltered(with: normalizedSearchQuery)
    }
    replaceSnapshot(with: filteredSnapshot)
    maintainSelectionAfterSnapshotChange()
  }

  func select(_ app: App?, isKeyboardSelection: Bool = false) {
    guard app?.identifier != selectedApp?.identifier else { return }
    if let app, app !== selectedApp {
      MigrationTelemetry.shared.selectionStarted(appName: app.name)
    }
    selection.set(app, isKeyboardSelection: isKeyboardSelection)
  }

  func update(_ app: App) {
    updating.update(app)
  }

  func open(_ app: App) {
    workspace.openApplication(at: app.fileURL)
  }

  func revealInFinder(_ app: App) {
    workspace.revealInFinder([app.fileURL])
  }

  func setIgnored(_ ignored: Bool, for app: App) {
    appProvider.setIgnoredState(ignored, for: app)
  }

  var hasUpdatesAvailable: Bool {
    !appProvider.updatableApps.isEmpty
  }

  var showsSupportStatus: Bool {
    settings.includeAppsWithLimitedSupport || settings.includeUnsupportedApps
  }

  private var normalizedSearchQuery: String? {
    searchQuery.isEmpty ? nil : searchQuery
  }

  private func refreshSnapshot() {
    replaceSnapshot(with: snapshot.updated(with: normalizedSearchQuery))
    maintainSelectionAfterSnapshotChange()
    updateDockBadge()
  }

  private func replaceSnapshot(with snapshot: AppListSnapshot) {
    snapshotRevision &+= 1
    self.snapshot = snapshot
    MigrationTelemetry.shared.snapshotCommitted(
      rowCount: snapshot.entries.count,
      appCount: snapshot.apps.count
    )
  }

  private func maintainSelectionAfterSnapshotChange() {
    if let selectedApp,
      snapshot.firstIndex(of: selectedApp) != nil
    {
      let refreshedApp = snapshot.app(withIdentifier: selectedApp.identifier)
      if refreshedApp !== selectedApp { self.selectedApp = refreshedApp }
      return
    }

    selectedApp = snapshot.sections.first?.apps.first
  }

  private func updateDockBadge() {
    let showExternalUpdates = settings.includeAppsWithLimitedSupport
    let count = appProvider.countOfAvailableUpdates { app in
      showExternalUpdates || app.usesBuiltInUpdater
    }

    workspace.setDockBadge(
      count == 0
        ? nil
        : Self.badgeNumberFormatter.string(from: count as NSNumber))
  }
}
