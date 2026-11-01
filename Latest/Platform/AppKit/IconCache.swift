//
//  IconCache.swift
//  Latest
//
//  Created by Max Langer on 12.08.18.
//  Copyright © 2018 Max Langer. All rights reserved.
//

import AppKit

/// A cache for app icons.
@MainActor
class IconCache {

  /// The shared cache object.
  static let shared = IconCache()

  /// Initializes the cache.
  private init() {
    self.cache = NSCache()
    self.cache.countLimit = 256
    self.cache.totalCostLimit = 64 * 1_024 * 1_024
  }

  /// The object storing app images.
  private let cache: NSCache<NSString, NSImage>
  private var missingApplicationIcon: NSImage?

  /// Loads an icon before a row is displayed, avoiding a blank first frame.
  func iconImmediately(for app: App) -> NSImage {
    loadIcon(for: app)
  }

  /// Returns an icon after an asynchronous scheduling boundary. SwiftUI tasks
  /// use this form so a cache hit cannot mutate view state during rendering.
  func icon(for app: App) async -> NSImage {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.main.async {
        continuation.resume()
      }
    }
    return loadIcon(for: app)
  }

  private func loadIcon(for app: App) -> NSImage {
    let cacheKey = cacheKey(for: app)
    if let icon = cache.object(forKey: cacheKey) { return icon }

    // Discovery results normally point to real bundles. Fixtures, stale
    // volumes, and benchmark rows can point at missing paths; asking
    // NSWorkspace to rediscover the same generic icon for every such path
    // blocks scrolling and needlessly fills the cache with identical images.
    guard FileManager.default.fileExists(atPath: app.fileURL.path) else {
      if let missingApplicationIcon {
        return missingApplicationIcon
      }
      let icon = NSWorkspace.shared.icon(forFile: app.fileURL.path)
      missingApplicationIcon = icon
      return icon
    }

    let icon = NSWorkspace.shared.icon(forFile: app.fileURL.path)
    let pixelCount = max(Int(icon.size.width * icon.size.height), 1)
    self.cache.setObject(icon, forKey: cacheKey, cost: pixelCount * 4)
    return icon
  }

  private func cacheKey(for app: App) -> NSString {
    "\(app.fileURL.standardizedFileURL.path)\u{0}\(app.bundle.modificationDate.timeIntervalSinceReferenceDate)"
      as NSString
  }

}
