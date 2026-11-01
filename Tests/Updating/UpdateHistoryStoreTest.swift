// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import XCTest

#if LATEST_HOSTED_TESTS
  @testable import Latest
#endif

final class UpdateHistoryStoreTest: XCTestCase {
  private func bundle(
    _ path: String, id: String = "com.example.fixture", version: String = "1.0",
    build: String? = "100"
  ) -> App.Bundle {
    App.Bundle(
      version: Version(versionNumber: version, buildNumber: build), name: "Fixture",
      bundleIdentifier: id, fileURL: URL(fileURLWithPath: path), source: .sparkle,
      modificationDate: .distantPast)
  }

  func testOutcomesPersistAcrossStoreInstancesAndSkipTornLines() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Updater/history.jsonl")
    let app = bundle("/tmp/Fixture.app")
    let other = bundle("/tmp/Other/Fixture.app")

    let store = UpdateHistoryStore(fileURL: file)
    store.record(UpdateHistoryEntry(bundle: app, outcome: .updated(from: "0.9", to: "1.0")))
    store.record(
      UpdateHistoryEntry(bundle: app, outcome: .failed(reason: "Signature changed", logPath: nil)))
    store.record(UpdateHistoryEntry(bundle: other, outcome: .handedOff))
    // Simulate a crash mid-write.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"appPath\":".utf8))
    try handle.close()

    let reloaded = UpdateHistoryStore(fileURL: file)
    XCTAssertEqual(
      reloaded.latestEntry(for: app.fileURL)?.outcome,
      .failed(reason: "Signature changed", logPath: nil))
    XCTAssertEqual(reloaded.latestEntry(for: other.fileURL)?.outcome, .handedOff)
    XCTAssertNil(reloaded.latestEntry(for: URL(fileURLWithPath: "/tmp/Missing.app")))

    // Sol R10: an entry appended after the torn fragment must survive the next reload.
    reloaded.record(UpdateHistoryEntry(bundle: app, outcome: .needsQuit))
    XCTAssertEqual(
      UpdateHistoryStore(fileURL: file).latestEntry(for: app.fileURL)?.outcome, .needsQuit)
  }

  /// Sol R11: a recorded outcome describes one product at one full version (short + build).
  func testEntryMatchesOnlyTheSameProductPathAndFullVersion() {
    let entry = UpdateHistoryEntry(
      bundle: bundle("/tmp/A.app"), outcome: .failed(reason: "x", logPath: nil))
    XCTAssertTrue(entry.describes(bundle("/tmp/A.app")))
    XCTAssertFalse(entry.describes(bundle("/tmp/A.app", build: "101")), "new build")
    XCTAssertFalse(entry.describes(bundle("/tmp/A.app", id: "com.example.other")), "other app")
    XCTAssertFalse(entry.describes(bundle("/tmp/A.app", version: "1.1")))
    XCTAssertFalse(entry.describes(bundle("/tmp/B.app")))
  }

  @MainActor
  func testCapabilityFollowsTheSourceAction() {
    XCTAssertEqual(makeTestApp(name: "A", version: "1", remoteVersion: "2").capability, .install)
    let external = makeTestApp(
      name: "B", version: "1", remoteVersion: "2", updateAction: .external(label: "Store") { _ in })
    XCTAssertEqual(external.capability, .handOff)
    let bundle = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "C",
      bundleIdentifier: "com.example.c", fileURL: URL(fileURLWithPath: "/tmp/C.app"),
      source: .none, modificationDate: .distantPast)
    XCTAssertEqual(App(bundle: bundle, update: nil, isIgnored: false).capability, .unsupported)
    XCTAssertTrue(UpdateCapability.vendorTool.isAutomatic)
    XCTAssertFalse(UpdateCapability.handOff.isAutomatic)
  }
}
