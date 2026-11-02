//
//  AppDependencyBoundaryTest.swift
//  Latest Tests
//
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import Observation
import Synchronization
import XCTest

@testable import Latest

@MainActor
final class AppDependencyBoundaryTest: XCTestCase {
  /// Update All runs only install/vendorTool apps; hand-offs stay per-app actions.
  func testBulkUpdateSkipsHandOffsWithoutOpeningAnything() {
    let apps = ["Wrapped One", "Wrapped Two"].map {
      makeTestApp(
        name: $0, version: "1", remoteVersion: "2",
        updateAction: .external(label: "App Store") { _ in })
    }
    let (service, store, workspace, updating) = bulkService(apps: apps)
    service.updateAll()
    XCTAssertEqual(store.preparations, 0)
    XCTAssertTrue(workspace.openedURLs.isEmpty)
    XCTAssertTrue(updating.updatedNames.isEmpty)
  }

  func testBulkManualPreferenceAppliesToPreviouslyCheckedNativeApps() {
    let app = makeTestApp(name: "Native", version: "1", remoteVersion: "2")
    let (service, store, workspace, updating) = bulkService(apps: [app])
    store.alwaysUsesManualUpdates = true
    service.updateAll()
    XCTAssertEqual(store.preparations, 0)
    XCTAssertTrue(updating.updatedNames.isEmpty)
    store.alwaysUsesManualUpdates = false
    service.updateAll()
    XCTAssertEqual(store.preparations, 1)
    XCTAssertEqual(updating.updatedNames, ["Native"])
    XCTAssertTrue(workspace.openedURLs.isEmpty, "Update All never opens a store page")
  }

  func testBulkMixedAppStoreActionsPrepareAndEnqueueOnlyNativeUpdates() {
    let native = makeTestApp(name: "Native", version: "1", remoteVersion: "2")
    let wrapped = makeTestApp(
      name: "Wrapped", version: "1", remoteVersion: "2",
      updateAction: .external(label: "App Store") { _ in })
    let (service, store, _, updating) = bulkService(apps: [native, wrapped])
    service.updateAll()
    XCTAssertEqual(store.preparations, 1)
    XCTAssertEqual(updating.updatedNames, ["Native"])
    service.updateAll()
    XCTAssertEqual(
      store.preparations, 1, "Already queued native apps do not need helper preparation again")
    XCTAssertEqual(updating.updatedNames, ["Native"])
  }

  /// The menu bar lists every waiting update but enables Update All by the window's rule.
  func testMenuBarUsesTheWindowsUpdateAllEligibility() throws {
    let native = makeTestApp(name: "Native", version: "1", remoteVersion: "2")
    let handOff = makeTestApp(
      name: "Hand Off", version: "1", remoteVersion: "2",
      updateAction: .external(label: "App Store") { _ in })
    let current = makeTestApp(name: "Current", version: "2", remoteVersion: "2")
    let apps = [native, handOff, current]
    let store = StubAppStoreService()
    let updating = BulkUpdating()
    let environment = AppEnvironment(
      settings: try isolatedAppListSettings(for: self),
      coordinator: StubCheckCoordinator(apps: apps), updating: updating,
      appStoreUpdateService: store)
    let menu = environment.menuBar

    menu.refresh(with: apps)
    XCTAssertEqual(menu.updates.map(\.name), ["Hand Off", "Native"])
    XCTAssertEqual(
      environment.updateCheckingService.updateAllCandidates.map(\.name), ["Native"])
    XCTAssertTrue(menu.canUpdateAll)

    store.alwaysUsesManualUpdates = true
    menu.refresh(with: apps)
    XCTAssertFalse(menu.canUpdateAll, "manual App Store installs are hand-offs in both places")
    store.alwaysUsesManualUpdates = false
    updating.update(native, isBulkUpdate: true)
    menu.refresh(with: apps)
    XCTAssertFalse(menu.canUpdateAll, "an app already updating is not started again")
    XCTAssertTrue(
      UpdateCheckingService.updateAllCandidates(
        from: apps.filter { $0.updateAvailable }, isUpdating: { _ in false },
        alwaysUsesManualAppStoreUpdates: false
      ).map(\.name) == ["Native"], "hand-offs never join Update All")
  }

