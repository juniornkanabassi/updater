//
//  BundleCollector.swift
//  Latest
//
//  Created by Max Langer on 07.03.24.
//  Copyright © 2024 Max Langer. All rights reserved.
//

import Darwin
import Foundation
import Synchronization
import UniformTypeIdentifiers

/// Gathers apps at a given URL.
enum BundleCollector {
  private static let collectionCoordinator = BundleCollectionCoordinator { url in
    Self.collectBundlesUncoordinated(at: url)
  }

  /// Excluded subfolders that won't be checked.
  private static let excludedSubfolders = Set(["Setapp"])

  /// Set of bundles that should not be included in Latest.
  private static let excludedBundleIdentifiers = Set([
    // Safari Web Apps
    "com.apple.Safari.WebApp"
  ])

  private static let appExtension = UTType.applicationBundle.preferredFilenameExtension

  private static let packageExtensionsToSkip = Set([
    "app", "appex", "bundle", "framework", "kext", "mdimporter", "plugin", "prefpane",
    "qlgenerator", "xpc",
  ])

  private static let metadataCache = BundleMetadataCache()
  private static let collectionCountCache = BundleCollectionCountCache()

  /// Returns a list of application bundles at the given URL.
  static func collectBundles(at url: URL) -> [App.Bundle] {
    collectionCoordinator.collectBundles(at: url)
  }

  private static func collectBundlesUncoordinated(at url: URL) -> [App.Bundle] {
    guard !isInExcludedSubfolder(url) else { return [] }

    let enumerator = FileManager.default.enumerator(
      at: url,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )

    var bundles = [App.Bundle]()
    while let bundleURL = enumerator?.nextObject() as? URL {
      guard !isExcludedSubfolder(bundleURL) else {
        enumerator?.skipDescendants()
        continue
      }

      let pathExtension = bundleURL.pathExtension.lowercased()
      if pathExtension == appExtension {
        if let bundle = cachedBundle(forAppAt: bundleURL) {
          bundles.append(bundle)
        }
        enumerator?.skipDescendants()
        continue
      }

      if packageExtensionsToSkip.contains(pathExtension) {
        enumerator?.skipDescendants()
      }
    }

    metadataCache.pruneEntries(below: url, keeping: Set(bundles.map(\.fileURL)))
    collectionCountCache.store(bundles.count, for: url)
    return bundles
  }

  /// Returns a recently collected app count without walking the directory again.
  static func cachedBundleCount(at url: URL) -> Int? {
    collectionCountCache.count(for: url)
  }

  /// Returns a single application bundle at the given URL.
  static func collectBundle(at url: URL) -> App.Bundle? {
    guard url.pathExtension == appExtension else { return nil }
    return cachedBundle(forAppAt: url)
  }

  // MARK: - Utilities

  private static func isExcludedSubfolder(_ url: URL) -> Bool {
    return excludedSubfolders.contains(url.lastPathComponent)
  }

  private static func isInExcludedSubfolder(_ url: URL) -> Bool {
    return url.pathComponents.contains { excludedSubfolders.contains($0) }
  }

  private static func cachedBundle(forAppAt url: URL) -> App.Bundle? {
    guard shouldIncludeApplication(at: url) else { return nil }

    guard let signature = BundleFileSignature(appURL: url) else {
      metadataCache.removeBundle(forAppAt: url)
      return nil
    }

    let bundle = metadataCache.bundle(forAppAt: url, signature: signature) {
      Self.bundle(forAppAt: url, modificationDate: signature.bundleModificationDate)
    }
    // Payload updates can happen outside the bundle, so resolve them after the plist cache.
    return bundle.map { InstalledAppVersion.resolve(for: $0) }
  }

  /// Built-in macOS apps are serviced by system updates and must not enter the
  /// third-party application library, even if `/System` is added as a custom
  /// search location.
  static func shouldIncludeApplication(at url: URL) -> Bool {
    let path = url.resolvingSymlinksInPath().standardizedFileURL.path
    return path != "/System" && !path.hasPrefix("/System/")
  }

