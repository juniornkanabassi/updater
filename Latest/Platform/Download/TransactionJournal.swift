// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Darwin
import Foundation

/// One bundle replacement or clone in flight, written before the first change and kept until
/// it settles, so an interrupted update (a crash, a power cut) is put right at the next launch.
struct TransactionRecord: Codable, Equatable, Sendable {
  enum Phase: String, Codable, Sendable {
    /// Recorded, nothing changed yet.
    case prepared
    /// The original was moved into the backup folder; the target may be missing.
    case originalAside
    /// The candidate is at the target and has not been verified yet.
    case installed
    /// An installer Updater does not drive (Sparkle, brew, a vendor tool, the App Store
    /// helper) may be changing the target; the clone is the original.
    case external
  }

  /// Whoever may still be changing the target.
  enum Writer: Codable, Equatable, Sendable {
    /// A process, told apart from a later one with the same PID by its start time.
    case process(pid: Int32, started: Int64)
    /// Any running process with one of these executable names (Sparkle's Autoupdate).
    case named([String])
    /// The privileged App Store helper; it is asked whether it is idle.
    case helper
  }

  struct Companion: Codable, Equatable, Sendable {
    let live: String
    let saved: String
  }

  let id: String
  let target: String
  /// Where the original (moved or cloned) is kept.
  let backup: String
  var companions: [Companion] = []
  let bundleIdentifier: String?
  let teamIdentifier: String?
  let originalVersion: String?
  let originalBuild: String?
  /// The version the route promised (number and build), recorded before the change or as
  /// soon as it is known; recovery accepts a new version only if it reaches this.
  var expectedVersion: String?
  var expectedBuild: String? = nil
  var phase: Phase
  /// "replace" (Updater moves bundles itself) or "clone:<installer>".
  let mechanism: String
  var writer: Writer
  /// The scheduler lock of the job, so recovery holds back jobs on the same tool.
  let lockKey: String
  /// False while a tool is registered but not yet resumed (it starts suspended); nil or true
  /// once it may run. A registered, still-stopped tool never ran (UPD-003).
  var writerStarted: Bool? = nil
  /// Recovery's own progress, so a crash during recovery resumes where it stopped.
  var recovery: RecoveryProgress? = nil

  /// Completed steps only. What to do is decided from the disk on every attempt (UPD-001).
  struct RecoveryProgress: Codable, Equatable, Sendable {
    enum Decision: String, Codable, Sendable { case restore, keepNew, unchanged }
    /// Written by 0.7.0; read but never trusted.
    var decision: Decision? = nil
    var appRestored = false
    var companionsRestored: [Int] = []
  }
}

/// `~/Library/Application Support/Updater/transactions/<id>.json`, each write flushed to disk.
/// Backups live in `Updater/Backups` when that is on the target's volume (renames stay atomic),
/// otherwise in a clearly named `.Updater Backups` folder beside the target.
final class TransactionJournal: Sendable {
  let directory: URL
  let backups: URL

  init(root: URL) {
    directory = root.appendingPathComponent("transactions", isDirectory: true)
    backups = root.appendingPathComponent("Backups", isDirectory: true)
  }

  /// UPDATER_HOME for tests and test instances; a test process never writes to the real folder.
  static let shared: TransactionJournal = {
    let environment = ProcessInfo.processInfo.environment
    if let home = environment["UPDATER_HOME"], !home.isEmpty {
      return TransactionJournal(root: URL(fileURLWithPath: home))
    }
    if environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil {
      return TransactionJournal(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterTestJournal"))
    }
    return TransactionJournal(
      root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Updater"))
  }()

  /// A fresh folder for one job's backup (and staged candidate) on the target's volume.
  func backupDirectory(for target: URL, id: String) throws -> URL {
    let manager = FileManager.default
    try manager.createDirectory(at: backups, withIntermediateDirectories: true)
    let folder = target.deletingLastPathComponent()
    let root =
      Self.sameVolume(backups, folder) ? backups : folder.appendingPathComponent(".Updater Backups")
    let directory = root.appendingPathComponent(id, isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func sameVolume(_ first: URL, _ second: URL) -> Bool {
    let key = URLResourceKey.volumeIdentifierKey
    guard let a = try? first.resourceValues(forKeys: [key]).volumeIdentifier,
      let b = try? second.resourceValues(forKeys: [key]).volumeIdentifier
    else { return false }
    return a.isEqual(b)
  }

  /// Written to a temporary file, flushed, renamed into place and the folder flushed, so a
  /// crash leaves either the previous phase or the new one, never a torn record.
  func write(_ record: TransactionRecord) throws {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(record)
    let final = directory.appendingPathComponent("\(record.id).json")
    let temporary = directory.appendingPathComponent("\(record.id).json.tmp")
    manager.createFile(atPath: temporary.path, contents: nil)
    let handle = try FileHandle(forWritingTo: temporary)
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    guard rename(temporary.path, final.path) == 0 else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: final.path])
    }
    Self.flush(directory)
  }

  func remove(_ id: String) {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).json"))
    Self.flush(directory)
  }

