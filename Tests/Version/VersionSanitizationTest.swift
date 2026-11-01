//
//  VersionTest.swift
//  Latest Tests
//
//  Created by Max Langer on 14.11.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import XCTest

class VersionSanitizationTest: XCTestCase {

  func testUpdateRetainsOriginalVersionWhenSanitizedPrecedenceIsUnchanged() {
    let bundle = App.Bundle(
      version: Version(versionNumber: "1.2.3", buildNumber: "1.2.3"),
      name: "Example", bundleIdentifier: "test.version",
      fileURL: URL(fileURLWithPath: "/tmp/Version.app"), source: .sparkle,
      modificationDate: .distantPast)
    let update = App.Update(
      app: bundle, remoteVersion: Version(versionNumber: "1.2.3.4", buildNumber: "abc"),
      minimumOSVersion: nil, source: .sparkle, date: nil, releaseNotes: nil,
      updateAction: .builtIn { _ in })
    XCTAssertTrue(update.sanitized(for: bundle) === update)
    XCTAssertEqual(update.remoteVersion.versionNumber, "1.2.3.4")
  }

  func testNoSanitization() {
    let appVersion = Version(versionNumber: "1.2", buildNumber: "40")
    let remoteVersion = Version(versionNumber: "3.2", buildNumber: "ABC")

    XCTAssertEqual(remoteVersion.sanitize(with: appVersion), remoteVersion)
  }

  func testBuildNumberAttachedToVersionNumber() {
    let appVersion = Version(versionNumber: "1.2", buildNumber: "40")
    let remoteVersion = Version(versionNumber: "1.2.40", buildNumber: nil)

    XCTAssertEqual(
      remoteVersion.sanitize(with: appVersion), Version(versionNumber: "1.2", buildNumber: "40"))
  }

  func testVersionNumberReplacedByBuildNumber() {
    var appVersion = Version(versionNumber: "1.2", buildNumber: "40")
    var remoteVersion = Version(versionNumber: "40", buildNumber: nil)
    XCTAssertEqual(
      remoteVersion.sanitize(with: appVersion), Version(versionNumber: nil, buildNumber: "40"))

    appVersion = Version(versionNumber: "1.2", buildNumber: "40")
    remoteVersion = Version(versionNumber: "40", buildNumber: "some")
    XCTAssertEqual(
      remoteVersion.sanitize(with: appVersion), Version(versionNumber: nil, buildNumber: "40"))

    appVersion = Version(versionNumber: "1.2", buildNumber: "1.2.40")
    remoteVersion = Version(versionNumber: "1.2.40", buildNumber: nil)
    XCTAssertEqual(
      remoteVersion.sanitize(with: appVersion), Version(versionNumber: nil, buildNumber: "1.2.40"))
  }

  func testRemovingVersionNumberPostfix() {
    // Nothing should happen for 3 segments
    var appVersion = Version(versionNumber: "1.2", buildNumber: "1.2")
    var remoteVersion = Version(versionNumber: "1.2.3", buildNumber: "abc")
    XCTAssertEqual(remoteVersion.sanitize(with: appVersion), remoteVersion)

    //  Keep fourth segment if build number is different
    appVersion = Version(versionNumber: "1.2.3", buildNumber: "40")
    remoteVersion = Version(versionNumber: "1.2.3.4", buildNumber: "abc")
    XCTAssertEqual(remoteVersion.sanitize(with: appVersion), remoteVersion)

    //  Remove fourth segment, if first 3 match and build and version number are identical
    appVersion = Version(versionNumber: "1.2.3", buildNumber: "1.2.3")
    remoteVersion = Version(versionNumber: "1.2.3.4", buildNumber: "abc")
    XCTAssertEqual(
      remoteVersion.sanitize(with: appVersion), Version(versionNumber: "1.2.3", buildNumber: "abc"))
  }

}
