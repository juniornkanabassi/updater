// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Sparkle
import Synchronization
import XCTest

@testable import Latest

/// Sol's inspection of 0.6.0 (UPD-001 to UPD-005), through the production operations with
/// injected seams. Nothing opens the App Store, quits a real app or touches /Applications.
@MainActor
final class ControlFollowUpTest: XCTestCase {
  private let manualKey = AppStoreUpdateSettings.alwaysPerformManualUpdates.rawValue

  private func withManualPreference(_ value: Bool) {
    let stored = UserDefaults.standard.object(forKey: manualKey)
    addTeardownBlock { @MainActor [manualKey] in
      UserDefaults.standard.set(stored, forKey: manualKey)
    }
    AppStoreUpdateSettings.alwaysPerformManualUpdates.active = value
  }

  /// UPD-001: after extraction Sparkle's job is committed, so a declined quit cannot cancel
  /// it. It now ends by itself: finished (its lock free), the app untouched, no history,
  /// reported as needsQuit.
  func testDeclinedQuitAfterExtractionFinishesTheSparkleJob() async throws {
    let app = try FixtureApp.make(in: try disposableDirectory(), version: "1.0")
    let operation = SparkleUpdateOperation(
      bundleIdentifier: FixtureApp.identifier, appIdentifier: app)
    operation.requiresTeam = false
    operation.lifecycle = AppLifecycle(
      runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
      confirmQuit: { _ in false }, reopen: { _ in })
    try operation.takeBackup()
    let before = try FixtureApp.digest(app)
    operation.showDownloadDidStartExtractingUpdate()
    XCTAssertTrue(operation.isCommitting, "extraction is the commit point")
    let replied = expectation(description: "Sparkle told to skip")
    operation.showReady { choice in
      XCTAssertEqual(choice, .skip)
      replied.fulfill()
    }
    await fulfillment(of: [replied], timeout: 3)
    for _ in 0..<200 where !operation.isFinished { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(operation.isFinished, "the job ends, so its lock is released")
    XCTAssertTrue(operation.quitDeclined)
    XCTAssertNil(operation.error)
    XCTAssertEqual(try FixtureApp.digest(app), before, "the app is untouched")
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: app))
    XCTAssertNil(
      UpdateQueue.outcome(of: operation, before: bundle, after: bundle), "no history is written")
  }

  /// UPD-002: helper recovery keeps the submission's policy. With "Always open App Store"
  /// on, the sheet opens the App Store for the window but not for automation.
  func testHelperRecoveryOpensTheAppStoreOnlyForTheWindow() throws {
    withManualPreference(true)
    let url = URL(string: "macappstore://apps.apple.com/updates")!
    let automationWorkspace = StubApplicationWorkspace()
    let automation = UpdateInstallHelperAlert(
      helper: HelperRegistrationFixture(), workspace: automationWorkspace)
    ExternalHandOff.$allowed.withValue(false) {
      automation.prepare(fallbackURL: url, error: .installHelperNotRegistered) {}
    }
    XCTAssertTrue(automationWorkspace.openedURLs.isEmpty)
    XCTAssertFalse(automation.isPresented)

    let windowWorkspace = StubApplicationWorkspace()
    let window = UpdateInstallHelperAlert(
      helper: HelperRegistrationFixture(), workspace: windowWorkspace)
    window.prepare(fallbackURL: url, error: .installHelperNotRegistered) {}
    XCTAssertEqual(windowWorkspace.openedURLs, [url])
  }

  /// UPD-002: the real App Store job's helper failure goes through the same sheet with the
  /// job's policy, so an automation job opens nothing.
  func testAppStoreHelperFailureFromAutomationOpensNothing() async throws {
    withManualPreference(true)
    let app = try FixtureApp.make(in: try disposableDirectory(), version: "1.0", signed: false)
    let workspace = StubApplicationWorkspace()
    let alert = UpdateInstallHelperAlert(helper: HelperRegistrationFixture(), workspace: workspace)
    let operation = AppStoreUpdateOperation(
      bundleIdentifier: FixtureApp.identifier, installURL: app, appIdentifier: app,
      appStoreIdentifier: 1)
    operation.installGate = { _, _ in true }
    operation.usesVerifiedHelperInstall = true
    operation.prepare = { throw InstallHelperError.installHelperNotRegistered }
    operation.openURL = { _ in XCTFail("the job itself must not open anything") }
    operation.injectedHelperAlert = alert
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    ExternalHandOff.$allowed.withValue(false) { UpdateQueue().addOperation(operation) }
    await fulfillment(of: [done], timeout: 5)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(workspace.openedURLs.isEmpty, "automation's helper recovery opened nothing")
  }

  /// UPD-002: Update All's deferred retry (after the helper sheet) keeps the policy.
  func testUpdateAllRetryAfterHelperRecoveryKeepsThePolicy() async throws {
    withManualPreference(false)
    let app = makeTestApp(name: "Native", version: "1", remoteVersion: "2")
    let store = FailingOnceStore()
    let updating = PolicyRecorder()
    let helper = HelperRegistrationFixture()
    helper.enabled = true
    let alert = UpdateInstallHelperAlert(helper: helper, workspace: StubApplicationWorkspace())
    let service = UpdateCheckingService(
      coordinator: OneAppCoordinator(apps: [app]), appStoreUpdateService: store, updating: updating,
      helperAlert: alert)
    ExternalHandOff.$allowed.withValue(false) { service.updateAll() }
    XCTAssertTrue(updating.policies.isEmpty, "nothing runs before the helper is ready")
    alert.enableHelper()
    for _ in 0..<200 where updating.policies.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(updating.policies, [false], "the retried Update All is still automation's")
  }

  /// UPD-003: a job id resolves throughout, including between isFinished and its completion.
  func testJobStaysResolvableWhileItsCompletionIsDelayed() async throws {
    let queue = UpdateQueue()
    let url = URL(fileURLWithPath: "/tmp/Delayed-\(UUID().uuidString).app")
    let operation = QuickOperation(url: url)
    let release = DispatchSemaphore(value: 0)
    // The queue runs this before its own bookkeeping: hold the completion there.
    operation.completionBlock = { release.wait() }
    queue.addOperation(operation)
    for _ in 0..<200 where !operation.isFinished { try await Task.sleep(for: .milliseconds(5)) }
    XCTAssertTrue(operation.isFinished)
    let during = try XCTUnwrap(queue.job(withID: operation.jobID), "unresolvable mid-completion")
    XCTAssertNil(during.state)
    XCTAssertNotNil(during.record)
    release.signal()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertNotNil(queue.job(withID: operation.jobID)?.record)
  }

  /// UPD-004: `current` only after a successful, comparable check.
  func testAvailabilityIsCurrentOnlyAfterASuccessfulComparison() {
    let current = makeTestApp(name: "Current", version: "2", remoteVersion: "2")
    XCTAssertEqual(ControlService.availability(of: current, checking: false).0, "current")
    XCTAssertEqual(
      ControlService.availability(
        of: makeTestApp(name: "New", version: "1", remoteVersion: "2"), checking: false
      ).0, "available")
    let bundle = current.bundle
    let failed = App(
      bundle: bundle, update: .failure(LatestError.updateInfoUnavailable), isIgnored: false)
    let (state, note) = ControlService.availability(of: failed, checking: false)
    XCTAssertEqual(state, "error")
    XCTAssertNotNil(note, "the check's error is included")
    let pending = App(bundle: bundle, update: nil, isIgnored: false)
    XCTAssertEqual(ControlService.availability(of: pending, checking: true).0, "checking")
    XCTAssertEqual(ControlService.availability(of: pending, checking: false).0, "unknown")
    let adobe = App(
      bundle: bundle,
      update: .success(
        App.Update(
          app: bundle, remoteVersion: bundle.version, minimumOSVersion: nil, source: .vendor,
          date: nil, releaseNotes: nil, updateAction: .external(label: "Creative Cloud") { _ in },
          availabilityUnknown: true)),
      isIgnored: false)
    XCTAssertEqual(ControlService.availability(of: adobe, checking: false).0, "unknown")
  }

  /// UPD-005: a fallback that opens nothing (a vendor tool out of scope) is a handOff with a
  /// destination and reason, and never suggests --allow-handoff; an App Store fallback that
  /// automation blocked does; one the window opened is handedOff.
  func testHandOffReportsWhatActuallyHappened() async throws {
    let app = try FixtureApp.make(in: try disposableDirectory(), version: "1.0", signed: false)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: app))
    let vendor = VendorToolOperation(
      app: bundle, lock: "msupdate", expectedVersion: nil, inScope: { false },
      install: { XCTFail("out of scope: never run") })
    let vendorRecord = try await finishedRecord(of: vendor, allowsHandOff: true)
    XCTAssertEqual(vendorRecord.handOff?.opened, false)
    XCTAssertEqual(vendorRecord.handOff?.blockedByPolicy, false)
    XCTAssertTrue(vendorRecord.handOff?.destination.contains("msupdate") == true)

    func store(_ allowed: Bool, opened: OpenCount) -> AppStoreUpdateOperation {
      let operation = AppStoreUpdateOperation(
        bundleIdentifier: FixtureApp.identifier, installURL: app, appIdentifier: app,
        appStoreIdentifier: 1)
      operation.installGate = { _, _ in false }
      operation.usesVerifiedHelperInstall = true
      operation.openURL = { _ in opened.value.withLock { $0 += 1 } }
      return operation
    }
    let blockedCount = OpenCount()
    let blocked = try await finishedRecord(
      of: store(false, opened: blockedCount), allowsHandOff: false)
    XCTAssertEqual(blocked.handOff?.blockedByPolicy, true)
    XCTAssertEqual(blockedCount.value.withLock { $0 }, 0)
    let openedCount = OpenCount()
    let opened = try await finishedRecord(of: store(true, opened: openedCount), allowsHandOff: true)
    XCTAssertEqual(opened.handOff?.opened, true)
    XCTAssertEqual(openedCount.value.withLock { $0 }, 1)
  }

  private func finishedRecord(of operation: UpdateOperation, allowsHandOff: Bool) async throws
    -> UpdateJobRecord
  {
    let queue = UpdateQueue()
    ExternalHandOff.$allowed.withValue(allowsHandOff) { queue.addOperation(operation) }
    for _ in 0..<300 {
      if let record = queue.job(withID: operation.jobID)?.record { return record }
      try await Task.sleep(for: .milliseconds(10))
    }
    throw XCTSkip("job did not finish")
  }
  /// R5B-003: history keeps where a hand-off went, why and whether it opened; status and
  /// history read it the same way, also after reloading; old records claim nothing opened.
  func testHandOffDetailsSurviveHistoryReload() throws {
    let file = try disposableDirectory().appendingPathComponent("history.jsonl")
    let app = makeTestApp(name: "Store", version: "1", remoteVersion: "2")
    let blocked = HandOffNote(
      destination: "the App Store", reason: "Updater could not confirm the copy.", opened: false,
      blockedByPolicy: true)
    UpdateHistoryStore(fileURL: file).record(
      UpdateHistoryEntry(
        before: app.bundle, after: app.bundle, outcome: .handedOff, handOff: blocked))
    let reloaded = try XCTUnwrap(UpdateHistoryStore(fileURL: file).entries(limit: 1).first)
    XCTAssertEqual(reloaded.handOff, blocked)
    let fromHistory = ControlService.report(reloaded.outcome, handOff: reloaded.handOff, label: nil)
    let fromStatus = ControlService.report(.handedOff, handOff: blocked, label: "ignored")
    XCTAssertEqual(fromHistory, fromStatus)
    XCTAssertEqual(fromHistory["state"], "handOff")
    XCTAssertTrue(fromHistory["message"]?.stringValue?.contains("--allow-handoff") == true)

    // A 0.6 record: no note, so nothing is claimed to have opened.
    let old =
      #"{"date":"2026-11-01T10:00:00Z","appPath":"/Applications/Old.app","bundleIdentifier":"com.example.old","versionNumber":"1","buildNumber":null,"resultBundleIdentifier":"com.example.old","resultVersionNumber":"1","resultBuildNumber":null,"outcome":{"handedOff":{}}}"#
    let legacy = try disposableDirectory().appendingPathComponent("old.jsonl")
    try Data((old + "\n").utf8).write(to: legacy)
    let entry = try XCTUnwrap(UpdateHistoryStore(fileURL: legacy).entries(limit: 1).first)
    XCTAssertNil(entry.handOff)
    XCTAssertEqual(
      ControlService.report(entry.outcome, handOff: nil, label: nil)["state"], "handOff")
  }
}

