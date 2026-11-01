// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

final class BoundedUpdateCheckExecutorTest: XCTestCase {
  func testStreamingModeDoesNotRetainCompletedResults() async {
    let completedValues = Mutex([Int]())
    let execution = await BoundedUpdateCheckExecutor(maximumConcurrentTasks: 3).run(
      Array(0..<12),
      collectResults: false,
      onCompletion: { result in
        guard case .success(let value) = result.result else { return }
        completedValues.withLock { $0.append(value) }
      }
    ) { $0 }

    XCTAssertTrue(execution.results.isEmpty)
    XCTAssertEqual(execution.metrics.scheduledCount, 12)
    XCTAssertEqual(execution.metrics.completedCount, 12)
    XCTAssertEqual(Set(completedValues.withLock { $0 }), Set(0..<12))
  }

  func testBoundsParallelismAndReportsProgressForEveryCompletedCheck() async throws {
    let activity = UpdateCheckActivityTracker()
    let progressCount = Mutex(0)
    let execution = await BoundedUpdateCheckExecutor(maximumConcurrentTasks: 4).run(
      Array(0..<24),
      onCompletion: { _ in progressCount.withLock { $0 += 1 } }
    ) { value in
      await activity.started()
      try await Task.sleep(for: .milliseconds(3))
      await activity.finished()
      return value
    }

    let maximumConcurrentCount = await activity.maximumConcurrentCount()
    XCTAssertEqual(maximumConcurrentCount, 4)
    XCTAssertEqual(try execution.results.map { try $0.result.get() }, Array(0..<24))
    XCTAssertEqual(execution.metrics.scheduledCount, 24)
    XCTAssertEqual(execution.metrics.completedCount, 24)
    XCTAssertEqual(progressCount.withLock { $0 }, 24)
    XCTAssertFalse(execution.metrics.wasCancelled)
  }

  func testCancellationStopsAdmittingNewChecks() async {
    let task = Task {
      await BoundedUpdateCheckExecutor(maximumConcurrentTasks: 4).run(Array(0..<100)) { value in
        try await Task.sleep(for: .milliseconds(100))
        return value
      }
    }
    try? await Task.sleep(for: .milliseconds(10))
    task.cancel()
    let execution = await task.value

    XCTAssertTrue(execution.metrics.wasCancelled)
    XCTAssertLessThan(execution.metrics.scheduledCount, 100)
    XCTAssertLessThanOrEqual(execution.metrics.completedCount, execution.metrics.scheduledCount)
    XCTAssertLessThan(execution.results.count, 100)
  }

}

private actor UpdateCheckActivityTracker {
  private var activeCount = 0
  private var maximumCount = 0

  func started() {
    activeCount += 1
    maximumCount = max(maximumCount, activeCount)
  }

  func finished() {
    activeCount -= 1
  }

  func maximumConcurrentCount() -> Int {
    maximumCount
  }
}