  private func bulkService(apps: [App]) -> (
    UpdateCheckingService, StubAppStoreService, StubApplicationWorkspace, BulkUpdating
  ) {
    let store = StubAppStoreService()
    let workspace = StubApplicationWorkspace()
    let updating = BulkUpdating()
    let service = UpdateCheckingService(
      coordinator: StubCheckCoordinator(apps: apps), appStoreUpdateService: store,
      updating: updating)
    return (service, store, workspace, updating)
  }

  func testUpdatesListViewModelDoesNotRebuildSnapshotForDuplicateSearchAction() throws {
    let viewModel = UpdatesListViewModel(settings: try isolatedAppListSettings(for: self))

    XCTAssertEqual(viewModel.snapshotRevision, 0)
    viewModel.setSearchQuery("latest")
    XCTAssertEqual(viewModel.snapshotRevision, 1)
    viewModel.setSearchQuery("latest")
    XCTAssertEqual(viewModel.snapshotRevision, 1)
  }

  func testSnapshotUsesInjectedSettingsInsteadOfGlobalPreferences() throws {
    let (settings, defaults, suiteName) = try makeSettings()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    settings.includeUnsupportedApps = false

    let app = makeApp(source: .none)
    let hidden = AppListSnapshot(
      withApps: [app],
      filterQuery: nil,
      settings: settings
    )
    XCTAssertTrue(hidden.apps.isEmpty == false)
    XCTAssertTrue(hidden.sections.isEmpty)

    settings.includeUnsupportedApps = true
    let visible = hidden.updated(with: nil)
    XCTAssertEqual(visible.sections.flatMap(\.apps), [app])
  }

  func testUpdatesViewModelRoutesWorkspaceAndStoreActionsThroughInjectedBoundaries() throws {
    let (settings, defaults, suiteName) = try makeSettings()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let app = makeApp(source: .sparkle)
    let provider = StubAppProvider(apps: [app])
    let workspace = StubApplicationWorkspace()
    let viewModel = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [app], filterQuery: nil, settings: settings),
      settings: settings,
      appProvider: provider,
      workspace: workspace
    )

    viewModel.open(app)
    viewModel.revealInFinder(app)
    viewModel.setIgnored(true, for: app)

    XCTAssertEqual(workspace.openedApplicationURLs, [app.fileURL])
    XCTAssertEqual(workspace.revealedURLs, [[app.fileURL]])
    XCTAssertEqual(provider.ignoredChanges.count, 1)
    XCTAssertEqual(provider.ignoredChanges.first?.ignored, true)
    XCTAssertEqual(provider.ignoredChanges.first?.app, app)
  }

  func testSelectedAppUsesFreshObjectAfterProviderRefresh() throws {
    let (settings, defaults, suiteName) = try makeSettings()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    settings.showInstalledUpdates = true
    let original = makeApp(source: .sparkle)
    let refreshed = original.with(ignoredState: true)
    settings.showIgnoredUpdates = true
    let viewModel = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [original], filterQuery: nil, settings: settings),
      settings: settings,
      appProvider: StubAppProvider(apps: [refreshed]),
      workspace: StubApplicationWorkspace()
    )
    viewModel.select(original)
    let selectionRefreshed = expectation(description: "Selected app refreshed")
    let observedSelection = withObservationTracking {
      viewModel.selectedApp
    } onChange: {
      selectionRefreshed.fulfill()
    }
    XCTAssertTrue(observedSelection === original)
    viewModel.startObserving()
    defer {
      viewModel.stopObserving()
    }
    wait(for: [selectionRefreshed], timeout: 2)
    XCTAssertTrue(viewModel.selectedApp === refreshed)
  }

  func testCommandsUseInjectedPreferences() throws {
    let (settings, defaults, suiteName) = try makeSettings()
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let commands = AppCommands(
      updateCheckingService: StubUpdateCheckingCommands(),
      updatesListViewModel: UpdatesListViewModel(
        settings: settings,
        appProvider: StubAppProvider(apps: []),
        workspace: StubApplicationWorkspace()
      ),
      searchFocusController: SearchFocusController(),
      settings: settings
    )

    commands.changeSortOrder(.name)
    commands.showInstalledUpdates.toggle()

    XCTAssertEqual(settings.sortOrder, .name)
    XCTAssertFalse(settings.showInstalledUpdates)
  }

  func testUpdaterHasNoSelfUpdateFeed() {
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey"))
  }

  private func makeSettings() throws -> (AppListSettings, UserDefaults, String) {
    let suiteName = "AppDependencyBoundaryTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return (AppListSettings(userDefaults: defaults), defaults, suiteName)
  }

  private func makeApp(source: App.Source) -> App {
    let bundle = App.Bundle(
      version: Version(versionNumber: "1.0", buildNumber: "1"),
      name: "Fixture",
      bundleIdentifier: "com.example.fixture",
      fileURL: URL(fileURLWithPath: "/Applications/Fixture.app", isDirectory: true),
      source: source,
      modificationDate: .distantPast
    )
    return App(bundle: bundle, update: nil, isIgnored: false)
  }
}

