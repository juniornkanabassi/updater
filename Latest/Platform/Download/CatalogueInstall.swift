// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Round 5b: apps the Homebrew catalogue knows but brew did not install. Updater downloads and
/// installs them itself only when every rule below holds; otherwise they keep their own route.
enum CatalogueInstall {
  /// Apps whose own updater keeps state outside the bundle: replacing only the bundle can make
  /// it restore an older host (Discord). Extend only with evidence.
  static let deniedBundleIdentifiers: Set<String> = [
    "com.hnc.Discord", "com.hnc.DiscordPTB", "com.hnc.DiscordCanary",
  ]

  enum Refusal: Error, Equatable, LocalizedError {
    case identity(String), shape(String), scope(String), payload(String), trust(String)

    var errorDescription: String? {
      switch self {
      case .identity(let reason), .shape(let reason), .scope(let reason), .payload(let reason),
        .trust(let reason):
        reason
      }
    }
  }

  // MARK: 1. Identity

  /// The one cask with identifier evidence for this bundle ID. Name-only matches (no
  /// evidence), duplicate identifiers and denied apps are refused.
  static func token(for bundleIdentifier: String, candidates: [String]) throws(Refusal) -> String {
    guard !deniedBundleIdentifiers.contains(bundleIdentifier) else {
      throw .scope("Its own updater keeps state outside the app, so it updates itself.")
    }
    let tokens = Set(candidates)
    guard let token = tokens.first else {
      throw .identity("No catalogue entry names this app's bundle ID.")
    }
    guard tokens.count == 1 else {
      throw .identity("Several catalogue entries name this app's bundle ID.")
    }
    return token
  }

  // MARK: 2. Shape (and the payload's metadata)

  /// Applies Round 2's allow list to a cask's JSON (a fresh per-cask fetch) and returns what to
  /// download. Refuses `latest`, `:no_check`, anything but one app plus zap and a quit of this
  /// bundle, dependencies other than macOS or architecture, and non-HTTPS URLs.
  static func release(
    fromCask data: Data, bundleIdentifier: String, platform: String = AppDownloadRelease.platform
  ) throws(Refusal) -> AppDownloadRelease {
    guard var cask = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      throw .shape("The catalogue entry could not be read.")
    }
    if let variation = (cask["variations"] as? [String: [String: Any]])?[platform] {
      cask.merge(variation) { _, new in new }
    }
    guard let rawVersion = cask["version"] as? String, rawVersion != "latest" else {
      throw .shape("The catalogue does not name a version (version :latest).")
    }
    guard let hash = cask["sha256"] as? String,
      hash.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil
    else { throw .shape("The catalogue has no checksum for the download (sha256 :no_check).") }
    guard let artifacts = cask["artifacts"] as? [[String: Any]],
      let quits = HomebrewAllowList.quits(in: artifacts),
      quits.allSatisfy({ $0 == bundleIdentifier })
    else { throw .shape("The cask does more than install one app.") }
    if let dependencies = cask["depends_on"] as? [String: Any],
      !Set(dependencies.keys).isSubset(of: ["macos", "arch"])
    {
      throw .shape("The cask depends on other software.")
    }
    guard
      let path = artifacts.lazy.compactMap({ ($0["app"] as? [Any])?.first as? String }).first,
      !path.hasPrefix("/"), !path.split(separator: "/").contains(".."), path.hasSuffix(".app")
    else { throw .shape("The cask's app path is not usable.") }
    guard let address = cask["url"] as? String, let url = URL(string: address), url.host != nil,
      url.user == nil, url.password == nil,
      url.scheme == "https" || DownloadUpdateOperation.allowsLoopbackHTTP(url)
    else { throw .shape("The download is not offered over HTTPS.") }
    let version = VersionParser.parse(combinedVersionNumber: rawVersion)
    guard !version.isEmpty else { throw .shape("The catalogue version could not be read.") }
    return AppDownloadRelease(version: version, url: url, sha256: hash.lowercased(), appPath: path)
  }

  // MARK: 5. Scope

  /// Before anything is downloaded: not denied, the folder is writable without admin, and
  /// the folder walk finds this copy and no other.
  static func checkScope(of app: App.Bundle, copies: Set<String>, writable: Bool) throws(Refusal) {
    guard !deniedBundleIdentifiers.contains(app.bundleIdentifier) else {
      throw .scope("Its own updater keeps state outside the app, so it updates itself.")
    }
    guard writable else { throw .scope("Its folder needs an administrator to change.") }
    guard copies == [app.fileURL.standardizedFileURL.path] else {
      throw .scope("Another copy of this app is on this Mac.")
    }
  }

  /// After staging and again after the quit, right before replacement: the same walk, which
  /// excludes exactly this job's own staging folder (by path) and nothing else.
  static func recheck(_ app: App.Bundle, copies: Set<String>, excluding staging: URL)
    throws(Refusal)
  {
    let staged = staging.standardizedFileURL.path + "/"
    let others = copies.filter { !$0.hasPrefix(staged) }
    guard others == [app.fileURL.standardizedFileURL.path] else {
      throw .scope("Another copy of this app appeared, so nothing was replaced.")
    }
  }

  // MARK: 3. Payload

  enum PayloadKind { case zip, tar, diskImage }

  /// The archive format from its first bytes (the URL need not say); only formats macOS's own
  /// tools unpack.
  static func payloadKind(of file: URL) -> PayloadKind? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 512)) ?? Data()
    func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
      head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
    }
    if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }
    if starts([0x1F, 0x8B]) || starts(Array("BZh".utf8))
      || starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) || starts(Array("ustar".utf8), at: 257)
    {
      return .tar
    }
    guard let end = try? handle.seekToEnd(), end >= 512 else { return nil }
    try? handle.seek(toOffset: end - 512)
    return (try? handle.read(upToCount: 4)) == Data("koly".utf8) ? .diskImage : nil
  }

  /// Every outer `.app` in an unpacked payload: wrapper folders are walked, symlinks are not
  /// followed, and a branch stops at its first `.app` (helpers inside it are its own; strict
  /// nested signature validation covers them). Zip resource-fork folders are ignored.
  static func outerApps(in folder: URL) -> [URL] {
    guard
      let walk = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return [] }
    var apps = [URL]()
    while let item = walk.nextObject() as? URL {
      let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
      if item.lastPathComponent == "__MACOSX" || values?.isSymbolicLink == true {
        walk.skipDescendants()
        continue
      }
      if item.pathExtension == "app", values?.isDirectory == true {
        apps.append(item)
        walk.skipDescendants()
      }
    }
    return apps
  }
}

