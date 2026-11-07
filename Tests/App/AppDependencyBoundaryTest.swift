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
  func testVerifiedUpdateReceiptsSurviveFilteringAndExcludeOtherOutcomes() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = UpdateHistoryStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let original = makeTestApp(name: "Receipt Fixture", version: "1", remoteVersion: "2")
    let installed = makeTestApp(name: "Receipt Fixture", version: "2")
    let success = UpdateHistoryEntry(
      before: original.bundle, after: installed.bundle, outcome: .updated(from: "1", to: "2"))
    history.record(success)
    let receipt = UpdateReceiptModel(history: history)
    XCTAssertNil(receipt.message, "Past history must not create a new completion banner")
    let otherOutcomes: [UpdateOutcome] = [
      .noChange(reason: nil), .failed(reason: "Not installed", logPath: nil),
      .handedOff, .needsQuit, .needsPermission(kind: "appManagement"),
    ]
    for outcome in otherOutcomes {
      history.record(
        UpdateHistoryEntry(before: original.bundle, after: original.bundle, outcome: outcome))
    }
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertNil(receipt.message)
    history.record(success)
    for _ in 0..<100 where receipt.count != 1 { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(receipt.count, 1)
    XCTAssertEqual(receipt.message, "Updated Receipt Fixture to 2.")
    let settings = try isolatedAppListSettings(for: self)
    let list = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [original], filterQuery: nil, settings: settings),
      settings: settings)
    list.select(original)
    list.setSearchQuery("No match")
    XCTAssertNil(list.selectedApp)
    XCTAssertEqual(receipt.count, 1, "Filtering and selection never dismiss a receipt")
    history.record(success)
    for _ in 0..<100 where receipt.count != 2 { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(receipt.count, 2)
    XCTAssertTrue(receipt.message?.contains("2 updates completed") == true)
    receipt.dismiss()
    XCTAssertNil(receipt.message)
    history.record(success)
    for _ in 0..<100 where receipt.count != 1 { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertEqual(receipt.count, 1, "Dismissal starts a new completion count")
  }

  func testMultipleSelectionUpdatesAutomaticAppsAndSurvivesFiltering() throws {
    let first = makeTestApp(name: "Alpha", version: "1", remoteVersion: "2")
    let second = makeTestApp(name: "Beta", version: "1", remoteVersion: "2")
    let handoff = makeTestApp(
      name: "Gamma", version: "1", remoteVersion: "2",
      updateAction: .external(label: "Fixture Store") { _ in })
    let settings = try isolatedAppListSettings(for: self)
    let updating = BulkUpdating()
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(
        withApps: [first, second, handoff], filterQuery: nil, settings: settings),
      settings: settings, updating: updating,
      bulkUpdateService: UpdateCheckingService(
        coordinator: StubCheckCoordinator(apps: []), appStoreUpdateService: StubAppStoreService(),
        updating: updating))
    model.select(Set([first.identifier, second.identifier, handoff.identifier]))
    XCTAssertEqual(model.selectedAppIDs.count, 3)
    model.updateSelection(model.selectedAppIDs)
    XCTAssertEqual(Set(updating.updatedNames), Set(["Alpha", "Beta"]))
    model.setSearchQuery("Beta")
    XCTAssertEqual(model.selectedAppIDs, [second.identifier])
    XCTAssertEqual(model.selectedApp?.identifier, second.identifier)
    model.select(Set([handoff.identifier]))
    XCTAssertTrue(model.selectedAppIDs.isEmpty, "Hidden rows cannot remain selected")
  }

  func testBulkSelectionSkipsIgnoredUnknownCurrentAndManualApps() throws {
    let available = makeTestApp(name: "Available", version: "1", remoteVersion: "2")
    let ignored = makeTestApp(name: "Ignored", version: "1", remoteVersion: "2")
      .with(ignoredState: true)
    let current = makeTestApp(name: "Current", version: "1")
    let bundle = makeApp(source: .vendor).bundle
    let unknown = App(
      bundle: bundle,
      update: .success(
        App.Update(
          app: bundle, remoteVersion: bundle.version, minimumOSVersion: nil, source: .vendor,
          date: nil, releaseNotes: nil, updateAction: .builtIn { _ in },
          availabilityUnknown: true)), isIgnored: false)
    let apps = [available, ignored, current, unknown]
    let (service, store, _, updating) = bulkService(apps: apps)
    let settings = try isolatedAppListSettings(for: self)
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
      settings: settings, updating: updating, bulkUpdateService: service)
    let identifiers = Set(apps.map(\.identifier))
    model.select(identifiers)
    let commands = AppCommands(
      updateCheckingService: service, updatesListViewModel: model,
      searchFocusController: SearchFocusController(), settings: settings)
    XCTAssertEqual(model.automaticUpdateCandidates(identifiers).map(\.name), ["Available"])
    store.alwaysUsesManualUpdates = true
    XCTAssertFalse(commands.canUpdateSelectedApp)
    model.updateSelection(identifiers)
    XCTAssertTrue(updating.updatedNames.isEmpty)
    store.alwaysUsesManualUpdates = false
    XCTAssertTrue(commands.canUpdateSelectedApp)
    commands.updateSelectedApp()
    XCTAssertEqual(updating.updatedNames, ["Available"])
    XCTAssertEqual(store.preparations, 1)
  }

  func testBulkSelectionPreflightsOnceAndRetriesWholeBatchAfterRepair() async throws {
    let preferences = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    setTestManualAppStorePreference(false)
    defer {
      UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    }
    let apps = ["First", "Second", "Third"].map {
      makeTestApp(name: $0, version: "1", remoteVersion: "2")
    }
    let store = StubAppStoreService()
    store.availabilityError = .installHelperNotRegistered
    let helper = HelperRegistrationFixture()
    helper.enabled = true
    let alert = UpdateInstallHelperAlert(
      helper: helper, workspace: StubApplicationWorkspace())
    defer { alert.cancel() }
    let updating = BulkUpdating()
    let service = UpdateCheckingService(
      coordinator: StubCheckCoordinator(apps: apps), appStoreUpdateService: store,
      updating: updating, helperAlert: alert)
    let settings = try isolatedAppListSettings(for: self)
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
      settings: settings, updating: updating, bulkUpdateService: service)
    model.updateSelection(Set(apps.map(\.identifier)))
    XCTAssertEqual(store.preparations, 1)
    XCTAssertTrue(alert.isPresented)
    XCTAssertTrue(updating.updatedNames.isEmpty)
    store.availabilityError = nil
    alert.enableHelper()
    for _ in 0..<100 where alert.isPresented {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(alert.isPresented)
    XCTAssertEqual(store.preparations, 2)
    XCTAssertEqual(Set(updating.updatedNames), Set(apps.map(\.name)))
    XCTAssertEqual(updating.bulkFlags, [true, true, true])
  }

  func testBulkRepairCannotBecomeASingleHandOffAfterFiltering() async throws {
    let preferences = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    setTestManualAppStorePreference(false)
    defer {
      UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
    }
    let native = makeTestApp(name: "Native", version: "1", remoteVersion: "2")
    let handoff = makeTestApp(
      name: "Hand Off", version: "1", remoteVersion: "2",
      updateAction: .external(label: "Fixture Store") { _ in })
    let store = StubAppStoreService()
    store.availabilityError = .installHelperNotRegistered
    let helper = HelperRegistrationFixture()
    helper.enabled = true
    let alert = UpdateInstallHelperAlert(helper: helper, workspace: StubApplicationWorkspace())
    defer { alert.cancel() }
    let updating = BulkUpdating()
    let service = UpdateCheckingService(
      coordinator: StubCheckCoordinator(apps: [native, handoff]), appStoreUpdateService: store,
      updating: updating, helperAlert: alert)
    let settings = try isolatedAppListSettings(for: self)
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [native, handoff], filterQuery: nil, settings: settings),
      settings: settings, updating: updating, bulkUpdateService: service)
    model.updateSelection(Set([native.identifier, handoff.identifier]))
    XCTAssertTrue(alert.isPresented)
    model.setSearchQuery("Hand Off")
    store.availabilityError = nil
    alert.enableHelper()
    for _ in 0..<100 where alert.isPresented {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(alert.isPresented)
    XCTAssertTrue(updating.updatedNames.isEmpty, "Bulk repair must never execute a hand-off")
    model.updateSelection(Set([native.identifier, handoff.identifier]))
    XCTAssertTrue(
      updating.updatedNames.isEmpty,
      "An old multi-selection context menu must retain bulk policy after its rows are filtered")
  }

  func testRefreshKeepsMultipleSelectionAndDetailInAgreement() async throws {
    let settings = try isolatedAppListSettings(for: self)
    let first = makeTestApp(name: "Alpha", version: "1", remoteVersion: "2")
    let retained = makeTestApp(name: "Beta", version: "1", remoteVersion: "2")
    let unrelated = makeTestApp(name: "Aardvark", version: "1", remoteVersion: "2")
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [first, retained], filterQuery: nil, settings: settings),
      settings: settings, appProvider: StubAppProvider(apps: [unrelated, retained]))
    model.select(Set([first.identifier, retained.identifier]), isKeyboardSelection: true)
    XCTAssertTrue(model.isKeyboardSelection)
    model.startObserving()
    defer { model.stopObserving() }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(model.selectedAppIDs, [retained.identifier])
    XCTAssertTrue(model.selectedApp === retained)
  }

  func testAutomaticSelectionMovesHighlightWithDetailToNextUpdate() async throws {
    let settings = try isolatedAppListSettings(for: self)
    let first = makeTestApp(name: "Alpha", version: "1", remoteVersion: "2")
    let current = makeTestApp(name: "Alpha", version: "1", remoteVersion: "1")
    let next = makeTestApp(name: "Beta", version: "1", remoteVersion: "2")
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [first, next], filterQuery: nil, settings: settings),
      settings: settings, appProvider: StubAppProvider(apps: [current, next]))
    model.selectedApp = first
    model.startObserving()
    defer { model.stopObserving() }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(model.selectedAppIDs, [next.identifier])
    XCTAssertTrue(model.selectedApp === next)
    model.select(Set([current.identifier, next.identifier]))
    model.select(next)
    XCTAssertEqual(model.selectedAppIDs, [next.identifier])
  }

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
    defer { defaults.removeTestPersistentDomain(forName: suiteName) }
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
    defer { defaults.removeTestPersistentDomain(forName: suiteName) }
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
    defer { defaults.removeTestPersistentDomain(forName: suiteName) }
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
    defer { defaults.removeTestPersistentDomain(forName: suiteName) }
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

  func testAllFourVisibilityCommandsKeepTheirPersistedPreferenceKeys() throws {
    let (settings, defaults, suiteName) = try makeSettings()
    defer { defaults.removeTestPersistentDomain(forName: suiteName) }
    let commands = AppCommands(
      updateCheckingService: StubUpdateCheckingCommands(),
      updatesListViewModel: UpdatesListViewModel(
        settings: settings, appProvider: StubAppProvider(apps: []),
        workspace: StubApplicationWorkspace()),
      searchFocusController: SearchFocusController(), settings: settings)
    for enabled in [false, true] {
      commands.includeAppsWithLimitedSupport = enabled
      commands.showInstalledUpdates = enabled
      commands.includeUnsupportedApps = enabled
      commands.showIgnoredUpdates = enabled
      XCTAssertEqual(defaults.bool(forKey: "IncludeAppsWithLimitedSupportKey"), enabled)
      XCTAssertEqual(defaults.bool(forKey: "ShowInstalledUpdatesKey"), enabled)
      XCTAssertEqual(defaults.bool(forKey: "ShowUnsupportedUpdatesKey"), enabled)
      XCTAssertEqual(defaults.bool(forKey: "ShowIgnoredUpdatesKey"), enabled)
      let reloaded = AppListSettings(userDefaults: defaults)
      XCTAssertEqual(reloaded.includeAppsWithLimitedSupport, enabled)
      XCTAssertEqual(reloaded.showInstalledUpdates, enabled)
      XCTAssertEqual(reloaded.includeUnsupportedApps, enabled)
      XCTAssertEqual(reloaded.showIgnoredUpdates, enabled)
    }
  }

  func testUpdateCommandRequiresKnownUpdateAndUsesSelectedAppOutsideFilter() throws {
    let settings = try isolatedAppListSettings(for: self)
    let bundle = makeApp(source: .vendor).bundle
    let unknown = App(
      bundle: bundle,
      update: .success(
        App.Update(
          app: bundle, remoteVersion: bundle.version, minimumOSVersion: nil, source: .vendor,
          date: nil, releaseNotes: nil, updateAction: .external(label: "Creative Cloud") { _ in },
          availabilityUnknown: true)), isIgnored: false)
    let available = makeTestApp(name: "Available", version: "1", remoteVersion: "2")
    let updating = BulkUpdating()
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(
        withApps: [unknown, available], filterQuery: nil, settings: settings),
      settings: settings, updating: updating)
    let commands = AppCommands(
      updateCheckingService: StubUpdateCheckingCommands(),
      updatesListViewModel: model, searchFocusController: SearchFocusController(),
      settings: settings)
    XCTAssertFalse(unknown.updateAvailable)
    XCTAssertTrue(unknown.isActionable)
    model.select(unknown)
    XCTAssertFalse(commands.canUpdateSelectedApp)
    commands.updateSelectedApp()
    XCTAssertTrue(updating.updatedNames.isEmpty)
    model.select(available)
    XCTAssertTrue(commands.canUpdateSelectedApp)
    model.setSearchQuery("No match")
    // An explicitly retained selection still owns the command, not the filtered rows.
    model.selectedApp = available
    XCTAssertTrue(commands.canUpdateSelectedApp)
    commands.updateSelectedApp()
    XCTAssertEqual(updating.updatedNames, [available.name])
  }

  func testUpdaterHasNoSelfUpdateFeed() {
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
    XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey"))
  }

  private func makeSettings() throws -> (AppListSettings, UserDefaults, String) {
    let suiteName = "AppDependencyBoundaryTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defaults.removeTestPersistentDomain(forName: suiteName)
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
  @MainActor var checkCompletion: (@MainActor (UpdateCheckCompletion) -> Void)?
  @MainActor func run(hardRefresh: Bool, origin: UpdateCheckOrigin) {}
}

