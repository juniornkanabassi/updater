//
//  UpdateQueue.swift
//  Latest
//
//  Created by Max Langer on 01.07.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import Foundation
import Synchronization

/// The update scheduler. GUI and Update All submit here (CLI and MCP will too): one job
/// per target URL, jobs sharing a `lockKey` run one after another, and every finished job
/// is turned into an `UpdateOutcome` by re-reading the bundle at its URL.
class UpdateQueue: OperationQueue, @unchecked Sendable {

  /// Nil keeps test queues from writing to the user's history.
  let history: UpdateHistoryStore?
  private let readBundle: @Sendable (URL) -> App.Bundle?
  /// Pending entries here hold their target and tool until recovery settles them.
  let journal: TransactionJournal

  // MARK: - Initialization
  init(
    history: UpdateHistoryStore? = nil, journal: TransactionJournal = .shared,
    readBundle: @escaping @Sendable (URL) -> App.Bundle? = { BundleCollector.collectBundle(at: $0) }
  ) {
    self.history = history
    self.journal = journal
    self.readBundle = readBundle
    super.init()

    self.maxConcurrentOperationCount = 3
  }

  /// The shared instance of the queue.
  static let shared = UpdateQueue(history: .shared)

  private let operationIndexLock = NSLock()

  private var operationsByIdentifier = [App.Bundle.Identifier: UpdateOperation]()
  /// How recent jobs ended, by job id, so any job id handed out (by the window's jobs too)
  /// can be looked up after it finishes. Bounded; guarded by the index lock.
  private var finishedJobs = [String: UpdateJobRecord]()
  private var finishedOrder = [String]()
  /// Jobs held back by an interrupted update still to settle (released when it settles) or by
  /// a recovery record that cannot be read (kept until relaunch): by target, tool, or all.
  /// Held jobs wait on a barrier that only runs when the hold is released (no slot used).
  private struct Hold {
    let barrier = BlockOperation {}
    var reason: String
    let releasable: Bool
    /// The targets whose pending journals share this hold (a tool lock can serve several).
    var owners: Set<String> = []
  }
  private var holds = [String: Hold]()
  /// Jobs waiting on a hold. Recovery, which releases the hold, must not wait on them.
  private var heldOperations = Set<ObjectIdentifier>()

  /// Unfinished jobs by id, kept until their record replaces them in one step, so a job id
  /// never stops resolving between `isFinished` and the completion block.
  private var jobsByID = [String: UpdateOperation]()
  /// Unfinished jobs per lock, in submission order. A new job depends on all of them: a
  /// cancelled waiter becomes ready at once, so depending only on the last one would let
  /// the newcomer overtake the running holder.
  private var operationsByLock = [String: [UpdateOperation]]()

  // MARK: - Public Methods

  /// Cancels the update operation for the given app.
  func cancelUpdate(for identifier: App.Bundle.Identifier) {
    guard let operation = self.operation(for: identifier) else { return }
    operation.cancel()
  }

  @MainActor
  func retryTermination(for identifier: App.Bundle.Identifier) {
    operation(for: identifier)?.retryTermination()
  }

  /// The unfinished job for the app, if any.
  func jobID(for identifier: App.Bundle.Identifier) -> String? {
    operation(for: identifier)?.jobID
  }

  /// Holds every later job on this target or tool (or every job, with neither). Releasable
  /// holds belong to a pending journal entry and go when it settles; others last until relaunch.
  func hold(target: String?, lockKey: String?, reason: String, releasable: Bool = false) {
    let owner = target.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    var keys = [String]()
    if let owner { keys.append("target:" + owner) }
    if let lockKey { keys.append("lock:" + lockKey) }
    if keys.isEmpty { keys = ["all"] }
    operationIndexLock.withLock {
      for key in keys {
        var hold = holds[key] ?? Hold(reason: reason, releasable: releasable)
        if let owner { hold.owners.insert(owner) }
        holds[key] = hold
      }
    }
  }

  /// Ends the releasable holds a settled target had; a tool lock stays held while another
  /// pending entry shares it.
  private func releaseHolds(of target: String) {
    let barriers = operationIndexLock.withLock { () -> [BlockOperation] in
      var released = [BlockOperation]()
      for (key, var hold) in holds where hold.releasable && hold.owners.contains(target) {
        hold.owners.remove(target)
        if hold.owners.isEmpty {
          holds[key] = nil
          released.append(hold.barrier)
        } else {
          holds[key] = hold
        }
      }
      return released
    }
    barriers.forEach { $0.start() }
  }

