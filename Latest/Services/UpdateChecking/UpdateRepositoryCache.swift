//
//  UpdateRepositoryCache.swift
//  Latest
//
//  Created by Max Langer on 10.12.23.
//  Copyright © 2023 Max Langer. All rights reserved.
//

import CryptoKit
import Foundation
import Synchronization

final class UpdateRepositoryCache: Sendable {
  /// UserDefaults is thread-safe, but Foundation does not declare it Sendable.
  /// Every access is serialized by the owning mutex.
  private struct UserDefaultsDependency: @unchecked Sendable {
    let value: UserDefaults
  }

  struct Validators: Equatable, Sendable {
    let eTag: String?
    let lastModified: String?
  }

  /// Duration after which the cache will be invalidated. (1 hour in seconds)
  private static let cacheInvalidationDuration: Double = 1 * 60 * 60

  init(cacheURL: URL?, userDefaultsKey: String, userDefaults: UserDefaults = .standard) {
    self.cacheURL = cacheURL
    self.userDefaultsKey = userDefaultsKey
    self.userDefaults = Mutex(UserDefaultsDependency(value: userDefaults))
  }

  private let cacheURL: URL?
  private let userDefaultsKey: String
  private let userDefaults: Mutex<UserDefaultsDependency>

  func cachedData(allowExpired: Bool = false) -> Data? {
    guard allowExpired || isCacheValid, let cacheURL else {
      return nil
    }

    return try? Data(contentsOf: cacheURL)
  }

  func store(_ data: Data, response: HTTPURLResponse? = nil) {
    guard let cacheURL else { return }

    userDefaults.withLock { userDefaults in
      do {
        try FileManager.default.createDirectory(
          at: cacheURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: cacheURL, options: .atomic)
        userDefaults.value.set(Date.timeIntervalSinceReferenceDate, forKey: userDefaultsKey)
        if let response {
          userDefaults.value.set(response.value(forHTTPHeaderField: "ETag"), forKey: eTagKey)
          userDefaults.value.set(
            response.value(forHTTPHeaderField: "Last-Modified"), forKey: lastModifiedKey)
        }
      } catch {
        try? FileManager.default.removeItem(at: cacheURL)
      }
    }
  }

  var validators: Validators {
    userDefaults.withLock { userDefaults in
      Validators(
        eTag: userDefaults.value.string(forKey: eTagKey),
        lastModified: userDefaults.value.string(forKey: lastModifiedKey)
      )
    }
  }

  func markFresh() {
    userDefaults.withLock { userDefaults in
      userDefaults.value.set(Date.timeIntervalSinceReferenceDate, forKey: userDefaultsKey)
    }
  }

  /// A payload that cannot be decoded must be fetched again, including its validators.
  func invalidate() {
    userDefaults.withLock { userDefaults in
      if let cacheURL { try? FileManager.default.removeItem(at: cacheURL) }
      for key in [userDefaultsKey, eTagKey, lastModifiedKey] {
        userDefaults.value.removeObject(forKey: key)
      }
    }
  }

  private var eTagKey: String {
    userDefaultsKey + ".etag"
  }

  private var lastModifiedKey: String {
    userDefaultsKey + ".lastModified"
  }

  private var isCacheValid: Bool {
    userDefaults.withLock { userDefaults in
      let timeInterval = userDefaults.value.double(forKey: userDefaultsKey) as TimeInterval
      return timeInterval > 0
        && timeInterval.distance(to: Date.timeIntervalSinceReferenceDate)
          < Self.cacheInvalidationDuration
    }
  }

}

struct UpdateRepositoryCompactIndex: Codable, Sendable {
  static let currentSchemaVersion = 2

  let schemaVersion: Int
  let sourceFingerprint: Data
  let sourceByteCount: Int
  let sourceEntryCount: Int
  let records: [UpdateRepository.Entry.CompactRecord]

  init(sourceData: Data, sourceEntryCount: Int, entries: [UpdateRepository.Entry]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.sourceFingerprint = Self.fingerprint(sourceData)
    self.sourceByteCount = sourceData.count
    self.sourceEntryCount = sourceEntryCount
    self.records = entries.map(\.compactRecord)
  }

  func matches(_ sourceData: Data) -> Bool {
    schemaVersion == Self.currentSchemaVersion && sourceByteCount == sourceData.count
      && sourceFingerprint == Self.fingerprint(sourceData)
  }

  var entries: [UpdateRepository.Entry] {
    records.map(UpdateRepository.Entry.init(compactRecord:))
  }

  private static func fingerprint(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }
}

final class UpdateRepositoryCompactIndexCache: Sendable {
  private let cacheURL: URL?

  init(cacheURL: URL?) {
    self.cacheURL = cacheURL
  }

  func load(matching sourceData: Data) -> UpdateRepositoryCompactIndex? {
    guard let cacheURL,
      let data = try? Data(contentsOf: cacheURL),
      let index = try? PropertyListDecoder().decode(UpdateRepositoryCompactIndex.self, from: data),
      index.matches(sourceData)
    else {
      return nil
    }
    return index
  }

  func store(_ index: UpdateRepositoryCompactIndex) {
    guard let cacheURL else { return }
    do {
      let encoder = PropertyListEncoder()
      encoder.outputFormat = .binary
      let data = try encoder.encode(index)
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: cacheURL, options: .atomic)
    } catch {
      try? FileManager.default.removeItem(at: cacheURL)
    }
  }
}
