//
//  AppStoreUpdateOperation.swift
//  Latest
//
//  Created by Max Langer on 01.07.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import AppKit
import CommerceKit
import CoreServices
import StoreFoundation
import os

private let appStoreUpdateLogger = Logger(
  subsystem: "com.juniornkanabassi.Updater", category: "AppStoreUpdates")

/// Public boundary for App Store updates backed by private Apple frameworks.
enum AppStoreUpdater {

  static func verifyAvailability() throws(InstallHelperError) {
    if AppStoreUpdateOperation.requiresManualInstallation { try InstallHelper.verifyAvailability() }
  }

  /// Verifies whether the app can prepare App Store updates.
  static func prepareForUpdates() async throws {
    if AppStoreUpdateOperation.requiresManualInstallation {
      try await InstallHelper.prepareForUpdates()
    }
  }

  /// Enqueues an App Store update operation.
  static func enqueueUpdate(for app: App.Bundle, appStoreIdentifier: UInt64, version: String) {
    let operation = AppStoreUpdateOperation(
      bundleIdentifier: app.bundleIdentifier,
      installURL: app.fileURL,
      appIdentifier: app.identifier,
      appStoreIdentifier: appStoreIdentifier
    )
    operation.expectedVersion = Version(versionNumber: version, buildNumber: nil)
    UpdateQueue.shared.addOperation(operation)
  }

}

/// Owns App Store downloads while Latest displays progress. Apple downloads the
/// purchased update; the signed helper handles PackageKit's entitlement failure.
final class AppStoreUpdateOperation: UpdateOperation, @unchecked Sendable {
  private let itemIdentifier: UInt64
  private let installURL: URL
  @MainActor private var observerIdentifier: String?
  @MainActor private var artifacts = AppStoreDownloadArtifacts()
  @MainActor private var isInstalling = false

  /// Seams for tests: the gate runs before `prepare` (the helper) and any purchase.
  var installGate: @Sendable (URL, String) async -> Bool = {
    await AppStoreInstallGate.live.allowsInstall(at: $0, bundleIdentifier: $1)
  }
  var prepare: @Sendable () async throws -> Void = { try await AppStoreUpdater.prepareForUpdates() }
  var openURL: @MainActor @Sendable (URL) -> Void = { NSWorkspace.shared.open($0) }
  var lifecycle = AppLifecycle.live
  /// The helper route (macOS 26.1+) is the only one with quit, backup and verification.
  var usesVerifiedHelperInstall = AppStoreUpdateOperation.requiresManualInstallation
  var installPackage: @Sendable (URL, URL, Data, String) async throws -> URL = {
    try await InstallHelper.installPackage(
      at: $0, appURL: $1, receiptData: $2, expectedVersion: $3)
  }

  /// Starts the CommerceKit purchase; replaced in tests, which cannot reach the App Store.
  var purchase: @MainActor @Sendable (AppStoreUpdateOperation) async -> Void = {
    await $0.performPurchase()
  }
  /// False only for ad-hoc signed test fixtures.
  var requiresTeam = true
  /// Updater's own clone of the exact target: CommerceKit can install by itself on success.
  private let protection: ExternalInstallGuard

  /// Every App Store job goes through the one helper and download queue.
  override var lockKey: String { "appStoreHelper" }

  init(
    bundleIdentifier: String, installURL: URL, appIdentifier: App.Bundle.Identifier,
    appStoreIdentifier: UInt64
  ) {
    self.installURL = installURL
    itemIdentifier = appStoreIdentifier
    protection = ExternalInstallGuard(target: installURL)
    super.init(bundleIdentifier: bundleIdentifier, appIdentifier: appIdentifier)
  }

  static let requiresManualInstallation = ProcessInfo.processInfo.isOperatingSystemAtLeast(
    .init(majorVersion: 26, minorVersion: 1, patchVersion: 0))

