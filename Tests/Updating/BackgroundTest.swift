// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import ServiceManagement
import UserNotifications
import XCTest

@testable import Latest

/// Background checks, notifications and permissions, all with injected clocks and probes:
/// nothing here posts a notification, opens System Settings or touches a real app.
@MainActor
final class BackgroundTest: XCTestCase {
  private final class Clock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    var interval: TimeInterval? = 4 * 3600
    var checking = false
    var triggers = [BackgroundCheckScheduler.Trigger]()
  }

  private func scheduler(_ clock: Clock) -> BackgroundCheckScheduler {
    BackgroundCheckScheduler(
      interval: { clock.interval }, isChecking: { clock.checking }, now: { clock.now },
      check: { clock.triggers.append($0) })
  }

  func testTimerWaitsForTheIntervalAndSkipsWhileAChecksRuns() {
    let clock = Clock()
    let checks = scheduler(clock)
    XCTAssertTrue(checks.fire(.launch))
    clock.now += 3 * 3600
    XCTAssertFalse(checks.fire(.timer), "not before the interval has passed")
    clock.now += 3600
    clock.checking = true
    XCTAssertFalse(checks.fire(.timer), "a running check is never doubled")
    clock.checking = false
    XCTAssertTrue(checks.fire(.timer))
    XCTAssertEqual(clock.triggers, [.launch, .timer])
    clock.now += 3600
    XCTAssertFalse(checks.fire(.timer), "the interval restarts from the last check")
  }

  func testWakeChecksAtOnceUnlessOffOrBusy() {
    let clock = Clock()
    let checks = scheduler(clock)
    XCTAssertTrue(checks.fire(.launch))
    clock.now += 60
    XCTAssertTrue(checks.fire(.wake), "waking does not wait for the interval")
    clock.checking = true
    XCTAssertFalse(checks.fire(.wake))
    clock.checking = false
    clock.interval = nil
    clock.now += 48 * 3600
    XCTAssertFalse(checks.fire(.wake), "off turns wake checks off")
    XCTAssertFalse(checks.fire(.timer), "off turns the timer off")
    XCTAssertTrue(checks.fire(.launch), "launch still checks, as before")
    XCTAssertEqual(clock.triggers, [.launch, .wake, .launch])
  }

  func testIntervalSettingDefaultsToFourHours() throws {
    let suite = "BackgroundTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    XCTAssertEqual(BackgroundCheckInterval.current(in: defaults).seconds, 4 * 3600)
    defaults.set(0, forKey: BackgroundCheckInterval.storageKey)
    XCTAssertNil(BackgroundCheckInterval.current(in: defaults).seconds)
    defaults.set(24, forKey: BackgroundCheckInterval.storageKey)
    XCTAssertEqual(BackgroundCheckInterval.current(in: defaults), .daily)
  }

  // MARK: - Notifications

  private final class RecordingNotifier: UpdateNotifying {
    var authorizationRequests = 0
    var posts = [(title: String, body: String)]()
    func requestAuthorization() async { authorizationRequests += 1 }
    func post(title: String, body: String) async { posts.append((title, body)) }
  }

  func testOnlyNewUpdatesNotifyAndOnlyManualChecksStayQuiet() async throws {
    let suite = "BackgroundTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let notifier = RecordingNotifier()
    let controller = UpdateNotificationController(notifier: notifier, defaults: defaults)
    let warp = makeTestApp(name: "Warp", version: "1", remoteVersion: "2")
    let goodnotes = makeTestApp(name: "Goodnotes", version: "1", remoteVersion: "2")
    func finished(_ apps: [App], _ origin: UpdateCheckOrigin) async {
      await controller.checkFinished(
        UpdateCheckCompletion(generation: 1, origin: origin, apps: apps), includeExternal: true)
    }

    // A manual check moves the baseline without asking or posting.
    await finished([warp], .manual)
    XCTAssertEqual(notifier.authorizationRequests, 0, "never asks before a background result")
    XCTAssertTrue(notifier.posts.isEmpty)

    await finished([warp], .background)
    XCTAssertEqual(notifier.authorizationRequests, 1, "asks on the first background result")
    XCTAssertTrue(notifier.posts.isEmpty, "an unchanged set says nothing")

    await finished([warp, goodnotes], .background)
    XCTAssertEqual(notifier.posts.count, 1)
    XCTAssertEqual(notifier.posts.last?.title, "1 update available")
    XCTAssertEqual(notifier.posts.last?.body, "Goodnotes")

    let warpNext = makeTestApp(name: "Warp", version: "1", remoteVersion: "3")
    await finished([warpNext, goodnotes], .background)
    XCTAssertEqual(notifier.posts.last?.body, "Warp", "a newer version is new again")

    // Sol R4-002: an app installed while Updater runs is found by the folder watcher, and
    // its update is announced rather than silently marked as seen.
    let zoom = makeTestApp(name: "Zoom", version: "1", remoteVersion: "2")
    await finished([warpNext, goodnotes, zoom], .filesystem)
    XCTAssertEqual(notifier.posts.last?.body, "Zoom")
    XCTAssertEqual(notifier.posts.count, 3)
  }

  /// Sol R4-001: completion is an explicit event per generation, so a check that finishes
  /// before the first throttled snapshot is still reported, with its origin.
  func testFastChecksReportCompletionWithTheirOrigin() async throws {
    let coordinator = UpdateCheckCoordinator(
      check: { _, _ in throw LatestError.updateInfoUnavailable }, repositoryProvider: { nil })
    var completions = [UpdateCheckCompletion]()
    coordinator.checkCompletion = { completions.append($0) }
    let root = try disposableDirectory()
    let bundle = try XCTUnwrap(
      BundleCollector.collectBundle(at: FixtureApp.make(in: root, version: "1.0", signed: false)))

    coordinator.updateDiscoveredBundles([bundle], origin: .background)
    try await waitUntil { completions.count == 1 }
    let other = try XCTUnwrap(
      BundleCollector.collectBundle(
        at: FixtureApp.make(
          in: root, name: "Other", identifier: "com.example.other", version: "1.0", signed: false)))
    // A folder change with no run pending is the watcher's.
    coordinator.updateDiscoveredBundles([bundle, other])
    try await waitUntil { completions.count == 2 }
    coordinator.updateDiscoveredBundles([bundle], forceRefresh: true, origin: .manual)
    try await waitUntil { completions.count == 3 }
    XCTAssertEqual(completions.map(\.origin), [.background, .filesystem, .manual])
    XCTAssertEqual(completions.last?.apps.map(\.fileURL), [bundle.fileURL])
  }

  // MARK: - Menu bar

  private final class StreamingProvider: AppProviding {
    let apps: [App]
    init(apps: [App]) { self.apps = apps }
    var updatableApps: [App] {
      apps.filter { $0.updateAvailable && $0.capability.isAutomatic && !$0.isIgnored }
    }
    func countOfAvailableUpdates(where condition: (App) -> Bool) -> Int { 0 }
    func updates() -> AsyncStream<AppListUpdate> {
      AsyncStream { $0.yield(AppListUpdate(apps: apps, checkingGeneration: nil)) }
    }
    func setIgnoredState(_ ignored: Bool, for app: App) {}
  }

  /// Sol R4-003: preference changes and jobs starting or being declined update the menu
  /// without a manual refresh.
  func testMenuFollowsPreferencesAndJobsWithoutARefresh() async throws {
    let settings = try isolatedAppListSettings(for: self)
    settings.includeAppsWithLimitedSupport = false
    let native = makeTestApp(name: "Native", version: "1", remoteVersion: "2")
    let externalBundle = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "Outside",
      bundleIdentifier: "com.example.outside",
      fileURL: URL(fileURLWithPath: "/Applications/Outside.app"),
      source: .sparkle, modificationDate: .distantPast)
    let outside = App(
      bundle: externalBundle,
      update: .success(
        App.Update(
          app: externalBundle, remoteVersion: Version(versionNumber: "2", buildNumber: nil),
          minimumOSVersion: nil, source: .sparkle, date: nil, releaseNotes: nil,
          updateAction: .external(label: "Its updater") { _ in })),
      isIgnored: false)
    let apps = [native, outside]
    let queue = UpdateQueue()
    let updating = AppUpdateService(queue: queue)
    let menu = MenuBarViewModel(
      appProvider: StreamingProvider(apps: apps), settings: settings,
      updateAllCandidates: {
        UpdateCheckingService.updateAllCandidates(
          from: apps.filter { $0.capability.isAutomatic }, isUpdating: updating.isUpdating,
          alwaysUsesManualAppStoreUpdates: false)
      })
    menu.startObserving()
    defer { menu.stopObserving() }
    try await waitUntil { menu.updates.map(\.name) == ["Native"] }
    XCTAssertTrue(menu.canUpdateAll)

    settings.includeAppsWithLimitedSupport = true
    try await waitUntil { menu.updates.map(\.name) == ["Native", "Outside"] }

    let job = HeldOperation(url: native.fileURL)
    queue.addOperation(job)
    try await waitUntil { !menu.canUpdateAll }
    job.decline()
    try await waitUntil { menu.canUpdateAll }
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(condition(), "timed out")
  }

  func testSummaryNamesThreeAppsThenCountsTheRest() {
    let apps = ["Warp", "Goodnotes", "Zoom", "Slack", "Arc"].map {
      makeTestApp(name: $0, version: "1", remoteVersion: "2")
    }
    let summary = UpdateNotificationController.summary(of: apps)
    XCTAssertEqual(summary?.title, "5 updates available")
    XCTAssertEqual(summary?.body, "Warp, Goodnotes, Zoom and 2 more")
    XCTAssertNil(UpdateNotificationController.summary(of: []))
  }

  // MARK: - Permissions

  func testPermissionRowsShowProbedStatesAndOpenTheirOwnPane() async {
    let workspace = StubApplicationWorkspace()
    let model = PermissionsViewModel(
      probes: [
        .appManagement: { .notGranted },
        .backgroundItem: { .granted },
        .notifications: { .unknown },
      ], history: { [] }, workspace: workspace)
    await model.refresh()
    XCTAssertEqual(model.state(of: .appManagement), .notGranted)
    XCTAssertEqual(model.state(of: .backgroundItem), .granted)
    XCTAssertEqual(model.state(of: .fullDiskAccess), .unknown, "a missing probe is unknown")

    for kind in PermissionKind.allCases { model.openSettings(for: kind) }
    XCTAssertEqual(
      workspace.openedURLs.map(\.absoluteString),
      [
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles",
        "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
          + Bundle.main.bundleIdentifier!,
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
      ])
  }

  func testLiveStatesMapToGrantedNotGrantedOrUnknown() {
    XCTAssertEqual(PermissionsViewModel.helperState(.enabled), .granted)
    XCTAssertEqual(PermissionsViewModel.helperState(.requiresApproval), .notGranted)
    XCTAssertEqual(PermissionsViewModel.notificationState(.denied), .notGranted)
    XCTAssertEqual(PermissionsViewModel.notificationState(.notDetermined), .unknown)
    XCTAssertEqual(PermissionsViewModel.notificationState(.authorized), .granted)
    let bundle = makeTestApp(name: "Refused", version: "1").bundle
    let refused = UpdateHistoryEntry(
      before: bundle, after: bundle, outcome: .needsPermission(kind: "appManagement"))
    let admin = UpdateHistoryEntry(
      before: bundle, after: bundle, outcome: .needsPermission(kind: "administrator"))
    // Sol R4-004: a refusal on record is history, never the current state.
    XCTAssertEqual(
      PermissionsViewModel.notes(for: [refused]),
      [.appManagement: "Last attempt was blocked by App Management."])
    XCTAssertTrue(PermissionsViewModel.notes(for: [admin]).isEmpty)
  }

  /// A failed row whose outcome is a missing permission offers that pane next to Retry, and
  /// keeps its failure until a retry produces a new result (Sol R4-004).
  func testNeedsPermissionFailureOffersSettingsAndKeepsRetry() async throws {
    let directory = try disposableDirectory()
    let history = UpdateHistoryStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let app = makeTestApp(name: "Refused", version: "1", remoteVersion: "2")
    history.record(
      UpdateHistoryEntry(
        before: app.bundle, after: app.bundle, outcome: .needsPermission(kind: "appManagement")))
    let queue = UpdateQueue(history: history) { _ in app.bundle }
    let workspace = StubApplicationWorkspace()
    let model = UpdateActionViewModel(
      app: app, workspace: workspace, updating: AppUpdateService(queue: queue))
    model.performAction()
    let permission = try XCTUnwrap(model.presentedError?.permission)
    XCTAssertEqual(permission, .appManagement)
    model.openSettings(for: permission)
    XCTAssertEqual(workspace.openedURLs, [PermissionKind.appManagement.settingsURL])
    XCTAssertNil(PermissionKind(outcomeKind: "administrator"), "admin stays the brew hand-off")
    model.presentedError = nil
    model.performAction()
    XCTAssertNotNil(model.presentedError, "opening Settings does not clear the recorded failure")
    let model2 = PermissionsViewModel(
      probes: [:], history: { history.latestEntries() }, workspace: workspace)
    await model2.refresh()
    XCTAssertEqual(model2.state(of: .appManagement), .unknown)
    XCTAssertNotNil(model2.notes[.appManagement])
  }
}

/// Waits until declined, then cancels and finishes cleanly, as a declined quit does.
private final class HeldOperation: UpdateOperation, @unchecked Sendable {
  private let gate = AsyncStream<Void>.makeStream()
  init(url: URL) { super.init(bundleIdentifier: "com.example.held", appIdentifier: url) }
  override func execute() {
    super.execute()
    Task.detached { [self] in
      for await _ in gate.stream {}
      cancel()
      finish()
    }
  }
  func decline() { gate.continuation.finish() }
}
