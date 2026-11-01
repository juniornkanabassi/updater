// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import XCTest

@testable import Latest

final class InstallHelperTest: XCTestCase {
  func testHelperReplyGateResumesContinuationOnlyOnce() async throws {
    let expected = URL(fileURLWithPath: "/Applications/Updated.app")
    let installed = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<URL, Error>) in
      let replyGate = HelperReplyGate(continuation: continuation)
      replyGate.resume(with: .success(expected))
      replyGate.resume(with: .failure(LatestError.installHelperCommunicationFailed))
    }
    XCTAssertEqual(installed, expected)
  }

  @MainActor
  func testHelperRegistrationResumesPendingUpdateAfterApprovalOnlyOnce() async throws {
    let stored = AppStoreUpdateSettings.alwaysPerformManualUpdates.active
    AppStoreUpdateSettings.alwaysPerformManualUpdates.active = false
    defer { AppStoreUpdateSettings.alwaysPerformManualUpdates.active = stored }
    let helper = HelperRegistrationFixture()
    let presenter = UpdateInstallHelperAlert(helper: helper)
    var resumed = 0
    presenter.prepare(
      fallbackURL: URL(string: "https://example.com")!, error: .installHelperNotRegistered
    ) { resumed += 1 }
    presenter.enableHelper()
    try await waitForHelper { !presenter.isChecking }
    XCTAssertEqual(helper.registrations, 1)
    XCTAssertEqual(resumed, 0)
    helper.enabled = true
    presenter.resumeIfAvailable()
    presenter.resumeIfAvailable()
    try await waitForHelper { !presenter.isChecking }
    XCTAssertEqual(resumed, 1)
    XCTAssertFalse(presenter.isPresented)
  }

  @MainActor
  func testHelperRegistrationFailureIsVisibleAndCancelDoesNotRetry() async throws {
    let stored = AppStoreUpdateSettings.alwaysPerformManualUpdates.active
    AppStoreUpdateSettings.alwaysPerformManualUpdates.active = false
    defer { AppStoreUpdateSettings.alwaysPerformManualUpdates.active = stored }
    let helper = HelperRegistrationFixture()
    helper.failure = NSError(
      domain: "registration", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Signing does not match"])
    let presenter = UpdateInstallHelperAlert(helper: helper)
    var resumed = false
    presenter.prepare(
      fallbackURL: URL(string: "https://example.com")!, error: .installHelperNotRegistered
    ) { resumed = true }
    presenter.enableHelper()
    try await waitForHelper { !presenter.isChecking }
    XCTAssertTrue(presenter.isPresented)
    XCTAssertTrue(
      presenter.errorDetails?.contains("Signing does not match") == true)
    presenter.cancel()
    helper.enabled = true
    presenter.resumeIfAvailable()
    XCTAssertFalse(resumed)
  }
  @MainActor
  func testFailedReadinessBlocksWholeBatchAndRetryStartsEachUpdateOnce() async throws {
    let helper = HelperRegistrationFixture()
    helper.enabled = true
    helper.readinessFailure = InstallHelperError.unavailable("Connection rejected")
    let presenter = UpdateInstallHelperAlert(helper: helper)
    var downloads: [Int] = []
    let url = URL(string: "macappstore://apps.apple.com/updates")!
    presenter.prepare(fallbackURL: url) { downloads.append(1) }
    presenter.prepare(fallbackURL: url) { downloads.append(2) }
    try await waitForHelper { !presenter.isChecking }
    XCTAssertTrue(downloads.isEmpty)
    XCTAssertTrue(presenter.isPresented)
    XCTAssertEqual(presenter.primaryTitle, "Check Again")
    helper.readinessFailure = nil
    presenter.enableHelper()
    try await waitForHelper { !presenter.isChecking }
    XCTAssertEqual(downloads, [1, 2])
    presenter.resumeIfAvailable()
    XCTAssertEqual(downloads, [1, 2])
  }

  @MainActor
  func testCancelAndAppStoreFallbackDiscardLateSuccessfulReadiness() async throws {
    for opensStore in [false, true] {
      let helper = HelperRegistrationFixture()
      helper.enabled = true
      helper.suspendsCheck = true
      let workspace = StubApplicationWorkspace()
      let presenter = UpdateInstallHelperAlert(helper: helper, workspace: workspace)
      let url = URL(string: "macappstore://apps.apple.com/updates")!
      var downloads = 0
      presenter.prepare(fallbackURL: url) { downloads += 1 }
      try await waitForHelper { helper.pendingCheck != nil }
      let cancelledCheck = try XCTUnwrap(helper.pendingCheck)
      if opensStore { presenter.openAppStore() } else { presenter.cancel() }
      XCTAssertEqual(downloads, 0)
      XCTAssertFalse(presenter.isPresented)
      XCTAssertEqual(workspace.openedURLs, opensStore ? [url] : [])

      helper.pendingCheck = nil
      presenter.prepare(fallbackURL: url) { downloads += 1 }
      try await waitForHelper { helper.pendingCheck != nil }
      cancelledCheck.resume()
      try await waitForHelper { helper.completedChecks == 1 }
      XCTAssertEqual(downloads, 0, "A cancelled reply must not release a newer batch")
      XCTAssertTrue(presenter.isChecking)
      helper.pendingCheck?.resume()
      try await waitForHelper { !presenter.isChecking }
      XCTAssertEqual(downloads, 1)
    }
  }

  func testReadinessRepairsStaleDaemonAndChecksAgainForNextBatch() async throws {
    let backend = ReadinessFixture(probes: [
      .success(.stale), .success(.idle), .success(.idle),
    ])
    let readiness = InstallHelperReadiness(backend: backend)
    try await readiness.prepare()
    try await readiness.prepare()
    let events = await backend.events
    XCTAssertEqual(events, ["verify", "probe", "refresh", "probe", "verify", "probe"])
  }

  func testLegacyRegistrationMigratesOnlyWhenTheHelperIsNotBusy() async throws {
    for busy in [false, true] {
      let backend = ReadinessFixture(
        probes: [.success(busy ? .busy : .idle), .success(.idle)], needsMigration: true)
      do {
        try await InstallHelperReadiness(backend: backend).prepare()
        XCTAssertFalse(busy, "Migration must wait for the active installation")
      } catch {
        XCTAssertTrue(busy)
        XCTAssertTrue(error.localizedDescription.contains("installation"))
      }
      let events = await backend.events
      XCTAssertEqual(events, busy ? ["verify", "probe"] : ["verify", "probe", "refresh", "probe"])
    }
  }

  func testBundledMigrationPreservesTheAuthenticatedEndpointAndLaunchConstraint() throws {
    func plist(_ label: String) throws -> NSDictionary {
      let url = Bundle.main.bundleURL.appendingPathComponent(
        "Contents/Library/LaunchDaemons/\(label).plist")
      return try XCTUnwrap(
        PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
          as? NSDictionary)
    }
    let legacy = try plist(UpdateInstallerIdentity.service)
    let current = try plist(UpdateInstallerIdentity.daemon)
    XCTAssertEqual(current["Label"] as? String, UpdateInstallerIdentity.daemon)
    XCTAssertNotEqual(current["Label"] as? String, legacy["Label"] as? String)
    for key in ["BundleProgram", "MachServices", "SpawnConstraint"] {
      XCTAssertEqual(current[key] as? NSObject, legacy[key] as? NSObject, key)
    }
  }

  func testFailedPrerequisiteDoesNotContactOrRefreshDaemon() async {
    let backend = ReadinessFixture(probes: [])
    await backend.failVerification()
    do {
      try await InstallHelperReadiness(backend: backend).prepare()
      XCTFail("Must stop before download")
    } catch { XCTAssertEqual(error as? InstallHelperError, .installHelperRequiresApproval) }
    let events = await backend.events
    XCTAssertEqual(events, ["verify"])
  }

  func testUnreachableHelperStopsBeforeInstallationAfterOneRepair() async {
    let backend = ReadinessFixture(
      probes: Array(repeating: .failure(CocoaError(.xpcConnectionInvalid)), count: 4))
    let readiness = InstallHelperReadiness(backend: backend)
    do {
      _ = try await readiness.install {
        XCTFail("Must not install")
        return URL(fileURLWithPath: "/unused")
      }
      XCTFail("Unreachable helper must fail")
    } catch {}
    let events = await backend.events
    XCTAssertEqual(events.filter { $0 == "refresh" }.count, 1)
    XCTAssertEqual(events.filter { $0 == "probe" }.count, 4)
  }

  func testFailedHealthValidationCannotRestartAnAuthenticatedBusyHelper() async throws {
    let failure = CocoaError(.executableNotLoadable)
    let health = try InstallHelperHealth(signature: nil, isInstalling: true, error: failure)
    let backend = ReadinessFixture(probes: [.success(health)])
    do {
      try await InstallHelperReadiness(backend: backend).prepare()
      XCTFail("A fresh app must not restart a busy helper")
    } catch { XCTAssertTrue(error.localizedDescription.contains("installation")) }
    let events = await backend.events
    XCTAssertFalse(events.contains("refresh"))
    XCTAssertThrowsError(
      try InstallHelperHealth(signature: nil, isInstalling: false, error: failure))
  }

  func testReadinessFailureDoesNotRestartAnActiveInstallation() async throws {
    let backend = ReadinessFixture(probes: [
      .success(.idle), .failure(CocoaError(.xpcConnectionInvalid)),
    ])
    let readiness = InstallHelperReadiness(backend: backend)
    let started = expectation(description: "Installation dispatched")
    let (release, continuation) = AsyncStream<Void>.makeStream()
    let installation = Task {
      try await readiness.install {
        started.fulfill()
        for await _ in release { break }
        return URL(fileURLWithPath: "/installed.app")
      }
    }
    await fulfillment(of: [started], timeout: 2)
    do {
      try await readiness.prepare()
      XCTFail("Broken helper must not admit another download")
    } catch { XCTAssertTrue(error.localizedDescription.contains("installation")) }
    let events = await backend.events
    XCTAssertFalse(events.contains("refresh"))
    continuation.yield(())
    continuation.finish()
    _ = try await installation.value
  }

  func testConcurrentReadinessChecksShareOnlyTheInFlightProbe() async throws {
    let backend = ReadinessFixture(probes: [.success(.idle), .success(.idle)])
    let probing = expectation(description: "Readiness probe started")
    await backend.suspendNextProbe(started: probing)
    let readiness = InstallHelperReadiness(backend: backend)
    let first = Task { try await readiness.prepare() }
    await fulfillment(of: [probing], timeout: 2)
    let second = Task { try await readiness.prepare() }
    try await Task.sleep(for: .milliseconds(30))
    await backend.releaseProbe()
    try await first.value
    try await second.value
    try await readiness.prepare()
    let events = await backend.events
    XCTAssertEqual(events, ["verify", "probe", "verify", "probe"])
  }

  func testLostInstallationReplyPreventsBlindRefreshUntilLiveIdleResponse() async throws {
    let backend = ReadinessFixture(probes: [
      .success(.idle), .failure(CocoaError(.xpcConnectionInvalid)), .success(.busy),
      .success(.idle),
    ])
    let readiness = InstallHelperReadiness(backend: backend)
    do {
      _ = try await readiness.install { throw CocoaError(.xpcConnectionInterrupted) }
      XCTFail("Installation reply must fail")
    } catch {}
    for expectedMessage in ["unknown", "still installing"] {
      do {
        try await readiness.prepare()
        XCTFail("Unknown or busy installation must block repair")
      } catch { XCTAssertTrue(error.localizedDescription.contains(expectedMessage)) }
    }
    try await readiness.prepare()
    let events = await backend.events
    XCTAssertFalse(events.contains("refresh"))
  }

  func testIdleProbeCannotClearAnInstallationFailureThatHappenedDuringTheProbe() async throws {
    let backend = ReadinessFixture(probes: [
      .success(.idle), .success(.idle), .failure(CocoaError(.xpcConnectionInvalid)),
    ])
    let readiness = InstallHelperReadiness(backend: backend)
    let started = expectation(description: "Installation dispatched")
    let (release, continuation) = AsyncStream<Void>.makeStream()
    let installation = Task {
      try await readiness.install {
        started.fulfill()
        for await _ in release { break }
        throw CocoaError(.xpcConnectionInterrupted)
      }
    }
    await fulfillment(of: [started], timeout: 2)
    let probing = expectation(description: "Idle response pending")
    await backend.suspendNextProbe(started: probing)
    let check = Task { try await readiness.prepare() }
    await fulfillment(of: [probing], timeout: 2)
    continuation.finish()
    do {
      _ = try await installation.value
      XCTFail("Installation reply must fail")
    } catch {}
    await backend.releaseProbe()
    try await check.value
    do {
      try await readiness.prepare()
      XCTFail("The earlier idle response must not authorize a helper restart")
    } catch { XCTAssertTrue(error.localizedDescription.contains("unknown")) }
    let events = await backend.events
    XCTAssertFalse(events.contains("refresh"))
  }

  func testCancellationDuringReadinessNeverDispatchesInstallation() async throws {
    let backend = ReadinessFixture(probes: [.success(.idle)])
    let probing = expectation(description: "Readiness probe started")
    await backend.suspendNextProbe(started: probing)
    let readiness = InstallHelperReadiness(backend: backend)
    let cancelled = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await readiness.prepare()
    }
    do {
      try await cancelled.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
    let events = await backend.events
    XCTAssertTrue(events.isEmpty)
    let installation = Task {
      try await readiness.install {
        XCTFail("Cancelled caller must not install")
        return URL(fileURLWithPath: "/unused")
      }
    }
    await fulfillment(of: [probing], timeout: 2)
    installation.cancel()
    await backend.releaseProbe()
    do {
      _ = try await installation.value
      XCTFail("Expected cancellation")
    } catch { XCTAssertTrue(error is CancellationError) }
  }

}

