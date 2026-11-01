// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import CoreServices
import Foundation
import Synchronization

/// Decides, before any purchase or helper request, whether an App Store install provably
/// writes to the selected URL. PackageKit may relocate the install to any copy that
/// LaunchServices or Spotlight knows about, so every doubt fails closed to a hand-off.
struct AppStoreInstallGate: Sendable {
  /// Paths of every copy found by walking the watched folders directly on disk.
  var walk: @Sendable (_ bundleIdentifier: String) throws -> Set<String>
  var launchServicesURLs: @Sendable (_ bundleIdentifier: String) throws -> [URL]
  var spotlightURLs: @Sendable (_ bundleIdentifier: String) async throws -> [URL]
  var indexingEnabled: @Sendable () async throws -> Bool
  /// Total time allowed for every probe together; past it the app is handed off.
  var deadline: Duration = .seconds(10)

  func allowsInstall(at url: URL, bundleIdentifier: String) async -> Bool {
    let target = url.standardizedFileURL
    // 1. The package's own location on the boot volume, not reached through a link.
    guard target.deletingLastPathComponent().path == "/Applications",
      target.pathExtension == "app", target.resolvingSymlinksInPath().path == target.path,
      !bundleIdentifier.isEmpty,
      bundleIdentifier.allSatisfy({
        $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))
      })
    else { return false }
    // One deadline covers every probe. The answer is taken once: a probe finishing after
    // the deadline cannot turn a hand-off into an install.
    let id = bundleIdentifier
    return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      let answer = ResumeOnce(continuation)
      // The walk and LaunchServices block, so they run on a GCD thread, not the actor pool.
      DispatchQueue.global(qos: .userInitiated).async {
        // 2. A direct walk finds no other copy. 3. LaunchServices agrees.
        let local =
          (try? walk(id)) == [target.path]
          && (try? launchServicesURLs(id)).map { Set($0.map(\.standardizedFileURL.path)) }
            == [target.path]
        guard local else { return answer.resume(false) }
        Task {
          // 3. Spotlight agrees. 4. It is indexing, so an absent result is meaningful.
          let spotlight = (try? await spotlightURLs(id)).map {
            Set($0.map(\.standardizedFileURL.path))
          }
          let indexing = (try? await indexingEnabled()) == true
          answer.resume(spotlight == [target.path] && indexing)
        }
      }
      Task { [deadline] in
        try? await Task.sleep(for: deadline)
        answer.resume(false)
      }
    }
  }

  /// Every `.app` with this bundle ID under the folders, without descending into bundles.
  /// A missing optional folder is skipped. A missing required folder, a folder that exists
  /// but cannot be read, or an app whose Info.plist cannot be read throws, so a copy that
  /// cannot be seen blocks the install.
  static func copies(of bundleIdentifier: String, in folders: [URL], required: Set<String> = [])
    throws -> Set<String>
  {
    var found = Set<String>()
    for folder in folders {
      guard try exists(folder) else {
        if required.contains(folder.path) { throw CocoaError(.fileNoSuchFile) }
        continue
      }
      var failure: Error?
      let enumerator = FileManager.default.enumerator(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]
      ) { _, error in
        failure = error
        return false
      }
      while let item = enumerator?.nextObject() as? URL {
        guard item.pathExtension == "app" else { continue }
        let data = try Data(contentsOf: item.appendingPathComponent("Contents/Info.plist"))
        guard
          let info = try PropertyListSerialization.propertyList(from: data, format: nil)
            as? [String: Any]
        else { throw CocoaError(.propertyListReadCorrupt) }
        if info["CFBundleIdentifier"] as? String == bundleIdentifier {
          found.insert(item.standardizedFileURL.path)
        }
      }
      if let failure { throw failure }
    }
    return found
  }

  /// Absent (ENOENT) is false; any other failure, such as no permission, throws.
  private static func exists(_ url: URL) throws -> Bool {
    var info = stat()
    if stat(url.path, &info) == 0 { return true }
    if errno == ENOENT { return false }
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }

  static let live = AppStoreInstallGate(
    walk: { identifier in
      let users = try FileManager.default.contentsOfDirectory(atPath: "/Users")
        .filter { !$0.hasPrefix(".") }
      let folders =
        [URL(fileURLWithPath: "/Applications")]
        + users.map { URL(fileURLWithPath: "/Users/\($0)/Applications") }
        + AppDirectoryStore(updateHandler: {}).URLs
      return try copies(of: identifier, in: folders, required: ["/Applications"])
    },
    launchServicesURLs: { identifier in
      (LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?
        .takeRetainedValue() as? [URL]) ?? []
    },
    spotlightURLs: { identifier in
      try await InstallerCommand.run(
        "/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == \"\(identifier)\""],
        timeout: .seconds(10)
      )
      .split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    },
    indexingEnabled: {
      // /Applications lives on the Data volume; `mdutil -s /` reports the sealed
      // system volume, which is never indexed on macOS 26.
      let data = "/System/Volumes/Data"
      let volume = FileManager.default.fileExists(atPath: data) ? data : "/"
      return try await InstallerCommand.run(
        "/usr/bin/mdutil", ["-s", volume], timeout: .seconds(10)
      )
      .contains("Indexing enabled.")
    })
}

/// Resumes a continuation once; later calls are ignored.
private final class ResumeOnce: Sendable {
  private let continuation: Mutex<CheckedContinuation<Bool, Never>?>
  init(_ continuation: CheckedContinuation<Bool, Never>) {
    self.continuation = Mutex(continuation)
  }
  func resume(_ value: Bool) {
    continuation.withLock { pending in
      defer { pending = nil }
      return pending
    }?.resume(returning: value)
  }
}