private final class QuickOperation: UpdateOperation, @unchecked Sendable {
  init(url: URL) { super.init(bundleIdentifier: "test.quick", appIdentifier: url) }
  override func execute() {
    super.execute()
    finish()
  }
}

@MainActor
private final class FailingOnceStore: AppStoreUpdateServicing {
  var alwaysUsesManualUpdates = false
  private var failed = false
  func verifyAvailability() throws(InstallHelperError) {
    guard failed else {
      failed = true
      throw .installHelperNotRegistered
    }
  }
}

private final class PolicyRecorder: AppUpdating {
  private let recorded = Mutex<[Bool]>([])
  var policies: [Bool] { recorded.withLock { $0 } }
  func isUpdating(_ app: App) -> Bool { false }
  func update(_ app: App, isBulkUpdate: Bool) {
    let allowed = ExternalHandOff.allowed
    recorded.withLock { $0.append(allowed) }
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

private final class OneAppCoordinator: UpdateCheckCoordinating {
  private final class Provider: AppProviding {
    let apps: [App]
    init(apps: [App]) { self.apps = apps }
    var updatableApps: [App] { apps.filter { $0.updateAvailable && $0.capability.isAutomatic } }
    func countOfAvailableUpdates(where condition: (App) -> Bool) -> Int { 0 }
    func updates() -> AsyncStream<AppListUpdate> { AsyncStream { $0.finish() } }
    func setIgnoredState(_ ignored: Bool, for app: App) {}
  }
  let appProvider: any AppProviding
  @MainActor var progressDelegate: (any UpdateCheckProgressReporting)?
  @MainActor var checkCompletion: (@MainActor (UpdateCheckCompletion) -> Void)?
  init(apps: [App]) { appProvider = Provider(apps: apps) }
  @MainActor func run(hardRefresh: Bool, origin: UpdateCheckOrigin) {}
}
