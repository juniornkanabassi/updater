//
//  AppLibrary.swift
//  Latest
//
//  Created by Max Langer on 08.01.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Foundation
import OSLog

private let appLibraryLogger = Logger(
  subsystem: Foundation.Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
  category: "AppDiscovery"
)

/// Observes the local collection of apps and notifies its owner of changes.
class AppLibrary: @unchecked Sendable {

  /// The handler to be called when apps change locally.
  typealias UpdateHandler = @Sendable ([App.Bundle]) -> Void
  let updateHandler: UpdateHandler

  /// The handler to be called when a full reload completed.
  typealias ReloadHandler = @Sendable ([App.Bundle]) -> Void

  /// A list of all application bundles that are available locally.
  var bundles: [App.Bundle] {
    stateQueue.sync {
      currentBundles()
    }
  }

  private var directories = [URL: AppDirectory]()
  private var directoryGeneration = 0
  private var isPreparingDirectories = false

  /// Initializes the library with the given handler for updates.
  typealias DirectoryStoreFactory =
    @Sendable (@escaping AppDirectoryUpdateHandler) -> any AppDirectoryStoring
  private let directoryStoreFactory: DirectoryStoreFactory

  init(
    directoryStoreFactory: @escaping DirectoryStoreFactory = {
      AppDirectoryStore(updateHandler: $0)
    },
    handler: @escaping UpdateHandler
  ) {
    self.directoryStoreFactory = directoryStoreFactory
    self.updateHandler = handler
  }

  private let stateQueue = DispatchQueue(label: "AppLibraryStateQueue")

  private var scheduledUpdateWorkItem: DispatchWorkItem?

  private static let updateCoalescingInterval: TimeInterval = 0.5

  // MARK: - Actions

  /// Starts the update checking process
  func startQuery() {
    stateQueue.async { [weak self] in
      guard let self else { return }
      self.setupDirectoryObservers()
    }
  }

  /// Forces all observed directories to be read from disk again.
  func reload(handler: @escaping ReloadHandler) {
    stateQueue.async { [weak self] in
      guard let self else { return }
      self.setupDirectoryObservers()
      self.refreshDirectories(handler: handler)
    }
  }

  private func setupDirectoryObservers() {
    // Publish a changed directory set after new observers finish their first scan.
    // Removal-only changes also need a publication: they have no file event.
    let isInitialSetup = self.directories.isEmpty
    let dispatchGroup = DispatchGroup()
    let previousURLs = Set(directories.keys)
    appLibraryLogger.info(
      "Preparing app directory observers. initial=\(isInitialSetup, privacy: .public)")

    // Setup directories
    let observedDirectories: [(URL, AppDirectory)] = directoryStore.URLs.compactMap { url in
      // Skip unreachable directories
      guard directoryStore.isReachable(url) else { return nil }

      // Reuse existing directory observations if possible
      if let directory = directories[url] {
        return (url, directory)
      }

      let directory: AppDirectory
      let updateHandler: AppDirectory.UpdateHandler = { [weak self] in
        // Schedule update and coalesce bursts of file-system events.
        self?.scheduleUpdate()
      }

      dispatchGroup.enter()
      directory = AppDirectory(
        url: url,
        notifyOnInitialCollection: false,
        initialCollectionCompletion: { dispatchGroup.leave() },
        updateHandler: updateHandler
      )

      return (url, directory)
    }
    directories = Dictionary(uniqueKeysWithValues: observedDirectories)
    appLibraryLogger.info("Observing \(self.directories.count, privacy: .public) app directories")

    guard isInitialSetup || previousURLs != Set(directories.keys) else { return }
    directoryGeneration += 1
    let generation = directoryGeneration
    isPreparingDirectories = true
    scheduledUpdateWorkItem?.cancel()
    dispatchGroup.notify(queue: stateQueue) {
      guard self.directoryGeneration == generation else { return }
      self.isPreparingDirectories = false
      // Call update immediately. Using the scheduler delays the update.
      self.performUpdate()
    }
  }

  private func performUpdate() {
    guard !isPreparingDirectories else { return }
    let bundles = currentBundles()
    appLibraryLogger.info("Publishing \(bundles.count, privacy: .public) discovered apps")
    updateHandler(bundles)
  }

  private func refreshDirectories(handler: @escaping ReloadHandler) {
    let directories = Array(self.directories.values)
    appLibraryLogger.info("Refreshing \(directories.count, privacy: .public) app directories")

    Task { [weak self] in
      await withTaskGroup(of: Void.self) { group in
        for directory in directories {
          group.addTask {
            await directory.refreshBundles()
          }
        }
      }

      guard let self else { return }
      let bundles = self.stateQueue.sync { self.currentBundles() }
      handler(bundles)
    }
  }

  private func scheduleUpdate() {
    stateQueue.async { [weak self] in
      guard let self else { return }
      self.scheduleUpdateOnStateQueue()
    }
  }

  private func scheduleUpdateOnStateQueue() {
    self.scheduledUpdateWorkItem?.cancel()

    let workItem = DispatchWorkItem { [weak self] in
      self?.performUpdate()
    }
    self.scheduledUpdateWorkItem = workItem

    self.stateQueue.asyncAfter(deadline: .now() + Self.updateCoalescingInterval, execute: workItem)
  }

  private func currentBundles() -> [App.Bundle] {
    directories.flatMap { $0.value.bundles }
  }

  // MARK: - Directory Handling

  /// The store handling application directories.
  private lazy var directoryStore = {
    directoryStoreFactory { [weak self] in self?.startQuery() }
  }()

}
