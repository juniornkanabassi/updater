// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Runs an updater command as the user (never root), stdin closed so nothing can prompt,
/// all output in a per-run log. It is never killed part way: callers wait for it to exit.
enum ToolProcess {
  static let defaultLogDirectory = FileManager.default.urls(
    for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Updater/logs")

  struct RootRefused: Error {}

  static func newLog(named name: String, in directory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    return directory.appendingPathComponent("\(name)-\(stamp)-\(UUID().uuidString.prefix(8)).log")
  }

  static func run(
    _ executable: URL, _ arguments: [String], log: URL, environment: [String: String] = [:],
    onStart: @escaping @Sendable (Int32) -> Void = { _ in }
  ) async throws -> Int32 {
    guard geteuid() != 0 else { throw RootRefused() }
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    var env = ProcessInfo.processInfo.environment
    env["SUDO_ASKPASS"] = nil
    env.merge(environment) { _, new in new }
    process.environment = env
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do {
        try process.run()
        onStart(process.processIdentifier)
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}
