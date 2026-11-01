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
    operation.installGate = { [gate] in await gate.allowsInstall(at: $0, bundleIdentifier: $1) }
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
    let agreeing = AppStoreInstallGate.agreeing(on: target.path)
    operation.installGate = { await agreeing.allowsInstall(at: $0, bundleIdentifier: $1) }
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
    operation.installGate = { [gate] in await gate.allowsInstall(at: $0, bundleIdentifier: $1) }
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

  private func nativeOperation(
    for app: URL, target: FakeTarget,
    purchase: @escaping @MainActor @Sendable (AppStoreUpdateOperation) async -> Void
  ) -> AppStoreUpdateOperation {
    let operation = AppStoreUpdateOperation(
      bundleIdentifier: FixtureApp.identifier, installURL: app, appIdentifier: app,
      appStoreIdentifier: 1)
    operation.installGate = { _, _ in true }
    operation.prepare = {}
    operation.openURL = { _ in }
    operation.requiresTeam = false
    operation.lifecycle = target.lifecycle(timeout: .milliseconds(300))
    operation.purchase = purchase
    operation.expectedVersion = Version(versionNumber: "1.1", buildNumber: nil)
    return operation
  }

  private func run(_ operation: AppStoreUpdateOperation) async {
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    UpdateQueue().addOperation(operation)
    await fulfillment(of: [done], timeout: 10)
  }

  /// Sol R2 (third pass): CommerceKit's own successful install is protected like every other
  /// route: quit and clone first, then verified, and restored with the app reopened.
  func testNativeCommerceKitInstallIsQuitClonedVerifiedAndRestored() async throws {
    // A bad native install: restored byte-for-byte and the quit app reopened once.
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let before = try FixtureApp.digest(app)
    let payload = try FixtureApp.make(in: root.appendingPathComponent("payload"), version: "0.9")
    let target = FakeTarget(running: true)
    let purchases = Mutex(0)
    let bad = nativeOperation(for: app, target: target) { operation in
      purchases.withLock { $0 += 1 }
      XCTAssertEqual(target.quits.withLock { $0 }, 1, "quit before the purchase")
      try? FileManager.default.removeItem(at: app)
      try? FileManager.default.copyItem(at: payload, to: app)
      await operation.nativeInstallCompleted()
    }
    await run(bad)
    XCTAssertEqual(purchases.withLock { $0 }, 1)
    XCTAssertTrue(bad.error is ReplacementError, String(describing: bad.error))
    XCTAssertEqual(try FixtureApp.digest(app), before)
    XCTAssertEqual(target.reopens.withLock { $0 }, 1)

    // A good native install is kept.
    let good = try FixtureApp.make(in: root.appendingPathComponent("good"), version: "1.1")
    let kept = nativeOperation(for: app, target: FakeTarget(running: false)) { operation in
      try? FileManager.default.removeItem(at: app)
      try? FileManager.default.copyItem(at: good, to: app)
      await operation.nativeInstallCompleted()
    }
    await run(kept)
    XCTAssertNil(kept.error)
    XCTAssertEqual(try BundleIdentity.read(at: app, validate: false).shortVersion, "1.1")
  }

  /// Sol R2 (third pass): no purchase when the app will not quit or cannot be cloned.
  func testNoPurchaseWithoutQuitOrClone() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let purchases = Mutex(0)
    let refusing = FakeTarget(running: true)
    let stubborn = nativeOperation(for: app, target: refusing) { _ in purchases.withLock { $0 += 1 }
    }
    stubborn.lifecycle = AppLifecycle(
      runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
      confirmQuit: { _ in true }, reopen: { _ in }, timeout: .milliseconds(200))
    await run(stubborn)
    guard case AppDownloadError.applicationStillRunning? = stubborn.error else {
      return XCTFail("Expected needs-quit, got \(String(describing: stubborn.error))")
    }

    let missing = root.appendingPathComponent("Missing.app")
    let uncloneable = nativeOperation(for: missing, target: FakeTarget(running: false)) { _ in
      purchases.withLock { $0 += 1 }
    }
    await run(uncloneable)
    XCTAssertEqual(uncloneable.outcomeOverride, .handedOff)
    XCTAssertEqual(purchases.withLock { $0 }, 0)
  }

  /// Sol R2 (fourth pass): the gate runs again after preparation and the quit, right before
  /// the purchase; failing then means no purchase, the clone discarded and the app reopened.
  func testGateIsRecheckedRightBeforeThePurchase() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let before = try FixtureApp.digest(app)
    let target = FakeTarget(running: true)
    let purchases = Mutex(0)
    let checks = Mutex(0)
    let operation = nativeOperation(for: app, target: target) { _ in purchases.withLock { $0 += 1 }
    }
    operation.installGate = { _, _ in
      checks.withLock {
        $0 += 1
        return $0 == 1
      }
    }
    await run(operation)
    XCTAssertEqual(checks.withLock { $0 }, 2)
    XCTAssertEqual(purchases.withLock { $0 }, 0)
    XCTAssertEqual(operation.outcomeOverride, .handedOff)
    XCTAssertEqual(target.reopens.withLock { $0 }, 1)
    XCTAssertEqual(try FixtureApp.digest(app), before)
  }

  /// Sol R1 (fourth pass): a cancel during the quit waits for the quit to finish and
  /// reopens the app. Sol R2 (fifth pass): once the purchase is issued, cancel is ignored;
  /// CommerceKit's install is then verified and restored as usual.
  func testCancelBeforePurchaseWaitsForQuitAndIsIgnoredAfterIt() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let before = try FixtureApp.digest(app)

    let slow = SlowQuitTarget()
    let purchases = Mutex(0)
    let quitting = nativeOperation(for: app, target: FakeTarget(running: false)) { _ in
      purchases.withLock { $0 += 1 }
    }
    quitting.lifecycle = slow.lifecycle
    let quitDone = expectation(description: "finished")
    quitting.completionBlock = { quitDone.fulfill() }
    let queue = UpdateQueue()
    queue.addOperation(quitting)
    while !slow.asked.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
    quitting.cancel()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertFalse(quitting.isFinished, "the quit is still in progress")
    XCTAssertTrue(queue.contains(app), "the target stays locked")
    await fulfillment(of: [quitDone], timeout: 5)
    XCTAssertEqual(purchases.withLock { $0 }, 0)
    XCTAssertEqual(slow.reopens.withLock { $0 }, 1, "a completed quit is undone")

    let release = AsyncStream<Void>.makeStream()
    let payload = try FixtureApp.make(in: root.appendingPathComponent("payload"), version: "0.9")
    let installing = nativeOperation(for: app, target: FakeTarget(running: false)) { operation in
      for await _ in release.stream {}
      try? FileManager.default.removeItem(at: app)
      try? FileManager.default.copyItem(at: payload, to: app)
      await operation.nativeInstallCompleted()
    }
    let installDone = expectation(description: "finished")
    installing.completionBlock = { installDone.fulfill() }
    queue.addOperation(installing)
    while !installing.isCommitting { try await Task.sleep(for: .milliseconds(5)) }
    installing.cancel()
    XCTAssertFalse(installing.isCancelled, "the purchase was issued: cancel is a no-op")
    // The row shows a waiting state, which has no cancel control.
    guard
      case .waiting = await MainActor.run(body: {
        UpdateActionPresentation.make(
          for: makeTestApp(name: "Store", version: "1", remoteVersion: "2"),
          progressState: installing.progressState)
      })
    else { return XCTFail("no cancel control once the purchase is issued") }
    release.continuation.finish()
    await fulfillment(of: [installDone], timeout: 10)
    XCTAssertEqual(try FixtureApp.digest(app), before, "verified and restored")
  }

  /// Sol R1 (fifth pass): a cancel while the final gate runs means no purchase.
  func testCancelDuringTheFinalGatePreventsThePurchase() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let target = FakeTarget(running: true)
    let purchases = Mutex(0)
    let checks = Mutex(0)
    let release = AsyncStream<Void>.makeStream()
    let operation = nativeOperation(for: app, target: target) { _ in purchases.withLock { $0 += 1 }
    }
    operation.installGate = { _, _ in
      let call = checks.withLock {
        $0 += 1
        return $0
      }
      if call == 2 { for await _ in release.stream {} }
      return true
    }
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    UpdateQueue().addOperation(operation)
    while checks.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(5)) }
    operation.cancel()
    release.continuation.finish()
    await fulfillment(of: [done], timeout: 5)
    XCTAssertEqual(purchases.withLock { $0 }, 0)
    XCTAssertEqual(target.reopens.withLock { $0 }, 1)
  }

  /// Sol R3 (fifth pass): a lost helper reply leaves everything in place until the helper
  /// reports idle; if it never does, the original is kept aside and nothing is restored.
  @MainActor
  func testLostHelperReplyWaitsForIdleAndNeverRestoresBlindly() async throws {
    for helperComesBack in [true, false] {
      let root = try disposableDirectory()
      let app = try FixtureApp.make(in: root, version: "1.0")
      let before = try FixtureApp.digest(app)
      let bad = try FixtureApp.make(in: root.appendingPathComponent("payload"), version: "0.9")
      let badDigest = try FixtureApp.digest(bad)
      let target = FakeTarget(running: false)
      let operation = nativeOperation(for: app, target: target) { _ in }
      operation.helperPollInterval = .milliseconds(30)
      operation.helperWaitLimit = .milliseconds(300)
      let polls = Mutex(0)
      let untouchedWhileWaiting = Mutex(true)
      operation.helperIsIdle = {
        let poll = polls.withLock {
          $0 += 1
          return $0
        }
        if (try? FixtureApp.digest(app)) != badDigest {
          untouchedWhileWaiting.withLock { $0 = false }
        }
        return helperComesBack && poll >= 3 ? true : nil
      }
      operation.installPackage = { _, appURL, _, _ in
        // The installer wrote a bad bundle, then the connection dropped.
        try FileManager.default.removeItem(at: appURL)
        try FileManager.default.copyItem(at: bad, to: appURL)
        throw LatestError.installHelperCommunicationFailed
      }
      try operation.takeBackup()
      await operation.installThroughHelper(
        URL(fileURLWithPath: "/tmp/p.pkg"), receipt: Data("r".utf8))
      for _ in 0..<100 where !operation.isFinished { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertTrue(untouchedWhileWaiting.withLock { $0 }, "nothing restored while unknown")
      if helperComesBack {
        XCTAssertEqual(try FixtureApp.digest(app), before, "settled normally once idle")
      } else {
        guard case ReplacementError.outcomeUnknown(let kept)? = operation.error else {
          return XCTFail("Expected outcome-unknown, got \(String(describing: operation.error))")
        }
        XCTAssertEqual(try FixtureApp.digest(app), badDigest, "not restored automatically")
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept), "original kept at \(kept)")
        XCTAssertEqual(target.reopens.withLock { $0 }, 0)
        try? FileManager.default.removeItem(
          at: URL(fileURLWithPath: kept).deletingLastPathComponent())
      }
    }
  }

  /// Queued Q1 (0.2.1 inspection): a raw XPC transport error, arriving before the
  /// interruption handler, is still a lost reply: nothing is restored while unknown.
  @MainActor
  func testRawXPCTransportErrorIsTreatedAsALostReply() async throws {
    let raw = NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionInterrupted)
    XCTAssertTrue(InstallHelper.isLostReply(raw))
    XCTAssertTrue(InstallHelper.isLostReply(InstallHelper.lostReply(raw)))
    XCTAssertFalse(
      InstallHelper.isLostReply(NSError(domain: "LatestInstallerErrorDomain", code: 1)),
      "a failure the helper reports itself is not a lost reply")
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let bad = try FixtureApp.make(in: root.appendingPathComponent("payload"), version: "0.9")
    let badDigest = try FixtureApp.digest(bad)
    let operation = nativeOperation(for: app, target: FakeTarget(running: false)) { _ in }
    operation.helperPollInterval = .milliseconds(20)
    operation.helperWaitLimit = .milliseconds(150)
    operation.helperIsIdle = { nil }
    operation.installPackage = { _, appURL, _, _ in
      try FileManager.default.removeItem(at: appURL)
      try FileManager.default.copyItem(at: bad, to: appURL)
      throw raw
    }
    try operation.takeBackup()
    await operation.installThroughHelper(
      URL(fileURLWithPath: "/tmp/p.pkg"), receipt: Data("r".utf8))
    for _ in 0..<100 where !operation.isFinished { try await Task.sleep(for: .milliseconds(10)) }
    guard case ReplacementError.outcomeUnknown(let kept)? = operation.error else {
      return XCTFail("Expected outcome-unknown, got \(String(describing: operation.error))")
    }
    XCTAssertEqual(try FixtureApp.digest(app), badDigest, "not restored blindly")
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: kept).deletingLastPathComponent())
  }

  /// Queued Q2 (0.2.1 inspection): an app reopened during the download is quit again before
  /// the helper install, and reopened only after a confirmed settlement, never while the
  /// outcome is unknown.
  @MainActor
  func testAppReopenedDuringDownloadIsReopenedOnlyAfterSettlement() async throws {
    for helperComesBack in [false, true] {
      let root = try disposableDirectory()
      let app = try FixtureApp.make(in: root, version: "1.0")
      let target = FakeTarget(running: true)  // the user reopened it during the download
      let operation = nativeOperation(for: app, target: target) { _ in }
      operation.helperPollInterval = .milliseconds(20)
      operation.helperWaitLimit = .milliseconds(200)
      let reopenedWhileUnknown = Mutex(false)
      let polls = Mutex(0)
      operation.helperIsIdle = {
        if target.reopens.withLock({ $0 }) > 0 { reopenedWhileUnknown.withLock { $0 = true } }
        let poll = polls.withLock {
          $0 += 1
          return $0
        }
        return helperComesBack && poll >= 3 ? true : nil
      }
      operation.installPackage = { _, _, _, _ in throw LatestError.installHelperCommunicationFailed
      }
      try operation.takeBackup()
      await operation.installThroughHelper(
        URL(fileURLWithPath: "/tmp/p.pkg"), receipt: Data("r".utf8))
      for _ in 0..<100 where !operation.isFinished { try await Task.sleep(for: .milliseconds(10)) }
      XCTAssertEqual(target.quits.withLock { $0 }, 1)
      XCTAssertFalse(reopenedWhileUnknown.withLock { $0 }, "not reopened mid-install")
      XCTAssertEqual(target.reopens.withLock { $0 }, helperComesBack ? 1 : 0)
      if case ReplacementError.outcomeUnknown(let kept)? = operation.error {
        try? FileManager.default.removeItem(
          at: URL(fileURLWithPath: kept).deletingLastPathComponent())
      }
    }
  }
}

/// An app that takes a moment to quit after being asked.
private final class SlowQuitTarget: Sendable {
  let asked = Mutex(false)
  let terminated = Mutex(false)
  let reopens = Mutex(0)

  var lifecycle: AppLifecycle {
    AppLifecycle(
      runningApps: { [self] _ in
        terminated.withLock { $0 }
          ? []
          : [
            .init(
              terminate: { [self] in
                asked.withLock { $0 = true }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                  self.terminated.withLock { $0 = true }
                }
              }, isTerminated: { [self] in terminated.withLock { $0 } })
          ]
      },
      confirmQuit: { _ in true },
      reopen: { [self] _ in reopens.withLock { $0 += 1 } },
      timeout: .seconds(5))
  }
}
