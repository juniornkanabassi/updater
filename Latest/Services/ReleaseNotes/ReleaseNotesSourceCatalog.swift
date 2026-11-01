//
//  ReleaseNotesSourceCatalog.swift
//  Latest
//
//  Runtime index for bundled and remotely refreshed release-note source definitions.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import OSLog
import Synchronization

enum ReleaseNotesSourceCatalog {
  static let didRefreshNotification = Notification.Name("ReleaseNotesSourceCatalogDidRefresh")

  private struct Index: Sendable {
    let definitions: [ReleaseNotesSourceDefinition]
    let definitionsByKey: [String: ReleaseNotesSourceDefinition]

    init(document: ReleaseNotesCatalogDocument) {
      definitions = document.definitions
      definitionsByKey = document.definitions.reduce(into: [:]) { result, definition in
        for key in definition.keys + definition.homebrewTokens {
          result[ReleaseNotesSourceCatalog.normalizedKey(key)] = definition
        }
      }
    }
  }

  private struct State: Sendable {
    var index: Index
    var revision: UInt64
  }

  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
    category: "ReleaseNotesCatalog"
  )
  private static let bundledData: Data = {
    guard let url = Bundle.main.url(forResource: "ReleaseNotesSources", withExtension: "json"),
      let data = try? Data(contentsOf: url)
    else {
      return Data()
    }
    return data
  }()
  private static let state = Mutex<State>(
    {
      guard let document = try? ReleaseNotesCatalogCodec.decodeBundled(bundledData) else {
        return State(
          index: Index(
            document: ReleaseNotesCatalogDocument(
              schemaVersion: ReleaseNotesCatalogDocument.supportedSchemaVersion,
              definitions: []
            )),
          revision: 0
        )
      }
      return State(index: Index(document: document), revision: 0)
    }())

  static var revision: UInt64 {
    state.withLock { $0.revision }
  }

  @discardableResult
  static func refresh(client: SignedReleaseNotesCatalogClient? = nil) async -> UInt64 {
    guard !bundledData.isEmpty else {
      logger.error("Bundled release-notes catalog is unavailable")
      return revision
    }

    do {
      let client =
        client
        ?? SignedReleaseNotesCatalogClient(
          configuration: .live(), bundledCatalogData: bundledData, cache: .live())
      let loaded = try await client.load()
      guard !Task.isCancelled else { return revision }
      let revision = state.withLock { state in
        state.index = Index(document: loaded.document)
        state.revision &+= 1
        return state.revision
      }
      await MainActor.run {
        NotificationCenter.default.post(name: didRefreshNotification, object: nil)
      }
      logger.info(
        "Activated release-notes catalog origin=\(String(describing: loaded.origin), privacy: .public) definitions=\(loaded.document.definitions.count, privacy: .public) revision=\(revision, privacy: .public)"
      )
      return revision
    } catch {
      logger.error(
        "Could not load release-notes catalog: \(error.localizedDescription, privacy: .public)")
      return revision
    }
  }

  static var catalogHomebrewTokens: [String] {
    state.withLock { state in
      state.index.definitions.flatMap(\.homebrewTokens)
    }
  }

  static func releaseNotes(forHomebrewToken token: String, version: Version) -> App.Update
    .ReleaseNotes?
  {
    releaseNotes(forKey: normalizedKey(token), version: version)
  }

  static func releaseNotes(
    for bundle: App.Bundle,
    remoteVersion: Version,
    allowNameFallback: Bool = true
  ) -> App.Update.ReleaseNotes? {
    if let releaseNotes = releaseNotes(
      forKey: normalizedKey(bundle.bundleIdentifier),
      version: remoteVersion
    ) {
      return releaseNotes
    }

    if allowNameFallback,
      let releaseNotes = releaseNotes(
        forKey: normalizedKey(bundle.name),
        version: remoteVersion
      )
    {
      return releaseNotes
    }

    guard let apiURL = ElectronReleaseNotesSource.githubReleaseAPIURL(forAppAt: bundle.fileURL)
    else {
      return nil
    }
    return .githubRelease(apiURL: apiURL, fallbackHTML: nil)
  }

  private static func releaseNotes(forKey key: String, version: Version) -> App.Update.ReleaseNotes?
  {
    let definition = state.withLock { state in
      state.index.definitionsByKey[key]
    }
    guard let definition else { return nil }
    guard !definition.capabilities.contains(.disabled) else { return nil }
    guard let template = definition.urlTemplate,
      let url = expandedURL(template, version: version)
    else {
      return nil
    }

    let versionPrefix: String? =
      if definition.capabilities.contains(.exactVersion) {
        version.versionNumber
      } else if definition.capabilities.contains(.majorMinorPatchVersion) {
        version.versionNumber.map { $0.split(separator: ".").prefix(3).joined(separator: ".") }
      } else if definition.capabilities.contains(.majorMinorVersion) {
        version.versionNumber?.majorMinorVersionPrefix
      } else {
        nil
      }
    let bundledFallbackHTML =
      definition.capabilities.contains(.bundledFallback)
      ? definition.knownFallbackKey.flatMap {
        knownReleaseNotesHTML(forKey: $0, version: version)
      } : nil

    if definition.capabilities.contains(.changelogHTML) {
      return .changelog(
        urls: [url],
        versionPrefix: versionPrefix,
        allowsLatestFallback: definition.capabilities.contains(.latestSectionFallback),
        fallbackHTML: bundledFallbackHTML
      )
    }
    if definition.capabilities.contains(.githubReleaseAPI) {
      return .githubRelease(apiURL: url, fallbackHTML: bundledFallbackHTML)
    }
    return nil
  }

  private static func expandedURL(_ template: String, version: Version) -> URL? {
    let versionNumber = version.versionNumber.map {
      $0.hasPrefix("v") ? String($0.dropFirst()) : $0
    }
    let major = versionNumber?.split(separator: ".", maxSplits: 1).first.map(String.init)
    let majorMinor = versionNumber?.majorMinorVersionPrefix
    var value = template
    let replacements: [(placeholder: String, replacement: String?)] = [
      ("{version}", versionNumber),
      ("{version-dashes}", versionNumber?.replacingOccurrences(of: ".", with: "-")),
      ("{major}", major),
      ("{major-minor}", majorMinor),
      ("{major-minor-dashes}", majorMinor?.replacingOccurrences(of: ".", with: "-")),
      ("{major-minor-underscores}", majorMinor?.replacingOccurrences(of: ".", with: "_")),
    ]
    for replacement in replacements where value.contains(replacement.placeholder) {
      guard let replacementValue = replacement.replacement else { return nil }
      value = value.replacingOccurrences(of: replacement.placeholder, with: replacementValue)
    }
    return URL(string: value)
  }

  static func releaseNotes(
    forSparkleReleaseNotesURL url: URL, bundle: App.Bundle, remoteVersion: Version
  ) -> App.Update.ReleaseNotes? {
    let host = url.host?.lowercased() ?? ""
    let path = url.path.lowercased()
    guard host == "waydabber.github.io",
      path == "/betterdisplay/changelog.html",
      let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "tag" })?
        .value,
      tag != "pre"
    else {
      return nil
    }

    guard let version = remoteVersion.versionNumber,
      let apiURL = URL(
        string: "https://api.github.com/repos/waydabber/BetterDisplay/releases/tags/v\(version)")
    else {
      return nil
    }

    return .githubRelease(
      apiURL: apiURL,
      fallbackHTML: knownReleaseNotesHTML(forKey: "betterdisplay", version: remoteVersion)
    )
  }

  private static func knownReleaseNotesHTML(forKey key: String, version: Version) -> String? {
    guard key == "betterdisplay", version.versionNumber == "4.3.4" else {
      return nil
    }

    return """
      <h2>BetterDisplay 4.3.4</h2>
      <p>This version is a minor service release with bug fixes and improvements.</p>
      <h3>Fixes, improvements</h3>
      <ul>
      \t<li>Fixed a Direct display brightness Force EDR mode issue that could cause heavy CPU usage and hangs after longer sleep.</li>
      \t<li>Fixed macOS 26.5 Shortcuts opening app Settings when another app action is in the same Shortcut.</li>
      \t<li>Fixed brightness nits in the OSD not being turnable off without Pro.</li>
      \t<li>Fixed a rare resolution slider crash when the resolutions list changes.</li>
      \t<li>Improved menu, OSD, onboarding, and localization behavior.</li>
      </ul>
      <p><a href="https://github.com/waydabber/BetterDisplay/releases/tag/v4.3.4">Full BetterDisplay v4.3.4 release notes</a></p>
      """
  }

  private static func normalizedKey(_ value: String) -> String {
    value.lowercased().filter { character in
      character.isLetter || character.isNumber
    }
  }

}

extension String {
  fileprivate var majorMinorVersionPrefix: String? {
    let parts = split(separator: ".", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return isEmpty ? nil : self }

    return parts.prefix(2).joined(separator: ".")
  }
}
