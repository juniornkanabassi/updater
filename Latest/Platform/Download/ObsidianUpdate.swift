import Foundation

enum ObsidianUpdate {
  struct Release: Decodable, Sendable {
    let minimumVersion: String
    let latestVersion: String
    var isEarlyAccess = false

    private enum CodingKeys: String, CodingKey {
      case minimumVersion, latestVersion
    }
  }

  private struct Manifest: Decodable {
    let stable: Release
    let beta: Release?
    private enum CodingKeys: String, CodingKey { case beta }

    init(from decoder: Decoder) throws {
      stable = try Release(from: decoder)
      beta = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(
        Release.self, forKey: .beta)
    }
  }

  /// Follow Obsidian's explicit user preference, never infer a beta opt-in from version numbers.
  static func release(from data: Data, includesEarlyAccess: Bool) throws -> Release {
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    if includesEarlyAccess, var beta = manifest.beta {
      beta.isEarlyAccess = true
      return beta
    }
    return manifest.stable
  }

  static func check(_ bundle: App.Bundle) async throws -> App.Update {
    var request = URLRequest(
      url: URL(
        string:
          "https://raw.githubusercontent.com/obsidianmd/obsidian-releases/master/desktop-releases.json"
      )!,
      cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65_536 else {
      throw AppDownloadError.invalidMetadata
    }
    let settingsURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
    let settings = (try? Data(contentsOf: settingsURL)).flatMap {
      (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
    }
    return try update(
      for: bundle,
      release: release(from: data, includesEarlyAccess: settings?["insider"] as? Bool == true))
  }

  /// Always a hand-off. Obsidian's update is a payload in ~/Library/Application Support/obsidian
  /// shared by every installed copy, so Updater cannot prove it touches only the selected app.
  /// A compatible launcher updates itself; an outdated one needs Obsidian's installer page.
  static func update(for bundle: App.Bundle, release: Release) throws -> App.Update {
    let version = Version(versionNumber: release.latestVersion, buildNumber: nil)
    let action: App.Update.Action
    if try installerIsCompatible(bundle, with: release) {
      action = .external(label: bundle.name) { app in
        Task { @MainActor in MacApplicationWorkspace.shared.openApplication(at: app.fileURL) }
      }
    } else {
      action = .external(label: "Obsidian Installer") { _ in
        Task { @MainActor in
          MacApplicationWorkspace.shared.open(URL(string: "https://obsidian.md/download")!)
        }
      }
    }
    return App.Update(
      app: bundle, remoteVersion: version, minimumOSVersion: nil, source: .vendor, date: nil,
      releaseNotes: ReleaseNotesSourceCatalog.releaseNotes(for: bundle, remoteVersion: version),
      updateAction: action)
  }

  static func installerIsCompatible(_ bundle: App.Bundle, with release: Release) throws -> Bool {
    let plist = try Data(contentsOf: bundle.fileURL.appendingPathComponent("Contents/Info.plist"))
    let information =
      try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
    let installer = Version(
      versionNumber: information?["CFBundleShortVersionString"] as? String, buildNumber: nil)
    let minimum = Version(versionNumber: release.minimumVersion, buildNumber: nil)
    return [.samePrecedence, .newer].contains(installer.comparisonForUpdate(to: minimum))
  }
}