  /// What is on disk: readable records, and files that could not be read (with whatever
  /// scope could still be recovered from them). A folder that cannot be listed is a failure.
  struct Scan: Sendable {
    var records: [TransactionRecord] = []
    var unreadable: [(file: URL, target: String?, lockKey: String?)] = []
    var failure: String?
  }

  func scan() -> Scan {
    var scan = Scan()
    let files: [URL]
    do {
      files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)
    } catch CocoaError.fileReadNoSuchFile {
      return scan
    } catch {
      scan.failure =
        "The recovery records in \(directory.path) cannot be listed: \(error.localizedDescription)"
      return scan
    }
    for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
      guard let data = try? Data(contentsOf: file),
        let record = try? JSONDecoder().decode(TransactionRecord.self, from: data)
      else {
        let object = (try? Data(contentsOf: file)).flatMap {
          try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        scan.unreadable.append((file, object?["target"] as? String, object?["lockKey"] as? String))
        continue
      }
      scan.records.append(record)
    }
    return scan
  }

  func pending() -> [TransactionRecord] { scan().records }

  private static func flush(_ directory: URL) {
    let descriptor = open(directory.path, O_RDONLY)
    guard descriptor >= 0 else { return }
    fsync(descriptor)
    close(descriptor)
  }

  // MARK: Writers

  static func writer(pid: Int32 = getpid()) -> TransactionRecord.Writer {
    .process(pid: pid, started: startTime(of: pid) ?? 0)
  }

  /// A tool registered but never resumed (Updater stopped between journaling it and letting
  /// it run) is still stopped: it never ran, so it is killed and recovery goes on.
  static func stopUnstartedWriter(_ record: TransactionRecord) {
    guard record.writerStarted == false, case .process(let pid, let started) = record.writer else {
      return
    }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
      Int64(info.pbi_start_tvsec) == started, info.pbi_status == UInt32(SSTOP)
    else { return }
    kill(pid, SIGKILL)
    for _ in 0..<100 where startTime(of: pid) != nil { usleep(10_000) }
  }

  static func startTime(of pid: Int32) -> Int64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Int64(info.pbi_start_tvsec)
  }

  /// Whether the writer may still be changing the target. An unreachable helper counts as
  /// running: copies are kept until it can be asked.
  static func mayBeRunning(
    _ writer: TransactionRecord.Writer, helperIsIdle: @Sendable () async -> Bool?
  ) async -> Bool {
    switch writer {
    case .process(let pid, let started):
      guard let now = startTime(of: pid) else { return false }
      return started == 0 || now == started
    case .named(let names):
      return runningExecutableNames().contains { names.contains($0) }
    case .helper:
      return await helperIsIdle() != true
    }
  }

  private static func runningExecutableNames() -> Set<String> {
    var pids = [pid_t](repeating: 0, count: 4096)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var path = [CChar](repeating: 0, count: 4096)
    var names = Set<String>()
    for pid in pids.prefix(max(0, count)) where pid > 0 {
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
      names.insert((String(cString: path) as NSString).lastPathComponent)
    }
    return names
  }
}

/// Settles what an interrupted transaction left, once its writer has stopped. Every step is
/// journaled, so a crash during recovery resumes it; nothing is deleted until it settles.
enum TransactionRecovery {
  enum Outcome: Equatable, Sendable {
    case restored
    case keptNewVersion(String)
    case unchanged
    /// Kept as it is, both copies in place, the record kept for the next launch or mount.
    case unresolved(String)
    /// The target is open and its quit was refused; retried later.
    case needsQuit
  }

