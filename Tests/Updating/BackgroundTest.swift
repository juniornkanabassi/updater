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

  func testOnlyNewUpdatesNotifyAndUnchangedSetsStaySilent() async throws {
    let suite = "BackgroundTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let notifier = RecordingNotifier()
    let controller = UpdateNotificationController(notifier: notifier, defaults: defaults)
    let warp = makeTestApp(name: "Warp", version: "1", remoteVersion: "2")
    let goodnotes = makeTestApp(name: "Goodnotes", version: "1", remoteVersion: "2")

    // A manual check moves the baseline without asking or posting.
    await controller.checkFinished(waiting: [warp], announce: false)
    XCTAssertEqual(notifier.authorizationRequests, 0, "never asks before a background result")
    XCTAssertTrue(notifier.posts.isEmpty)

    await controller.checkFinished(waiting: [warp], announce: true)
    XCTAssertEqual(notifier.authorizationRequests, 1, "asks on the first background result")
    XCTAssertTrue(notifier.posts.isEmpty, "an unchanged set says nothing")

    await controller.checkFinished(waiting: [warp, goodnotes], announce: true)
    XCTAssertEqual(notifier.posts.count, 1)
    XCTAssertEqual(notifier.posts.last?.title, "1 update available")
    XCTAssertEqual(notifier.posts.last?.body, "Goodnotes")

    let warpNext = makeTestApp(name: "Warp", version: "1", remoteVersion: "3")
    await controller.checkFinished(waiting: [warpNext, goodnotes], announce: true)
    XCTAssertEqual(notifier.posts.last?.body, "Warp", "a newer version is new again")
    XCTAssertEqual(notifier.posts.count, 2)
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
      ], workspace: workspace)
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
    XCTAssertEqual(PermissionsViewModel.appManagementState(latest: [refused]), .notGranted)
    XCTAssertEqual(PermissionsViewModel.appManagementState(latest: [admin]), .unknown)
  }

  /// A failed row whose outcome is a missing permission offers that permission's pane.
  func testNeedsPermissionFailureOffersFixInSettings() async throws {
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
  }
}
