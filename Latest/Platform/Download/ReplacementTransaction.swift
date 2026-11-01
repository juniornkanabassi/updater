// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.
// Compiled into the app and the root install helper; Foundation and Security only.

import Foundation
import Security

/// Identity of the bundle currently on disk. Info.plist is read directly because
/// `Bundle(url:)` caches its dictionary and would describe a replaced bundle.
struct BundleIdentity: Equatable, Sendable {
  let bundleIdentifier: String?
  let teamIdentifier: String?
  let shortVersion: String?
  let bundleVersion: String?

  /// `validate` checks the whole signature (strict, nested code); without it only
  /// the signing information is read, which is enough to compare an original.
  static func read(at url: URL, validate: Bool) throws -> BundleIdentity {
    let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
    let info =
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]
    var code: SecStaticCode?
    var signing: CFDictionary?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing)
        == errSecSuccess
    else { throw ReplacementError.verificationFailed("\(url.lastPathComponent) is not signed.") }
    if validate {
      let flags = SecCSFlags(
        rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
      guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
        throw ReplacementError.verificationFailed(
          "The signature of \(url.lastPathComponent) is not valid.")
      }
    }
    return BundleIdentity(
      bundleIdentifier: info["CFBundleIdentifier"] as? String,
      teamIdentifier: (signing as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String,
      shortVersion: info["CFBundleShortVersionString"] as? String,
      bundleVersion: info["CFBundleVersion"] as? String)
  }

  /// The destination keeps the original's bundle ID and Team ID and has a valid signature.
  /// `requiresTeam` is false only for ad-hoc signed test fixtures.
  func verifyReplacement(at url: URL, requiresTeam: Bool = true) throws -> BundleIdentity {
    let installed = try Self.read(at: url, validate: true)
    guard installed.bundleIdentifier == bundleIdentifier, bundleIdentifier != nil else {
      throw ReplacementError.verificationFailed("The installed bundle identifier changed.")
    }
    guard installed.teamIdentifier == teamIdentifier, !requiresTeam || teamIdentifier != nil
    else { throw ReplacementError.verificationFailed("The installed signing team changed.") }
    return installed
  }
}

enum ReplacementError: LocalizedError, Equatable {
  case verificationFailed(String)
  case restoreFailed(String)
  case outcomeUnknown(String)

  var errorDescription: String? {
    switch self {
    case .verificationFailed(let reason): "The update was rolled back. \(reason)"
    case .restoreFailed(let backup):
      "The update failed and the original could not be restored. It was kept at \(backup)."
    case .outcomeUnknown(let backup):
      "Installer connection lost; your original is kept at \(backup)."
    }
  }
}

/// Keeps the original until the installed destination passes `verify`, restoring it otherwise.
enum ReplacementTransaction {
  static let backupName = "original"

  /// `copyingOriginal` clones the original aside for installers that replace it in place
  /// (PackageKit); otherwise it is moved aside and `install` puts the candidate at `target`.
  static func perform(
    at target: URL, backupDirectory: URL, copyingOriginal: Bool = false,
    install: () throws -> Void, verify: (URL) throws -> Void
  ) throws {
    let manager = FileManager.default
    let backup = backupDirectory.appendingPathComponent(backupName)
    let hadOriginal = manager.fileExists(atPath: target.path)
    let originalIdentity = hadOriginal ? try? BundleIdentity.read(at: target, validate: false) : nil
    if hadOriginal {
      if copyingOriginal {
        try manager.copyItem(at: target, to: backup)
      } else {
        try manager.moveItem(at: target, to: backup)
      }
    }
    do {
      try install()
      try verify(target)
    } catch {
      guard hadOriginal else {
        try? manager.removeItem(at: target)
        throw error
      }
      try restore(target, backupDirectory: backupDirectory, originalIdentity: originalIdentity)
      throw error
    }
    if hadOriginal { try? manager.removeItem(at: backup) }
  }

  /// Clones `target` into `backupDirectory` for an installer Updater does not drive itself
  /// (Sparkle). Returns the original's identity for `verifyExternalInstall`.
  static func cloneOriginal(at target: URL, into backupDirectory: URL) throws -> BundleIdentity {
    let identity = try BundleIdentity.read(at: target, validate: false)
    try FileManager.default.copyItem(
      at: target, to: backupDirectory.appendingPathComponent(backupName))
    return identity
  }

