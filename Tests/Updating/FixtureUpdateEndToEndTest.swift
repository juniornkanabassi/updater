// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import CryptoKit
import Network
import Synchronization
import XCTest

@testable import Latest

/// Round 1 proof: disposable fixture apps updated from a local appcast served on 127.0.0.1,
/// through the real download operation, scheduler, transaction and history store.
final class FixtureUpdateEndToEndTest: XCTestCase {
  private struct Setup {
    let root: URL
    let installed: URL
    let otherCopy: URL
    let server: LocalFileServer
    let history: UpdateHistoryStore
    let queue: UpdateQueue
  }

  private func makeSetup(candidateLaunches: Bool = true) async throws -> Setup {
    let root = try disposableDirectory()
    let installed = try FixtureApp.make(in: root.appendingPathComponent("Copy A"), version: "1.0")
    let otherCopy = try FixtureApp.make(in: root.appendingPathComponent("Copy B"), version: "1.0")
    let build = root.appendingPathComponent("build")
    let feed = root.appendingPathComponent("feed")
    try FileManager.default.createDirectory(at: feed, withIntermediateDirectories: true)
    let candidate = try FixtureApp.make(in: build, version: "1.1", launches: candidateLaunches)
    let archive = feed.appendingPathComponent("Fixture-1.1.zip")
    try FixtureApp.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", candidate.path, archive.path])
    let server = try await LocalFileServer.start(serving: feed)
    addTeardownBlock { server.stop() }
    let sha = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }
      .joined()
    try """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><item>
        <title>1.1</title>
        <sparkle:version>1.1</sparkle:version>
        <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
        <enclosure url="\(server.baseURL.appendingPathComponent("Fixture-1.1.zip").absoluteString)"
          sparkle:sha256="\(sha)" type="application/octet-stream"/>
      </item></channel>
    </rss>
    """.write(to: feed.appendingPathComponent("appcast.xml"), atomically: true, encoding: .utf8)
    let history = UpdateHistoryStore(fileURL: root.appendingPathComponent("history.jsonl"))
    return Setup(
      root: root, installed: installed, otherCopy: otherCopy, server: server, history: history,
      queue: UpdateQueue(history: history))
  }

  private func operation(for setup: Setup, lifecycle: AppLifecycle = .notRunning) throws
    -> AppDownloadUpdateOperation
  {
    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: setup.installed))
    let appcast = setup.server.baseURL.appendingPathComponent("appcast.xml")
    let operation = AppDownloadUpdateOperation(app: bundle) {
      try await LocalAppcast.release(from: appcast)
    }
    operation.requiresTeam = false
    operation.launchProbe = { try FixtureApp.launchProbe($0) }
    operation.lifecycle = lifecycle
    return operation
  }

  private func run(_ operation: AppDownloadUpdateOperation, in setup: Setup) async throws
    -> UpdateOutcome?
  {
    let done = expectation(description: "update finished")
    operation.completionBlock = { done.fulfill() }
    setup.queue.submit(operation)
    await fulfillment(of: [done], timeout: 60)
    for _ in 0..<200 where setup.history.latestEntry(for: setup.installed) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    return setup.history.latestEntry(for: setup.installed)?.outcome
  }

  func testFixtureUpdatesFromLocalAppcastAndOnlyTheSelectedCopyChanges() async throws {
    let setup = try await makeSetup()
    let otherBefore = try FixtureApp.digest(setup.otherCopy)
    let outcome = try await run(try operation(for: setup), in: setup)
    XCTAssertEqual(outcome, .updated(from: "1.0", to: "1.1"))
    // The row's version comes from the bundle on disk at the exact URL.
    XCTAssertEqual(BundleCollector.collectBundle(at: setup.installed)?.version.versionNumber, "1.1")
    XCTAssertEqual(try FixtureApp.digest(setup.otherCopy), otherBefore, "other copy untouched")
    XCTAssertEqual(
      BundleCollector.collectBundle(at: setup.otherCopy)?.version.versionNumber, "1.0")
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: setup.installed.deletingLastPathComponent().path)
    XCTAssertEqual(leftovers, ["Fixture.app"], "no backup or stage left behind")
  }

  func testFailureAfterTheSwapRestoresTheOriginalAndStaysVisibleAfterReload() async throws {
    // The candidate is correctly signed and versioned but will not launch, which only the
    // post-swap probe detects.
    let setup = try await makeSetup(candidateLaunches: false)
    let before = try FixtureApp.digest(setup.installed)
    let outcome = try await run(try operation(for: setup), in: setup)
    guard case .failed(let reason, _) = outcome else {
      return XCTFail("Expected a failed outcome, got \(String(describing: outcome))")
    }
    XCTAssertTrue(reason.contains("did not launch"), reason)
    XCTAssertEqual(try FixtureApp.digest(setup.installed), before, "restored byte-for-byte")
    // A fresh queue and store, as after the list reloads or Updater relaunches.
    let reloaded = UpdateQueue(history: UpdateHistoryStore(fileURL: setup.history.fileURL))
    guard case .error(let error) = reloaded.state(for: setup.installed) else {
      return XCTFail("The failure must stay on the row after a reload")
    }
    XCTAssertTrue(error.localizedDescription.contains("did not launch"))
  }

  func testAppThatRefusesToQuitGetsNoReplacement() async throws {
    let setup = try await makeSetup()
    let before = try FixtureApp.digest(setup.installed)
    let refusing = AppLifecycle(
      runningApps: { _ in [.init(terminate: {}, isTerminated: { false })] },
      confirmQuit: { _ in true }, reopen: { _ in XCTFail("Never quit, never reopened") },
      timeout: .milliseconds(300))
    let outcome = try await run(try operation(for: setup, lifecycle: refusing), in: setup)
    XCTAssertEqual(outcome, .needsQuit)
    XCTAssertEqual(try FixtureApp.digest(setup.installed), before)
  }
}

