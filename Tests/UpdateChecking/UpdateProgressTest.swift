// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

final class UpdateProgressTest: XCTestCase {
  @MainActor
  func testUpdateProgressAggregatesOverlappingBatches() {
    let service = UpdateCheckingService()
    let coordinator = UpdateCheckCoordinator()

    service.updateCheckerDidStartScanningForApps(coordinator)
    service.updateChecker(coordinator, didStartCheckingApps: 4, generation: 1)
    service.updateChecker(coordinator, didStartCheckingApps: 1, generation: 1)

    XCTAssertTrue(service.isRunning)
    XCTAssertFalse(service.isIndeterminate)
    XCTAssertEqual(service.totalApps, 5)

    service.updateCheckerDidFinishCheckingForUpdates(coordinator, generation: 1)
    XCTAssertTrue(service.isRunning)

    service.updateCheckerDidFinishCheckingForUpdates(coordinator, generation: 1)
    XCTAssertFalse(service.isRunning)
  }

  @MainActor
  func testReplacementBatchDiscardsProgressForCancelledGeneration() {
    let service = UpdateCheckingService()
    let coordinator = UpdateCheckCoordinator()

    service.updateCheckerDidStartScanningForApps(coordinator)
    service.updateChecker(coordinator, didStartCheckingApps: 38, generation: 1)
    service.updateChecker(coordinator, didCheckApp: makeTestApp(name: "Checked", version: "1"))

    service.updateChecker(coordinator, didStartCheckingApps: 1, generation: 2)

    XCTAssertTrue(service.isRunning)
    XCTAssertEqual(service.checkedApps, 0)
    XCTAssertEqual(service.totalApps, 1)

    service.updateCheckerDidFinishCheckingForUpdates(coordinator, generation: 1)
    XCTAssertTrue(service.isRunning)

    service.updateCheckerDidFinishCheckingForUpdates(coordinator, generation: 2)
    XCTAssertFalse(service.isRunning)
  }

}
