// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import XCTest

#if LATEST_HOSTED_TESTS
  @testable import Latest
#endif

final class UpdateHistoryStoreTest: XCTestCase {
  func testOutcomesPersistAcrossStoreInstancesAndSkipTornLines() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("Updater/history.jsonl")
    let app = URL(fileURLWithPath: "/tmp/Fixture.app")
    let other = URL(fileURLWithPath: "/tmp/Other/Fixture.app")

    let store = UpdateHistoryStore(fileURL: file)
    store.record(
      UpdateHistoryEntry(
        appPath: app.path, bundleIdentifier: "com.example.fixture", installedVersion: "1.0",
        outcome: .updated(from: "0.9", to: "1.0")))
    store.record(
      UpdateHistoryEntry(
        appPath: app.path, bundleIdentifier: "com.example.fixture", installedVersion: "1.0",
        outcome: .failed(reason: "Signature changed", logPath: nil)))
    store.record(
      UpdateHistoryEntry(
        appPath: other.path, bundleIdentifier: "com.example.fixture", installedVersion: "1.0",
        outcome: .handedOff))
    // Simulate a crash mid-write.
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"appPath\":".utf8))
    try handle.close()

    let reloaded = UpdateHistoryStore(fileURL: file)
    XCTAssertEqual(
      reloaded.latestEntry(for: app)?.outcome, .failed(reason: "Signature changed", logPath: nil))
    XCTAssertEqual(reloaded.latestEntry(for: other)?.outcome, .handedOff)
    XCTAssertNil(reloaded.latestEntry(for: URL(fileURLWithPath: "/tmp/Missing.app")))
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
