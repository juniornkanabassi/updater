import Foundation

/// Vendor feeds outside the catalogue. Catalogue (Homebrew cask) downloads go through
/// `CatalogueInstall`'s rules instead of a fixed table.
enum AppDownloadSource: Sendable {
  case delta

  #if arch(arm64)
    static let hostArchitecture = NSBundleExecutableArchitectureARM64
    static let hostArchitectureName = "arm64"
  #else
    static let hostArchitecture = NSBundleExecutableArchitectureX86_64
    static let hostArchitectureName = "x86_64"
  #endif

  func release() async throws -> AppDownloadRelease {
    let endpoint = URL(
      string:
        "https://delta.dev/api/releases/stable/latest/asset?asset=delta&os=macos&arch=\(Self.hostArchitectureName == "arm64" ? "aarch64" : "x86_64")"
    )!
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
  /// For a download with no published checksum: the vendor's domain family. Every redirect
  /// and the final URL must stay inside it.
  var allowedDomain: String? = nil

  init(version: Version, url: URL, sha256: String?, appPath: String, allowedDomain: String? = nil) {
    self.version = version
    self.url = url
    self.sha256 = sha256
    self.appPath = appPath
    self.allowedDomain = allowedDomain
  }

  init(data: Data, source: AppDownloadSource) throws {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw AppDownloadError.invalidMetadata
    }
    // The vendor supplies an expiring HTTPS asset URL. The app's Apple signing requirement is
    // verified against the installed copy before any replacement.
    sha256 = nil
    appPath = "Delta.app"
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
