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
      "upgrade --cask")
        token="$3"
        [ -f "$dir/delay" ] && sleep "$(cat "$dir/delay")"
        if [ -f "$dir/$token.sudo" ]; then
          echo "sudo: a terminal is required to read the password"; status=1
        else
          target="$(cat "$dir/$token.target")"
          rm -rf "$target" && /usr/bin/ditto "$dir/$token.payload" "$target"
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

  /// `casks`: token → (installed app targets, needs a pkg, quit IDs, signals). Each gets a
  /// Caskroom record for version 1.0; `outdated` gives the version brew would install.
  func describe(
    _ casks: [String: (apps: [URL], pkg: Bool)], outdated: [String: String],
    quits: [String: [String]] = [:], signals: Set<String> = []
  ) throws {
    let info: [String: Any] = [
      "formulae": [],
      "casks": casks.map { token, cask in
        var uninstall = [String: Any]()
        if let ids = quits[token] { uninstall["quit"] = ids }
        if signals.contains(token) { uninstall["signal"] = [["TERM", "com.example.any"]] }
        return [
          "token": token,
          "artifacts": cask.apps.map { ["app": [$0.lastPathComponent], "target": $0.path] }
            + (cask.pkg ? [["pkg": ["Installer.pkg"]]] : [])
            + (uninstall.isEmpty ? [] : [["uninstall": [uninstall]]]),
        ] as [String: Any]
      },
    ]
    try JSONSerialization.data(withJSONObject: info).write(
      to: directory.appendingPathComponent("info.json"))
    for token in casks.keys {
      let record = caskroom.appendingPathComponent("\(token)/1.0")
      try FileManager.default.createDirectory(at: record, withIntermediateDirectories: true)
      try Data("installed 1.0".utf8).write(to: record.appendingPathComponent(".metadata"))
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
    try stub.describe(["fixture": ([installed], false)], outdated: ["fixture": "1.1"])
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
      ["fixture": ([setup.installed], false), "pkgcask": ([pkgApp], true)],
      outdated: ["fixture": "1.1"])
    let owner = try await setup.homebrew.owningCask(of: setup.installed)
    XCTAssertEqual(owner?.token, "fixture")
    let viaLink = try await setup.homebrew.owningCask(of: link)
    XCTAssertEqual(viaLink?.token, "fixture", "resolved to the canonical path")
    let other = try await setup.homebrew.owningCask(of: setup.otherCopy)
    XCTAssertNil(other, "a copy elsewhere is not owned")
    let pkg = try await setup.homebrew.owningCask(of: pkgApp)
    XCTAssertEqual(pkg?.needsAdministrator, true)
    let outdated = try await setup.homebrew.outdatedVersion(of: "fixture")
    XCTAssertEqual(outdated, "1.1")
  }

  /// Owned casks become installs; sudo casks hand off; others keep the catalogue route.
  func testCheckerRoutesOwnedCasksToBrew() async throws {
    let setup = try makeSetup()
    let pkgApp = try FixtureApp.make(in: setup.root.appendingPathComponent("Pkg"), version: "1.0")
    try setup.stub.describe(
      ["fixture": ([setup.installed], false), "pkgcask": ([pkgApp], true)],
      outdated: ["fixture": "1.1", "pkgcask": "2.0"])
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
      ["fixture": ([setup.installed], false), "fixture2": ([second], false)],
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

  /// Sol R2-001: brew's uninstall hooks act by bundle ID. Signals always hand off; a quit
  /// hands off when another copy with that ID exists on disk or is running elsewhere.
  func testQuitAndSignalHooksMustStayOnTheSelectedCopy() throws {
    let root = try disposableDirectory()
    let selected = try FixtureApp.make(in: root.appendingPathComponent("A"), version: "1.0")
    let second = try FixtureApp.make(in: root.appendingPathComponent("B"), version: "1.0")
    let path = Homebrew.canonical(selected)
    let quitting = InstalledCask(
      token: "fixture", apps: [path], needsAdministrator: false, quits: [FixtureApp.identifier])
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
      )
      .installs(quitting, at: selected), "an unreadable walk fails closed")
    let signalling = InstalledCask(
      token: "fixture", apps: [path], needsAdministrator: false, signals: true)
    XCTAssertFalse(scope(copies: [path], running: []).installs(signalling, at: selected))
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
      try FileManager.default.contentsOfDirectory(atPath: record.path), ["1.0"])
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
    try stub.describe(["fixture": ([owned], false)], outdated: ["fixture": "1.1"])
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
}
