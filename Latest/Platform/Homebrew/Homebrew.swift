// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// An installed cask and the app bundles it put on disk.
struct InstalledCask: Sendable, Equatable {
  let token: String
  /// Canonical paths of the cask's `app` artifacts.
  let apps: [String]
  /// Package installers and system-level uninstall steps need sudo, which Updater does not
  /// provide in this round.
  let needsAdministrator: Bool
}

enum HomebrewError: LocalizedError, Equatable {
  case unavailable
  case failed(reason: String, logPath: String)
  case needsAdministrator(token: String)

  var errorDescription: String? {
    switch self {
    case .unavailable: "Homebrew was not found in /opt/homebrew or /usr/local."
    case .failed(let reason, _): reason
    case .needsAdministrator(let token):
      "This cask needs administrator rights. Run brew upgrade --cask \(token) in Terminal."
    }
  }
}

/// Runs the user's brew, never as root and never two invocations at once (detection
/// included), with auto-update and analytics off. Every run writes a log.
actor Homebrew {
  static let shared = Homebrew(brew: locate())

  let brew: URL?
  private let environment: [String: String]
  private let logDirectory: URL
  private let timeout: Duration
  /// The last scheduled invocation; each new one waits for it, across suspensions.
  private var tail: Task<Void, Never>?
  private var detection: (date: Date, installed: [InstalledCask], outdated: [String: String])?

  init(
    brew: URL?, environment: [String: String] = [:],
    logDirectory: URL = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Updater/logs"),
    timeout: Duration = .seconds(1_800)
  ) {
    self.brew = brew
    self.environment = environment
    self.logDirectory = logDirectory
    self.timeout = timeout
  }

  /// Fixed locations only; PATH is never consulted.
  static func locate(
    _ candidates: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
  ) -> URL? {
    candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  // MARK: - Detection

  /// The cask whose installed app artifact is exactly this bundle, if any.
  func owningCask(of app: URL, fresh: Bool = false) async throws -> InstalledCask? {
    let canonical = Self.canonical(app)
    return try await detect(fresh: fresh).installed.first { $0.apps.contains(canonical) }
  }

  /// The version brew would upgrade the cask to, or nil if it is current.
  func outdatedVersion(of token: String, fresh: Bool = false) async throws -> String? {
    try await detect(fresh: fresh).outdated[token]
  }

  func invalidate() { detection = nil }

  /// One scan serves a whole check pass; refreshes older than a minute run brew again.
  private func detect(fresh: Bool) async throws
    -> (date: Date, installed: [InstalledCask], outdated: [String: String])
  {
    if !fresh, let detection, Date().timeIntervalSince(detection.date) < 60 { return detection }
    let installed = try Self.parseInstalled(
      try await output(["info", "--cask", "--json=v2", "--installed"]))
    let outdated = try Self.parseOutdated(
      try await output(["outdated", "--cask", "--greedy", "--json=v2"]))
    let result = (Date(), installed, outdated)
    detection = result
    return result
  }

  static func parseInstalled(_ data: Data) throws -> [InstalledCask] {
    guard
      let casks = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["casks"]
        as? [[String: Any]]
    else { throw HomebrewError.unavailable }
    return casks.compactMap { cask in
      guard let token = cask["token"] as? String else { return nil }
      let artifacts = cask["artifacts"] as? [[String: Any]] ?? []
      let apps = artifacts.compactMap { artifact -> String? in
        guard artifact["app"] != nil, let target = artifact["target"] as? String else { return nil }
        return canonical(URL(fileURLWithPath: target))
      }
      let needsAdministrator = artifacts.contains { artifact in
        artifact["pkg"] != nil || artifact["installer"] != nil
          || ["pkgutil", "kext", "early_script"].contains {
            "\(artifact["uninstall"] ?? "")".contains($0)
          }
      }
      return InstalledCask(token: token, apps: apps, needsAdministrator: needsAdministrator)
    }
  }

  static func parseOutdated(_ data: Data) throws -> [String: String] {
    guard
      let casks = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["casks"]
        as? [[String: Any]]
    else { throw HomebrewError.unavailable }
    var versions = [String: String]()
    for cask in casks {
      if let name = cask["name"] as? String, let version = cask["current_version"] as? String {
        versions[name] = version
      }
    }
    return versions
  }

  static func canonical(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
  }

  // MARK: - Running brew

  /// `brew upgrade --cask <token>` with its output in a per-run log. Throws a plain reason
  /// and the log path on failure; a sudo prompt fails at once because stdin is closed.
  func upgrade(_ token: String) async throws -> URL {
    let log = try newLog(named: "brew-upgrade-\(token)")
    let (brew, env, timeout) = (try requireBrew(), processEnvironment, timeout)
    let status = try await serialized {
      try await Self.execute(
        brew, ["upgrade", "--cask", token], log: log, env: env, timeout: timeout)
    }
    detection = nil
    guard status == 0 else {
      let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
      if output.contains("sudo:") || output.contains("a password is required") {
        throw HomebrewError.needsAdministrator(token: token)
      }
      let lastLine = output.split(separator: "\n").last(where: { $0.contains("Error") })
      throw HomebrewError.failed(
        reason: "brew upgrade --cask \(token) failed"
          + (lastLine.map { ": \($0)" } ?? " (exit \(status))."),
        logPath: log.path)
    }
    return log
  }

  private func output(_ arguments: [String]) async throws -> Data {
    let log = try newLog(named: "brew-" + arguments.prefix(1).joined())
    let (brew, env) = (try requireBrew(), processEnvironment)
    let status = try await serialized {
      try await Self.execute(brew, arguments, log: log, env: env, timeout: .seconds(120))
    }
    let data = try Data(contentsOf: log)
    guard status == 0 else {
      throw HomebrewError.failed(reason: "brew \(arguments[0]) failed.", logPath: log.path)
    }
    try? FileManager.default.removeItem(at: log)  // detection output is not kept
    // brew prints warnings before the JSON on stderr; take the JSON object.
    guard let start = data.firstIndex(of: UInt8(ascii: "{")) else { return data }
    return data[start...]
  }

  private func requireBrew() throws -> URL {
    guard let brew else { throw HomebrewError.unavailable }
    return brew
  }

  /// Chains every invocation after the previous one, so two brew processes never overlap.
  private func serialized<T: Sendable>(_ body: @escaping @Sendable () async throws -> T)
    async throws -> T
  {
    let previous = tail
    let task = Task {
      await previous?.value
      return try await body()
    }
    tail = Task { _ = try? await task.value }
    return try await task.value
  }

  private func newLog(named name: String) throws -> URL {
    try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    return logDirectory.appendingPathComponent(
      "\(name)-\(stamp)-\(UUID().uuidString.prefix(8)).log")
  }

  private nonisolated var processEnvironment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["SUDO_ASKPASS"] = nil
    env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
    env["HOMEBREW_NO_ANALYTICS"] = "1"
    env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
    env["HOMEBREW_NO_ENV_HINTS"] = "1"
    env.merge(environment) { _, new in new }
    return env
  }

  private static func execute(
    _ brew: URL, _ arguments: [String], log: URL, env: [String: String], timeout: Duration
  ) async throws -> Int32 {
    // Homebrew refuses root, and Updater never escalates it.
    guard geteuid() != 0 else { throw HomebrewError.unavailable }
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    defer { try? handle.close() }
    let process = Process()
    process.executableURL = brew
    process.arguments = arguments
    process.environment = env
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = handle
    process.standardError = handle
    // A hung brew is asked to stop (SIGTERM, never SIGKILL); the clone covers what it left.
    let deadline = Task.detached {
      try? await Task.sleep(for: timeout)
      if process.isRunning { process.terminate() }
    }
    defer { deadline.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
  }
}
