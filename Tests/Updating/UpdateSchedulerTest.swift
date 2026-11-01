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
      queue.addOperation(ScriptedOperation(url: url, body: body))
      // The queue records the outcome in its completion block, just after finishing.
      for _ in 0..<200 where history.latestEntry(for: url)?.date == previous {
        try? await Task.sleep(for: .milliseconds(10))
      }
    }

    await run { installed.withLock { $0 = "1.1" } }
    XCTAssertEqual(history.latestEntry(for: url)?.outcome, .updated(from: "1.0", to: "1.1"))

    await run {}  // the installer claims success but nothing changed on disk
    XCTAssertEqual(history.latestEntry(for: url)?.outcome, .noChange)

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
  init(url: URL, gate: AsyncStream<Void>) {
    self.gate = gate
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
