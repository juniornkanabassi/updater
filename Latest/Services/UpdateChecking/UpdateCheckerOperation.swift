//
//  UpdateCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 03.10.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import Foundation
import OSLog

private let updateCheckEngineSignposter = OSSignposter(
  subsystem: Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
  category: "UpdateCheckPerformance"
)

struct IndexedUpdateCheckResult<Value: Sendable>: Sendable {
  let index: Int
  let result: Result<Value, Error>
}

struct UpdateCheckExecutionMetrics: Equatable, Sendable {
  let scheduledCount: Int
  let completedCount: Int
  let wasCancelled: Bool
  let duration: Duration
}

struct UpdateCheckExecution<Value: Sendable>: Sendable {
  let results: [IndexedUpdateCheckResult<Value>]
  let metrics: UpdateCheckExecutionMetrics
}

/// Runs update checks as child tasks while bounding active work. New work is
/// admitted only when a previous child finishes, so cancellation cannot leave a
/// large backlog of detached or queued checks behind.
struct BoundedUpdateCheckExecutor: Sendable {
  let maximumConcurrentTasks: Int

  init(maximumConcurrentTasks: Int = 6) {
    precondition(maximumConcurrentTasks > 0)
    self.maximumConcurrentTasks = maximumConcurrentTasks
  }

  func run<Input: Sendable, Output: Sendable>(
    _ inputs: [Input],
    collectResults: Bool = true,
    onCompletion: (@Sendable (IndexedUpdateCheckResult<Output>) -> Void)? = nil,
    operation: @escaping @Sendable (Input) async throws -> Output
  ) async -> UpdateCheckExecution<Output> {
    let clock = ContinuousClock()
    let startedAt = clock.now
    let signpostID = updateCheckEngineSignposter.makeSignpostID()
    let interval = updateCheckEngineSignposter.beginInterval("Update Check Batch", id: signpostID)
    defer { updateCheckEngineSignposter.endInterval("Update Check Batch", interval) }

    var results = [IndexedUpdateCheckResult<Output>]()
    if collectResults {
      results.reserveCapacity(inputs.count)
    }
    var scheduledCount = 0
    var completedCount = 0
    var encounteredCancellation = false
    await withTaskGroup(of: IndexedUpdateCheckResult<Output>.self) { group in
      var nextInputIndex = 0

      func addNextTask() {
        guard nextInputIndex < inputs.count, !Task.isCancelled else { return }
        let index = nextInputIndex
        let input = inputs[index]
        nextInputIndex += 1
        scheduledCount += 1
        group.addTask {
          do {
            try Task.checkCancellation()
            return IndexedUpdateCheckResult(
              index: index, result: .success(try await operation(input)))
          } catch {
            return IndexedUpdateCheckResult(index: index, result: .failure(error))
          }
        }
      }

      for _ in 0..<min(maximumConcurrentTasks, inputs.count) {
        addNextTask()
      }

      while let result = await group.next() {
        completedCount += 1
        if case .failure(let error) = result.result, error is CancellationError {
          encounteredCancellation = true
        }
        if collectResults {
          results.append(result)
        }
        onCompletion?(result)
        if Task.isCancelled {
          group.cancelAll()
        } else {
          addNextTask()
        }
      }
    }

    let wasCancelled = Task.isCancelled || encounteredCancellation
    return UpdateCheckExecution(
      results: collectResults ? results.sorted { $0.index < $1.index } : [],
      metrics: UpdateCheckExecutionMetrics(
        scheduledCount: scheduledCount,
        completedCount: completedCount,
        wasCancelled: wasCancelled,
        duration: startedAt.duration(to: clock.now)
      )
    )
  }
}
