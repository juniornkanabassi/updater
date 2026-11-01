//
//  UpdateRepository.swift
//  Latest
//
//  Created by Max Langer on 01.10.23.
//  Copyright © 2023 Max Langer. All rights reserved.
//

import Foundation
import Synchronization

extension UpdateRepository {

  /// Represents one application within the repository.
  struct Entry: Decodable {
    struct CompactRecord: Codable, Sendable {
      let token: String
      let rawVersion: String
      let urlString: String?
      let homepageString: String?
      let description: String?
      let names: [String]
      let bundleIdentifiers: [String]
      let requiresBundleIdentifierMatch: Bool
      let minimumOSVersion: [Int]?
    }

    // MARK:  - Structure

    enum CodingKeys: String, CodingKey {
      case artifacts
      case desc
      case homepage
      case names = "name"
      case token
      case url
      case rawVersion = "version"
      case minimumOSVersion = "depends_on"
    }

    private struct MinimumOS: Decodable {
      let macos: Version?

      struct Version: Decodable {
        let version: [String]?

        enum CodingKeys: String, CodingKey {
          case version = ">="
        }
      }
    }

    private final class LazyMetadata: Sendable {
      private enum ReleaseNotesState: Sendable {
        case uninitialized
        case value(catalogRevision: UInt64, App.Update.ReleaseNotes?)
      }

      private struct State: Sendable {
        var version: Version?
        var releaseNotes: ReleaseNotesState = .uninitialized
      }

      let rawVersion: String
      let urlString: String?
      let homepageString: String?
      let desc: String?
      let names: Set<String>
      let token: String
      private let state = Mutex(State())

      init(
        rawVersion: String,
        urlString: String?,
        homepageString: String?,
        desc: String?,
        names: Set<String>,
        token: String
      ) {
        self.rawVersion = rawVersion
        self.urlString = urlString
        self.homepageString = homepageString
        self.desc = desc
        self.names = names
        self.token = token
      }

      var version: Version {
        state.withLock { state in
          if let version = state.version {
            return version
          }
          let version = VersionParser.parse(combinedVersionNumber: rawVersion)
          state.version = version
          return version
        }
      }

      var releaseNotes: App.Update.ReleaseNotes? {
        state.withLock { state in
          let catalogRevision = ReleaseNotesSourceCatalog.revision
          if case .value(let cachedRevision, let releaseNotes) = state.releaseNotes,
            cachedRevision == catalogRevision
          {
            return releaseNotes
          }

          guard !names.isEmpty else {
            state.releaseNotes = .value(catalogRevision: catalogRevision, nil)
            return nil
          }

          let version: Version
          if let cachedVersion = state.version {
            version = cachedVersion
          } else {
            version = VersionParser.parse(combinedVersionNumber: rawVersion)
            state.version = version
          }

          let releaseNotes = makeReleaseNotes(version: version)
          state.releaseNotes = .value(catalogRevision: catalogRevision, releaseNotes)
          return releaseNotes
        }
      }

      private func makeReleaseNotes(version: Version) -> App.Update.ReleaseNotes? {
        let url = urlString.flatMap { URL(string: $0) }
        let homepage = homepageString.flatMap { URL(string: $0) }
        let genericMetadataHTML = Entry.genericMetadataHTML(
          version: version,
          names: names,
          token: token,
          desc: desc,
          homepage: homepage
        )
        if let catalogReleaseNotes = ReleaseNotesSourceCatalog.releaseNotes(
          forHomebrewToken: token,
          version: version
        ) {
          return catalogReleaseNotes
        }

        if let githubReleaseURL = Entry.githubReleaseURL(fromDownloadURL: url)
          ?? Entry.githubReleaseURL(fromHomepage: homepage)
        {
          return .githubRelease(apiURL: githubReleaseURL, fallbackHTML: nil)
        }

        return genericMetadataHTML.map { .genericMetadata(string: $0) }
      }
    }

