//
//  SparkleFeed.swift
//  Latest
//
//  Created by Max Langer on 23.04.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Foundation

enum SparkleFeed {

  /// Returns the Sparkle feed url for the app at the given URL, if available.
  static func feedURL(from bundle: Bundle) -> URL? {
    guard let information = bundle.infoDictionary, let identifier = bundle.bundleIdentifier else {
      return nil
    }

    return feedURL(from: information, bundleIdentifier: identifier, bundleURL: bundle.bundleURL)
  }

  /// Returns the Sparkle feed URL from already-loaded bundle metadata.
  static func feedURL(from information: [String: Any], bundleIdentifier: String, bundleURL: URL)
    -> URL?
  {
    if let urlString = information["SUFeedURL"] as? String,
      let feedURL = URL(string: urlString.unquoted)
    {
      return feedURL
    } else if let feedURL = feedURLOverrides[bundleIdentifier] {
      // Some modern apps configure Sparkle from packaged runtime metadata
      // instead of exposing SUFeedURL in Info.plist. Keep these verified
      // vendor feeds data-driven so name-only Homebrew matching is not used.
      return feedURL
    } else {  // Maybe the app is built using DevMate
      // Check for the DevMate framework
      let frameworksURL = bundleURL.appendingPathComponent("Contents").appendingPathComponent(
        "Frameworks")
      guard FileManager.default.fileExists(atPath: frameworksURL.path) else {
        return nil
      }

      let frameworks = try? FileManager.default.contentsOfDirectory(atPath: frameworksURL.path)
      if !(frameworks?.contains(where: { $0.contains("DevMateKit") }) ?? false) {
        return nil
      }

      // The app uses Devmate, so lets get the appcast from their servers
      guard var feedURL = URL(string: "https://updates.devmate.com") else {
        return nil
      }

      feedURL.appendPathComponent(bundleIdentifier)
      feedURL.appendPathExtension("xml")

      return feedURL
    }
  }

  private struct FeedURLOverride: Decodable {
    let bundleIdentifiers: [String]
    let sparkleFeedURL: URL
  }

  private static let feedURLOverrides: [String: URL] = {
    guard let sourceURL = Bundle.main.url(forResource: "UpdateSources", withExtension: "json"),
      let data = try? Data(contentsOf: sourceURL),
      let overrides = try? JSONDecoder().decode([FeedURLOverride].self, from: data)
    else {
      return [:]
    }

    return overrides.reduce(into: [String: URL]()) { result, override in
      guard override.sparkleFeedURL.scheme == "https" else { return }
      for bundleIdentifier in override.bundleIdentifiers {
        result[bundleIdentifier] = override.sparkleFeedURL
      }
    }
  }()

}

extension String {

  /// Returns the string with quotation marks trimmed.
  fileprivate var unquoted: String {
    return NSString(string: self).trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
  }

}
