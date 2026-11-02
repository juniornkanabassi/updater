//
//  UpdateOperation.swift
//  Latest
//
//  Created by Max Langer on 01.07.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import Foundation
import Synchronization

extension Notification.Name {
  static let latestUpdateOperationDidFinish = Notification.Name("LatestUpdateOperationDidFinish")
  /// A job joined or left the scheduler, cancelled ones included.
  static let latestUpdateQueueDidChange = Notification.Name("LatestUpdateQueueDidChange")
}

/// Whether a submission may open another updater (the App Store, a web page) if its job ends
/// up handing off. The window may; automation only with `--allow-handoff`. Read synchronously
/// while the job is submitted, then kept on the job.
enum ExternalHandOff {
  @TaskLocal static var allowed = true
}

/// The abstract update operation used for updating apps.
class UpdateOperation: StatefulOperation, @unchecked Sendable {

  typealias ProgressState = UpdateProgressState

  /// The app that is updated by this operation.
  let bundleIdentifier: String

  /// The identifier of the updated app.
  let appIdentifier: App.Bundle.Identifier

  /// Names this job to automation callers (`updater status <job-id>`).
  let jobID = UUID().uuidString.lowercased()

  private let handOffPolicy = Mutex(true)
  /// False when automation submitted the job without `--allow-handoff`: every fallback then
  /// records `handedOff` and opens nothing.
  var allowsExternalHandOff: Bool {
    get { handOffPolicy.withLock { $0 } }
    set { handOffPolicy.withLock { $0 = newValue } }
  }

  private let declinedQuit = Mutex(false)
  /// The user declined (or did not answer) the quit prompt. Like any cancel nothing is
  /// recorded in history, but automation reports it as needsQuit.
  var quitDeclined: Bool { declinedQuit.withLock { $0 } }

  /// Ends the job as a declined quit: a cancel that is reported as needsQuit.
  func declineQuit() {
    markQuitDeclined()
    cancel()
  }

  /// For jobs past their commit point, where cancel() is refused: the job finishes cleanly
  /// and the scheduler writes no history for it.
  func markQuitDeclined() { declinedQuit.withLock { $0 = true } }

  private let handOffStorage = Mutex<HandOffNote?>(nil)
  var handOffNote: HandOffNote? { handOffStorage.withLock { $0 } }

  /// Ends the job as a hand-off. `open` (the App Store, a page) runs only when the submission
  /// allows it; brew and vendor fallbacks pass none and only say where to go.
  @MainActor func recordHandOff(
    to destination: String, because reason: String, open: (@MainActor () -> Void)? = nil
  ) {
    outcomeOverride = .handedOff
    let opens = open != nil && allowsExternalHandOff
    if opens { open?() }
    handOffStorage.withLock {
      $0 = HandOffNote(
        destination: destination, reason: reason, opened: opens,
        blockedByPolicy: open != nil && !allowsExternalHandOff)
    }
  }

  private let resolvedStorage = Mutex<UpdateOutcome?>(nil)
  /// The outcome the scheduler recorded as the job finished, if any.
  var resolvedOutcome: UpdateOutcome? { resolvedStorage.withLock { $0 } }

  private let completionNotificationLock = NSLock()

  private var didPostCompletionNotification = false

  private let committing = Mutex(false)

  var isCommitting: Bool { committing.withLock { $0 } }

  private struct Progress: Sendable {
    var state: ProgressState = .pending
    var handler: (@Sendable (App.Bundle.Identifier) -> Void)?
  }
  private let progress = Mutex(Progress())

  /// OperationQueue requires unchecked inheritance. The mutable progress and
  /// handler are protected together; notifications always run outside the lock.
  var progressHandler: (@Sendable (App.Bundle.Identifier) -> Void)? {
    get { progress.withLock { $0.handler } }
    set {
      progress.withLock { $0.handler = newValue }
      newValue?(appIdentifier)
    }
  }

