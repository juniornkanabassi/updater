//
//  ReleaseNotesPersistentCacheTest.swift
//  Latest Tests
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import CryptoKit
import XCTest

@testable import Latest

final class ReleaseNotesPersistentCacheTest: XCTestCase {
  @MainActor
  func testPersistentReleaseNotesCacheRoundTripsRenderedContentAndProvenance() async throws {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directoryURL) }
    let cache = ReleaseNotesPersistentCache(directoryURL: directoryURL)
    let source = ReleaseNotesContent(runs: [
      .init(text: "Version 2.0", link: URL(string: "https://example.com/releases/2.0")!),
      .init(text: "\nFixed repeated release-note parsing."),
    ])
    let resolved = ResolvedReleaseNotes(content: source, quality: .genuine, provenance: .changelog)
    let payload = ReleaseNotesPersistentCache.payload(from: resolved)

    await cache.store(payload, forKey: "com.example.app-2.0")
    let loadedPayload = await cache.payload(forKey: "com.example.app-2.0")
    let storedPayload = try XCTUnwrap(loadedPayload)
    let restored = try XCTUnwrap(
      ReleaseNotesPersistentCache.resolvedReleaseNotes(from: storedPayload))

    XCTAssertEqual(restored.content.string, source.string)
    XCTAssertEqual(restored.quality, .genuine)
    XCTAssertEqual(restored.provenance, .changelog)
    XCTAssertEqual(
      restored.content.runs.first?.link, URL(string: "https://example.com/releases/2.0"))
    XCTAssertTrue(storedPayload.richTextData.isEmpty, "New cache entries must not serialize RTF")
    XCTAssertNotNil(storedPayload.semanticContent)
  }

  func testExpiredPayloadIsRemovedWithoutRenewingIt() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ReleaseNotesPersistentCache(directoryURL: directory, lifetime: 60)
    await cache.store(makePayload(storedAt: Date(timeIntervalSinceNow: -120)), forKey: "expired")
    let loaded = await cache.payload(forKey: "expired")
    XCTAssertNil(loaded)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
  }

  func testEvictionHonorsCountAndEncodedByteLimits() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = ReleaseNotesPersistentCache(directoryURL: directory, maximumEntryCount: 2)
    for index in 0..<4 {
      await cache.store(makePayload(), forKey: "item-\(index)")
      // Give deterministic ages without depending on filesystem clock resolution.
      let path = directory.appendingPathComponent(
        ReleaseNotesStableDigest.hex(of: Data("item-\(index)".utf8)) + ".plist")
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: path.path)
    }
    let files = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, 2)
    let evicted = await cache.payload(forKey: "item-0")
    let retained = await cache.payload(forKey: "item-3")
    XCTAssertNil(evicted)
    XCTAssertNotNil(retained)
    let payload = makePayload()
    let size = try PropertyListEncoder().encode(payload).count
    let byteLimited = ReleaseNotesPersistentCache(
      directoryURL: directory,
      maximumEntryCount: 100, maximumStoredBytes: size)
    await byteLimited.store(payload, forKey: "new")
    let remaining = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey])
    let total = try remaining.reduce(0) {
      try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
    XCTAssertLessThanOrEqual(total, size)
  }

  func testFailedEvictionStillCountsBytesAndTriesNextFile() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cache = ReleaseNotesPersistentCache(directoryURL: directory, maximumEntryCount: 1)
    await cache.store(makePayload(), forKey: "locked")
    let file = directory.appendingPathComponent(
      ReleaseNotesStableDigest.hex(of: Data("locked".utf8)) + ".plist")
    defer {
      try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: file.path)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.setAttributes(
      [.modificationDate: Date.distantPast, .immutable: true], ofItemAtPath: file.path)
    await cache.store(makePayload(), forKey: "new")
    let locked = await cache.payload(forKey: "locked")
    let newer = await cache.payload(forKey: "new")
    XCTAssertNotNil(locked)
    XCTAssertNil(newer)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
  }

  private func makePayload(storedAt: Date = Date()) -> ReleaseNotesPersistentPayload {
    ReleaseNotesPersistentPayload(
      richTextData: Data(repeating: 65, count: 128),
      qualityRawValue: 3, provenanceRawValue: "changelog", storedAt: storedAt)
  }

}
