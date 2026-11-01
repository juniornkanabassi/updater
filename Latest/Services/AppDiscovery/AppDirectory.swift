//
//  DirectoryObserver.swift
//  Latest
//
//  Created by Max Langer on 02.01.18.
//  Copyright © 2018 Max Langer. All rights reserved.
//

import Darwin
import Foundation
import OSLog

private let appDirectoryLogger = Logger(
  subsystem: Foundation.Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
  category: "AppDiscovery"
)
private let appDirectorySignposter = OSSignposter(
  subsystem: Foundation.Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
  category: "AppDiscoveryPerformance"
)

/// The folder listener listens for changes in the given directory and then runs the update checker on changes
class AppDirectory: @unchecked Sendable {
  private struct CollectionRequest: Sendable {
    var notifyHandler: Bool
    var completions: [RefreshCompletion]
  }

  /// The url on which the listener reacts to changes on
  let url: URL

  /// The bundles collected within this directory.
  var bundles: [App.Bundle] {
    collectionQueue.sync {
      collectedBundles
    }
  }

  private var collectedBundles = [App.Bundle]()

  typealias UpdateHandler = @Sendable () -> Void
  typealias RefreshCompletion = @Sendable () -> Void

  /// The handler to be called once the directory contents change.
  let handler: UpdateHandler

  /// The queue on which updates to the collection are being performed.
  private let collectionQueue: DispatchQueue
  private let bundleCollector: @Sendable (URL) -> [App.Bundle]
  private let collectionRequestLock = NSLock()
  private var isCollectionScheduledOrRunning = false
  private var pendingCollectionRequest: CollectionRequest?

  /// The file system listener
  private lazy var listener: DispatchSourceFileSystemObject? = {
    let descriptor = open((self.url as NSURL).fileSystemRepresentation, O_EVTONLY)
    guard descriptor != -1 else { return nil }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: .write)

    source.setEventHandler { [weak self] in
      self?.collectBundles()
    }
    source.setCancelHandler {
      close(descriptor)
    }

    return source
  }()

  /// Initializes the class and resumes the listener automatically
  init(
    url: URL,
    notifyOnInitialCollection: Bool = true,
    initialCollectionCompletion: RefreshCompletion? = nil,
    bundleCollector: @escaping @Sendable (URL) -> [App.Bundle] = {
      BundleCollector.collectBundles(at: $0)
    },
    updateHandler: @escaping UpdateHandler
  ) {
    self.url = url
    self.handler = updateHandler
    self.bundleCollector = bundleCollector
    self.collectionQueue = DispatchQueue(label: "AppDirectoryCollectionQueue.\(url.path)")

    resumeTracking(
      notifyHandler: notifyOnInitialCollection,
      completion: initialCollectionCompletion
    )
  }

  deinit {
    listener?.cancel()
  }

  /// Forces the directory contents to be read from disk.
  func refresh(completion: RefreshCompletion? = nil) {
    collectBundles(notifyHandler: false, completion: completion)
  }

  /// Refreshes the directory with structured concurrency while preserving request coalescing.
  func refreshBundles() async {
    await withCheckedContinuation { continuation in
      refresh {
        continuation.resume()
      }
    }
  }

  /// Resumes tracking if it is not already running
  private func resumeTracking(notifyHandler: Bool, completion: RefreshCompletion?) {
    listener?.activate()
    collectBundles(notifyHandler: notifyHandler, completion: completion)
  }

  /// Triggers an update run
  private func collectBundles(notifyHandler: Bool = true, completion: RefreshCompletion? = nil) {
    let request = CollectionRequest(
      notifyHandler: notifyHandler,
      completions: completion.map { [$0] } ?? []
    )

    collectionRequestLock.lock()
    if isCollectionScheduledOrRunning {
      var pendingRequest =
        pendingCollectionRequest ?? CollectionRequest(notifyHandler: false, completions: [])
      pendingRequest.notifyHandler = pendingRequest.notifyHandler || request.notifyHandler
      pendingRequest.completions.append(contentsOf: request.completions)
      pendingCollectionRequest = pendingRequest
      collectionRequestLock.unlock()
      return
    }
    isCollectionScheduledOrRunning = true
    collectionRequestLock.unlock()

    collectionQueue.async {
      self.performCollections(startingWith: request)
    }
  }

  private func performCollections(startingWith initialRequest: CollectionRequest) {
    var request = initialRequest

    while true {
      let signpostID = appDirectorySignposter.makeSignpostID()
      let interval = appDirectorySignposter.beginInterval("Collect App Bundles", id: signpostID)
      let start = DispatchTime.now().uptimeNanoseconds
      let bundles = bundleCollector(url)
      let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
      collectedBundles = bundles
      appDirectorySignposter.endInterval("Collect App Bundles", interval)
      appDirectoryLogger.info(
        "Collected \(bundles.count, privacy: .public) apps from \(self.url.lastPathComponent, privacy: .private) in \(duration, privacy: .public) ms"
      )
      if request.notifyHandler {
        handler()
      }
      request.completions.forEach { $0() }

      collectionRequestLock.lock()
      if let pendingRequest = pendingCollectionRequest {
        pendingCollectionRequest = nil
        collectionRequestLock.unlock()
        request = pendingRequest
        continue
      }

      isCollectionScheduledOrRunning = false
      collectionRequestLock.unlock()
      return
    }
  }

}
