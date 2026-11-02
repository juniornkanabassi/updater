import CryptoKit
import Foundation
import Security
import Synchronization

/// Installs a verified standalone bundle, retaining the original until replacement succeeds.
final class AppDownloadUpdateOperation: DownloadUpdateOperation, @unchecked Sendable {
  private let fetchRelease: @Sendable () async throws -> AppDownloadRelease
  /// False only for ad-hoc signed test fixtures; real vendors must keep a Team ID.
  var requiresTeam = true
  /// Launch-and-quit check for fixtures. Real apps are not launched to verify them.
  var launchProbe: (@Sendable (URL) throws -> Void)?

  /// Set for catalogue installs (Round 5b): their extra scope, payload and trust rules.
  private let catalogue: CatalogueJob?

  init(app: App.Bundle, source: AppDownloadSource) {
    fetchRelease = { try await source.release() }
    catalogue = nil
    super.init(app: app)
  }

  /// A catalogue app: the cask is fetched fresh right before installing and must still pass
  /// the allow list; a changed shape refuses.
  init(app: App.Bundle, catalogue: CatalogueJob) {
    fetchRelease = { [bundleIdentifier = app.bundleIdentifier] in
      let data = try await catalogue.check.fetchCask(catalogue.token)
      return try CatalogueInstall.release(fromCask: data, bundleIdentifier: bundleIdentifier)
    }
    self.catalogue = catalogue
    super.init(app: app)
  }

  /// Fixture feeds supply their own release metadata.
  init(app: App.Bundle, release: @escaping @Sendable () async throws -> AppDownloadRelease) {
    fetchRelease = release
    catalogue = nil
    super.init(app: app)
  }