  /// After every job: a journal entry left for its target (an incomplete or refused restore,
  /// an unresolved recovery) holds the target and tool at once; none left releases them.
  private func reconcileHolds(after operation: UpdateOperation) {
    let target = operation.appIdentifier.standardizedFileURL.path
    if let pending = journal.scan().records.first(where: {
      URL(fileURLWithPath: $0.target).standardizedFileURL.path == target
    }) {
      hold(
        target: pending.target, lockKey: pending.lockKey,
        reason:
          "An interrupted update of \(pending.target) is not settled yet; its original is kept at \(pending.backup).",
        releasable: true)
    } else {
      releaseHolds(of: target)
    }
  }

  /// Why jobs are held, for status reports.
  var heldBecause: [String] {
    operationIndexLock.withLock { Array(Set(holds.values.map(\.reason))).sorted() }
  }

  /// A job by id: running or waiting (its current state), or finished (how it ended).
  func job(withID id: String) -> UpdateJob? {
    operationIndexLock.withLock {
      if let record = finishedJobs[id] {
        return UpdateJob(id: id, appURL: record.appURL, state: nil, record: record)
      }
      guard let operation = jobsByID[id] else { return nil }
      // Finished but its completion block has not run yet: report how it ended already.
      guard !operation.isFinished else {
        let record = Self.record(of: operation)
        return UpdateJob(id: id, appURL: record.appURL, state: nil, record: record)
      }
      return UpdateJob(
        id: id, appURL: operation.appIdentifier, state: operation.progressState, record: nil)
    }
  }

  /// Whether the queue contains an update operation for the given app.
  func contains(_ identifier: App.Bundle.Identifier) -> Bool {
    return self.operation(for: identifier) != nil
  }

  /// Returns the state for a given app. With no job running, a recorded failure that still
  /// describes the bundle on disk is shown, so a reloaded row keeps its error.
  func state(for identifier: App.Bundle.Identifier) -> UpdateOperation.ProgressState {
    if let operation = self.operation(for: identifier) { return operation.progressState }
    guard let entry = history?.latestEntry(for: identifier),
      UpdateOutcomeError(outcome: entry.outcome) != nil,
      let current = readBundle(identifier), entry.describes(current)
    else { return .none }
    return .error(UpdateOutcomeError(outcome: entry.outcome)!)
  }

  override func addOperation(_ op: Operation) {
    // Abort if the operation is of an unknown type
    guard let operation = op as? UpdateOperation else {
      assertionFailure("Added unknown operation \(op.self) to update queue.")
      return
    }
    submit(operation)
  }

  /// Schedules the job, or returns the job already scheduled for the same target URL.
  @discardableResult
  func submit(_ operation: UpdateOperation) -> UpdateOperation {
    if let existing = index(operation) { return existing }
    if !ExternalHandOff.allowed { operation.allowsExternalHandOff = false }
    let before = readBundle(operation.appIdentifier)

    operation.resolveOutcome = { [weak self] operation in
      self?.resolveOutcome(of: operation, before: before)
    }
    let previousCompletionBlock = operation.completionBlock
    operation.completionBlock = { [weak self, weak operation] in
      previousCompletionBlock?()

      guard let self, let operation else { return }
      self.removeIndexedOperation(operation)
      self.reconcileHolds(after: operation)
      // A clean finish (a declined quit records nothing) published .none while the job was
      // still indexed; republish so the row falls back to history and an earlier failure
      // shows again. A terminal error stays as published.
      if operation.error == nil { self.publishState(for: operation.appIdentifier) }
      NotificationCenter.default.post(name: .latestUpdateQueueDidChange, object: self)
    }

    operation.progressHandler = { [weak self] identifier in
      self?.publishState(for: identifier)
    }

    super.addOperation(operation)
    NotificationCenter.default.post(name: .latestUpdateQueueDidChange, object: self)
    return operation
  }

  /// Hand-offs happen outside the queue; record them so the row can say so.
  func recordHandOff(of app: App) {
    // The window's hand-off actions open their target directly.
    let note = HandOffNote(
      destination: app.externalUpdaterName ?? app.name, reason: "Opened from Updater.",
      opened: true, blockedByPolicy: false)
    history?.record(
      UpdateHistoryEntry(before: app.bundle, after: app.bundle, outcome: .handedOff, handOff: note))
  }

  /// Called by the job as it finishes, before its terminal state is published.
  private func resolveOutcome(of operation: UpdateOperation, before: App.Bundle?) -> UpdateOutcome?
  {
    let after = readBundle(operation.appIdentifier)
    // A recovery job may start with the target missing, or find neither copy readable; its
    // outcome is set by itself and its record of the app stands in.
    let fallback = operation.outcomeOverride != nil ? (after ?? operation.recordedIdentity) : nil
    guard let before = before ?? fallback else { return nil }
    guard let outcome = Self.outcome(of: operation, before: before, after: after) else {
      return nil
    }
    history?.record(
      UpdateHistoryEntry(
        before: before, after: after, outcome: outcome, handOff: operation.handOffNote))
    return outcome
  }

