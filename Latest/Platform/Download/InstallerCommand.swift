import Foundation
import Synchronization

/// Fixed system tools and argument arrays, with file-backed output and bounded execution.
enum InstallerCommand {
  static func run(
    _ executable: String, _ arguments: [String], cancellable: Bool = true,
    timeout: Duration = .seconds(300)
  ) async throws -> String {
    if cancellable { try Task.checkCancellation() }
    let process = Process()
    let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath: output.path, contents: nil)
    let handle = try FileHandle(forWritingTo: output)
    defer {
      try? handle.close()
      try? FileManager.default.removeItem(at: output)
    }
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle

    let timedOut = Mutex(false)
    let deadline = Task.detached {
      do { try await Task.sleep(for: timeout) } catch { return }
      timedOut.withLock { $0 = true }
      terminate(process)
    }
    defer { deadline.cancel() }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
          try process.run()
          if (cancellable && Task.isCancelled) || timedOut.withLock({ $0 }) {
            terminate(process)
          }
        } catch {
          process.terminationHandler = nil
          continuation.resume(throwing: error)
        }
      }
    } onCancel: {
      if cancellable { terminate(process) }
    }
    if cancellable { try Task.checkCancellation() }
    guard !timedOut.withLock({ $0 }) else {
      throw AppDownloadError.toolFailed("The system installer tool timed out.")
    }
    let reader = try FileHandle(forReadingFrom: output)
    defer { try? reader.close() }
    let data = try reader.read(upToCount: 8 * 1_024 * 1_024) ?? Data()
    guard (try reader.read(upToCount: 1))?.isEmpty != false else {
      throw AppDownloadError.invalidDownload
    }
    guard process.terminationStatus == 0 else {
      throw AppDownloadError.toolFailed(String(decoding: data.suffix(2_048), as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
  }

  private static func terminate(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }
}
