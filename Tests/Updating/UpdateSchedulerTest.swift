// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

/// The scheduler is `UpdateQueue`: per-URL dedup, per-tool locks, outcomes read from disk.
final class UpdateSchedulerTest: XCTestCase {
  func testJobsSharingAToolLockNeverOverlap() async throws {
    let queue = UpdateQueue()
    let log = RunLog()
    let done = expectation(description: "All jobs finished")
    done.expectedFulfillmentCount = 3
    let jobs = [("first", "appStoreHelper"), ("second", "appStoreHelper"), ("other", "target:x")]
      .map { name, lock in
        TimedOperation(name: name, lockKey: lock, log: log) { done.fulfill() }
      }
    jobs.forEach { queue.addOperation($0) }
    await fulfillment(of: [done], timeout: 5)

    let entries = log.entries.withLock { $0 }
    let first = try XCTUnwrap(entries.first { $0.name == "first" })
    let second = try XCTUnwrap(entries.first { $0.name == "second" })
    let other = try XCTUnwrap(entries.first { $0.name == "other" })
    XCTAssertLessThanOrEqual(first.end, second.start, "Jobs on one tool lock must not overlap")
    // A job on another lock is free to run alongside them.
    XCTAssertLessThan(other.start, first.end)
  }

  /// Sol R4: cancelling waiting jobs must not let a later job overtake the running holder.
  func testCancelledWaitersNeverLetALaterJobOvertakeTheHolder() async throws {
    let queue = UpdateQueue()
    let release = AsyncStream<Void>.makeStream()
    let holder = GatedOperation(
      url: URL(fileURLWithPath: "/tmp/H.app"), gate: release.stream, lock: "tool")
    let started = StartLog()
    let middle = MarkingOperation(name: "middle", lock: "tool", started: started)
    let tail = MarkingOperation(name: "tail", lock: "tool", started: started)
    queue.addOperation(holder)
    while !holder.isExecuting { try await Task.sleep(for: .milliseconds(5)) }
    queue.addOperation(middle)
    queue.addOperation(tail)
    middle.cancel()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(
      started.names.withLock { $0 }.isEmpty, "tail waits for the holder, not the middle")
    tail.cancel()
    let late = MarkingOperation(name: "late", lock: "tool", started: started)
    queue.addOperation(late)
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertTrue(started.names.withLock { $0 }.isEmpty, "a newcomer waits for the holder too")
    XCTAssertTrue(holder.isExecuting)
    let done = expectation(description: "late finished")
    late.completionBlock = { done.fulfill() }
    release.continuation.finish()
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(started.names.withLock { $0 }, ["late"])
  }

  /// Sol R1: `updated` needs a newer on-disk version that reaches the expected one.
  func testOutcomeRejectsDowngradesAndShortfalls() {
    func outcome(_ before: String, _ after: String, expected: String?) -> UpdateOutcome? {
      let url = URL(fileURLWithPath: "/tmp/Outcome.app")
      func bundle(_ version: String) -> App.Bundle {
        App.Bundle(
          version: Version(versionNumber: version, buildNumber: nil), name: "Outcome",
          bundleIdentifier: "com.example.outcome", fileURL: url, source: .sparkle,
          modificationDate: .distantPast)
      }
      let operation = ScriptedOperation(url: url) {}
      operation.expectedVersion = expected.map { Version(versionNumber: $0, buildNumber: nil) }
      return UpdateQueue.outcome(of: operation, before: bundle(before), after: bundle(after))
    }
    XCTAssertEqual(outcome("1.0", "1.2", expected: "1.2"), .updated(from: "1.0", to: "1.2"))
    XCTAssertEqual(outcome("1.0", "1.3", expected: "1.2"), .updated(from: "1.0", to: "1.3"))
    XCTAssertEqual(outcome("1.0", "1.0", expected: "1.2"), .noChange(reason: nil))
    guard case .failed = outcome("1.0", "1.1", expected: "1.2") else {
      return XCTFail("Short of the expected version is a failure")
    }
    guard case .failed = outcome("1.0", "0.9", expected: nil) else {
      return XCTFail("A downgrade is never an update")
    }
  }

