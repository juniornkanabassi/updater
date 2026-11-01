import CryptoKit
import Foundation
import Security

/// Installs a verified standalone bundle, retaining the original until replacement succeeds.
final class AppDownloadUpdateOperation: DownloadUpdateOperation, @unchecked Sendable {
  private let source: AppDownloadSource

  init(app: App.Bundle, source: AppDownloadSource) {
    self.source = source
    super.init(app: app)
  }

  override func performUpdate() async throws {
    let release = try await source.release()
    guard app.version.comparisonForUpdate(to: release.version) == .older else {
      throw AppDownloadError.versionMismatch
    }
    let manager = FileManager.default
    let work = manager.temporaryDirectory.appendingPathComponent("Latest-" + UUID().uuidString)
    try manager.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: work) }
    let archive = try await download(from: release.url, into: work)
    if let hash = release.sha256 { try Self.verifyChecksum(of: archive, expected: hash) }

    // Stage on the destination volume before touching the installed app.
    let stage = app.fileURL.deletingLastPathComponent()
      .appendingPathComponent(".latest-update-" + UUID().uuidString)
    try manager.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { Self.removeStageUnlessRecoveryIsNeeded(stage) }
    let candidate = stage.appendingPathComponent("candidate.app")
    let extracted = work.appendingPathComponent("payload")
    try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
    progressState = .extracting(progress: nil)
    try await Self.stageApp(
      from: archive, appPath: release.appPath, extracted: extracted, to: candidate)
    try Self.validate(candidate: candidate, replacing: app, expectedVersion: release.version)
    try await withApplicationClosed { [self] in
      guard let current = BundleCollector.collectBundle(at: app.fileURL),
        current.bundleIdentifier == app.bundleIdentifier, current.version == app.version
      else { throw AppDownloadError.versionMismatch }
      try beginCommit()
      progressState = .installing
      try Self.replaceItem(at: app.fileURL, with: candidate, backupDirectory: stage)
    }
  }

  /// Copies a downloaded bundle into staging and releases any mounted image before returning.
  static func stageApp(from archive: URL, appPath: String, extracted: URL, to candidate: URL)
    async throws
  {
    let isDiskImage = archive.pathExtension == "dmg"
    var diskImageMounted = false
    let preparation: Result<Void, Error>
    do {
      if isDiskImage {
        _ = try await InstallerCommand.run(
          "/usr/bin/hdiutil",
          [
            "attach", archive.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint",
            extracted.path,
          ])
        diskImageMounted = true
      } else {
        try await Self.extractZIP(at: archive, to: extracted)
      }
      let sourceApp = extracted.appendingPathComponent(appPath)
      guard
        sourceApp.resolvingSymlinksInPath().path.hasPrefix(
          extracted.resolvingSymlinksInPath().path + "/")
      else {
        throw AppDownloadError.invalidDownload
      }
      _ = try await InstallerCommand.run("/usr/bin/ditto", [sourceApp.path, candidate.path])
      preparation = .success(())
    } catch { preparation = .failure(error) }
    // A failed attach may still have mounted a volume. Detach only an actual mount.
    if isDiskImage, !diskImageMounted {
      diskImageMounted =
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil)?.contains {
          $0.resolvingSymlinksInPath().path == extracted.resolvingSymlinksInPath().path
        } == true
    }
    var detachError: Error?
    if diskImageMounted {
      do {
        _ = try await InstallerCommand.run(
          "/usr/bin/hdiutil", ["detach", extracted.path], cancellable: false)
      } catch { detachError = error }
    }
    // Preserve the preparation failure, even if cleanup also failed.
    try preparation.get()
    if let detachError { throw detachError }
  }

  static func extractZIP(at archive: URL, to directory: URL) async throws {
    let listing = try await InstallerCommand.run("/usr/bin/zipinfo", ["-1", archive.path])
    guard !listing.isEmpty,
      listing.split(separator: "\n").allSatisfy({
        !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..")
      })
    else { throw AppDownloadError.invalidDownload }
    // ditto also rejects archive members that traverse an extracted symlink.
    _ = try await InstallerCommand.run(
      "/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
  }

  static func verifyChecksum(of url: URL, expected: String) throws {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 1_024 * 1_024), !data.isEmpty {
      try Task.checkCancellation()
      hash.update(data: data)
    }
    let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
    guard actual == expected else { throw AppDownloadError.checksumMismatch }
  }

  static func validateCompatibility(of url: URL) throws {
    guard let bundle = Bundle(url: url),
      bundle.executableArchitectures?.contains(NSNumber(value: AppDownloadSource.hostArchitecture))
        == true
    else { throw AppDownloadError.incompatibleSystem }
    let architecture = AppDownloadSource.hostArchitectureName
    let minimum =
      (bundle.infoDictionary?["LSMinimumSystemVersionByArchitecture"] as? [String: String])?[
        architecture]
      ?? bundle.infoDictionary?["LSMinimumSystemVersion"] as? String
    if let minimum {
      guard let version = try? OperatingSystemVersion(string: minimum),
        ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
      else { throw AppDownloadError.incompatibleSystem }
    }
  }

  static func validate(candidate: URL, replacing app: App.Bundle, expectedVersion: Version) throws {
    guard let installed = BundleCollector.collectBundle(at: candidate),
      installed.bundleIdentifier == app.bundleIdentifier
    else { throw AppDownloadError.identityMismatch }
    guard app.version.comparisonForUpdate(to: installed.version) == .older,
      installed.version.comparisonForUpdate(to: expectedVersion) == .samePrecedence
        || installed.version.comparisonForUpdate(to: expectedVersion) == .newer
    else { throw AppDownloadError.versionMismatch }

    try validateCompatibility(of: candidate)

    var originalCode: SecStaticCode?
    var candidateCode: SecStaticCode?
    var requirement: SecRequirement?
    var information: CFDictionary?
    var candidateInformation: CFDictionary?
    guard SecStaticCodeCreateWithPath(app.fileURL as CFURL, [], &originalCode) == errSecSuccess,
      SecStaticCodeCreateWithPath(candidate as CFURL, [], &candidateCode) == errSecSuccess,
      let originalCode, let candidateCode,
      SecCodeCopySigningInformation(
        originalCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
        == errSecSuccess,
      let team = (information as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
      !team.isEmpty,
      SecCodeCopySigningInformation(
        candidateCode, SecCSFlags(rawValue: kSecCSSigningInformation), &candidateInformation)
        == errSecSuccess,
      (candidateInformation as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        == team,
      SecCodeCopyDesignatedRequirement(originalCode, [], &requirement) == errSecSuccess,
      let requirement,
      SecStaticCodeCheckValidity(
        candidateCode,
        SecCSFlags(
          rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate),
        requirement) == errSecSuccess
    else { throw AppDownloadError.identityMismatch }
  }

}