private final class StubAppProvider: AppProviding {
  struct IgnoredChange {
    let ignored: Bool
    let app: App
  }

  let apps: [App]
  private(set) var ignoredChanges = [IgnoredChange]()

  init(apps: [App]) {
    self.apps = apps
  }

  var updatableApps: [App] {
    apps.filter { $0.updateAvailable && $0.capability.isAutomatic && !$0.isIgnored }
  }

  func countOfAvailableUpdates(where condition: (App) -> Bool) -> Int {
    apps.filter { $0.updateAvailable && !$0.isIgnored && condition($0) }.count
  }

  @MainActor
  func updates() -> AsyncStream<AppListUpdate> {
    AsyncStream { continuation in
      continuation.yield(AppListUpdate(apps: apps, checkingGeneration: nil))
      continuation.finish()
    }
  }

  func setIgnoredState(_ ignored: Bool, for app: App) {
    ignoredChanges.append(IgnoredChange(ignored: ignored, app: app))
  }
}

@MainActor
final class StubApplicationWorkspace: ApplicationWorkspace {
  private(set) var openedApplicationURLs = [URL]()
  private(set) var revealedURLs = [[URL]]()
  private(set) var openedURLs = [URL]()
  private(set) var badgeLabels = [String?]()

  func openApplication(at url: URL) {
    openedApplicationURLs.append(url)
  }

  func revealInFinder(_ urls: [URL]) {
    revealedURLs.append(urls)
  }

  func open(_ url: URL) {
    openedURLs.append(url)
  }

  func setDockBadge(_ label: String?) {
    badgeLabels.append(label)
  }
}

@MainActor
private final class StubUpdateCheckingCommands: UpdateCheckingCommandHandling {
  func checkForUpdates() {}
  func updateAll() {}
}

private final class StubCheckCoordinator: UpdateCheckCoordinating {
  let appProvider: any AppProviding
  @MainActor var progressDelegate: (any UpdateCheckProgressReporting)?
  init(apps: [App]) { appProvider = StubAppProvider(apps: apps) }
  @MainActor func run(hardRefresh: Bool) {}
}

@MainActor
private final class StubAppStoreService: AppStoreUpdateServicing {
  var alwaysUsesManualUpdates = false
  private(set) var preparations = 0
  func verifyAvailability() throws(InstallHelperError) { preparations += 1 }
}

private final class BulkUpdating: AppUpdating {
  private let names = Mutex<[String]>([])
  var updatedNames: [String] { names.withLock { $0 } }
  func isUpdating(_ app: App) -> Bool { names.withLock { $0.contains(app.name) } }
  func update(_ app: App, isBulkUpdate: Bool) { names.withLock { $0.append(app.name) } }
  func cancel(_ app: App) {}
  @MainActor func retryTermination(_ app: App) {}
  func state(for identifier: App.Bundle.Identifier) -> UpdateProgressState { .none }
  @MainActor func states(for identifier: App.Bundle.Identifier) -> AsyncStream<UpdateProgressState>
  { AsyncStream { $0.finish() } }
  @MainActor func stateChanges(for identifier: App.Bundle.Identifier) -> UpdateStateFeed {
    (.none, states(for: identifier))
  }
}