  override func execute() {
    super.execute()
    Task { @MainActor in
      guard !self.isCancelled else {
        self.finish()
        return
      }
      // Fail closed before any helper or CommerceKit request if the install could land
      // on another copy of this app. Before macOS 26.1 CommerceKit installs by itself,
      // with no quit check, backup or verification, so that route always hands off.
      guard self.usesVerifiedHelperInstall, await self.allowsInstall() else {
        self.handOff()
        self.finishOnMain()
        return
      }
      guard !self.isCancelled, !self.isFinished else { return }
      // Recheck at execution time as well: approval or daemon health may have
      // changed while the operation waited in the queue.
      do { try await self.prepare() } catch {
        guard !self.isCancelled, !self.isFinished else { return }
        self.preparationFailed(error)
        return
      }
      guard !self.isCancelled, !self.isFinished else { return }
      // Before CommerceKit or the helper can touch the app: quit it with a time limit
      // (a refusal means no purchase) and take Updater's own clone (none means no purchase).
      do {
        self.protection.noteQuit(
          wasRunning: try await self.lifecycle.quit(
            at: self.installURL, name: self.installURL.deletingPathExtension().lastPathComponent))
      } catch is CancellationError {
        self.finishOnMain()
        return
      } catch {
        self.finish(with: error)
        return
      }
      do { try self.protection.takeClone() } catch {
        self.handOff()
        self.finishOnMain()
        return
      }
      guard !self.isCancelled, !self.isFinished else {
        await self.finalize(nil)
        return
      }
      await self.purchase(self)
    }
  }

  @MainActor private func performPurchase() async {
    // Register before starting the purchase: small downloads can finish before
    // its completion callback, and their package/receipt must be preserved.
    observerIdentifier = CKDownloadQueue.shared().add(self)
    let purchase = SSPurchase(itemIdentifier: itemIdentifier)
    do {
      let (_, completed, response) = try await CKPurchaseController.shared().perform(
        purchase, withOptions: 0)
      let downloads = response?.downloads ?? []
      // Cancellation can finish the operation before Apple creates its download.
      guard !isCancelled else {
        for download in downloads {
          CKDownloadQueue.shared().cancelDownload(
            download, promptToConfirm: false, askToDelete: false)
        }
        await finalize(nil)
        return
      }
      appStoreUpdateLogger.notice(
        "Purchase completed=\(completed), downloads=\(downloads.count)"
      )
      if downloads.isEmpty, !isFinished, !isInstalling {
        await finalize(LatestError.updateInfoUnavailable)
      }
    } catch {
      guard !isFinished, !isInstalling else { return }
      await finalize(error)
    }
  }

  /// Every path after the clone ends here: CommerceKit's own install, the helper install,
  /// or any failure. The shared guard verifies the exact URL, restores the clone on failure
  /// and reopens an app Updater quit; then the result is published.
  @MainActor func finalize(_ error: Error?) async {
    guard !isFinished else { return }
    let result = await protection.settle(
      error: error, expected: expectedVersion, requiresTeam: requiresTeam, lifecycle: lifecycle)
    if let result { finish(with: result) } else { finish() }
  }

  @MainActor private func allowsInstall() async -> Bool {
    await installGate(installURL, bundleIdentifier)
  }

  @MainActor private func handOff() {
    outcomeOverride = .handedOff
    openURL(URL(string: "macappstore://showUpdatesPage")!)
  }

  @MainActor private func preparationFailed(_ error: Error) {
    // No purchase has started. Remove the waiting operation without publishing
    // an update failure or a successful-install notification, then offer recovery.
    super.cancel()
    finishOnMain()
    let fallback = URL(string: "macappstore://apps.apple.com/updates")!
    UpdateInstallHelperAlert.shared.prepare(
      fallbackURL: fallback,
      error: error as? InstallHelperError ?? .unavailable(error.localizedDescription)
    ) { [bundleIdentifier, installURL, appIdentifier, itemIdentifier, expectedVersion] in
      let retry = AppStoreUpdateOperation(
        bundleIdentifier: bundleIdentifier, installURL: installURL,
        appIdentifier: appIdentifier, appStoreIdentifier: itemIdentifier)
      retry.expectedVersion = expectedVersion
      UpdateQueue.shared.addOperation(retry)
    }
  }

  override func cancel() {
    super.cancel()
    guard isCancelled else { return }
    Task { @MainActor in
      CKPurchaseController.shared().cancelPurchase(
        withProductID: NSNumber(value: self.itemIdentifier))
      self.cancelPendingDownload()
      // installer cannot safely be interrupted halfway through replacing an app.
      if !self.isInstalling { await self.finalize(nil) }
    }
  }

  @MainActor private func cancelPendingDownload() {
    let queue = CKDownloadQueue.shared()
    if let download = queue.download(forItemIdentifier: itemIdentifier) {
      queue.cancelDownload(download, promptToConfirm: false, askToDelete: false)
    }
  }

  override func finish() {
    Task { @MainActor in self.finishOnMain() }
  }

  @MainActor private func finishOnMain() {
    guard !isFinished else { return }
    if let observerIdentifier {
      CKDownloadQueue.shared().removeObserver(observerIdentifier)
      self.observerIdentifier = nil
    }
    artifacts.removeAll()
    // Exits that never reached finalize happened before anything could touch the app.
    protection.discard()
    protection.reopenIfQuit(lifecycle)
    super.finish()
  }

