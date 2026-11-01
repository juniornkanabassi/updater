//
//  SparkleUpdateOperation.swift
//  Latest
//
//  Created by Max Langer on 01.07.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import AppKit
import Sparkle
import Synchronization

/// The operation updating Sparkle apps.
final class SparkleUpdateOperation: UpdateOperation, @unchecked Sendable {

  // Sparkle's driver callbacks run on the main actor. OperationQueue entry
  // points hop there before touching the updater or its download state.
  @MainActor private var updater: SPUUpdater?
  @MainActor private var cancellationCallback: (() -> Void)?
  @MainActor private var terminationRetry: (() -> Void)?
  @MainActor private var progressTask: Task<Void, Never>?
  @MainActor private var expectedContentLength: UInt64 = 0
  @MainActor private var receivedLength: UInt64 = 0
  /// Quits the target before Sparkle installs; injectable so tests never quit a real app.
  var lifecycle = AppLifecycle.live
  /// False only for ad-hoc signed test fixtures.
  var requiresTeam = true
  /// Updater's own clone of the exact target, taken before Sparkle can commit.
  private let backup = Mutex<(directory: URL, original: BundleIdentity)?>(nil)
  /// Set when Updater quit the target, so it is reopened after any failure or cancel.
  @MainActor private var wasRunning = false
  /// Opens an information-only item's page; injectable so tests open nothing.
  var openURL: @MainActor @Sendable (URL) -> Void = { MacApplicationWorkspace.shared.open($0) }

  // MARK: - Operation Overrides

  override func execute() {
    super.execute()

    // Gather app and app bundle
    guard let bundle = Bundle(path: self.appIdentifier.path) else {
      self.finish(with: LatestError.updateInfoUnavailable)
      return
    }
    // No Updater-owned copy, no Sparkle install: Sparkle replaces the bundle itself.
    do { try takeBackup() } catch {
      self.finish(with: error)
      return
    }

    Task { @MainActor in
      guard !self.isCancelled, !self.isFinished else { return }
      // Instantiate a new updater that performs the update
      let updater = SPUUpdater(
        hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)

      do {
        try updater.start()
      } catch let error {
        self.finish(with: error)
        return
      }

      guard !self.isCancelled, !self.isFinished else { return }
      self.updater = updater
      updater.checkForUpdates()
    }
  }

  override func cancel() {
    super.cancel()
    guard isCancelled else { return }
    self.finish()
  }

  /// APFS clone into a private folder on the target's volume.
  func takeBackup() throws {
    let directory = try FileManager.default.url(
      for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appIdentifier,
      create: true)
    let original = try ReplacementTransaction.cloneOriginal(at: appIdentifier, into: directory)
    backup.withLock { $0 = (directory, original) }
  }

  /// Every terminal path ends here: verify what Sparkle left at the exact URL against the
  /// clone (restoring it on failure, after closing a relaunched app), reopen the app if
  /// Updater quit it and it is not running, then publish the result.
  @MainActor func finalize(_ error: Error?) async {
    var result = error
    if let saved = backup.withLock({ value -> (directory: URL, original: BundleIdentity)? in
      defer { value = nil }
      return value
    }) {
      do {
        try ReplacementTransaction.verifyExternalInstall(
          at: appIdentifier, original: saved.original, expected: expectedVersion,
          requiresTeam: requiresTeam)
        try? FileManager.default.removeItem(at: saved.directory)
      } catch let failure {
        do {
          try await lifecycle.quit(
            at: appIdentifier, name: appIdentifier.deletingPathExtension().lastPathComponent)
          try ReplacementTransaction.restore(
            appIdentifier, backupDirectory: saved.directory, originalIdentity: saved.original)
          try? FileManager.default.removeItem(at: saved.directory)
          result = failure
        } catch {
          result = ReplacementError.restoreFailed(
            saved.directory.appendingPathComponent(ReplacementTransaction.backupName).path)
        }
      }
    }
    reopenIfQuit()
    if let result { finish(with: result) } else { finish() }
  }

  @MainActor private func reopenIfQuit() {
    guard wasRunning, lifecycle.runningApps(appIdentifier).isEmpty,
      FileManager.default.fileExists(atPath: appIdentifier.path)
    else { return }
    wasRunning = false
    lifecycle.reopen(appIdentifier)
  }

  override func finish() {
    // Cancel and early exits happen before Sparkle commits: the target is untouched.
    if let saved = backup.withLock({ value -> (directory: URL, original: BundleIdentity)? in
      defer { value = nil }
      return value
    }) {
      try? FileManager.default.removeItem(at: saved.directory)
    }
    super.finish()
    Task { @MainActor in
      self.reopenIfQuit()
      self.cancelProgressNotification()
      let cancellation = self.cancellationCallback
      self.cancellationCallback = nil
      self.terminationRetry = nil
      if self.isCancelled { cancellation?() }
      self.updater = nil
    }
  }

  @MainActor
  override func retryTermination() {
    guard !isCancelled, !isFinished else { return }
    terminationRetry?()
  }

}

// MARK: - Driver Implementation
extension SparkleUpdateOperation: SPUUserDriver {

  // MARK: - Preparing Update

