// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

/// A stand-in for brew on an injected path. It answers `info`/`outdated` from JSON files and
/// performs `upgrade --cask` by staging the cask's payload over its target, the way brew
/// replaces an app artifact. Real brew is never run: it would need a full Homebrew prefix and
/// network access, and could reach the user's real prefix, caches or casks.
private struct BrewStub {
  /// Data the stub reads and writes (flags, payloads, call log).
  let directory: URL
  /// `<prefix>/bin/brew`, so the client finds the Caskroom at `<prefix>/Caskroom`.
  let brew: URL
  let caskroom: URL

  init(in root: URL) throws {
    directory = root.appendingPathComponent("brew-data")
    let bin = root.appendingPathComponent("prefix/bin")
    caskroom = root.appendingPathComponent("prefix/Caskroom")
    for folder in [directory, bin, caskroom] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    brew = bin.appendingPathComponent("brew")
    try #"""
    #!/bin/bash
    dir="$STUB_DIR"
    caskroom="$(cd "$(dirname "$0")/.." && pwd)/Caskroom"
    now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
    start=$(now)
    status=0
    case "$1 $2" in
      "info --cask") cat "$dir/info.json" ;;
      "outdated --cask")
        # Outdated while the Caskroom lacks the current version, as brew decides.
        printf 'Warning: stub warning line\n{"formulae":[],"casks":['
        sep=""
        for f in "$dir"/*.current; do
          [ -f "$f" ] || continue
          t="$(basename "$f" .current)"; v="$(cat "$f")"
          if [ ! -d "$caskroom/$t/$v" ]; then
            printf '%s{"name":"%s","installed_versions":["1.0"],"current_version":"%s"}' "$sep" "$t" "$v"
            sep=","
          fi
        done
        printf ']}\n' ;;
      "fetch --cask")
        [ -f "$dir/fetchdelay" ] && sleep "$(cat "$dir/fetchdelay")"
        touch "$dir/fetched"
        echo "==> Downloading $3" ;;
      "upgrade --cask")
        token="${@: -1}"
        [ -f "$dir/delay" ] && sleep "$(cat "$dir/delay")"
        if [ -f "$dir/$token.sudo" ]; then
          echo "sudo: a terminal is required to read the password"; status=1
        else
          target="$(cat "$dir/$token.target")"
          # .noop: brew reports success and advances its record but leaves the app alone.
          [ -f "$dir/$token.noop" ] || { rm -rf "$target" && /usr/bin/ditto "$dir/$token.payload" "$target"; }
          rm -rf "$caskroom/$token"/* && mkdir -p "$caskroom/$token/$(cat "$dir/$token.current")"
          echo "==> Upgrading $token"
          if [ -f "$dir/$token.fail" ]; then echo "Error: postflight failed"; status=1; fi
        fi ;;
      *) echo "Error: unexpected brew $*"; status=1 ;;
    esac
    echo "$start $(now) $*" >> "$dir/calls.log"
    exit $status
    """#.write(to: brew, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
  }

  /// `casks`: token → installed app target. The current definition (brew info) and the
  /// installed one (the Caskroom receipt) both hold that app and a zap; `current` and
  /// `installed` add artifacts to either side. Each cask gets a Caskroom record for 1.0, and
  /// `outdated` gives the version brew would install.
  func describe(
    _ casks: [String: URL], outdated: [String: String],
    current: [String: [[String: Any]]] = [:], installed: [String: [[String: Any]]] = [:],
    version: [String: String] = [:], flightBlocks: Set<String> = [],
    dependsOn: [String: [String: Any]] = [:], installedAppdir: [String: String] = [:]
  ) throws {
    let zap: [String: Any] = ["zap": [["trash": ["~/Library/Caches/fixture"]]]]
    let info: [String: Any] = [
      "formulae": [],
      "casks": casks.map { token, app in
        [
          "token": token, "version": version[token] ?? "1.1", "installed": "1.0",
          "depends_on": dependsOn[token] ?? [:],
          "artifacts": [["app": [app.lastPathComponent], "target": app.path], zap]
            + (current[token] ?? []),
        ] as [String: Any]
      },
    ]
    try JSONSerialization.data(withJSONObject: info).write(
      to: directory.appendingPathComponent("info.json"))
    for (token, app) in casks {
      let record = caskroom.appendingPathComponent("\(token)/1.0")
      try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
      try Data("installed 1.0".utf8).write(to: record.appendingPathComponent(".metadata"))
      let metadata = caskroom.appendingPathComponent("\(token)/.metadata")
      try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
      let receipt: [String: Any] = [
        "uninstall_flight_blocks": flightBlocks.contains(token),
        "uninstall_artifacts": [["app": [app.lastPathComponent]], zap] + (installed[token] ?? []),
      ]
      try JSONSerialization.data(withJSONObject: receipt).write(
        to: metadata.appendingPathComponent("INSTALL_RECEIPT.json"))
      // The appdir brew installed into: the app's folder unless a test moves it.
      let config: [String: Any] = [
        "default": ["appdir": installedAppdir[token] ?? app.deletingLastPathComponent().path],
        "explicit": [:],
      ]
      try JSONSerialization.data(withJSONObject: config).write(
        to: metadata.appendingPathComponent("config.json"))
    }
    for (token, version) in outdated {
      try version.write(
        to: directory.appendingPathComponent("\(token).current"), atomically: true, encoding: .utf8)
    }
  }

  func stage(_ token: String, payload: URL, target: URL) throws {
    try FileManager.default.copyItem(
      at: payload, to: directory.appendingPathComponent("\(token).payload"))
    try target.path.write(
      to: directory.appendingPathComponent("\(token).target"), atomically: true, encoding: .utf8)
  }

  func flag(_ name: String, _ contents: String = "") throws {
    try contents.write(
      to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }

  func client(logs: URL) -> Homebrew {
    Homebrew(brew: brew, environment: ["STUB_DIR": directory.path], logDirectory: logs)
  }

  /// (start, end) of every brew invocation.
  func calls() throws -> [(start: Double, end: Double, arguments: String)] {
    try String(contentsOf: directory.appendingPathComponent("calls.log"), encoding: .utf8)
      .split(separator: "\n").map { line in
        let parts = line.split(separator: " ", maxSplits: 2)
        return (Double(parts[0])!, Double(parts[1])!, String(parts[2]))
      }
  }
}

final class HomebrewTest: XCTestCase {
  private struct Setup {
    let root: URL
    let installed: URL
    let otherCopy: URL
    let stub: BrewStub
    let homebrew: Homebrew
    let logs: URL
    let history: UpdateHistoryStore
  }

  private func makeSetup(payloadVersion: String = "1.1") throws -> Setup {
    let root = try disposableDirectory()
    let installed = try FixtureApp.make(in: root.appendingPathComponent("Casks A"), version: "1.0")
    let otherCopy = try FixtureApp.make(in: root.appendingPathComponent("Copy B"), version: "1.0")
    let stub = try BrewStub(in: root)
    let payload = try FixtureApp.make(
      in: root.appendingPathComponent("payload"), version: payloadVersion)
    try stub.stage("fixture", payload: payload, target: installed)
    try stub.describe(["fixture": installed], outdated: ["fixture": "1.1"])
    let logs = root.appendingPathComponent("logs")
    return Setup(
      root: root, installed: installed, otherCopy: otherCopy, stub: stub,
      homebrew: stub.client(logs: logs), logs: logs,
      history: UpdateHistoryStore(fileURL: root.appendingPathComponent("history.jsonl")))
  }

  private func upgrade(_ setup: Setup, queue: UpdateQueue? = nil) async throws -> (
    HomebrewUpgradeOperation, UpdateOutcome?
  ) {
    let queue = queue ?? UpdateQueue(history: setup.history)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
    let operation = HomebrewUpgradeOperation(
      app: bundle, token: "fixture",
      expectedVersion: Version(versionNumber: "1.1", buildNumber: nil))
    operation.homebrew = setup.homebrew
    operation.lifecycle = .notRunning
    operation.requiresTeam = false
    let done = expectation(description: "upgrade finished")
    operation.completionBlock = { done.fulfill() }
    queue.submit(operation)
    await fulfillment(of: [done], timeout: 30)
    for _ in 0..<200 where setup.history.latestEntry(for: setup.installed) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    return (operation, setup.history.latestEntry(for: setup.installed)?.outcome)
  }

  func testBrewIsFoundOnlyAtFixedPaths() throws {
    let root = try disposableDirectory()
    let stub = try BrewStub(in: root)
    XCTAssertNil(Homebrew.locate([root.appendingPathComponent("missing").path]))
    XCTAssertEqual(Homebrew.locate(["/nonexistent/brew", stub.brew.path]), stub.brew)
    XCTAssertEqual(
      Homebrew.locate(["/nonexistent/brew"]), nil, "PATH is never consulted")
  }

  /// A cask owns an app only if its installed artifact is exactly this bundle.
  func testOwnershipFollowsTheCanonicalArtifactPath() async throws {
    let setup = try makeSetup()
    let link = setup.root.appendingPathComponent("Linked.app")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: setup.installed)
    let pkgApp = try FixtureApp.make(in: setup.root.appendingPathComponent("Pkg"), version: "1.0")
    try setup.stub.describe(
      ["fixture": setup.installed, "pkgcask": pkgApp],
      outdated: ["fixture": "1.1"], current: ["pkgcask": [["pkg": ["Installer.pkg"]]]])
    let owner = try await setup.homebrew.owningCask(of: setup.installed)
    XCTAssertEqual(owner?.token, "fixture")
    let viaLink = try await setup.homebrew.owningCask(of: link)
    XCTAssertEqual(viaLink?.token, "fixture", "resolved to the canonical path")
    let other = try await setup.homebrew.owningCask(of: setup.otherCopy)
    XCTAssertNil(other, "a copy elsewhere is not owned")
    let pkg = try await setup.homebrew.owningCask(of: pkgApp)
    XCTAssertEqual(pkg?.allowListed, false, "a pkg is outside the allow list")
    let outdated = try await setup.homebrew.outdatedVersion(of: "fixture")
    XCTAssertEqual(outdated, "1.1")
  }

  /// Owned casks become installs; sudo casks hand off; others keep the catalogue route.
  func testCheckerRoutesOwnedCasksToBrew() async throws {
    let setup = try makeSetup()
    let pkgApp = try FixtureApp.make(in: setup.root.appendingPathComponent("Pkg"), version: "1.0")
    try setup.stub.describe(
      ["fixture": setup.installed, "pkgcask": pkgApp],
      outdated: ["fixture": "1.1", "pkgcask": "2.0"],
      current: ["pkgcask": [["pkg": ["Installer.pkg"]]]])
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
    let update = try await HomebrewCheckerOperation(
      with: bundle, repository: nil, homebrew: setup.homebrew
    ).check()
    let app = App(bundle: bundle, update: .success(update), isIgnored: false)
    XCTAssertEqual(app.capability, .install)
    XCTAssertTrue(app.updateAvailable)
    XCTAssertEqual(update.remoteVersion.versionNumber, "1.1")

    let pkgBundle = try XCTUnwrap(BundleCollector.collectBundle(at: pkgApp))
    let pkgUpdate = try await HomebrewCheckerOperation(
      with: pkgBundle, repository: nil, homebrew: setup.homebrew
    ).check()
    let pkg = App(bundle: pkgBundle, update: .success(pkgUpdate), isIgnored: false)
    XCTAssertEqual(pkg.capability, .handOff)
    // Sol R2-005: admin casks hand off with the exact command on the clipboard.
    XCTAssertEqual(pkg.externalUpdaterName, "Terminal (brew command copied)")
    XCTAssertEqual(
      HomebrewCheckerOperation.adminCommand(for: "pkgcask"), "brew upgrade --cask pkgcask")

    let notOwned = try XCTUnwrap(BundleCollector.collectBundle(at: setup.otherCopy))
    do {
      _ = try await HomebrewCheckerOperation(
        with: notOwned, repository: nil, homebrew: setup.homebrew
      ).check()
      XCTFail("an app brew does not own falls through to the catalogue route")
    } catch {}
  }

  /// Proof: 1.0 → 1.1 through brew, the row reads 1.1 from disk, the other copy is untouched,
  /// and the run is logged.
  func testUpgradeInstallsOwnedCaskAndLeavesOtherCopiesAlone() async throws {
    let setup = try makeSetup()
    let otherBefore = try FixtureApp.digest(setup.otherCopy)
    let (operation, outcome) = try await upgrade(setup)
    XCTAssertNil(operation.error)
    XCTAssertEqual(outcome, .updated(from: "1.0", to: "1.1"))
    XCTAssertEqual(BundleCollector.collectBundle(at: setup.installed)?.version.versionNumber, "1.1")
    XCTAssertEqual(try FixtureApp.digest(setup.otherCopy), otherBefore)
    let logs = try FileManager.default.contentsOfDirectory(atPath: setup.logs.path)
    let upgradeLog = try XCTUnwrap(logs.first { $0.hasPrefix("brew-upgrade-fixture") })
    XCTAssertTrue(
      try String(contentsOf: setup.logs.appendingPathComponent(upgradeLog), encoding: .utf8)
        .contains("Upgrading fixture"))
  }

  /// Proof: a non-zero exit after brew changed the app, or a wrong version, restores the
  /// original byte-for-byte and keeps the log path in the failure.
  func testFailedOrWrongUpgradeRestoresTheOriginal() async throws {
    let failing = try makeSetup()
    try failing.stub.flag("fixture.fail")
    let before = try FixtureApp.digest(failing.installed)
    let (_, failed) = try await upgrade(failing)
    guard case .failed(let reason, let log)? = failed else {
      return XCTFail("Expected failed, got \(String(describing: failed))")
    }
    XCTAssertTrue(reason.contains("postflight failed"), reason)
    XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(log)))
    XCTAssertEqual(try FixtureApp.digest(failing.installed), before, "restored byte-for-byte")

    let wrong = try makeSetup(payloadVersion: "1.0.5")
    let wrongBefore = try FixtureApp.digest(wrong.installed)
    let (_, wrongOutcome) = try await upgrade(wrong)
    guard case .failed? = wrongOutcome else {
      return XCTFail("Expected failed, got \(String(describing: wrongOutcome))")
    }
    XCTAssertEqual(try FixtureApp.digest(wrong.installed), wrongBefore)

    let sudo = try makeSetup()
    try sudo.stub.flag("fixture.sudo")
    let (_, sudoOutcome) = try await upgrade(sudo)
    XCTAssertEqual(sudoOutcome, .needsPermission(kind: "administrator"))
  }

  /// Proof: brew invocations, detection included, never overlap; two upgrade jobs wait for
  /// each other through the `homebrew` lock.
  func testBrewInvocationsNeverOverlap() async throws {
    let setup = try makeSetup()
    let second = try FixtureApp.make(
      in: setup.root.appendingPathComponent("Casks C"), version: "1.0")
    let payload = setup.root.appendingPathComponent("payload/Fixture.app")
    try setup.stub.stage("fixture2", payload: payload, target: second)
    try setup.stub.describe(
      ["fixture": setup.installed, "fixture2": second],
      outdated: ["fixture": "1.1", "fixture2": "1.1"])
    try setup.stub.flag("delay", "0.3")
    let queue = UpdateQueue()
    var operations = [HomebrewUpgradeOperation]()
    let done = expectation(description: "both upgrades")
    done.expectedFulfillmentCount = 2
    for (url, token) in [(setup.installed, "fixture"), (second, "fixture2")] {
      let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: url))
      let operation = HomebrewUpgradeOperation(
        app: bundle, token: token, expectedVersion: Version(versionNumber: "1.1", buildNumber: nil))
      operation.homebrew = setup.homebrew
      operation.lifecycle = .notRunning
      operation.requiresTeam = false
      operation.completionBlock = { done.fulfill() }
      operations.append(operation)
      queue.submit(operation)
    }
    // Detection from elsewhere at the same time.
    async let a = setup.homebrew.owningCask(of: setup.installed, fresh: true)
    async let b = setup.homebrew.outdatedVersion(of: "fixture2", fresh: true)
    _ = try await (a, b)
    await fulfillment(of: [done], timeout: 30)
    XCTAssertTrue(operations.allSatisfy { $0.error == nil })
    let calls = try setup.stub.calls().sorted { $0.start < $1.start }
    XCTAssertGreaterThanOrEqual(calls.filter { $0.arguments.hasPrefix("upgrade") }.count, 2)
    for (earlier, later) in zip(calls, calls.dropFirst()) {
      XCTAssertLessThanOrEqual(
        earlier.end, later.start, "\(earlier.arguments) overlapped \(later.arguments)")
    }
  }

  /// Sol R2-001: brew's uninstall quit acts by bundle ID, so it must name only this app and
  /// that ID must have no other copy on disk or running elsewhere.
  func testQuitHooksMustStayOnTheSelectedCopy() throws {
    let root = try disposableDirectory()
    let selected = try FixtureApp.make(in: root.appendingPathComponent("A"), version: "1.0")
    let second = try FixtureApp.make(in: root.appendingPathComponent("B"), version: "1.0")
    let path = Homebrew.canonical(selected)
    let quitting = InstalledCask(
      token: "fixture", apps: [path], allowListed: true, quits: [FixtureApp.identifier],
      installedApp: path)
    func scope(copies: Set<String>, running: [String]) -> HomebrewScope {
      HomebrewScope(copies: { _ in copies }, runningPaths: { _ in running })
    }
    XCTAssertTrue(scope(copies: [path], running: [path]).installs(quitting, at: selected))
    XCTAssertFalse(
      scope(copies: [path, second.path], running: []).installs(quitting, at: selected),
      "another copy on disk")
    XCTAssertFalse(
      scope(copies: [path], running: [Homebrew.canonical(second)]).installs(quitting, at: selected),
      "the second copy is running")
    XCTAssertFalse(
      HomebrewScope(
        copies: { _ in throw CocoaError(.fileReadNoPermission) }, runningPaths: { _ in [] }
      ).installs(quitting, at: selected), "an unreadable walk fails closed")
    let otherID = InstalledCask(
      token: "fixture", apps: [path], allowListed: true, quits: ["com.example.someone-else"],
      installedApp: path)
    XCTAssertFalse(scope(copies: [], running: []).installs(otherID, at: selected))
    let refused = InstalledCask(token: "fixture", apps: [path], allowListed: false)
    XCTAssertFalse(scope(copies: [], running: []).installs(refused, at: selected))
  }

  /// Sol R2-101/102: only `app` (exactly one), `zap`, and `uninstall` with nothing but
  /// `quit:` pass. Everything else is refused.
  func testAllowListAcceptsOnlyOneAppZapAndQuit() {
    let app: [String: Any] = ["app": ["Fixture.app"]]
    let zap: [String: Any] = ["zap": [["trash": ["~/x"]]]]
    XCTAssertEqual(HomebrewAllowList.quits(in: [app]), [])
    XCTAssertEqual(
      HomebrewAllowList.quits(in: [app, zap, ["uninstall": [["quit": "com.example.a"]]]]),
      ["com.example.a"])
    let refused: [(String, [[String: Any]])] = [
      ("launchctl", [app, ["uninstall": [["quit": "a", "launchctl": "b"]]]]),
      ("signal", [app, ["uninstall": [["signal": [["TERM", "a"]]]]]]),
      ("delete", [app, ["uninstall": [["delete": ["/x"]]]]]),
      ("rmdir", [app, ["uninstall": [["rmdir": ["/x"]]]]]),
      ("script", [app, ["uninstall": [["script": ["executable": "x"]]]]]),
      ("pkg", [app, ["pkg": ["Installer.pkg"]]]),
      ("installer", [app, ["installer": [["script": "x"]]]]),
      ("binary", [app, ["binary": ["x"]]]),
      ("postflight", [app, ["postflight": NSNull()]]),
      ("two apps", [app, app]),
      ("no app", [zap]),
    ]
    for (name, artifacts) in refused {
      XCTAssertNil(HomebrewAllowList.quits(in: artifacts), name)
    }
  }

  /// Sol R2-101/102 and R2-105: the installed definition (receipt) and the current one
  /// (brew info) must both pass, and `:latest` hands off.
  func testInstalledAndCurrentDefinitionsMustBothPass() async throws {
    let cases: [(String, (BrewStub, URL) throws -> Void)] = [
      (
        "installed has launchctl",
        { stub, app in
          try stub.describe(
            ["fixture": app], outdated: ["fixture": "1.1"],
            installed: ["fixture": [["uninstall": [["launchctl": "com.example.agent"]]]]])
        }
      ),
      (
        "current adds a pkg",
        { stub, app in
          try stub.describe(
            ["fixture": app], outdated: ["fixture": "1.1"],
            current: ["fixture": [["pkg": ["Installer.pkg"]]]])
        }
      ),
      (
        "installed has flight blocks",
        { stub, app in
          try stub.describe(
            ["fixture": app], outdated: ["fixture": "1.1"], flightBlocks: ["fixture"])
        }
      ),
      (
        "current is :latest",
        { stub, app in
          try stub.describe(
            ["fixture": app], outdated: ["fixture": "latest"], version: ["fixture": "latest"])
        }
      ),
      (
        "outdated reports latest",
        { stub, app in
          try stub.describe(["fixture": app], outdated: ["fixture": "latest"])
        }
      ),
    ]
    for (name, describe) in cases {
      let setup = try makeSetup()
      try describe(setup.stub, setup.installed)
      let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
      let update = try await HomebrewCheckerOperation(
        with: bundle, repository: nil, homebrew: setup.homebrew
      ).check()
      XCTAssertEqual(
        App(bundle: bundle, update: .success(update), isIgnored: false).capability, .handOff, name)
    }
    // A missing receipt with an empty API caskfile cannot be read: refused.
    let root = try disposableDirectory()
    let metadata = root.appendingPathComponent(".metadata/1.0/20261101/Casks")
    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: metadata.appendingPathComponent("fixture.json"))
    XCTAssertNil(
      HomebrewAllowList.installedArtifacts(caskroom: root).flatMap(HomebrewAllowList.quits))
    try FileManager.default.removeItem(at: metadata.appendingPathComponent("fixture.json"))
    try Data("cask \"fixture\" do\nend\n".utf8).write(
      to: metadata.appendingPathComponent("fixture.rb"))
    XCTAssertNil(HomebrewAllowList.installedArtifacts(caskroom: root), "Ruby caskfiles are refused")
  }

  /// Sol R2-002: brew exits 0 but Updater rejects the result; the app and brew's Caskroom
  /// record both go back, the failure is recorded, and the update is offered again.
  func testRejectedUpgradeRestoresTheCaskroomRecordToo() async throws {
    let setup = try makeSetup(payloadVersion: "1.0.5")  // brew says 1.1, installs 1.0.5
    let appBefore = try FixtureApp.digest(setup.installed)
    let record = setup.stub.caskroom.appendingPathComponent("fixture")
    let recordBefore = try FixtureApp.digest(record)
    let (_, outcome) = try await upgrade(setup)
    guard case .failed? = outcome else {
      return XCTFail("Expected failed, got \(String(describing: outcome))")
    }
    XCTAssertEqual(try FixtureApp.digest(setup.installed), appBefore)
    XCTAssertEqual(try FixtureApp.digest(record), recordBefore, "Caskroom says 1.0 again")
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: record.path).filter {
        !$0.hasPrefix(".")
      },
      ["1.0"])
    await setup.homebrew.invalidate()
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
    let retry = try await HomebrewCheckerOperation(
      with: bundle, repository: nil, homebrew: setup.homebrew
    ).check()
    let app = App(bundle: bundle, update: .success(retry), isIgnored: false)
    XCTAssertTrue(app.updateAvailable, "brew and the disk agree the update is still pending")
    XCTAssertEqual(app.capability, .install)
  }

  /// Sol R2-003: when the installer reports failure, the clone goes back even if the bundle
  /// looks unchanged.
  @MainActor
  func testInstallerFailureAlwaysRestores() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let guardian = ExternalInstallGuard(target: app)
    try guardian.takeClone()
    let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    let before = try app.resourceValues(forKeys: key).fileResourceIdentifier
    let result = await guardian.settle(
      error: HomebrewError.failed(reason: "x", logPath: "/tmp/x"), expected: nil,
      requiresTeam: false, lifecycle: .notRunning, restoreOnInstallerFailure: true)
    XCTAssertEqual(result as? HomebrewError, .failed(reason: "x", logPath: "/tmp/x"))
    let after = try URL(fileURLWithPath: app.path).resourceValues(forKeys: key)
      .fileResourceIdentifier
    XCTAssertFalse(before?.isEqual(after) ?? true, "the clone replaced the bundle")
  }

  /// Sol R2-004: verified brew ownership wins over a Sparkle feed, through the coordinator;
  /// an unowned copy of the same app keeps its Sparkle route.
  func testOwnedSparkleAppIsRoutedToBrewThroughTheCoordinator() async throws {
    let root = try disposableDirectory()
    let feed = ["SUFeedURL": "http://127.0.0.1:9/appcast.xml"]
    let owned = try FixtureApp.make(
      in: root.appendingPathComponent("Owned"), version: "1.0", extraInfo: feed)
    let unowned = try FixtureApp.make(
      in: root.appendingPathComponent("Copy"), version: "1.0", extraInfo: feed)
    let stub = try BrewStub(in: root)
    try stub.describe(["fixture": owned], outdated: ["fixture": "1.1"])
    let homebrew = stub.client(logs: root.appendingPathComponent("logs"))
    let ownedBundle = try XCTUnwrap(BundleCollector.collectBundle(at: owned))
    let unownedBundle = try XCTUnwrap(BundleCollector.collectBundle(at: unowned))
    XCTAssertEqual(ownedBundle.source, .sparkle)
    let coordinator = UpdateCheckCoordinator(
      check: { bundle, repository in
        try await UpdateCheckCoordinator.check(bundle, repository: repository, homebrew: homebrew)
      }, repositoryProvider: { nil })
    coordinator.updateDiscoveredBundles([ownedBundle, unownedBundle])
    let store = try XCTUnwrap(coordinator.appProvider as? AppDataStore)
    func app(_ url: URL) -> App? { store.apps.first { $0.fileURL == url } }
    for _ in 0..<1_500 {
      if app(owned)?.source == .homebrew, let copy = app(unowned),
        copy.error != nil || copy.remoteVersion != nil
      {
        break
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertEqual(app(owned)?.source, .homebrew)
    XCTAssertEqual(app(owned)?.capability, .install)
    XCTAssertNotEqual(app(unowned)?.source, .homebrew, "the unowned copy keeps its Sparkle route")
  }

  /// Sol R2-103: brew is never stopped part way; the job waits for it and keeps the lock.
  func testSlowBrewIsWaitedForWhileHoldingTheLock() async throws {
    let setup = try makeSetup()
    try setup.stub.flag("delay", "1.2")
    let queue = UpdateQueue(history: setup.history)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
    let operation = HomebrewUpgradeOperation(
      app: bundle, token: "fixture",
      expectedVersion: Version(versionNumber: "1.1", buildNumber: nil))
    operation.homebrew = setup.homebrew
    operation.lifecycle = .notRunning
    operation.requiresTeam = false
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    queue.submit(operation)
    try await Task.sleep(for: .milliseconds(800))
    XCTAssertFalse(operation.isFinished, "brew is still running")
    XCTAssertTrue(queue.contains(setup.installed), "the job keeps its lock")
    guard case .installing = operation.progressState else {
      return XCTFail("the row shows the job is still working")
    }
    await fulfillment(of: [done], timeout: 30)
    XCTAssertNil(operation.error)
  }

  /// Sol R2-104: fetch first with the app untouched, then quit, then upgrade from the cache.
  /// An app reopened during a slow download that then refuses to quit means needs-quit,
  /// with nothing changed and no upgrade run.
  func testFetchComesBeforeTheQuitAndARefusalChangesNothing() async throws {
    let setup = try makeSetup()
    let before = try FixtureApp.digest(setup.installed)
    try setup.stub.flag("fetchdelay", "0.6")
    let reopened = Mutex(false)
    let quitAsked = Mutex<Double?>(nil)
    let lifecycle = AppLifecycle(
      runningApps: { _ in
        reopened.withLock { $0 }
          ? [
            .init(
              terminate: { quitAsked.withLock { $0 = Date().timeIntervalSince1970 } },
              isTerminated: { false })
          ] : []
      },
      confirmQuit: { _ in true }, reopen: { _ in }, timeout: .milliseconds(200))
    let queue = UpdateQueue(history: setup.history)
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
    let operation = HomebrewUpgradeOperation(
      app: bundle, token: "fixture",
      expectedVersion: Version(versionNumber: "1.1", buildNumber: nil))
    operation.homebrew = setup.homebrew
    operation.lifecycle = lifecycle
    operation.requiresTeam = false
    let done = expectation(description: "finished")
    operation.completionBlock = { done.fulfill() }
    queue.submit(operation)
    try await Task.sleep(for: .milliseconds(200))
    reopened.withLock { $0 = true }  // the user opens the app while it downloads
    await fulfillment(of: [done], timeout: 30)
    guard case AppDownloadError.applicationStillRunning? = operation.error else {
      return XCTFail("Expected needs-quit, got \(String(describing: operation.error))")
    }
    XCTAssertEqual(try FixtureApp.digest(setup.installed), before)
    let calls = try setup.stub.calls()
    XCTAssertFalse(calls.contains { $0.arguments.hasPrefix("upgrade") }, "no upgrade ran")
    let fetch = try XCTUnwrap(calls.first { $0.arguments.hasPrefix("fetch") })
    XCTAssertGreaterThanOrEqual(
      try XCTUnwrap(quitAsked.withLock { $0 }), fetch.end, "quit after fetch")

    // The normal order: fetch, then upgrade.
    let fresh = try makeSetup()
    _ = try await upgrade(fresh)
    let order = try fresh.stub.calls().map {
      $0.arguments.split(separator: " ").first.map(String.init) ?? ""
    }
    let fetchIndex = try XCTUnwrap(order.firstIndex(of: "fetch"))
    let upgradeIndex = try XCTUnwrap(order.firstIndex(of: "upgrade"))
    XCTAssertLessThan(fetchIndex, upgradeIndex)
  }

  /// Sol R2-106: the app and the Caskroom record are restored separately; a failed record
  /// move is reported with the surviving paths, and the app is reopened only afterwards.
  @MainActor
  func testCompanionRestoreFailuresReportWhatSurvived() async throws {
    for failingMove in [1, 2] {
      let root = try disposableDirectory()
      let app = try FixtureApp.make(in: root.appendingPathComponent("App"), version: "1.0")
      let record = root.appendingPathComponent("Caskroom/fixture")
      try FileManager.default.createDirectory(
        at: record.appendingPathComponent("1.0"), withIntermediateDirectories: true)
      let appBefore = try FixtureApp.digest(app)
      let moves = Mutex(0)
      let guardian = ExternalInstallGuard(target: app) { from, to in
        let move = moves.withLock {
          $0 += 1
          return $0
        }
        if move == failingMove { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.moveItem(at: from, to: to)
      }
      try guardian.takeClone(companions: [record])
      let target = FakeTarget(running: false)
      guardian.noteQuit(wasRunning: true)
      // What brew did: new app version and a new Caskroom record.
      let payload = try FixtureApp.make(in: root.appendingPathComponent("payload"), version: "1.1")
      try FileManager.default.removeItem(at: app)
      try FileManager.default.copyItem(at: payload, to: app)
      try FileManager.default.removeItem(at: record.appendingPathComponent("1.0"))
      try FileManager.default.createDirectory(
        at: record.appendingPathComponent("1.1"), withIntermediateDirectories: true)
      let result = await guardian.settle(
        error: HomebrewError.failed(reason: "x", logPath: "/tmp/x"), expected: nil,
        requiresTeam: false, lifecycle: target.lifecycle(), restoreOnInstallerFailure: true)
      guard case ReplacementError.incompleteRestore(let records)? = result else {
        return XCTFail(
          "move \(failingMove): expected an incomplete restore, got \(String(describing: result))")
      }
      XCTAssertTrue(records.contains(record.path), records)
      XCTAssertTrue(records.contains("previous record kept at"), records)
      XCTAssertEqual(try FixtureApp.digest(app), appBefore, "the app itself was restored")
      XCTAssertEqual(target.reopens.withLock { $0 }, 1, "reopened after settlement")
    }
  }

  private func capability(_ setup: Setup) async throws -> UpdateCapability {
    await setup.homebrew.invalidate()
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
    let update = try await HomebrewCheckerOperation(
      with: bundle, repository: nil, homebrew: setup.homebrew
    ).check()
    return App(bundle: bundle, update: .success(update), isIgnored: false).capability
  }

  /// Sol R2-201: the installed target (from the receipt and the Caskroom's appdir) and the
  /// current target must both be the selected bundle; a migrating target hands off.
  func testInstalledAndCurrentTargetsMustBothBeTheSelectedApp() async throws {
    let setup = try makeSetup()
    let capabilityBefore = try await capability(setup)
    XCTAssertEqual(capabilityBefore, .install, "both targets agree")
    try setup.stub.describe(
      ["fixture": setup.installed], outdated: ["fixture": "1.1"],
      installedAppdir: ["fixture": setup.root.appendingPathComponent("Elsewhere").path])
    let moved = try await capability(setup)
    XCTAssertEqual(moved, .handOff, "the installed app was somewhere else")
    let room = setup.stub.caskroom.appendingPathComponent("fixture")
    let receipt: [[String: Any]] = [["app": ["Old.app", ["target": setup.installed.path]]]]
    XCTAssertEqual(
      Homebrew.installedTarget(of: receipt, caskroom: room), Homebrew.canonical(setup.installed),
      "an explicit target wins over the appdir")
    try FileManager.default.removeItem(at: room.appendingPathComponent(".metadata/config.json"))
    XCTAssertNil(Homebrew.installedTarget(of: receipt, caskroom: room), "unresolvable")
  }

  /// Sol R2-202: dependencies would be installed outside Updater's protection: hand off,
  /// and no mutating brew command runs.
  func testCasksWithDependenciesHandOffWithoutChangingAnything() async throws {
    for dependency in [["cask": ["other-cask"]], ["formula": ["unar"]]] as [[String: Any]] {
      let setup = try makeSetup()
      try setup.stub.describe(
        ["fixture": setup.installed], outdated: ["fixture": "1.1"],
        dependsOn: ["fixture": dependency.merging(["macos": [">=": ["14"]]]) { a, _ in a }])
      let routed = try await capability(setup)
      XCTAssertEqual(routed, .handOff, "\(dependency)")
      let (operation, _) = try await upgrade(setup)
      XCTAssertEqual(operation.outcomeOverride, .handedOff)
      let mutating = try setup.stub.calls().filter {
        $0.arguments.hasPrefix("fetch") || $0.arguments.hasPrefix("upgrade")
      }
      XCTAssertTrue(mutating.isEmpty, "\(mutating)")
    }
    let macOnly = try makeSetup()
    try macOnly.stub.describe(
      ["fixture": macOnly.installed], outdated: ["fixture": "1.1"],
      dependsOn: ["fixture": ["macos": [">=": ["14"]], "arch": ["arm64"]]])
    let allowed = try await capability(macOnly)
    XCTAssertEqual(allowed, .install, "macOS and architecture constraints are fine")
  }

  /// Sol R2-203: brew exits 0 and advances its record but the bundle is still 1.0: not an
  /// update. The app and the Caskroom record are restored.
  func testSuccessfulBrewThatLeftTheAppUnchangedIsRolledBack() async throws {
    let setup = try makeSetup()
    try setup.stub.flag("fixture.noop")
    let record = setup.stub.caskroom.appendingPathComponent("fixture")
    let recordBefore = try FixtureApp.digest(record)
    let (_, outcome) = try await upgrade(setup)
    guard case .failed(let reason, _)? = outcome else {
      return XCTFail("Expected failed, got \(String(describing: outcome))")
    }
    XCTAssertTrue(reason.contains("still version 1.0"), reason)
    XCTAssertEqual(try FixtureApp.digest(record), recordBefore, "the Caskroom record went back")
    XCTAssertEqual(BundleCollector.collectBundle(at: setup.installed)?.version.versionNumber, "1.0")
  }

  /// Sol R2-204: scope is checked again after the download; a copy that appears or starts
  /// meanwhile means no upgrade. The upgrade itself runs with --no-quit.
  func testScopeIsRecheckedAfterFetchAndUpgradeRunsWithNoQuit() async throws {
    for change in ["appears", "starts"] {
      let setup = try makeSetup()
      try setup.stub.describe(
        ["fixture": setup.installed], outdated: ["fixture": "1.1"],
        current: ["fixture": [["uninstall": [["quit": FixtureApp.identifier]]]]],
        installed: ["fixture": [["uninstall": [["quit": FixtureApp.identifier]]]]])
      try setup.stub.flag("fetchdelay", "0.4")
      let selected = Homebrew.canonical(setup.installed)
      let fetched = setup.stub.directory.appendingPathComponent("fetched")
      let other = Homebrew.canonical(setup.otherCopy)
      let scope = HomebrewScope(
        copies: { _ in
          change == "appears" && FileManager.default.fileExists(atPath: fetched.path)
            ? [selected, other] : [selected]
        },
        runningPaths: { _ in
          change == "starts" && FileManager.default.fileExists(atPath: fetched.path) ? [other] : []
        })
      let queue = UpdateQueue(history: setup.history)
      let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
      let operation = HomebrewUpgradeOperation(
        app: bundle, token: "fixture",
        expectedVersion: Version(versionNumber: "1.1", buildNumber: nil))
      operation.homebrew = setup.homebrew
      operation.scope = scope
      operation.lifecycle = .notRunning
      operation.requiresTeam = false
      let done = expectation(description: "finished")
      operation.completionBlock = { done.fulfill() }
      queue.submit(operation)
      await fulfillment(of: [done], timeout: 30)
      XCTAssertEqual(operation.outcomeOverride, .handedOff, change)
      let calls = try setup.stub.calls()
      XCTAssertTrue(calls.contains { $0.arguments.hasPrefix("fetch") }, change)
      XCTAssertFalse(calls.contains { $0.arguments.hasPrefix("upgrade") }, "\(change): no upgrade")
    }
    let normal = try makeSetup()
    _ = try await upgrade(normal)
    XCTAssertTrue(
      try normal.stub.calls().contains { $0.arguments == "upgrade --cask --no-quit fixture" })
  }

  /// Sol R2-205: if the app cannot be restored (it would not quit), its Caskroom record is
  /// left live with it, and both saved copies are reported.
  @MainActor
  func testCompanionsStayLiveWhenTheAppCannotBeRestored() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root.appendingPathComponent("App"), version: "1.0")
    let record = root.appendingPathComponent("Caskroom/fixture")
    try FileManager.default.createDirectory(
      at: record.appendingPathComponent("1.0"), withIntermediateDirectories: true)
    let guardian = ExternalInstallGuard(target: app)
    try guardian.takeClone(companions: [record])
    try FileManager.default.removeItem(at: record.appendingPathComponent("1.0"))
    try FileManager.default.createDirectory(
      at: record.appendingPathComponent("1.1"), withIntermediateDirectories: true)
    let refusing = AppLifecycle(
      runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
      confirmQuit: { _ in true }, reopen: { _ in XCTFail("an unrestored app is not reopened") },
      timeout: .milliseconds(100))
    let result = await guardian.settle(
      error: HomebrewError.failed(reason: "x", logPath: "/tmp/x"), expected: nil,
      requiresTeam: false, lifecycle: refusing, restoreOnInstallerFailure: true)
    guard case ReplacementError.restoreFailed(let paths)? = result else {
      return XCTFail("Expected restore failure, got \(String(describing: result))")
    }
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: record.path), ["1.1"],
      "the live record matches the app that is still there")
    let saved = try XCTUnwrap(
      paths.components(separatedBy: "; ").first { $0.contains("Homebrew's previous record") }?
        .components(separatedBy: " (").first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: saved), "previous record kept at \(saved)")
    XCTAssertTrue(paths.contains(ReplacementTransaction.backupName))
  }
}
