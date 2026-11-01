//
//  VersionTest.swift
//  Latest Tests
//
//  Created by Max Langer on 14.11.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import XCTest

class VersionTest: XCTestCase {

  func testInitialization() {
    // Simple test
    var version = Version(versionNumber: "2.1.5", buildNumber: "215")

    XCTAssertEqual(version.versionNumber, "2.1.5")
    XCTAssertEqual(version.buildNumber, "215")

    // Nil test
    version = Version(versionNumber: nil, buildNumber: nil)
    XCTAssertNil(version.versionNumber)
    XCTAssertNil(version.buildNumber)
  }

  func testEmptyVersion() {
    XCTAssertTrue(Version(versionNumber: nil, buildNumber: nil).isEmpty)
    XCTAssertTrue(Version(versionNumber: nil, buildNumber: "").isEmpty)
    XCTAssertTrue(Version(versionNumber: "", buildNumber: "").isEmpty)
    XCTAssertTrue(Version(versionNumber: nil, buildNumber: ".").isEmpty)
    XCTAssertTrue(Version(versionNumber: "\n", buildNumber: nil).isEmpty)

    XCTAssertFalse(Version(versionNumber: "1", buildNumber: nil).isEmpty)
    XCTAssertFalse(Version(versionNumber: nil, buildNumber: "1").isEmpty)
    XCTAssertFalse(Version(versionNumber: "1.2", buildNumber: "123").isEmpty)
  }

  func testEmptyVersionEquality() {
    let emptyVersions = [
      Version(versionNumber: nil, buildNumber: nil),
      Version(versionNumber: nil, buildNumber: ""),
      Version(versionNumber: "", buildNumber: ""),
      Version(versionNumber: nil, buildNumber: "."),
      Version(versionNumber: "\n", buildNumber: nil),
    ]

    for version in emptyVersions {
      XCTAssertEqual(version, emptyVersions[0])
    }

    XCTAssertEqual(Set(emptyVersions).count, 1)
  }

  func testVersionIdentityDistinguishesDisplayedVersionsAndBuilds() {
    let versions = [
      Version(versionNumber: "1.0", buildNumber: nil),
      Version(versionNumber: "1.0.0", buildNumber: nil),
      Version(versionNumber: "1.0", buildNumber: "10"),
      Version(versionNumber: "1.0", buildNumber: "20"),
      Version(versionNumber: "2.0", buildNumber: "10"),
    ]
    for (left, lhs) in versions.enumerated() {
      for (right, rhs) in versions.enumerated() {
        XCTAssertEqual(lhs == rhs, left == right, "\(lhs) / \(rhs)")
      }
    }
    let copies = versions.map {
      Version(versionNumber: $0.versionNumber, buildNumber: $0.buildNumber)
    }
    XCTAssertEqual(Set(versions + copies).count, versions.count)
    for (version, copy) in zip(versions, copies) {
      XCTAssertEqual(version, copy)
      XCTAssertEqual(version.hashValue, copy.hashValue)
    }
  }

  func testUpdateAvailabilityPreservesInstalledToRemoteComparisonDirection() {
    func update(local: Version, remote: Version) -> App.Update {
      let bundle = App.Bundle(
        version: local, name: "Example", bundleIdentifier: "test.version",
        fileURL: URL(fileURLWithPath: "/tmp/Version.app"), source: .sparkle,
        modificationDate: .distantPast)
      return App.Update(
        app: bundle, remoteVersion: remote, minimumOSVersion: nil, source: .sparkle,
        date: nil, releaseNotes: nil, updateAction: .builtIn { _ in })
    }
    let first = Version(versionNumber: "1", buildNumber: "1")
    let second = Version(versionNumber: "2", buildNumber: "1")
    XCTAssertTrue(update(local: first, remote: second).updateAvailable)
    XCTAssertFalse(update(local: second, remote: first).updateAvailable)
  }