/// The live inputs of the catalogue rules; tests inject every one of them.
struct CatalogueInstallCheck: Sendable {
  var fetchCask: @Sendable (_ token: String) async throws -> Data = { token in
    // A fresh per-cask entry, never the cached catalogue, right before deciding or installing.
    let endpoint = URL(string: "https://formulae.brew.sh/api/cask/\(token).json")!
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.url?.scheme == "https", data.count <= 2 * 1_024 * 1_024
    else { throw AppDownloadError.invalidMetadata }
    return data
  }
  var copies: @Sendable (_ bundleIdentifier: String) throws -> Set<String> = {
    try AppStoreInstallGate.live.walk($0)
  }
  var isWritable: @Sendable (_ folder: URL) -> Bool = {
    FileManager.default.isWritableFile(atPath: $0.path)
  }
  /// Whether brew owns the app; anything but a confirmed `notOwned` refuses (R5B-001).
  var ownership: @Sendable (_ app: URL, _ fresh: Bool) async -> CaskOwnership = {
    await Homebrew.shared.ownership(of: $0, fresh: $1)
  }
  /// Gatekeeper's verdict on the staged candidate (notarised, or otherwise accepted).
  var assess: @Sendable (_ app: URL) async throws -> Void = { app in
    _ = try await InstallerCommand.run(
      "/usr/sbin/spctl", ["--assess", "--type", "execute", app.path], timeout: .seconds(60))
  }
  static let live = CatalogueInstallCheck()

  /// Whether a checked app qualifies right now (identity, scope, fresh shape); nil keeps its
  /// current route. Only apps the catalogue says are behind are asked, so no extra fetches.
  func plan(
    for bundle: App.Bundle, candidateTokens: [String], matchedToken: String,
    catalogueVersion: Version
  ) async -> (token: String, release: AppDownloadRelease)? {
    guard bundle.version.comparisonForUpdate(to: catalogueVersion) == .older,
      await ownership(bundle.fileURL, false) == .notOwned,
      let token = try? CatalogueInstall.token(
        for: bundle.bundleIdentifier, candidates: candidateTokens),
      // The version shown came from name matching; a different cask would install something
      // else than what the row says.
      token == matchedToken,
      let copies = try? copies(bundle.bundleIdentifier),
      (try? CatalogueInstall.checkScope(
        of: bundle, copies: copies,
        writable: isWritable(bundle.fileURL.deletingLastPathComponent()))) != nil,
      let data = try? await fetchCask(token),
      let release = try? CatalogueInstall.release(
        fromCask: data, bundleIdentifier: bundle.bundleIdentifier),
      bundle.version.comparisonForUpdate(to: release.version) == .older
    else { return nil }
    return (token, release)
  }
}

/// What a catalogue job knows from the check that offered it.
struct CatalogueJob: Sendable {
  let token: String
  /// The catalogue version the row showed; the fresh entry and the payload must reach it.
  let minimumVersion: Version
  var check = CatalogueInstallCheck.live
}
