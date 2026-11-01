// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import XCTest

final class UnhostedTestExecutionTest: XCTestCase {
  func testUnitBundleRunsInXCTestWithoutAnApplicationHost() {
    XCTAssertEqual(ProcessInfo.processInfo.processName, "xctest")
    XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app")
    XCTAssertNil(Bundle(identifier: "com.max-langer.Latest.dev"))
    print(
      "Unhosted test process: \(ProcessInfo.processInfo.processName), executable: \(Bundle.main.executableURL?.path ?? "unknown")"
    )
  }
}