  var progressState: ProgressState {
    get { progress.withLock { $0.state } }
    set {
      let handler = progress.withLock { progress in
        progress.state = newValue
        return progress.handler
      }
      handler?(appIdentifier)
    }
  }

  /// Initializes the operation with the given app and progress handler.
  init(bundleIdentifier: String, appIdentifier: App.Bundle.Identifier) {
    self.bundleIdentifier = bundleIdentifier
    self.appIdentifier = appIdentifier
  }

  // MARK: - Operation sub-classing

  override func execute() {
    self.progressState = .initializing
  }

  override func cancel() {
    let cancelled = committing.withLock { committing in
      guard !committing else { return false }
      super.cancel()
      return true
    }
    guard cancelled else { return }
    self.progressState = .cancelling
  }

  /// Installation and rollback must finish once they start. Serialize this
  /// boundary with cancellation so a completed install still triggers a refresh.
  func beginCommit() throws {
    try committing.withLock { committing in
      try Task.checkCancellation()
      guard !isCancelled else { throw CancellationError() }
      committing = true
    }
  }

  /// Jobs sharing a key never run at the same time. Installers that only touch their own
  /// URL lock that URL; a shared tool (the App Store helper, later brew or msupdate) locks
  /// its name.
  var lockKey: String { "target:" + appIdentifier.path }

  private let outcomeStorage = Mutex<UpdateOutcome?>(nil)
  /// Set by operations whose result is not read from disk, such as a hand-off.
  var outcomeOverride: UpdateOutcome? {
    get { outcomeStorage.withLock { $0 } }
    set { outcomeStorage.withLock { $0 = newValue } }
  }

  private let resolver = Mutex<(@Sendable (UpdateOperation) -> UpdateOutcome?)?>(nil)
  /// Set by the scheduler. Runs once as the job finishes, reads the bundle on disk and
  /// returns the verified outcome, so a derived failure is what subscribers see.
  var resolveOutcome: (@Sendable (UpdateOperation) -> UpdateOutcome?)? {
    get { resolver.withLock { $0 } }
    set { resolver.withLock { $0 = newValue } }
  }

  private let reasonStorage = Mutex<String?>(nil)
  /// Why the version might not change, recorded with a no-change outcome.
  var noChangeReason: String? {
    get { reasonStorage.withLock { $0 } }
    set { reasonStorage.withLock { $0 = newValue } }
  }

  private let expectedStorage = Mutex<Version?>(nil)
  /// The version the installer promised, when known; an outcome below it is a failure.
  var expectedVersion: Version? {
    get { expectedStorage.withLock { $0 } }
    set { expectedStorage.withLock { $0 = newValue } }
  }

  /// Update mechanisms that wait for an app to quit can offer another quit request.
  @MainActor func retryTermination() {}

  override func finish() {
    let resolve = resolver.withLock { resolve in
      defer { resolve = nil }
      return resolve
    }
    let outcome = resolve?(self)
    resolvedStorage.withLock { $0 = outcome }
    if let outcome, self.error == nil, let failure = UpdateOutcomeError(outcome: outcome) {
      recordError(failure)
    }
    // Any attempt may have changed or removed the bundle, including failures and rollbacks,
    // so the row is reconciled with the disk after every finish except a plain cancel.
    let shouldReconcile =
      !(self.isCancelled && self.error == nil) && self.markCompletionNotificationPending()

    if let error = self.error {
      self.progressState = .error(error)
    } else {
      self.progressState = .none
    }

    super.finish()

    if shouldReconcile {
      NotificationCenter.default.post(
        name: .latestUpdateOperationDidFinish, object: self,
        userInfo: [
          Self.appIdentifierUserInfoKey: self.appIdentifier
        ])
    }
  }

  private func markCompletionNotificationPending() -> Bool {
    completionNotificationLock.withLock {
      guard !didPostCompletionNotification else {
        return false
      }

      didPostCompletionNotification = true
      return true
    }
  }

}

extension UpdateOperation {
  static let appIdentifierUserInfoKey = "appIdentifier"
}
