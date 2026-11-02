//
//  DirectoryObserver.swift
//  Latest
//
//  Created by Max Langer on 02.01.18.
//  Copyright © 2018 Max Langer. All rights reserved.
//

import CoreServices
import Foundation
import OSLog

private let appDirectoryLogger = Logger(
  subsystem: Foundation.Bundle.main.bundleIdentifier ?? "com.juniornkanabassi.Updater",
  category: "AppDiscovery"
)
private let appDirectorySignposter = OSSignposter(
  subsystem: Foundation.Bundle.main.bundleIdentifier ?? "com.juniornkanabassi.Updater",
  category: "AppDiscoveryPerformance"
)

/// Watches a folder and everything below it with FSEvents. A change inside a known bundle
/// re-reads only that app; anything else (a new app, a removal, a subfolder) rescans the folder.
class AppDirectory: @unchecked Sendable {
  private struct CollectionRequest: Sendable {
    var notifyHandler: Bool
    var completions: [RefreshCompletion]
    /// Apps to re-read; nil rescans the whole folder.
    var apps: Set<URL>? = nil

    mutating func merge(_ other: CollectionRequest) {
      notifyHandler = notifyHandler || other.notifyHandler
      completions.append(contentsOf: other.completions)
      apps = apps.flatMap { mine in other.apps.map { mine.union($0) } }
    }
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

  private let bundleReader: @Sendable (URL) -> App.Bundle?
  private var stream: FSEventStreamRef?
  private let eventQueue: DispatchQueue

  /// Initializes the class and resumes the listener automatically
  init(
    url: URL,
    notifyOnInitialCollection: Bool = true,
    initialCollectionCompletion: RefreshCompletion? = nil,
    bundleCollector: @escaping @Sendable (URL) -> [App.Bundle] = {
      BundleCollector.collectBundles(at: $0)
    },
    bundleReader: @escaping @Sendable (URL) -> App.Bundle? = {
      BundleCollector.collectBundle(at: $0)
    },
    debounce: TimeInterval = 2,
    updateHandler: @escaping UpdateHandler
  ) {
    self.url = url
    self.handler = updateHandler
    self.bundleCollector = bundleCollector
    self.bundleReader = bundleReader
    self.collectionQueue = DispatchQueue(label: "AppDirectoryCollectionQueue.\(url.path)")
    self.eventQueue = DispatchQueue(label: "AppDirectoryEvents.\(url.path)")

    startWatching(latency: debounce)
    collectBundles(
      notifyHandler: notifyOnInitialCollection, completion: initialCollectionCompletion)
  }

  deinit {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
  }

  /// The stream holds a weak box, so it never keeps the directory alive or calls a freed one.
  private final class WeakDirectory {
    weak var directory: AppDirectory?
    init(_ directory: AppDirectory) { self.directory = directory }
  }

  /// FSEvents' latency coalesces bursts (an install writes thousands of files) into one batch.
  private func startWatching(latency: TimeInterval) {
    let box = Unmanaged.passRetained(WeakDirectory(self))
    var context = FSEventStreamContext(
      version: 0, info: box.toOpaque(), retain: nil,
      release: { info in
        guard let info else { return }
        Unmanaged<WeakDirectory>.fromOpaque(info).release()
      }, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info,
        let directory = Unmanaged<WeakDirectory>.fromOpaque(info).takeUnretainedValue().directory,
        let paths = unsafeBitCast(paths, to: NSArray.self) as? [String]
      else { return }
      directory.handleEvents(
        paths: paths, flags: Array(UnsafeBufferPointer(start: flags, count: count)))
    }
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, [url.path] as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
    else {
      box.release()
      appDirectoryLogger.error("Could not watch \(self.url.path, privacy: .private)")
      return
    }
    self.stream = stream
    FSEventStreamSetDispatchQueue(stream, eventQueue)
    FSEventStreamStart(stream)
  }

  private func handleEvents(paths: [String], flags: [FSEventStreamEventFlags]) {
    let rescanFlags = FSEventStreamEventFlags(
      kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
        | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
    let apps =
      flags.contains { $0 & rescanFlags != 0 } ? nil : Self.changedApps(in: paths, below: url)
    collectBundles(notifyHandler: true, apps: apps)
  }

  /// The outermost app bundle each event path lies in, or nil when any path is outside one.
  static func changedApps(in paths: [String], below root: URL) -> Set<URL>? {
    // FSEvents reports resolved paths (/private/var/…); rows keep the watched spelling.
    // URL.resolvingSymlinksInPath keeps /var, so ask the kernel for the real path.
    let real = realpath(root.path, nil).map { pointer in
      defer { free(pointer) }
      return String(cString: pointer)
    }
    let rootComponents = URL(fileURLWithPath: real ?? root.path).standardizedFileURL.pathComponents
    var apps = Set<URL>()
    for path in paths {
      let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
      guard components.starts(with: rootComponents) else { return nil }
      let relative = components.dropFirst(rootComponents.count)
      guard let end = relative.firstIndex(where: { $0.lowercased().hasSuffix(".app") }) else {
        return nil
      }
      apps.insert(relative[...end].reduce(root) { $0.appendingPathComponent($1) })
    }
    return apps
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

  /// Triggers an update run
  private func collectBundles(
    notifyHandler: Bool = true, completion: RefreshCompletion? = nil, apps: Set<URL>? = nil
  ) {
    let request = CollectionRequest(
      notifyHandler: notifyHandler,
      completions: completion.map { [$0] } ?? [],
      apps: apps
    )

    collectionRequestLock.lock()
    if isCollectionScheduledOrRunning {
      if var pendingRequest = pendingCollectionRequest {
        pendingRequest.merge(request)
        pendingCollectionRequest = pendingRequest
      } else {
        pendingCollectionRequest = request
      }
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
      let bundles = rescanned(request.apps)
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

  /// Re-reads only the named apps when all of them are already known; an unknown one may be
  /// new or sit in an excluded folder, so the folder's own rules decide with a full scan.
  private func rescanned(_ apps: Set<URL>?) -> [App.Bundle] {
    // Matched by path, then re-read at the URL the full scan produced, so the row keeps its identity.
    let known = Dictionary(
      collectedBundles.map { ($0.fileURL.standardizedFileURL.path, $0.fileURL) },
      uniquingKeysWith: { first, _ in first })
    let urls = apps?.compactMap { known[$0.standardizedFileURL.path] } ?? []
    guard let apps, !apps.isEmpty, urls.count == apps.count else { return bundleCollector(url) }
    let changed = Set(urls)
    return collectedBundles.filter { !changed.contains($0.fileURL) } + urls.compactMap(bundleReader)
  }

}
