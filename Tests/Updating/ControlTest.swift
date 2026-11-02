// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Darwin
import Sparkle
import Synchronization
import XCTest

@testable import Latest

/// The control socket, the built `updater` CLI and the MCP adapter against a test server on a
/// disposable socket, with fixture apps in a temporary folder. Nothing here starts the real app,
/// updates a real app or touches /Applications (UPDATER_HOME keeps the CLI on the test socket).
@MainActor
final class ControlTest: XCTestCase {
  // MARK: Fixtures

  @MainActor
  private final class Harness {
    let home: URL
    let queue: UpdateQueue
    let updating: AppUpdateService
    let history: UpdateHistoryStore
    var apps = [App]()
    var checking = false
    var initialCheckFinished = true
    var server: ControlServer?
    let service: ControlService

    init(home: URL, historyURL: URL) {
      self.home = home
      history = UpdateHistoryStore(fileURL: historyURL)
      queue = UpdateQueue(history: history)
      updating = AppUpdateService(queue: queue)
      var harness: Harness?
      service = ControlService(
        .init(
          apps: { harness?.apps ?? [] },
          isChecking: { harness?.checking ?? false },
          initialCheckFinished: { harness?.initialCheckFinished ?? false },
          startCheck: { _ in
            harness?.checking = true
            Task { @MainActor in
              try? await Task.sleep(for: .milliseconds(300))
              harness?.checking = false
            }
          },
          updateAllCandidates: {
            UpdateCheckingService.updateAllCandidates(
              from: harness?.apps.filter { $0.updateAvailable } ?? [],
              isUpdating: { harness?.updating.isUpdating($0) ?? false },
              alwaysUsesManualAppStoreUpdates: false)
          },
          updateAll: {
            guard let harness else { return }
            for app in harness.apps where app.updateAvailable && app.capability.isAutomatic {
              harness.updating.update(app, isBulkUpdate: true)
            }
          },
          updating: updating, history: history, readinessWait: .milliseconds(400)))
      harness = self
    }

    var socket: URL { home.appendingPathComponent("control.sock") }

    func start(allowedUID: uid_t = getuid()) throws {
      let service = service
      server = try ControlServer(path: socket, allowedUID: allowedUID) { await service.handle($0) }
    }
  }

  /// Socket paths are limited to 103 bytes, so the home is short, under /tmp.
  private func harness() throws -> Harness {
    let home = URL(fileURLWithPath: "/tmp/updater-ctl-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let harness = Harness(
      home: home, historyURL: try disposableDirectory().appendingPathComponent("history.jsonl"))
    addTeardownBlock { @MainActor in
      harness.server?.stop()
      try? FileManager.default.removeItem(at: home)
    }
    try harness.start()
    return harness
  }