extension AppLifecycle {
  static let notRunning = AppLifecycle(
    runningApps: { _ in [] }, confirmQuit: { _ in true }, reopen: { _ in })
}

/// Reads the first item of a Sparkle appcast from the fixture server.
private enum LocalAppcast {
  static func release(from url: URL) async throws -> AppDownloadRelease {
    let (data, _) = try await URLSession.shared.data(from: url)
    let parser = XMLParser(data: data)
    let delegate = Delegate()
    parser.delegate = delegate
    guard parser.parse(), let enclosure = delegate.enclosure,
      let address = enclosure["url"], let file = URL(string: address)
    else { throw AppDownloadError.invalidMetadata }
    return AppDownloadRelease(
      version: Version(versionNumber: delegate.shortVersion, buildNumber: delegate.version),
      url: file, sha256: enclosure["sparkle:sha256"], appPath: "Fixture.app")
  }

  private final class Delegate: NSObject, XMLParserDelegate {
    var enclosure: [String: String]?
    var version: String?
    var shortVersion: String?
    private var text = ""

    func parser(
      _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String] = [:]
    ) {
      text = ""
      if name == "enclosure" { enclosure = attributes }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(
      _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if name == "sparkle:version" { version = value }
      if name == "sparkle:shortVersionString" { shortVersion = value }
    }
  }
}

/// Minimal HTTP/1.1 static file server on 127.0.0.1 for fixture feeds.
final class LocalFileServer: Sendable {
  private let listener: NWListener
  private let root: URL
  private let queue = DispatchQueue(label: "updater.tests.file-server")
  let baseURL: URL

  private init(listener: NWListener, root: URL, port: UInt16) {
    self.listener = listener
    self.root = root
    baseURL = URL(string: "http://127.0.0.1:\(port)")!
  }

  static func start(serving root: URL) async throws -> LocalFileServer {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let ready = AsyncStream<UInt16?>.makeStream()
    listener.stateUpdateHandler = { state in
      switch state {
      case .ready: ready.continuation.yield(listener.port?.rawValue)
      case .failed, .cancelled: ready.continuation.yield(nil)
      default: break
      }
    }
    let box = Mutex<LocalFileServer?>(nil)
    listener.newConnectionHandler = { connection in box.withLock { $0 }?.serve(connection) }
    listener.start(queue: DispatchQueue(label: "updater.tests.file-server.listener"))
    var port: UInt16?
    for await value in ready.stream {
      port = value
      break
    }
    guard let port else { throw URLError(.cannotConnectToHost) }
    let server = LocalFileServer(listener: listener, root: root, port: port)
    box.withLock { $0 = server }
    return server
  }

  func stop() { listener.cancel() }

  private func serve(_ connection: NWConnection) {
    connection.start(queue: queue)
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [root] data, _, _, _ in
      let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
      let file = root.appendingPathComponent(String(path.dropFirst()))
      let body = (!path.contains("..") ? try? Data(contentsOf: file) : nil)
      let status = body == nil ? "404 Not Found" : "200 OK"
      var response = Data(
        "HTTP/1.1 \(status)\r\nContent-Length: \(body?.count ?? 0)\r\nConnection: close\r\n\r\n"
          .utf8)
      response.append(body ?? Data())
      connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
  }
}