    // MARK: - Accessors

    /// Possible names of the app.
    ///
    /// Used for matching app bundles with repository entries.
    let names: Set<String>

    /// Possible bundle identifiers of the app.
    ///
    /// Used for matching app bundles with repository entries.
    let bundleIdentifiers: Set<String>

    /// Whether this entry was matched through broad cask metadata and must be verified with its bundle identifier.
    let requiresBundleIdentifierMatch: Bool

    /// The current version of the app, parsed only after the entry matches an installed app.
    var version: Version {
      metadata.version
    }

    /// The brew identifier for the app.
    let token: String

    /// The minimum os version required for the update.
    let minimumOSVersion: OperatingSystemVersion?

    /// Release notes derived from upstream metadata where possible.
    ///
    /// Repository decoding touches thousands of casks, while only installed apps ever use
    /// this value. Keep source construction demand-driven so decoding does not build fallback
    /// HTML and speculative URL arrays for every catalog entry.
    var releaseNotes: App.Update.ReleaseNotes? {
      metadata.releaseNotes
    }

    private let metadata: LazyMetadata

    init(compactRecord: CompactRecord) {
      token = compactRecord.token
      names = Set(compactRecord.names)
      bundleIdentifiers = Set(compactRecord.bundleIdentifiers)
      requiresBundleIdentifierMatch = compactRecord.requiresBundleIdentifierMatch
      if let components = compactRecord.minimumOSVersion, let major = components.first {
        minimumOSVersion = OperatingSystemVersion(
          majorVersion: major,
          minorVersion: components.count > 1 ? components[1] : 0,
          patchVersion: components.count > 2 ? components[2] : 0
        )
      } else {
        minimumOSVersion = nil
      }
      metadata = LazyMetadata(
        rawVersion: compactRecord.rawVersion,
        urlString: compactRecord.urlString,
        homepageString: compactRecord.homepageString,
        desc: compactRecord.description,
        names: names,
        token: token
      )
    }

    var compactRecord: CompactRecord {
      let minimumOSVersion = minimumOSVersion.map {
        [$0.majorVersion, $0.minorVersion, $0.patchVersion]
      }
      return CompactRecord(
        token: token,
        rawVersion: metadata.rawVersion,
        urlString: metadata.urlString,
        homepageString: metadata.homepageString,
        description: metadata.desc,
        names: names.sorted(),
        bundleIdentifiers: bundleIdentifiers.sorted(),
        requiresBundleIdentifierMatch: requiresBundleIdentifierMatch,
        minimumOSVersion: minimumOSVersion
      )
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      // Decode only matching metadata first. Non-app casks never enter the repository index.
      token = try container.decode(String.self, forKey: .token)

      // Artifacts: Contains application names and bundle identifiers.
      let artifacts = try container.decode([FailableDecodable<Artifact>].self, forKey: .artifacts)
        .reduce(into: (names: [String](), identifiers: [String]())) { result, artifactWrapper in
          guard let artifact = artifactWrapper.base else {
            return
          }

          result.names.append(contentsOf: artifact.names)
          result.identifiers.append(contentsOf: artifact.identifiers)
        }
      bundleIdentifiers = Set(artifacts.identifiers)
      let artifactNames = Set(artifacts.names)

      if artifactNames.isEmpty, !bundleIdentifiers.isEmpty {
        let displayNames = try container.decodeIfPresent([String].self, forKey: .names) ?? []
        names = Set(displayNames.compactMap(\.homebrewAppBundleName))
        requiresBundleIdentifierMatch = !names.isEmpty
      } else {
        names = artifactNames
        requiresBundleIdentifierMatch = false
      }

      guard !names.isEmpty else {
        minimumOSVersion = nil
        metadata = LazyMetadata(
          rawVersion: "",
          urlString: nil,
          homepageString: nil,
          desc: nil,
          names: names,
          token: token
        )
        return
      }

      let rawVersion = try container.decode(String.self, forKey: .rawVersion)
      let urlString = try container.decodeIfPresent(String.self, forKey: .url)
      let homepageString = try container.decodeIfPresent(String.self, forKey: .homepage)
      let desc = try container.decodeIfPresent(String.self, forKey: .desc)

      // OS Version
      if let osVersion = try container.decode(MinimumOS.self, forKey: .minimumOSVersion).macos?
        .version?.first
      {
        minimumOSVersion = try OperatingSystemVersion(string: osVersion)
      } else {
        minimumOSVersion = nil
      }

      metadata = LazyMetadata(
        rawVersion: rawVersion,
        urlString: urlString,
        homepageString: homepageString,
        desc: desc,
        names: names,
        token: token
      )

    }

