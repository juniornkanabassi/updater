// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Darwin
import Synchronization
import XCTest

@testable import Latest

/// Interruption recovery (Round 5b, C): a real replacement in a separate process is killed at
/// a chosen phase, and the next launch's recovery reconciles what it left. Disposable fixtures
/// and a private journal only.
final class TransactionJournalTest: XCTestCase {
  private struct Scene {
    let journal: TransactionJournal
    let root: URL
    let target: URL
    let candidate: URL
  }

  private func scene() throws -> Scene {
    let root = try disposableDirectory()
    let apps = root.appendingPathComponent("Apps")
    let staging = root.appendingPathComponent("Staging")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let target = try FixtureApp.make(in: apps, version: "1.0")
    let candidate = try FixtureApp.make(in: staging, version: "1.1")
    let journalRoot = root.appendingPathComponent("Journal")
    return Scene(
      journal: TransactionJournal(root: journalRoot), root: journalRoot, target: target,
      candidate: candidate)
  }

  /// Starts the probe (this test host's own binary, Debug only) and kills it with SIGKILL once
  /// it reaches `phase`, as a crash or power cut would.
  private func killDuring(_ phase: String, _ scene: Scene) async throws {
    try FileManager.default.createDirectory(at: scene.root, withIntermediateDirectories: true)
    // posix_spawn and waitpid directly: the test reaps the child itself, so nothing depends
    // on a run loop to notice the exit.
    let arguments = [
      try XCTUnwrap(Bundle.main.executablePath), "--journal-crash-probe", scene.root.path,
      scene.target.path, scene.candidate.path, phase,
    ]
    let pid = try spawn(arguments)
    let reached = scene.root.appendingPathComponent("reached")
    for _ in 0..<500 where !FileManager.default.fileExists(atPath: reached.path) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: reached.path), "probe reached \(phase)")
    kill(pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
  }

  /// A child the test reaps itself with waitpid (Process waits on a run loop, which an async
  /// test's thread does not run).
  private func spawn(_ arguments: [String]) throws -> pid_t {
    var argv = arguments.map { strdup($0) } + [nil]
    var envp: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    guard posix_spawn(&pid, arguments[0], nil, nil, &argv, &envp) == 0 else {
      throw POSIXError(.ECHILD)
    }
    return pid
  }

  private func recover(_ scene: Scene, queue: UpdateQueue = UpdateQueue()) async throws
    -> RecoveryOperation
  {
    let operations = RecoveryOperation.enqueuePending(
      from: scene.journal, into: queue, helperIsIdle: { true })
    let operation = try XCTUnwrap(operations.first)
    operation.requiresTeam = false
    for _ in 0..<500 where !operation.isFinished { try await Task.sleep(for: .milliseconds(10)) }
    return operation
  }

  private func version(_ url: URL) -> String? {
    BundleCollector.collectBundle(at: url)?.version.versionNumber
  }

  func testKilledAfterTheOriginalMovedIsRestoredAtNextLaunch() async throws {
    let scene = try scene()
    let original = try FixtureApp.digest(scene.target)
    try await killDuring("originalAside", scene)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: scene.target.path), "the crash left a gap")
    XCTAssertEqual(scene.journal.pending().first?.phase, .originalAside)
    let recovery = try await recover(scene)
    XCTAssertEqual(recovery.result, .restored)
    XCTAssertEqual(try FixtureApp.digest(scene.target), original, "the original is back")
    XCTAssertTrue(scene.journal.pending().isEmpty, "settled, so the record is gone")
  }

  func testKilledAfterInstallingAVerifiedNewVersionKeepsIt() async throws {
    let scene = try scene()
    try await killDuring("installed", scene)
    XCTAssertEqual(version(scene.target), "1.1")
    let backup = try XCTUnwrap(scene.journal.pending().first?.backup)
    let recovery = try await recover(scene)
    XCTAssertEqual(recovery.result, .keptNewVersion("1.1"))
    XCTAssertEqual(version(scene.target), "1.1")
    XCTAssertFalse(FileManager.default.fileExists(atPath: backup), "the backup is discarded")
  }

  /// A valid copy of the same product that is neither the original nor newer: both are kept,
  /// the row fails with both paths, and nothing is deleted.
  func testAmbiguousStateKeepsBothCopies() async throws {
    let scene = try scene()
    try await killDuring("originalAside", scene)
    try FixtureApp.make(in: scene.target.deletingLastPathComponent(), version: "0.9")
    let record = try XCTUnwrap(scene.journal.pending().first)
    let recovery = try await recover(scene)
    guard case .ambiguous(let target, let backup) = recovery.result else {
      return XCTFail("expected ambiguous, got \(String(describing: recovery.result))")
    }
    XCTAssertEqual(target, scene.target.path)
    XCTAssertEqual(backup, record.backup)
    XCTAssertEqual(version(scene.target), "0.9")
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.backup), "nothing is deleted")
    guard case .failed(let reason, _) = recovery.outcomeOverride else { return XCTFail() }
    XCTAssertTrue(reason.contains(record.backup))
  }

  /// A writer that may still run (here a live process with the recorded start time) holds
  /// recovery, and jobs on the same target or tool wait, until it exits.
  func testSurvivingWriterBlocksRecoveryAndConflictingJobs() async throws {
    let scene = try scene()
    try await killDuring("originalAside", scene)
    let writer = try spawn(["/bin/sleep", "30"])
    var reaped = false
    defer {
      if !reaped {
        kill(writer, SIGKILL)
        var status: Int32 = 0
        waitpid(writer, &status, 0)
      }
    }
    var record = try XCTUnwrap(scene.journal.pending().first)
    record.writer = TransactionJournal.writer(pid: writer)
    try scene.journal.write(record)
    let alive = await TransactionJournal.mayBeRunning(record.writer, helperIsIdle: { true })
    XCTAssertTrue(alive)

    let queue = UpdateQueue()
    let operations = RecoveryOperation.enqueuePending(
      from: scene.journal, into: queue, helperIsIdle: { true })
    let recovery = try XCTUnwrap(operations.first)
    recovery.requiresTeam = false
    recovery.pollInterval = .milliseconds(50)
    let sameTarget = BlockedProbe(url: scene.target, lock: "unrelated")
    XCTAssertTrue(
      queue.submit(sameTarget) === recovery, "a job on the target gets the recovery job")
    let sameTool = BlockedProbe(url: URL(fileURLWithPath: "/tmp/Other.app"), lock: record.lockKey)
    queue.addOperation(sameTool)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertFalse(recovery.isFinished)
    XCTAssertFalse(sameTool.ran.withLock { $0 }, "the tool's jobs wait")
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.backup), "every copy is kept")
    if case .waitingForVendor(let status) = recovery.progressState {
      XCTAssertTrue(status.contains("Recovering"))
    } else {
      XCTFail("the row says it is recovering")
    }

    kill(writer, SIGKILL)
    var status: Int32 = 0
    waitpid(writer, &status, 0)
    reaped = true
    for _ in 0..<300 where !(recovery.isFinished && sameTool.ran.withLock { $0 }) {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(recovery.result, .restored)
    XCTAssertTrue(sameTool.ran.withLock { $0 }, "then the waiting job runs")
    XCTAssertEqual(version(scene.target), "1.0")
  }

  /// Clones are journaled too and the record goes when they settle.
  func testExternalInstallerClonesAreJournaledUntilSettled() async throws {
    let scene = try scene()
    let guarded = ExternalInstallGuard(target: scene.target, journal: scene.journal)
    try guarded.takeClone(mechanism: "sparkle", writer: .named(["Autoupdate"]))
    let record = try XCTUnwrap(scene.journal.pending().first)
    XCTAssertEqual(record.mechanism, "clone:sparkle")
    XCTAssertEqual(record.phase, .external)
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.backup))
    XCTAssertTrue(
      record.backup.hasPrefix(scene.journal.backups.path), "in Updater's own backup folder")
    _ = await guarded.settle(
      error: nil, expected: nil, requiresTeam: false,
      lifecycle: FakeTarget(running: false).lifecycle())
    XCTAssertTrue(scene.journal.pending().isEmpty)
  }
}

private final class BlockedProbe: UpdateOperation, @unchecked Sendable {
  let ran = Mutex(false)
  private let lock: String
  override var lockKey: String { lock }
  init(url: URL, lock: String) {
    self.lock = lock
    super.init(bundleIdentifier: "test.blocked", appIdentifier: url)
  }
  override func execute() {
    super.execute()
    ran.withLock { $0 = true }
    finish()
  }
}
