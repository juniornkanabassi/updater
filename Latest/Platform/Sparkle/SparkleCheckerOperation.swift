//
//  SparkleUpdateCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 03.10.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import Foundation
import Sparkle
import Synchronization

private actor SparkleCheckResultGate {
  private var continuation: CheckedContinuation<App.Update, Error>?
  private var pendingResult: Result<App.Update, Error>?

  func install(_ continuation: CheckedContinuation<App.Update, Error>) {
    if let pendingResult {
      self.pendingResult = nil
      continuation.resume(with: pendingResult)
    } else {
      self.continuation = continuation
    }
  }

  func resume(with result: Result<App.Update, Error>) {
    if let continuation {
      self.continuation = nil
      continuation.resume(with: result)
    } else if pendingResult == nil {
      pendingResult = result
    }
  }
}

/// Async update checking for a Sparkle app. The historical type name is
/// retained for source compatibility, but checking is no longer an Operation.
final class SparkleUpdateCheckerOperation: NSObject, @unchecked Sendable {
  static let checkTimeout: TimeInterval = 10

  private static func feedURL(from appURL: URL) -> URL? {
    guard let bundle = Bundle(path: appURL.path) else { return nil }
    return SparkleFeed.feedURL(from: bundle)
  }

  private let app: App.Bundle
  private let url: URL?
  private let resultGate = SparkleCheckResultGate()
  private let cancellationState = Mutex(false)
  @MainActor private var updater: SPUUpdater?

  init(with app: App.Bundle) {
    self.app = app
    self.url = Self.feedURL(from: app.fileURL)
  }

  func check() async throws -> App.Update {
    guard let bundle = Bundle(path: app.fileURL.path) else {
      throw LatestError.updateInfoUnavailable
    }
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(Self.checkTimeout * 1_000_000_000))
      guard !Task.isCancelled else { return }
      self?.complete(.failure(URLError(.timedOut)))
    }
    defer {
      timeoutTask.cancel()
      Task { @MainActor [weak self] in self?.updater = nil }
    }

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        Task { [weak self] in
          guard let self else {
            continuation.resume(throwing: CancellationError())
            return
          }
          await self.resultGate.install(continuation)
          guard !self.cancellationState.withLock({ $0 }) else { return }
          do {
            try await self.startUpdater(for: bundle)
          } catch {
            self.complete(.failure(error))
          }
        }
      }
    } onCancel: { [weak self] in
      guard let self else { return }
      self.cancellationState.withLock { $0 = true }
      self.complete(.failure(CancellationError()))
    }
  }

  @MainActor
  private func startUpdater(for bundle: Bundle) throws {
    guard !cancellationState.withLock({ $0 }) else {
      throw CancellationError()
    }
    let updater = SPUUpdater(
      hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
    try updater.start()
    updater.checkForUpdates()
    self.updater = updater
  }

  private func complete(_ result: Result<App.Update, Error>) {
    Task { await resultGate.resume(with: result) }
  }

  private func finish(with appcastItem: SUAppcastItem) {
    guard !cancellationState.withLock({ $0 }) else { return }
    let version = Version(
      versionNumber: appcastItem.displayVersionString, buildNumber: appcastItem.versionString)
    let minimumOSVersion = appcastItem.minimumSystemVersion.flatMap {
      try? OperatingSystemVersion(string: $0)
    }

    var releaseNotes: App.Update.ReleaseNotes?
    let releaseNotesURL = appcastItem.releaseNotesURL ?? appcastItem.fullReleaseNotesURL
    // Surge publishes its changelog in this custom appcast element.
    if let description = appcastItem.itemDescription
      ?? appcastItem.propertiesDictionary["markdownDescription"] as? String
    {
      if ReleaseNotesMarkup.isUsefulReleaseNotesText(
        description, relevantVersion: version.versionNumber)
      {
        releaseNotes = .html(string: description)
      } else if let url = releaseNotesURL
        ?? ReleaseNotesMarkup.firstReleaseNotesURL(in: description, baseURL: self.url)
      {
        releaseNotes =
          ReleaseNotesSourceCatalog.releaseNotes(
            forSparkleReleaseNotesURL: url,
            bundle: app,
            remoteVersion: version
          ) ?? .url(url: url)
      }
    } else if let url = releaseNotesURL {
      releaseNotes =
        ReleaseNotesSourceCatalog.releaseNotes(
          forSparkleReleaseNotesURL: url,
          bundle: app,
          remoteVersion: version
        ) ?? .url(url: url)
    }

    if releaseNotes == nil {
      releaseNotes = ReleaseNotesSourceCatalog.releaseNotes(for: app, remoteVersion: version)
    }

    complete(
      .success(
        App.Update(
          app: app,
          remoteVersion: version,
          minimumOSVersion: minimumOSVersion,
          source: .sparkle,
          date: appcastItem.date,
          releaseNotes: releaseNotes,
          updateAction: .builtIn { app in
            UpdateQueue.shared.addOperation(
              SparkleUpdateOperation(
                bundleIdentifier: app.bundleIdentifier,
                appIdentifier: app.identifier
              ))
          }
        )))
  }
}

extension SparkleUpdateCheckerOperation: SPUUserDriver {
  func show(
    _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
  ) {
    reply(.init(automaticUpdateChecks: false, sendSystemProfile: false))
  }

  func showUpdateFound(
    with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
    reply: @escaping (SPUUserUpdateChoice) -> Void
  ) {
    finish(with: appcastItem)
  }

  func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
    let nsError = error as NSError
    if nsError.domain == SUSparkleErrorDomain,
      nsError.code == SUError.noUpdateError.rawValue,
      let appcastItem = nsError.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem
    {
      finish(with: appcastItem)
    } else {
      complete(.failure(error))
    }
    acknowledgement()
  }

  func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
    complete(.failure(error))
    acknowledgement()
  }

  func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
    acknowledgement()
    complete(.failure(LatestError.updateInfoUnavailable))
  }

  func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}
  func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
  func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
  func showUpdateInFocus() {}
  func showDownloadInitiated(cancellation: @escaping () -> Void) {}
  func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
  func showDownloadDidReceiveData(ofLength length: UInt64) {}
  func showDownloadDidStartExtractingUpdate() {}
  func showExtractionReceivedProgress(_ progress: Double) {}
  func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {}
  func showInstallingUpdate(
    withApplicationTerminated applicationTerminated: Bool,
    retryTerminatingApplication: @escaping () -> Void
  ) {}
  // Sparkle calls this SPUUserDriver requirement through its protocol.
  // swiftlint:disable:next unused_declaration
  func showCanCheck(forUpdates canCheckForUpdates: Bool) {}
  func dismissUserInitiatedUpdateCheck() {}
  func showSendingTerminationSignal() {}
  func dismissUpdateInstallation() {}
}

extension SparkleUpdateCheckerOperation: SPUUpdaterDelegate {
  func feedURLString(for updater: SPUUpdater) -> String? {
    url?.absoluteString
  }
}
