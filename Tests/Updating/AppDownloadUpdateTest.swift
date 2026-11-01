import Network
import Synchronization
import XCTest

@testable import Latest

final class AppDownloadUpdateTest: XCTestCase {
  func testStandaloneSourceLeavesDiscordToItsNativeUpdater() throws {
    let directory = try temporaryDirectory()
    for (identifier, token, supported) in [
      ("com.hnc.Discord", "discord", false),
      ("com.1password.1password", "1password", true),
      ("com.docker.docker", "docker-desktop", true),
      ("com.1password.1password", "discord", false),
    ] {
      let app = App.Bundle(
        version: Version(versionNumber: "1", buildNumber: nil), name: token,
        bundleIdentifier: identifier, fileURL: directory.appendingPathComponent(token + ".app"),
        source: .homebrew)
      XCTAssertEqual(AppDownloadSource.homebrewSource(for: app, token: token) != nil, supported)
    }
  }

  func testRealDownloadReportsPartialProgressAndKeepsTheCompletedFile() async throws {
    for knownSize in [true, false] {
      let ready = expectation(description: "Loopback server ready")
      let partial = expectation(description: "Progress arrives before the response completes")
      let server = try StreamingDownloadServer(knownSize: knownSize, ready: ready)
      defer { server.stop() }
      await fulfillment(of: [ready], timeout: 3)
      let url = try XCTUnwrap(server.url)
      let samples = Mutex<[(Int64, Int64)]>([])
      let delegate = BoundedDownloadDelegate(maximumSize: 1_024 * 1_024) { loaded, total in
        let first = samples.withLock { samples in
          let first = samples.isEmpty
          samples.append((loaded, total))
          return first
        }
        if first { partial.fulfill() }
      }
      let destination = try temporaryDirectory().appendingPathComponent("download.zip")
      let task = Task { try await delegate.download(from: url, to: destination) }
      defer { task.cancel() }
      await fulfillment(of: [partial], timeout: 3)
      let first = try XCTUnwrap(samples.withLock { $0.first })
      XCTAssertGreaterThan(first.0, 0)
      XCTAssertLessThan(first.0, Int64(server.payload.count * 2))
      XCTAssertEqual(first.1, knownSize ? Int64(server.payload.count * 2) : -1)
      server.complete()
      let response = try await task.value
      XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      XCTAssertEqual(try Data(contentsOf: destination), server.payload + server.payload)
      XCTAssertFalse(delegate.exceededLimit)
    }
  }

  func testRealDownloadCancellationAndSizeLimitsFinishBeforeTheServerCompletes() async throws {
    for scenario in ["cancel", "cancel-before-start", "known-limit", "unknown-limit"] {
      let ready = expectation(description: "Loopback server ready")
      let partial = scenario == "cancel" ? expectation(description: "Download started") : nil
      let server = try StreamingDownloadServer(knownSize: scenario != "unknown-limit", ready: ready)
      defer { server.stop() }
      await fulfillment(of: [ready], timeout: 3)
      let url = try XCTUnwrap(server.url)
      let limited = scenario.hasSuffix("limit")
      let firstProgress = Mutex(true)
      let delegate = BoundedDownloadDelegate(maximumSize: limited ? 16 : 1_024 * 1_024) { _, _ in
        let first = firstProgress.withLock { first in
          defer { first = false }
          return first
        }
        if first { partial?.fulfill() }
      }
      let destination = try temporaryDirectory().appendingPathComponent("download.zip")
      let gate = AsyncStream<Void>.makeStream()
      let task = Task {
        for await _ in gate.stream { break }
        return try await delegate.download(from: url, to: destination)
      }
      if scenario == "cancel-before-start" { task.cancel() }
      gate.continuation.finish()
      if let partial {
        await fulfillment(of: [partial], timeout: 3)
        task.cancel()
      }
      do {
        _ = try await task.value
        XCTFail("Cancelled or oversized transfer must fail")
      } catch {
        XCTAssertEqual((error as? URLError)?.code, .cancelled)
      }
      XCTAssertEqual(delegate.exceededLimit, limited)
      XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
  }

  func testInvalidDiskImagePreservesAttachmentError() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let extracted = directory.appendingPathComponent("payload")
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let archive = directory.appendingPathComponent("invalid.dmg")
    try Data("This is not a disk image".utf8).write(to: archive)
    do {
      try await AppDownloadUpdateOperation.stageApp(
        from: archive, appPath: "Fixture.app", extracted: extracted,
        to: directory.appendingPathComponent("candidate.app"))
      XCTFail("Invalid images must fail before copying")
    } catch AppDownloadError.toolFailed(let message) {
      XCTAssertTrue(message.contains("attach failed"), message)
      XCTAssertFalse(message.contains("detach failed"), message)
    }
  }