  /// Returns a bundle representation for the app at the given url, without Spotlight Metadata.
  static private func bundle(forAppAt url: URL, modificationDate: Date) -> App.Bundle? {
    guard let infoDictionary = Bundle.infoDictionary(forAppAt: url),
      let identifier = infoDictionary.bundleIdentifier,
      let appName = infoDictionary.bundleName
    else {
      return nil
    }

    // Skip bundles which are explicitly excluded
    guard !isExcludedBundleIdentifier(identifier) else {
      return nil
    }

    // Find update source
    let source = source(forAppAt: url, information: infoDictionary, bundleIdentifier: identifier)

    // Build version. Skip bundle if no version is provided.
    let version = Version(
      versionNumber: infoDictionary.versionNumber.flatMap {
        VersionParser.parse(versionNumber: $0)
      },
      buildNumber: infoDictionary.bundleVersion.flatMap { VersionParser.parse(buildNumber: $0) }
    )
    guard !version.isEmpty else {
      return nil
    }

    // Create bundle
    return App.Bundle(
      version: version,
      name: appName,
      bundleIdentifier: identifier,
      fileURL: url,
      source: source,
      modificationDate: modificationDate
    )
  }

  private static func isExcludedBundleIdentifier(_ identifier: String) -> Bool {
    excludedBundleIdentifiers.contains { identifier.contains($0) }
  }

  private static func source(
    forAppAt url: URL, information: [String: Any], bundleIdentifier: String
  ) -> App.Source {
    if AppStoreUpdateCheckerOperation.canPerformUpdateCheck(forAppAt: url) {
      return .appStore
    }

    if SparkleFeed.feedURL(from: information, bundleIdentifier: bundleIdentifier, bundleURL: url)
      != nil
    {
      return .sparkle
    }

    return .none
  }

}

/// Coalesces simultaneous walks of the same directory across app discovery and Settings.
final class BundleCollectionCoordinator: @unchecked Sendable {
  typealias Collector = @Sendable (URL) -> [App.Bundle]

  private struct Slot {
    var generation = 0
    var isCollecting = false
    var mostRecentBundles = [App.Bundle]()
  }

  private let condition = NSCondition()
  private var slots = [URL: Slot]()
  private let collector: Collector
  private let waiterDidJoin: @Sendable () -> Void

  init(
    collector: @escaping Collector,
    waiterDidJoin: @escaping @Sendable () -> Void = {}
  ) {
    self.collector = collector
    self.waiterDidJoin = waiterDidJoin
  }

  func collectBundles(at url: URL) -> [App.Bundle] {
    let key = url.standardizedFileURL
    condition.lock()
    var slot = slots[key] ?? Slot()
    if slot.isCollecting {
      let awaitedGeneration = slot.generation
      waiterDidJoin()
      while slots[key, default: Slot()].generation == awaitedGeneration {
        condition.wait()
      }
      let bundles = slots[key, default: Slot()].mostRecentBundles
      condition.unlock()
      return bundles
    }

    slot.isCollecting = true
    slots[key] = slot
    condition.unlock()

    let bundles = collector(key)

    condition.lock()
    slot = slots[key] ?? Slot()
    slot.generation &+= 1
    slot.isCollecting = false
    slot.mostRecentBundles = bundles
    slots[key] = slot
    condition.broadcast()
    condition.unlock()
    return bundles
  }
}

private final class BundleMetadataCache: Sendable {
  private struct Entry: Sendable {
    let signature: BundleFileSignature
    let bundle: App.Bundle
  }

  private let entries = Mutex([URL: Entry]())

  func bundle(forAppAt url: URL, signature: BundleFileSignature, loader: () -> App.Bundle?) -> App
    .Bundle?
  {
    let key = url.standardizedFileURL

    if let cachedBundle = entries.withLock({ $0[key] }) {
      if cachedBundle.signature == signature {
        return cachedBundle.bundle
      }
    }

    guard let bundle = loader() else {
      removeBundle(forAppAt: url)
      return nil
    }

    entries.withLock { entries in
      entries[key] = Entry(signature: signature, bundle: bundle)
    }
    return bundle
  }

  func removeBundle(forAppAt url: URL) {
    let key = url.standardizedFileURL
    entries.withLock { entries in
      _ = entries.removeValue(forKey: key)
    }
  }

  func pruneEntries(below rootURL: URL, keeping retainedURLs: Set<URL>) {
    let rootPath = rootURL.standardizedFileURL.path
    let descendantPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
    let retainedURLs = Set(retainedURLs.map(\.standardizedFileURL))

    entries.withLock { entries in
      entries = entries.filter { url, _ in
        let path = url.path
        guard path == rootPath || path.hasPrefix(descendantPrefix) else { return true }
        return retainedURLs.contains(url)
      }
    }
  }
}

