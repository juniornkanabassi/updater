//
//  ReleaseNotesPersistentCache.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import CryptoKit
import Foundation
import OSLog

enum ReleaseNotesStableDigest {
  static func hex(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct ReleaseNotesPersistentPayload: Codable, Sendable {
  let richTextData: Data
  let semanticContent: ReleaseNotesContent?
  let qualityRawValue: Int
  let provenanceRawValue: String
  let storedAt: Date

  init(
    richTextData: Data = Data(), semanticContent: ReleaseNotesContent? = nil,
    qualityRawValue: Int, provenanceRawValue: String, storedAt: Date
  ) {
    self.richTextData = richTextData
    self.semanticContent = semanticContent
    self.qualityRawValue = qualityRawValue
    self.provenanceRawValue = provenanceRawValue
    self.storedAt = storedAt
  }
}

actor ReleaseNotesPersistentCache {
  private let directoryURL: URL
  private let lifetime: TimeInterval
  private let maximumEntryCount: Int
  private let maximumStoredBytes: Int

  init(
    directoryURL: URL? = nil,
    lifetime: TimeInterval = 30 * 24 * 60 * 60,
    maximumEntryCount: Int = 256,
    maximumStoredBytes: Int = 32 * 1_024 * 1_024
  ) {
    let cachesDirectory =
      FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    self.directoryURL =
      directoryURL
      ?? cachesDirectory.appendingPathComponent(
        "com.max-langer.Latest/ReleaseNotes-v2", isDirectory: true)
    self.lifetime = lifetime
    self.maximumEntryCount = maximumEntryCount
    self.maximumStoredBytes = maximumStoredBytes
  }

  func payload(forKey key: String) -> ReleaseNotesPersistentPayload? {
    let fileURL = fileURL(forKey: key)
    guard let data = try? Data(contentsOf: fileURL),
      let payload = try? PropertyListDecoder().decode(
        ReleaseNotesPersistentPayload.self, from: data),
      Date().timeIntervalSince(payload.storedAt) < lifetime
    else {
      try? FileManager.default.removeItem(at: fileURL)
      return nil
    }
    return payload
  }

  func store(_ payload: ReleaseNotesPersistentPayload, forKey key: String) {
    do {
      let data = try PropertyListEncoder().encode(payload)
      guard data.count <= maximumStoredBytes else { return }
      try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      try data.write(to: fileURL(forKey: key), options: .atomic)
      trimToLimits()
    } catch {
      releaseNotesLogger.debug(
        "Unable to persist rendered release notes: \(error.localizedDescription, privacy: .public)")
    }
  }

  nonisolated static func payload(from releaseNotes: ResolvedReleaseNotes)
    -> ReleaseNotesPersistentPayload
  {
    ReleaseNotesPersistentPayload(
      semanticContent: releaseNotes.content,
      qualityRawValue: releaseNotes.quality.rawValue,
      provenanceRawValue: releaseNotes.provenance.rawValue,
      storedAt: Date()
    )
  }

  @MainActor
  static func resolvedReleaseNotes(from payload: ReleaseNotesPersistentPayload)
    -> ResolvedReleaseNotes?
  {
    guard let quality = ReleaseNotesQuality(rawValue: payload.qualityRawValue),
      let provenance = ReleaseNotesProvenance(rawValue: payload.provenanceRawValue),
      let content = payload.semanticContent
        ?? (try? ReleaseNotesLegacyBridge.decodeRTF(payload.richTextData))
    else {
      return nil
    }
    return ResolvedReleaseNotes(content: content, quality: quality, provenance: provenance)
  }

  private func fileURL(forKey key: String) -> URL {
    directoryURL.appendingPathComponent(ReleaseNotesStableDigest.hex(of: Data(key.utf8)) + ".plist")
  }

  private func trimToLimits() {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles]
      )
    else { return }

    let files = urls.map { url in
      let values = try? url.resourceValues(forKeys: keys)
      return (
        url: url, date: values?.contentModificationDate ?? .distantPast,
        size: values?.fileSize ?? 0
      )
    }
    var remainingCount = files.count
    var totalBytes = files.reduce(0) { $0 + $1.size }
    guard remainingCount > maximumEntryCount || totalBytes > maximumStoredBytes else { return }
    for file in files.sorted(by: { $0.date < $1.date }) {
      guard remainingCount > maximumEntryCount || totalBytes > maximumStoredBytes else { break }
      do {
        try FileManager.default.removeItem(at: file.url)
        remainingCount -= 1
        totalBytes -= file.size
      } catch {
        // A failed deletion still occupies space. Try the next oldest file.
        releaseNotesLogger.debug(
          "Unable to evict cached release notes: \(error.localizedDescription, privacy: .public)")
      }
    }
  }
}