  /// Sol R4 (second pass): a failure found by re-reading the disk is the job's terminal
  /// state for subscribers, and stays on the row after reload while that bundle remains.
  @MainActor
  func testDerivedFailureIsPublishedAndKeyedToTheResultingBundle() async throws {
    let directory = try disposableDirectory()
    let history = UpdateHistoryStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let url = directory.appendingPathComponent("Fixture.app")
    let installed = Mutex("1.0")
    let read: @Sendable (URL) -> App.Bundle? = { url in
      App.Bundle(
        version: Version(versionNumber: installed.withLock { $0 }, buildNumber: nil),
        name: "Fixture", bundleIdentifier: FixtureApp.identifier, fileURL: url, source: .sparkle,
        modificationDate: .distantPast)
    }
    let queue = UpdateQueue(history: history, readBundle: read)
    let feed = queue.stateChanges(for: url)
    let terminal = Task { () -> UpdateProgressState? in
      for await state in feed.changes { if case .error = state { return state } }
      return nil
    }
    // The installer reports success but left an older version behind.
    let done = expectation(description: "done")
    let job = ScriptedOperation(url: url) { installed.withLock { $0 = "0.9" } }
    job.completionBlock = { done.fulfill() }
    queue.addOperation(job)
    await fulfillment(of: [done], timeout: 2)
    XCTAssertTrue(job.error is UpdateOutcomeError)
    let published = await terminal.value
    guard case .error(let error) = published else { return XCTFail("subscribers saw no failure") }
    XCTAssertTrue(error.localizedDescription.contains("not an update"))
    let reloaded = UpdateQueue(
      history: UpdateHistoryStore(fileURL: history.fileURL), readBundle: read)
    guard case .error = reloaded.state(for: url) else {
      return XCTFail("the failure applies to the bundle the attempt left on disk")
    }
  }

  /// Sol R3-201: a declined quit records nothing, and the row goes back to the previous
  /// persisted failure instead of a blank state.
  @MainActor
  func testDeclinedRetryRestoresThePreviousFailure() async throws {
    let directory = try disposableDirectory()
    let history = UpdateHistoryStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let url = directory.appendingPathComponent("Fixture.app")
    let bundle = App.Bundle(
      version: Version(versionNumber: "1.0", buildNumber: nil), name: "Fixture",
      bundleIdentifier: FixtureApp.identifier, fileURL: url, source: .sparkle,
      modificationDate: .distantPast)
    history.record(
      UpdateHistoryEntry(before: bundle, after: bundle, outcome: .failed(reason: "x", logPath: nil))
    )
    let queue = UpdateQueue(history: history) { _ in bundle }
    let feed = queue.stateChanges(for: url)
    guard case .error = feed.current else { return XCTFail("the failure starts on the row") }
    let done = expectation(description: "done")
    // A declined quit: the installer cancels itself and finishes without an error.
    let job = DeclinedQuitOperation(url: url)
    job.completionBlock = { done.fulfill() }
    let states = Task { () -> [UpdateProgressState] in
      var seen = [UpdateProgressState]()
      for await state in feed.changes {
        seen.append(state)
        if case .error = state { break }  // changes never replay the starting state
      }
      return seen
    }
    queue.addOperation(job)
    await fulfillment(of: [done], timeout: 2)
    let timeout = Task {
      try await Task.sleep(for: .seconds(2))
      states.cancel()
    }
    let seen = await states.value
    timeout.cancel()
    guard case .error = seen.last else {
      return XCTFail("the previous failure must come back, saw \(seen)")
    }
    let lines = try String(contentsOf: history.fileURL, encoding: .utf8).split(separator: "\n")
    XCTAssertEqual(lines.count, 1, "a declined quit writes no history")
  }

