// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

extension AppStoreInstallGate {
  /// Every probe agrees that `path` is the only copy.
  static func agreeing(on path: String) -> AppStoreInstallGate {
    AppStoreInstallGate(
      walk: { _ in [path] }, launchServicesURLs: { _ in [URL(fileURLWithPath: path)] },
      spotlightURLs: { _ in [URL(fileURLWithPath: path)] }, indexingEnabled: { true })
  }
}

private struct ProbeFailure: Error {}

final class AppStoreInstallGateTest: XCTestCase {
  private let target = URL(fileURLWithPath: "/Applications/UpdaterGateFixture.app")
  private let identifier = FixtureApp.identifier

  func testInstallIsAllowedOnlyWhenEveryProbeAgreesOnTheExactURL() async throws {
    let target = self.target
    let other = URL(fileURLWithPath: "/Users/Shared/Copy/UpdaterGateFixture.app")
    let allowed = AppStoreInstallGate.agreeing(on: target.path)
    var allowedResult = await allowed.allowsInstall(at: target, bundleIdentifier: identifier)
    XCTAssertTrue(allowedResult, "positive control")

    let root = try disposableDirectory()
    try FixtureApp.make(in: root.appendingPathComponent("Nested"), version: "1.0", signed: false)

    var cases = [String: AppStoreInstallGate]()
    var gate = allowed
    gate.launchServicesURLs = { _ in [target, other] }
    cases["second copy registered with LaunchServices"] = gate
    gate = allowed
    gate.spotlightURLs = { _ in [target, other] }
    cases["second copy found by Spotlight"] = gate
    gate = allowed
    gate.walk = { id in
      try AppStoreInstallGate.copies(of: id, in: [root]).union([target.path])
    }
    cases["unregistered second copy in a walked folder"] = gate
    gate = allowed
    gate.launchServicesURLs = { _ in throw ProbeFailure() }
    cases["LaunchServices query fails"] = gate
    gate = allowed
    gate.spotlightURLs = { _ in throw AppDownloadError.toolFailed("timed out") }
    cases["Spotlight query times out"] = gate
    gate = allowed
    gate.spotlightURLs = { _ in [] }
    cases["Spotlight does not know the app"] = gate
    gate = allowed
    gate.indexingEnabled = { false }
    cases["indexing disabled"] = gate
    gate = allowed
    gate.walk = { _ in throw ProbeFailure() }
    cases["folder walk fails"] = gate
    for (name, gate) in cases {
      allowedResult = await gate.allowsInstall(at: target, bundleIdentifier: identifier)
      XCTAssertFalse(allowedResult, name)
    }

    for url in [
      root.appendingPathComponent("Fixture.app"),
      URL(fileURLWithPath: "/Applications/Utilities/UpdaterGateFixture.app"),
    ] {
      allowedResult = await AppStoreInstallGate.agreeing(on: url.path)
        .allowsInstall(at: url, bundleIdentifier: identifier)
      XCTAssertFalse(allowedResult, "Only /Applications/<name>.app is the package's target")
    }
    allowedResult = await allowed.allowsInstall(at: target, bundleIdentifier: "bad\"id")
    XCTAssertFalse(allowedResult)
  }

  func testFolderWalkFindsNestedCopiesButNotBundlesInsideApps() throws {
    let root = try disposableDirectory()
    let nested = try FixtureApp.make(
      in: root.appendingPathComponent("Folder"), version: "1.0", signed: false)
    // A helper app inside another bundle is not an installed copy.
    try FixtureApp.make(
      in: nested.appendingPathComponent("Contents/Library"), name: "Inner", version: "1.0",
      signed: false)
    try FixtureApp.make(in: root, name: "Unrelated", identifier: "com.example.x", version: "1")
    XCTAssertEqual(
      try AppStoreInstallGate.copies(
        of: identifier, in: [root, root.appendingPathComponent("gone")]),
      [nested.standardizedFileURL.path])
  }

  /// The gate runs before the helper is even asked whether it is ready, so a failing gate
  /// issues no helper request and never reaches the CommerceKit purchase after it.
  func testFailingGateHandsOffBeforeAnyHelperOrPurchaseRequest() async throws {
    let directory = try disposableDirectory()
    let history = UpdateHistoryStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let queue = UpdateQueue(history: history) { url in
      App.Bundle(
        version: Version(versionNumber: "1.0", buildNumber: nil), name: "Gate",
        bundleIdentifier: FixtureApp.identifier, fileURL: url, source: .appStore,
        modificationDate: .distantPast)
    }
    let helperCalls = Mutex(0)
    let opened = Mutex<[URL]>([])
    let operation = AppStoreUpdateOperation(
      bundleIdentifier: identifier, installURL: target, appIdentifier: target,
      appStoreIdentifier: 1)
    var gate = AppStoreInstallGate.agreeing(on: target.path)
    gate.indexingEnabled = { false }
    operation.gate = gate
    operation.prepare = { helperCalls.withLock { $0 += 1 } }
    operation.openURL = { url in opened.withLock { $0.append(url) } }
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    queue.addOperation(operation)
    await fulfillment(of: [done], timeout: 5)
    for _ in 0..<200 where history.latestEntry(for: target) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(helperCalls.withLock { $0 }, 0)
    XCTAssertEqual(opened.withLock { $0 }.map(\.absoluteString), ["macappstore://showUpdatesPage"])
    XCTAssertNil(operation.error)
    XCTAssertEqual(history.latestEntry(for: target)?.outcome, .handedOff)
  }
}