  /// A fixture app at 1.0 whose update rewrites its own Info.plist to 1.1 through the queue.
  private func fixtureApp(
    _ harness: Harness, name: String, lock: String? = nil, gate: AsyncStream<Void>? = nil,
    declinesQuit: Bool = false, log: InstallLog? = nil, handOff: OpenCount? = nil
  ) throws -> App {
    let url = try FixtureApp.make(
      in: try disposableDirectory(), name: name, identifier: "com.example.\(name.lowercased())",
      version: "1.0", signed: false)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: url))
    let queue = harness.queue
    let action: App.Update.Action =
      if let handOff {
        .external(label: "Its Store") { _ in handOff.value.withLock { $0 += 1 } }
      } else {
        .builtIn { _ in
          queue.addOperation(
            FixtureInstall(
              url: url, lock: lock, gate: gate, declinesQuit: declinesQuit, log: log, name: name))
        }
      }
    let update = App.Update(
      app: bundle, remoteVersion: Version(versionNumber: "1.1", buildNumber: nil),
      minimumOSVersion: nil, source: .sparkle, date: nil, releaseNotes: nil, updateAction: action)
    return App(bundle: bundle, update: .success(update), isIgnored: false)
  }

  private func request(
    _ harness: Harness, _ command: String, _ args: [String: String] = [:], caller: String = "test"
  ) async throws -> ControlResponse {
    let socket = harness.socket
    let request = ControlRequest(command: command, args: args, caller: caller)
    return try await Task.detached { try ControlClient.send(request, to: socket, timeout: 10) }
      .value
  }

  private func updateResults(
    _ harness: Harness, _ args: [String: String], caller: String = "test"
  ) async throws -> [[String: JSONValue]] {
    results(try await request(harness, "update", args, caller: caller))
  }

  private func results(_ response: ControlResponse) -> [[String: JSONValue]] {
    (response.data?["results"]?.arrayValue ?? []).compactMap(\.objectValue)
  }

  private func waitForJob(_ harness: Harness, _ id: String) async throws -> [String: JSONValue] {
    for _ in 0..<200 {
      let job = try await request(harness, "status", ["job": id]).data?["job"]?.objectValue ?? [:]
      if let state = job["state"]?.stringValue, !["waiting", "running", "idle"].contains(state) {
        return job
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    XCTFail("job \(id) did not settle")
    return [:]
  }

  // MARK: Socket server

  func testSocketIsOwnerOnlyAndRefusesOtherUsersBadJSONAndOtherVersions() async throws {
    let harness = try harness()
    var info = stat()
    XCTAssertEqual(lstat(harness.socket.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600, "socket is owner-only")
    XCTAssertEqual(lstat(harness.home.path, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o700, "its folder is owner-only")

    func raw(_ text: String) async throws -> ControlResponse {
      let socket = harness.socket
      let line = try await Task.detached {
        try ControlClient.exchange(Data((text + "\n").utf8), with: socket, timeout: 5)
      }.value
      return try JSONDecoder().decode(ControlResponse.self, from: line)
    }
    let malformed = try await raw("{not json")
    XCTAssertEqual(malformed.code, "bad_request")
    XCTAssertEqual(malformed.version, controlProtocolVersion)
    let value1 = try await raw(#"{"id":"1","command":"list"}"#)
    XCTAssertEqual(value1.code, "bad_request", "no version")
    let future = try await raw(#"{"version":99,"id":"1","command":"list"}"#)
    XCTAssertEqual(future.code, "unsupported_version")
    let value2 = try await raw(#"{"version":1,"id":"1","command":"list"}"#)
    XCTAssertEqual(value2.ok, true)
    let value3 = try await request(harness, "explode")
    XCTAssertEqual(value3.code, "unknown_command")

    // A second server on the same live socket is refused; the first keeps answering.
    XCTAssertThrowsError(try ControlServer(path: harness.socket) { _ in .failure("x", "x") }) {
      XCTAssertEqual(($0 as? ControlError)?.code, "already_running")
    }

    // getpeereid: a peer that is not the allowed user gets nothing done.
    harness.server?.stop()
    try harness.start(allowedUID: getuid() + 1)
    let value4 = try await request(harness, "list")
    XCTAssertEqual(value4.code, "forbidden")
  }

  // MARK: Service through the socket

  func testListCheckUpdateStatusAndHistoryGoThroughTheScheduler() async throws {
    let harness = try harness()
    let gate = AsyncStream<Void>.makeStream()
    let app = try fixtureApp(harness, name: "Alpha", gate: gate.stream)
    harness.apps = [app]
    let row = UpdateActionViewModel(app: app, updating: harness.updating)

    let listed = try await request(harness, "list", ["updates": "1"])
    let entry = try XCTUnwrap(listed.data?["apps"]?.arrayValue?.first?.objectValue)
    XCTAssertEqual(entry["installed"], "1.0")
    XCTAssertEqual(entry["available"], "1.1")
    XCTAssertEqual(entry["capability"], "install")

    let checked = try await request(harness, "check", ["refresh": "1"])
    XCTAssertEqual(checked.data?["finished"], .bool(true))
    XCTAssertEqual(checked.data?["updatesAvailable"], .number(1))

    let startedResults = try await updateResults(harness, ["target": app.fileURL.path])
    let started = try XCTUnwrap(startedResults.first)
    XCTAssertEqual(started["status"], "started")
    let id = try XCTUnwrap(started["jobId"]?.stringValue)
    // The window's row observes the same scheduler, so the CLI's job shows there live.
    for _ in 0..<100 where row.presentation == .update {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotEqual(row.presentation, .update, "the window's row shows the CLI's job")
    gate.continuation.finish()
    let job = try await waitForJob(harness, id)
    XCTAssertEqual(job["state"], "updated")
    XCTAssertEqual(job["from"], "1.0")
    XCTAssertEqual(job["to"], "1.1")
    XCTAssertEqual(job["caller"], "test")
    XCTAssertEqual(
      BundleCollector.collectBundle(at: app.fileURL)?.version.versionNumber, "1.1",
      "success is what the disk says")

    let history = try await request(harness, "history", ["limit": "5"])
    XCTAssertEqual(history.data?["entries"]?.arrayValue?.first?.objectValue?["state"], "updated")
    let overview = try await request(harness, "status")
    XCTAssertEqual(overview.data?["jobs"]?.arrayValue?.count, 1)
  }

  func testHandOffsNeedAnExplicitFlagAndDeclinedQuitsReportNeedsQuit() async throws {
    let harness = try harness()
    let opened = OpenCount()
    let store = try fixtureApp(harness, name: "Stored", handOff: opened)
    let declined = try fixtureApp(harness, name: "Busy", declinesQuit: true)
    harness.apps = [store, declined]

    let refusedResults = try await updateResults(harness, ["target": "com.example.stored"])
    let refused = try XCTUnwrap(refusedResults.first)
    XCTAssertEqual(refused["status"], "handOff")
    XCTAssertEqual(refused["label"], "Its Store")
    XCTAssertEqual(
      opened.value.withLock { $0 }, 0, "automation never opens another updater by itself")
    let all = results(
      try await request(harness, "update", ["target": "all", "allow-handoff": "1"]))
    XCTAssertEqual(
      all.first { $0["name"] == "Stored" }?["status"], "handOff", "Update All never hands off")
    XCTAssertEqual(opened.value.withLock { $0 }, 0)
    let allowed = results(
      try await request(harness, "update", ["target": "com.example.stored", "allow-handoff": "1"]))
    XCTAssertEqual(allowed.first?["status"], "handedOff")
    XCTAssertEqual(opened.value.withLock { $0 }, 1)

    let busyJob = try XCTUnwrap(all.first { $0["name"] == "Busy" }?["jobId"]?.stringValue)
    let settled = try await waitForJob(harness, busyJob)
    XCTAssertEqual(settled["state"], "needsQuit")
    XCTAssertEqual(
      BundleCollector.collectBundle(at: declined.fileURL)?.version.versionNumber, "1.0")

    let ambiguous = try fixtureApp(harness, name: "Twin")
    let copy = try fixtureApp(harness, name: "Twin")  // same bundle id, another folder
    harness.apps = [ambiguous, copy]
    let twin = try await request(harness, "update", ["target": "com.example.twin"])
    XCTAssertEqual(twin.code, "ambiguous")
    let missing = try await request(harness, "update", ["target": "com.example.none"])
    XCTAssertEqual(missing.code, "not_found")
  }

  /// House rule: two callers at once. The same target gets one job; two targets sharing a tool
  /// queue instead of overlapping.
  func testConcurrentCallersShareOneJobAndQueueOnASharedTool() async throws {
    let harness = try harness()
    let gate = AsyncStream<Void>.makeStream()
    let log = InstallLog()
    let first = try fixtureApp(
      harness, name: "First", lock: "tool:fake", gate: gate.stream, log: log)
    let second = try fixtureApp(harness, name: "Second", lock: "tool:fake", log: log)
    harness.apps = [first, second]

    // Two clients on their own threads, sending at the same moment.
    let socket = harness.socket
    let callers = ["agent-a", "agent-b"].map { caller in
      let request = ControlRequest(
        command: "update", args: ["target": first.fileURL.path], caller: caller)
      return Task.detached { try ControlClient.send(request, to: socket, timeout: 10) }
    }
    var replies = [ControlResponse]()
    for caller in callers { replies.append(try await caller.value) }
    let both = replies.flatMap { results($0) }
    XCTAssertEqual(
      Set(both.compactMap { $0["jobId"]?.stringValue }).count, 1, "one job for one target")
    XCTAssertEqual(Set(both.compactMap { $0["status"]?.stringValue }), ["started", "inProgress"])

    let queuedResults = try await updateResults(
      harness, ["target": second.fileURL.path], caller: "agent-b")
    let queued = try XCTUnwrap(queuedResults.first)
    XCTAssertEqual(queued["status"], "started")
    XCTAssertEqual(queued["state"], "waiting", "the shared tool is busy, so the job waits")
    gate.continuation.finish()
    let secondJob = try XCTUnwrap(queued["jobId"]?.stringValue)
    let value5 = try await waitForJob(harness, secondJob)
    XCTAssertEqual(value5["state"], "updated")
    let runs = log.entries.withLock { $0 }
    let firstRun = try XCTUnwrap(runs.first { $0.name == "First" })
    let secondRun = try XCTUnwrap(runs.first { $0.name == "Second" })
    XCTAssertLessThanOrEqual(firstRun.end, secondRun.start, "jobs on one tool never overlap")
  }

  /// Retrying a request with the same id acts once and replays the first answer.
  func testRetriedRequestIDsActOnce() async throws {
    let harness = try harness()
    let app = try fixtureApp(harness, name: "Once")
    harness.apps = [app]
    let socket = harness.socket
    let request = ControlRequest(
      id: "retry-1", command: "update", args: ["target": app.fileURL.path])
    let firstReply = try await Task.detached {
      try ControlClient.send(request, to: socket, timeout: 10)
    }.value
    let replay = try await Task.detached {
      try ControlClient.send(request, to: socket, timeout: 10)
    }.value
    XCTAssertEqual(replay.data?["replayed"], .bool(true))
    XCTAssertEqual(results(firstReply).first?["jobId"], results(replay).first?["jobId"])
  }

  // MARK: Sol R5 findings

  /// R5-001: the policy travels with the job. A real App Store job whose gate fails at run
  /// time opens nothing for automation (single app or Update All), but still does for the window.
  func testAutomationJobsNeverOpenTheAppStoreFromInsideTheJob() async throws {
    let harness = try harness()
    let opened = InstallLog()
    let url = try FixtureApp.make(
      in: try disposableDirectory(), name: "Store", identifier: "com.example.store",
      version: "1.0", signed: false)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: url))
    let queue = harness.queue
    let action = App.Update.Action.builtIn { app in
      let operation = AppStoreUpdateOperation(
        bundleIdentifier: app.bundleIdentifier, installURL: app.fileURL,
        appIdentifier: app.identifier, appStoreIdentifier: 1)
      operation.installGate = { _, _ in false }  // another copy appeared: fail closed
      operation.usesVerifiedHelperInstall = true
      operation.prepare = {}
      operation.openURL = { url in
        opened.entries.withLock { $0.append((url.absoluteString, Date(), Date())) }
      }
      queue.addOperation(operation)
    }
    let app = App(
      bundle: bundle,
      update: .success(
        App.Update(
          app: bundle, remoteVersion: Version(versionNumber: "1.1", buildNumber: nil),
          minimumOSVersion: nil, source: .appStore, date: nil, releaseNotes: nil,
          updateAction: action)),
      isIgnored: false)
    harness.apps = [app]
    XCTAssertEqual(app.capability, .install)

    let single = try await updateResults(harness, ["target": url.path])
    let singleJob = try await waitForJob(
      harness, try XCTUnwrap(single.first?["jobId"]?.stringValue))
    XCTAssertEqual(singleJob["state"], "handOff")
    XCTAssertEqual(singleJob["label"], "the App Store")
    let all = try await updateResults(harness, ["target": "all"])
    let allJob = try await waitForJob(harness, try XCTUnwrap(all.first?["jobId"]?.stringValue))
    XCTAssertEqual(allJob["state"], "handOff")
    XCTAssertTrue(opened.entries.withLock { $0 }.isEmpty, "automation opened nothing")

    harness.updating.update(app)  // the window: hand-offs open as before
    for _ in 0..<200 where opened.entries.withLock({ $0 }).isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(opened.entries.withLock { $0.count }, 1)
  }

  /// R5-001: a Sparkle job submitted by automation keeps the policy, so an item that turned
  /// information-only records a hand-off without opening its page.
  func testAutomationSparkleInfoOnlyItemOpensNothing() throws {
    let queue = UpdateQueue()
    queue.isSuspended = true  // the policy is set at submission; Sparkle itself never runs here
    let url = URL(fileURLWithPath: "/tmp/Info-\(UUID().uuidString).app")
    let operation = SparkleUpdateOperation(bundleIdentifier: "test.info", appIdentifier: url)
    ExternalHandOff.$allowed.withValue(false) { queue.submit(operation) }
    XCTAssertFalse(operation.allowsExternalHandOff)
    let item = try XCTUnwrap(
      SUAppcastItem(dictionary: [
        "sparkle:version": "2.0", "sparkle:shortVersionString": "2.0",
        "link": "https://example.com/release",
      ]))
    let opened = InstallLog()
    operation.openURL = { url in
      opened.entries.withLock { $0.append((url.absoluteString, Date(), Date())) }
    }
    operation.handleUpdateFound(item) { _ in }
    XCTAssertEqual(operation.outcomeOverride, .handedOff)
    XCTAssertTrue(opened.entries.withLock { $0 }.isEmpty)
    let gui = SparkleUpdateOperation(bundleIdentifier: "test.info", appIdentifier: url)
    queue.submit(gui)
    XCTAssertTrue(gui.allowsExternalHandOff, "the window's jobs keep opening hand-offs")
    queue.cancelAllOperations()
  }

  /// R5-002: before the first check finishes, commands that need it answer not_ready
  /// (retryable) instead of an empty or stale answer; a running check marks lists.
  func testColdStartAnswersNotReadyThenMarksPartialLists() async throws {
    let harness = try harness()
    harness.initialCheckFinished = false
    let early = try await request(harness, "list")
    XCTAssertEqual(early.code, "not_ready", "nothing discovered yet")
    XCTAssertEqual(early.data?["retryable"], .bool(true))
    harness.apps = [try fixtureApp(harness, name: "Cold")]
    let names = try await request(harness, "list")
    XCTAssertEqual(names.ok, true, "names are fine once discovery has run")
    let versions = try await request(harness, "list", ["updates": "1"])
    XCTAssertEqual(versions.code, "not_ready", "versions need the first check")
    let update = try await request(harness, "update", ["target": "all"])
    XCTAssertEqual(update.code, "not_ready")
    harness.initialCheckFinished = true
    harness.checking = true
    let partial = try await request(harness, "list", ["updates": "1"])
    XCTAssertEqual(partial.data?["checking"], .bool(true))
  }

  /// R5-003: a job the window started is resolvable by the id `list` shows.
  func testWindowStartedJobsResolveByID() async throws {
    let harness = try harness()
    let gate = AsyncStream<Void>.makeStream()
    let app = try fixtureApp(harness, name: "Gui", gate: gate.stream)
    harness.apps = [app]
    harness.updating.update(app)
    let listed = try await request(harness, "list")
    let id = try XCTUnwrap(
      listed.data?["apps"]?.arrayValue?.first?.objectValue?["jobId"]?.stringValue)
    let running = try await request(harness, "status", ["job": id])
    XCTAssertNotNil(running.data?["job"]?.objectValue?["state"])
    gate.continuation.finish()
    let finished = try await waitForJob(harness, id)
    XCTAssertEqual(finished["state"], "updated")
  }

  /// R5-004: a real App Store job whose quit prompt is declined reports needsQuit and writes
  /// no history; the real Sparkle path marks the decline too.
  func testDeclinedQuitInRealOperationsIsNeedsQuit() async throws {
    let harness = try harness()
    let url = try FixtureApp.make(
      in: try disposableDirectory(), name: "Busy", identifier: "com.example.busy",
      version: "1.0", signed: false)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: url))
    let declining = AppLifecycle(
      runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
      confirmQuit: { _ in false }, reopen: { _ in })
    let queue = harness.queue
    let action = App.Update.Action.builtIn { app in
      let operation = AppStoreUpdateOperation(
        bundleIdentifier: app.bundleIdentifier, installURL: app.fileURL,
        appIdentifier: app.identifier, appStoreIdentifier: 1)
      operation.installGate = { _, _ in true }
      operation.usesVerifiedHelperInstall = true
      operation.prepare = {}
      operation.openURL = { _ in }
      operation.lifecycle = declining
      queue.addOperation(operation)
    }
    harness.apps = [
      App(
        bundle: bundle,
        update: .success(
          App.Update(
            app: bundle, remoteVersion: Version(versionNumber: "1.1", buildNumber: nil),
            minimumOSVersion: nil, source: .appStore, date: nil, releaseNotes: nil,
            updateAction: action)),
        isIgnored: false)
    ]
    let started = try await updateResults(harness, ["target": url.path])
    let job = try await waitForJob(harness, try XCTUnwrap(started.first?["jobId"]?.stringValue))
    XCTAssertEqual(job["state"], "needsQuit")
    XCTAssertNil(harness.history.latestEntry(for: url), "a declined quit writes no history")

    let sparkle = SparkleUpdateOperation(bundleIdentifier: "test.busy", appIdentifier: url)
    sparkle.lifecycle = declining
    let replied = expectation(description: "replied")
    sparkle.showReady { _ in replied.fulfill() }
    await fulfillment(of: [replied], timeout: 3)
    XCTAssertTrue(sparkle.quitDeclined)
    XCTAssertTrue(sparkle.isCancelled, "a cancel, so nothing is recorded")
  }

  /// R5-005: availability Updater cannot see is reported as unknown, never as the installed
  /// version, and the source is the route Updater chose.
  func testUnknownAvailabilityAndSelectedSourceAreReported() async throws {
    let harness = try harness()
    let url = try FixtureApp.make(
      in: try disposableDirectory(), name: "Premiere", identifier: "com.adobe.premiere",
      version: "25.0", signed: false)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: url))
    harness.apps = [
      App(
        bundle: bundle,
        update: .success(
          App.Update(
            app: bundle, remoteVersion: bundle.version, minimumOSVersion: nil, source: .vendor,
            date: nil, releaseNotes: nil, updateAction: .external(label: "Creative Cloud") { _ in },
            availabilityUnknown: true)),
        isIgnored: false)
    ]
    let listed = try await request(harness, "list", ["updates": "1"])
    let entry = try XCTUnwrap(listed.data?["apps"]?.arrayValue?.first?.objectValue)
    XCTAssertEqual(entry["availability"], "unknown")
    XCTAssertNil(entry["available"], "no invented version")
    XCTAssertEqual(entry["source"], "vendor")
    XCTAssertEqual(entry["detectedBy"], .string(bundle.source.rawValue))
    let cli = helpers.appendingPathComponent("Helpers/updater")
    let output = try await run(cli, ["list", "--updates"], home: harness.home)
    XCTAssertTrue(output.output.contains("check in Creative Cloud"), output.output)
  }

  // MARK: The built CLI and MCP adapter

  private var helpers: URL { Bundle.main.bundleURL.appendingPathComponent("Contents") }

  private func run(_ executable: URL, _ arguments: [String], home: URL, input: String? = nil)
    async throws -> (status: Int32, output: String)
  {
    try await Task.detached {
      let process = Process()
      process.executableURL = executable
      process.arguments = arguments
      var environment = ProcessInfo.processInfo.environment
      environment["UPDATER_HOME"] = home.path
      environment["UPDATER_CLI"] =
        executable.deletingLastPathComponent()
        .appendingPathComponent("updater").path
      process.environment = environment
      let output = Pipe()
      process.standardOutput = output
      let stdin = Pipe()
      process.standardInput = stdin
      try process.run()
      if let input { stdin.fileHandleForWriting.write(Data(input.utf8)) }
      try? stdin.fileHandleForWriting.close()
      let data = output.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }.value
  }

  func testBuiltCLIDrivesTheTestInstance() async throws {
    let harness = try harness()
    let app = try fixtureApp(harness, name: "Cli")
    harness.apps = [app]
    let cli = helpers.appendingPathComponent("Helpers/updater")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: cli.path), "the CLI ships in the bundle")

    let list = try await run(cli, ["list", "--updates"], home: harness.home)
    XCTAssertEqual(list.status, 0)
    XCTAssertTrue(list.output.contains("Cli  1.0 → 1.1"), list.output)

    let update = try await run(cli, ["update", app.fileURL.path, "--json"], home: harness.home)
    let reply = try JSONDecoder().decode(ControlResponse.self, from: Data(update.output.utf8))
    let id = try XCTUnwrap(results(reply).first?["jobId"]?.stringValue)
    _ = try await waitForJob(harness, id)
    let status = try await run(cli, ["status", id], home: harness.home)
    XCTAssertTrue(status.output.contains("updated"), status.output)
    let history = try await run(cli, ["history", "--limit", "1"], home: harness.home)
    XCTAssertTrue(history.output.contains("1.0 → 1.1"), history.output)

    let value6 = try await run(cli, ["update"], home: harness.home)
    XCTAssertEqual(value6.status, 2, "usage error")
    harness.server?.stop()
    let closed = try await run(cli, ["list"], home: harness.home)
    XCTAssertEqual(closed.status, 3, "a test home never starts the real app")
  }

  func testMCPToolsCallTheSameSocket() async throws {
    let candidates =
      (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
      + ["/opt/homebrew/bin", "/usr/local/bin"]
      + ((try? FileManager.default.contentsOfDirectory(
        atPath: NSHomeDirectory() + "/.local/opt")) ?? []).map {
        NSHomeDirectory() + "/.local/opt/\($0)/bin"
      }
    guard
      let node = candidates.map({ URL(fileURLWithPath: $0).appendingPathComponent("node") })
        .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    else { throw XCTSkip("Node.js is not installed; the MCP adapter needs it.") }
    let harness = try harness()
    let app = try fixtureApp(harness, name: "Mcp")
    harness.apps = [app]
    let adapter = helpers.appendingPathComponent("Resources/mcp/updater-mcp.mjs")
    let messages = [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#,
      #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
      #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list","arguments":{"updates":true}}}"#,
      #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"update","arguments":{"target":"com.example.mcp"}}}"#,
      #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"update","arguments":{"nope":1}}}"#,
    ]
    // The adapter answers each line as it comes; closing stdin ends it once replies are written.
    let output = try await Task.detached {
      let process = Process()
      process.executableURL = node
      process.arguments = [adapter.path]
      var environment = ProcessInfo.processInfo.environment
      environment["UPDATER_HOME"] = harness.home.path
      environment["UPDATER_CLI"] =
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/updater").path
      process.environment = environment
      let stdout = Pipe()
      let stdin = Pipe()
      process.standardOutput = stdout
      process.standardInput = stdin
      try process.run()
      for message in messages { stdin.fileHandleForWriting.write(Data((message + "\n").utf8)) }
      var text = ""
      let deadline = Date().addingTimeInterval(20)
      while text.split(separator: "\n").count < messages.count, Date() < deadline {
        text += String(decoding: stdout.fileHandleForReading.availableData, as: UTF8.self)
      }
      process.terminate()
      return text
    }.value
    let replies = output.split(separator: "\n").compactMap {
      try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
    }
    func reply(_ id: Int) -> [String: Any]? { replies.first { $0["id"] as? Int == id } }
    let tools = ((reply(2)?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap
    {
      $0["name"] as? String
    }
    XCTAssertEqual(tools, ["list", "check", "update", "status", "history"])
    func text(_ id: Int) -> String {
      (((reply(id)?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"]
        as? String) ?? ""
    }
    XCTAssertTrue(text(3).contains(#""available":"1.1""#), text(3))
    XCTAssertTrue(text(4).contains(#""status":"started""#), text(4))
    XCTAssertTrue(text(4).contains(#""version":1"#))
    XCTAssertNotNil(reply(5)?["error"], "unknown arguments are refused before the CLI runs")
  }
}

/// A fixture install that writes 1.1 into the bundle's Info.plist, optionally after a gate,
/// on a shared lock, or ending like a declined quit prompt (cancel, then finish cleanly).
final class FixtureInstall: UpdateOperation, @unchecked Sendable {
  private let url: URL
  private let lock: String?
  private let gate: AsyncStream<Void>?
  private let declinesQuit: Bool
  private let log: InstallLog?
  private let label: String
  override var lockKey: String { lock ?? super.lockKey }

  init(
    url: URL, lock: String?, gate: AsyncStream<Void>?, declinesQuit: Bool, log: InstallLog?,
    name: String
  ) {
    self.url = url
    self.lock = lock
    self.gate = gate
    self.declinesQuit = declinesQuit
    self.log = log
    self.label = name
    super.init(bundleIdentifier: "com.example.fixture", appIdentifier: url)
  }

  override func execute() {
    super.execute()
    Task.detached { [self] in
      let start = Date()
      if let gate { for await _ in gate {} }
      if declinesQuit {
        declineQuit()
        return finish()
      }
      progressState = .installing
      let plist = url.appendingPathComponent("Contents/Info.plist")
      if var info =
        (try? PropertyListSerialization.propertyList(
          from: Data(contentsOf: plist), format: nil)) as? [String: Any]
      {
        info["CFBundleShortVersionString"] = "1.1"
        info["CFBundleVersion"] = "1.1"
        try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
          .write(to: plist)
      }
      log?.entries.withLock { $0.append((name: label, start: start, end: Date())) }
      finish()
    }
  }
}

final class OpenCount: Sendable {
  let value = Mutex(0)
}

final class InstallLog: Sendable {
  let entries = Mutex<[(name: String, start: Date, end: Date)]>([])
}
