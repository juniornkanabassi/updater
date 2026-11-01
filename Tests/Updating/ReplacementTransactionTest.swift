// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Synchronization
import XCTest

@testable import Latest

final class ReplacementTransactionTest: XCTestCase {
  /// Failure injection after the swap restores the original byte-for-byte and leaves no backup.
  func testFailedDestinationChecksRestoreTheOriginalByteForByte() throws {
    let injections = ["wrong team", "wrong signature", "wrong version", "won't launch", "wrong id"]
    for injection in injections {
      let root = try disposableDirectory()
      let original = try FixtureApp.make(in: root, version: "1.0")
      let before = try FixtureApp.digest(original)
      let stage = root.appendingPathComponent(".stage")
      try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
      let candidate = try FixtureApp.make(
        in: stage, name: "Fixture",
        identifier: injection == "wrong id" ? "com.example.other" : FixtureApp.identifier,
        version: injection == "wrong version" ? "1.0.5" : "1.1",
        launches: injection != "won't launch")
      if injection == "wrong signature" {
        // Modify the signed executable after signing; the plist stays valid.
        let executable = try FileHandle(
          forWritingTo: candidate.appendingPathComponent("Contents/MacOS/Fixture"))
        try executable.seekToEnd()
        try executable.write(contentsOf: Data([0]))
        try executable.close()
      }
      var identity = try BundleIdentity.read(at: original, validate: false)
      if injection == "wrong team" {
        identity = BundleIdentity(
          bundleIdentifier: identity.bundleIdentifier, teamIdentifier: "TEAMA12345",
          shortVersion: identity.shortVersion, bundleVersion: identity.bundleVersion)
      }
      XCTAssertThrowsError(
        try DownloadUpdateOperation.replaceItem(
          at: original, with: candidate, backupDirectory: stage
        ) { url in
          try AppDownloadUpdateOperation.verifyInstalled(
            at: url, original: identity,
            expectedVersion: Version(versionNumber: "1.1", buildNumber: "1.1"),
            requiresTeam: injection == "wrong team", launchProbe: FixtureApp.launchProbe)
        }, injection
      ) { error in
        XCTAssertTrue(error is ReplacementError, "\(injection): \(error)")
      }
      XCTAssertEqual(try FixtureApp.digest(original), before, injection)
      XCTAssertFalse(ReplacementTransaction.needsRecovery(stage), injection)
    }
  }

  func testVerifiedReplacementDiscardsTheBackup() throws {
    let root = try disposableDirectory()
    let original = try FixtureApp.make(in: root, version: "1.0")
    let stage = root.appendingPathComponent(".stage")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    let candidate = try FixtureApp.make(in: stage, version: "1.1")
    let expected = try FixtureApp.digest(candidate)
    let identity = try BundleIdentity.read(at: original, validate: false)
    try DownloadUpdateOperation.replaceItem(at: original, with: candidate, backupDirectory: stage) {
      try AppDownloadUpdateOperation.verifyInstalled(
        at: $0, original: identity,
        expectedVersion: Version(versionNumber: "1.1", buildNumber: "1.1"),
        requiresTeam: false, launchProbe: FixtureApp.launchProbe)
    }
    XCTAssertEqual(try FixtureApp.digest(original), expected)
    XCTAssertFalse(ReplacementTransaction.needsRecovery(stage))
  }

  /// The App Store helper path: PackageKit replaces the bundle in place, so the original is
  /// cloned aside first and put back if the result is not the same signed product.
  func testInPlaceInstallerFailureRestoresTheClonedOriginal() throws {
    let root = try disposableDirectory()
    let target = try FixtureApp.make(in: root, version: "1.0")
    let before = try FixtureApp.digest(target)
    let staging = root.appendingPathComponent("staging")
    let payload = root.appendingPathComponent("payload")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
    let other = try FixtureApp.make(in: payload, identifier: "com.example.impostor", version: "2.0")
    let identity = try BundleIdentity.read(at: target, validate: false)
    XCTAssertThrowsError(
      try ReplacementTransaction.perform(
        at: target, backupDirectory: staging, copyingOriginal: true,
        install: {
          XCTAssertTrue(
            FileManager.default.fileExists(atPath: target.path), "original stays in place")
          try FileManager.default.removeItem(at: target)
          try FileManager.default.copyItem(at: other, to: target)
        },
        verify: { _ = try identity.verifyReplacement(at: $0, requiresTeam: false) }))
    XCTAssertEqual(try FixtureApp.digest(target), before)
    XCTAssertFalse(ReplacementTransaction.needsRecovery(staging))
  }

