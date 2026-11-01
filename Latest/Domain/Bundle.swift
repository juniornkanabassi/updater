//
//  AppUpdater.swift
//  Latest
//
//  Created by Max Langer on 15.02.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import Darwin
import Foundation

extension App {

  /// An object representing a single application that is available on the computer.
  final class Bundle: Sendable {

    typealias Identifier = URL

    /// The version currently present on the users computer
    let version: Version

    /// The display name of the app
    let name: String

    /// The unique identifier of the bundle, equal to the URL of the bundle.
    let identifier: Identifier

    /// The bundle identifier of the app.
    let bundleIdentifier: String

    /// The url of the app on the users computer
    let fileURL: URL

    /// The date the bundle was last modified.
    let modificationDate: Date

    /// The source of the bundle (App Store, Sparkle...)
    let source: Source

    init(
      version: Version,
      name: String,
      bundleIdentifier: String,
      fileURL: URL,
      source: Source,
      modificationDate: Date? = nil
    ) {
      self.version = version
      self.name = name
      self.identifier = fileURL
      self.bundleIdentifier = bundleIdentifier
      self.fileURL = fileURL
      self.source = source

      self.modificationDate = modificationDate ?? Self.modificationDate(forBundleAt: fileURL)
    }

    /// Bundle identity is its path; check results additionally belong to the
    /// exact installed metadata that was checked.
    func matchesMetadata(of other: App.Bundle) -> Bool {
      identifier == other.identifier
        && version.versionNumber == other.version.versionNumber
        && version.buildNumber == other.version.buildNumber
        && name == other.name && bundleIdentifier == other.bundleIdentifier
        && source == other.source && modificationDate == other.modificationDate
    }

    private static func modificationDate(forBundleAt fileURL: URL) -> Date {
      let candidateURLs = [
        fileURL,
        fileURL.appendingPathComponent("Contents", isDirectory: true),
        fileURL.appendingPathComponent("Contents/Info.plist", isDirectory: false),
        fileURL.appendingPathComponent("Contents/PkgInfo", isDirectory: false),
        fileURL.appendingPathComponent("Contents/MacOS", isDirectory: true),
        fileURL.appendingPathComponent("Contents/Resources", isDirectory: true),
        fileURL.appendingPathComponent("Contents/Frameworks", isDirectory: true),
        fileURL.appendingPathComponent("Contents/_CodeSignature/CodeResources", isDirectory: false),
      ]

      return candidateURLs.compactMap(modificationDate).max() ?? Date.distantPast
    }

    private static func modificationDate(for url: URL) -> Date? {
      var fileInfo = stat()
      let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return stat(path, &fileInfo)
      }
      guard result == 0 else { return nil }

      return Date(
        timeIntervalSince1970: TimeInterval(fileInfo.st_mtimespec.tv_sec) + TimeInterval(
          fileInfo.st_mtimespec.tv_nsec) / 1_000_000_000
      )
    }

  }

}

extension App.Bundle: Equatable {
  /// Compares two apps on equality
  static func == (lhs: App.Bundle, rhs: App.Bundle) -> Bool {
    return lhs.fileURL == rhs.fileURL
  }
}

extension App.Bundle: Hashable {
  func hash(into hasher: inout Hasher) {
    hasher.combine(self.identifier)
  }
}

extension App.Bundle: CustomDebugStringConvertible {
  var debugDescription: String {
    return "\(name), \(version)"
  }
}
