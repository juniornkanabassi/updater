// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import XCTest

#if LATEST_HOSTED_TESTS
  @testable import Latest
#endif

// Foundation leaves an empty plist behind even after removing a persistent domain.
extension UserDefaults {
  func removeTestPersistentDomain(
    forName name: String, file: StaticString = #filePath, line: UInt = #line
  ) {
    precondition(UUID(uuidString: String(name.split(separator: ".").last ?? "")) != nil)
    if let path = ProcessInfo.processInfo.environment["UPDATER_TEST_DEFAULTS_MANIFEST"] {
      do {
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(name)\n".utf8))
      } catch {
        XCTFail("Could not record test preferences: \(error)", file: file, line: line)
      }
    }
    removePersistentDomain(forName: name)
    synchronize()
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/\(name).plist")
    do {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {
      XCTFail("Could not remove test preferences: \(error)", file: file, line: line)
    }
  }
}

@MainActor
func isolatedAppListSettings(for testCase: XCTestCase) throws -> AppListSettings {
  let suiteName = "LatestTests.AppListSettings.\(UUID().uuidString)"
  let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  testCase.addTeardownBlock {
    defaults.removeTestPersistentDomain(forName: suiteName)
  }

  let settings = AppListSettings(userDefaults: defaults)
  settings.sortOrder = .name
  settings.showInstalledUpdates = true
  settings.showIgnoredUpdates = true
  settings.includeUnsupportedApps = true
  settings.includeAppsWithLimitedSupport = true
  return settings
}

@MainActor
func makeTestApp(
  name: String,
  version: String,
  remoteVersion: String? = nil,
  date: Date? = Date(timeIntervalSince1970: 1_750_000_000),
  updateAction: App.Update.Action = .builtIn { _ in }
) -> App {
  let bundle = App.Bundle(
    version: Version(versionNumber: version, buildNumber: nil),
    name: name,
    bundleIdentifier: "com.example.\(name.replacingOccurrences(of: " ", with: "-"))",
    fileURL: URL(fileURLWithPath: "/Applications/\(name).app"),
    source: .appStore,
    modificationDate: .distantPast
  )
  let update = App.Update(
    app: bundle,
    remoteVersion: Version(versionNumber: remoteVersion ?? version, buildNumber: nil),
    minimumOSVersion: nil,
    source: .appStore,
    date: date,
    releaseNotes: .html(string: "<p>Release notes</p>"),
    updateAction: updateAction
  )
  return App(bundle: bundle, update: .success(update), isIgnored: false)
}
