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
  var expectedVersion: String?
  var phase: Phase
  /// "replace" (Updater moves bundles itself) or "clone:<installer>".
  let mechanism: String
  var writer: Writer
  /// The scheduler lock of the job, so recovery holds back jobs on the same tool.
  let lockKey: String
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

  func pending() -> [TransactionRecord] {
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap {
      try? JSONDecoder().decode(TransactionRecord.self, from: Data(contentsOf: $0))
    }.sorted { $0.id < $1.id }
  }

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

/// Settles what an interrupted transaction left, once its writer has stopped: a missing or
/// unverified target is restored from the backup; a verified new version keeps it and drops
/// the backup; anything else keeps both and says where.
enum TransactionRecovery {
  enum Result: Equatable, Sendable {
    case restored
    case keptNewVersion(String)
    case unchanged
    case ambiguous(target: String, backup: String)
  }

  static func reconcile(_ record: TransactionRecord, requiresTeam: Bool = true) -> Result {
    let manager = FileManager.default
    let target = URL(fileURLWithPath: record.target)
    let backup = URL(fileURLWithPath: record.backup)
    let hasBackup = manager.fileExists(atPath: backup.path)
    let current = try? BundleIdentity.read(at: target, validate: true)
    let sameProduct =
      current.map {
        $0.bundleIdentifier == record.bundleIdentifier
          && (!requiresTeam || $0.teamIdentifier == record.teamIdentifier)
      } ?? false
    let original = Version(versionNumber: record.originalVersion, buildNumber: record.originalBuild)
    let installed = current.map {
      Version(versionNumber: $0.shortVersion, buildNumber: $0.bundleVersion)
    }

    if let installed, sameProduct, original.comparisonForUpdate(to: installed) == .older,
      record.expectedVersion.map({
        installed.comparisonForUpdate(to: Version(versionNumber: $0, buildNumber: nil)) != .older
      }) ?? true
    {
      dropBackup(record)
      return .keptNewVersion(installed.versionNumber ?? installed.buildNumber ?? "")
    }
    if let installed, sameProduct, installed == original {
      dropBackup(record)
      return .unchanged
    }
    guard hasBackup, current == nil || !sameProduct else {
      return .ambiguous(target: target.path, backup: backup.path)
    }
    // Missing, damaged or not the same product: the original goes back.
    do {
      try ReplacementTransaction.restore(
        target, backupDirectory: backup.deletingLastPathComponent(), originalIdentity: nil)
      for companion in record.companions where manager.fileExists(atPath: companion.saved) {
        let live = URL(fileURLWithPath: companion.live)
        if manager.fileExists(atPath: live.path) {
          try manager.moveItem(
            at: live,
            to: backup.deletingLastPathComponent().appendingPathComponent(
              "failed-companion-" + UUID().uuidString))
        }
        try manager.moveItem(at: URL(fileURLWithPath: companion.saved), to: live)
      }
      return .restored
    } catch {
      return .ambiguous(target: target.path, backup: backup.path)
    }
  }

  private static func dropBackup(_ record: TransactionRecord) {
    try? FileManager.default.removeItem(
      at: URL(fileURLWithPath: record.backup).deletingLastPathComponent())
  }
}

/// Holds a recovered target and its tool lock in the scheduler until the writer has stopped
/// and the transaction is reconciled, so no job (window, CLI or MCP) runs on them meanwhile.
final class RecoveryOperation: UpdateOperation, @unchecked Sendable {
  let record: TransactionRecord
  private let journal: TransactionJournal
  private let helperIsIdle: @Sendable () async -> Bool?
  var pollInterval: Duration = .seconds(2)
  var requiresTeam = true
  override var lockKey: String { record.lockKey }
  private(set) var result: TransactionRecovery.Result?

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
  }

  override func execute() {
    super.execute()
    Task.detached { [self] in
      progressState = .waitingForVendor("Recovering an interrupted update")
      while await TransactionJournal.mayBeRunning(record.writer, helperIsIdle: helperIsIdle) {
        try? await Task.sleep(for: pollInterval)
      }
      let result = TransactionRecovery.reconcile(record, requiresTeam: requiresTeam)
      self.result = result
      switch result {
      case .restored:
        outcomeOverride = .failed(
          reason: "Updater was interrupted while updating this app; the original was put back.",
          logPath: nil)
      case .keptNewVersion(let version):
        outcomeOverride = .updated(from: record.originalVersion ?? "?", to: version)
      case .unchanged:
        outcomeOverride = .noChange(reason: "An interrupted update had not changed the app.")
      case .ambiguous(let target, let backup):
        outcomeOverride = .failed(
          reason:
            "Updater was interrupted while updating this app and cannot tell which copy is right. Both are kept: \(target) and the original at \(backup).",
          logPath: nil)
      }
      journal.remove(record.id)
      finish()
    }
  }

  /// Every pending transaction goes back into the scheduler before any other job is accepted.
  static func enqueuePending(
    from journal: TransactionJournal, into queue: UpdateQueue,
    helperIsIdle: @escaping @Sendable () async -> Bool? = { await InstallHelper.isIdle() }
  ) -> [RecoveryOperation] {
    journal.pending().map { record in
      let operation = RecoveryOperation(
        record: record, journal: journal, helperIsIdle: helperIsIdle)
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
      do {
        let backupDirectory = try journal.backupDirectory(for: target, id: UUID().uuidString)
        let original = try BundleIdentity.read(at: target, validate: false)
        var record = TransactionRecord(
          id: backupDirectory.lastPathComponent, target: target.path,
          backup: backupDirectory.appendingPathComponent(ReplacementTransaction.backupName).path,
          bundleIdentifier: original.bundleIdentifier, teamIdentifier: original.teamIdentifier,
          originalVersion: original.shortVersion, originalBuild: original.bundleVersion,
          expectedVersion: nil, phase: .prepared, mechanism: "replace",
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
  }
#endif
