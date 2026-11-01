import Sparkle
import Synchronization
import XCTest

@testable import Latest

@MainActor
final class SparkleUpdateOperationTest: XCTestCase {
  func testDownloadProgressCoalescesAndUsesLatestByteCounts() async {
    let operation = makeOperation()
    let published = expectation(description: "Latest download totals")
    operation.progressHandler = { [weak operation] _ in
      guard
        case .downloading(let received, let expected, let cancellable) = operation?.progressState
      else { return }
      XCTAssertEqual(received, 130)
      XCTAssertEqual(expected, 130)
      XCTAssertTrue(cancellable)
      published.fulfill()
    }
    operation.showDownloadDidReceiveExpectedContentLength(100)
    operation.showDownloadDidReceiveData(ofLength: 60)
    operation.showDownloadDidReceiveData(ofLength: 70)
    await fulfillment(of: [published], timeout: 1)
    operation.finish()
  }

  func testPendingDownloadProgressCannotReplaceExtractionOrInstallation() async {
    let extracting = makeOperation()
    let installing = makeOperation()
    let staleDownload = expectation(description: "No download progress after phase transition")
    staleDownload.isInverted = true
    for operation in [extracting, installing] {
      operation.progressHandler = { [weak operation] _ in
        if case .downloading = operation?.progressState { staleDownload.fulfill() }
      }
      operation.showDownloadDidReceiveExpectedContentLength(100)
      operation.showDownloadDidReceiveData(ofLength: 100)
    }
    extracting.showDownloadDidStartExtractingUpdate()
    extracting.showExtractionReceivedProgress(0.5)
    installing.showInstallingUpdate(
      withApplicationTerminated: true, retryTerminatingApplication: {})

    await fulfillment(of: [staleDownload], timeout: 0.35)
    if case .extracting(let progress, let cancellable) = extracting.progressState {
      XCTAssertEqual(progress, 0.5)
      XCTAssertFalse(cancellable)
    } else {
      XCTFail("Extraction must remain visible")
    }
    if case .installing = installing.progressState {
      // Installation must not regress to downloading.
    } else {
      XCTFail("Installation must remain visible")
    }
    extracting.finish()
    installing.finish()
  }

  func testFallbackDownloadKeepsInstallerHandoffProtected() async {
    let operation = makeOperation()
    operation.showDownloadDidStartExtractingUpdate()
    let published = expectation(description: "Protected full download after delta failure")
    operation.progressHandler = { [weak operation] _ in
      guard
        case .downloading(let received, let expected, let cancellable) = operation?.progressState
      else { return }
      XCTAssertEqual(received, 20)
      XCTAssertEqual(expected, 100)
      XCTAssertFalse(cancellable)
      published.fulfill()
    }
    operation.showDownloadDidReceiveExpectedContentLength(100)
    operation.showDownloadDidReceiveData(ofLength: 20)
    await fulfillment(of: [published], timeout: 1)
    operation.cancel()
    XCTAssertFalse(operation.isCancelled)
    XCTAssertFalse(operation.isFinished)
    operation.finish()
  }

  func testCancellationFinishesAndCallsSparkleOnMainActor() async {
    let operation = makeOperation()
    let cancelled = expectation(description: "Sparkle cancellation callback")
    operation.showDownloadInitiated {
      XCTAssertTrue(Thread.isMainThread)
      cancelled.fulfill()
    }
    operation.showDownloadDidReceiveExpectedContentLength(100)
    await Task.detached { operation.cancel() }.value
    XCTAssertTrue(operation.isCancelled)
    XCTAssertTrue(operation.isFinished)
    await fulfillment(of: [cancelled], timeout: 1)
    if case .none = operation.progressState {
      // Completion clears progress synchronously, before actor cleanup.
    } else {
      XCTFail("Cancelled operation must clear its progress")
    }
  }

