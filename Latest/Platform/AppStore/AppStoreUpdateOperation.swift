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
  @MainActor private var published = false

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
  /// After a lost helper reply: is the helper idle (nil = unreachable), how often to ask,
  /// and for how long before giving up and keeping the original aside.
  var helperIsIdle: @Sendable () async -> Bool? = { await InstallHelper.isIdle() }
  var helperPollInterval: Duration = .seconds(5)
  var helperWaitLimit: Duration = .seconds(600)
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
    // This task owns the job until something else (the purchase or the download queue)
    // takes over; cancel() only signals, and each step below checks it.
    Task { @MainActor in
      guard !self.isCancelled else { return self.finishOnMain() }
      // Fail closed before any helper or CommerceKit request if the install could land
      // on another copy of this app. Before macOS 26.1 CommerceKit installs by itself,
      // with no quit check, backup or verification, so that route always hands off.
      guard self.usesVerifiedHelperInstall else {
        self.handOff(
          because: "Before macOS 26.1 the App Store installs by itself, without Updater's checks.")
        return self.finishOnMain()
      }
      guard await self.allowsInstall() else {
        self.handOff(because: Self.notSoleCopy)
        return self.finishOnMain()
      }
      guard !self.isCancelled else { return self.finishOnMain() }
      // Recheck at execution time as well: approval or daemon health may have
      // changed while the operation waited in the queue.
      do { try await self.prepare() } catch {
        guard !self.isCancelled else { return self.finishOnMain() }
        return self.preparationFailed(error)
      }
      guard !self.isCancelled else { return self.finishOnMain() }
      // Before CommerceKit or the helper can touch the app: quit it with a time limit
      // (a refusal means no purchase) and take Updater's own clone (none means no purchase).
      // A quit that completed is always undone by reopening, however the job ends.
      do {
        self.protection.noteQuit(
          wasRunning: try await self.lifecycle.quit(
            at: self.installURL, name: self.installURL.deletingPathExtension().lastPathComponent))
      } catch is CancellationError {
        // A declined or unanswered quit prompt: a cancel, recorded nowhere, reported as needsQuit.
        if !self.isCancelled { self.declineQuit() }
        return self.finishOnMain()
      } catch {
        return self.finish(with: error)
      }
      guard !self.isCancelled else { return self.finishOnMain() }
      do { try self.takeBackup() } catch {
        self.handOff(because: "Updater could not make its safety copy of the app.")
        return self.finishOnMain()
      }
      // Discovery can change during preparation and the quit: check again right before
      // the purchase, which is the first step that can change the app.
      guard !self.isCancelled, await self.allowsInstall() else {
        if !self.isCancelled { self.handOff(because: Self.notSoleCopy) }
        return await self.finalize(nil)
      }
      // Issuing the purchase is the commit point, as for Sparkle: from here cancel is a
      // no-op and the cancel control is hidden. A cancel during the gate above ends here.
      do { try self.beginCommit() } catch { return await self.finalize(nil) }
      self.progressState = .initializing
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
    // Every caller waits for the same settlement; the result is published once, after it.
    let result = await protection.settle(
      error: error, expected: expectedVersion, requiresTeam: requiresTeam, lifecycle: lifecycle)
    guard !published else { return }
    published = true
    if let result { finish(with: result) } else { finish() }
  }

  @MainActor private func allowsInstall() async -> Bool {
    await installGate(installURL, bundleIdentifier)
  }

  private static let notSoleCopy =
    "Updater could not confirm that this is the only copy the App Store would update."

  /// Automation without --allow-handoff only learns that the App Store has it.
  @MainActor private func handOff(because reason: String) {
    recordHandOff(to: "the App Store", because: reason) { [openURL] in
      openURL(URL(string: "macappstore://showUpdatesPage")!)
    }
  }

  /// The recovery sheet; injectable so tests never present the shared one.
  @MainActor var helperAlert: UpdateInstallHelperAlert { injectedHelperAlert ?? .shared }
  @MainActor var injectedHelperAlert: UpdateInstallHelperAlert?

  @MainActor private func preparationFailed(_ error: Error) {
    // No purchase has started. Remove the waiting operation without publishing
    // an update failure or a successful-install notification, then offer recovery.
    super.cancel()
    finishOnMain()
    let fallback = URL(string: "macappstore://apps.apple.com/updates")!
    // The sheet runs outside this job: it keeps the job's hand-off policy.
    ExternalHandOff.$allowed.withValue(allowsExternalHandOff) { presentRecovery(error, fallback) }
  }

  @MainActor private func presentRecovery(_ error: Error, _ fallback: URL) {
    helperAlert.prepare(
      fallbackURL: fallback,
      error: error as? InstallHelperError ?? .unavailable(error.localizedDescription)
    ) {
      [
        bundleIdentifier, installURL, appIdentifier, itemIdentifier, expectedVersion,
        allowsExternalHandOff
      ] in
      let retry = AppStoreUpdateOperation(
        bundleIdentifier: bundleIdentifier, installURL: installURL,
        appIdentifier: appIdentifier, appStoreIdentifier: itemIdentifier)
      retry.expectedVersion = expectedVersion
      retry.allowsExternalHandOff = allowsExternalHandOff
      UpdateQueue.shared.addOperation(retry)
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
    await installThroughHelper(package, receipt: receipt)
  }

  /// Takes Updater's clone outside the normal flow; for tests of the install phase.
  /// The helper's PackageKit install is the writer; it is asked whether it is idle.
  func takeBackup() throws {
    try protection.takeClone(mechanism: "appStore", lockKey: lockKey, writer: .helper)
  }

  @MainActor func installThroughHelper(_ package: URL, receipt: Data) async {
    isInstalling = true
    do {
      // The app may have been reopened during the download. Quit it again, but leave the
      // reopen to the guard: it happens after settlement, never while the outcome is unknown.
      protection.noteQuit(
        wasRunning: try await lifecycle.quit(
          at: installURL, name: installURL.deletingPathExtension().lastPathComponent))
      try await installPreservedPackage(package, receipt: receipt)
      await finalize(nil)
    } catch {
      if InstallHelper.isLostReply(error) {
        await finalizeAfterLostReply()
      } else {
        // The pre-install gate hands off by throwing a cancellation; that is not a failure.
        await finalize(outcomeOverride == .handedOff && error is CancellationError ? nil : error)
      }
    }
  }

  /// A lost reply does not mean the installer stopped. Keep the clone, the lock and the
  /// closed app until the helper reports idle, then settle normally. If that cannot be
  /// established, finish as failed with the original kept aside and nothing restored.
  @MainActor private func finalizeAfterLostReply() async {
    progressState = .installing
    let deadline = ContinuousClock.now + helperWaitLimit
    while ContinuousClock.now < deadline {
      if await helperIsIdle() == true { return await finalize(nil) }
      try? await Task.sleep(for: helperPollInterval)
    }
    let kept = protection.abandon()
    guard !published else { return }
    published = true
    finish(with: ReplacementError.outcomeUnknown(kept?.path ?? installURL.path))
  }

  /// CommerceKit's download queue reported that it installed the update itself.
  @MainActor func nativeInstallCompleted() async {
    await finalize(nil)
  }

  /// Rechecks the exact target right before the helper mutates anything: copies can
  /// appear while the download ran or while the app was quitting.
  @MainActor func installPreservedPackage(_ package: URL, receipt: Data) async throws {
    guard await allowsInstall() else {
      handOff(because: Self.notSoleCopy)
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
        self.progressState = .downloading(
          loadedSize: snapshot.loaded, totalSize: snapshot.total, cancellable: false)
      case 1:
        self.progressState = .extracting(
          progress: snapshot.total > 0 ? Double(snapshot.loaded) / Double(snapshot.total) : 0,
          cancellable: false)
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
