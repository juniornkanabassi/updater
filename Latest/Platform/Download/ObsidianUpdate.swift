import CryptoKit
import Foundation
import Security

enum ObsidianUpdate {
  struct Release: Decodable, Sendable {
    let minimumVersion: String
    let latestVersion: String
    let downloadUrl: URL
    let hash: String
    let signature: String
    var isEarlyAccess = false

    private enum CodingKeys: String, CodingKey {
      case minimumVersion, latestVersion, downloadUrl, hash, signature
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
    let release = try release(
      from: data, includesEarlyAccess: settings?["insider"] as? Bool == true)
    let version = Version(versionNumber: release.latestVersion, buildNumber: nil)
    let compatible = try installerIsCompatible(bundle, with: release)
    let canInstall = compatible && !release.isEarlyAccess
    let action: App.Update.Action
    if canInstall {
      action = .builtIn { app in
        UpdateQueue.shared.addOperation(ObsidianUpdateOperation(app: app, release: release))
      }
    } else if release.isEarlyAccess && compatible {
      // Catalyst downloads require Obsidian's authenticated session. Keep its
      // credentials in Obsidian and let its own updater download these releases.
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
      app: bundle, remoteVersion: version, minimumOSVersion: nil,
      source: canInstall ? .directDownload : .vendor, date: nil,
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

  static func verify(_ data: Data, release: Release) throws {
    guard
      SHA256.hash(data: data).withUnsafeBytes({ Data($0).base64EncodedString() }) == release.hash,
      let certificateData = Data(base64Encoded: certificate),
      let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
      let key = SecCertificateCopyKey(certificate),
      let signature = Data(base64Encoded: release.signature),
      SecKeyVerifySignature(
        key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    else { throw AppDownloadError.checksumMismatch }
  }

  // Obsidian's public payload-signing certificate, shipped by its desktop launcher.
  private static let certificate =
    "MIIDjzCCAnegAwIBAgIJAOFHLJ2gTCBzMA0GCSqGSIb3DQEBCwUAMF4xCzAJBgNVBAYTAlVTMRMwEQYDVQQIDApTb21lLVN0YXRlMREwDwYDVQQKDAhEeW5hbGlzdDERMA8GA1UECwwIRHluYWxpc3QxFDASBgNVBAMMC2R5bmFsaXN0LmlvMB4XDTE2MDUxNjAyMTA1NFoXDTQwMDUxMDAyMTA1NFowXjELMAkGA1UEBhMCVVMxEzARBgNVBAgMClNvbWUtU3RhdGUxETAPBgNVBAoMCER5bmFsaXN0MREwDwYDVQQLDAhEeW5hbGlzdDEUMBIGA1UEAwwLZHluYWxpc3QuaW8wggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDcodSNp30B0oE+2vRUdr//SGfbDow+67OtGuRYQSjn86bn55fQXhMJb5xgZ0natiCriCyllLWgPf+4PnxGRSJZGbm38QSArb0MWR8/yXA+q+7nZisIsN2dXih8B3APImxJ4A50nsK/C+fl7nYdo04iz3oerP0UhLDrsLbL+9rdmshjB1boLPf6QpAAC57OTPQpFBd2hFoS6xAnIb708SHOndsrWDIFEFVCPDYcme3WF5jznuT05OFGMIX8SZe2jXpg2Vco/1oKRPC7mYFN5B0JTZ7mOH48vB/zPNIsVz8KHh3P9Ru2fC2r3nPDXFGKzcUZneJmXh4LIUVqwdEPw7hvAgMBAAGjUDBOMB0GA1UdDgQWBBTF2xMx8xVDZ2wteJPsHUe0OCu18TAfBgNVHSMEGDAWgBTF2xMx8xVDZ2wteJPsHUe0OCu18TAMBgNVHRMEBTADAQH/MA0GCSqGSIb3DQEBCwUAA4IBAQB6rgBF+DvDHifP+U6ZFqJ4mX1nalEXEPI1jvRZaOheKpkOEBbhkCAosbBEmYxfj8xay1GGgB9nkJk2dodRsGVhrZz+CwGR+hSEfYDQwMBvmzm3OcETfEtvwEAU1P93prbxul2oSWP48AVDDYKepxTZvW/yZcnoHI9XzhLNMYIEvOs+wKWAOF0+BjsIukQouaXs6gklul2J99IqpdPhw2l4l7mkPx8htCbTE47GTraHt2i2mwyBZSKbfqzi73Fj5SFRtZlWJDNPKoWxcFg291B7IHumd5jwAUdVJit3K5Tgt/q4OzwokcDZcrh5lJg0+Kstsz4RDWDbfzTNJuKnoueR"
}

final class ObsidianUpdateOperation: DownloadUpdateOperation, @unchecked Sendable {
  private let release: ObsidianUpdate.Release

  init(app: App.Bundle, release: ObsidianUpdate.Release) {
    self.release = release
    super.init(app: app)
  }

  override func performUpdate() async throws {
    guard !release.isEarlyAccess,
      release.latestVersion.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression)
        != nil,
      try ObsidianUpdate.installerIsCompatible(app, with: release)
    else { throw AppDownloadError.invalidMetadata }
    let version = Version(versionNumber: release.latestVersion, buildNumber: nil)
    guard app.version.comparisonForUpdate(to: version) == .older else {
      throw AppDownloadError.versionMismatch
    }
    let manager = FileManager.default
    let work = manager.temporaryDirectory.appendingPathComponent(
      "Latest-Obsidian-" + UUID().uuidString)
    try manager.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: work) }
    let archive = try await download(
      from: release.downloadUrl, into: work, maximumSize: 128 * 1_024 * 1_024)
    try ObsidianUpdate.verify(Data(contentsOf: archive, options: .mappedIfSafe), release: release)
    progressState = .extracting(progress: nil)
    _ = try await InstallerCommand.run("/usr/bin/gzip", ["-d", archive.path])
    let payload = archive.deletingPathExtension()
    guard InstalledAppVersion.asarVersion(at: payload) == release.latestVersion else {
      throw AppDownloadError.versionMismatch
    }
    let support = manager.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/obsidian")
    let stage = support.appendingPathComponent(".latest-update-" + UUID().uuidString)
    try manager.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { Self.removeStageUnlessRecoveryIsNeeded(stage) }
    let candidate = stage.appendingPathComponent("candidate.asar")
    try manager.copyItem(at: payload, to: candidate)
    let target = support.appendingPathComponent("obsidian-\(release.latestVersion).asar")
    try await withApplicationClosed { [self] in
      // The vendor may have completed the same update while Latest was downloading.
      if InstalledAppVersion.asarVersion(at: target) == release.latestVersion { return }
      guard let current = BundleCollector.collectBundle(at: app.fileURL),
        current.version.comparisonForUpdate(to: version) == .older,
        try ObsidianUpdate.installerIsCompatible(current, with: release)
      else { throw AppDownloadError.versionMismatch }
      try beginCommit()
      progressState = .installing
      // Replace a partial same-name payload too; the previous usable version stays intact.
      try Self.replaceItem(at: target, with: candidate, backupDirectory: stage)
    }
  }
}