  /// Sol R4 (third pass): failed attempts reconcile the row with the disk too, and a bundle
  /// that is gone afterwards loses its row while its failure stays in history.
  func testFailedAttemptsReconcileTheRowAndAVanishedAppLosesIt() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0", signed: false)
    let notices = Mutex(0)
    let job = ScriptedOperation(url: app) { throw ReplacementError.verificationFailed("x") }
    let observer = NotificationCenter.default.addObserver(
      forName: .latestUpdateOperationDidFinish, object: job, queue: nil
    ) { _ in notices.withLock { $0 += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }
    let done = expectation(description: "done")
    job.completionBlock = { done.fulfill() }
    UpdateQueue().addOperation(job)
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(notices.withLock { $0 }, 1, "a failed attempt still refreshes the row")

    let coordinator = UpdateCheckCoordinator(
      check: { _, _ in throw LatestError.updateInfoUnavailable }, repositoryProvider: { nil })
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: app))
    coordinator.updateDiscoveredBundles([bundle])
    let store = try XCTUnwrap(coordinator.appProvider as? AppDataStore)
    XCTAssertTrue(store.apps.contains { $0.fileURL == app })
    try FileManager.default.removeItem(at: app)
    NotificationCenter.default.post(
      name: .latestUpdateOperationDidFinish, object: nil,
      userInfo: [UpdateOperation.appIdentifierUserInfoKey: app])
    for _ in 0..<200 where store.apps.contains(where: { $0.fileURL == app }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertFalse(store.apps.contains { $0.fileURL == app })
  }

  /// Sol R4 (fifth pass): a real error during settling beats a hand-off.
  func testRealErrorsTakePrecedenceOverHandOff() {
    let url = URL(fileURLWithPath: "/tmp/HandOff.app")
    let bundle = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "HandOff",
      bundleIdentifier: "com.example.handoff", fileURL: url, source: .appStore,
      modificationDate: .distantPast)
    let failed = ScriptedOperation(url: url) { throw ReplacementError.restoreFailed("/tmp/kept") }
    failed.outcomeOverride = .handedOff
    failed.start()
    guard
      case .failed(let reason, _) = UpdateQueue.outcome(of: failed, before: bundle, after: bundle)
    else { return XCTFail("a failed restore must not read as handed off") }
    XCTAssertTrue(reason.contains("/tmp/kept"))
    let clean = ScriptedOperation(url: url) {}
    clean.outcomeOverride = .handedOff
    clean.start()
    XCTAssertEqual(UpdateQueue.outcome(of: clean, before: bundle, after: bundle), .handedOff)
  }

  func testSecondSubmissionForTheSameURLReturnsTheRunningJob() async {
    let queue = UpdateQueue()
    let url = URL(fileURLWithPath: "/tmp/Dedup-\(UUID().uuidString).app")
    let release = AsyncStream<Void>.makeStream()
    let first = GatedOperation(url: url, gate: release.stream)
    let second = GatedOperation(url: url, gate: release.stream)
    XCTAssertTrue(queue.submit(first) === first)
    XCTAssertTrue(queue.submit(second) === first, "Duplicates get the existing job")
    let done = expectation(description: "finished")
    first.completionBlock = { done.fulfill() }
    release.continuation.finish()
    await fulfillment(of: [done], timeout: 2)
    XCTAssertFalse(second.isExecuting || second.isFinished)
  }

  /// Every outcome comes from re-reading the bundle, and failures survive a reload.
  func testOutcomesAreReadFromDiskAndFailuresPersistAfterTheJobLeaves() async throws {
    let directory = try disposableDirectory()
    let history = UpdateHistoryStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let url = directory.appendingPathComponent("Fixture.app")
    let installed = Mutex("1.0")
    let queue = UpdateQueue(history: history) { url in
      App.Bundle(
        version: Version(versionNumber: installed.withLock { $0 }, buildNumber: nil),
        name: "Fixture", bundleIdentifier: FixtureApp.identifier, fileURL: url, source: .sparkle,
        modificationDate: .distantPast)
    }

    func run(_ body: @escaping @Sendable () throws -> Void) async {
      let previous = history.latestEntry(for: url)?.date
      let operation = ScriptedOperation(url: url, body: body)
      XCTAssertTrue(queue.submit(operation) === operation)
      // History is written before the completion block removes the target from the queue.
      for _ in 0..<200
      where history.latestEntry(for: url)?.date == previous || queue.contains(url) {
        try? await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertFalse(queue.contains(url), "The next run must not reuse the finishing job")
      XCTAssertNotEqual(history.latestEntry(for: url)?.date, previous)
    }

    await run { installed.withLock { $0 = "1.1" } }
    XCTAssertEqual(history.latestEntry(for: url)?.outcome, .updated(from: "1.0", to: "1.1"))

    await run {}  // the installer claims success but nothing changed on disk
    XCTAssertEqual(history.latestEntry(for: url)?.outcome, .noChange(reason: nil))

    await run { throw AppDownloadError.applicationStillRunning }
    XCTAssertEqual(history.latestEntry(for: url)?.outcome, .needsQuit)

    await run { throw ReplacementError.verificationFailed("Signature changed.") }
    guard case .failed(let reason, _) = history.latestEntry(for: url)?.outcome else {
      return XCTFail("Expected a failed outcome")
    }
    XCTAssertTrue(reason.contains("Signature changed."))
    // A reloaded row (fresh queue and store, no job) still shows the failure...
    let reloaded = UpdateQueue(
      history: UpdateHistoryStore(fileURL: history.fileURL),
      readBundle: { url in
        App.Bundle(
          version: Version(versionNumber: installed.withLock { $0 }, buildNumber: nil),
          name: "Fixture", bundleIdentifier: FixtureApp.identifier, fileURL: url,
          source: .sparkle, modificationDate: .distantPast)
      })
    guard case .error(let error) = reloaded.state(for: url) else {
      return XCTFail("A failure must stay visible after the list reloads")
    }
    XCTAssertTrue(error.localizedDescription.contains("Signature changed."))
    // ...until the bundle on disk is no longer the one that failed.
    installed.withLock { $0 = "1.2" }
    guard case .none = reloaded.state(for: url) else {
      return XCTFail("An app updated elsewhere no longer shows the old failure")
    }
  }
}

