import Foundation
import Synchronization

/// Some vendors update their payload without updating the outer bundle's plist.
/// Read their installed metadata without executing an application's code during a scan.
enum InstalledAppVersion {
  static func resolve(
    for bundle: App.Bundle,
    applicationSupport: URL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support", isDirectory: true)
  ) -> App.Bundle {
    let payload: (String, URL)?
    switch bundle.bundleIdentifier {
    case "md.obsidian":
      payload = obsidianPayload(for: bundle, applicationSupport: applicationSupport)
    case "com.zed-industries.delta":
      let executable = bundle.fileURL.appendingPathComponent("Contents/MacOS/delta-app")
      payload = deltaVersion(at: executable).map { ($0, executable) }
    default:
      return bundle
    }
    guard let (number, url) = payload, number != bundle.version.versionNumber else { return bundle }
    let date =
      (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
      .contentModificationDate ?? bundle.modificationDate
    return App.Bundle(
      version: Version(versionNumber: number, buildNumber: nil), name: bundle.name,
      bundleIdentifier: bundle.bundleIdentifier, fileURL: bundle.fileURL, source: bundle.source,
      modificationDate: max(bundle.modificationDate, date))
  }

  private static func obsidianPayload(for bundle: App.Bundle, applicationSupport: URL)
    -> (String, URL)?
  {
    let directory = applicationSupport.appendingPathComponent("obsidian", isDirectory: true)
    let updates =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
    var selected: (String, URL)?
    var version = bundle.version
    for url in updates
    where url.lastPathComponent.hasPrefix("obsidian-")
      && url.pathExtension == "asar"
    {
      let number = String(url.deletingPathExtension().lastPathComponent.dropFirst(9))
      guard isVersion(number),
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
        version.comparisonForUpdate(to: Version(versionNumber: number, buildNumber: nil)) == .older,
        asarVersion(at: url) == number
      else { continue }
      selected = (number, url)
      version = Version(versionNumber: number, buildNumber: nil)
    }
    return selected
  }

  /// ASAR starts with two Chromium Pickle headers, followed by a JSON file index.
  /// Bound both reads; a malformed archive must fall back to the bundle version.
  static func asarVersion(at url: URL) -> String? {
    guard let file = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? file.close() }
    guard let prefix = try? file.read(upToCount: 16), prefix.count == 16 else { return nil }
    func uint32(_ offset: Int) -> UInt64 {
      (0..<4).reduce(0) { $0 | UInt64(prefix[offset + $1]) << ($1 * 8) }
    }
    let headerSize = uint32(4)
    let jsonSize = uint32(12)
    guard uint32(0) == 4, headerSize >= 8, headerSize <= 4 * 1_024 * 1_024,
      jsonSize <= headerSize - 8,
      let header = try? file.read(upToCount: Int(jsonSize)), header.count == Int(jsonSize),
      let index = try? JSONSerialization.jsonObject(with: header) as? [String: Any],
      let files = index["files"] as? [String: Any], files["main.js"] != nil,
      let entry = files["package.json"] as? [String: Any],
      let offsetString = entry["offset"] as? String, let offset = UInt64(offsetString),
      let size = entry["size"] as? Int, (1...65_536).contains(size),
      offset <= UInt64.max - headerSize - 8
    else { return nil }
    do {
      try file.seek(toOffset: 8 + headerSize + offset)
      guard let data = try file.read(upToCount: size), data.count == size,
        let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        package["name"] as? String == "obsidian-dev",
        let version = package["version"] as? String, isVersion(version)
      else { return nil }
      return version
    } catch { return nil }
  }

  private struct DeltaVersionCache: Sendable {
    let size: Int
    let date: Date?
    let version: String?
  }
  private static let deltaVersions = Mutex([URL: DeltaVersionCache]())

  static func deltaVersion(at url: URL) -> String? {
    guard
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
      let size = values.fileSize, size <= 512 * 1_024 * 1_024
    else { return nil }
    if let cached = deltaVersions.withLock({ $0[url] }),
      cached.size == size, cached.date == values.contentModificationDate
    {
      return cached.version
    }
    // Map and scan outside the cache lock so unrelated discovery is never blocked by I/O.
    let version = readDeltaVersion(at: url)
    deltaVersions.withLock { cache in
      if cache.count >= 64 { cache.removeAll(keepingCapacity: true) }
      cache[url] = DeltaVersionCache(
        size: size, date: values.contentModificationDate, version: version)
    }
    return version
  }

  private static func readDeltaVersion(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
    let marker = Data("delta_version".utf8)
    let suffix = Data("zed_username".utf8)
    var position = data.startIndex
    while position < data.endIndex,
      let range = data.range(of: marker, in: position..<data.endIndex)
    {
      position = range.upperBound
      let bytes = data[position...].prefix(32).prefix { (48...57).contains($0) || $0 == 46 }
      if let number = String(bytes: bytes, encoding: .utf8), isVersion(number),
        data.dropFirst(position + bytes.count).starts(with: suffix)
      {
        return number
      }
    }
    // Current builds store version + 40-byte source commit before this startup
    // diagnostic, rather than beside the telemetry key. Validate both fields;
    // arbitrary dependency versions elsewhere in the executable are not evidence.
    let diagnostic = Data("could not build HTTP client".utf8)
    position = data.startIndex
    var version: String?
    while position < data.endIndex,
      let range = data.range(of: diagnostic, in: position..<data.endIndex)
    {
      position = range.upperBound
      let metadata = data[..<range.lowerBound].suffix(72)
      let commit = metadata.suffix(40)
      guard commit.count == 40,
        commit.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
      else { continue }
      let bytes = metadata.dropLast(40).reversed().prefix {
        (48...57).contains($0) || $0 == 46
      }.reversed()
      guard let number = String(bytes: bytes, encoding: .utf8), isVersion(number) else { continue }
      if let version, version != number { return nil }
      version = number
    }
    return version
  }

  private static func isVersion(_ string: String) -> Bool {
    string.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil
  }
}