  override func performUpdate() async throws {
    if let catalogue { return try await performCatalogueUpdate(catalogue) }
    let release = try await fetchRelease()
    expectedVersion = release.version
    guard app.version.comparisonForUpdate(to: release.version) == .older else {
      throw AppDownloadError.versionMismatch
    }
    let manager = FileManager.default
    let work = manager.temporaryDirectory.appendingPathComponent("Updater-" + UUID().uuidString)
    try manager.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: work) }
    let archive = try await download(from: release.url, into: work)
    if let hash = release.sha256 { try Self.verifyChecksum(of: archive, expected: hash) }

    // Stage on the destination volume before touching the installed app.
    // Staged and backed up in Updater's own folder on the app's volume.
    let stage = try journal.backupDirectory(for: app.fileURL, id: jobID)
    defer { Self.removeStageUnlessRecoveryIsNeeded(stage) }
    let candidate = stage.appendingPathComponent("candidate.app")
    let extracted = work.appendingPathComponent("payload")
    try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
    progressState = .extracting(progress: nil)
    try await Self.stageApp(
      from: archive, appPath: release.appPath, extracted: extracted, to: candidate)
    try Self.validate(
      candidate: candidate, replacing: app, expectedVersion: release.version,
      requiresTeam: requiresTeam)
    let original = try BundleIdentity.read(at: app.fileURL, validate: false)
    try await withApplicationClosed { [self] in
      guard let current = BundleCollector.collectBundle(at: app.fileURL),
        current.bundleIdentifier == app.bundleIdentifier, current.version == app.version
      else { throw AppDownloadError.versionMismatch }
      try beginCommit()
      progressState = .installing
      try journaledReplace(
        with: candidate, backupDirectory: stage, expectedVersion: release.version
      ) { url in
        try Self.verifyInstalled(
          at: url, original: original, expectedVersion: release.version,
          requiresTeam: requiresTeam, launchProbe: launchProbe)
      }
    }
  }

  /// Round 5b. Scope refusals keep the app on its own route (a hand-off that opens nothing);
  /// payload and trust refusals fail with the reason. The original stays until the
  /// replacement verifies.
  private func performCatalogueUpdate(_ job: CatalogueJob) async throws {
    let check = job.check
    let folder = app.fileURL.deletingLastPathComponent()
    do {
      try CatalogueInstall.checkScope(
        of: app, copies: try check.copies(app.bundleIdentifier), writable: check.isWritable(folder))
    } catch let refusal as CatalogueInstall.Refusal {
      return await keepOwnRoute(refusal)
    }
    let release = try await fetchRelease()
    expectedVersion = release.version
    guard app.version.comparisonForUpdate(to: release.version) == .older,
      release.version.comparisonForUpdate(to: job.minimumVersion) != .older
    else { throw AppDownloadError.versionMismatch }
    let manager = FileManager.default
    let work = manager.temporaryDirectory.appendingPathComponent("Updater-" + UUID().uuidString)
    try manager.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: work) }
    let archive = try await download(
      from: release.url, into: work, allowedDomain: release.allowedDomain)
    // No published checksum is allowed only on the vendor's own domain (checked with the
    // cask); the Trust checks below are what accept such a download.
    if let expected = release.sha256 { try Self.verifyChecksum(of: archive, expected: expected) }
    guard let kind = CatalogueInstall.payloadKind(of: archive) else {
      throw CatalogueInstall.Refusal.payload(
        "The download is not a zip, disk image or tar archive.")
    }

    let stage = try journal.backupDirectory(for: app.fileURL, id: jobID)
    defer { Self.removeStageUnlessRecoveryIsNeeded(stage) }
    let candidate = stage.appendingPathComponent("candidate.app")
    let extracted = work.appendingPathComponent("payload")
    try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
    progressState = .extracting(progress: nil)
    try await Self.stage(from: archive, kind: kind, extracted: extracted, to: candidate) { root in
      let apps = CatalogueInstall.outerApps(in: root)
      guard apps.count == 1, let app = apps.first else {
        throw CatalogueInstall.Refusal.payload(
          "The download holds \(apps.count) apps instead of exactly one.")
      }
      return app
    }
    try Self.validate(
      candidate: candidate, replacing: app, expectedVersion: release.version,
      requiresTeam: requiresTeam)
    do { try await check.assess(candidate) } catch {
      throw CatalogueInstall.Refusal.trust("macOS Gatekeeper did not accept the downloaded app.")
    }
    // brew must still not own it, freshly asked (an unknown answer refuses too).
    guard await check.ownership(app.fileURL, true) == .notOwned else {
      return await keepOwnRoute(
        .scope("Homebrew may own this app (or could not be asked), so Updater leaves it to brew."))
    }
    // Fail closed after staging: our own staged candidate is the only extra copy allowed.
    do {
      try CatalogueInstall.recheck(
        app, copies: try check.copies(app.bundleIdentifier), excluding: stage)
    } catch let refusal as CatalogueInstall.Refusal {
      return await keepOwnRoute(refusal)
    }
    let original = try BundleIdentity.read(at: app.fileURL, validate: false)
    let appearedDuringQuit = Mutex<CatalogueInstall.Refusal?>(nil)
    try await withApplicationClosed { [self] in
      guard let current = BundleCollector.collectBundle(at: app.fileURL),
        current.bundleIdentifier == app.bundleIdentifier, current.version == app.version
      else { throw AppDownloadError.versionMismatch }
      // Again after the quit prompt, with nothing asynchronous before the replacement.
      do {
        try CatalogueInstall.recheck(
          app, copies: try check.copies(app.bundleIdentifier), excluding: stage)
      } catch let refusal as CatalogueInstall.Refusal {
        appearedDuringQuit.withLock { $0 = refusal }
        return
      }
      try beginCommit()
      progressState = .installing
      try journaledReplace(
        with: candidate, backupDirectory: stage, expectedVersion: release.version
      ) { url in
        try Self.verifyInstalled(
          at: url, original: original, expectedVersion: release.version,
          requiresTeam: requiresTeam, launchProbe: launchProbe)
      }
    }
    if let refusal = appearedDuringQuit.withLock({ $0 }) { await keepOwnRoute(refusal) }
  }

  @MainActor private func keepOwnRoute(_ refusal: CatalogueInstall.Refusal) {
    recordHandOff(to: "\(app.name)'s own updater", because: refusal.localizedDescription)
  }

  /// Unpacks an archive of a known kind, copies the app `locate` picks into staging, and
  /// releases a mounted image before returning.
  static func stage(
    from archive: URL, kind: CatalogueInstall.PayloadKind, extracted: URL, to candidate: URL,
    locate: (URL) throws -> URL
  ) async throws {
    var mounted = false
    let preparation: Result<Void, Error>
    do {
      switch kind {
      case .diskImage:
        _ = try await InstallerCommand.run(
          "/usr/bin/hdiutil",
          [
            "attach", archive.path, "-readonly", "-nobrowse", "-noautoopen", "-mountpoint",
            extracted.path,
          ])
        mounted = true
      case .zip: try await extractZIP(at: archive, to: extracted)
      case .tar: try await extractTar(at: archive, to: extracted)
      }
      let source = try locate(extracted)
      guard
        source.resolvingSymlinksInPath().path.hasPrefix(
          extracted.resolvingSymlinksInPath().path + "/")
      else { throw AppDownloadError.invalidDownload }
      _ = try await InstallerCommand.run("/usr/bin/ditto", [source.path, candidate.path])
      preparation = .success(())
    } catch { preparation = .failure(error) }
    if kind == .diskImage, !mounted {
      mounted =
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil)?.contains {
          $0.resolvingSymlinksInPath().path == extracted.resolvingSymlinksInPath().path
        } == true
    }
    var detachError: Error?
    if mounted {
      do {
        _ = try await InstallerCommand.run(
          "/usr/bin/hdiutil", ["detach", extracted.path], cancellable: false)
      } catch { detachError = error }
    }
    try preparation.get()
    if let detachError { throw detachError }
  }

  /// bsdtar unpacks gzip, bzip2 and xz itself; members with absolute paths or `..` refuse.
  static func extractTar(at archive: URL, to directory: URL) async throws {
    let listing = try await InstallerCommand.run("/usr/bin/tar", ["-tf", archive.path])
    guard !listing.isEmpty,
      listing.split(separator: "\n").allSatisfy({
        !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..")
      })
    else { throw AppDownloadError.invalidDownload }
    _ = try await InstallerCommand.run("/usr/bin/tar", ["-xf", archive.path, "-C", directory.path])
  }

  /// The destination, not the staged candidate, decides whether the backup is discarded.
  static func verifyInstalled(
    at url: URL, original: BundleIdentity, expectedVersion: Version, requiresTeam: Bool,
    launchProbe: ((URL) throws -> Void)?
  ) throws {
    _ = try original.verifyReplacement(at: url, requiresTeam: requiresTeam)
    let comparison = BundleCollector.collectBundle(at: url)?.version.comparisonForUpdate(
      to: expectedVersion)
    guard comparison == .samePrecedence || comparison == .newer else {
      throw ReplacementError.verificationFailed(
        "The installed version is not \(expectedVersion.versionNumber ?? expectedVersion.buildNumber ?? "the expected one")."
      )
    }
    try launchProbe?(url)
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

  static func validate(
    candidate: URL, replacing app: App.Bundle, expectedVersion: Version, requiresTeam: Bool = true
  ) throws {
    guard let installed = BundleCollector.collectBundle(at: candidate),
      installed.bundleIdentifier == app.bundleIdentifier
    else { throw AppDownloadError.identityMismatch }
    guard app.version.comparisonForUpdate(to: installed.version) == .older,
      installed.version.comparisonForUpdate(to: expectedVersion) == .samePrecedence
        || installed.version.comparisonForUpdate(to: expectedVersion) == .newer
    else { throw AppDownloadError.versionMismatch }

    try validateCompatibility(of: candidate)

    // Ad-hoc fixtures have no Team ID or stable designated requirement to check.
    if !requiresTeam {
      guard
        (try? BundleIdentity.read(at: app.fileURL, validate: false)
          .verifyReplacement(at: candidate, requiresTeam: false)) != nil
      else { throw AppDownloadError.identityMismatch }
      return
    }

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