private final class RunLog: Sendable {
  let entries = Mutex<
    [(name: String, start: ContinuousClock.Instant, end: ContinuousClock.Instant)]
  >([])
}

private final class TimedOperation: UpdateOperation, @unchecked Sendable {
  private let label: String
  private let key: String
  private let log: RunLog
  private let onFinish: @Sendable () -> Void
  override var lockKey: String { key }

  init(
    name: String, lockKey: String,
    log: RunLog,
    onFinish: @escaping @Sendable () -> Void
  ) {
    self.label = name
    self.key = lockKey
    self.log = log
    self.onFinish = onFinish
    super.init(
      bundleIdentifier: "com.example.timed",
      appIdentifier: URL(fileURLWithPath: "/tmp/Timed-\(name)-\(UUID().uuidString).app"))
  }

  override func execute() {
    super.execute()
    Task.detached { [self] in
      let start = ContinuousClock.now
      try? await Task.sleep(for: .milliseconds(200))
      let end = ContinuousClock.now
      log.entries.withLock { $0.append((label, start, end)) }
      finish()
      onFinish()
    }
  }
}

private final class GatedOperation: UpdateOperation, @unchecked Sendable {
  private let gate: AsyncStream<Void>
  private let lock: String?
  override var lockKey: String { lock ?? super.lockKey }
  init(url: URL, gate: AsyncStream<Void>, lock: String? = nil) {
    self.gate = gate
    self.lock = lock
    super.init(bundleIdentifier: "com.example.gated", appIdentifier: url)
  }
  override func execute() {
    super.execute()
    Task.detached { [self] in
      for await _ in gate {}
      finish()
    }
  }
}

private final class ScriptedOperation: UpdateOperation, @unchecked Sendable {
  private let body: @Sendable () throws -> Void
  init(url: URL, body: @escaping @Sendable () throws -> Void) {
    self.body = body
    super.init(bundleIdentifier: FixtureApp.identifier, appIdentifier: url)
  }
  override func execute() {
    super.execute()
    do {
      try body()
      finish()
    } catch { finish(with: error) }
  }
}

private final class DeclinedQuitOperation: UpdateOperation, @unchecked Sendable {
  init(url: URL) { super.init(bundleIdentifier: FixtureApp.identifier, appIdentifier: url) }
  override func execute() {
    super.execute()
    cancel()
    finish()
  }
}

private final class StartLog: Sendable {
  let names = Mutex<[String]>([])
}

private final class MarkingOperation: UpdateOperation, @unchecked Sendable {
  private let label: String
  private let lock: String
  private let log: StartLog
  override var lockKey: String { lock }
  init(name: String, lock: String, started: StartLog) {
    label = name
    self.lock = lock
    log = started
    super.init(
      bundleIdentifier: "com.example.marking",
      appIdentifier: URL(fileURLWithPath: "/tmp/Marking-\(name).app"))
  }
  override func execute() {
    super.execute()
    log.names.withLock { $0.append(label) }
    finish()
  }
}