  /// Sol R1 + R2: the helper's App Store sequence keeps the original until the installer
  /// wrote this URL, the receipt exists, and the version is newer and at least the expected
  /// one. Every failure, including the receipt step, restores the original byte-for-byte.
  func testAppStorePackageInstallVerifiesVersionAndReceiptBeforeDiscardingTheBackup() throws {
    let scenarios: [(name: String, installs: String, expected: String, receiptFails: Bool)] = [
      ("below expected version", "1.1", "1.2", false),
      ("downgrade", "0.9", "0.9", false),
      ("unchanged", "1.0", "1.0", false),
      ("receipt write fails", "1.2", "1.2", true),
    ]
    for scenario in scenarios {
      let root = try disposableDirectory()
      let app = try FixtureApp.make(in: root, version: "1.0")
      let before = try FixtureApp.digest(app)
      let staging = root.appendingPathComponent("staging")
      try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      let payload = try FixtureApp.make(
        in: root.appendingPathComponent("payload"), version: scenario.installs)
      XCTAssertThrowsError(
        try AppStorePackageInstall.perform(
          appURL: app, staging: staging, expectedVersion: scenario.expected, requiresTeam: false,
          runInstaller: {
            try FileManager.default.removeItem(at: app)
            try FileManager.default.copyItem(at: payload, to: app)
            return [app.standardizedFileURL.path]
          },
          writeReceipt: { receipt in
            if scenario.receiptFails { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.createDirectory(
              at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("receipt".utf8).write(to: receipt)
          }), scenario.name)
      XCTAssertEqual(try FixtureApp.digest(app), before, scenario.name)
      XCTAssertFalse(ReplacementTransaction.needsRecovery(staging), scenario.name)
    }

    // The installer registering a different copy is not an install of this URL.
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let staging = root.appendingPathComponent("staging")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    XCTAssertThrowsError(
      try AppStorePackageInstall.perform(
        appURL: app, staging: staging, expectedVersion: "1.1", requiresTeam: false,
        runInstaller: { ["/Applications/Fixture.app"] }, writeReceipt: { _ in }))

    // Success: new version, receipt present, backup gone.
    let payload = try FixtureApp.make(in: root.appendingPathComponent("payload"), version: "1.2")
    try AppStorePackageInstall.perform(
      appURL: app, staging: staging, expectedVersion: "1.2", requiresTeam: false,
      runInstaller: {
        try FileManager.default.removeItem(at: app)
        try FileManager.default.copyItem(at: payload, to: app)
        return [app.standardizedFileURL.path]
      },
      writeReceipt: { receipt in
        try FileManager.default.createDirectory(
          at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("receipt".utf8).write(to: receipt)
      })
    XCTAssertEqual(try BundleIdentity.read(at: app, validate: false).shortVersion, "1.2")
    XCTAssertFalse(ReplacementTransaction.needsRecovery(staging))
  }

  @MainActor
  func testAppThatRefusesToQuitIsNeverReplacedOrReopened() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    let before = try FixtureApp.digest(app)
    let quitRequests = Mutex(0)
    let reopened = Mutex(0)
    let lifecycle = AppLifecycle(
      runningApps: { url in
        XCTAssertEqual(url, app)
        // Receives the quit request but stays open, as with a save prompt left unanswered.
        return [.init(terminate: { quitRequests.withLock { $0 += 1 } }, isTerminated: { false })]
      },
      confirmQuit: { _ in true },
      reopen: { _ in reopened.withLock { $0 += 1 } },
      timeout: .milliseconds(300))
    do {
      try await lifecycle.withApplicationClosed(at: app, name: "Fixture") {
        XCTFail("A running app must not be replaced")
      }
      XCTFail("Expected the refusal to cancel the update")
    } catch AppDownloadError.applicationStillRunning {}
    XCTAssertEqual(quitRequests.withLock { $0 }, 1)
    XCTAssertEqual(reopened.withLock { $0 }, 0)
    XCTAssertEqual(try FixtureApp.digest(app), before)

    // Declining the quit prompt sends no quit request at all.
    let declined = AppLifecycle(
      runningApps: { _ in
        [.init(terminate: { XCTFail("Declined quit must not terminate") }, isTerminated: { false })]
      },
      confirmQuit: { _ in false }, reopen: { _ in XCTFail("Never quit, never reopened") })
    do {
      try await declined.withApplicationClosed(at: app, name: "Fixture") { XCTFail("No install") }
      XCTFail("Expected cancellation")
    } catch is CancellationError {}
  }

  @MainActor
  func testLifecycleReopensOnlyAppsThatWereRunning() async throws {
    let root = try disposableDirectory()
    let app = try FixtureApp.make(in: root, version: "1.0")
    for wasRunning in [true, false] {
      let terminated = Mutex(false)
      let installed = Mutex(false)
      let reopened = Mutex(0)
      let lifecycle = AppLifecycle(
        runningApps: { _ in
          wasRunning
            ? [
              .init(
                terminate: { terminated.withLock { $0 = true } },
                isTerminated: { terminated.withLock { $0 } })
            ] : []
        },
        confirmQuit: { _ in
          XCTAssertTrue(wasRunning, "Only a running app is asked to quit")
          return true
        },
        reopen: { _ in reopened.withLock { $0 += 1 } })
      try await lifecycle.withApplicationClosed(at: app, name: "Fixture") {
        installed.withLock { $0 = true }
      }
      XCTAssertTrue(installed.withLock { $0 })
      XCTAssertEqual(reopened.withLock { $0 }, wasRunning ? 1 : 0)
    }
  }
}