  @MainActor private func preserveArtifacts() {
    guard Self.requiresManualInstallation, !isFinished else { return }
    let folder = URL(fileURLWithPath: CKDownloadDirectory(nil), isDirectory: true)
      .appendingPathComponent(String(itemIdentifier), isDirectory: true)
    do { try artifacts.refresh(in: folder) } catch {
      // The folder is absent during initialization. If capture still fails at
      // removal, report the missing package/receipt instead of claiming success.
    }
  }

  @MainActor private func removed(_ snapshot: AppStoreDownloadSnapshot) async {
    guard !isFinished, !isInstalling else { return }
    appStoreUpdateLogger.notice(
      "Download removed: failed=\(snapshot.failed), cancelled=\(snapshot.cancelled), error=\((snapshot.error as NSError?)?.domain ?? "none", privacy: .public):\((snapshot.error as NSError?)?.code ?? 0)"
    )
    switch AppStoreDownloadResult(
      failed: snapshot.failed, cancelled: snapshot.cancelled, error: snapshot.error,
      wasCancelled: isCancelled)
    {
    case .completed:
      // CommerceKit installed by itself: verify against the clone like any other route.
      await nativeInstallCompleted()
      return
    case .failed(let error):
      await finalize(error)
      return
    case .installPackage:
      break
    }
    preserveArtifacts()
    guard let package = artifacts.packageURL,
      let receipt = artifacts.receiptURL.flatMap({ try? Data(contentsOf: $0) })
        ?? snapshot.receiptData,
      !receipt.isEmpty
    else {
      await finalize(
        LatestError.custom(
          title: "App Store Package Unavailable",
          description:
            "The App Store download did not provide a complete installer package and receipt. Please retry the update."
        ))
      return
    }
    do {
      isInstalling = true
      try await lifecycle.withApplicationClosed(
        at: installURL, name: installURL.deletingPathExtension().lastPathComponent
      ) { [self] in
        try await installPreservedPackage(package, receipt: receipt)
      }
      await finalize(nil)
    } catch  where outcomeOverride == .handedOff {
      await finalize(nil)
    } catch {
      await finalize(error)
    }
  }

  /// CommerceKit's download queue reported that it installed the update itself.
  @MainActor func nativeInstallCompleted() async {
    await finalize(nil)
  }

  /// Rechecks the exact target right before the helper mutates anything: copies can
  /// appear while the download ran or while the app was quitting.
  @MainActor func installPreservedPackage(_ package: URL, receipt: Data) async throws {
    guard await allowsInstall() else {
      handOff()
      throw CancellationError()
    }
    try beginCommit()
    progressState = .installing
    appStoreUpdateLogger.notice(
      "Installing preserved package: bytes=\((try? package.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)"
    )
    let installedURL = try await installPackage(
      package, installURL, receipt, expectedVersion?.versionNumber ?? "")
    // Refresh Spotlight and LaunchServices after restoring the App Store receipt.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
    process.arguments = [installedURL.path]
    try? process.run()
    LSRegisterURL(installedURL as CFURL, true)
  }
}

/// PackageKit reports its entitlement restriction as both failed and cancelled.
/// Only cancellation requested in Latest must prevent the installer workaround.
enum AppStoreDownloadResult {
  case completed
  case installPackage
  case failed(Error)

  init(failed: Bool, cancelled: Bool, error: Error?, wasCancelled: Bool) {
    if wasCancelled {
      self = .failed(CancellationError())
    } else if let error {
      self =
        AppStoreDownloadArtifacts.requiresPackageInstallation(error)
        ? .installPackage : .failed(error)
    } else if cancelled {
      self = .failed(CancellationError())
    } else if failed {
      self = .failed(LatestError.updateInfoUnavailable)
    } else {
      self = .completed
    }
  }
}

private struct AppStoreDownloadSnapshot: Sendable {
  let failed: Bool
  let cancelled: Bool
  let error: Error?
  let receiptData: Data?
  let phase: Int64?
  let loaded: Int64
  let total: Int64

  init?(_ download: SSDownload, itemIdentifier: UInt64) {
    guard let metadata = download.metadata, metadata.itemIdentifier == itemIdentifier,
      let status = download.status
    else {
      return nil
    }
    failed = status.isFailed
    cancelled = status.isCancelled
    error = status.error
    receiptData = metadata.receiptData
    let activePhase = status.activePhase
    phase = activePhase?.phaseType
    loaded = activePhase?.progressValue ?? 0
    total = activePhase?.totalProgressValue ?? 0
  }
}

