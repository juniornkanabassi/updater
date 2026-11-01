import Foundation

/// Known standalone app distributions. Install scripts, packages and companion services
/// are deliberately not interpreted as replaceable application bundles.
enum AppDownloadSource: Sendable {
  case homebrew(String)
  case delta

  private static let casks = [
    "com.docker.docker": "docker-desktop",
    "com.tdesktop.Telegram": "telegram-desktop",
    "dev.zed.Zed": "zed",
    "com.google.Chrome": "google-chrome",
    "com.usebruno.app": "bruno",
    "com.1password.1password": "1password",
  ]

  static func homebrewSource(for bundle: App.Bundle, token: String?) -> AppDownloadSource? {
    // Discord's native updater owns a separate host-version database and cached
    // bundles. Replacing only /Applications can make it restore an older host.
    // The Homebrew checker opens unsupported standalone apps in their own updater.
    guard let token, casks[bundle.bundleIdentifier] == token,
      FileManager.default.isWritableFile(atPath: bundle.fileURL.deletingLastPathComponent().path)
    else { return nil }
    return .homebrew(token)
  }

  #if arch(arm64)
    static let hostArchitecture = NSBundleExecutableArchitectureARM64
    static let hostArchitectureName = "arm64"
  #else
    static let hostArchitecture = NSBundleExecutableArchitectureX86_64
    static let hostArchitectureName = "x86_64"
  #endif

  func release() async throws -> AppDownloadRelease {
    let endpoint: URL
    switch self {
    case .homebrew(let token):
      endpoint = URL(string: "https://formulae.brew.sh/api/cask/\(token).json")!
    case .delta:
      endpoint = URL(
        string:
          "https://delta.dev/api/releases/stable/latest/asset?asset=delta&os=macos&arch=\(Self.hostArchitectureName == "arm64" ? "aarch64" : "x86_64")"
      )!
    }
    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
    request.timeoutInterval = 30
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse, response.statusCode == 200,
      response.url?.scheme == "https", data.count <= 2 * 1_024 * 1_024
    else { throw AppDownloadError.invalidMetadata }
    return try AppDownloadRelease(data: data, source: self)
  }
}

struct AppDownloadRelease: Sendable {
  let version: Version
  let url: URL
  let sha256: String?
  let appPath: String

  init(data: Data, source: AppDownloadSource, platform: String = Self.platform) throws {
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AppDownloadError.invalidMetadata
    }
    switch source {
    case .homebrew:
      if let variation = (object["variations"] as? [String: [String: Any]])?[platform] {
        object.merge(variation) { _, new in new }
      }
      guard let hash = object["sha256"] as? String,
        hash == "no_check"
          || hash.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil,
        let artifacts = object["artifacts"] as? [[String: Any]],
        !artifacts.contains(where: { $0["pkg"] != nil || $0["installer"] != nil })
      else { throw AppDownloadError.invalidMetadata }
      let paths = artifacts.compactMap { ($0["app"] as? [Any])?.first as? String }
      guard paths.count == 1, let path = paths.first, Self.isSafeAppPath(path)
      else { throw AppDownloadError.invalidMetadata }
      sha256 = hash == "no_check" ? nil : hash.lowercased()
      appPath = path
    case .delta:
      // The vendor supplies an expiring HTTPS asset URL. The app's Apple signing
      // requirement is verified against the installed copy before any replacement.
      sha256 = nil
      appPath = "Delta.app"
    }
    guard let rawVersion = object["version"] as? String,
      let address = object["url"] as? String, let url = URL(string: address),
      url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      ["dmg", "zip"].contains(url.pathExtension.lowercased())
    else { throw AppDownloadError.invalidMetadata }
    version = VersionParser.parse(combinedVersionNumber: rawVersion)
    guard !version.isEmpty else { throw AppDownloadError.invalidMetadata }
    self.url = url
  }

  static var platform: String {
    let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    let name = major >= 27 ? "golden_gate" : "tahoe"
    #if arch(arm64)
      return "arm64_" + name
    #else
      return name
    #endif
  }

  private static func isSafeAppPath(_ path: String) -> Bool {
    !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
      && path.hasSuffix(".app")
  }
}

enum AppDownloadError: LocalizedError {
  case invalidMetadata, invalidDownload, checksumMismatch, identityMismatch, versionMismatch
  case incompatibleSystem, applicationStillRunning
  case replacementFailed(String)
  case toolFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidMetadata: "The vendor did not provide a supported application download."
    case .invalidDownload: "The application download could not be completed."
    case .checksumMismatch: "The download does not match the published checksum."
    case .identityMismatch:
      "The downloaded app does not match the installed app’s signing identity."
    case .versionMismatch: "The downloaded app is not the expected newer version."
    case .incompatibleSystem: "The downloaded app does not support this Mac or macOS version."
    case .applicationStillRunning: "Quit the app, then try updating again."
    case .replacementFailed(let message): message
    case .toolFailed(let message): "Could not prepare the update: \(message)"
    }
  }
}