private final class BundleCollectionCountCache: Sendable {
  private struct Entry: Sendable {
    let count: Int
    let collectedAt: Date
    var lastAccessedAt: Date
  }

  private let entries = Mutex([URL: Entry]())
  private let lifetime: TimeInterval = 60
  private let maximumEntryCount = 64

  func count(for url: URL) -> Int? {
    let key = url.standardizedFileURL
    let now = Date()
    return entries.withLock { entries in
      guard var entry = entries[key], now.timeIntervalSince(entry.collectedAt) < lifetime else {
        entries[key] = nil
        return nil
      }
      entry.lastAccessedAt = now
      entries[key] = entry
      return entry.count
    }
  }

  func store(_ count: Int, for url: URL) {
    let key = url.standardizedFileURL
    let now = Date()
    entries.withLock { entries in
      entries[key] = Entry(count: count, collectedAt: now, lastAccessedAt: now)
      while entries.count > maximumEntryCount {
        guard
          let leastRecentlyUsedKey = entries.min(by: {
            $0.value.lastAccessedAt < $1.value.lastAccessedAt
          })?.key
        else { return }
        entries[leastRecentlyUsedKey] = nil
      }
    }
  }
}

private struct BundleFileSignature: Equatable, Sendable {
  let resources: FileSystemItemSignature?
  let infoPlist: FileSystemItemSignature
  let standardReceipt: FileSystemItemSignature?
  let codeSignature: FileSystemItemSignature?

  /// Reuses the metadata already read for cache invalidation instead of
  /// issuing a second set of `stat` calls when constructing `App.Bundle`.
  var bundleModificationDate: Date {
    [
      resources,
      Optional(infoPlist),
      codeSignature,
    ]
    .compactMap { $0?.modificationDate }
    .max() ?? .distantPast
  }

  init?(appURL: URL) {
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
    let infoPlistURL = contentsURL.appendingPathComponent("Info.plist", isDirectory: false)
    guard let infoPlist = FileSystemItemSignature(url: infoPlistURL) else {
      return nil
    }

    let standardReceiptURL = contentsURL.appendingPathComponent(
      "_MASReceipt/receipt", isDirectory: false)

    self.resources = FileSystemItemSignature(url: resourcesURL)
    self.infoPlist = infoPlist
    self.standardReceipt = FileSystemItemSignature(url: standardReceiptURL)
    self.codeSignature = FileSystemItemSignature(
      url: contentsURL.appendingPathComponent("_CodeSignature/CodeResources", isDirectory: false))
  }
}

private struct FileSystemItemSignature: Equatable, Sendable {
  let modificationSeconds: Int
  let modificationNanoseconds: Int
  let size: Int64

  var modificationDate: Date {
    Date(
      timeIntervalSince1970: TimeInterval(modificationSeconds)
        + TimeInterval(modificationNanoseconds) / 1_000_000_000
    )
  }

  init?(url: URL) {
    var fileInfo = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return stat(path, &fileInfo)
    }
    guard result == 0 else { return nil }

    self.modificationSeconds = Int(fileInfo.st_mtimespec.tv_sec)
    self.modificationNanoseconds = Int(fileInfo.st_mtimespec.tv_nsec)
    self.size = fileInfo.st_size
  }
}

extension Bundle {

  /// Returns the bundle info dictionary which is guaranteed to be current.
  fileprivate static func infoDictionary(forAppAt url: URL) -> [String: Any]? {
    let infoPlistURL = url.appendingPathComponent("Contents/Info.plist", isDirectory: false)
    guard let data = try? Data(contentsOf: infoPlistURL) else {
      return nil
    }

    return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
      as? [String: Any]
  }

}

extension Dictionary where Key == String, Value == Any {

  /// Returns the bundle identifier when working without Spotlight.
  fileprivate var bundleIdentifier: String? {
    return self["CFBundleIdentifier"] as? String
  }

  /// Returns the bundle name when working without Spotlight.
  fileprivate var bundleName: String? {
    return self["CFBundleName"] as? String
      ?? self["CFBundleDisplayName"] as? String
      ?? self["CFBundleExecutable"] as? String
  }

  /// Returns the short version string when working without Spotlight.
  fileprivate var versionNumber: String? {
    return self["CFBundleShortVersionString"] as? String
  }

  /// Returns the bundle version when working without Spotlight.
  fileprivate var bundleVersion: String? {
    return self["CFBundleVersion"] as? String
  }
}