    /// Whether the cask represents the default stable channel.
    var isStableRelease: Bool {
      return !token.contains("@")
    }

  }

}

extension UpdateRepository.Entry {

  fileprivate static func githubReleaseURL(fromDownloadURL url: URL?) -> URL? {
    guard let url, url.host?.caseInsensitiveCompare("github.com") == .orderedSame else {
      return nil
    }

    let components = url.pathComponents
    guard components.count > 5, components[3] == "releases" else { return nil }

    let owner = components[1]
    let repository = components[2]
    if components[4] == "latest", components[5] == "download" {
      return URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")
    }

    guard components[4] == "download" else { return nil }

    let tag = components[5]
    return URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/tags/\(tag)")
  }

  fileprivate static func githubReleaseURL(fromHomepage homepage: URL?) -> URL? {
    guard let homepage, homepage.host?.caseInsensitiveCompare("github.com") == .orderedSame else {
      return nil
    }
    let components = homepage.pathComponents.filter { $0 != "/" }
    guard components.count == 2 else { return nil }

    let owner = components[0]
    let repository = components[1].replacingOccurrences(of: ".git", with: "")
    guard !owner.isEmpty, !repository.isEmpty else { return nil }
    return URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")
  }

  fileprivate static func genericMetadataHTML(
    version: Version, names: Set<String>, token: String, desc: String?, homepage: URL?
  ) -> String? {
    guard let versionNumber = version.versionNumber ?? version.buildNumber else {
      return nil
    }

    let title = names.min()?.homebrewDisplayName ?? token
    let description = desc?.trimmingCharacters(in: .whitespacesAndNewlines)

    var paragraphs = [
      "<p><strong>\(title.htmlEscaped) \(versionNumber.htmlEscaped)</strong> is available from Homebrew.</p>"
    ]

    if let description, !description.isEmpty {
      paragraphs.append("<p>\(description.htmlEscaped)</p>")
    }

    if let homepage {
      let homepageString = homepage.absoluteString
      paragraphs.append(
        "<p><a href=\"\(homepageString.htmlEscaped)\">\(homepageString.htmlEscaped)</a></p>")
    }

    return paragraphs.joined()
  }

}

extension String {

  fileprivate var homebrewDisplayName: String {
    if hasSuffix(".app") {
      return String(dropLast(4))
    }

    return self
  }

}

extension String {

  fileprivate var htmlEscaped: String {
    replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

}

extension UpdateRepository.Entry {

