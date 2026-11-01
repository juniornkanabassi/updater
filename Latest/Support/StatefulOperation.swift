//
//  StatefulOperation.swift
//  Latest
//
//  Created by Max Langer on 01.07.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import Foundation
import Synchronization

/// An convenience operation adding state to Operations.
class StatefulOperation: Operation, @unchecked Sendable {

  // MARK: State Management

  override class func keyPathsForValuesAffectingValue(forKey key: String) -> Set<String> {
    switch key {
    // Not isReady: readiness depends on dependencies only. Announcing a readiness change on
    // every state change (including finishing while start() is still running) invites the
    // queue to start the operation again.
    case "isFinished", "isExecuting":
      return ["state"]

    default:
      return []
    }
  }

  /// The states this `Operation` can be in.
  private enum State: Int {

    /// The initial state of an `Operation`.
    case ready

    /// The `Operation` is executing.
    case executing

    /// The `Operation` has finished executing.
    case finished

  }

  /// Private storage for the `state` property.
  private var _state = State.ready

  /// A lock to guard reads and writes to the `_state` property
  private let stateLock = NSLock()

  /// The actual state of the operation
  private var state: State {
    get {
      return self.stateLock.withLock({
        return self._state
      })
    }

    set(newState) {
      // Announce real transitions only; a repeated finish must not re-announce the state.
      guard stateLock.withLock({ _state != .finished && _state != newState }) else { return }
      self.willChangeValue(forKey: "state")

      self.stateLock.withLock {
        guard _state != .finished else {
          return
        }

        _state = newState
      }

      self.didChangeValue(forKey: "state")
    }
  }

  /// Whether the operation is currently executing
  override final var isExecuting: Bool {
    return self.state == .executing
  }

  /// Whether the operation is finished
  override final var isFinished: Bool {
    return self.state == .finished
  }

  // MARK: - Execution

  override final func start() {
    // NSOperation.start() contains important logic that shouldn't be bypassed.
    super.start()

    // If the operation has been cancelled, we still need to enter the "Finished" state.
    if !self.isCancelled {
      self.state = .executing

      self.execute()
    } else {
      self.finish()
    }
  }

  /**
   `execute()` is the entry point of execution for all `StatefulOperation` subclasses.
   If you subclass `StatefulOperation` and wish to customize its execution, you would
   do so by overriding the `execute()` method.

   At some point, your `StatefulOperation` subclass must call one of the "finish"
   methods defined below; this is how you indicate that your operation has
   finished its execution.
   */
  func execute() {
    fatalError("\(type(of: self)) must override `execute()`.")
  }

  func finish() {
    self.state = .finished
  }

  /// The error raised during execution
  private let storedError = Mutex<Error?>(nil)
  var error: Error? { storedError.withLock { $0 } }

  func finish(with error: Error) {
    recordError(error)
    self.finish()
  }

  /// Sets the error that `finish()` will publish, for failures found while finishing.
  func recordError(_ error: Error) {
    storedError.withLock { $0 = error }
  }

}