  func testNumericVersionPrefixPreservesDisplayAndFindsEqMacUpdate() {
    let installed = Version(versionNumber: "1.8.15", buildNumber: "1.8.15")
    let remote = Version(versionNumber: "v1.9.2", buildNumber: "1.9.2")
    XCTAssertEqual(installed.comparisonForUpdate(to: remote), .older)
    XCTAssertEqual(remote.versionNumber, "v1.9.2", "Keep the vendor's displayed version")
    XCTAssertEqual(remote.comparisonForUpdate(to: installed), .newer)
    for prefix in ["v", "V"] {
      let prefixed = Version(versionNumber: prefix + "1.8.15", buildNumber: nil)
      XCTAssertEqual(installed.comparisonForUpdate(to: prefixed), .samePrecedence)
      XCTAssertEqual(prefixed.comparisonForUpdate(to: installed), .samePrecedence)
      XCTAssertNotEqual(prefixed, installed, "Precedence normalization must not change identity")
      XCTAssertEqual(
        Version(versionNumber: prefix + "1.9.2beta", buildNumber: nil)
          .comparisonForUpdate(to: remote), .older)
    }
  }

  /// Update precedence is directional and separate from Version identity.
  func testUpdatePrecedence() {
    let cases:
      [(
        local: String, localBuild: String?, remote: String, remoteBuild: String?,
        expected: Version.UpdateComparison
      )] = [
        ("2.1.5", "312", "2.1.6d12", "215", .newer),
        ("2.1.5", nil, "2.2.6", "216", .older),
        ("2.1.5", "215", "2.2.6", nil, .older),
        ("2.1.5", nil, "2.2.6", nil, .older),
        ("2.1.5", "215", "2.1.6", "216", .older),
        ("2.1.5", "215a", "2.2.6", "216b", .older),
        ("2.1.5", "215", "2.1.5", "215", .samePrecedence),
        ("2.0.6", "217", "2.1.5", "216", .newer),
        ("2.1.6", "217a", "2.2.4", "216b", .newer),
        ("2.1.5", nil, "2.1.6", "216", .older),
        ("2.1.5", nil, "3.1.6", nil, .older),
        ("2.1.5", nil, "2.1.5", "215", .samePrecedence),
        ("2.2.6", "215", "2.2.6", nil, .samePrecedence),
        ("3.1.6", nil, "3.1.6", nil, .samePrecedence),
        ("2.1.6", nil, "2.1.5", "216", .newer),
        ("2.3.6", "215", "2.2.4", nil, .newer),
        ("4.1.5", nil, "3.1.6", nil, .newer),
        ("2.1.5", nil, "2.1.5.0", "215", .samePrecedence),
        ("2.2.6.0", "215", "2.2.6", nil, .samePrecedence),
        ("2.2.6", nil, "2.2.6", nil, .samePrecedence),
        ("3.1.5", "215", "2.2.6", nil, .newer),
        ("3.1.5", nil, "2.1.6", "216", .newer),
        ("٣.١.٥", "٢١٥", "٢.٢.٦", nil, .newer),
        ("३.१.५", "२१७", "२.१.६", nil, .newer),
        ("1.2", nil, "1.2.0.1", nil, .older),
        ("1.2.0.1", nil, "1.2", nil, .newer),
        ("1.2", nil, "1.2.0.0", nil, .samePrecedence),
        ("1.2", nil, "1.2a", nil, .newer),
        ("1.2a", nil, "1.2", nil, .older),
        ("1.2", nil, "1.2.0beta", nil, .newer),
      ]
    for fixture in cases {
      let local = Version(versionNumber: fixture.local, buildNumber: fixture.localBuild)
      let remote = Version(versionNumber: fixture.remote, buildNumber: fixture.remoteBuild)
      XCTAssertEqual(
        local.comparisonForUpdate(to: remote), fixture.expected, "\(local) → \(remote)")
    }
  }

  func testEqualBundlesWithDifferentVersionsDeduplicateByIdentifier() {
    let appURL = URL(
      fileURLWithPath: "/Applications/Versioned-\(UUID().uuidString).app", isDirectory: true)
    let oldBundle = App.Bundle(
      version: Version(versionNumber: "1.0", buildNumber: nil),
      name: "Versioned",
      bundleIdentifier: "com.example.versioned",
      fileURL: appURL,
      source: .sparkle,
      modificationDate: .distantPast
    )
    let newBundle = App.Bundle(
      version: Version(versionNumber: "1.1", buildNumber: nil),
      name: "Versioned",
      bundleIdentifier: "com.example.versioned",
      fileURL: appURL,
      source: .sparkle,
      modificationDate: .distantPast
    )

    XCTAssertEqual(oldBundle, newBundle)
    XCTAssertEqual(Set([oldBundle, newBundle]).count, 1)
  }

}
