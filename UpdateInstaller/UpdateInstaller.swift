// Copyright © 2026 Max Langer and ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import Security
import Synchronization

/// Installs an App Store package without shell interpolation. The client is
/// authenticated by the listener; PackageKit validates the signed package.
final class UpdateInstaller: NSObject, UpdateInstallerProtocol {
  private static let installations = Mutex(0)

  func checkAvailability(reply: @escaping (Data?, Bool, Error?) -> Void) {
    do {
      var code: SecCode?
      var staticCode: SecStaticCode?
      guard geteuid() == 0,
        FileManager.default.isExecutableFile(atPath: "/usr/sbin/installer"),
        SecCodeCopySelf([], &code) == errSecSuccess, let code,
        SecCodeCheckValidity(code, [], nil) == errSecSuccess,
        SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode
      else { throw failure("The update helper cannot run the system installer.") }
      // Use the running code identity, not the file now at its path: an app
      // replacement can leave the previous daemon alive.
      reply(
        try UpdateInstallerIdentity.signature(of: staticCode),
        Self.installations.withLock { $0 > 0 }, nil)
    } catch { reply(nil, Self.installations.withLock { $0 > 0 }, error) }
  }

  func performInstallation(
    ofPackage source: FileHandle, appURL: URL, receiptData: Data,
    reply: @escaping (URL?, Error?) -> Void
  ) {
    Self.installations.withLock { $0 += 1 }
    defer { Self.installations.withLock { $0 -= 1 } }
    defer { try? source.close() }
    do {
      guard appURL.isFileURL, !receiptData.isEmpty,
        let expectedIdentifier = Bundle(url: appURL)?.bundleIdentifier
      else {
        throw failure("The App Store package, installed app, or receipt is unavailable.")
      }
      let volume =
        try appURL.resourceValues(forKeys: [.volumeURLKey]).volume ?? URL(fileURLWithPath: "/")
      // installer runs outside the user's temporary-file context. Stage its
      // input in the daemon's private directory and keep it until installation ends.
      let fileManager = FileManager.default
      let staging = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("LatestUpdateInstaller-" + UUID().uuidString)
      try fileManager.createDirectory(
        at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      defer { try? fileManager.removeItem(at: staging) }
      let package = staging.appendingPathComponent("update.pkg")
      guard
        fileManager.createFile(
          atPath: package.path, contents: nil, attributes: [.posixPermissions: 0o600])
      else { throw failure("The installer could not create its package file.") }
      do {
        let output = try FileHandle(forWritingTo: package)
        defer { try? output.close() }
        guard
          fcopyfile(
            source.fileDescriptor, output.fileDescriptor, nil, copyfile_flags_t(COPYFILE_DATA))
            == 0
        else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      }
      let output = try performCommand(
        "/usr/sbin/installer",
        arguments: ["-dumplog", "-pkg", package.path, "-target", volume.path])
      let expression = try NSRegularExpression(
        pattern: "PackageKit: Registered bundle (\\S+) for uid 0")
      let range = NSRange(output.startIndex..<output.endIndex, in: output)
      let registeredURLs = expression.matches(in: output, range: range).compactMap {
        match -> URL? in
        guard let range = Range(match.range(at: 1), in: output),
          let candidate = URL(string: String(output[range])), candidate.isFileURL,
          Bundle(url: candidate)?.bundleIdentifier == expectedIdentifier
        else { return nil }
        return candidate
      }
      guard let installedURL = registeredURLs.min(by: { $0.path.count < $1.path.count }) else {
        throw failure("The installer did not register the expected app: \(expectedIdentifier).")
      }
      // Derive the receipt path from the actual installed bundle. Never use a
      // caller-provided receipt path as an arbitrary privileged write target.
      let destination = installedURL.appendingPathComponent("Contents/_MASReceipt/receipt")
      try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
      try receiptData.write(to: destination, options: .atomic)
      try fileManager.setAttributes(
        [
          .ownerAccountID: 0, .groupOwnerAccountID: 0,
          .posixPermissions: 0o644,
        ], ofItemAtPath: destination.path)
      reply(installedURL, nil)
    } catch { reply(nil, error) }
  }

  private func performCommand(_ executable: String, arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    // Drain while the process runs; waiting first can deadlock on a full pipe.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else { throw failure(output) }
    return output
  }

  private func failure(_ message: String) -> NSError {
    NSError(
      domain: "LatestInstallerErrorDomain", code: 1,
      userInfo: [NSLocalizedDescriptionKey: message])
  }
}
