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

  // MARK: - Initialization
  init(
    history: UpdateHistoryStore? = nil,
    readBundle: @escaping @Sendable (URL) -> App.Bundle? = { BundleCollector.collectBundle(at: $0) }
  ) {
    self.history = history
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
  /// Jobs held back because a recovery record cannot be read: by target, by tool, or all when
  /// the scope is unknown. They wait on a dependency that never finishes (no slot used).
  private var heldTargets = Set<String>()
  private var heldLocks = Set<String>()
  private var holdsEverything = false
  private var holdReasons = [String]()
  private let holdBarrier = BlockOperation {}

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

  /// Holds every later job on this target or tool (or every job, with neither) until relaunch.
  func hold(target: String?, lockKey: String?, reason: String) {
    operationIndexLock.withLock {
      if let target { heldTargets.insert(URL(fileURLWithPath: target).standardizedFileURL.path) }
      if let lockKey { heldLocks.insert(lockKey) }
      if target == nil && lockKey == nil { holdsEverything = true }
      holdReasons.append(reason)
    }
  }

  /// Why jobs are held, for status reports.
  var heldBecause: [String] { operationIndexLock.withLock { holdReasons } }

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
      if let existingOperation = operationsByIdentifier[operation.appIdentifier],
        !existingOperation.isFinished
      {
        return existingOperation
      }

      operationsByIdentifier[operation.appIdentifier] = operation
      jobsByID[operation.jobID] = operation
      if holdsEverything || heldLocks.contains(operation.lockKey)
        || heldTargets.contains(operation.appIdentifier.standardizedFileURL.path)
      {
        operation.addDependency(holdBarrier)
      }
      let holders = (operationsByLock[operation.lockKey] ?? []).filter { !$0.isFinished }
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

      operationsByIdentifier[operation.appIdentifier] = nil
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
