//
//  AppDirectoryStore.swift
//  Latest
//
//  Created by Max Langer on 05.07.24.
//  Copyright © 2024 Max Langer. All rights reserved.
//

import Foundation

typealias AppDirectoryUpdateHandler = @MainActor @Sendable () -> Void

protocol AppDirectoryStoring: AnyObject {
  var URLs: [URL] { get }
  func add(_ url: URL)
  func insert(_ url: URL, at index: Int)
  func remove(_ url: URL)
  func canRemove(_ url: URL) -> Bool
  func isReachable(_ url: URL) -> Bool
}

/// Object that takes care of storing and observing application directories.
final class AppDirectoryStore: AppDirectoryStoring {

  private let observer: NSKeyValueObservation?
  private let defaults: UserDefaults

  /// Initializes the store with the given update handler.
  init(defaults: UserDefaults = .standard, updateHandler: @escaping AppDirectoryUpdateHandler) {
    self.defaults = defaults
    observer = defaults.observe(
      \.directoryPaths,
      changeHandler: { _, _ in
        Task { @MainActor in
          updateHandler()
        }
      })
  }

  // MARK: - URLs

  /// The URLs stored in this object.
  var URLs: [URL] {
    (Self.defaultURLs + customURLs).deduplicated()
  }

  /// Set of URLs that will always be checked.
  private static let defaultURLs: [URL] = {
    let fileManager = FileManager.default
    let applicationURLs = [FileManager.SearchPathDomainMask.localDomainMask, .userDomainMask]
      .flatMap { (domainMask) -> [URL] in
        return fileManager.urls(for: .applicationDirectory, in: domainMask)
      }

    return applicationURLs.filter { url -> Bool in
      return fileManager.fileExists(atPath: url.path)
    }.deduplicated()
  }()

  /// User-definable URLs.
  private var customURLs: [URL] {
    get {
      guard let paths = defaults.directoryPaths else { return [] }

      return paths.map { path in
        URL(filePath: path, directoryHint: .isDirectory, relativeTo: nil)
      }
    }

    set {
      defaults.directoryPaths = newValue.map { $0.relativePath }
    }
  }

  // MARK: - Actions

  /// Adds the given URL to the store.
  ///
  /// This method does nothing if the URL already exists.
  func add(_ url: URL) {
    // Ignore adding the same URL multiple times
    guard !URLs.contains(url) else { return }
    customURLs.append(url)
  }

  func insert(_ url: URL, at index: Int) {
    guard !URLs.contains(url) else { return }
    // Translate the visible index into stored paths without rewriting hidden duplicates.
    var paths = defaults.directoryPaths ?? []
    var seen = Set(Self.defaultURLs.map(\.standardizedFileURL))
    var visibleIndex = Self.defaultURLs.count
    var storageIndex = paths.endIndex
    for (rawIndex, path) in paths.enumerated() {
      let existing = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
      guard seen.insert(existing).inserted else { continue }
      if visibleIndex >= index {
        storageIndex = rawIndex
        break
      }
      visibleIndex += 1
    }
    paths.insert(url.relativePath, at: storageIndex)
    defaults.directoryPaths = paths
  }

  /// Removes the custom URL, if set.
  func remove(_ url: URL) {
    customURLs.removeAll(where: { $0 == url })
  }

  /// Whether the URL can be removed from the store.
  func canRemove(_ url: URL) -> Bool {
    customURLs.contains(url) && !Self.defaultURLs.contains(url)
  }

  /// Whether the url currently reachable.
  func isReachable(_ url: URL) -> Bool {
    (try? url.checkResourceIsReachable()) == true
  }
}

extension UserDefaults {
  private static let directoryPathsKey = "directoryPaths"
  @objc dynamic var directoryPaths: [String]? {
    get {
      stringArray(forKey: Self.directoryPathsKey)
    }
    set {
      setValue(newValue, forKey: Self.directoryPathsKey)
    }
  }
}

extension Array where Element == URL {
  fileprivate func deduplicated() -> [URL] {
    var seen = Set<URL>()
    return filter { url in
      seen.insert(url.standardizedFileURL).inserted
    }
  }
}