extension AppStoreUpdateOperation: CKDownloadQueueObserver {
  func downloadQueue(_ queue: CKDownloadQueue, statusChangedFor download: SSDownload) {
    guard let snapshot = AppStoreDownloadSnapshot(download, itemIdentifier: itemIdentifier)
    else { return }
    Task { @MainActor in
      guard !self.isFinished, !self.isInstalling, !self.isCancelled else { return }
      self.preserveArtifacts()
      switch snapshot.phase {
      case 0:
        self.progressState = .downloading(loadedSize: snapshot.loaded, totalSize: snapshot.total)
      case 1:
        self.progressState = .extracting(
          progress: snapshot.total > 0 ? Double(snapshot.loaded) / Double(snapshot.total) : 0)
      default: self.progressState = .initializing
      }
    }
  }

  func downloadQueue(_ queue: CKDownloadQueue, changedWithRemoval download: SSDownload) {
    guard let snapshot = AppStoreDownloadSnapshot(download, itemIdentifier: itemIdentifier)
    else { return }
    Task { @MainActor in await self.removed(snapshot) }
  }
  func downloadQueue(_ queue: CKDownloadQueue, changedWithAddition download: SSDownload) {
    downloadQueue(queue, statusChangedFor: download)
  }
}

/// PackageKit's 201 restriction is the only failure a manual install can repair.
/// Preserve the newest inode on every event: App Store replaces partial files.
struct AppStoreDownloadArtifacts {
  private(set) var packageURL: URL?
  private(set) var receiptURL: URL?

  mutating func refresh(in folder: URL) throws {
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey,
    ]
    let children = try FileManager.default.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: Array(keys))
    var package: (url: URL, date: Date)?
    var receipt: URL?
    for file in children {
      guard file.pathExtension == "pkg" || file.lastPathComponent == "receipt",
        let info = try? file.resourceValues(forKeys: keys),
        info.isRegularFile == true, info.isSymbolicLink != true
      else { continue }
      if file.pathExtension == "pkg" {
        let date = info.contentModificationDate ?? .distantPast
        if let current = package, current.date >= date { continue }
        package = (file, date)
      } else {
        receipt = file
      }
    }
    // Capture the receipt even when a package link fails. Removal reports any
    // incomplete artifacts rather than claiming the update succeeded.
    defer {
      if let receipt, let link = try? preserve(receipt, replacing: receiptURL) {
        receiptURL = link
      }
    }
    if let package {
      packageURL = try preserve(package.url, replacing: packageURL)
    }
  }

  mutating func removeAll() {
    for url in [packageURL, receiptURL].compactMap({ $0 }) {
      try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
    packageURL = nil
    receiptURL = nil
  }

  static func requiresPackageInstallation(_ error: Error) -> Bool {
    var cause = error as NSError
    for _ in 0..<8 {
      if cause.domain == "PKInstallErrorDomain", cause.code == 201 { return true }
      guard let underlying = cause.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
      cause = underlying
    }
    return false
  }

  private func preserve(_ source: URL, replacing existing: URL?) throws -> URL {
    let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
    if let existing,
      let sourceID = try source.resourceValues(forKeys: key).fileResourceIdentifier,
      let existingID = try existing.resourceValues(forKeys: key).fileResourceIdentifier,
      sourceID.isEqual(existingID)
    {
      return existing
    }
    let directory = try FileManager.default.url(
      for: .itemReplacementDirectory,
      in: .userDomainMask, appropriateFor: source, create: true)
    let link = directory.appendingPathComponent(source.lastPathComponent)
    do { try FileManager.default.linkItem(at: source, to: link) } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
    if let existing {
      try? FileManager.default.removeItem(at: existing.deletingLastPathComponent())
    }
    return link
  }
}

extension SSPurchase {
  fileprivate convenience init(itemIdentifier: UInt64) {
    self.init(
      buyParameters:
        "productType=C&price=0&salableAdamId=\(itemIdentifier)&pg=default&appExtVrsId=0&pricingParameters=STDRDL"
    )

    let downloadMetadata = SSDownloadMetadata(kind: "software")
    downloadMetadata.itemIdentifier = itemIdentifier

    self.downloadMetadata = downloadMetadata
    self.itemIdentifier = itemIdentifier
    self.isUpdate = true
    self.isRedownload = true
  }
}

extension SSDownloadMetadata {
  /// Returns the app store receipt from the metadata.
  var receiptData: Data? {
    dictionary?["app-receipt"] as? Data
  }
}