  /// Success is never taken from the installer's word: `updated` needs the version on
  /// disk at the exact URL to have changed. User cancellation records nothing.
  static func outcome(of operation: UpdateOperation, before: App.Bundle, after: App.Bundle?)
    -> UpdateOutcome?
  {
    // User cancellation or a declined quit prompt is not an outcome (a declined quit after
    // the commit point finishes without cancelling, so it is checked by itself).
    if operation.quitDeclined && operation.error == nil { return nil }
    if operation.error is CancellationError || (operation.isCancelled && operation.error == nil) {
      return operation.error == nil ? nil : operation.outcomeOverride
    }
    // A real error (a failed restore, say) beats a hand-off; the hand-off stands only when
    // settling finished cleanly.
    if operation.error == nil, let outcome = operation.outcomeOverride { return outcome }
    if let error = operation.error {
      if case AppDownloadError.applicationStillRunning = error { return .needsQuit }
      if case HomebrewError.needsAdministrator = error {
        return .needsPermission(kind: "administrator")
      }
      if case HomebrewError.failed(let reason, let logPath) = error {
        return .failed(reason: reason, logPath: logPath)
      }
      if case VendorToolError.failed(let reason, let logPath) = error {
        return .failed(reason: reason, logPath: logPath)
      }
      let nsError = error as NSError
      if (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteNoPermissionError)
        || (nsError.domain == NSPOSIXErrorDomain
          && [Int(EPERM), Int(EACCES)].contains(nsError.code))
      {
        return .needsPermission(kind: "appManagement")
      }
      return .failed(reason: error.localizedDescription, logPath: nil)
    }
    guard let after else {
      return .failed(reason: "The app is no longer at \(before.fileURL.path).", logPath: nil)
    }
    if after.version == before.version { return .noChange(reason: operation.noChangeReason) }
    switch before.version.comparisonForUpdate(to: after.version) {
    case .older:
      do {
        try ReplacementTransaction.verifyVersion(
          installed: after.version, previous: before.version, expected: operation.expectedVersion)
        return .updated(from: display(before.version), to: display(after.version))
      } catch {
        return .failed(reason: error.localizedDescription, logPath: nil)
      }
    case .samePrecedence: return .noChange(reason: operation.noChangeReason)
    case .newer, .unavailable:
      return .failed(
        reason:
          "The installed version changed from \(display(before.version)) to \(display(after.version)), which is not an update.",
        logPath: nil)
    }
  }

  static func display(_ version: Version) -> String {
    version.versionNumber ?? version.buildNumber ?? ""
  }

  // MARK: - State Feeds

  /// Bounded structured-concurrency feeds used by SwiftUI rows.
  private let stateFeedLock = NSLock()
  private var stateContinuations = [
    App.Bundle.Identifier: [UUID: AsyncStream<UpdateOperation.ProgressState>.Continuation]
  ]()

  @MainActor
  func states(for identifier: App.Bundle.Identifier) -> AsyncStream<UpdateOperation.ProgressState> {
    makeStateFeed(for: identifier, includesCurrentState: true).changes
  }

  /// Registers a stream and captures current progress under the publication lock,
  /// without replaying publications made before registration. SwiftUI state owners
  /// use this to avoid publishing the initial value during view construction.
  @MainActor
  func stateChanges(
    for identifier: App.Bundle.Identifier
  ) -> UpdateStateFeed {
    makeStateFeed(for: identifier, includesCurrentState: false)
  }

