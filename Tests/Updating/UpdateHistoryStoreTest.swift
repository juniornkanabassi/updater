// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import Synchronization
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
    store.record(
      UpdateHistoryEntry(before: app, after: app, outcome: .updated(from: "0.9", to: "1.0")))
    store.record(
      UpdateHistoryEntry(
        before: app, after: app, outcome: .failed(reason: "Signature changed", logPath: nil)))
    store.record(UpdateHistoryEntry(before: other, after: other, outcome: .handedOff))
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
    reloaded.record(UpdateHistoryEntry(before: app, after: app, outcome: .needsQuit))
    XCTAssertEqual(
      UpdateHistoryStore(fileURL: file).latestEntry(for: app.fileURL)?.outcome, .needsQuit)
  }

  func testRecordNotifiesAfterUnlockAndMakesTheRecordedEntryReadable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = UpdateHistoryStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let app = bundle("/tmp/History notification.app")
    let entry = UpdateHistoryEntry(before: app, after: app, outcome: .noChange(reason: nil))
    let received = Mutex<UpdateHistoryEntry?>(nil)
    let token = NotificationCenter.default.addObserver(
      forName: UpdateHistoryStore.didRecordNotification, object: store, queue: nil
    ) { notification in
      // A synchronous observer can re-enter the store only after record releases its mutex.
      let readable = store.latestEntry(for: app.fileURL)
      let published = notification.userInfo?[UpdateHistoryStore.entryKey] as? UpdateHistoryEntry
      XCTAssertEqual(readable, published)
      received.withLock { $0 = published }
    }
    defer { NotificationCenter.default.removeObserver(token) }
    store.record(entry)
    XCTAssertEqual(received.withLock { $0 }, entry)
  }

  /// Sol R11: a recorded outcome describes one product at one full version (short + build).
  func testEntryMatchesOnlyTheSameProductPathAndFullVersion() {
    let entry = UpdateHistoryEntry(
      before: bundle("/tmp/A.app", version: "0.9"), after: bundle("/tmp/A.app"),
      outcome: .failed(reason: "x", logPath: nil))
    // Sol R4 (second pass): the failure follows the bundle left after the attempt, not
    // the one it started from.
    XCTAssertTrue(entry.describes(bundle("/tmp/A.app")))
    XCTAssertFalse(entry.describes(bundle("/tmp/A.app", version: "0.9")), "starting version")
    XCTAssertFalse(entry.describes(bundle("/tmp/A.app", build: "101")), "new build")
    XCTAssertFalse(entry.describes(bundle("/tmp/A.app", id: "com.example.other")), "other app")
    XCTAssertFalse(entry.describes(bundle("/tmp/A.app", version: "1.1")))
    XCTAssertFalse(entry.describes(bundle("/tmp/B.app")))
  }

  /// Sol R2-005: an administrator need reads as such, not as App Management.
  func testAdministratorOutcomeHasItsOwnWording() {
    let admin = UpdateOutcomeError(outcome: .needsPermission(kind: "administrator"))
    XCTAssertTrue(admin?.errorDescription?.contains("administrator rights") == true)
    XCTAssertFalse(admin?.errorDescription?.contains("App Management") == true)
    let management = UpdateOutcomeError(outcome: .needsPermission(kind: "appManagement"))
    XCTAssertTrue(management?.errorDescription?.contains("App Management") == true)
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