@MainActor
private final class StubAppStoreService: AppStoreUpdateServicing {
  var alwaysUsesManualUpdates = false
  private(set) var preparations = 0
  var availabilityError: InstallHelperError?
  func verifyAvailability() throws(InstallHelperError) {
    preparations += 1
    if let availabilityError { throw availabilityError }
  }
}

private final class BulkUpdating: AppUpdating {
  private let names = Mutex<[String]>([])
  private let flags = Mutex<[Bool]>([])
  var bulkFlags: [Bool] { flags.withLock { $0 } }
  var updatedNames: [String] { names.withLock { $0 } }
  func isUpdating(_ app: App) -> Bool { names.withLock { $0.contains(app.name) } }
  func update(_ app: App, isBulkUpdate: Bool) {
    names.withLock { $0.append(app.name) }
    flags.withLock { $0.append(isBulkUpdate) }
  }
  func cancel(_ app: App) {}
  @MainActor func retryTermination(_ app: App) {}
  func state(for identifier: App.Bundle.Identifier) -> UpdateProgressState { .none }
  @MainActor func states(for identifier: App.Bundle.Identifier) -> AsyncStream<UpdateProgressState>
  { AsyncStream { $0.finish() } }
  @MainActor func stateChanges(for identifier: App.Bundle.Identifier) -> UpdateStateFeed {
    (.none, states(for: identifier))
  }
}