  func testCancelAfterInstallationHandoffWaitsForSuccessAndRefreshes() async {
    let operation = makeOperation()
    let notices = Mutex(0)
    let observer = NotificationCenter.default.addObserver(
      forName: .latestUpdateOperationDidFinish, object: operation, queue: nil
    ) { _ in notices.withLock { $0 += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }
    operation.showReady { XCTAssertEqual($0, .install) }
    await Task.detached { operation.cancel() }.value
    XCTAssertFalse(operation.isCancelled)
    XCTAssertFalse(operation.isFinished)
    operation.showUpdateInstalledAndRelaunched(false, acknowledgement: {})
    await waitUntilFinished(operation)  // the result is verified before it is published
    XCTAssertTrue(operation.isFinished)
    XCTAssertEqual(notices.withLock { $0 }, 1)

    let cancelled = makeOperation()
    cancelled.cancel()
    cancelled.showReady { XCTAssertEqual($0, .skip) }
  }

  func testClosedAppInstallationProtectsCommitWithoutReadyCallback() async {
    for beforeStageTwo in [true, false] {
      let operation = makeOperation()
      let notices = Mutex(0)
      let observer = NotificationCenter.default.addObserver(
        forName: .latestUpdateOperationDidFinish, object: operation, queue: nil
      ) { _ in notices.withLock { $0 += 1 } }
      defer { NotificationCenter.default.removeObserver(observer) }
      // Sparkle can replace a closed target before its stage-two callback arrives.
      if beforeStageTwo {
        operation.showDownloadDidStartExtractingUpdate()
      } else {
        operation.showInstallingUpdate(
          withApplicationTerminated: true, retryTerminatingApplication: {})
      }
      await Task.detached { operation.cancel() }.value
      XCTAssertFalse(operation.isCancelled)
      XCTAssertFalse(operation.isFinished)
      operation.showInstallingUpdate(
        withApplicationTerminated: true, retryTerminatingApplication: {})
      operation.showUpdateInstalledAndRelaunched(false, acknowledgement: {})
      await waitUntilFinished(operation)
      XCTAssertTrue(operation.isFinished)
      XCTAssertEqual(notices.withLock { $0 }, 1)
    }
  }

  func testWaitingForTargetQuitOffersRetryThroughExistingOperation() async {
    let app = makeTestApp(name: "Sparkle target", version: "1", remoteVersion: "2")
    let queue = UpdateQueue()
    queue.isSuspended = true
    let operation = SparkleUpdateOperation(
      bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
    // Not running, and a quit limit longer than this test: retries stay available.
    operation.lifecycle = AppLifecycle(
      runningApps: { _ in [] }, confirmQuit: { _ in true }, reopen: { _ in },
      timeout: .seconds(60))
    queue.addOperation(operation)
    defer {
      operation.finish()
      queue.isSuspended = false
    }
    operation.showReady { XCTAssertEqual($0, .install) }
    var retries = 0
    operation.showInstallingUpdate(
      withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
    let model = UpdateActionViewModel(app: app, updating: AppUpdateService(queue: queue))
    model.performAction()
    model.performAction()
    XCTAssertEqual(retries, 2, "A refused quit must remain retryable without creating a new update")
    XCTAssertFalse(operation.isFinished)
    XCTAssertFalse(operation.isCancelled)

    operation.showInstallingUpdate(
      withApplicationTerminated: true, retryTerminatingApplication: { retries += 100 })
    for _ in 0..<100 {
      if model.presentation == .make(for: app, progressState: .installing) { break }
      await Task.yield()
    }
    model.performAction()
    XCTAssertEqual(retries, 2, "The retry action must disappear after the target has quit")
  }

  /// Sol finding: information-only items hand off to their page and are never installed.
  func testInformationOnlyItemsHandOffAndAreNeverInstalled() throws {
    // The deprecated initializer is the public way to build an item without a feed.
    let item = try XCTUnwrap(
      SUAppcastItem(dictionary: [
        "sparkle:version": "2.0", "sparkle:shortVersionString": "2.0",
        "link": "https://example.com/release",
      ]))
    XCTAssertTrue(item.isInformationOnlyUpdate)
    guard case .external(let label, _) = SparkleUpdateCheckerOperation.updateAction(for: item)
    else { return XCTFail("Information-only items must hand off") }
    XCTAssertEqual(label, "example.com")

    let operation = makeOperation()
    let opened = Mutex<[URL]>([])
    operation.openURL = { url in opened.withLock { $0.append(url) } }
    var choices = [SPUUserUpdateChoice]()
    operation.handleUpdateFound(item) { choices.append($0) }
    XCTAssertEqual(choices, [.dismiss])
    XCTAssertEqual(opened.withLock { $0 }, [URL(string: "https://example.com/release")!])
    XCTAssertEqual(operation.outcomeOverride, .handedOff)
    XCTAssertTrue(operation.isFinished)
  }

  /// Sol R7: a running target that refuses to quit within the limit gets no install and no
  /// deferred install (.skip), and the job ends as needing a quit.
  func testRefusedQuitBeforeInstallSkipsAndFinishes() async throws {
    let operation = makeOperation()
    operation.lifecycle = AppLifecycle(
      runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
      confirmQuit: { _ in true }, reopen: { _ in }, timeout: .milliseconds(200))
    let replied = expectation(description: "Sparkle got its answer")
    operation.showReady { choice in
      XCTAssertEqual(choice, .skip)
      replied.fulfill()
    }
    await fulfillment(of: [replied], timeout: 3)
    for _ in 0..<100 where !operation.isFinished { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(operation.isFinished)
    let before = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "Sparkle",
      bundleIdentifier: "test.sparkle", fileURL: operation.appIdentifier, source: .sparkle,
      modificationDate: .distantPast)
    XCTAssertEqual(UpdateQueue.outcome(of: operation, before: before, after: before), .needsQuit)
  }

  /// Sol R2 (second pass): once Sparkle has committed and waits for the app to quit, the
  /// job stays open past the quit window and keeps its target, so nothing else can start.
  func testCommittedWaitForQuitHoldsTheJobUntilSparkleFinishes() async throws {
    let queue = UpdateQueue()
    queue.isSuspended = true
    defer { queue.isSuspended = false }
    let url = URL(fileURLWithPath: "/tmp/Sparkle-\(UUID().uuidString).app")
    let operation = SparkleUpdateOperation(bundleIdentifier: "test.sparkle", appIdentifier: url)
    operation.lifecycle = FakeTarget(running: false).lifecycle(timeout: .milliseconds(100))
    queue.submit(operation)
    operation.showInstallingUpdate(
      withApplicationTerminated: false, retryTerminatingApplication: {})
    try await Task.sleep(for: .milliseconds(400))
    XCTAssertFalse(operation.isFinished)
    guard case .waitingForQuit = operation.progressState else {
      return XCTFail("The row keeps showing that the app must quit")
    }
    let other = SparkleUpdateOperation(bundleIdentifier: "test.sparkle", appIdentifier: url)
    XCTAssertTrue(queue.submit(other) === operation, "the target stays held")
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    queue.isSuspended = false
    operation.showUpdateInstalledAndRelaunched(false) {}
    await fulfillment(of: [done], timeout: 3)
  }

  /// Sol R1 (second pass): Updater clones the target before Sparkle commits and restores it
  /// if Sparkle leaves anything but the advertised (or newer) version of the same product.
  func testSparkleResultIsVerifiedAgainstUpdatersOwnClone() async throws {
    for (installed, expectRestore) in [("1.1", true), ("1.2", false)] {
      let root = try disposableDirectory()
      let app = try FixtureApp.make(in: root, version: "1.0")
      let before = try FixtureApp.digest(app)
      let operation = SparkleUpdateOperation(
        bundleIdentifier: FixtureApp.identifier, appIdentifier: app)
      operation.requiresTeam = false
      operation.lifecycle = FakeTarget(running: false).lifecycle()
      try operation.takeBackup()
      operation.expectedVersion = Version(versionNumber: "1.2", buildNumber: "1.2")
      // What Sparkle's installer would do: replace the bundle with its payload.
      let payload = try FixtureApp.make(
        in: root.appendingPathComponent("payload"), version: installed)
      try FileManager.default.removeItem(at: app)
      try FileManager.default.copyItem(at: payload, to: app)
      await operation.finalize(nil)
      XCTAssertTrue(operation.isFinished)
      if expectRestore {
        XCTAssertTrue(operation.error is ReplacementError, "\(String(describing: operation.error))")
        XCTAssertEqual(try FixtureApp.digest(app), before, "restored byte-for-byte")
      } else {
        XCTAssertNil(operation.error)
        XCTAssertEqual(try BundleIdentity.read(at: app, validate: false).shortVersion, "1.2")
      }
    }
  }

  /// Sol R1 + R6 (second pass): a relaunched bad version is quit before the clone goes back,
  /// and the app Updater quit is reopened exactly once after a restore or an error, but not
  /// when Sparkle already relaunched it.
  func testQuitTargetIsReopenedOnceAfterFailureButNotAfterRelaunch() async throws {
    // Relaunched with a bad version: quit it, restore, reopen once.
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let before = try FixtureApp.digest(app)
    let target = FakeTarget(running: true)
    let operation = SparkleUpdateOperation(
      bundleIdentifier: FixtureApp.identifier, appIdentifier: app)
    operation.requiresTeam = false
    operation.lifecycle = target.lifecycle()
    try operation.takeBackup()
    operation.expectedVersion = Version(versionNumber: "1.2", buildNumber: "1.2")
    let replied = expectation(description: "install answered")
    operation.showReady { choice in
      XCTAssertEqual(choice, .install)
      replied.fulfill()
    }
    await fulfillment(of: [replied], timeout: 3)
    let payload = try FixtureApp.make(in: root.appendingPathComponent("payload"), version: "1.1")
    try FileManager.default.removeItem(at: app)
    try FileManager.default.copyItem(at: payload, to: app)
    target.running.withLock { $0 = true }  // Sparkle relaunched it
    await operation.finalize(nil)
    XCTAssertEqual(try FixtureApp.digest(app), before)
    XCTAssertEqual(target.quits.withLock { $0 }, 2, "quit before install and before restore")
    XCTAssertEqual(target.reopens.withLock { $0 }, 1)

    // Quit, then Sparkle fails: reopened once.
    let existing = try FixtureApp.make(in: root.appendingPathComponent("other"), version: "1.0")
    let failing = FakeTarget(running: true)
    let errored = SparkleUpdateOperation(bundleIdentifier: "test.sparkle", appIdentifier: existing)
    errored.lifecycle = failing.lifecycle()
    let answered = expectation(description: "answered")
    errored.showReady { _ in answered.fulfill() }
    await fulfillment(of: [answered], timeout: 3)
    await errored.finalize(URLError(.cannotConnectToHost))
    XCTAssertEqual(failing.reopens.withLock { $0 }, 1)

    // Quit, installed and relaunched by Sparkle: no second launch.
    let relaunched = FakeTarget(running: true)
    let succeeded = SparkleUpdateOperation(
      bundleIdentifier: "test.sparkle", appIdentifier: existing)
    succeeded.lifecycle = relaunched.lifecycle()
    let ready = expectation(description: "ready")
    succeeded.showReady { _ in ready.fulfill() }
    await fulfillment(of: [ready], timeout: 3)
    relaunched.running.withLock { $0 = true }
    await succeeded.finalize(nil)
    XCTAssertEqual(relaunched.reopens.withLock { $0 }, 0)
  }

  private func waitUntilFinished(_ operation: SparkleUpdateOperation) async {
    for _ in 0..<200 where !operation.isFinished { try? await Task.sleep(for: .milliseconds(5)) }
  }

  private func makeOperation() -> SparkleUpdateOperation {
    SparkleUpdateOperation(
      bundleIdentifier: "test.sparkle", appIdentifier: URL(fileURLWithPath: "/tmp/Sparkle.app"))
  }
}

/// A target app that quits when asked and records relaunches.
private final class FakeTarget: Sendable {
  let running: Mutex<Bool>
  let quits = Mutex(0)
  let reopens = Mutex(0)
  init(running: Bool) { self.running = Mutex(running) }

  func lifecycle(timeout: Duration = .seconds(2)) -> AppLifecycle {
    AppLifecycle(
      runningApps: { [self] _ in
        running.withLock { $0 }
          ? [
            .init(
              terminate: { [self] in
                quits.withLock { $0 += 1 }
                running.withLock { $0 = false }
              }, isTerminated: { [self] in !running.withLock { $0 } })
          ] : []
      },
      confirmQuit: { _ in true },
      reopen: { [self] _ in
        reopens.withLock { $0 += 1 }
        running.withLock { $0 = true }
      },
      timeout: timeout)
  }
}
