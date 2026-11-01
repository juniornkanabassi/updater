//
//  BundleCollectorTest.swift
//  Latest Tests
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

final class BundleCollectorTest: XCTestCase {
  func testRemovingAnObservedDirectoryPublishesTheRemainingApps() async throws {
    let first = try makeTemporaryDirectory()
    let second = try makeTemporaryDirectory()
    for (name, directory) in [("First", first), ("Second", second)] {
      _ = try makeAppBundle(
        named: name, in: directory,
        info: [
          "CFBundleName": name, "CFBundleIdentifier": "test.directory." + name,
          "CFBundleShortVersionString": "1.0",
        ])
    }
    let store = LibraryDirectoryStore(urls: [first, second])
    let initial = expectation(description: "Both directories published")
    let removed = expectation(description: "Removed directory no longer published")
    initial.assertForOverFulfill = false
    removed.assertForOverFulfill = false
    let library = AppLibrary(directoryStoreFactory: { _ in store }) { apps in
      let names = Set(apps.map(\.name))
      if names == ["First", "Second"] { initial.fulfill() }
      if names == ["First"] { removed.fulfill() }
    }
    library.startQuery()
    await fulfillment(of: [initial], timeout: 3)
    store.remove(second)
    library.startQuery()
    await fulfillment(of: [removed], timeout: 3)
    XCTAssertEqual(library.bundles.map(\.name), ["First"])
  }

