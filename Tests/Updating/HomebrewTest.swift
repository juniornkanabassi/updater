// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

/// A stand-in for brew on an injected path. It answers `info`/`outdated` from JSON files and
/// performs `upgrade --cask` by staging the cask's payload over its target, the way brew
/// replaces an app artifact. Real brew is never run: it would need a full Homebrew prefix and
/// network access, and could reach the user's real prefix, caches or casks.
private struct BrewStub {
  let directory: URL
  let brew: URL

  init(in root: URL) throws {
    directory = root.appendingPathComponent("brew-stub")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    brew = directory.appendingPathComponent("brew")
    try #"""
    #!/bin/bash
    dir="$STUB_DIR"
    now() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%.6f\n", time'; }
    start=$(now)
    status=0
    case "$1 $2" in
      "info --cask") cat "$dir/info.json" ;;
      "outdated --cask") cat "$dir/outdated.json" ;;
      "upgrade --cask")
        token="$3"
        [ -f "$dir/delay" ] && sleep "$(cat "$dir/delay")"
        if [ -f "$dir/$token.sudo" ]; then
          echo "sudo: a terminal is required to read the password"; status=1
        else
          target="$(cat "$dir/$token.target")"
          rm -rf "$target" && /usr/bin/ditto "$dir/$token.payload" "$target"
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

  /// `casks`: token → (installed app targets, needs a pkg).
  func describe(_ casks: [String: (apps: [URL], pkg: Bool)], outdated: [String: String]) throws {
    let info: [String: Any] = [
      "formulae": [],
      "casks": casks.map { token, cask in
        [
          "token": token,
          "artifacts": cask.apps.map { ["app": [$0.lastPathComponent], "target": $0.path] }
            + (cask.pkg ? [["pkg": ["Installer.pkg"]]] : []),
        ] as [String: Any]
      },
    ]
    try JSONSerialization.data(withJSONObject: info).write(
      to: directory.appendingPathComponent("info.json"))
    let list: [String: Any] = [
      "formulae": [],
      "casks": outdated.map {
        ["name": $0.key, "installed_versions": ["1.0"], "current_version": $0.value]
      },
    ]
    // brew prints warnings before its JSON; the client must cope.
    var data = Data("Warning: stub warning line\n".utf8)
    data.append(try JSONSerialization.data(withJSONObject: list))
    try data.write(to: directory.appendingPathComponent("outdated.json"))
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
    XCTAssertEqual(
      App(bundle: pkgBundle, update: .success(pkgUpdate), isIgnored: false).capability, .handOff)

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
}
