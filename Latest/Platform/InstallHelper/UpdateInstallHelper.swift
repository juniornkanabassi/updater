//
//  UpdateInstallHelper.swift
//  Latest
//
//  Created by Max Langer on 11.01.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//

import Foundation
import Security
import ServiceManagement
import Synchronization

/// Manages the privileged helper daemon used to install App Store updates via XPC.
enum InstallHelper {

  // MARK: - Helper Registration

  /// Verifies that the install helper is registered and approved.
  static func verifyAvailability() throws(InstallHelperError) {
    try verifyAvailability(of: registration.service)
  }

  private static func verifyAvailability(of service: SMAppService) throws(InstallHelperError) {
    switch service.status {
    case .notFound, .notRegistered:
      throw InstallHelperError.installHelperNotRegistered
    case .requiresApproval:
      throw InstallHelperError.installHelperRequiresApproval
    case .enabled:
      return
    @unknown default:
      throw InstallHelperError.installHelperNotRegistered
    }
  }

  static func prepareForUpdates() async throws {
    try await readiness.prepare()
  }

  private static let readiness = InstallHelperReadiness(backend: LiveInstallHelperBackend())

  /// Registers the helper or opens System Settings if approval is required.
  static func installHelper() throws {
    _ = try verifySigning()
    let service = registration.service
    switch service.status {
    case .notFound, .notRegistered:
      try service.register()
      if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    case .requiresApproval:
      SMAppService.openSystemSettingsLoginItems()
    case .enabled:
      break
    @unknown default:
      break
    }
  }

  private static var currentService: SMAppService {
    SMAppService.daemon(plistName: UpdateInstallerIdentity.daemon + ".plist")
  }

  private static var legacyService: SMAppService {
    SMAppService.daemon(plistName: UpdateInstallerIdentity.service + ".plist")
  }

  private static var registration: (service: SMAppService, needsMigration: Bool) {
    let current = currentService
    let legacy = legacyService
    let needsMigration = legacy.status == .enabled || legacy.status == .requiresApproval
    if needsMigration && (current.status == .notRegistered || current.status == .notFound) {
      return (legacy, true)
    }
    return (current, needsMigration)
  }

  /// A root daemon must have a stable Apple-issued signing identity. Do not
  /// weaken its launch or peer requirements for unsigned development builds.
  private static func verifySigning() throws -> Data {
    func verifiedCode(at url: URL, requirement: String) throws -> SecStaticCode {
      var code: SecStaticCode?
      var policy: SecRequirement?
      guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
        SecRequirementCreateWithString(requirement as CFString, [], &policy) == errSecSuccess,
        let code, let policy,
        SecStaticCodeCheckValidity(code, [], policy) == errSecSuccess
      else {
        throw LatestError.custom(
          title: "Update Helper Requires a Signed Build",
          description:
            "This copy of Latest or its helper does not have the required code signature. Use a signed build of Latest, then enable the helper again."
        )
      }
      return code
    }
    _ = try verifiedCode(
      at: Bundle.main.bundleURL, requirement: UpdateInstallerIdentity.appRequirement)
    let helper = try verifiedCode(
      at: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/LatestUpdateInstaller"),
      requirement: UpdateInstallerIdentity.helperRequirement)
    return try UpdateInstallerIdentity.signature(of: helper)
  }

  // MARK: - Package Installation

  /// Installs an App Store update package at the given target URL via the privileged helper.
  static func installPackage(at url: URL, appURL: URL, receiptData: Data)
    async throws -> URL
  {
    return try await readiness.install {
      try await performInstallation(at: url, appURL: appURL, receiptData: receiptData)
    }
  }

  private static func performInstallation(at url: URL, appURL: URL, receiptData: Data)
    async throws -> URL
  {
    // Transfer an open descriptor: the root daemon cannot reopen files in the
    // user's protected temporary directory on current macOS releases.
    let package = try FileHandle(forReadingFrom: url)
    defer { try? package.close() }

    let connection = NSXPCConnection(
      machServiceName: UpdateInstallerIdentity.service, options: .privileged)
    connection.setCodeSigningRequirement(UpdateInstallerIdentity.helperRequirement)
    connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)

    defer { connection.invalidate() }

