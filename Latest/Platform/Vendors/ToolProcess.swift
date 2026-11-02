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

  /// The tool runs only after `beforeStart` (journaling its PID, say) succeeded: a tiny shell
  /// waits on a pipe for "go" and then execs the tool in the same process. If `beforeStart`
  /// throws, or Updater dies first, the pipe closes without "go" and the shell exits without
  /// ever running the tool, so nothing is left to kill.
  static func run(
    _ executable: URL, _ arguments: [String], log: URL, environment: [String: String] = [:],
    beforeStart: @escaping @Sendable (Int32) throws -> Void = { _ in }
  ) async throws -> Int32 {
    guard geteuid() != 0 else { throw RootRefused() }
    FileManager.default.createFile(atPath: log.path, contents: nil)
    var env = ProcessInfo.processInfo.environment
    env["SUDO_ASKPASS"] = nil
    env.merge(environment) { _, new in new }

    var gate: [Int32] = [0, 0]
    guard pipe(&gate) == 0 else { throw POSIXError(.EMFILE) }
    let (readEnd, writeEnd) = (gate[0], gate[1])
    // Neither end may leak into other children, or the shell would never see the pipe close.
    _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
    _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)
    var writeOpen = true
    defer {
      if writeOpen { close(writeEnd) }
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_APPEND, 0o644)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)
    posix_spawn_file_actions_adddup2(&actions, readEnd, 3)
    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

    let gateScript = #"IFS= read -r go <&3 && [ "$go" = go ] && exec "$0" "$@" 3<&-"#
    let argv =
      (["/bin/sh", "-c", gateScript, executable.path] + arguments).map { strdup($0) } + [nil]
    let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }
    var pid: pid_t = 0
    let spawned = posix_spawn(&pid, "/bin/sh", &actions, &attributes, argv, envp)
    close(readEnd)
    guard spawned == 0 else { throw POSIXError(POSIXErrorCode(rawValue: spawned) ?? .EIO) }
    do {
      try beforeStart(pid)
    } catch {
      close(writeEnd)
      writeOpen = false
      _ = reap(pid)
      throw error
    }
    let go = Array("go\n".utf8)
    _ = go.withUnsafeBufferPointer { write(writeEnd, $0.baseAddress, $0.count) }
    close(writeEnd)
    writeOpen = false
    // Never killed part way: wait for it, off the cooperative pool.
    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async { continuation.resume(returning: reap(pid)) }
    }
  }

  /// Exit code, or the signal number for a signalled child (as Process reports it).
  private static func reap(_ pid: pid_t) -> Int32 {
    var status: Int32 = 0
    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    let low = status & 0x7f
    return low == 0 ? (status >> 8) & 0xff : low
  }
}
