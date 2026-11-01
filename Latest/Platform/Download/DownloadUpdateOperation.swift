import AppKit
import Foundation
import Synchronization

/// Shared download, cancellation and commit lifecycle for vendor installers.
class DownloadUpdateOperation: UpdateOperation, @unchecked Sendable {
  let app: App.Bundle
  private let work = Mutex<Task<Void, Never>?>(nil)

  init(app: App.Bundle) {
    self.app = app
    super.init(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
  }

  final override func execute() {
    super.execute()
    work.withLock { work in
      work = Task.detached { [self] in
        do {
          try Task.checkCancellation()
          try await performUpdate()
          finish()
        } catch  where error is CancellationError || (error as? URLError)?.code == .cancelled {
          cancel()
          finish()
        } catch {
          // A late cancellation must never hide an installation or rollback failure.
          finish(with: error)
        }
      }
      if isCancelled { work?.cancel() }
    }
  }

  final override func cancel() {
    super.cancel()
    guard isCancelled else { return }
    work.withLock { work in
      work?.cancel()
    }
  }

  func performUpdate() async throws { fatalError("Subclasses must implement performUpdate") }

  func download(from url: URL, into directory: URL, maximumSize: Int = 8 * 1_024 * 1_024 * 1_024)
    async throws -> URL
  {
    guard url.scheme == "https" else { throw AppDownloadError.invalidMetadata }
    progressState = .downloading(loadedSize: 0, totalSize: 0)
    let delegate = BoundedDownloadDelegate(maximumSize: maximumSize) { [weak self] loaded, total in
      self?.progressState = .downloading(loadedSize: loaded, totalSize: total)
    }
    let archive = directory.appendingPathComponent("download." + url.pathExtension.lowercased())
    let response: URLResponse
    do {
      response = try await delegate.download(from: url, to: archive)
    } catch {
      try? FileManager.default.removeItem(at: archive)
      if delegate.exceededLimit { throw AppDownloadError.invalidDownload }
      throw error
    }
    guard !delegate.exceededLimit,
      (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme == "https",
      (try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= maximumSize
    else { throw AppDownloadError.invalidDownload }
    try Task.checkCancellation()
    return archive
  }

  /// Quits the app through the shared lifecycle; tests inject a fake one.
  var lifecycle = AppLifecycle.live

  /// Reopen the surviving app after success, rollback, or cancellation after quitting.
  @MainActor
  func withApplicationClosed(_ install: @Sendable () async throws -> Void) async throws {
    try await lifecycle.withApplicationClosed(at: app.fileURL, name: app.name, install)
  }

  /// Same-volume renames. The original stays in `backupDirectory` until `verify` accepts
  /// the installed destination, and is restored on any failure.
  static func replaceItem(
    at target: URL, with candidate: URL, backupDirectory: URL,
    verify: (URL) throws -> Void = { _ in }
  ) throws {
    try ReplacementTransaction.perform(
      at: target, backupDirectory: backupDirectory,
      install: { try FileManager.default.moveItem(at: candidate, to: target) }, verify: verify)
  }

  static func removeStageUnlessRecoveryIsNeeded(_ stage: URL) {
    if !ReplacementTransaction.needsRecovery(stage) {
      try? FileManager.default.removeItem(at: stage)
    }
  }
}

/// Enforce the limit while receiving bytes, including responses without a
/// Content-Length. The final file-size check also covers a last callback race.
final class BoundedDownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
  private let maximumSize: Int64
  private let progress: @Sendable (Int64, Int64) -> Void
  var exceededLimit: Bool { transfer.withLock { $0.exceededLimit } }

  private struct Transfer {
    var task: URLSessionDownloadTask?
    var continuation: CheckedContinuation<URLResponse, Error>?
    var destination: URL?
    var cancelled = false
    var exceededLimit = false
  }
  private let transfer = Mutex(Transfer())

  init(maximumSize: Int, progress: @escaping @Sendable (Int64, Int64) -> Void) {
    self.maximumSize = Int64(maximumSize)
    self.progress = progress
  }

  /// Async download convenience APIs use a completion handler and omit the
  /// download delegate's progress callbacks. Own a delegate-driven task instead.
  func download(from url: URL, to destination: URL) async throws -> URLResponse {
    let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = session.downloadTask(with: url)
        let cancelled = transfer.withLock { transfer in
          transfer.task = task
          transfer.continuation = continuation
          transfer.destination = destination
          return transfer.cancelled
        }
        if cancelled { task.cancel() } else { task.resume() }
      }
    } onCancel: {
      let task = self.transfer.withLock { transfer in
        transfer.cancelled = true
        return transfer.task
      }
      task?.cancel()
    }
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
  ) {
    if totalBytesWritten > maximumSize || totalBytesExpectedToWrite > maximumSize {
      transfer.withLock { $0.exceededLimit = true }
      downloadTask.cancel()
      return
    }
    progress(totalBytesWritten, totalBytesExpectedToWrite)
  }

  func urlSession(
    _ session: URLSession, downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    do {
      guard let destination = transfer.withLock({ $0.destination }),
        let response = downloadTask.response
      else { throw AppDownloadError.invalidDownload }
      // Foundation deletes the temporary file when this callback returns.
      try FileManager.default.moveItem(at: location, to: destination)
      complete(.success(response))
    } catch { complete(.failure(error)) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { complete(.failure(error)) }
  }

  private func complete(_ result: Result<URLResponse, Error>) {
    let continuation = transfer.withLock { transfer in
      let continuation = transfer.continuation
      transfer.continuation = nil
      transfer.task = nil
      transfer.destination = nil
      return continuation
    }
    continuation?.resume(with: result)
  }
}