  /// What to do, decided once from the disk and the record: restore a missing, damaged or
  /// foreign target; keep a new version only if it passes the route's checks against the
  /// promised version; an untouched app is unchanged; anything else is unresolved.
  static func decide(_ record: TransactionRecord, requiresTeam: Bool) -> TransactionRecord
    .RecoveryProgress.Decision?
  {
    let target = URL(fileURLWithPath: record.target)
    let hasBackup = FileManager.default.fileExists(atPath: record.backup)
    let current = try? BundleIdentity.read(at: target, validate: true)
    let sameProduct =
      current.map {
        $0.bundleIdentifier == record.bundleIdentifier && $0.teamIdentifier == record.teamIdentifier
          && (!requiresTeam || record.teamIdentifier != nil)
      } ?? false
    let original = Version(versionNumber: record.originalVersion, buildNumber: record.originalBuild)
    if let current, sameProduct {
      let installed = Version(
        versionNumber: current.shortVersion, buildNumber: current.bundleVersion)
      if current.shortVersion == record.originalVersion
        && current.bundleVersion == record.originalBuild
      {
        return .unchanged
      }
      // A newer version is accepted only against what the route promised.
      if let expected = record.expectedVersion ?? record.expectedBuild,
        !expected.isEmpty,
        (try? ReplacementTransaction.verifyVersion(
          installed: installed, previous: original,
          expected: Version(
            versionNumber: record.expectedVersion, buildNumber: record.expectedBuild)))
          != nil
      {
        return .keepNew
      }
      return nil
    }
    return hasBackup ? .restore : nil
  }

  static func installedVersion(_ record: TransactionRecord) -> String {
    let current = try? BundleIdentity.read(at: URL(fileURLWithPath: record.target), validate: false)
    return current?.shortVersion ?? current?.bundleVersion ?? "?"
  }

  /// Puts the original back. Restartable: a crash after the swap leaves the original at the
  /// target and no backup, which counts as done.
  static func restoreApp(_ record: TransactionRecord) throws {
    let manager = FileManager.default
    let target = URL(fileURLWithPath: record.target)
    let backup = URL(fileURLWithPath: record.backup)
    guard manager.fileExists(atPath: backup.path) else {
      let current = try? BundleIdentity.read(at: target, validate: false)
      guard current?.bundleIdentifier == record.bundleIdentifier,
        current?.shortVersion == record.originalVersion,
        current?.bundleVersion == record.originalBuild
      else { throw ReplacementError.restoreFailed(record.backup) }
      return
    }
    try ReplacementTransaction.restore(
      target, backupDirectory: backup.deletingLastPathComponent(), originalIdentity: nil)
  }

  /// One companion record back (Homebrew's Caskroom entry). Restartable the same way.
  static func restoreCompanion(_ companion: TransactionRecord.Companion, aside: URL) throws {
    let manager = FileManager.default
    guard manager.fileExists(atPath: companion.saved) else { return }  // already moved back
    if manager.fileExists(atPath: companion.live) {
      try manager.moveItem(
        at: URL(fileURLWithPath: companion.live),
        to: aside.appendingPathComponent("failed-companion-" + UUID().uuidString))
    }
    try manager.moveItem(
      at: URL(fileURLWithPath: companion.saved), to: URL(fileURLWithPath: companion.live))
  }
}

/// Holds a recovered target and its tool lock in the scheduler until the writer has stopped
/// and the transaction is reconciled, so no job (window, CLI or MCP) runs on them meanwhile.
final class RecoveryOperation: UpdateOperation, @unchecked Sendable {
  private(set) var record: TransactionRecord
  private let journal: TransactionJournal
  private let helperIsIdle: @Sendable () async -> Bool?
  var pollInterval: Duration = .seconds(2)
  var requiresTeam = true
  /// A restore quits the target first, with the user's consent, like any update.
  var lifecycle = AppLifecycle.live
  override var lockKey: String { record.lockKey }
  private(set) var result: TransactionRecovery.Outcome?