  func testZIPExtractionCannotWriteThroughAnArchiveSymlink() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = directory.appendingPathComponent("outside")
    let extracted = directory.appendingPathComponent("extracted")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/symlink-escape.zip")
    do {
      try await AppDownloadUpdateOperation.extractZIP(at: fixture, to: extracted)
      XCTFail("Archive paths through symlinks must be rejected")
    } catch {}
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.txt").path))
  }

  /// Opt-in integration check against downloaded vendor artifacts; never installs them.
  func testDownloadedVendorArtifactsMatchTheirInstalledSigningIdentity() async throws {
    guard let path = ProcessInfo.processInfo.environment["LATEST_VENDOR_ARTIFACTS"] else {
      throw XCTSkip("Set LATEST_VENDOR_ARTIFACTS to a prepared vendor-validation directory.")
    }
    try await Task.detached {
      let directory = URL(fileURLWithPath: path)
      let delta = try XCTUnwrap(
        BundleCollector.collectBundle(at: URL(fileURLWithPath: "/Applications/Delta.app")))
      let release = try AppDownloadRelease(
        data: Data(contentsOf: directory.appendingPathComponent("delta-release.json")),
        source: .delta
      )
      try AppDownloadUpdateOperation.validate(
        candidate: directory.appendingPathComponent("Delta.app"),
        replacing: delta, expectedVersion: release.version)
      let obsidian = try ObsidianUpdate.release(
        from: Data(
          contentsOf: directory.deletingLastPathComponent().appendingPathComponent(
            "obsidian-release.json")),
        includesEarlyAccess: false)
      try ObsidianUpdate.verify(
        Data(contentsOf: directory.appendingPathComponent("obsidian.asar.gz")), release: obsidian)
    }.value
  }

  func testDownloadMetadataSelectsTheHostArchitectureAndRejectsInstallerArtifacts() throws {
    var record: [String: Any] = [
      "version": "2.0.0", "url": "https://example.com/arm64.dmg",
      "sha256": String(repeating: "a", count: 64), "artifacts": [["app": ["Example.app"]]],
      "variations": [
        "tahoe": [
          "url": "https://example.com/intel.dmg", "sha256": String(repeating: "b", count: 64),
        ]
      ],
    ]
    func release(_ platform: String) throws -> AppDownloadRelease {
      try AppDownloadRelease(
        data: JSONSerialization.data(withJSONObject: record),
        source: .homebrew("example"), platform: platform)
    }
    XCTAssertEqual(try release("arm64_tahoe").url.lastPathComponent, "arm64.dmg")
    XCTAssertEqual(try release("tahoe").url.lastPathComponent, "intel.dmg")
    XCTAssertEqual(try release("tahoe").sha256, String(repeating: "b", count: 64))
    record["artifacts"] = [["pkg": ["Installer.pkg"]]]
    XCTAssertThrowsError(try release("arm64_tahoe"))
    record["artifacts"] = [["app": ["../Other.app"]]]
    XCTAssertThrowsError(try release("arm64_tahoe"))
    record["artifacts"] = [["app": ["Example.app"]]]
    record["url"] = "http://example.com/update.dmg"
    XCTAssertThrowsError(try release("arm64_tahoe"))
  }

  func testDownloadChecksumRejectsModifiedArchiveAndReplacementRestoresOriginalOnFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let original = directory.appendingPathComponent("Example.app")
    try Data("abc".utf8).write(to: original)
    try AppDownloadUpdateOperation.verifyChecksum(
      of: original,
      expected: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    XCTAssertThrowsError(
      try AppDownloadUpdateOperation.verifyChecksum(
        of: original,
        expected: String(repeating: "0", count: 64)))
    let stage = directory.appendingPathComponent("stage")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try DownloadUpdateOperation.replaceItem(
        at: original, with: stage.appendingPathComponent("missing.app"), backupDirectory: stage))
    XCTAssertEqual(try Data(contentsOf: original), Data("abc".utf8))
    let candidate = stage.appendingPathComponent("Example.app")
    try Data("new".utf8).write(to: candidate)
    try DownloadUpdateOperation.replaceItem(
      at: original, with: candidate, backupDirectory: stage)
    XCTAssertEqual(try Data(contentsOf: original), Data("new".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: stage.appendingPathComponent("original").path))
  }

  func testObsidianPreservesStableAndExistingEarlyAccessChannels() throws {
    let data = Data(
      #"{"minimumVersion":"1.1.9","latestVersion":"1.13.7","downloadUrl":"https://example.com/public.asar.gz","hash":"hash","signature":"signature","beta":{"minimumVersion":"1.1.9","latestVersion":"1.14.4","downloadUrl":"https://example.com/beta.asar.gz","hash":"hash","signature":"signature"}}"#
        .utf8)
    XCTAssertEqual(
      try ObsidianUpdate.release(
        from: data,
        includesEarlyAccess: false
      ).latestVersion, "1.13.7")
    let beta = try ObsidianUpdate.release(
      from: data,
      includesEarlyAccess: true)
    XCTAssertEqual(beta.latestVersion, "1.14.4")
    XCTAssertThrowsError(try ObsidianUpdate.verify(Data("tampered".utf8), release: beta))
  }

  func testCandidateCompatibilityRejectsNewerOSAndWrongArchitecture() throws {
    let directory = try temporaryDirectory()
    func candidate(_ name: String, minimumOS: String, architecture: Int) throws -> URL {
      let url = directory.appendingPathComponent(name + ".app")
      let contents = url.appendingPathComponent("Contents")
      let executable = contents.appendingPathComponent("MacOS/fixture")
      try FileManager.default.createDirectory(
        at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
      let plist: [String: Any] = [
        "CFBundleIdentifier": "test.compatibility." + name, "CFBundleExecutable": "fixture",
        "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": minimumOS,
      ]
      try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
      // A minimal Mach-O header exercises Foundation's real architecture parser.
      var executableData = Data()
      for value: UInt32 in [0xfeed_facf, UInt32(architecture), 0, 2, 0, 0, 0, 0] {
        var word = value.littleEndian
        executableData.append(Data(bytes: &word, count: 4))
      }
      try executableData.write(to: executable)
      return url
    }
    let native = AppDownloadSource.hostArchitecture
    let wrong =
      native == NSBundleExecutableArchitectureARM64
      ? NSBundleExecutableArchitectureX86_64 : NSBundleExecutableArchitectureARM64
    try AppDownloadUpdateOperation.validateCompatibility(
      of: candidate("supported", minimumOS: "13.0", architecture: native))
    XCTAssertThrowsError(
      try AppDownloadUpdateOperation.validateCompatibility(
        of: candidate("future", minimumOS: "99.0", architecture: native)))
    XCTAssertThrowsError(
      try AppDownloadUpdateOperation.validateCompatibility(
        of: candidate("wrong", minimumOS: "13.0", architecture: wrong)))
  }

  func testPayloadReplacementRepairsPartialFilesAndPreservesOtherVersions() throws {
    let directory = try temporaryDirectory()
    let older = directory.appendingPathComponent("obsidian-1.0.0.asar")
    let target = directory.appendingPathComponent("obsidian-2.0.0.asar")
    let candidate = directory.appendingPathComponent("candidate.asar")
    let stage = directory.appendingPathComponent("stage")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    try Data("usable older payload".utf8).write(to: older)
    try Data("partial download".utf8).write(to: target)
    try Data("verified new payload".utf8).write(to: candidate)
    try DownloadUpdateOperation.replaceItem(at: target, with: candidate, backupDirectory: stage)
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "verified new payload")
    XCTAssertEqual(try String(contentsOf: older, encoding: .utf8), "usable older payload")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: stage.appendingPathComponent("original").path))
  }

  func testCancellationStopsPreparationButCannotInterruptCommittedReplacement() async throws {
    for commit in [false, true] {
      let ready = expectation(description: "Operation reached requested phase")
      let done = expectation(description: "Operation finished")
      let gate = AsyncStream<Void>.makeStream()
      let notices = Mutex(0)
      let operation = FixtureDownloadOperation { operation in
        if commit { try operation.beginCommit() }
        ready.fulfill()
        for await _ in gate.stream { break }
        try Task.checkCancellation()
      }
      operation.completionBlock = { done.fulfill() }
      let observer = NotificationCenter.default.addObserver(
        forName: .latestUpdateOperationDidFinish, object: operation, queue: nil
      ) { _ in notices.withLock { $0 += 1 } }
      defer { NotificationCenter.default.removeObserver(observer) }
      let queue = UpdateQueue()
      queue.addOperation(operation)
      await fulfillment(of: [ready], timeout: 2)
      operation.cancel()
      gate.continuation.yield(())
      gate.continuation.finish()
      await fulfillment(of: [done], timeout: 2)
      XCTAssertNil(operation.error)
      XCTAssertEqual(operation.isCancelled, !commit)
      XCTAssertEqual(notices.withLock { $0 }, commit ? 1 : 0)
    }
  }

  @MainActor
  func testCancellationDuringQuitWaitsForTerminationAndReopensWithoutInstalling() async {
    let requested = expectation(description: "Quit requested")
    let reopened = expectation(description: "App reopened after delayed termination")
    let terminated = Mutex(false)
    let task = Task {
      do {
        try await ApplicationQuitLifecycle.run(
          terminate: { requested.fulfill() },
          isTerminated: { terminated.withLock { $0 } },
          reopen: { reopened.fulfill() },
          install: { XCTFail("Cancelled update must not install") })
        XCTFail("Expected cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
    await fulfillment(of: [requested], timeout: 2)
    task.cancel()
    terminated.withLock { $0 = true }
    await task.value
    await fulfillment(of: [reopened], timeout: 2)

    // Cancellation accepted while confirmation is open must not issue quit.
    let cancelled = Task {
      do {
        try await ApplicationQuitLifecycle.run(
          terminate: { XCTFail("Already cancelled update must not quit") },
          isTerminated: { false },
          reopen: { XCTFail("App was never quit") },
          install: { XCTFail("Already cancelled update must not install") })
        XCTFail("Expected cancellation")
      } catch { XCTAssertTrue(error is CancellationError) }
    }
    cancelled.cancel()
    await cancelled.value
  }

  func testCancellationNeverHidesRecoveryErrors() async throws {
    let ready = expectation(description: "Operation started")
    let done = expectation(description: "Operation finished")
    let gate = AsyncStream<Void>.makeStream()
    let operation = FixtureDownloadOperation { _ in
      ready.fulfill()
      for await _ in gate.stream { break }
      throw AppDownloadError.replacementFailed("Recover the original at the backup path.")
    }
    operation.completionBlock = { done.fulfill() }
    let queue = UpdateQueue()
    queue.addOperation(operation)
    await fulfillment(of: [ready], timeout: 2)
    operation.cancel()
    gate.continuation.finish()
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(
      operation.error?.localizedDescription, "Recover the original at the backup path.")
    guard case .error = operation.progressState else {
      return XCTFail("Recovery instructions must remain visible")
    }
  }

  func testInstallerCommandsHonorTimeoutAndAllowCleanupAfterCancellation() async throws {
    do {
      _ = try await InstallerCommand.run("/bin/sleep", ["10"], timeout: .milliseconds(50))
      XCTFail("A timed-out process must fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("timed out"))
    }
    let cleanup = Task {
      try await InstallerCommand.run("/usr/bin/printf", ["cleaned"], cancellable: false)
    }
    cleanup.cancel()
    let result = try await cleanup.value
    XCTAssertEqual(result, "cleaned")
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    return directory
  }
}

private final class FixtureDownloadOperation: DownloadUpdateOperation, @unchecked Sendable {
  private let action: @Sendable (DownloadUpdateOperation) async throws -> Void

  init(action: @escaping @Sendable (DownloadUpdateOperation) async throws -> Void) {
    self.action = action
    super.init(
      app: App.Bundle(
        version: Version(versionNumber: "1.0", buildNumber: nil), name: "Fixture",
        bundleIdentifier: "test.download", fileURL: URL(fileURLWithPath: "/tmp/Fixture.app"),
        source: .none))
  }

  override func performUpdate() async throws { try await action(self) }
}

/// A gated HTTP transfer tests Foundation's actual delegate delivery without
/// network access or vendor downloads. The second half waits for the assertion.
private final class StreamingDownloadServer: Sendable {
  let payload = Data(repeating: 0x61, count: 128 * 1_024)
  private let listener: NWListener
  private let queue = DispatchQueue(label: "test.streaming-download")
  private let connection = Mutex<NWConnection?>(nil)

  var url: URL? {
    listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/update.zip") }
  }

  init(knownSize: Bool, ready: XCTestExpectation) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    listener = try NWListener(using: parameters)
    listener.stateUpdateHandler = { state in
      if case .ready = state { ready.fulfill() }
    }
    listener.newConnectionHandler = { [self] incoming in
      connection.withLock { $0 = incoming }
      incoming.start(queue: queue)
      incoming.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [self] _, _, _, error in
        guard error == nil else { return }
        var headers = "HTTP/1.1 200 OK\r\nConnection: close\r\n"
        if knownSize { headers += "Content-Length: \(payload.count * 2)\r\n" }
        incoming.send(
          content: Data((headers + "\r\n").utf8) + payload,
          completion: .contentProcessed { _ in })
      }
    }
    listener.start(queue: queue)
  }

  func complete() {
    guard let incoming = connection.withLock({ $0 }) else { return }
    incoming.send(content: payload, completion: .contentProcessed { _ in incoming.cancel() })
  }

  func stop() {
    listener.cancel()
    listener.newConnectionHandler = nil
    connection.withLock { $0 }?.cancel()
  }
}