  func show(
    _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(.init(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
    guard !isCancelled, !isFinished else {
      cancellation()
      return
    }
    cancellationCallback = cancellation
    self.progressState = .initializing
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    handleUpdateFound(appcastItem, reply: reply)
  }

  /// Split out because Sparkle's update state cannot be constructed in tests.
  @MainActor func handleUpdateFound(
    _ appcastItem: SUAppcastItem, reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    expectedVersion = Version(
      versionNumber: appcastItem.displayVersionString, buildNumber: appcastItem.versionString)
    // The feed may have turned informational since the check: never reply .install.
    if appcastItem.isInformationOnlyUpdate {
      reply(.dismiss)
      if let infoURL = appcastItem.infoURL { openURL(infoURL) }
      outcomeOverride = .handedOff
      finish()
      return
    }
    reply(self.isCancelled ? .dismiss : .install)
  }

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    Task { await finalize(error) }
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    Task { await finalize(error) }
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    // A relaunched app is running, so reopenIfQuit leaves it alone.
    Task { await finalize(nil) }
  }

  func showUpdateInFocus() {
    // Noop
  }

  func showDownloadInitiated(cancellation: @escaping () -> Void) {
    if self.isCancelled || self.isFinished {
      cancellation()
      return
    }

    self.cancellationCallback = cancellation
  }

  // MARK: - Downloading Update

  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
    // A replacement download (for example after a failed delta) resets progress.
    self.expectedContentLength = expectedContentLength
    self.receivedLength = 0

    self.scheduleProgressHandler()
  }

  func showDownloadDidReceiveData(ofLength length: UInt64) {
    self.receivedLength += length

    // Expected content length may be wrong, adjust if needed
    self.expectedContentLength = max(self.expectedContentLength, self.receivedLength)

    self.scheduleProgressHandler()
  }

  @MainActor
  private func scheduleProgressHandler() {
    guard progressTask == nil, !isCancelled, !isFinished else { return }
    progressTask = Task { [weak self] in
      do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
      guard let self else { return }
      self.progressTask = nil
      guard !self.isCancelled, !self.isFinished else { return }
      self.progressState = .downloading(
        loadedSize: Int64(clamping: self.receivedLength),
        totalSize: Int64(clamping: self.expectedContentLength),
        cancellable: !self.isCommitting)
    }
  }

  @MainActor
  private func cancelProgressNotification() {
    progressTask?.cancel()
    progressTask = nil
  }

  // MARK: - Installing Update

  func showDownloadDidStartExtractingUpdate() {
    guard !isFinished else { return }
    // Sparkle launches its installer immediately after this callback. A closed
    // target can be replaced before showReady or showInstallingUpdate arrives.
    do { try beginCommit() } catch { return }
    cancelProgressNotification()
    self.progressState = .extracting(progress: 0, cancellable: false)
  }

  func showExtractionReceivedProgress(_ progress: Double) {
    guard !isCancelled, !isFinished else { return }
    cancelProgressNotification()
    self.progressState = .extracting(progress: progress, cancellable: false)
  }

  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard !isFinished else {
      reply(.skip)
      return
    }
    // A running target is quit by Updater first, with a time limit. Sparkle's own
    // terminate request waits without end, so a refusal would leave the job pending
    // and the install deferred to whenever the app later quits.
    if !lifecycle.runningApps(appIdentifier).isEmpty {
      Task { @MainActor in
        do {
          wasRunning = try await lifecycle.quit(
            at: appIdentifier, name: appIdentifier.deletingPathExtension().lastPathComponent)
        } catch {
          // .skip cancels the installation; .dismiss would defer it.
          reply(.skip)
          await finalize(error is CancellationError ? nil : error)
          return
        }
        install(reply)
      }
      return
    }
    install(reply)
  }

  @MainActor private func install(_ reply: @escaping (SPUUserUpdateChoice) -> Void) {
    guard !isFinished else {
      reply(.skip)
      return
    }
    do {
      try beginCommit()
      cancelProgressNotification()
      progressState = .installing
      reply(.install)
    } catch {
      // Dismiss leaves the update scheduled for the next quit; skip cancels it.
      reply(.skip)
    }
  }

  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {
    guard !isFinished else { return }
    // Closed targets skip showReady, so this route needs the same protection.
    do { try beginCommit() } catch { return }
    cancelProgressNotification()
    terminationRetry = applicationTerminated ? nil : retryTerminatingApplication
    progressState = applicationTerminated ? .installing : .waitingForQuit
    // After commit Sparkle's installer will replace the app whenever it quits, so the job
    // stays open, holds its lock and shows Retry until Sparkle reports the result.
  }

  // MARK: - Ignored Methods

  // Sparkle calls this SPUUserDriver requirement through its protocol.
  // swiftlint:disable:next unused_declaration
  func showCanCheck(forUpdates canCheckForUpdates: Bool) {}
  func dismissUserInitiatedUpdateCheck() {}
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showSendingTerminationSignal() {}
  func dismissUpdateInstallation() {}

}

extension SparkleUpdateOperation: SPUUpdaterDelegate {

  func feedURLString(for updater: SPUUpdater) -> String? {
    // We can try to supply a valid feed as addition to Sparkle's own methods.
    // For some cases (like DevMate) Sparkle fails to retrieve an appcast by itself.
    return SparkleFeed.feedURL(from: updater.hostBundle)?.absoluteString
  }

}