  init(
    record: TransactionRecord, journal: TransactionJournal,
    helperIsIdle: @escaping @Sendable () async -> Bool? = { await InstallHelper.isIdle() }
  ) {
    self.record = record
    self.journal = journal
    self.helperIsIdle = helperIsIdle
    super.init(
      bundleIdentifier: record.bundleIdentifier ?? "",
      appIdentifier: URL(fileURLWithPath: record.target))
    // The journal's identity stands in for history when neither copy can be read.
    recordedIdentity = App.Bundle(
      version: Version(versionNumber: record.originalVersion, buildNumber: record.originalBuild),
      name: URL(fileURLWithPath: record.target).deletingPathExtension().lastPathComponent,
      bundleIdentifier: record.bundleIdentifier ?? "", fileURL: URL(fileURLWithPath: record.target),
      source: .none, modificationDate: .distantPast)
  }

  override func execute() {
    super.execute()
    Task { @MainActor [self] in
      progressState = .waitingForVendor("Recovering an interrupted update")
      TransactionJournal.stopUnstartedWriter(record)
      while await TransactionJournal.mayBeRunning(record.writer, helperIsIdle: helperIsIdle) {
        try? await Task.sleep(for: pollInterval)
      }
      let outcome = await reconcile()
      result = outcome
      switch outcome {
      case .restored:
        outcomeOverride = .failed(
          reason: "Updater was interrupted while updating this app; the original was put back.",
          logPath: nil)
      case .keptNewVersion(let version):
        outcomeOverride = .updated(from: record.originalVersion ?? "?", to: version)
      case .unchanged:
        outcomeOverride = .noChange(reason: "An interrupted update had not changed the app.")
      case .unresolved(let reason):
        outcomeOverride = .failed(reason: reason, logPath: nil)
      case .needsQuit:
        outcomeOverride = .needsQuit
      }
      finish()
    }
  }

  /// Settled outcomes remove the record and the backup; unresolved and refused ones keep both
  /// for the next launch or volume mount.
  @MainActor private func reconcile() async -> TransactionRecovery.Outcome {
    let unresolved = TransactionRecovery.Outcome.unresolved(
      "Updater was interrupted while updating this app and cannot settle it yet. Both copies are kept: \(record.target) and the original at \(record.backup)."
    )
    var done = record.recovery ?? .init()
    // Decided from the disk on every attempt. Once a step is done the app must be the
    // original (restored or untouched), checked again here.
    let decision: TransactionRecord.RecoveryProgress.Decision
    let fresh = TransactionRecovery.decide(record, requiresTeam: requiresTeam)
    if done.appRestored || !done.companionsRestored.isEmpty {
      guard fresh == .unchanged else { return unresolved }
      decision = done.appRestored ? .restore : .unchanged
    } else {
      guard let fresh else { return unresolved }
      decision = fresh
    }
    let target = URL(fileURLWithPath: record.target)
    let aside = URL(fileURLWithPath: record.backup).deletingLastPathComponent()
    var wasRunning = false
    do {
      if decision == .restore, !done.appRestored {
        do {
          wasRunning = try await lifecycle.quit(
            at: target, name: target.deletingPathExtension().lastPathComponent)
        } catch { return .needsQuit }
        try TransactionRecovery.restoreApp(record)
        done.appRestored = true
        record.recovery = done
        try journal.write(record)
      }
      // The app's records follow the app: back with a restored or untouched app, kept with
      // a verified new one.
      if decision != .keepNew {
        for (index, companion) in record.companions.enumerated()
        where !done.companionsRestored.contains(index) {
          try TransactionRecovery.restoreCompanion(companion, aside: aside)
          done.companionsRestored.append(index)
          record.recovery = done
          try journal.write(record)
        }
      }
    } catch {
      return unresolved
    }
    if wasRunning { lifecycle.reopen(target) }
    // Immediately before deleting anything: the disk must still say what was decided.
    let final = TransactionRecovery.decide(record, requiresTeam: requiresTeam)
    guard decision == .keepNew ? final == .keepNew : final == .unchanged else { return unresolved }
    try? FileManager.default.removeItem(at: aside)
    journal.remove(record.id)
    switch decision {
    case .restore: return .restored
    case .unchanged: return .unchanged
    case .keepNew: return .keptNewVersion(TransactionRecovery.installedVersion(record))
    }
  }

