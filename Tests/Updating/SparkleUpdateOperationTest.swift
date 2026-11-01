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

  private func makeOperation() -> SparkleUpdateOperation {
    SparkleUpdateOperation(
      bundleIdentifier: "test.sparkle", appIdentifier: URL(fileURLWithPath: "/tmp/Sparkle.app"))
  }
}
