// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import XCTest

final class ToolbarProgressTest: XCTestCase {
  func testToolbarProgressVisibilityAndClamping() {
    XCTAssertEqual(ToolbarProgressMetrics.normalized(-0.25), 0)
    XCTAssertEqual(ToolbarProgressMetrics.normalized(0.5), 0.5)
    XCTAssertEqual(ToolbarProgressMetrics.normalized(1.25), 1)
    XCTAssertEqual(ToolbarProgressPresentation(isRunning: false, fraction: 0.5), .hidden)
    XCTAssertEqual(ToolbarProgressPresentation(isRunning: true, fraction: 0.5), .determinate(0.5))
    XCTAssertEqual(ToolbarProgressPresentation(isRunning: true, fraction: nil), .determinate(0))
    XCTAssertEqual(ToolbarProgressPresentation(isRunning: true, fraction: -0.25), .determinate(0))
    XCTAssertEqual(ToolbarProgressPresentation(isRunning: true, fraction: 1.25), .determinate(1))
  }
}
