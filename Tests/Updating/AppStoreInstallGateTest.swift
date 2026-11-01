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

  /// Sol R5: before macOS 26.1 CommerceKit installs without quit, backup or verification,
  /// so even a passing gate hands off with no helper request.
  func testNativeCommerceKitRouteHandsOff() async throws {
    let helperCalls = Mutex(0)
    let opened = Mutex<[URL]>([])
    let operation = AppStoreUpdateOperation(
      bundleIdentifier: identifier, installURL: target, appIdentifier: target,
      appStoreIdentifier: 1)
    operation.gate = .agreeing(on: target.path)
    operation.usesVerifiedHelperInstall = false
    operation.prepare = { helperCalls.withLock { $0 += 1 } }
    operation.openURL = { url in opened.withLock { $0.append(url) } }
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    UpdateQueue().addOperation(operation)
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(helperCalls.withLock { $0 }, 0)
    XCTAssertEqual(operation.outcomeOverride, .handedOff)
    XCTAssertEqual(opened.withLock { $0 }.count, 1)
  }

  /// Sol R3: the gate runs again right before the helper install, after download and quit.
  @MainActor
  func testGateIsRecheckedImmediatelyBeforeTheHelperInstall() async throws {
    let installs = Mutex(0)
    let operation = AppStoreUpdateOperation(
      bundleIdentifier: identifier, installURL: target, appIdentifier: target,
      appStoreIdentifier: 1)
    var gate = AppStoreInstallGate.agreeing(on: target.path)
    // A second copy appeared while the package downloaded.
    gate.launchServicesURLs = { _ in
      [
        URL(fileURLWithPath: "/Applications/UpdaterGateFixture.app"),
        URL(fileURLWithPath: "/Users/Shared/UpdaterGateFixture.app"),
      ]
    }
    operation.gate = gate
    operation.openURL = { _ in }
    operation.installPackage = { _, appURL, _, _ in
      installs.withLock { $0 += 1 }
      return appURL
    }
    do {
      try await operation.installPreservedPackage(
        URL(fileURLWithPath: "/tmp/none.pkg"), receipt: Data("r".utf8))
      XCTFail("A changed discovery must stop the install")
    } catch {}
    XCTAssertEqual(installs.withLock { $0 }, 0)
    XCTAssertEqual(operation.outcomeOverride, .handedOff)
    XCTAssertFalse(operation.isCommitting, "Nothing was committed")
  }

  /// Sol R8: unreadable candidates and inaccessible folders fail closed; only absent
  /// optional folders are skipped.
  func testFolderWalkFailsClosedOnUnreadableItems() throws {
    let root = try disposableDirectory()
    // An .app whose Info.plist cannot be read.
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Broken.app/Contents"), withIntermediateDirectories: true)
    XCTAssertThrowsError(try AppStoreInstallGate.copies(of: identifier, in: [root]))

    let clean = try disposableDirectory()
    XCTAssertEqual(
      try AppStoreInstallGate.copies(of: identifier, in: [clean.appendingPathComponent("absent")]),
      [], "an absent optional folder is skipped")
    XCTAssertThrowsError(
      try AppStoreInstallGate.copies(
        of: identifier, in: [clean.appendingPathComponent("absent")],
        required: [clean.appendingPathComponent("absent").path]),
      "an absent required folder blocks")

    // A folder that exists but cannot be entered.
    let locked = clean.appendingPathComponent("locked")
    try FileManager.default.createDirectory(
      at: locked.appendingPathComponent("Applications"), withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }
    XCTAssertThrowsError(
      try AppStoreInstallGate.copies(
        of: identifier, in: [locked.appendingPathComponent("Applications")]))
    XCTAssertThrowsError(try AppStoreInstallGate.copies(of: identifier, in: [locked]))
  }

  /// Sol R5 (second pass): blocking probes share one deadline; a late "yes" is ignored.
  func testSlowProbesHitTheDeadlineAndCannotAllowLater() async throws {
    let target = self.target
    let finished = Mutex(false)
    var gate = AppStoreInstallGate.agreeing(on: target.path)
    gate.deadline = .milliseconds(200)
    gate.walk = { _ in
      Thread.sleep(forTimeInterval: 1.5)  // a hung folder walk
      finished.withLock { $0 = true }
      return [target.path]
    }
    let start = ContinuousClock.now
    let allowed = await gate.allowsInstall(at: target, bundleIdentifier: identifier)
    XCTAssertFalse(allowed)
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(1), "answered at the deadline")
    XCTAssertFalse(finished.withLock { $0 }, "the walk was still running")

    var slowSpotlight = AppStoreInstallGate.agreeing(on: target.path)
    slowSpotlight.deadline = .milliseconds(200)
    slowSpotlight.spotlightURLs = { _ in
      try await Task.sleep(for: .seconds(2))
      return [target]
    }
    let late = await slowSpotlight.allowsInstall(at: target, bundleIdentifier: identifier)
    XCTAssertFalse(late)
  }
}