  @MainActor
  private func makeStateFeed(for identifier: App.Bundle.Identifier, includesCurrentState: Bool)
    -> UpdateStateFeed
  {
    let streamIdentifier = UUID()
    let (stream, continuation) = AsyncStream.makeStream(
      of: UpdateOperation.ProgressState.self,
      bufferingPolicy: .bufferingNewest(1)
    )
    let currentState = stateFeedLock.withLock {
      let current = state(for: identifier)
      stateContinuations[identifier, default: [:]][streamIdentifier] = continuation
      if includesCurrentState { continuation.yield(current) }
      return current
    }
    continuation.onTermination = { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.removeStateContinuation(streamIdentifier, for: identifier)
      }
    }
    return (currentState, stream)
  }

  /// Delivers progress to the app's bounded state feeds.
  private func publishState(for identifier: App.Bundle.Identifier) {
    // AsyncStream continuations are thread-safe. Yield directly so their bounded
    // buffers coalesce progress before any MainActor work is scheduled. Sampling
    // inside the lock serializes concurrent publishers and captures terminal errors
    // before the operation is removed from the queue.
    stateFeedLock.withLock {
      guard let continuations = stateContinuations[identifier] else { return }
      let state = self.state(for: identifier)
      for continuation in continuations.values { continuation.yield(state) }
    }
  }

  private func removeStateContinuation(
    _ streamIdentifier: UUID, for identifier: App.Bundle.Identifier
  ) {
    stateFeedLock.withLock {
      stateContinuations[identifier]?.removeValue(forKey: streamIdentifier)
      if stateContinuations[identifier]?.isEmpty == true {
        stateContinuations.removeValue(forKey: identifier)
      }
    }
  }

  // MARK: - Helper

  /// Returns the operation for the given app.
  private func operation(for identifier: App.Bundle.Identifier) -> UpdateOperation? {
    operationIndexLock.withLock {
      guard let operation = operationsByIdentifier[identifier] else {
        return nil
      }

      if operation.isFinished {
        operationsByIdentifier[identifier] = nil
        return nil
      }

      return operation
    }
  }

  /// Returns the unfinished job for the same URL, or indexes this one and orders it after
  /// the last job holding the same lock.
  private func index(_ operation: UpdateOperation) -> UpdateOperation? {
    operationIndexLock.withLock {
      let isRecovery = operation is RecoveryOperation
      if let existingOperation = operationsByIdentifier[operation.appIdentifier],
        !existingOperation.isFinished
      {
        // Recovery goes ahead of a job that is only waiting on its hold; anything running
        // or another recovery keeps the target.
        guard isRecovery, heldOperations.contains(ObjectIdentifier(existingOperation)) else {
          return existingOperation
        }
      }

      operationsByIdentifier[operation.appIdentifier] = operation
      jobsByID[operation.jobID] = operation
      // Recovery is what settles a hold, so it never waits on one, nor on jobs held by one.
      if !isRecovery {
        for key in [
          "all", "lock:" + operation.lockKey,
          "target:" + operation.appIdentifier.standardizedFileURL.path,
        ] {
          if let hold = holds[key] {
            operation.addDependency(hold.barrier)
            heldOperations.insert(ObjectIdentifier(operation))
          }
        }
      }
      let holders = (operationsByLock[operation.lockKey] ?? []).filter {
        !$0.isFinished && !(isRecovery && heldOperations.contains(ObjectIdentifier($0)))
      }
      holders.forEach(operation.addDependency)
      operationsByLock[operation.lockKey] = holders + [operation]
      return nil
    }
  }

  private static func record(of operation: UpdateOperation) -> UpdateJobRecord {
    UpdateJobRecord(
      appURL: operation.appIdentifier, outcome: operation.resolvedOutcome,
      quitDeclined: operation.quitDeclined, cancelled: operation.isCancelled,
      failure: operation.error?.localizedDescription, handOff: operation.handOffNote)
  }

  /// The terminal record replaces the live entry under one lock.
  private func removeIndexedOperation(_ operation: UpdateOperation) {
    operationIndexLock.withLock {
      heldOperations.remove(ObjectIdentifier(operation))
      finishedJobs[operation.jobID] = Self.record(of: operation)
      finishedOrder.append(operation.jobID)
      if finishedOrder.count > 200 { finishedJobs[finishedOrder.removeFirst()] = nil }
      jobsByID[operation.jobID] = nil
      operationsByLock[operation.lockKey]?.removeAll { $0 === operation }
      if operationsByLock[operation.lockKey]?.isEmpty == true {
        operationsByLock[operation.lockKey] = nil
      }
      guard operationsByIdentifier[operation.appIdentifier] === operation else {
        return
      }

      // A job that waited behind a recovery on this target owns it again.
      operationsByIdentifier[operation.appIdentifier] = jobsByID.values.first {
        $0.appIdentifier == operation.appIdentifier && !$0.isFinished
      }
    }
  }

}

/// How a finished job ended, kept for status queries by job id.
struct UpdateJobRecord: Sendable {
  let appURL: URL
  /// The outcome written to history, if any (a cancel or declined quit writes none).
  let outcome: UpdateOutcome?
  let quitDeclined: Bool
  let cancelled: Bool
  let failure: String?
  /// Where a hand-off sends the user and whether anything was opened.
  let handOff: HandOffNote?
}

/// A job as automation sees it: `state` while it is queued or running, `record` once it ended.
struct UpdateJob: Sendable {
  let id: String
  let appURL: URL
  let state: UpdateProgressState?
  let record: UpdateJobRecord?
}
