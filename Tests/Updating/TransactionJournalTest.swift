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
      from: scene.journal, into: queue, helperIsIdle: { true }
    ) {
      $0.requiresTeam = false
      $0.lifecycle = FakeTarget(running: false).lifecycle()
    }
    let operation = try XCTUnwrap(operations.first)
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
    XCTAssertEqual(recovery.result, .keptNewVersion("1.1"), "the probe recorded 1.1 as promised")
    XCTAssertEqual(version(scene.target), "1.1")
    XCTAssertFalse(FileManager.default.fileExists(atPath: backup), "the backup is discarded")
  }

  /// A valid copy of the same product that is neither the original nor newer: both are kept,
  /// the row fails with both paths, nothing is deleted, and the record stays (REV-004).
  func testAmbiguousStateKeepsBothCopiesAndTheRecord() async throws {
    let scene = try scene()
    try await killDuring("originalAside", scene)
    try FixtureApp.make(in: scene.target.deletingLastPathComponent(), version: "0.9")
    let record = try XCTUnwrap(scene.journal.pending().first)
    let recovery = try await recover(scene)
    guard case .unresolved(let reason) = recovery.result else {
      return XCTFail("expected unresolved, got \(String(describing: recovery.result))")
    }
    XCTAssertTrue(reason.contains(record.backup) && reason.contains(scene.target.path))
    XCTAssertEqual(version(scene.target), "0.9")
    XCTAssertTrue(FileManager.default.fileExists(atPath: record.backup), "nothing is deleted")
    XCTAssertEqual(scene.journal.pending().map(\.id), [record.id], "kept for the next launch")
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
      from: scene.journal, into: queue, helperIsIdle: { true }
    ) {
      $0.requiresTeam = false
      $0.pollInterval = .milliseconds(50)
      $0.lifecycle = FakeTarget(running: false).lifecycle()
    }
    let recovery = try XCTUnwrap(operations.first)
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

  /// REV-001: a tool (brew) starts suspended. Its PID and start time are journaled before it
  /// runs a single instruction; if that fails, it never runs.
  func testToolsRunOnlyAfterTheirWriterIsRecorded() async throws {
    let folder = try disposableDirectory()
    let marker = folder.appendingPathComponent("ran")
    let log = folder.appendingPathComponent("tool.log")
    struct JournalDown: Error {}
    do {
      _ = try await ToolProcess.run(
        URL(fileURLWithPath: "/usr/bin/touch"), [marker.path], log: log,
        beforeStart: { _ in throw JournalDown() })
      XCTFail("a failed journal write must stop the tool")
    } catch is JournalDown {}
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the tool never ran")

    let scene = try scene()
    let guarded = ExternalInstallGuard(target: scene.target, journal: scene.journal)
    try guarded.takeClone(mechanism: "homebrew", lockKey: "homebrew")
    let seenBeforeRun = Mutex<(TransactionRecord.Writer?, Bool)>((nil, true))
    let status = try await ToolProcess.run(
      URL(fileURLWithPath: "/usr/bin/touch"), [marker.path], log: log,
      beforeStart: { pid in
        try guarded.noteWriter(TransactionJournal.writer(pid: pid))
        let recorded = scene.journal.pending().first?.writer
        seenBeforeRun.withLock {
          $0 = (recorded, FileManager.default.fileExists(atPath: marker.path))
        }
      })
    XCTAssertEqual(status, 0)
    let (writer, ranEarly) = seenBeforeRun.withLock { $0 }
    guard case .process(_, let started)? = writer else { return XCTFail("PID journaled first") }
    XCTAssertGreaterThan(started, 0)
    XCTAssertFalse(ranEarly, "it was still suspended while its PID was journaled")
    XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "then it ran")
  }

  // MARK: Sol's inspection of 0.7.0 (UPD-001, UPD-003)

  /// UPD-001: saved progress is completed steps only; what to do is decided from the disk on
  /// every attempt, so an old "keep new" never deletes a backup the app now needs, and an old
  /// "restore" never overwrites an app that is now a verified new version.
  func testSavedDecisionsAreNeverTrustedOverTheDisk() async throws {
    let needed = try scene()
    var stale = try record(needed, expected: "1.1")
    stale.recovery = .init(decision: .keepNew)
    try needed.journal.write(stale)
    try FileManager.default.removeItem(at: needed.target)
    let restored = try await recover(needed).result
    XCTAssertEqual(restored, .restored, "the backup was needed, and used")
    XCTAssertEqual(version(needed.target), "1.0")

    let repaired = try scene()
    var old = try record(repaired, expected: "1.1")
    old.recovery = .init(decision: .restore)
    try repaired.journal.write(old)
    try replaceTarget(repaired, version: "1.1")
    let kept = try await recover(repaired).result
    XCTAssertEqual(kept, .keptNewVersion("1.1"), "the verified new app is not overwritten")
    XCTAssertEqual(version(repaired.target), "1.1")
  }

  /// UPD-004: Updater died after journaling a tool but before telling it to go. The tool
  /// waits on a pipe, sees it close and exits without running, so nobody has to kill it.
  func testToolWhoseParentDiedBeforeGoExitsByItselfAndRecoveryProceeds() async throws {
    let scene = try scene()
    let original = try FixtureApp.digest(scene.target)
    try await killDuring("toolRegistered", scene)
    let record = try XCTUnwrap(scene.journal.pending().first)
    guard case .process(let pid, _) = record.writer else { return XCTFail("tool PID journaled") }
    for _ in 0..<200 where TransactionJournal.startTime(of: pid) != nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNil(TransactionJournal.startTime(of: pid), "it exited on its own")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: scene.root.appendingPathComponent("tool-ran").path),
      "the tool never ran")
    let recovery = try await recover(scene)
    XCTAssertEqual(recovery.result, .unchanged)
    XCTAssertEqual(try FixtureApp.digest(scene.target), original)
    XCTAssertTrue(scene.journal.pending().isEmpty)
  }

  /// UPD-004: a recorded writer that is alive is never killed, even if it is stopped;
  /// recovery waits until it exits.
  func testLiveWriterIsNeverKilledEvenWhenStopped() async throws {
    let scene = try scene()
    try await killDuring("originalAside", scene)
    let writer = try spawn(["/bin/sleep", "30"])
    kill(writer, SIGSTOP)
    var reaped = false
    defer {
      if !reaped {
        kill(writer, SIGKILL)
        var status: Int32 = 0
        waitpid(writer, &status, 0)
      }
    }
    var entry = try XCTUnwrap(scene.journal.pending().first)
    entry.writer = TransactionJournal.writer(pid: writer)
    try scene.journal.write(entry)
    let recovery = try XCTUnwrap(
      RecoveryOperation.enqueuePending(
        from: scene.journal, into: UpdateQueue(), helperIsIdle: { true }
      ) {
        $0.requiresTeam = false
        $0.pollInterval = .milliseconds(50)
        $0.lifecycle = FakeTarget(running: false).lifecycle()
      }.first)
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertFalse(recovery.isFinished, "it waits")
    XCTAssertNotNil(TransactionJournal.startTime(of: writer), "and kills nothing")
    kill(writer, SIGKILL)
    var status: Int32 = 0
    waitpid(writer, &status, 0)
    reaped = true
    for _ in 0..<300 where !recovery.isFinished { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(recovery.result, .restored)
  }

  /// UPD-005: an incomplete restore leaves a journal; the queue holds that target and tool at
  /// once, and releases them when recovery settles it.
  func testPendingJournalHoldsTheTargetUntilRecoverySettlesIt() async throws {
    let scene = try scene()
    let queue = UpdateQueue(journal: scene.journal)
    let companion = scene.root.deletingLastPathComponent().appendingPathComponent("Caskroom-x")
    try FileManager.default.createDirectory(
      at: companion.appendingPathComponent("1.0"), withIntermediateDirectories: true)
    let job = IncompleteRestoreOperation(
      target: scene.target, companion: companion, journal: scene.journal)
    let done = expectation(description: "settled")
    job.completionBlock = { done.fulfill() }
    queue.addOperation(job)
    await fulfillment(of: [done], timeout: 10)
    guard case ReplacementError.incompleteRestore? = job.error as? ReplacementError else {
      return XCTFail("expected an incomplete restore, got \(String(describing: job.error))")
    }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(scene.journal.pending().count, 1)
    XCTAssertFalse(queue.heldBecause.isEmpty)
    let conflicting = BlockedProbe(url: scene.target, lock: "other")
    let sameTool = BlockedProbe(
      url: URL(fileURLWithPath: "/tmp/Other-\(UUID()).app"), lock: "homebrew")
    queue.addOperation(conflicting)
    queue.addOperation(sameTool)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(conflicting.ran.withLock { $0 }, "the target waits")
    XCTAssertFalse(sameTool.ran.withLock { $0 }, "so does its tool")

    let recovery = try XCTUnwrap(
      RecoveryOperation.enqueuePending(from: scene.journal, into: queue, helperIsIdle: { true }) {
        $0.requiresTeam = false
        $0.lifecycle = FakeTarget(running: false).lifecycle()
      }.first)
    for _ in 0..<300 where !(conflicting.ran.withLock { $0 } && sameTool.ran.withLock { $0 }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(recovery.result, .restored)
    XCTAssertTrue(conflicting.ran.withLock { $0 } && sameTool.ran.withLock { $0 }, "released")
    XCTAssertTrue(queue.heldBecause.isEmpty)
  }

  // MARK: Sol's inspection of 0.7.2 (REV-001, REV-002)

  private func incompleteRestore(_ scene: Scene, on queue: UpdateQueue) throws
    -> IncompleteRestoreOperation
  {
    let companion = scene.root.deletingLastPathComponent().appendingPathComponent(
      "Caskroom-\(UUID())")
    try FileManager.default.createDirectory(
      at: companion.appendingPathComponent("1.0"), withIntermediateDirectories: true)
    let job = IncompleteRestoreOperation(
      target: scene.target, companion: companion, journal: scene.journal)
    queue.addOperation(job)
    return job
  }

  private func settle(_ scene: Scene, on queue: UpdateQueue) throws -> RecoveryOperation {
    try XCTUnwrap(
      RecoveryOperation.enqueuePending(from: scene.journal, into: queue, helperIsIdle: { true }) {
        $0.requiresTeam = false
        $0.pollInterval = .milliseconds(50)
        $0.lifecycle = FakeTarget(running: false).lifecycle()
      }.first)
  }

  private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
  }

  /// REV-001: a job queued on the same tool before the restore went wrong is held too: the
  /// hold is in place before the restoring job counts as finished.
  func testJobQueuedBeforeAnIncompleteRestoreIsHeld() async throws {
    let scene = try scene()
    let queue = UpdateQueue(journal: scene.journal)
    let job = try incompleteRestore(scene, on: queue)
    let queuedBehind = BlockedProbe(
      url: URL(fileURLWithPath: "/tmp/Behind-\(UUID()).app"), lock: "homebrew")
    queue.addOperation(queuedBehind)
    try await waitFor { job.isFinished }
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(queuedBehind.ran.withLock { $0 }, "it was already waiting, and stays held")
    let recovery = try settle(scene, on: queue)
    try await waitFor { queuedBehind.ran.withLock { $0 } }
    XCTAssertEqual(recovery.result, .restored)
    XCTAssertTrue(queuedBehind.ran.withLock { $0 })
  }

  /// REV-001: a job queued behind a recovery that ends unresolved stays held.
  func testJobQueuedBeforeAnUnresolvedRecoveryIsHeld() async throws {
    let scene = try scene()
    let queue = UpdateQueue(journal: scene.journal)
    var entry = try record(scene, expected: nil, lockKey: "homebrew")
    try replaceTarget(scene, version: "0.9")  // neither the original nor newer: unresolved
    let writer = try spawn(["/bin/sleep", "30"])
    entry.writer = TransactionJournal.writer(pid: writer)
    try scene.journal.write(entry)
    let recovery = try settle(scene, on: queue)
    let queuedBehind = BlockedProbe(
      url: URL(fileURLWithPath: "/tmp/Behind-\(UUID()).app"), lock: "homebrew")
    queue.addOperation(queuedBehind)
    kill(writer, SIGKILL)
    var status: Int32 = 0
    waitpid(writer, &status, 0)
    try await waitFor { recovery.isFinished }
    try await Task.sleep(for: .milliseconds(300))
    guard case .unresolved = recovery.result else { return XCTFail("expected unresolved") }
    XCTAssertFalse(queuedBehind.ran.withLock { $0 }, "held while the entry is unresolved")
    XCTAssertFalse(queue.heldBecause.isEmpty)
  }

  /// REV-002: a held job keeps its place in its tool's line when recovery goes ahead of it, so
  /// a job submitted later waits for it.
  func testReleasedWaiterKeepsItsPlaceInTheToolLine() async throws {
    let scene = try scene()
    let queue = UpdateQueue(journal: scene.journal)
    let job = try incompleteRestore(scene, on: queue)
    try await waitFor { job.isFinished }
    let gate = AsyncStream<Void>.makeStream()
    let held = GatedProbe(
      url: URL(fileURLWithPath: "/tmp/Held-\(UUID()).app"), lock: "homebrew", gate: gate.stream)
    queue.addOperation(held)
    let recovery = try settle(scene, on: queue)
    try await waitFor { held.started.withLock { $0 != nil } }
    XCTAssertEqual(recovery.result, .restored)
    let later = GatedProbe(
      url: URL(fileURLWithPath: "/tmp/Later-\(UUID()).app"), lock: "homebrew", gate: nil)
    queue.addOperation(later)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertNil(later.started.withLock { $0 }, "it waits for the released job")
    gate.continuation.finish()
    try await waitFor { later.started.withLock { $0 != nil } }
    let heldEnd = try XCTUnwrap(held.ended.withLock { $0 })
    let laterStart = try XCTUnwrap(later.started.withLock { $0 })
    XCTAssertLessThanOrEqual(heldEnd, laterStart, "never overlapping on one tool")
  }

  // MARK: Sol's inspection (REV-002 to REV-006)

  private func record(
    _ scene: Scene, expected: String?, companions: [TransactionRecord.Companion] = [],
    lockKey: String? = nil
  ) throws -> TransactionRecord {
    let backupDirectory = try scene.journal.backupDirectory(
      for: scene.target, id: UUID().uuidString)
    let backup = backupDirectory.appendingPathComponent(ReplacementTransaction.backupName)
    try FileManager.default.copyItem(at: scene.target, to: backup)
    let record = TransactionRecord(
      id: backupDirectory.lastPathComponent, target: scene.target.path, backup: backup.path,
      companions: companions, bundleIdentifier: FixtureApp.identifier, teamIdentifier: nil,
      originalVersion: "1.0", originalBuild: "1.0", expectedVersion: expected,
      expectedBuild: expected, phase: .external, mechanism: "clone:homebrew",
      writer: .process(pid: 999_999, started: 1), lockKey: lockKey ?? "target:" + scene.target.path)
    try scene.journal.write(record)
    return record
  }

  private func replaceTarget(
    _ scene: Scene, version: String, identifier: String = FixtureApp.identifier
  ) throws {
    try FileManager.default.removeItem(at: scene.target)
    try FixtureApp.make(
      in: scene.target.deletingLastPathComponent(), identifier: identifier, version: version)
  }

  /// REV-002: a newer version is kept only if it reaches the version the route promised.
  func testNewVersionMustReachThePromisedVersion() async throws {
    let short = try scene()
    _ = try record(short, expected: "1.2")
    try replaceTarget(short, version: "1.1")
    let shortResult = try await recover(short).result
    guard case .unresolved = shortResult else {
      return XCTFail("short of 1.2: \(String(describing: shortResult))")
    }

    let unknown = try scene()
    _ = try record(unknown, expected: nil)
    try replaceTarget(unknown, version: "1.1")
    let unknownResult = try await recover(unknown).result
    guard case .unresolved = unknownResult else { return XCTFail("nothing was promised") }

    let reached = try scene()
    _ = try record(reached, expected: "1.1")
    try replaceTarget(reached, version: "1.1")
    let reachedResult = try await recover(reached).result
    XCTAssertEqual(reachedResult, .keptNewVersion("1.1"))

    // Routes record the promise in the clone's record, or as soon as it is known.
    let guarded = ExternalInstallGuard(target: try scene().target, journal: unknown.journal)
    try guarded.takeClone(mechanism: "sparkle", expected: nil)
    try guarded.noteExpected(Version(versionNumber: "2.0", buildNumber: "200"))
    let noted = try XCTUnwrap(unknown.journal.pending().first { $0.mechanism == "clone:sparkle" })
    XCTAssertEqual(noted.expectedVersion, "2.0")
    XCTAssertEqual(noted.expectedBuild, "200")
  }

  /// REV-003: recovery is journaled. A crash after the app was restored resumes with the
  /// Caskroom record; an untouched app still gets its records back before anything is deleted.
  func testRecoveryResumesAndPutsCompanionsBackBeforeDeleting() async throws {
    let scene = try scene()
    let live = scene.root.deletingLastPathComponent().appendingPathComponent("Caskroom-fixture")
    try Data("new".utf8).write(to: live)
    let savedDirectory = try scene.journal.backupDirectory(for: scene.target, id: "companions")
    let saved = savedDirectory.appendingPathComponent("companion-0")
    try Data("old".utf8).write(to: saved)
    // Crash after the app was restored and recorded, before the companion.
    var resumed = try record(
      scene, expected: "1.1", companions: [.init(live: live.path, saved: saved.path)])
    try FileManager.default.removeItem(atPath: resumed.backup)
    resumed.recovery = .init(decision: .restore, appRestored: true)
    try scene.journal.write(resumed)
    let result = try await recover(scene).result
    XCTAssertEqual(result, .restored)
    XCTAssertEqual(try String(contentsOf: live, encoding: .utf8), "old", "Caskroom record back")
    XCTAssertTrue(scene.journal.pending().isEmpty)

    // Untouched app, changed record: unchanged is settled only after the record agrees.
    let second = try self.scene()
    let live2 = second.root.deletingLastPathComponent().appendingPathComponent("Caskroom-2")
    try Data("brew's new".utf8).write(to: live2)
    let dir2 = try second.journal.backupDirectory(for: second.target, id: "companions-2")
    let saved2 = dir2.appendingPathComponent("companion-0")
    try Data("previous".utf8).write(to: saved2)
    _ = try record(
      second, expected: "1.1", companions: [.init(live: live2.path, saved: saved2.path)])
    let unchanged = try await recover(second).result
    XCTAssertEqual(unchanged, .unchanged)
    XCTAssertEqual(try String(contentsOf: live2, encoding: .utf8), "previous")
  }

  /// REV-004: nothing readable (an unplugged volume): the failure is recorded from the
  /// journal's own identity, the record stays, and a later attempt settles it.
  func testUnreadableTargetIsRecordedFromTheJournalAndRetried() async throws {
    let scene = try scene()
    let entry = try record(scene, expected: "1.1")
    let parked = scene.root.deletingLastPathComponent().appendingPathComponent("parked")
    try FileManager.default.moveItem(atPath: entry.backup, toPath: parked.path)
    try FileManager.default.removeItem(at: scene.target)
    let history = UpdateHistoryStore(
      fileURL: try disposableDirectory().appendingPathComponent("h.jsonl"))
    let first = try await recover(scene, queue: UpdateQueue(history: history))
    guard case .unresolved = first.result else { return XCTFail("nothing can be read") }
    XCTAssertEqual(history.latestEntry(for: scene.target)?.bundleIdentifier, FixtureApp.identifier)
    XCTAssertEqual(scene.journal.pending().map(\.id), [entry.id])
    // The volume comes back: the backup is there again and the next attempt restores.
    try FileManager.default.moveItem(atPath: parked.path, toPath: entry.backup)
    let second = try await recover(scene)
    XCTAssertEqual(second.result, .restored)
    XCTAssertEqual(version(scene.target), "1.0")
  }

  /// REV-005: a restore quits the target first, with consent; refused, everything is kept.
  func testRecoveryAsksBeforeQuittingAndKeepsEverythingIfRefused() async throws {
    let scene = try scene()
    let entry = try record(scene, expected: "1.1")
    try replaceTarget(scene, version: "5.0", identifier: "com.example.foreign")
    let operations = RecoveryOperation.enqueuePending(
      from: scene.journal, into: UpdateQueue(), helperIsIdle: { true }
    ) {
      $0.requiresTeam = false
      $0.lifecycle = AppLifecycle(
        runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
        confirmQuit: { _ in false }, reopen: { _ in })
    }
    let recovery = try XCTUnwrap(operations.first)
    for _ in 0..<300 where !recovery.isFinished { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertEqual(recovery.result, .needsQuit)
    XCTAssertEqual(
      BundleCollector.collectBundle(at: scene.target)?.bundleIdentifier, "com.example.foreign",
      "nothing was moved")
    XCTAssertTrue(FileManager.default.fileExists(atPath: entry.backup))
    XCTAssertEqual(scene.journal.pending().count, 1)
  }

  /// REV-006: an unreadable record holds its own target and tool, or everything when it names
  /// neither; a folder that cannot be listed holds everything.
  func testUnreadableRecordsFailClosed() async throws {
    let scoped = try scene()
    try FileManager.default.createDirectory(
      at: scoped.journal.directory, withIntermediateDirectories: true)
    try Data(#"{"target": "/tmp/Held.app", "lockKey": "homebrew"}"#.utf8)
      .write(to: scoped.journal.directory.appendingPathComponent("broken.json"))
    let queue = UpdateQueue()
    RecoveryOperation.enqueuePending(from: scoped.journal, into: queue, helperIsIdle: { true })
    let held = BlockedProbe(url: URL(fileURLWithPath: "/tmp/Held.app"), lock: "other")
    let sameTool = BlockedProbe(url: URL(fileURLWithPath: "/tmp/Else.app"), lock: "homebrew")
    let free = BlockedProbe(url: URL(fileURLWithPath: "/tmp/Free.app"), lock: "free")
    [held, sameTool, free].forEach(queue.addOperation)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertTrue(free.ran.withLock { $0 })
    XCTAssertFalse(held.ran.withLock { $0 }, "its target is held")
    XCTAssertFalse(sameTool.ran.withLock { $0 }, "its tool is held")
    XCTAssertEqual(queue.heldBecause.count, 1)

    let global = try scene()
    try FileManager.default.createDirectory(
      at: global.journal.directory, withIntermediateDirectories: true)
    try Data("not json".utf8).write(
      to: global.journal.directory.appendingPathComponent("torn.json"))
    let everything = UpdateQueue()
    RecoveryOperation.enqueuePending(from: global.journal, into: everything, helperIsIdle: { true })
    let any = BlockedProbe(url: URL(fileURLWithPath: "/tmp/Any.app"), lock: "any")
    everything.addOperation(any)
    try await Task.sleep(for: .milliseconds(300))
    XCTAssertFalse(any.ran.withLock { $0 }, "no scope: everything is held")

    let locked = try scene()
    try FileManager.default.createDirectory(
      at: locked.journal.directory, withIntermediateDirectories: true)
    chmod(locked.journal.directory.path, 0)
    defer { chmod(locked.journal.directory.path, 0o755) }
    XCTAssertNotNil(locked.journal.scan().failure)
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

/// Brew left a new app and record; putting the record back fails once (incomplete restore).
private final class IncompleteRestoreOperation: UpdateOperation, @unchecked Sendable {
  private let protection: ExternalInstallGuard
  private let companion: URL
  override var lockKey: String { "homebrew" }

  init(target: URL, companion: URL, journal: TransactionJournal) {
    self.companion = companion
    let moves = Mutex(0)
    protection = ExternalInstallGuard(target: target, journal: journal) { from, to in
      let move = moves.withLock {
        $0 += 1
        return $0
      }
      if move == 2 { throw CocoaError(.fileWriteNoPermission) }
      try FileManager.default.moveItem(at: from, to: to)
    }
    super.init(bundleIdentifier: FixtureApp.identifier, appIdentifier: target)
  }

  override func execute() {
    super.execute()
    Task { @MainActor [self] in
      do {
        try protection.takeClone(
          companions: [companion], mechanism: "homebrew", lockKey: lockKey,
          writer: .process(pid: 999_999, started: 1), expected: nil)
        try FileManager.default.removeItem(at: appIdentifier)
        try FixtureApp.make(in: appIdentifier.deletingLastPathComponent(), version: "1.1")
        try FileManager.default.removeItem(at: companion.appendingPathComponent("1.0"))
        try FileManager.default.createDirectory(
          at: companion.appendingPathComponent("1.1"), withIntermediateDirectories: true)
      } catch { return finish(with: error) }
      let result = await protection.settle(
        error: HomebrewError.failed(reason: "x", logPath: "/tmp/x"), expected: nil,
        requiresTeam: false,
        lifecycle: FakeTarget(running: false).lifecycle(), restoreOnInstallerFailure: true)
      if let result { finish(with: result) } else { finish() }
    }
  }
}

/// Records when it ran; with a gate it stays running until the gate closes.
private final class GatedProbe: UpdateOperation, @unchecked Sendable {
  let started = Mutex<ContinuousClock.Instant?>(nil)
  let ended = Mutex<ContinuousClock.Instant?>(nil)
  private let lock: String
  private let gate: AsyncStream<Void>?
  override var lockKey: String { lock }
  init(url: URL, lock: String, gate: AsyncStream<Void>?) {
    self.lock = lock
    self.gate = gate
    super.init(bundleIdentifier: "test.gated", appIdentifier: url)
  }
  override func execute() {
    super.execute()
    started.withLock { $0 = .now }
    Task.detached { [self] in
      if let gate { for await _ in gate {} }
      ended.withLock { $0 = .now }
      finish()
    }
  }
}