@MainActor
final class HelperRegistrationFixture: InstallHelperServicing {
  var enabled = false
  var failure: Error?
  private(set) var registrations = 0
  func verifyAvailability() throws {
    if !enabled { throw InstallHelperError.installHelperRequiresApproval }
  }
  var pendingCheck: CheckedContinuation<Void, Error>?
  var suspendsCheck = false
  var readinessFailure: Error?
  private(set) var completedChecks = 0
  func prepareForUpdates() async throws {
    defer { completedChecks += 1 }
    if suspendsCheck {
      try await withCheckedThrowingContinuation { pendingCheck = $0 }
    }
    if let readinessFailure { throw readinessFailure }
    try verifyAvailability()
  }
  func register() throws {
    registrations += 1
    if let failure { throw failure }
  }
}

@MainActor
func waitForHelper(_ condition: () -> Bool) async throws {
  for _ in 0..<200 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  XCTFail("Helper state did not settle")
  throw CocoaError(.userCancelled)
}

private actor ReadinessFixture: InstallHelperReadinessBackend {
  var events: [String] = []
  var probes: [Result<InstallHelperHealth, Error>]
  var verificationFails = false
  private let needsMigration: Bool
  private var probeStarted: XCTestExpectation?
  private var probeContinuation: CheckedContinuation<Void, Never>?
  func suspendNextProbe(started: XCTestExpectation) { probeStarted = started }
  func releaseProbe() {
    probeContinuation?.resume()
    probeContinuation = nil
  }

  init(probes: [Result<InstallHelperHealth, Error>], needsMigration: Bool = false) {
    self.probes = probes
    self.needsMigration = needsMigration
  }
  func failVerification() { verificationFails = true }
  func verify() throws -> (signature: Data, needsMigration: Bool) {
    events.append("verify")
    if verificationFails { throw InstallHelperError.installHelperRequiresApproval }
    return (Data([1]), needsMigration)
  }
  func probe() async throws -> InstallHelperHealth {
    events.append("probe")
    if let started = probeStarted {
      probeStarted = nil
      await withCheckedContinuation {
        probeContinuation = $0
        started.fulfill()
      }
    }
    guard !probes.isEmpty else { throw CocoaError(.xpcConnectionInvalid) }
    return try probes.removeFirst().get()
  }
  func refresh() { events.append("refresh") }
}

extension InstallHelperHealth {
  fileprivate static let idle = Self(signature: Data([1]), isInstalling: false)
  fileprivate static let busy = Self(signature: Data([1]), isInstalling: true)
  fileprivate static let stale = Self(signature: Data([0]), isInstalling: false)
}
