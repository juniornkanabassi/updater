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
    calls: Calls = Calls(), journal: TransactionJournal? = nil
  ) async throws -> UpdateJobRecord {
    var check = CatalogueInstallCheck(
      fetchCask: { _ in
        calls.fetches.withLock { $0 += 1 }
        return cask
      }, copies: walk(scene), isWritable: { _ in true }, ownership: { _, _ in .notOwned },
      assess: { _ in })
    transform(&check)
    let operation = AppDownloadUpdateOperation(
      app: scene.bundle,
      catalogue: CatalogueJob(
        token: "fixture", minimumVersion: Version(versionNumber: "1.1", buildNumber: nil),
        check: check))
    operation.requiresTeam = requiresTeam
    operation.launchProbe = { try FixtureApp.launchProbe($0) }
    operation.lifecycle = lifecycle
    if let journal { operation.journal = journal }
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

  /// The job stages in Updater's backup folder. Where the walk can see that folder (a
  /// watched folder on another volume keeps it beside the app), the recheck excludes exactly
  /// this job's staging folder, so the install still goes ahead.
  func testOwnStagedCandidateIsNotASecondCopy() async throws {
    let scene = try scene()
    let server = try await LocalFileServer.start(serving: scene.payloads)
    defer { server.stop() }
    let (name, hash) = try payload(in: scene, kind: .zip)
    let journal = TransactionJournal(root: try disposableDirectory())
    let seen = Mutex<[Set<String>]>([])
    let folders = [scene.apps, journal.backups]
    let record = try await install(
      scene,
      cask: try cask(url: server.baseURL.appendingPathComponent(name).absoluteString, sha256: hash),
      check: {
        $0.copies = { id in
          let found = try AppStoreInstallGate.copies(of: id, in: folders)
          seen.withLock { $0.append(found) }
          return found
        }
      }, journal: journal)
    XCTAssertEqual(record.outcome, .updated(from: "1.0", to: "1.1"))
    XCTAssertTrue(
      seen.withLock { $0 }.contains { $0.contains { $0.hasPrefix(journal.backups.path) } },
      "the walk did see the staged candidate")
    XCTAssertTrue(journal.pending().isEmpty, "the replacement's journal record is gone")
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
      try? CatalogueInstall.token(for: catalogueBundle(id), candidates: Array(index[id] ?? []))
    }
    XCTAssertEqual(token("com.example.fixture"), "fixture")
    XCTAssertNil(token("com.example.renamed"), "a name match without identifier evidence")
    XCTAssertNil(token("com.example.twin"), "duplicate identifier")
    XCTAssertThrowsError(
      try CatalogueInstall.token(for: catalogueBundle("com.hnc.Discord"), candidates: ["discord"]))
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
      fetchCask: { _ in data }, copies: walk(scene), isWritable: { _ in true },
      ownership: { _, _ in .notOwned }, assess: { _ in })
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

  // MARK: Sol's inspection (R5B)

  /// R5B-001: an ownership query that fails is unknown, not "not owned": no catalogue
  /// decision and no replacement, rechecked freshly right before replacing.
  func testFailedBrewOwnershipQueryNeverAllowsADirectReplacement() async throws {
    let scene = try scene()
    let failing = try disposableDirectory().appendingPathComponent("brew")
    try "#!/bin/sh\nexit 1\n".write(to: failing, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failing.path)
    let brew = Homebrew(brew: failing, logDirectory: try disposableDirectory())
    let unknown = await brew.ownership(of: scene.installed, fresh: true)
    XCTAssertEqual(unknown, .unknown)
    let none = await Homebrew(brew: nil).ownership(of: scene.installed)
    XCTAssertEqual(none, .notOwned, "no brew installed: nothing can own it")

    let data = try cask(url: "https://example.com/a.zip", sha256: String(repeating: "a", count: 64))
    let check = CatalogueInstallCheck(
      fetchCask: { _ in data }, copies: walk(scene), isWritable: { _ in true },
      ownership: { app, fresh in await brew.ownership(of: app, fresh: fresh) }, assess: { _ in })
    let decided = await check.plan(
      for: scene.bundle, candidateTokens: ["fixture"], matchedToken: "fixture",
      catalogueVersion: Version(versionNumber: "1.1", buildNumber: nil))
    XCTAssertNil(decided, "unknown ownership offers no install")

    // Offered while brew answered, then the fresh query before replacing fails.
    let server = try await LocalFileServer.start(serving: scene.payloads)
    defer { server.stop() }
    let (name, hash) = try payload(in: scene, kind: .zip)
    let before = try FixtureApp.digest(scene.installed)
    let record = try await install(
      scene,
      cask: try cask(url: server.baseURL.appendingPathComponent(name).absoluteString, sha256: hash),
      check: {
        $0.ownership = { app, fresh in
          fresh ? await brew.ownership(of: app, fresh: true) : .notOwned
        }
      })
    XCTAssertEqual(record.outcome, .handedOff)
    XCTAssertEqual(record.handOff?.opened, false)
    XCTAssertEqual(try FixtureApp.digest(scene.installed), before, "no direct replacement")
  }

  /// R5B-002: the identity index comes from every cask, including one without app names, and
  /// survives the compact cache.
  func testIdentityIndexCountsCasksWithoutAppNamesThroughLoadingAndTheCache() throws {
    let catalogue = """
      [
        {"token": "fixture", "version": "1.1", "artifacts": [{"app": ["Fixture.app"]},
          {"uninstall": [{"quit": "com.juniornkanabassi.updater-fixture"}]}], "depends_on": {}},
        {"token": "fixture-suite", "version": "3", "artifacts": [{"pkg": ["Suite.pkg"]},
          {"uninstall": [{"quit": "com.juniornkanabassi.updater-fixture"}]}], "depends_on": {}}
      ]
      """
    let data = Data(catalogue.utf8)
    let cache = UpdateRepositoryCompactIndexCache(
      cacheURL: try disposableDirectory().appendingPathComponent("compact.plist"))
    let fresh = try UpdateRepository.decodeCatalogue(data, cache: cache)
    XCTAssertFalse(fresh.usedCompactIndex)
    XCTAssertEqual(fresh.appEntries.map(\.token), ["fixture"], "name matching sees only app casks")
    XCTAssertEqual(fresh.identityIndex[identifier], ["fixture", "fixture-suite"])
    let cached = try UpdateRepository.decodeCatalogue(data, cache: cache)
    XCTAssertTrue(cached.usedCompactIndex)
    XCTAssertEqual(cached.identityIndex, fresh.identityIndex)
    XCTAssertThrowsError(
      try CatalogueInstall.token(
        for: catalogueBundle(identifier), candidates: Array(cached.identityIndex[identifier] ?? []))
    )
  }

  // MARK: Plan additions (2 Nov 2026)

  /// A. Channel variants are told apart only by positive evidence of the installed channel.
  func testChannelRuleNeedsPositiveEvidenceAndMatchesExactly() throws {
    let t3 = ["t3-code", "t3-code@nightly", "t3-code@beta"]
    let nightly = catalogueBundle(
      "com.t3tools.t3code", name: "T3 Code (Nightly)", version: "0.1.7-nightly.20261031.3991")
    XCTAssertEqual(try CatalogueInstall.token(for: nightly, candidates: t3), "t3-code@nightly")
    XCTAssertThrowsError(
      try CatalogueInstall.token(for: nightly, candidates: ["t3-code", "t3-code@beta"]),
      "a nightly never takes @beta")
    let beta = catalogueBundle("app.freeshow", name: "FreeShow Beta", version: "1.6.7")
    XCTAssertEqual(
      try CatalogueInstall.token(for: beta, candidates: ["freeshow", "freeshow@beta"]),
      "freeshow@beta",
      "a channel word in the name, numbers-only version")
    let release = catalogueBundle("app.freeshow", name: "FreeShow", version: "1.6.7")
    XCTAssertEqual(
      try CatalogueInstall.token(for: release, candidates: ["freeshow", "freeshow@beta"]),
      "freeshow")
    let prerelease = catalogueBundle("app.freeshow", name: "FreeShow", version: "1.7.0-rc1")
    XCTAssertThrowsError(
      try CatalogueInstall.token(for: prerelease, candidates: ["freeshow", "freeshow@beta"]),
      "no channel evidence and a prerelease version keep the current route")
    let conflicting = catalogueBundle("app.freeshow", name: "FreeShow Beta Nightly", version: "1.7")
    XCTAssertThrowsError(
      try CatalogueInstall.token(
        for: conflicting, candidates: ["freeshow", "freeshow@beta", "freeshow@nightly"]))
    XCTAssertThrowsError(
      try CatalogueInstall.token(
        for: catalogueBundle("com.microsoft.VSCode", name: "Code", version: "1.144.0"),
        candidates: ["visual-studio-code", "tidgi"]),
      "two different products are not channels")
    XCTAssertEqual(
      CatalogueInstall.channelEvidence(of: catalogueBundle("dev.zed.Zed", name: "Zed")), [],
      "a dev top-level domain is not a channel")
  }

  /// B. `sha256 :no_check` installs only from the vendor's own domain, and only when every
  /// Trust check passes (here: the same signing identity, then a required Team ID that an
  /// ad-hoc candidate cannot match).
  func testNoCheckDownloadsNeedTheVendorDomainAndEveryTrustCheck() async throws {
    let scene = try scene()
    let server = try await LocalFileServer.start(serving: scene.payloads)
    defer { server.stop() }
    let (name, _) = try payload(in: scene, kind: .zip)
    let url = server.baseURL.appendingPathComponent(name).absoluteString
    let ours = try cask(url: url, sha256: "no_check", extra: ["homepage": "http://127.0.0.1/"])
    XCTAssertNil(
      try CatalogueInstall.release(fromCask: ours, bundleIdentifier: identifier).sha256)
    XCTAssertThrowsError(
      try CatalogueInstall.release(
        fromCask: try cask(
          url: url, sha256: "no_check", extra: ["homepage": "https://vendor.example/"]),
        bundleIdentifier: identifier),
      "not on the vendor's own domain")
    XCTAssertEqual(CatalogueInstall.registrableDomain("cdn.rogueamoeba.com"), "rogueamoeba.com")
    XCTAssertEqual(CatalogueInstall.registrableDomain("dl.vendor.co.uk"), "vendor.co.uk")

    let before = try FixtureApp.digest(scene.installed)
    let refused = try await install(scene, cask: ours, requiresTeam: true)
    guard case .failed = refused.outcome else { return XCTFail("without a matching Team ID") }
    XCTAssertEqual(try FixtureApp.digest(scene.installed), before)
    let allowed = try await install(scene, cask: ours)
    XCTAssertEqual(allowed.outcome, .updated(from: "1.0", to: "1.1"), "matching identity")
  }

  /// Opt-in, read-only: which apps on this Mac the catalogue rules would install today. It reads
  /// the real catalogue, fresh per-cask entries (metadata only) and the folder walk; it never
  /// downloads a payload or changes anything. Payload and trust rules are judged at install.
  func testLiveCatalogueEligibilityReport() async throws {
    guard ProcessInfo.processInfo.environment["UPDATER_LIVE_CATALOGUE_REPORT"] == "1" else {
      throw XCTSkip("Set UPDATER_LIVE_CATALOGUE_REPORT=1 for the read-only catalogue report.")
    }
    let repository = UpdateRepository.newRepository()
    let check = CatalogueInstallCheck.live
    let folders = ["/Applications", NSHomeDirectory() + "/Applications"]
    var lines = [String]()
    for folder in folders {
      for bundle in BundleCollector.collectBundles(at: URL(fileURLWithPath: folder)) {
        guard let entry = await repository.entry(for: bundle),
          bundle.version.comparisonForUpdate(to: entry.version) == .older
        else { continue }
        let tokens = await repository.caskTokens(withBundleIdentifier: bundle.bundleIdentifier)
        var verdict = "install"
        do {
          guard await check.ownership(bundle.fileURL, false) == .notOwned else {
            throw CatalogueInstall.Refusal.scope("brew owns it, or could not be asked")
          }
          let token = try CatalogueInstall.token(for: bundle, candidates: tokens)
          guard token == entry.token else {
            throw CatalogueInstall.Refusal.identity(
              "index names \(token), row shows \(entry.token)")
          }
          try CatalogueInstall.checkScope(
            of: bundle, copies: try check.copies(bundle.bundleIdentifier),
            writable: check.isWritable(bundle.fileURL.deletingLastPathComponent()))
          let release = try CatalogueInstall.release(
            fromCask: try await check.fetchCask(token), bundleIdentifier: bundle.bundleIdentifier)
          verdict +=
            " (\(token) \(release.version.versionNumber ?? "?") from \(release.url.host() ?? "?")\(release.sha256 == nil ? ", no published checksum: trust checks decide" : ""))"
        } catch {
          verdict = "keeps its route: \(error.localizedDescription)"
        }
        lines.append(
          "\(bundle.name) | \(bundle.bundleIdentifier) | cask \(entry.token) | evidence \(tokens) | \(verdict)"
        )
      }
    }
    print(
      "CATALOGUE-REPORT-BEGIN\n" + lines.sorted().joined(separator: "\n") + "\nCATALOGUE-REPORT-END"
    )
  }
}

/// A plain-release bundle for identity checks: only the ID, name and version matter.
func catalogueBundle(
  _ identifier: String, name: String = "App", version: String = "1.0"
) -> App.Bundle {
  App.Bundle(
    version: Version(versionNumber: version, buildNumber: nil), name: name,
    bundleIdentifier: identifier, fileURL: URL(fileURLWithPath: "/tmp/\(name).app"),
    source: .homebrew, modificationDate: .distantPast)
}
