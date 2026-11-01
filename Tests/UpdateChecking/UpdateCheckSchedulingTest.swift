//
//  UpdateQueueTest.swift
//  Latest Tests
//
//  Created by ertyoii on 28.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-05-28.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import Synchronization
import XCTest

@testable import Latest

final class UpdateCheckSchedulingTest: XCTestCase {
  func testPriorityGroupingPreservesOrderAndDuplicates() {
    let sources: [App.Source] = [.none, .sparkle, .homebrew, .appStore, .none, .sparkle]
    let bundles = sources.enumerated().map { index, source in
      App.Bundle(
        version: Version(versionNumber: "1", buildNumber: nil),
        name: "App \(index)",
        bundleIdentifier: "test.\(index)",
        fileURL: URL(fileURLWithPath: "/Applications/Test-\(index).app"),
        source: source,
        modificationDate: .distantPast
      )
    }
    let input = bundles + [bundles[1]]
    XCTAssertEqual(
      UpdateCheckCoordinator.prioritizedBundlesForUpdateCheck(input).map(\.identifier),
      [1, 3, 5, 1, 0, 2, 4].map { bundles[$0].identifier }
    )
    XCTAssertTrue(UpdateCheckCoordinator.prioritizedBundlesForUpdateCheck([]).isEmpty)
  }
}

final class UpdateCheckGenerationTrackerTest: XCTestCase {
  func testGenerationCannotAdvanceDuringResultAcceptance() {
    let tracker = UpdateCheckGenerationTracker()
    let generation = tracker.begin()
    let accepting = DispatchSemaphore(value: 0)
    let releaseAcceptance = DispatchSemaphore(value: 0)
    let advanceAttempted = DispatchSemaphore(value: 0)
    let advanced = DispatchSemaphore(value: 0)
    let events = Mutex([String]())
    let finished = expectation(description: "Both operations finish")
    finished.expectedFulfillmentCount = 2
    DispatchQueue.global().async {
      _ = tracker.withCurrent(generation) {
        accepting.signal()
        releaseAcceptance.wait()
        events.withLock { $0.append("accepted") }
      }
      finished.fulfill()
    }
    XCTAssertEqual(accepting.wait(timeout: .now() + 2), .success)
    DispatchQueue.global().async {
      advanceAttempted.signal()
      _ = tracker.begin()
      events.withLock { $0.append("advanced") }
      advanced.signal()
      finished.fulfill()
    }
    XCTAssertEqual(advanceAttempted.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(advanced.wait(timeout: .now() + 0.05), .timedOut)
    releaseAcceptance.signal()
    wait(for: [finished], timeout: 2)
    XCTAssertEqual(events.withLock { $0 }, ["accepted", "advanced"])
    let stale = tracker.withCurrent(generation) {
      XCTFail("Stale write ran")
      return 1
    }
    XCTAssertNil(stale)
  }

  func testStartingNewGenerationInvalidatesOlderWork() {
    let tracker = UpdateCheckGenerationTracker()

    let firstGeneration = tracker.begin()
    XCTAssertTrue(tracker.isCurrent(firstGeneration))

    let secondGeneration = tracker.begin()
    XCTAssertFalse(tracker.isCurrent(firstGeneration))
    XCTAssertTrue(tracker.isCurrent(secondGeneration))
  }

  func testCurrentOrBeginReusesExistingGeneration() {
    let tracker = UpdateCheckGenerationTracker()

    XCTAssertEqual(tracker.currentOrBegin(), 1)
    XCTAssertEqual(tracker.currentOrBegin(), 1)
    XCTAssertEqual(tracker.begin(), 2)
    XCTAssertEqual(tracker.currentOrBegin(), 2)
    XCTAssertEqual(tracker.begin(), 3)
    XCTAssertEqual(tracker.currentOrBegin(), 3)
  }

}
