//
//  InstallerProtocol.swift
//  Installer
//
//  Created by Max Langer on 06.01.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//

import Foundation
import Security

/// Shared by the app and its authenticated installer daemon.
@objc protocol UpdateInstallerProtocol {
  /// A harmless round trip proves that the running, authenticated daemon is
  /// the binary bundled with this app and supports the current protocol.
  func checkAvailability(reply: @escaping (Data?, Bool, Error?) -> Void)

  // Invoked through the XPC proxy across the app/helper module boundary.
  // swiftlint:disable:next unused_declaration
  func performInstallation(
    ofPackage package: FileHandle, appURL: URL, receiptData: Data,
    reply: @escaping (URL?, Error?) -> Void)
}

enum UpdateInstallerIdentity {
  // Separate the fork's launchd registration from the legacy shared identity.
  // Keep the authenticated XPC endpoint and signing identity compatible.
  static let daemon = "com.max-langer.Latest.dev.UpdateInstaller"
  static let service = "com.max-langer.latest.UpdateInstaller"
  static let appRequirement = requirement(for: "com.max-langer.Latest.dev")
  // Used by app-side XPC/signature validation; this file also builds in the helper.
  // swiftlint:disable:next unused_declaration
  static let helperRequirement = requirement(for: service)

  static func signature(of code: SecStaticCode) throws -> Data {
    var information: CFDictionary?
    guard SecCodeCopySigningInformation(code, [], &information) == errSecSuccess,
      let hash = (information as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    else { throw CocoaError(.executableNotLoadable) }
    return hash
  }

  private static func requirement(for identifier: String) -> String {
    "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"D87N659XLV\""
  }
}