  /// One entry datapoint containing possible application names and bundle identifiers.
  fileprivate struct Artifact: Decodable {

    /// Possible application names.
    let names: Set<String>

    /// Possible bundle identifiers.
    let identifiers: Set<String>

    private enum CodingKeys: String, CodingKey {
      /// Contains application names
      case app

      /// Contains paths to files and folders that should be deleted upon deinstallation.
      ///
      /// These paths usually contain the bundle identifier of an app so we extract those from the paths.
      case zap

      /// Contains file paths and identifiers.
      ///
      /// Both app names and identifiers can be extracted from this data set.
      case uninstall
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      var names = [String]()
      var identifiers = [String]()
      var identifierPaths = [String]()

      // App names.
      if let appNames = try? Self.decodeAppNames(container) {
        names.append(contentsOf: appNames)
      }

      // Extract everything else.
      identifierPaths.append(contentsOf: (try? Self.decodeZap(container)) ?? [])
      if let uninstall = try? Self.decodeUninstall(container) {
        names.append(contentsOf: uninstall.names)
        identifiers.append(contentsOf: uninstall.identifiers)
      }

      self.names = Set(names)
      self.identifiers = Set(
        identifiers
          + identifierPaths.flatMap { path in
            let string = path as NSString
            guard !string.pathExtension.isEmpty else { return [String]() }
            let identifier = string.lastPathComponent
            return [identifier, (identifier as NSString).deletingPathExtension]
          })

    }

    // MARK: - Decoding

    private static func decodeAppNames(_ container: KeyedDecodingContainer<CodingKeys>) throws
      -> [String]
    {
      struct Target: Decodable {
        let target: String
      }

      var appContainer = try container.nestedUnkeyedContainer(forKey: .app)
      var names: [String] = []
      while !appContainer.isAtEnd {
        do {
          let target = try appContainer.decode(Target.self)
          names.append(target.target)
        } catch {
          let stringValue = try appContainer.decode(String.self)
          names.append(stringValue)
        }
      }

      return names
    }

    private static func decodeZap(_ container: KeyedDecodingContainer<CodingKeys>) throws
      -> [String]
    {
      enum ZapKeys: String, CodingKey {
        case trash
        case delete
      }

      var nestedContainer = try container.nestedUnkeyedContainer(forKey: .zap)
      let zapContainer = try nestedContainer.nestedContainer(keyedBy: ZapKeys.self)
      return ((try? zapContainer.decodeVariable(String.self, forKey: .trash)) ?? [])
        + ((try? zapContainer.decodeVariable(String.self, forKey: .delete)) ?? [])
    }

    private static func decodeUninstall(_ container: KeyedDecodingContainer<CodingKeys>) throws -> (
      names: [String], identifiers: [String]
    ) {
      enum UninstallKeys: String, CodingKey {
        /// List of bundle identifiers of binaries to be closed before uninstallation.
        case quit

        /// List of binary paths to be deleted separately.
        case delete

        /// List of bundle identifiers of binaries to be deleted separately..
        case pkgutil
      }

      guard var a = try? container.nestedUnkeyedContainer(forKey: .uninstall),
        let uninstallContainer = try? a.nestedContainer(keyedBy: UninstallKeys.self)
      else { return ([], []) }

      // Try to get application names
      let names: [String] =
        (try? uninstallContainer.decodeVariable(String.self, forKey: .delete))?.compactMap { path in
          let url = URL(fileURLWithPath: path)
          guard url.pathExtension == "app" else { return nil }
          return url.lastPathComponent
        } ?? []

      // Try to get bundle identifiers
      let identifiers = [UninstallKeys.pkgutil, .quit].flatMap { key in
        (try? uninstallContainer.decodeVariable(String.self, forKey: key)) ?? []
      }

      return (names, identifiers)
    }

  }

}

extension KeyedDecodingContainer {

  /// Returns an array with objects of the given type for the given key.
  ///
  /// Can decode single objects and arrays.
  fileprivate func decodeVariable<T>(_ type: T.Type, forKey key: KeyedDecodingContainer<K>.Key)
    throws -> [T] where T: Decodable
  {
    var value: [T] = []
    do {
      // Attempt to decode single object.
      let identifier = try decode(T.self, forKey: key)
      value.append(identifier)
    } catch {
      // Must be an array now.
      value = try decode([T].self, forKey: key)
    }
    return value
  }

}

extension String {

  /// Returns the value as an application bundle name.
  fileprivate var homebrewAppBundleName: String? {
    let name = trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    guard (name as NSString).pathExtension.caseInsensitiveCompare("app") != .orderedSame else {
      return name
    }

    return name + ".app"
  }

}
