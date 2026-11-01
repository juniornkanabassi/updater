// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import CryptoKit
import Foundation
import XCTest

@testable import Latest

/// Disposable, ad-hoc signed app bundles in temporary folders. Their executable is a copy
/// of /usr/bin/true (or false for "won't launch"), so probing them never opens a window.
enum FixtureApp {
  static let identifier = "com.juniornkanabassi.updater-fixture"

  @discardableResult
  static func make(
    in directory: URL, name: String = "Fixture", identifier: String = identifier,
    version: String, launches: Bool = true, signed: Bool = true
  ) throws -> URL {
    let app = directory.appendingPathComponent(name + ".app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleExecutable": name,
      "CFBundleShortVersionString": version, "CFBundleVersion": version,
      "CFBundlePackageType": "APPL", "LSBackgroundOnly": true, "LSMinimumSystemVersion": "26.0",
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
      .write(to: app.appendingPathComponent("Contents/Info.plist"))
    try FileManager.default.copyItem(
      at: URL(fileURLWithPath: launches ? "/usr/bin/true" : "/usr/bin/false"),
      to: macOS.appendingPathComponent(name))
    if signed { try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path]) }
    return app
  }

  /// Fixture-only launch check: the executable must start and exit cleanly.
  static func launchProbe(_ app: URL) throws {
    let info = try PropertyListSerialization.propertyList(
      from: Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")), format: nil)
    let executable = (info as? [String: Any])?["CFBundleExecutable"] as? String ?? ""
    let process = Process()
    process.executableURL = app.appendingPathComponent("Contents/MacOS/" + executable)
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ReplacementError.verificationFailed("\(app.lastPathComponent) did not launch.")
    }
  }

  /// Relative path → content hash (and symlink target), for byte-for-byte comparisons.
  static func digest(_ url: URL) throws -> [String: String] {
    var result = [String: String]()
    let base = url.resolvingSymlinksInPath().path
    let enumerator = FileManager.default.enumerator(
      at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    while let item = enumerator?.nextObject() as? URL {
      let relative = String(item.resolvingSymlinksInPath().path.dropFirst(base.count))
      let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true {
        result[relative] = try "→" + FileManager.default.destinationOfSymbolicLink(atPath: item.path)
      } else if values.isRegularFile == true {
        result[relative] = SHA256.hash(data: try Data(contentsOf: item))
          .map { String(format: "%02x", $0) }.joined()
      }
    }
    return result
  }

  static func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "FixtureApp", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: "\(executable) \(arguments) failed"])
    }
  }
}

extension XCTestCase {
  func disposableDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("UpdaterTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
}
