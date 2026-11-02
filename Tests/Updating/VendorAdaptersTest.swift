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
      --config) printf '\r\033[2K\rChecking configuration...\r\033[2K\r'; cat "$dir/config.plist" ;;
      --list)
        printf '\r\033[2K\rChecking for updates...\r\033[2K\r'
        if [ -f "$dir/list.plist" ]; then cat "$dir/list.plist"; else printf 'No updates available\r\n'; fi ;;
      --install|--wake)
        [ -f "$dir/delay" ] && sleep "$(cat "$dir/delay")"
        target="$(cat "$dir/target")"
        rm -rf "$target" && /usr/bin/ditto "$dir/payload" "$target"
        printf 'Update Assistant: Installing\r\n'
        if [ -f "$dir/fail" ]; then echo "Error: install failed"; status=1
        elif [ -f "$dir/busy" ]; then :
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
    let registered = MicrosoftAutoUpdate.parseRegistered(
      MicrosoftAutoUpdate.plistValue(in: try fixture("msupdate-config-recorded.txt")))
    XCTAssertEqual(
      registered[Homebrew.canonical(URL(fileURLWithPath: "/Applications/Microsoft Teams.app"))],
      "TEAMS21")
    XCTAssertNil(registered["/Applications/Microsoft Word.app"])
    XCTAssertNil(MicrosoftAutoUpdate.plistValue(in: try fixture("msupdate-list-none-recorded.txt")))
    let list: [[String: Any]] = [["Application ID": "TEAMS21", "Update Version": "26300.1.1.1"]]
    XCTAssertEqual(MicrosoftAutoUpdate.parseUpdates(list), ["TEAMS21": "26300.1.1.1"])
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
      inScope: { await microsoft.appID(for: target, fresh: true) == appID },
      install: { try await microsoft.install(appID) })
    operation.lifecycle = lifecycle
    operation.requiresTeam = false
    return operation
  }

  private func run(_ operation: VendorToolOperation, history: UpdateHistoryStore, app: URL)
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
    let vendors = VendorAdapters(microsoft: setup.microsoft)
    let update = await vendors.update(for: bundle)
    let app = App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
    XCTAssertEqual(app.capability, .vendorTool)
    XCTAssertTrue(app.updateAvailable)
    XCTAssertTrue(app.capability.isAutomatic, "included in Update All")
    // An App Store copy is not registered with MAU: no vendor route.
    let other = try FixtureApp.make(in: setup.root.appendingPathComponent("MAS"), version: "1.0")
    let unregistered = await vendors.update(
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

  /// MAU returning while its assistant is still busy: the outcome is unknown, nothing is
  /// restored, and the original is kept aside.
  func testMicrosoftStillWorkingKeepsTheOriginalAside() async throws {
    let setup = try microsoftSetup()
    try setup.tool.flag("busy")
    let operation = try msupdateJob(setup)
    _ = try await run(operation, history: setup.history, app: setup.app)
    guard case ReplacementError.outcomeUnknown(let kept)? = operation.error else {
      return XCTFail("Expected outcome-unknown, got \(String(describing: operation.error))")
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: kept))
    XCTAssertEqual(
      BundleCollector.collectBundle(at: setup.app)?.version.versionNumber, "1.1", "not restored")
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: kept).deletingLastPathComponent())
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

  func testChromeUpdatesThroughGoogleUpdaterOnlyWhenTheUserOwnsIt() async throws {
    let root = try disposableDirectory()
    let chrome = try FixtureApp.make(
      in: root.appendingPathComponent("Apps"), name: "Google Chrome",
      identifier: GoogleChrome.bundleIdentifier, version: "1.0")
    let tool = try FakeVendorTool(in: root, named: "GoogleUpdater")
    try tool.stage(
      payload: try FixtureApp.make(
        in: root.appendingPathComponent("payload"), name: "Google Chrome",
        identifier: GoogleChrome.bundleIdentifier, version: "1.1"),
      target: chrome)
    let google = GoogleChrome(
      updater: tool.tool,
      releases: { Data(#"{"releases":[{"version":"1.1","fraction":1}]}"#.utf8) },
      logDirectory: root.appendingPathComponent("logs"))
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: chrome))
    let update = await VendorAdapters(google: google).update(for: bundle)
    let app = App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
    XCTAssertEqual(app.capability, .vendorTool)
    XCTAssertTrue(app.updateAvailable)

    // A Chrome owned by another account (here a root-owned system app) hands off.
    let systemApp = URL(fileURLWithPath: "/System/Applications/Calculator.app")
    let notOwned = await google.canUpdate(systemApp)
    XCTAssertFalse(notOwned)

    // The job: quit Chrome, run --wake, verify on disk, reopen Chrome after.
    let target = FakeTarget(running: true)
    let operation = VendorToolOperation(
      app: bundle, lock: "googleUpdater", expectedVersion: nil,
      inScope: { await google.canUpdate(chrome) }, install: { try await google.install() })
    operation.lifecycle = target.lifecycle()
    operation.requiresTeam = false
    let history = UpdateHistoryStore(fileURL: root.appendingPathComponent("history.jsonl"))
    let outcome = try await run(operation, history: history, app: chrome)
    XCTAssertEqual(outcome, .updated(from: "1.0", to: "1.1"))
    XCTAssertTrue(tool.calls().contains { $0.arguments == "--wake" })
    XCTAssertEqual(target.quits.withLock { $0 }, 1)
    for _ in 0..<100 where target.reopens.withLock({ $0 }) == 0 {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(target.reopens.withLock { $0 }, 1, "Chrome reopened after the verified update")
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

  func testAdobeRouteIsAHandOffAndNotAnUpdateClaim() async throws {
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
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: photoshop))
    let update = await VendorAdapters(adobe: AdobeCreativeCloud(database: database, app: ccApp))
      .update(for: bundle)
    let app = App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
    XCTAssertEqual(app.capability, .handOff)
    XCTAssertEqual(app.externalUpdaterName, "Creative Cloud")
    XCTAssertFalse(app.updateAvailable, "no version is invented")
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
      bundle, repository: nil, homebrew: nil, vendors: VendorAdapters(microsoft: setup.microsoft))
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
      let update = await vendors.update(for: bundle)
      let app = App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
      print(
        "LIVE \(bundle.name) \(bundle.version.versionNumber ?? "?") → route: \(update == nil ? "not a vendor app" : "\(app.capability)") remote: \(app.remoteVersion?.versionNumber ?? "-") available: \(app.updateAvailable) label: \(app.externalUpdaterName ?? "Update")"
      )
    }
  }
}
