//
//  ElectronReleaseNotesSource.swift
//  Latest
//
//  Discovers GitHub update feeds embedded in Electron app bundles.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum ElectronReleaseNotesSource {

  private static let configurationNames = ["app-update.yml", "app-update.yaml"]
  private static let maximumConfigurationSize = 64 * 1_024

  static func githubReleaseAPIURL(forAppAt appURL: URL) -> URL? {
    let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
    for name in configurationNames {
      let configurationURL = resourcesURL.appendingPathComponent(name, isDirectory: false)
      guard let data = try? Data(contentsOf: configurationURL, options: .mappedIfSafe),
        data.count <= maximumConfigurationSize,
        let configuration = String(data: data, encoding: .utf8)
      else {
        continue
      }

      if let apiURL = githubReleaseAPIURL(from: configuration) {
        return apiURL
      }
    }

    return nil
  }

  static func githubReleaseAPIURL(from configuration: String) -> URL? {
    var values = [String: String]()
    for line in configuration.split(whereSeparator: { $0.isNewline }) {
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = parts[1]
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      guard !key.isEmpty, !value.isEmpty else { continue }
      values[key] = value
    }

    guard values["provider"]?.lowercased() == "github",
      let owner = values["owner"],
      let repository = values["repo"],
      isSafeRepositoryComponent(owner),
      isSafeRepositoryComponent(repository)
    else {
      return nil
    }

    return URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")
  }

  private static func isSafeRepositoryComponent(_ component: String) -> Bool {
    !component.isEmpty
      && component.allSatisfy { character in
        character.isLetter || character.isNumber || character == "-" || character == "_"
          || character == "."
      }
  }

}