  /// After an installer Updater does not drive. The destination's full signature is always
  /// checked (strict, every architecture, nested code), so a damaged bundle never passes
  /// because its metadata looks unchanged. An untouched target then passes; a changed one
  /// must be the same product, newer than before and at least `expected`.
  static func verifyExternalInstall(
    at target: URL, original: BundleIdentity, expected: Version?, requiresTeam: Bool = true
  ) throws {
    if try BundleIdentity.read(at: target, validate: true) == original { return }
    let installed = try original.verifyReplacement(at: target, requiresTeam: requiresTeam)
    try verifyVersion(
      installed: Version(
        versionNumber: installed.shortVersion, buildNumber: installed.bundleVersion),
      previous: Version(versionNumber: original.shortVersion, buildNumber: original.bundleVersion),
      expected: expected)
  }

  /// Moves whatever is at `target` aside and the backup back, then checks the restored
  /// identity. On failure the backup is left in place and its path reported.
  static func restore(_ target: URL, backupDirectory: URL, originalIdentity: BundleIdentity?) throws
  {
    let manager = FileManager.default
    let backup = backupDirectory.appendingPathComponent(backupName)
    do {
      if manager.fileExists(atPath: target.path) || isSymlink(target) {
        try manager.moveItem(
          at: target, to: backupDirectory.appendingPathComponent("failed-" + UUID().uuidString))
      }
      try manager.moveItem(at: backup, to: target)
      if let originalIdentity,
        (try? BundleIdentity.read(at: target, validate: false)) != originalIdentity
      {
        throw ReplacementError.restoreFailed(target.path)
      }
    } catch {
      throw ReplacementError.restoreFailed(
        manager.fileExists(atPath: backup.path) ? backup.path : target.path)
    }
  }

  /// Whether a failed transaction left the original in `backupDirectory` for recovery.
  static func needsRecovery(_ backupDirectory: URL) -> Bool {
    FileManager.default.fileExists(atPath: backupDirectory.appendingPathComponent(backupName).path)
  }

  private static func isSymlink(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
  }
}

extension ReplacementTransaction {
  /// An install counts only if it moved forward from `previous` and reached `expected`.
  static func verifyVersion(installed: Version, previous: Version, expected: Version?) throws {
    guard previous.comparisonForUpdate(to: installed) == .older else {
      throw ReplacementError.verificationFailed(
        "The installed version \(installed.versionNumber ?? "?") is not newer than \(previous.versionNumber ?? "?")."
      )
    }
    if let expected, installed.comparisonForUpdate(to: expected) == .older {
      throw ReplacementError.verificationFailed(
        "The installed version \(installed.versionNumber ?? "?") is older than \(expected.versionNumber ?? "?")."
      )
    }
  }
}

/// The helper's App Store install. PackageKit replaces the bundle in place, so the original
/// is cloned aside and discarded only after the installer, the receipt and the installed
/// identity and version all check out.
enum AppStorePackageInstall {
  static func perform(
    appURL: URL, staging: URL, expectedVersion: String, requiresTeam: Bool = true,
    runInstaller: () throws -> [String], writeReceipt: (URL) throws -> Void
  ) throws {
    let original = try BundleIdentity.read(at: appURL, validate: false)
    let previous = Version(
      versionNumber: original.shortVersion, buildNumber: original.bundleVersion)
    let receipt = appURL.appendingPathComponent("Contents/_MASReceipt/receipt")
    try ReplacementTransaction.perform(
      at: appURL, backupDirectory: staging, copyingOriginal: true,
      install: {
        guard try runInstaller().contains(appURL.standardizedFileURL.path) else {
          throw ReplacementError.verificationFailed(
            "The installer did not write to \(appURL.path).")
        }
        try writeReceipt(receipt)
      },
      verify: { url in
        let installed = try original.verifyReplacement(at: url, requiresTeam: requiresTeam)
        try ReplacementTransaction.verifyVersion(
          installed: Version(
            versionNumber: installed.shortVersion, buildNumber: installed.bundleVersion),
          previous: previous, expected: Version(versionNumber: expectedVersion, buildNumber: nil))
        guard FileManager.default.fileExists(atPath: receipt.path) else {
          throw ReplacementError.verificationFailed("The App Store receipt was not written.")
        }
      })
  }
}