    return try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<URL, Error>) in
      let replyGate = HelperReplyGate(continuation: continuation)
      // A deadline here would release the queue while /usr/sbin/installer is
      // still replacing the app. Wait for its result or an XPC connection error.
      connection.interruptionHandler = {
        replyGate.resume(with: .failure(LatestError.installHelperCommunicationFailed))
      }
      connection.invalidationHandler = {
        replyGate.resume(with: .failure(LatestError.installHelperCommunicationFailed))
      }
      connection.activate()

      guard
        let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
          replyGate.resume(with: .failure(error))
        }) as? UpdateInstallerProtocol
      else {
        replyGate.resume(with: .failure(LatestError.installHelperCommunicationFailed))
        return
      }

      proxy.performInstallation(
        ofPackage: package, appURL: appURL, receiptData: receiptData
      ) { installedURL, error in
        if let error {
          replyGate.resume(with: .failure(error))
        } else if let installedURL {
          replyGate.resume(with: .success(installedURL))
        } else {
          replyGate.resume(with: .failure(LatestError.installHelperCommunicationFailed))
        }
      }
    }
  }

  struct LiveInstallHelperBackend: InstallHelperReadinessBackend {
    func verify() throws -> (signature: Data, needsMigration: Bool) {
      let signature = try InstallHelper.verifySigning()
      let registration = InstallHelper.registration
      try InstallHelper.verifyAvailability(of: registration.service)
      return (signature, registration.needsMigration)
    }

    func refresh() async throws {
      try InstallHelper.verifyAvailability()
      // An older app copy can re-register the legacy job after migration.
      // Retire both registrations so only one job owns the shared XPC endpoint.
      for service in [InstallHelper.legacyService, InstallHelper.currentService] {
        if service.status == .enabled || service.status == .requiresApproval {
          try await service.unregister()
        }
      }
      // Background Task Management settles separately from process exit.
      try await Task.sleep(for: .milliseconds(500))
      // A new stable registration also rebuilds the missing BTM parent link
      // left by some legacy records. Never rotate identities on every retry.
      try InstallHelper.currentService.register()
      try InstallHelper.verifyAvailability()
    }

    func probe() async throws -> InstallHelperHealth {
      let connection = NSXPCConnection(
        machServiceName: UpdateInstallerIdentity.service, options: .privileged)
      connection.setCodeSigningRequirement(UpdateInstallerIdentity.helperRequirement)
      connection.remoteObjectInterface = NSXPCInterface(with: UpdateInstallerProtocol.self)
      defer { connection.invalidate() }
      return try await withCheckedThrowingContinuation { continuation in
        let gate = HelperReplyGate<InstallHelperHealth>(continuation: continuation)
        // Only the harmless readiness RPC has a deadline. Installation never does.
        let timeout = Task {
          do { try await Task.sleep(for: .seconds(3)) } catch { return }
          gate.resume(
            with: .failure(InstallHelperError.unavailable("The update helper did not respond.")))
        }
        let fail: @Sendable (Error) -> Void = { error in
          timeout.cancel()
          gate.resume(with: .failure(error))
        }
        connection.interruptionHandler = { fail(LatestError.installHelperCommunicationFailed) }
        connection.invalidationHandler = { fail(LatestError.installHelperCommunicationFailed) }
        connection.activate()
        guard
          let proxy = connection.remoteObjectProxyWithErrorHandler(fail) as? UpdateInstallerProtocol
        else {
          fail(LatestError.installHelperCommunicationFailed)
          return
        }
        proxy.checkAvailability { signature, isInstalling, error in
          timeout.cancel()
          gate.resume(
            with: Result {
              try InstallHelperHealth(
                signature: signature, isInstalling: isInstalling, error: error)
            })
        }
      }
    }
  }

}

final class HelperReplyGate<Value: Sendable>: Sendable {
  private let state: Mutex<CheckedContinuation<Value, Error>?>

  init(continuation: CheckedContinuation<Value, Error>) {
    state = Mutex(continuation)
  }

  func resume(with result: Result<Value, Error>) {
    let continuation = state.withLock { state in
      defer { state = nil }
      return state
    }
    continuation?.resume(with: result)
  }
}

// MARK: - InstallHelperError

/// Errors related to install helper availability.
enum InstallHelperError: LocalizedError, Equatable {
  case installHelperNotRegistered
  case installHelperRequiresApproval
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .unavailable(let detail):
      return detail
    case .installHelperNotRegistered:
      return NSLocalizedString(
        "InstallHelperNotFoundErrorDescription",
        comment: "Shown when the update helper is not installed.")
    case .installHelperRequiresApproval:
      return NSLocalizedString(
        "InstallHelperRequiresApprovalErrorDescription",
        comment: "Shown when the update helper is installed but disabled, requiring approval.")
    }
  }
}
