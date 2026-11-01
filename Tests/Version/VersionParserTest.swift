//
//  VersionParserTest.swift
//  Latest Tests
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import XCTest

final class VersionParserTest: XCTestCase {
  func testBuildNumberParsing() {
    XCTAssertEqual(VersionParser.parse(buildNumber: "1234"), "1234")
    XCTAssertEqual(VersionParser.parse(buildNumber: "IU-1234"), "1234")
    XCTAssertEqual(VersionParser.parse(buildNumber: "WS-1234"), "1234")
    XCTAssertEqual(VersionParser.parse(buildNumber: "1.2/1234"), "1234")
    XCTAssertEqual(VersionParser.parse(buildNumber: "1.2 (r1234)"), "1234")
    XCTAssertEqual(VersionParser.parse(buildNumber: "ab-1234"), "ab-1234")
  }

  func testVersionNumberParsing() {
    XCTAssertEqual(VersionParser.parse(versionNumber: "1234"), "1234")
    XCTAssertEqual(VersionParser.parse(versionNumber: "v1234"), "1234")
    XCTAssertEqual(VersionParser.parse(versionNumber: "1.2.3.4"), "1.2.3.4")
    XCTAssertEqual(VersionParser.parse(versionNumber: "Build 1234"), "1234")
    XCTAssertEqual(VersionParser.parse(versionNumber: "1.2.3 (r1234)"), "1.2.3")
    XCTAssertEqual(VersionParser.parse(versionNumber: "1.2.3.osx14"), "1.2.3")
    XCTAssertEqual(VersionParser.parse(versionNumber: "1.2-HEAD-123abc"), "1.2")
    XCTAssertEqual(VersionParser.parse(versionNumber: "1.2-stable.123abc"), "1.2")
    XCTAssertEqual(VersionParser.parse(versionNumber: "1.2-latest"), "1.2")
    XCTAssertEqual(VersionParser.parse(versionNumber: "1.2-release"), "1.2")
    XCTAssertEqual(VersionParser.parse(versionNumber: "1.2-demo"), "1.2")
  }

  func testNormalizationOnlyMatchesActualPrefixesAndSuffixes() {
    for version in ["1.2-dev", "1.2-preview", "1.2-release-candidate", "1.2xosx14"] {
      XCTAssertEqual(VersionParser.parse(versionNumber: version), version)
    }
    XCTAssertEqual(VersionParser.parse(buildNumber: "prefixIU-1234"), "prefixIU-1234")
    XCTAssertEqual(VersionParser.parse(versionNumber: "Product Build 1234"), "Product Build 1234")
  }

  func testCombinedVersionNumberParsing() {
    XCTAssertEqual(
      VersionParser.parse(combinedVersionNumber: "1234"),
      Version(versionNumber: "1234", buildNumber: nil))
    XCTAssertEqual(
      VersionParser.parse(combinedVersionNumber: "1234,321"),
      Version(versionNumber: "1234", buildNumber: "321"))
    XCTAssertEqual(
      VersionParser.parse(combinedVersionNumber: "1.2.3.4,321ABC,70"),
      Version(versionNumber: "1.2.3.4", buildNumber: "321ABC"))
    XCTAssertEqual(
      VersionParser.parse(combinedVersionNumber: "2.2.1-763"),
      Version(versionNumber: "2.2.1", buildNumber: "763"))
  }

  func testEmptyVersionParsing() {
    XCTAssertNil(VersionParser.parse(buildNumber: ""))
    XCTAssertNil(VersionParser.parse(versionNumber: ""))

    XCTAssertEqual(
      VersionParser.parse(combinedVersionNumber: ""), Version(versionNumber: nil, buildNumber: nil))
  }

  func testParsingPreservesUnicodeAcrossFoundationRegexRanges() {
    for version in ["1.2🚀", "1.2e\u{301}", "版本1.2🚀"] {
      XCTAssertEqual(VersionParser.parse(versionNumber: "v" + version), version)
      XCTAssertEqual(VersionParser.parse(buildNumber: "IU-" + version), version)
      let combined = VersionParser.parse(combinedVersionNumber: version + ",42🚀")
      XCTAssertEqual(combined.versionNumber, version)
      XCTAssertEqual(combined.buildNumber, "42🚀")
    }
  }
}
