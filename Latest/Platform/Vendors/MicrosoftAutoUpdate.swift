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

  let tool: URL
  private let logDirectory: URL
  private var scan: (date: Date, registered: [String: String], updates: [String: String])?

  init(tool: URL, logDirectory: URL = ToolProcess.defaultLogDirectory) {
    self.tool = tool
    self.logDirectory = logDirectory
  }

  var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: tool.path) }

  /// The MAU app ID registered for exactly this bundle path.
  func appID(for app: URL, fresh: Bool = false) async -> String? {
    guard isInstalled, let scan = try? await detect(fresh: fresh) else { return nil }
    return scan.registered[Homebrew.canonical(app)]
  }

  /// The version MAU would install for this app ID, if any.
  func availableVersion(of appID: String) async -> String? {
    (try? await detect(fresh: false))?.updates[appID]
  }

  func invalidate() { scan = nil }

  private func detect(fresh: Bool) async throws
    -> (date: Date, registered: [String: String], updates: [String: String])
  {
    if !fresh, let scan, Date().timeIntervalSince(scan.date) < 60 { return scan }
    let registered = Self.parseRegistered(try await plist(["--config", "--format", "plist"]))
    let updates = Self.parseUpdates(try await plist(["--list", "--format", "plist"]))
    let result = (Date(), registered, updates)
    scan = result
    return result
  }

  /// `RegisteredApplications`: app path → { "Application ID": ... }.
  static func parseRegistered(_ value: Any?) -> [String: String] {
    let apps = (value as? [String: Any])?["RegisteredApplications"] as? [String: Any] ?? [:]
    var registered = [String: String]()
    for (path, entry) in apps {
      if let identifier = (entry as? [String: Any])?["Application ID"] as? String {
        registered[Homebrew.canonical(URL(fileURLWithPath: path))] = identifier
      }
    }
    return registered
  }

  /// An array of updates, each with "Application ID" and "Update Version". With nothing to
  /// install MAU prints "No updates available" and no plist at all.
  static func parseUpdates(_ value: Any?) -> [String: String] {
    var updates = [String: String]()
    for entry in value as? [[String: Any]] ?? [] {
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

  private func plist(_ arguments: [String]) async throws -> Any? {
    let log = try ToolProcess.newLog(named: "msupdate-query", in: logDirectory)
    defer { try? FileManager.default.removeItem(at: log) }
    _ = try await ToolProcess.run(tool, arguments, log: log)
    return Self.plistValue(in: try Data(contentsOf: log))
  }

  /// `msupdate --install --apps <ID>`, waiting for MAU to finish. MAU reports its assistant's
  /// state as it goes; anything but a final "Idle" means it may still be installing.
  func install(_ appID: String) async throws {
    let log = try ToolProcess.newLog(named: "msupdate-install-\(appID)", in: logDirectory)
    let status = try await ToolProcess.run(
      tool, ["--install", "--apps", appID, "--wait", "3600"], log: log)
    scan = nil
    let output = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    guard status == 0 else {
      throw VendorToolError.failed(
        reason: "msupdate could not install the \(appID) update (exit \(status)).",
        logPath: log.path)
    }
    let lastState = output.components(separatedBy: "Update Assistant:").last?
      .split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
    guard lastState == "Idle" else { throw VendorToolError.stillWorking(logPath: log.path) }
  }
}
