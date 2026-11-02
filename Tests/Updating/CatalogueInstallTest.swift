// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import CryptoKit
import Synchronization
import XCTest

@testable import Latest

/// Round 5b: catalogue direct downloads, end to end against disposable fixture apps served from
/// 127.0.0.1 (zip, disk image, tar). Nothing here touches a real app or /Applications.
final class CatalogueInstallTest: XCTestCase {
  private let identifier = FixtureApp.identifier

  // MARK: Fixtures

  private struct Scene {
    let apps: URL
    let installed: URL
    let bundle: App.Bundle
    let payloads: URL
  }

  /// The installed 1.0 fixture in its own folder (the walk's scope) and a payload folder.
  private func scene() throws -> Scene {
    let root = try disposableDirectory()
    let apps = root.appendingPathComponent("Apps")
    let payloads = root.appendingPathComponent("Payloads")
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: payloads, withIntermediateDirectories: true)
    let installed = try FixtureApp.make(in: apps, version: "1.0")
    return Scene(
      apps: apps, installed: installed,
      bundle: try XCTUnwrap(BundleCollector.collectBundle(at: installed)), payloads: payloads)
  }

  /// A 1.1 fixture (optionally with an embedded helper app, or beside a second outer app)
  /// packed as zip, disk image or tar; returns the archive's name and SHA-256.
  private func payload(
    in scene: Scene, kind: CatalogueInstall.PayloadKind, helper: Bool = false, twoApps: Bool = false
  ) throws -> (name: String, sha256: String) {
    let source = scene.payloads.appendingPathComponent("src-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let app = try FixtureApp.make(in: source, version: "1.1", signed: !helper)
    if helper {
      let helpers = app.appendingPathComponent("Contents/Helpers")
      try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
      let embedded = try FixtureApp.make(
        in: helpers, name: "Helper", identifier: "com.example.helper", version: "1.1")
      XCTAssertTrue(FileManager.default.fileExists(atPath: embedded.path))
      try FixtureApp.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    }
    if twoApps {
      try FixtureApp.make(
        in: source, name: "Other", identifier: "com.example.other", version: "1.0")
    }
    let name: String
    switch kind {
    case .zip:
      name = "payload-\(UUID().uuidString).zip"
      try FixtureApp.run(
        "/usr/bin/ditto",
        ["-c", "-k", source.path, scene.payloads.appendingPathComponent(name).path])
    case .diskImage:
      name = "payload-\(UUID().uuidString).dmg"
      try FixtureApp.run(
        "/usr/bin/hdiutil",
        [
          "create", "-quiet", "-volname", "Fixture", "-srcfolder", source.path, "-format", "UDZO",
          "-ov", scene.payloads.appendingPathComponent(name).path,
        ])
    case .tar:
      name = "payload-\(UUID().uuidString).tgz"
      try FixtureApp.run(
        "/usr/bin/tar",
        ["-czf", scene.payloads.appendingPathComponent(name).path, "-C", source.path, "."])
    }
    let data = try Data(contentsOf: scene.payloads.appendingPathComponent(name))
    return (name, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
  }

  private func cask(
    url: String, sha256: String, version: String = "1.1",
    artifacts: [[String: Any]]? = nil, extra: [String: Any] = [:]
  ) throws -> Data {
    var cask: [String: Any] = [
      "token": "fixture", "version": version, "sha256": sha256, "url": url,
      "artifacts": artifacts ?? [
        ["app": ["Fixture.app"]], ["zap": [["trash": "~/Library/Preferences/x.plist"]]],
        ["uninstall": [["quit": FixtureApp.identifier]]],
      ],
    ]
    cask.merge(extra) { $1 }
    return try JSONSerialization.data(withJSONObject: cask)
  }

  /// The real folder walk over the fixture's folder: it sees hidden folders too, so it finds
  /// the job's own staged candidate, which the recheck must exclude.
  private func walk(_ scene: Scene) -> @Sendable (String) throws -> Set<String> {
    let apps = scene.apps
    return { try AppStoreInstallGate.copies(of: $0, in: [apps]) }
  }

  private final class Calls: Sendable {
    let fetches = Mutex(0)
    let walks = Mutex(0)
  }

  /// Runs one catalogue job through the scheduler and returns how it ended.
  private func install(
    _ scene: Scene, cask: Data, check transform: (inout CatalogueInstallCheck) -> Void = { _ in },
    lifecycle: AppLifecycle = FakeTarget(running: false).lifecycle(), requiresTeam: Bool = false,
    calls: Calls = Calls()
  ) async throws -> UpdateJobRecord {
    var check = CatalogueInstallCheck(
      fetchCask: { _ in
        calls.fetches.withLock { $0 += 1 }
        return cask
      }, copies: walk(scene), isWritable: { _ in true }, assess: { _ in })
    transform(&check)
    let operation = AppDownloadUpdateOperation(
      app: scene.bundle,
      catalogue: CatalogueJob(
        token: "fixture", minimumVersion: Version(versionNumber: "1.1", buildNumber: nil),
        check: check))
    operation.requiresTeam = requiresTeam
    operation.launchProbe = { try FixtureApp.launchProbe($0) }
    operation.lifecycle = lifecycle
    let queue = UpdateQueue(
      history: UpdateHistoryStore(
        fileURL: try disposableDirectory().appendingPathComponent("history.jsonl")))
    queue.addOperation(operation)
    for _ in 0..<1_500 {
      if let record = queue.job(withID: operation.jobID)?.record { return record }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("the job did not finish")
    throw CancellationError()
  }

  private func version(_ app: URL) -> String? {
    BundleCollector.collectBundle(at: app)?.version.versionNumber
  }

  // MARK: Happy paths

  func testZipWithEmbeddedHelperDiskImageAndTarInstallAndVerifyOnDisk() async throws {
    for (kind, helper) in [
      (CatalogueInstall.PayloadKind.zip, true), (.diskImage, false), (.tar, false),
    ] {
      let scene = try scene()
      let server = try await LocalFileServer.start(serving: scene.payloads)
      defer { server.stop() }
      let (name, hash) = try payload(in: scene, kind: kind, helper: helper)
      let record = try await install(
        scene,
        cask: try cask(
          url: server.baseURL.appendingPathComponent(name).absoluteString, sha256: hash))
      XCTAssertEqual(record.outcome, .updated(from: "1.0", to: "1.1"), "\(kind)")
      XCTAssertEqual(version(scene.installed), "1.1", "the disk says 1.1 (\(kind))")
      let leftovers = try FileManager.default.contentsOfDirectory(atPath: scene.apps.path)
      XCTAssertEqual(leftovers, ["Fixture.app"], "staging is cleaned up (\(kind))")
    }
  }

  // MARK: Payload and trust refusals

  func testWrongChecksumGatekeeperTwoAppsAndTeamRequirementAreRefused() async throws {
    let scene = try scene()
    let server = try await LocalFileServer.start(serving: scene.payloads)
    defer { server.stop() }
    let before = try FixtureApp.digest(scene.installed)
    let (name, hash) = try payload(in: scene, kind: .zip)
    let url = server.baseURL.appendingPathComponent(name).absoluteString

    let wrongHash = try await install(
      scene, cask: try cask(url: url, sha256: String(repeating: "0", count: 64)))
    guard case .failed = wrongHash.outcome else { return XCTFail("wrong SHA-256 must fail") }

    let gatekeeper = try await install(
      scene, cask: try cask(url: url, sha256: hash),
      check: { $0.assess = { _ in throw AppDownloadError.identityMismatch } })
    guard case .failed(let reason, _) = gatekeeper.outcome else { return XCTFail("spctl refusal") }
    XCTAssertTrue(reason.contains("Gatekeeper"), reason)

    // Real vendors must keep their Team ID; an ad-hoc candidate has none to match.
    let team = try await install(scene, cask: try cask(url: url, sha256: hash), requiresTeam: true)
    guard case .failed = team.outcome else { return XCTFail("a different Team ID must fail") }

    let (twoName, twoHash) = try payload(in: scene, kind: .zip, twoApps: true)
    let two = try await install(
      scene,
      cask: try cask(
        url: server.baseURL.appendingPathComponent(twoName).absoluteString, sha256: twoHash))
    guard case .failed(let twoReason, _) = two.outcome else { return XCTFail("two outer apps") }
    XCTAssertTrue(twoReason.contains("2 apps"), twoReason)

    XCTAssertEqual(try FixtureApp.digest(scene.installed), before, "the app is untouched")
  }

  // MARK: Scope

  func testScopeRefusalsKeepTheAppOnItsOwnRouteAndChangeNothing() async throws {
    let scene = try scene()
    let server = try await LocalFileServer.start(serving: scene.payloads)
    defer { server.stop() }
    let before = try FixtureApp.digest(scene.installed)
    let (name, hash) = try payload(in: scene, kind: .zip)
    let data = try cask(
      url: server.baseURL.appendingPathComponent(name).absoluteString, sha256: hash)
    let installedPath = scene.installed.standardizedFileURL.path

    // Not writable without admin: nothing is fetched.
    let calls = Calls()
    let locked = try await install(
      scene, cask: data, check: { $0.isWritable = { _ in false } }, calls: calls)
    XCTAssertEqual(locked.outcome, .handedOff)
    XCTAssertEqual(locked.handOff?.opened, false)
    XCTAssertEqual(calls.fetches.withLock { $0 }, 0)

    // A second copy already present.
    let second = try await install(
      scene, cask: data,
      check: { $0.copies = { _ in [installedPath, "/Users/Shared/Fixture.app"] } })
    XCTAssertEqual(second.outcome, .handedOff)

    // A copy appears while downloading (seen at the post-staging recheck) or during the quit
    // prompt (the recheck right before replacement).
    for appearsOnWalk in [2, 3] {
      let walks = Calls()
      let real = walk(scene)
      let appearing = try await install(
        scene, cask: data,
        check: {
          $0.copies = { id in
            let count = walks.walks.withLock {
              $0 += 1
              return $0
            }
            return try real(id).union(count >= appearsOnWalk ? ["/Users/Shared/Fixture.app"] : [])
          }
        }, lifecycle: FakeTarget(running: true).lifecycle())
      XCTAssertEqual(appearing.outcome, .handedOff, "copy on walk \(appearsOnWalk)")
      XCTAssertTrue(appearing.handOff?.reason.contains("appeared") == true)
    }
    XCTAssertEqual(try FixtureApp.digest(scene.installed), before, "no replacement happened")
  }

  /// The real walk sees the job's own staged candidate (a hidden folder beside the app); the
  /// recheck excludes exactly that folder, so the install still goes ahead.
  func testOwnStagedCandidateIsNotASecondCopy() async throws {
    let scene = try scene()
    let server = try await LocalFileServer.start(serving: scene.payloads)
    defer { server.stop() }
    let (name, hash) = try payload(in: scene, kind: .zip)
    let seen = Mutex<[Set<String>]>([])
    let real = walk(scene)
    let record = try await install(
      scene,
      cask: try cask(url: server.baseURL.appendingPathComponent(name).absoluteString, sha256: hash),
      check: {
        $0.copies = { id in
          let found = try real(id)
          seen.withLock { $0.append(found) }
          return found
        }
      })
    XCTAssertEqual(record.outcome, .updated(from: "1.0", to: "1.1"))
    XCTAssertTrue(
      seen.withLock { $0 }.contains { $0.contains { $0.contains("/.latest-update-") } },
      "the walk did see the staged candidate")
    XCTAssertEqual(
      CatalogueInstall.outerApps(in: scene.apps).map(\.lastPathComponent), ["Fixture.app"])
  }

  func testDeclinedQuitInstallsNothing() async throws {
    let scene = try scene()
    let server = try await LocalFileServer.start(serving: scene.payloads)
    defer { server.stop() }
    let (name, hash) = try payload(in: scene, kind: .zip)
    let declining = AppLifecycle(
      runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
      confirmQuit: { _ in false }, reopen: { _ in })
    let record = try await install(
      scene,
      cask: try cask(url: server.baseURL.appendingPathComponent(name).absoluteString, sha256: hash),
      lifecycle: declining)
    XCTAssertTrue(record.quitDeclined)
    XCTAssertNil(record.outcome)
    XCTAssertEqual(version(scene.installed), "1.0")
  }

  /// The cask fetched right before installing changed shape: refused, nothing downloaded.
  func testFreshCaskThatChangedShapeIsRefused() async throws {
    let scene = try scene()
    let changed = try cask(
      url: "https://example.com/x.zip", sha256: String(repeating: "a", count: 64),
      artifacts: [["app": ["Fixture.app"]], ["pkg": ["Extra.pkg"]]])
    let record = try await install(scene, cask: changed)
    guard case .failed(let reason, _) = record.outcome else { return XCTFail("changed shape") }
    XCTAssertTrue(reason.contains("more than install one app"), reason)
    XCTAssertEqual(version(scene.installed), "1.0")
  }

  // MARK: Rules as pure functions

  func testShapeRulesFollowTheRoundTwoAllowList() throws {
    let hash = String(repeating: "a", count: 64)
    func parse(_ data: Data, platform: String = "arm64_tahoe") throws -> AppDownloadRelease {
      try CatalogueInstall.release(fromCask: data, bundleIdentifier: identifier, platform: platform)
    }
    let good = try parse(
      try cask(
        url: "https://example.com/arm64.dmg", sha256: hash,
        extra: [
          "variations": [
            "tahoe": [
              "url": "https://example.com/intel.dmg", "sha256": String(repeating: "b", count: 64),
            ]
          ],
          "depends_on": ["macos": [">=": ["14"]]],
        ]))
    XCTAssertEqual(good.url.lastPathComponent, "arm64.dmg")
    XCTAssertEqual(good.sha256, hash)
    XCTAssertEqual(
      try parse(
        try cask(
          url: "https://example.com/arm64.dmg", sha256: hash,
          extra: ["variations": ["tahoe": ["url": "https://example.com/intel.dmg"]]]),
        platform: "tahoe"
      ).url.lastPathComponent, "intel.dmg")
    let refused: [(String, Data)] = [
      ("no_check", try cask(url: "https://example.com/a.zip", sha256: "no_check")),
      ("latest", try cask(url: "https://example.com/a.zip", sha256: hash, version: "latest")),
      ("http", try cask(url: "http://example.com/a.zip", sha256: hash)),
      (
        "pkg",
        try cask(url: "https://example.com/a.zip", sha256: hash, artifacts: [["pkg": ["A.pkg"]]])
      ),
      (
        "two apps",
        try cask(
          url: "https://example.com/a.zip", sha256: hash,
          artifacts: [["app": ["Fixture.app"]], ["app": ["Other.app"]]])
      ),
      (
        "binary",
        try cask(
          url: "https://example.com/a.zip", sha256: hash,
          artifacts: [["app": ["Fixture.app"]], ["binary": ["x"]]])
      ),
      (
        "uninstall delete",
        try cask(
          url: "https://example.com/a.zip", sha256: hash,
          artifacts: [["app": ["Fixture.app"]], ["uninstall": [["delete": "/x"]]]])
      ),
      (
        "quit another app",
        try cask(
          url: "https://example.com/a.zip", sha256: hash,
          artifacts: [["app": ["Fixture.app"]], ["uninstall": [["quit": "com.example.other"]]]])
      ),
      (
        "formula dependency",
        try cask(
          url: "https://example.com/a.zip", sha256: hash, extra: ["depends_on": ["formula": ["x"]]])
      ),
      (
        "unsafe path",
        try cask(url: "https://example.com/a.zip", sha256: hash, artifacts: [["app": ["../X.app"]]])
      ),
    ]
    for (label, data) in refused {
      XCTAssertThrowsError(try parse(data), label)
    }
  }

  /// Identity uses only the bundle-ID index: no evidence (name-only or renamed without it),
  /// duplicate identifiers and Discord are refused.
  func testIdentityIndexAndDenyList() throws {
    let catalogue = """
      [
        {"token": "fixture", "version": "1.1", "artifacts": [{"app": ["Fixture.app"]},
          {"uninstall": [{"quit": "com.example.fixture"}]}], "depends_on": {}},
        {"token": "renamed", "version": "2", "artifacts": [{"app": ["Renamed.app"]}],
          "depends_on": {}},
        {"token": "twin-a", "version": "1", "artifacts": [{"app": ["A.app"]},
          {"uninstall": [{"quit": "com.example.twin"}]}], "depends_on": {}},
        {"token": "twin-b", "version": "1", "artifacts": [{"app": ["B.app"]},
          {"uninstall": [{"quit": "com.example.twin"}]}], "depends_on": {}}
      ]
      """
    let entries = try JSONDecoder().decode(
      [UpdateRepository.Entry].self, from: Data(catalogue.utf8))
    let index = UpdateRepository.caskTokensByIdentifier(entries)
    func token(_ id: String) -> String? {
      try? CatalogueInstall.token(for: id, candidates: Array(index[id] ?? []))
    }
    XCTAssertEqual(token("com.example.fixture"), "fixture")
    XCTAssertNil(token("com.example.renamed"), "a name match without identifier evidence")
    XCTAssertNil(token("com.example.twin"), "duplicate identifier")
    XCTAssertThrowsError(
      try CatalogueInstall.token(for: "com.hnc.Discord", candidates: ["discord"]))
    let discord = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "Discord",
      bundleIdentifier: "com.hnc.Discord", fileURL: URL(fileURLWithPath: "/tmp/Discord.app"),
      source: .homebrew)
    XCTAssertThrowsError(
      try CatalogueInstall.checkScope(of: discord, copies: ["/tmp/Discord.app"], writable: true))
  }

  /// The check decides `install` only when identity, scope and the fresh shape hold, and only
  /// for the cask whose version the row shows.
  func testCheckTimePlanNeedsEveryRule() async throws {
    let scene = try scene()
    let data = try cask(url: "https://example.com/a.zip", sha256: String(repeating: "a", count: 64))
    let check = CatalogueInstallCheck(
      fetchCask: { _ in data }, copies: walk(scene), isWritable: { _ in true }, assess: { _ in })
    let newer = Version(versionNumber: "1.1", buildNumber: nil)
    func plan(
      _ check: CatalogueInstallCheck, tokens: [String] = ["fixture"], matched: String = "fixture"
    )
      async -> String?
    {
      await check.plan(
        for: scene.bundle, candidateTokens: tokens, matchedToken: matched, catalogueVersion: newer)?
        .token
    }
    let accepted = await plan(check)
    XCTAssertEqual(accepted, "fixture")
    let mismatched = await plan(check, matched: "other")
    XCTAssertNil(mismatched, "the row's version came from another cask")
    let duplicate = await plan(check, tokens: ["fixture", "fixture-beta"])
    XCTAssertNil(duplicate)
    var locked = check
    locked.isWritable = { _ in false }
    let notWritable = await plan(locked)
    XCTAssertNil(notWritable)
    var noCheck = check
    let noCheckData = try cask(url: "https://example.com/a.zip", sha256: "no_check")
    noCheck.fetchCask = { _ in noCheckData }
    let unverifiable = await plan(noCheck)
    XCTAssertNil(unverifiable)
  }
}