  func testDeltaUsesMainApplicationVersionAndRefreshesInPlace() throws {
    let directory = try makeTemporaryDirectory()
    let appURL = try makeAppBundle(
      named: "Delta", in: directory,
      info: [
        "CFBundleName": "Delta", "CFBundleIdentifier": "com.zed-industries.delta",
        "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0.1.0",
      ])
    let executable = appURL.appendingPathComponent("Contents/MacOS/delta-app")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    // The bundled CLI can lag behind the application and must never supply its version.
    try Data("delta 0.17.0".utf8).write(
      to: executable.deletingLastPathComponent().appendingPathComponent("delta"))
    let commit = "46d3f30ef08b184463af73f6247c295d95481f16"
    let cases = [
      ("\0delta_version0.18.0zed_username\0", "0.18.0"),
      ("\0delta_version0.18.2zed_username\0", "0.18.2"),
      // Current Rust builds concatenate the application version and source commit.
      (
        "\0png-0.18.1/src/encoder.rs\0delta_versiontenant_urlzed_username\0"
          + "0.19.1" + commit + "could not build HTTP client\0", "0.19.1"
      ),
      ("\0delta_versiontenant_urlzed_username\00.19.1\0", "0.1.0"),
      (
        "\00.19.1" + commit + "could not build HTTP client\0"
          + "0.19.0" + commit + "could not build HTTP client\0", "0.1.0"
      ),
      ("\00.19.1not-a-source-commitcould not build HTTP client\0", "0.1.0"),
      ("not version metadata", "0.1.0"),
    ]
    for (index, testCase) in cases.enumerated() {
      try Data(testCase.0.utf8).write(to: executable)
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: TimeInterval(index + 1))],
        ofItemAtPath: executable.path)
      XCTAssertEqual(
        BundleCollector.collectBundle(at: appURL)?.version.versionNumber, testCase.1,
        "Installed metadata case \(index)")
    }
  }

  func testObsidianUsesValidatedNewerPayloadAndDoesNotReuseInstallerBuildNumber() throws {
    let directory = try makeTemporaryDirectory()
    let updates = directory.appendingPathComponent("obsidian")
    try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
    let app = App.Bundle(
      version: Version(versionNumber: "1.13.7", buildNumber: "1.13.7"), name: "Obsidian",
      bundleIdentifier: "md.obsidian", fileURL: directory.appendingPathComponent("Obsidian.app"),
      source: .none)
    func writeArchive(filename: String, version: String) throws {
      let package = try JSONSerialization.data(withJSONObject: [
        "name": "obsidian-dev", "version": version,
      ])
      let header = try JSONSerialization.data(withJSONObject: [
        "files": [
          "main.js": ["size": 0, "offset": "0"],
          "package.json": ["size": package.count, "offset": "0"],
        ]
      ])
      var archive = Data()
      for value in [4, header.count + 8, header.count + 4, header.count] {
        var number = UInt32(value).littleEndian
        archive.append(Data(bytes: &number, count: 4))
      }
      archive.append(header)
      archive.append(package)
      try archive.write(to: updates.appendingPathComponent(filename))
    }
    try writeArchive(filename: "obsidian-1.14.4.asar", version: "1.14.4")
    // A higher filename alone is not evidence of an installed application version.
    try writeArchive(filename: "obsidian-9.0.0.asar", version: "1.14.4")
    try Data("truncated download".utf8).write(
      to: updates.appendingPathComponent("obsidian-8.0.0.asar"))
    let resolved = InstalledAppVersion.resolve(for: app, applicationSupport: directory)
    XCTAssertEqual(resolved.version.versionNumber, "1.14.4")
    XCTAssertNil(resolved.version.buildNumber)
    let update = App.Update(
      app: resolved, remoteVersion: Version(versionNumber: "1.13.7", buildNumber: "1.13.7"),
      minimumOSVersion: nil, source: .homebrew, date: nil, releaseNotes: nil,
      updateAction: .external(label: "Obsidian", block: { _ in }))
    XCTAssertFalse(update.updateAvailable, "An older installer must not replace a newer payload.")
    try FileManager.default.removeItem(at: updates.appendingPathComponent("obsidian-1.14.4.asar"))
    XCTAssertEqual(
      InstalledAppVersion.resolve(for: app, applicationSupport: directory).version.versionNumber,
      "1.13.7")
  }

  func testRenamedCodexBundleUsesCatalogedSparkleSource() throws {
    let directory = try makeTemporaryDirectory()
    let appURL = try makeAppBundle(
      named: "ChatGPT",
      in: directory,
      info: [
        "CFBundleName": "ChatGPT",
        "CFBundleExecutable": "ChatGPT",
        "CFBundleIdentifier": "com.openai.codex",
        "CFBundleShortVersionString": "26.707.51957",
        "CFBundleVersion": "5175",
      ]
    )

    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))

    XCTAssertEqual(bundle.source, .sparkle)
  }

  func testCollectsAppUsingDisplayNameWhenBundleNameIsMissing() throws {
    let directory = try makeTemporaryDirectory()
    let appURL = try makeAppBundle(
      named: "Display Name Only",
      in: directory,
      info: [
        "CFBundleDisplayName": "Display Name Only",
        "CFBundleExecutable": "Display Name Only",
        "CFBundleIdentifier": "com.example.display-name-only",
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "123",
      ]
    )

    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))

    XCTAssertEqual(bundle.name, "Display Name Only")
  }

  func testCollectsAppUsingBuildVersionWhenShortVersionIsMissing() throws {
    let directory = try makeTemporaryDirectory()
    let appURL = try makeAppBundle(
      named: "Build Version Only",
      in: directory,
      info: [
        "CFBundleName": "Build Version Only",
        "CFBundleExecutable": "Build Version Only",
        "CFBundleIdentifier": "com.example.build-version-only",
        "CFBundleVersion": "456",
      ]
    )

    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))

    XCTAssertEqual(bundle.version.buildNumber, "456")
    XCTAssertNil(bundle.version.versionNumber)
  }

  func testBundleModificationDateUsesContentsWhenPackageRootHasArchiveTimestamp() throws {
    let directory = try makeTemporaryDirectory()
    let appURL = try makeAppBundle(
      named: "Archive Timestamp",
      in: directory,
      info: [
        "CFBundleName": "Archive Timestamp",
        "CFBundleExecutable": "Archive Timestamp",
        "CFBundleIdentifier": "com.example.archive-timestamp",
        "CFBundleVersion": "1",
      ]
    )
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
    let archiveTimestamp = Date(timeIntervalSince1970: 315_504_000)
    let contentsTimestamp = Date(timeIntervalSince1970: 1_778_179_586)

    try setModificationDate(archiveTimestamp, for: appURL)
    try setModificationDate(contentsTimestamp, for: contentsURL)
    try setModificationDate(contentsTimestamp, for: infoPlistURL)

    let bundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))

    XCTAssertEqual(bundle.modificationDate, contentsTimestamp)
  }

  func testCollectingUpdatedBundleReadsCurrentInfoPlistVersions() throws {
    let directory = try makeTemporaryDirectory()
    let appURL = try makeAppBundle(
      named: "Updated In Place",
      in: directory,
      info: [
        "CFBundleName": "Updated In Place",
        "CFBundleExecutable": "Updated In Place",
        "CFBundleIdentifier": "com.example.updated-in-place",
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "123",
      ]
    )

    let oldBundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))
    XCTAssertEqual(oldBundle.version.versionNumber, "1.2.3")
    XCTAssertEqual(oldBundle.version.buildNumber, "123")

    try writeInfoPlist(
      forAppAt: appURL,
      info: [
        "CFBundleName": "Updated In Place",
        "CFBundleExecutable": "Updated In Place",
        "CFBundleIdentifier": "com.example.updated-in-place",
        "CFBundleShortVersionString": "1.2.5",
        "CFBundleVersion": "125",
      ]
    )

    let updatedBundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))
    XCTAssertEqual(updatedBundle.version.versionNumber, "1.2.5")
    XCTAssertEqual(updatedBundle.version.buildNumber, "125")
  }

  func testCollectingUnchangedBundleReusesCachedMetadata() throws {
    let directory = try makeTemporaryDirectory()
    let appURL = try makeAppBundle(
      named: "Cached In Place",
      in: directory,
      info: [
        "CFBundleName": "Cached In Place",
        "CFBundleExecutable": "Cached In Place",
        "CFBundleIdentifier": "com.example.cached-in-place",
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "123",
      ]
    )

    let firstBundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))
    let secondBundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))

    XCTAssertTrue(firstBundle === secondBundle)
  }

  func testCollectingBundleWithUpdatedModificationDateRefreshesCachedMetadata() throws {
    let directory = try makeTemporaryDirectory()
    let appURL = try makeAppBundle(
      named: "Updated Metadata",
      in: directory,
      info: [
        "CFBundleName": "Updated Metadata",
        "CFBundleExecutable": "Updated Metadata",
        "CFBundleIdentifier": "com.example.updated-metadata",
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "123",
      ]
    )

    let firstBundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))
    let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    let newerTimestamp = Date(
      timeIntervalSince1970: floor(firstBundle.modificationDate.timeIntervalSince1970) + 60)
    try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
    try setModificationDate(newerTimestamp, for: resourcesURL)

    let updatedBundle = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))

    XCTAssertFalse(firstBundle === updatedBundle)
    XCTAssertEqual(
      updatedBundle.modificationDate.timeIntervalSince1970, newerTimestamp.timeIntervalSince1970,
      accuracy: 0.001)
  }

  func testCollectBundlesSkipsAppsInsideExcludedSubfolders() throws {
    let directory = try makeTemporaryDirectory()
    let excludedDirectory = directory.appendingPathComponent("Setapp", isDirectory: true)

    _ = try makeAppBundle(
      named: "Excluded App",
      in: excludedDirectory,
      info: [
        "CFBundleName": "Excluded App",
        "CFBundleExecutable": "Excluded App",
        "CFBundleIdentifier": "com.example.excluded-app",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "100",
      ]
    )
    _ = try makeAppBundle(
      named: "Visible App",
      in: directory,
      info: [
        "CFBundleName": "Visible App",
        "CFBundleExecutable": "Visible App",
        "CFBundleIdentifier": "com.example.visible-app",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "100",
      ]
    )

    let bundles = BundleCollector.collectBundles(at: directory)

    XCTAssertEqual(Set(bundles.map(\.name)), ["Visible App"])
  }

  func testSystemApplicationsAreExcludedFromDiscovery() {
    XCTAssertFalse(
      BundleCollector.shouldIncludeApplication(
        at: URL(fileURLWithPath: "/System/Applications/Notes.app", isDirectory: true)
      ))
    XCTAssertFalse(
      BundleCollector.shouldIncludeApplication(
        at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
      ))
    XCTAssertTrue(
      BundleCollector.shouldIncludeApplication(
        at: URL(fileURLWithPath: "/Applications/Third Party.app", isDirectory: true)
      ))
  }

}

private final class LibraryDirectoryStore: AppDirectoryStoring, Sendable {
  private let urls: Mutex<[URL]>
  init(urls: [URL]) { self.urls = Mutex(urls) }
  var URLs: [URL] { urls.withLock { $0 } }
  func add(_ url: URL) { urls.withLock { $0.append(url) } }
  func remove(_ url: URL) { urls.withLock { $0.removeAll { $0 == url } } }
  func canRemove(_ url: URL) -> Bool { true }
  func isReachable(_ url: URL) -> Bool { true }
}

extension BundleCollectorTest {
  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock {
      try? FileManager.default.removeItem(at: directory)
    }
    return directory
  }

  private func makeAppBundle(named name: String, in directory: URL, info: [String: String]) throws
    -> URL
  {
    let appURL = directory.appendingPathComponent("\(name).app", isDirectory: true)
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)

    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try writeInfoPlist(forAppAt: appURL, info: info)

    return appURL
  }

  private func writeInfoPlist(forAppAt appURL: URL, info: [String: String]) throws {
    let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: plistURL)
  }

  private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }

}
