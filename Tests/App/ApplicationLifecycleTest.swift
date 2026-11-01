// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

final class ApplicationLifecycleTest: XCTestCase {
  @MainActor
  func testHostedTestsUseBackgroundApplicationLifecycle() {
    XCTAssertEqual(Bundle.main.bundleURL.pathExtension, "app")
    XCTAssertNotNil(NSApp)
    if ProcessInfo.processInfo.environment["LATEST_UI_TESTS"] != "1" {
      XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
      XCTAssertFalse(NSApp.isActive, "Background tests must not activate over another app")
    }
  }

  @MainActor
  func testStartupChecksImmediatelyWhileCatalogRefreshIsSuspended() async {
    let check = expectation(description: "Discovery starts")
    let catalogStarted = expectation(description: "Catalog suspended")
    var continuation: CheckedContinuation<Void, Never>?
    var checks = 0
    let task = Task {
      await AppStartupSequence.run(
        refreshCatalog: {
          await withCheckedContinuation {
            continuation = $0
            catalogStarted.fulfill()
          }
        },
        checkForUpdates: {
          checks += 1
          check.fulfill()
        })
    }
    await fulfillment(of: [check, catalogStarted], timeout: 2)
    task.cancel()
    continuation?.resume()
    await task.value
    XCTAssertEqual(checks, 1, "Finishing a cancelled catalog refresh must not restart discovery")
    await AppStartupSequence.run(refreshCatalog: {}, checkForUpdates: { checks += 1 })
    XCTAssertEqual(checks, 2, "A later launch can start discovery again")
  }

  @MainActor
  func testCancelledStartupDoesNotBeginDiscoveryOrCatalogRequests() async {
    var checks = 0
    var refreshes = 0
    let task = Task {
      await AppStartupSequence.run(
        refreshCatalog: { refreshes += 1 }, checkForUpdates: { checks += 1 })
    }
    task.cancel()
    await task.value
    XCTAssertEqual(checks, 0)
    XCTAssertEqual(refreshes, 0)
  }
}
