// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// A display-only "macOS update available" row from `softwareupdate -l` (read-only, bounded).
/// Its action opens Software Update; it is a hand-off, so Update All never includes it.
enum SystemUpdate {
  static let bundle = App.Bundle(
    version: Version(
      versionNumber: ProcessInfo.processInfo.operatingSystemVersionString
        .split(separator: " ").dropFirst().first.map(String.init),
      buildNumber: nil),
    name: "macOS", bundleIdentifier: "com.apple.macOS.softwareupdate",
    fileURL: URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"),
    source: .vendor)

  static func check() async -> App.Update? {
    guard
      let output = try? await InstallerCommand.run(
        "/usr/sbin/softwareupdate", ["-l"], timeout: .seconds(120)),
      let version = parseMacOSVersion(output)
    else { return nil }
    return update(version: version)
  }

  static func update(version: String) -> App.Update {
    App.Update(
      app: bundle, remoteVersion: Version(versionNumber: version, buildNumber: nil),
      minimumOSVersion: nil, source: .vendor, date: nil, releaseNotes: nil,
      updateAction: .external(label: "Software Update") { _ in
        Task { @MainActor in
          MacApplicationWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
        }
      })
  }

  /// "Title: macOS Tahoe 27.3, Version: 27.3, ..." under a "* Label:" line.
  static func parseMacOSVersion(_ output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) where line.contains("Title: macOS") {
      let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      if let version = fields.first(where: { $0.hasPrefix("Version:") }) {
        return version.dropFirst("Version:".count).trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }
}