  /// Every pending transaction goes back into the scheduler before any other job is accepted.
  /// Records that cannot be read hold their target (or, with no scope, every job) and say why.
  @discardableResult
  static func enqueuePending(
    from journal: TransactionJournal, into queue: UpdateQueue,
    helperIsIdle: @escaping @Sendable () async -> Bool? = { await InstallHelper.isIdle() },
    configure: (RecoveryOperation) -> Void = { _ in }
  ) -> [RecoveryOperation] {
    let scan = journal.scan()
    if let failure = scan.failure { queue.hold(target: nil, lockKey: nil, reason: failure) }
    for unreadable in scan.unreadable {
      queue.hold(
        target: unreadable.target, lockKey: unreadable.lockKey,
        reason:
          "The recovery record \(unreadable.file.path) cannot be read; Updater will not change \(unreadable.target ?? "any app") until it is fixed or removed."
      )
    }
    return scan.records.map { record in
      let operation = RecoveryOperation(
        record: record, journal: journal, helperIsIdle: helperIsIdle)
      configure(operation)
      queue.addOperation(operation)
      return operation
    }
  }
}

#if DEBUG
  /// Debug-only test probe: a separate process that journals a real replacement and stops at
  /// a chosen phase, so a test can kill it there and check what the next launch reconciles.
  /// `--journal-crash-probe <journal root> <target> <candidate> <phase>`.
  enum JournalCrashProbe {
    static func run(_ arguments: [String]) -> Never {
      guard arguments.count == 4 else { exit(2) }
      let root = URL(fileURLWithPath: arguments[0])
      let target = URL(fileURLWithPath: arguments[1])
      let candidate = URL(fileURLWithPath: arguments[2])
      let stop = arguments[3]
      let journal = TransactionJournal(root: root)
      if stop == "toolRegistered" { toolRegistered(journal: journal, target: target, root: root) }
      do {
        let backupDirectory = try journal.backupDirectory(for: target, id: UUID().uuidString)
        let original = try BundleIdentity.read(at: target, validate: false)
        let promised = try BundleIdentity.read(at: candidate, validate: false)
        var record = TransactionRecord(
          id: backupDirectory.lastPathComponent, target: target.path,
          backup: backupDirectory.appendingPathComponent(ReplacementTransaction.backupName).path,
          bundleIdentifier: original.bundleIdentifier, teamIdentifier: original.teamIdentifier,
          originalVersion: original.shortVersion, originalBuild: original.bundleVersion,
          expectedVersion: promised.shortVersion, expectedBuild: promised.bundleVersion,
          phase: .prepared, mechanism: "replace",
          writer: TransactionJournal.writer(), lockKey: "target:" + target.path)
        try ReplacementTransaction.perform(
          at: target, backupDirectory: backupDirectory,
          install: { try FileManager.default.moveItem(at: candidate, to: target) },
          verify: { _ in },
          onPhase: { phase in
            record.phase =
              switch phase {
              case .prepared: .prepared
              case .originalAside: .originalAside
              case .installed: .installed
              }
            try journal.write(record)
            if "\(phase)" == stop {
              FileManager.default.createFile(
                atPath: root.appendingPathComponent("reached").path, contents: nil)
              while true { pause() }
            }
          })
      } catch {
        exit(1)
      }
      exit(0)
    }

    /// Clones the target as Homebrew does, then starts a tool that stays suspended: the probe
    /// stops for good right after journaling it, before it would resume it.
    private static func toolRegistered(journal: TransactionJournal, target: URL, root: URL) -> Never
    {
      let guarded = ExternalInstallGuard(target: target, journal: journal)
      do { try guarded.takeClone(mechanism: "homebrew", lockKey: "homebrew") } catch { exit(1) }
      Task.detached {
        _ = try? await ToolProcess.run(
          URL(fileURLWithPath: "/bin/sleep"), ["60"], log: root.appendingPathComponent("tool.log"),
          beforeStart: { pid in
            try guarded.noteWriter(TransactionJournal.writer(pid: pid), started: false)
            FileManager.default.createFile(
              atPath: root.appendingPathComponent("reached").path, contents: nil)
            while true { pause() }
          })
      }
      dispatchMain()
    }
  }
#endif
