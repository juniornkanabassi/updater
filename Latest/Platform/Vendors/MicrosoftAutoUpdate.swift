// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Microsoft AutoUpdate's command-line tool. MAU itself says which apps it manages
/// (`--config`: path → app ID) and what it would install (`--list`), so no app IDs are guessed.
/// App Store copies of Office are not registered with MAU and keep the App Store route.
actor MicrosoftAutoUpdate {
  static let shared = MicrosoftAutoUpdate(
    tool: URL(
      fileURLWithPath:
        "/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"
    ))

  struct Scan: Sendable {
    let registered: [String: String]
    let updates: [String: String]
  }

  struct Unreadable: LocalizedError {
    var errorDescription: String? { "Microsoft AutoUpdate could not be read." }
  }

  let tool: URL
  private let logDirectory: URL
  private let queryTimeout: Duration
  private var scan: (date: Date, value: Scan)?
  /// One query at a time is shared by every caller. Invalidating bumps the generation, so a
  /// lookup that started earlier can never refill the cache.
  private var inFlight: (generation: Int, task: Task<Scan, Error>)?
  private var generation = 0

  init(
    tool: URL, logDirectory: URL = ToolProcess.defaultLogDirectory,
    queryTimeout: Duration = .seconds(30)
  ) {
    self.tool = tool
    self.logDirectory = logDirectory
    self.queryTimeout = queryTimeout
  }

  var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: tool.path) }

  enum Registration: Equatable, Sendable {
    /// The ID maps back to this path alone, so `--install --apps <ID>` targets this copy.
    case unique(String)
    /// Another registered path shares the ID; MAU's install has no path to choose with.
    case ambiguous(String)

    var identifier: String {
      switch self {
      case .unique(let identifier), .ambiguous(let identifier): identifier
      }
    }
  }

  /// How MAU registers exactly this bundle path; nil if it doesn't manage it. Throws when MAU
  /// cannot be read, which is not the same as "no update".
  func registration(for app: URL, fresh: Bool = false) async throws -> Registration? {
    guard isInstalled else { return nil }
    let registered = try await detect(fresh: fresh).registered
    guard let identifier = registered[Homebrew.canonical(app)] else { return nil }
    return registered.values.filter { $0 == identifier }.count == 1
      ? .unique(identifier) : .ambiguous(identifier)
  }

  /// The app ID, only when it maps back to this path alone.
  func appID(for app: URL, fresh: Bool = false) async throws -> String? {
    if case .unique(let identifier)? = try await registration(for: app, fresh: fresh) {
      return identifier
    }
    return nil
  }

  /// The version MAU would install for this app ID, or nil when it has none.
  func availableVersion(of appID: String) async throws -> String? {
    try await detect(fresh: false).updates[appID]
  }

  func invalidate() {
    generation += 1
    scan = nil
    inFlight = nil
  }

  private func detect(fresh: Bool) async throws -> Scan {
    if !fresh, let scan, Date().timeIntervalSince(scan.date) < 60 { return scan.value }
    if let inFlight, inFlight.generation == generation { return try await inFlight.task.value }
    let started = generation
    let task = Task { [tool, queryTimeout] in try await Self.query(tool, timeout: queryTimeout) }
    inFlight = (started, task)
    defer { if inFlight?.generation == started { inFlight = nil } }
    // Failures are not cached; the next check asks MAU again.
    let value = try await task.value
    if generation == started { scan = (Date(), value) }
    return value
  }

  /// Read-only queries have a deadline; installs never do.
  private static func query(_ tool: URL, timeout: Duration) async throws -> Scan {
    let config = try await InstallerCommand.run(
      tool.path, ["--config", "--format", "plist"], timeout: timeout)
    let list = try await InstallerCommand.run(
      tool.path, ["--list", "--format", "plist"], timeout: timeout)
    guard let registered = parseRegistered(plistValue(in: Data(config.utf8))),
      let updates = parseList(list)
    else { throw Unreadable() }
    return Scan(registered: registered, updates: updates)
  }

  /// `RegisteredApplications`: app path → { "Application ID": ... }; nil if absent.
  static func parseRegistered(_ value: Any?) -> [String: String]? {
    guard let apps = (value as? [String: Any])?["RegisteredApplications"] as? [String: Any]
    else { return nil }
    var registered = [String: String]()
    for (path, entry) in apps {
      if let identifier = (entry as? [String: Any])?["Application ID"] as? String {
        registered[Homebrew.canonical(URL(fileURLWithPath: path))] = identifier
      }
    }
    return registered
  }

  /// "No updates available" is a real answer; otherwise an array of updates with
  /// "Application ID" and "Update Version". Anything else is unreadable (nil).
  static func parseList(_ output: String) -> [String: String]? {
    if output.contains("No updates available") { return [:] }
    guard let entries = plistValue(in: Data(output.utf8)) as? [[String: Any]] else { return nil }
    var updates = [String: String]()
    for entry in entries {
      if let identifier = entry["Application ID"] as? String,
        let version = entry["Update Version"] as? String
      {
        updates[identifier] = version
      }
    }
    return updates
  }

  /// MAU prints progress lines before any plist; parse from `<?xml` on, nil if there is none.
  static func plistValue(in output: Data) -> Any? {
    guard let start = output.range(of: Data("<?xml".utf8))?.lowerBound else { return nil }
    return try? PropertyListSerialization.propertyList(from: output[start...], format: nil)
  }

  /// The last "Update Assistant: <state>" MAU printed.
  static func assistantState(in output: String) -> String? {
    guard output.contains("Update Assistant:") else { return nil }
    return output.components(separatedBy: "Update Assistant:").last?
      .split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
  }

  /// Whether MAU's assistant reports Idle right now. An unreadable answer counts as busy:
  /// a job waiting on MAU never restores while MAU might still be writing.
  func assistantIsIdle() async -> Bool {
    guard
      let output = try? await InstallerCommand.run(
        tool.path, ["--list"], timeout: queryTimeout)
    else { return false }
    return Self.assistantState(in: output) == "Idle"
  }

  /// `msupdate --install --apps <ID>`, waiting for MAU. Exit 0 with a final "Idle" is done;
  /// anything else is handed back for the job to wait on MAU before judging the result.
  func install(_ appID: String) async throws {
    let log = try ToolProcess.newLog(named: "msupdate-install-\(appID)", in: logDirectory)
    let status = try await ToolProcess.run(
      tool, ["--install", "--apps", appID, "--wait", "3600"], log: log)
    invalidate()
    let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    guard status == 0 else {
      throw VendorToolError.failed(
        reason: "msupdate could not install the \(appID) update (exit \(status)).",
        logPath: log.path)
    }
    guard Self.assistantState(in: output) == "Idle" else {
      throw VendorToolError.stillWorking(logPath: log.path)
    }
  }
}
