// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

/// The recursive FSEvents watcher on a disposable folder: a changed bundle is re-read on its
/// own, while new and removed apps rescan the folder.
final class AppDirectoryWatcherTest: XCTestCase {
  private final class Counts: Sendable {
    let fullScans = Mutex(0)
    let reads = Mutex<[String]>([])
    let notifications = Mutex(0)
  }

  func testChangedBundleIsRescannedAloneAndAddedOrRemovedAppsFollow() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0", signed: false)
    let counts = Counts()
    let ready = expectation(description: "initial scan")
    let directory = AppDirectory(
      url: root, notifyOnInitialCollection: false,
      initialCollectionCompletion: { ready.fulfill() },
      bundleCollector: { url in
        counts.fullScans.withLock { $0 += 1 }
        return BundleCollector.collectBundles(at: url)
      },
      bundleReader: { url in
        counts.reads.withLock { $0.append(url.lastPathComponent) }
        return BundleCollector.collectBundle(at: url)
      },
      debounce: 0.3,
      updateHandler: { counts.notifications.withLock { $0 += 1 } })
    await fulfillment(of: [ready], timeout: 5)
    XCTAssertEqual(directory.bundles.map(\.version.versionNumber), ["1.0"])
    let scannedURL = directory.bundles.first?.fileURL
    // Events from making the fixture can still arrive; let them settle before measuring.
    try await Task.sleep(for: .seconds(1))
    let baseline = counts.fullScans.withLock { $0 }
    counts.reads.withLock { $0.removeAll() }

    // Modify: only that app is read again.
    let plist = app.appendingPathComponent("Contents/Info.plist")
    var info = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
        as? [String: Any])
    info["CFBundleShortVersionString"] = "1.1"
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: plist)
    try await waitUntil { directory.bundles.first?.version.versionNumber == "1.1" }
    XCTAssertEqual(
      counts.fullScans.withLock { $0 }, baseline, "a changed bundle is not a full rescan")
    XCTAssertEqual(Set(counts.reads.withLock { $0 }), ["Fixture.app"])
    XCTAssertEqual(directory.bundles.first?.fileURL, scannedURL, "the row keeps its identity")
    XCTAssertGreaterThan(counts.notifications.withLock { $0 }, 0)

    // Add: a new app appears, from a nested folder too.
    let nested = root.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FixtureApp.make(
      in: nested, name: "Other", identifier: "com.example.other", version: "2.0", signed: false)
    try await waitUntil { directory.bundles.count == 2 }

    // Remove: the app leaves the list.
    try FileManager.default.removeItem(at: nested.appendingPathComponent("Other.app"))
    try await waitUntil { directory.bundles.count == 1 }
    XCTAssertEqual(directory.bundles.first?.name, "Fixture")
  }

  func testEventPathsMapToTheirOutermostApp() {
    let root = URL(fileURLWithPath: "/Applications")
    XCTAssertEqual(
      AppDirectory.changedApps(
        in: [
          "/Applications/Warp.app/Contents/", "/Applications/Tools/Zed.app/Contents/Helpers/X.app/",
        ],
        below: root),
      [root.appendingPathComponent("Warp.app"), root.appendingPathComponent("Tools/Zed.app")])
    XCTAssertNil(
      AppDirectory.changedApps(in: ["/Applications/Warp.app/", "/Applications/"], below: root),
      "a change to the folder itself rescans it")
    XCTAssertNil(AppDirectory.changedApps(in: ["/Users/x/Warp.app/"], below: root))
  }

  private func waitUntil(
    timeout: Duration = .seconds(10), _ condition: @escaping () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
      try await Task.sleep(for: .milliseconds(50))
    }
  }
}
