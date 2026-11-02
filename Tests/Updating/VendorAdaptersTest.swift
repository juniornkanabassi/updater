// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

/// A stand-in for msupdate and GoogleUpdater on an injected path. Real vendor tools are never
/// asked to install anything in tests.
private struct FakeVendorTool {
  let directory: URL
  let tool: URL

  init(in root: URL, named name: String) throws {
    directory = root.appendingPathComponent("\(name)-data")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    tool = root.appendingPathComponent(name)
    try #"""
    #!/bin/bash
    dir="$(dirname "$0")/$(basename "$0")-data"
    now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
    start=$(now)
    status=0
    case "$1" in
      --config)
        [ -f "$dir/slow" ] && sleep 5
        printf '\r\033[2K\rChecking configuration...\r\033[2K\r'
        if [ -f "$dir/garbage" ]; then echo "garbage"; else cat "$dir/config.plist"; fi ;;
      --list)
        printf '\r\033[2K\rChecking for updates...\r\033[2K\r'
        if [ "$2" != "--format" ]; then
          printf 'Update Assistant: %s\r\n' "$(cat "$dir/assistant" 2>/dev/null || echo Idle)"
        elif [ -f "$dir/list.plist" ]; then cat "$dir/list.plist"
        else printf 'No updates available\r\nUpdate Assistant: Idle\r\n'; fi ;;
      --install|--wake)
        [ -f "$dir/delay" ] && sleep "$(cat "$dir/delay")"
        target="$(cat "$dir/target")"
        rm -rf "$target" && /usr/bin/ditto "$dir/payload" "$target"
        printf 'Update Assistant: Installing\r\n'
        if [ -f "$dir/fail" ]; then echo "Error: install failed"; status=1
        elif [ -f "$dir/assistant" ]; then :
        else printf 'Update Assistant: Idle\r\n'; fi ;;
      *) echo "unexpected $*"; status=2 ;;
    esac
    echo "$start $(now) $*" >> "$dir/calls.log"
    exit $status
    """#.write(to: tool, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
  }

  func register(_ apps: [URL: String], updates: [String: String]) throws {
    let config: [String: Any] = [
      "RegisteredApplications": Dictionary(
        uniqueKeysWithValues: apps.map {
          ($0.key.path, ["Application ID": $0.value, "LCID": "1033"])
        })
    ]
    try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
      .write(to: directory.appendingPathComponent("config.plist"))
    let list = updates.map {
      ["Application ID": $0.key, "Update Version": $0.value, "Title": "Update"]
    }
    if !list.isEmpty {
      try PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0)
        .write(to: directory.appendingPathComponent("list.plist"))
    }
  }

  func stage(payload: URL, target: URL) throws {
    try? FileManager.default.removeItem(at: directory.appendingPathComponent("payload"))
    try FileManager.default.copyItem(at: payload, to: directory.appendingPathComponent("payload"))
    try target.path.write(
      to: directory.appendingPathComponent("target"), atomically: true, encoding: .utf8)
  }

  func flag(_ name: String, _ contents: String = "") throws {
    try contents.write(
      to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  func calls() -> [(start: Double, end: Double, arguments: String)] {
    ((try? String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)) ?? "")
      .split(separator: "\n").map { line in
        let parts = line.split(separator: " ", maxSplits: 2)
        return (Double(parts[0])!, Double(parts[1])!, String(parts[2]))
      }
  }
}

final class VendorAdaptersTest: XCTestCase {
  private func fixture(_ name: String) throws -> Data {
    try Data(
      contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)"))
  }

  // MARK: - Microsoft

  /// Parsing MAU output recorded read-only on Junior's Mac: Teams is the only registered
  /// Office-family app (Word, Excel, PowerPoint and Outlook are App Store copies), and with
  /// nothing pending `--list` prints no plist.
  func testParsesRecordedMicrosoftAutoUpdateOutput() throws {
    let registered = try XCTUnwrap(
      MicrosoftAutoUpdate.parseRegistered(
        MicrosoftAutoUpdate.plistValue(in: try fixture("msupdate-config-recorded.txt"))))
    XCTAssertEqual(
      registered[Homebrew.canonical(URL(fileURLWithPath: "/Applications/Microsoft Teams.app"))],
      "TEAMS21")
    XCTAssertNil(registered["/Applications/Microsoft Word.app"])
    // "No updates available" is an answer, not a failure (Sol R3-005).
    XCTAssertEqual(
      MicrosoftAutoUpdate.parseList(
        String(decoding: try fixture("msupdate-list-none-recorded.txt"), as: UTF8.self)), [:])
    XCTAssertEqual(
      MicrosoftAutoUpdate.assistantState(
        in: String(decoding: try fixture("msupdate-list-none-recorded.txt"), as: UTF8.self)), "Idle"
    )
    let list: [[String: Any]] = [["Application ID": "TEAMS21", "Update Version": "26300.1.1.1"]]
    let xml = String(
      decoding: try PropertyListSerialization.data(
        fromPropertyList: list, format: .xml, options: 0),
      as: UTF8.self)
    XCTAssertEqual(MicrosoftAutoUpdate.parseList("Checking...\r" + xml), ["TEAMS21": "26300.1.1.1"])
    XCTAssertNil(MicrosoftAutoUpdate.parseList("garbage"), "unreadable is not 'no update'")
    XCTAssertNil(MicrosoftAutoUpdate.parseRegistered(nil))
  }

  private struct MicrosoftSetup {
    let root: URL
    let app: URL
    let tool: FakeVendorTool
    let microsoft: MicrosoftAutoUpdate
    let history: UpdateHistoryStore
  }

  private func microsoftSetup(payloadVersion: String = "1.1") throws -> MicrosoftSetup {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root.appendingPathComponent("Apps"), version: "1.0")
    let tool = try FakeVendorTool(in: root, named: "msupdate")
    try tool.register([app: "FIXTURE01"], updates: ["FIXTURE01": "1.1"])
    try tool.stage(
      payload: try FixtureApp.make(
        in: root.appendingPathComponent("payload"), version: payloadVersion),
      target: app)
    return MicrosoftSetup(
      root: root, app: app, tool: tool,
      microsoft: MicrosoftAutoUpdate(
        tool: tool.tool, logDirectory: root.appendingPathComponent("logs")),
      history: UpdateHistoryStore(fileURL: root.appendingPathComponent("history.jsonl")))
  }

  /// The same operation the production action schedules, on the injected tool.
  private func msupdateJob(
    _ setup: MicrosoftSetup, app: URL? = nil, appID: String = "FIXTURE01",
    lifecycle: AppLifecycle = .notRunning
  ) throws -> VendorToolOperation {
    let target = app ?? setup.app
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: target))
    let microsoft = setup.microsoft
    let operation = VendorToolOperation(
      app: bundle, lock: "msupdate", expectedVersion: nil,
      inScope: { (try? await microsoft.appID(for: target, fresh: true)) == appID },
      install: { try await microsoft.install(appID) },
      vendorIsIdle: { await microsoft.assistantIsIdle() },
      waitingStatus: "Waiting for Microsoft AutoUpdate to finish")
    operation.pollInterval = .milliseconds(50)
    operation.lifecycle = lifecycle
    operation.requiresTeam = false
    return operation
  }

  private func run(_ operation: UpdateOperation, history: UpdateHistoryStore, app: URL)
    async throws -> UpdateOutcome?
  {
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    UpdateQueue(history: history).submit(operation)
    await fulfillment(of: [done], timeout: 30)
    for _ in 0..<200 where history.latestEntry(for: app) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    return history.latestEntry(for: app)?.outcome
  }

  func testMicrosoftRegisteredAppIsAVendorToolAndUnregisteredCopiesAreNot() async throws {
    let setup = try microsoftSetup()
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.app))
    let vendors = VendorAdapters(microsoft: setup.microsoft, copies: { _ in [] })
    let update = try await vendors.update(for: bundle)
    let app = App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
    XCTAssertEqual(app.capability, .vendorTool)
    XCTAssertTrue(app.updateAvailable)
    XCTAssertTrue(app.capability.isAutomatic, "included in Update All")
    // An App Store copy is not registered with MAU: no vendor route.
    let other = try FixtureApp.make(in: setup.root.appendingPathComponent("MAS"), version: "1.0")
    let unregistered = try await vendors.update(
      for: try XCTUnwrap(BundleCollector.collectBundle(at: other)))
    XCTAssertNil(unregistered)
  }

  func testMicrosoftInstallIsVerifiedOnDiskAndRestoredOnFailure() async throws {
    let success = try microsoftSetup()
    let updated = try await run(
      try msupdateJob(success), history: success.history, app: success.app)
    XCTAssertEqual(updated, .updated(from: "1.0", to: "1.1"))
    XCTAssertTrue(
      success.tool.calls().contains { $0.arguments == "--install --apps FIXTURE01 --wait 3600" })
    let logs = try FileManager.default.contentsOfDirectory(
      atPath: success.root.appendingPathComponent("logs").path)
    XCTAssertTrue(logs.contains { $0.hasPrefix("msupdate-install-FIXTURE01") })

    let failing = try microsoftSetup()
    try failing.tool.flag("fail")
    let before = try FixtureApp.digest(failing.app)
    let failed = try await run(try msupdateJob(failing), history: failing.history, app: failing.app)
    guard case .failed(_, let log)? = failed else {
      return XCTFail("Expected failed, got \(String(describing: failed))")
    }
    XCTAssertNotNil(log)
    XCTAssertEqual(try FixtureApp.digest(failing.app), before, "restored byte-for-byte")

    let downgrade = try microsoftSetup(payloadVersion: "0.9")
    let downgradeBefore = try FixtureApp.digest(downgrade.app)
    _ = try await run(try msupdateJob(downgrade), history: downgrade.history, app: downgrade.app)
    XCTAssertEqual(try FixtureApp.digest(downgrade.app), downgradeBefore)
  }

  /// Sol R3-002: while MAU is busy (exit 0 not idle, or a non-zero exit) the job stays
  /// open, holds its lock and target, shows that it is waiting, and never restores; once
  /// MAU is idle the normal verify or restore runs.
  func testBusyMicrosoftAutoUpdateIsWaitedForBeforeAnyVerdict() async throws {
    for nonZeroExit in [false, true] {
      let setup = try microsoftSetup(payloadVersion: nonZeroExit ? "1.1" : "1.1")
      let before = try FixtureApp.digest(setup.app)
      try setup.tool.flag("assistant", "Installing")
      if nonZeroExit { try setup.tool.flag("fail") }
      let operation = try msupdateJob(setup)
      let queue = UpdateQueue(history: setup.history)
      let done = expectation(description: "finished")
      operation.completionBlock = { done.fulfill() }
      queue.submit(operation)
      for _ in 0..<200 {
        if case .waitingForVendor = operation.progressState { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      try await Task.sleep(for: .milliseconds(300))
      guard case .waitingForVendor(let status) = operation.progressState else {
        return XCTFail("the row shows the job is waiting for MAU")
      }
      XCTAssertEqual(status, "Waiting for Microsoft AutoUpdate to finish")
      XCTAssertFalse(operation.isFinished)
      XCTAssertTrue(queue.contains(setup.app), "the job keeps its lock and target")
      XCTAssertEqual(
        BundleCollector.collectBundle(at: setup.app)?.version.versionNumber, "1.1",
        "nothing restored while MAU is busy")
      try FileManager.default.removeItem(
        at: setup.tool.directory.appendingPathComponent("assistant"))
      await fulfillment(of: [done], timeout: 10)
      if nonZeroExit {
        XCTAssertEqual(try FixtureApp.digest(setup.app), before, "restored once MAU was idle")
        XCTAssertNotNil(operation.error)
      } else {
        XCTAssertNil(operation.error)
        XCTAssertEqual(BundleCollector.collectBundle(at: setup.app)?.version.versionNumber, "1.1")
      }
    }
  }

  /// Sol R3-005/R3-006: unreadable MAU output is a visible failure, not "current"; queries
  /// have a deadline, are shared while in flight, and failures are not cached.
  func testMicrosoftQueriesFailVisiblyAreBoundedAndShared() async throws {
    let setup = try microsoftSetup()
    try setup.tool.flag("garbage")
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.app))
    do {
      _ = try await setup.microsoft.appID(for: setup.app)
      XCTFail("unreadable MAU output must throw")
    } catch {}
    // A Microsoft app outside the App Store gets a check failure on its row.
    let teams = try FixtureApp.make(
      in: setup.root.appendingPathComponent("Teams"), name: "Teams",
      identifier: "com.microsoft.teams2", version: "1.0")
    let teamsBundle = try XCTUnwrap(BundleCollector.collectBundle(at: teams))
    do {
      _ = try await VendorAdapters(microsoft: setup.microsoft, copies: { _ in [] }).update(
        for: teamsBundle)
      XCTFail("the row must show the check failure")
    } catch {}
    // Not cached: once MAU answers again, it is asked again.
    try FileManager.default.removeItem(at: setup.tool.directory.appendingPathComponent("garbage"))
    let recovered = try await setup.microsoft.appID(for: bundle.fileURL)
    XCTAssertEqual(recovered, "FIXTURE01")

    // Deadline: a hung query fails within the limit instead of blocking the check.
    let slow = try microsoftSetup()
    try slow.tool.flag("slow")
    let bounded = MicrosoftAutoUpdate(
      tool: slow.tool.tool, logDirectory: slow.root, queryTimeout: .milliseconds(300))
    let start = ContinuousClock.now
    do {
      _ = try await bounded.appID(for: slow.app)
      XCTFail("expected the deadline to end the query")
    } catch {}
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(4))

    // Coalescing: concurrent checks share one query.
    let shared = try microsoftSetup()
    async let a = shared.microsoft.appID(for: shared.app)
    async let b = shared.microsoft.appID(for: shared.app)
    _ = try await (a, b)
    XCTAssertEqual(shared.tool.calls().filter { $0.arguments.hasPrefix("--config") }.count, 1)
  }

  /// Sol R3-004: invalidation drops the cache, and a lookup that began before it cannot
  /// refill the cache afterwards.
  func testInvalidationBeatsAnOlderInFlightLookup() async throws {
    let calls = Mutex(0)
    let release = AsyncStream<Void>.makeStream()
    let releaseBox = Mutex<AsyncStream<Void>?>(release.stream)
    let google = GoogleChrome(releases: {
      let call = calls.withLock {
        $0 += 1
        return $0
      }
      if call == 1, let stream = releaseBox.withLock({ $0 }) { for await _ in stream {} }
      return Data(#"{"releases":[{"version":"\#(call).0","fraction":1}]}"#.utf8)
    })
    let older = Task { try await google.availableVersion() }
    while calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    await google.invalidate()
    release.continuation.finish()
    _ = try? await older.value
    let fresh = try await google.availableVersion()
    XCTAssertEqual(fresh, "2.0", "the older lookup did not repopulate the cache")

    let setup = try microsoftSetup()
    _ = try await setup.microsoft.appID(for: setup.app)
    await setup.microsoft.invalidate()
    _ = try await setup.microsoft.appID(for: setup.app)
    XCTAssertEqual(setup.tool.calls().filter { $0.arguments.hasPrefix("--config") }.count, 2)
  }

  /// IND-001: an app ID shared by two registered paths (or a second copy on disk) has no
  /// path for `msupdate --install --apps`, so it hands off and no install runs.
  func testAmbiguousMicrosoftRegistrationHandsOffWithoutInstalling() async throws {
    let setup = try microsoftSetup()
    let second = try FixtureApp.make(in: setup.root.appendingPathComponent("Copy"), version: "1.0")
    try setup.tool.register(
      [setup.app: "FIXTURE01", second: "FIXTURE01"], updates: ["FIXTURE01": "1.1"])
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.app))
    let ambiguous = try await setup.microsoft.registration(for: setup.app)
    XCTAssertEqual(ambiguous, .ambiguous("FIXTURE01"))
    let vendors = VendorAdapters(microsoft: setup.microsoft, copies: { _ in [] })
    let update = try await vendors.update(for: bundle)
    XCTAssertEqual(
      App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false).capability,
      .handOff)
    let microsoft = setup.microsoft
    let operation = VendorToolOperation(
      app: bundle, lock: "msupdate", expectedVersion: nil,
      inScope: {
        await VendorAdapters.microsoftScope(
          microsoft, appID: "FIXTURE01", app: bundle.fileURL,
          bundleIdentifier: bundle.bundleIdentifier, copies: { _ in [] })
      },
      install: { try await microsoft.install("FIXTURE01") })
    operation.lifecycle = .notRunning
    operation.requiresTeam = false
    _ = try await run(operation, history: setup.history, app: setup.app)
    XCTAssertEqual(operation.outcomeOverride, .handedOff)
    XCTAssertFalse(setup.tool.calls().contains { $0.arguments.hasPrefix("--install") })

    // A unique registration but another copy on disk: also a hand-off.
    let unique = try microsoftSetup()
    let other = Homebrew.canonical(unique.root.appendingPathComponent("Elsewhere/Fixture.app"))
    let withCopy = try await VendorAdapters(microsoft: unique.microsoft, copies: { _ in [other] })
      .update(for: try XCTUnwrap(BundleCollector.collectBundle(at: unique.app)))
    XCTAssertEqual(
      App(
        bundle: try XCTUnwrap(BundleCollector.collectBundle(at: unique.app)),
        update: withCopy.map { .success($0) }, isIgnored: false
      ).capability, .handOff)
    let scoped = await VendorAdapters.microsoftScope(
      unique.microsoft, appID: "FIXTURE01", app: unique.app,
      bundleIdentifier: FixtureApp.identifier, copies: { _ in [other] })
    XCTAssertFalse(scoped, "rechecked right before the install")
  }

  /// Sol R3-101: the registration and duplicate check runs again after the quit and the
  /// clone, right before msupdate. A duplicate appearing during the quit prompt means a
  /// hand-off, no MAU install, the clone discarded and the app reopened.
  func testScopeIsRecheckedAfterQuitBeforeMsupdate() async throws {
    let setup = try microsoftSetup()
    let second = try FixtureApp.make(in: setup.root.appendingPathComponent("Copy"), version: "1.0")
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.app))
    let microsoft = setup.microsoft
    let tool = setup.tool
    let running = Mutex(true)
    let reopens = Mutex(0)
    let operation = VendorToolOperation(
      app: bundle, lock: "msupdate", expectedVersion: nil,
      inScope: {
        await VendorAdapters.microsoftScope(
          microsoft, appID: "FIXTURE01", app: bundle.fileURL,
          bundleIdentifier: bundle.bundleIdentifier, copies: { _ in [] })
      },
      install: { try await microsoft.install("FIXTURE01") })
    operation.lifecycle = AppLifecycle(
      runningApps: { _ in
        running.withLock { $0 }
          ? [
            .init(
              terminate: { running.withLock { $0 = false } },
              isTerminated: { !running.withLock { $0 } })
          ]
          : []
      },
      confirmQuit: { _ in
        // While the user reads the quit prompt, MAU registers a second copy with the same ID.
        try? tool.register([bundle.fileURL: "FIXTURE01", second: "FIXTURE01"], updates: [:])
        return true
      },
      reopen: { _ in reopens.withLock { $0 += 1 } })
    operation.requiresTeam = false
    let before = try FixtureApp.digest(setup.app)
    _ = try await run(operation, history: setup.history, app: setup.app)
    XCTAssertEqual(operation.outcomeOverride, .handedOff)
    XCTAssertFalse(setup.tool.calls().contains { $0.arguments.hasPrefix("--install") })
    XCTAssertEqual(try FixtureApp.digest(setup.app), before)
    for _ in 0..<100 where reopens.withLock({ $0 }) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(reopens.withLock { $0 }, 1, "the quit app is reopened")
  }

  /// Sol R3-102: a stalled folder walk hits the shared deadline and counts as unsafe: a
  /// hand-off, and no installer runs.
  func testStalledCopyWalkIsUnsafe() async throws {
    let setup = try microsoftSetup()
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.app))
    let stalled: @Sendable (String) throws -> Set<String> = { _ in
      Thread.sleep(forTimeInterval: 2)
      return []
    }
    var vendors = VendorAdapters(microsoft: setup.microsoft, copies: stalled)
    vendors.copiesDeadline = .milliseconds(200)
    let start = ContinuousClock.now
    let update = try await vendors.update(for: bundle)
    XCTAssertLessThan(ContinuousClock.now - start, .seconds(1.5), "answered at the deadline")
    XCTAssertEqual(
      App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false).capability,
      .handOff)
    let microsoft = setup.microsoft
    let operation = VendorToolOperation(
      app: bundle, lock: "msupdate", expectedVersion: nil,
      inScope: {
        await VendorAdapters.microsoftScope(
          microsoft, appID: "FIXTURE01", app: bundle.fileURL,
          bundleIdentifier: bundle.bundleIdentifier, copies: stalled, deadline: .milliseconds(200))
      },
      install: { try await microsoft.install("FIXTURE01") })
    operation.lifecycle = .notRunning
    operation.requiresTeam = false
    _ = try await run(operation, history: setup.history, app: setup.app)
    XCTAssertEqual(operation.outcomeOverride, .handedOff)
    XCTAssertFalse(setup.tool.calls().contains { $0.arguments.hasPrefix("--install") })
  }

  /// Sol R3-103: enqueueing Chrome's relaunch records no hand-off; only the job's own outcome
  /// is recorded, and a declined quit is a cancel that leaves an earlier failure in place.
  @MainActor
  func testChromeRelaunchRecordsOnlyItsOwnOutcome() async throws {
    let root = try disposableDirectory()
    let chrome = try chromeFixture(root)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: chrome))
    let history = UpdateHistoryStore(fileURL: root.appendingPathComponent("history.jsonl"))
    history.record(
      UpdateHistoryEntry(
        before: bundle, after: bundle, outcome: .failed(reason: "earlier failure", logPath: nil)))
    let queue = UpdateQueue(history: history)
    let accept = Mutex(false)
    let done = Mutex(0)
    let lifecycle: AppLifecycle = {
      var lifecycle = AppLifecycle(
        runningApps: { _ in [.init(terminate: {}, isTerminated: { true })] },
        confirmQuit: { _ in accept.withLock { $0 } }, reopen: { _ in })
      lifecycle.launch = { _ in }
      return lifecycle
    }()
    let app = App(
      bundle: bundle,
      update: .success(
        App.Update(
          app: bundle, remoteVersion: Version(versionNumber: "1.1", buildNumber: nil),
          minimumOSVersion: nil, source: .vendor, date: nil, releaseNotes: nil,
          updateAction: .relaunch { target in
            let operation = ChromeRelaunchOperation(app: target)
            operation.lifecycle = lifecycle
            operation.settleTime = .milliseconds(100)
            operation.completionBlock = { done.withLock { $0 += 1 } }
            queue.addOperation(operation)
          })),
      isIgnored: false)
    let service = AppUpdateService(queue: queue)

    service.update(app)  // the user declines the quit prompt
    XCTAssertNotEqual(
      history.latestEntry(for: chrome)?.outcome, .handedOff, "nothing recorded at enqueue")
    for _ in 0..<200 where done.withLock({ $0 }) < 1 {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(
      history.latestEntry(for: chrome)?.outcome, .failed(reason: "earlier failure", logPath: nil),
      "a declined quit records nothing")

    accept.withLock { $0 = true }
    service.update(app)
    for _ in 0..<200 where done.withLock({ $0 }) < 2 {
      try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<100
    where history.latestEntry(for: chrome)?.outcome
      == .failed(reason: "earlier failure", logPath: nil)
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(
      history.latestEntry(for: chrome)?.outcome,
      .noChange(reason: "Chrome hasn't downloaded the update yet."), "the job's own outcome")
  }

  func testRefusedQuitRunsNoVendorTool() async throws {
    let setup = try microsoftSetup()
    let refusing = AppLifecycle(
      runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
      confirmQuit: { _ in true }, reopen: { _ in }, timeout: .milliseconds(150))
    let outcome = try await run(
      try msupdateJob(setup, lifecycle: refusing), history: setup.history, app: setup.app)
    XCTAssertEqual(outcome, .needsQuit)
    XCTAssertFalse(setup.tool.calls().contains { $0.arguments.hasPrefix("--install") })
  }

  func testTwoMsupdateJobsNeverOverlap() async throws {
    let setup = try microsoftSetup()
    let second = try FixtureApp.make(
      in: setup.root.appendingPathComponent("Second"), version: "1.0")
    try setup.tool.register([setup.app: "FIXTURE01", second: "FIXTURE02"], updates: [:])
    try setup.tool.flag("delay", "0.3")
    let queue = UpdateQueue()
    let done = expectation(description: "both")
    done.expectedFulfillmentCount = 2
    for (app, id) in [(setup.app, "FIXTURE01"), (second, "FIXTURE02")] {
      let operation = try msupdateJob(setup, app: app, appID: id)
      operation.completionBlock = { done.fulfill() }
      queue.submit(operation)
    }
    await fulfillment(of: [done], timeout: 30)
    let installs = setup.tool.calls().filter { $0.arguments.hasPrefix("--install") }
      .sorted { $0.start < $1.start }
    XCTAssertEqual(installs.count, 2)
    XCTAssertLessThanOrEqual(installs[0].end, installs[1].start, "msupdate lock")
  }

  // MARK: - Google

  /// Recorded read-only from Google's version-history API: the release served to every Mac
  /// is chosen, not the newest early-rollout build.
  func testChromeAvailabilityIsTheMostServedRelease() throws {
    XCTAssertEqual(
      GoogleChrome.parseServedVersion(try fixture("chrome-versionhistory-recorded.json")),
      "156.0.8078.80")
  }

  private func chromeFixture(_ root: URL, version: String = "1.0", in folder: String = "Apps")
    throws -> URL
  {
    try FixtureApp.make(
      in: root.appendingPathComponent(folder), name: "Google Chrome",
      identifier: GoogleChrome.bundleIdentifier, version: version)
  }

  /// Sol R3-001 / IND-003: Chrome's action is a user-only hand-off that relaunches a running
  /// Chrome (or opens a closed one), never part of Update All.
  @MainActor
  func testChromeActionIsAUserOnlyHandOff() async throws {
    let root = try disposableDirectory()
    let chrome = try chromeFixture(root)
    let google = GoogleChrome(releases: {
      Data(#"{"releases":[{"version":"1.1","fraction":1}]}"#.utf8)
    })
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: chrome))
    let update = try await VendorAdapters(google: google).update(for: bundle)
    let app = App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
    XCTAssertTrue(app.updateAvailable)
    XCTAssertTrue(app.relaunchesToUpdate)
    XCTAssertEqual(app.capability, .handOff)
    XCTAssertFalse(app.capability.isAutomatic, "not part of Update All")
    XCTAssertEqual(SidebarUpdateActionTitle.text(for: app), "Open Google Chrome", "closed Chrome")

    // Update All never runs it; an individual click does.
    let performed = Mutex(0)
    let counted = App(
      bundle: bundle,
      update: .success(
        App.Update(
          app: bundle, remoteVersion: Version(versionNumber: "1.1", buildNumber: nil),
          minimumOSVersion: nil, source: .vendor, date: nil, releaseNotes: nil,
          updateAction: .relaunch { _ in performed.withLock { $0 += 1 } })),
      isIgnored: false)
    let service = AppUpdateService(queue: UpdateQueue())
    service.update(counted, isBulkUpdate: true)
    XCTAssertEqual(performed.withLock { $0 }, 0, "Update All leaves Chrome alone")
    service.update(counted)
    XCTAssertEqual(performed.withLock { $0 }, 1)
  }

  /// IND-002: the launch is awaited and a staged update applied shortly after launch is
  /// caught; a closed Chrome is just opened; a launch failure is a failure, not "no change".
  @MainActor
  func testChromeRelaunchAwaitsLaunchAndWatchesTheVersion() async throws {
    for scenario in ["running, applies late", "closed, nothing staged", "launch fails"] {
      let root = try disposableDirectory()
      let chrome = try chromeFixture(root)
      let staged = try chromeFixture(root, version: "1.1", in: "staged")
      let running = Mutex(scenario.hasPrefix("running"))
      let quits = Mutex(0)
      let launches = Mutex(0)
      let operation = ChromeRelaunchOperation(
        app: try XCTUnwrap(BundleCollector.collectBundle(at: chrome)))
      operation.settleTime = .seconds(3)
      var lifecycle = AppLifecycle(
        runningApps: { _ in
          running.withLock { $0 }
            ? [
              .init(
                terminate: {
                  quits.withLock { $0 += 1 }
                  running.withLock { $0 = false }
                }, isTerminated: { !running.withLock { $0 } })
            ] : []
        },
        confirmQuit: { _ in true }, reopen: { _ in XCTFail("the launch is awaited instead") })
      lifecycle.launch = { url in
        launches.withLock { $0 += 1 }
        if scenario == "launch fails" { throw CocoaError(.fileReadNoPermission) }
        if scenario.hasSuffix("applies late") {
          // Chrome finishes applying its staged update a moment after it launched.
          Task.detached {
            try? await Task.sleep(for: .milliseconds(600))
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.copyItem(at: staged, to: url)
          }
        }
      }
      operation.lifecycle = lifecycle
      let history = UpdateHistoryStore(fileURL: root.appendingPathComponent("history.jsonl"))
      let outcome = try await run(operation, history: history, app: chrome)
      XCTAssertEqual(launches.withLock { $0 }, 1, scenario)
      switch scenario {
      case "running, applies late":
        XCTAssertEqual(quits.withLock { $0 }, 1)
        XCTAssertEqual(outcome, .updated(from: "1.0", to: "1.1"))
      case "closed, nothing staged":
        XCTAssertEqual(quits.withLock { $0 }, 0, "a closed Chrome is only opened")
        XCTAssertEqual(outcome, .noChange(reason: "Chrome hasn't downloaded the update yet."))
      default:
        guard case .failed(let reason, _)? = outcome else {
          return XCTFail("a launch failure is reported, got \(String(describing: outcome))")
        }
        XCTAssertFalse(reason.contains("hasn't downloaded"), reason)
      }
    }
  }

  /// Sol R3-005: an unreadable version list is a check failure, and it is not cached.
  func testChromeVersionFailureIsVisibleAndNotCached() async throws {
    let fail = Mutex(true)
    let google = GoogleChrome(releases: {
      if fail.withLock({ $0 }) { throw URLError(.notConnectedToInternet) }
      return Data(#"{"releases":[{"version":"1.1","fraction":1}]}"#.utf8)
    })
    do {
      _ = try await google.availableVersion()
      XCTFail("expected a failure")
    } catch {}
    fail.withLock { $0 = false }
    let version = try await google.availableVersion()
    XCTAssertEqual(version, "1.1")
  }

  // MARK: - Adobe

  func testAdobeAppsHandOffToCreativeCloudWithoutAnInventedVersion() throws {
    let root = try disposableDirectory()
    let ccApp = root.appendingPathComponent("Adobe Creative Cloud/Adobe Creative Cloud.app")
    try FileManager.default.createDirectory(at: ccApp, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("pim.db")
    try FixtureApp.run(
      "/usr/bin/sqlite3",
      [
        database.path,
        "CREATE TABLE package_installation_info (packageid, version, name, target_location); INSERT INTO package_installation_info VALUES ('1','6.11','Core','/Core/');",
      ])
    let before = try Data(contentsOf: database)
    let adobe = AdobeCreativeCloud(database: database, app: ccApp)
    XCTAssertEqual(adobe.packageCount(), 1)
    XCTAssertEqual(try Data(contentsOf: database), before, "pim.db is never written")
    let photoshop = try FixtureApp.make(
      in: root.appendingPathComponent("Adobe Photoshop 2026"), name: "Adobe Photoshop 2026",
      identifier: "com.adobe.Photoshop", version: "27.9")
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: photoshop))
    XCTAssertTrue(adobe.manages(bundle))
    let missing = AdobeCreativeCloud(database: root.appendingPathComponent("none.db"), app: ccApp)
    XCTAssertFalse(missing.manages(bundle))
  }

  /// Sol R3-003: availability is unknown, the app sits under "Check in Creative Cloud", and
  /// the production button path opens Creative Cloud. No update is claimed.
  @MainActor
  func testAdobeAppsAreAnActionableCreativeCloudCheck() async throws {
    let root = try disposableDirectory()
    let ccApp = root.appendingPathComponent("Adobe Creative Cloud/Adobe Creative Cloud.app")
    try FileManager.default.createDirectory(at: ccApp, withIntermediateDirectories: true)
    let database = root.appendingPathComponent("pim.db")
    try FixtureApp.run(
      "/usr/bin/sqlite3",
      [
        database.path,
        "CREATE TABLE package_installation_info (packageid); INSERT INTO package_installation_info VALUES ('1');",
      ])
    let photoshop = try FixtureApp.make(
      in: root.appendingPathComponent("PS"), name: "Adobe Photoshop 2026",
      identifier: "com.adobe.Photoshop", version: "27.9")
    let opened = Mutex<[URL]>([])
    var adobe = AdobeCreativeCloud(database: database, app: ccApp)
    adobe.open = { url in opened.withLock { $0.append(url) } }
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: photoshop))
    let update = try await VendorAdapters(adobe: adobe).update(for: bundle)
    let app = App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
    XCTAssertTrue(app.availabilityUnknown)
    XCTAssertFalse(app.updateAvailable, "no update is claimed")
    XCTAssertTrue(app.isActionable)
    XCTAssertEqual(app.capability, .handOff)
    XCTAssertEqual(SidebarUpdateActionTitle.text(for: app), "Open Creative Cloud")

    let snapshot = AppListSnapshot(
      withApps: [app], filterQuery: nil, settings: try isolatedAppListSettings(for: self))
    XCTAssertEqual(snapshot.sections.map(\.section.title), ["Check in Creative Cloud"])

    let model = UpdateActionViewModel(app: app, updating: AppUpdateService(queue: UpdateQueue()))
    XCTAssertEqual(model.presentation, .update)
    model.performAction()
    for _ in 0..<100 where opened.withLock({ $0 }).isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(opened.withLock { $0 }, [ccApp], "the button opens Creative Cloud")
  }

  // MARK: - System

  func testSystemRowParsesSoftwareUpdateAndStaysOutOfUpdateAll() async throws {
    XCTAssertNil(
      SystemUpdate.parseMacOSVersion(
        String(decoding: try fixture("softwareupdate-none-recorded.txt"), as: UTF8.self)))
    let available = """
      Software Update Tool

      Finding available software
      Software Update found the following new or updated software:
      * Label: macOS Golden Gate 27.3-27D50
      \tTitle: macOS Golden Gate 27.3, Version: 27.3, Size: 7340032KiB, Recommended: YES, Action: restart,
      """
    XCTAssertEqual(SystemUpdate.parseMacOSVersion(available), "27.3")
    let update = SystemUpdate.update(version: "27.3")
    let row = App(bundle: SystemUpdate.bundle, update: .success(update), isIgnored: false)
    XCTAssertEqual(row.capability, .handOff)
    XCTAssertFalse(row.capability.isAutomatic, "never part of Update All")
    XCTAssertEqual(row.externalUpdaterName, "Software Update")

    // The coordinator adds the row on a full scan when an update exists.
    let coordinator = UpdateCheckCoordinator(
      check: { _, _ in throw LatestError.updateInfoUnavailable }, repositoryProvider: { nil },
      systemUpdate: { update })
    coordinator.updateDiscoveredBundles([])
    let store = try XCTUnwrap(coordinator.appProvider as? AppDataStore)
    for _ in 0..<200
    where !store.apps.contains(where: {
      $0.bundleIdentifier == SystemUpdate.bundle.bundleIdentifier
    }) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(
      store.apps.contains { $0.bundleIdentifier == SystemUpdate.bundle.bundleIdentifier })
  }

  // MARK: - Order

  /// The vendor tool wins over a Homebrew cask that also owns the app.
  func testVendorToolComesBeforeHomebrew() async throws {
    let setup = try microsoftSetup()
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.app))
    let update = try await UpdateCheckCoordinator.check(
      bundle, repository: nil, homebrew: nil,
      vendors: VendorAdapters(microsoft: setup.microsoft, copies: { _ in [] }))
    XCTAssertEqual(
      App(bundle: bundle, update: .success(update), isIgnored: false).capability, .vendorTool)
  }

  // MARK: - Live, read-only

  /// Opt-in: runs the real detection on this Mac, read-only (msupdate --config/--list,
  /// Google's version API, a copy of pim.db). Never installs.
  func testLiveReadOnlyDetection() async throws {
    guard ProcessInfo.processInfo.environment["UPDATER_LIVE_VENDOR_PROBE"] == "1" else {
      throw XCTSkip("Set UPDATER_LIVE_VENDOR_PROBE=1 to probe the real vendor tools read-only.")
    }
    let vendors = VendorAdapters.live
    for path in [
      "/Applications/Microsoft Teams.app", "/Applications/Microsoft Word.app",
      "/Applications/Microsoft Excel.app", "/Applications/Microsoft PowerPoint.app",
      "/Applications/Microsoft Outlook.app", "/Applications/Google Chrome.app",
      "/Applications/Adobe Photoshop 2026/Adobe Photoshop 2026.app",
      "/Applications/Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app",
    ] {
      guard let bundle = BundleCollector.collectBundle(at: URL(fileURLWithPath: path)) else {
        print("LIVE \(path): not found")
        continue
      }
      let update = try await vendors.update(for: bundle)
      let app = App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
      print(
        "LIVE \(bundle.name) \(bundle.version.versionNumber ?? "?") → route: \(update == nil ? "not a vendor app" : "\(app.capability)") remote: \(app.remoteVersion?.versionNumber ?? "-") available: \(app.updateAvailable) label: \(app.externalUpdaterName ?? "Update")"
      )
    }
  }
}
