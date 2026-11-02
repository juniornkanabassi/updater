// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// An installed cask and the app bundles it put on disk.
struct InstalledCask: Sendable, Equatable {
  let token: String
  /// Canonical paths of the cask's `app` artifacts.
  let apps: [String]
  /// Both the installed definition (what the upgrade uninstalls) and the current one (what
  /// it installs) passed the allow list. Anything else hands off.
  let allowListed: Bool
  /// Bundle IDs either definition's `uninstall quit:` names; brew quits them by ID.
  var quits: [String] = []
  /// Where the installed definition says its app is (what the upgrade removes); nil if it
  /// cannot be resolved.
  var installedApp: String?
}

/// Whether brew owns an app. A failed query is `unknown`, never "not owned": a catalogue
/// download must not replace an app brew may own.
enum CaskOwnership: Sendable, Equatable {
  case owned(InstalledCask)
  case notOwned
  case unknown
}

/// Formats Homebrew unpacks with macOS's own tools. Others (RAR, 7z, ...) make brew install
/// an unpacking tool on the fly, outside Updater's protection, so they hand off.
enum HomebrewPayload {
  static func unpacksWithBuiltInTools(_ file: URL) -> Bool {
    if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
      return file.pathExtension == "app"
    }
    guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 512)) ?? Data()
    func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
      head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
    }
    if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x1F, 0x8B]) || starts(Array("BZh".utf8))
      || starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) || starts(Array("ustar".utf8), at: 257)
    {
      return true  // zip, gzip, bzip2, xz, tar
    }
    // A disk image ends with a 512-byte "koly" trailer.
    guard let end = try? handle.seekToEnd(), end >= 512 else { return false }
    try? handle.seek(toOffset: end - 512)
    return (try? handle.read(upToCount: 4)) == Data("koly".utf8)
  }
}

/// What brew may do during an upgrade without Updater handing off: one `app` artifact, an
/// optional `zap` (only runs with --zap), and an optional `uninstall` whose only directive is
/// `quit:`. Any other artifact or directive (pkg, installer, script, launchctl, signal,
/// delete, rmdir, flight blocks, binaries...) or `version :latest` is refused.
enum HomebrewAllowList {
  /// nil if the artifacts are outside the allow list; otherwise the bundle IDs quit.
  static func quits(in artifacts: [[String: Any]]) -> [String]? {
    var apps = 0
    var quits = [String]()
    for artifact in artifacts {
      let keys = Set(artifact.keys)
      if keys == ["app"] || keys == ["app", "target"] {
        apps += 1
      } else if keys == ["zap"] {
        continue
      } else if keys == ["uninstall"], let steps = artifact["uninstall"] as? [[String: Any]] {
        for step in steps {
          guard Set(step.keys) == ["quit"] else { return nil }
          if let one = step["quit"] as? String {
            quits.append(one)
          } else if let many = step["quit"] as? [String] {
            quits += many
          } else {
            return nil
          }
        }
      } else {
        return nil
      }
    }
    return apps == 1 ? quits : nil
  }

  /// The installed definition brew uses to uninstall the old version: the install receipt's
  /// `uninstall_artifacts` (casks loaded from the API keep an empty caskfile), or else a
  /// stored JSON caskfile with artifacts. A Ruby caskfile cannot be read, so it is refused.
  static func installedArtifacts(caskroom: URL) -> [[String: Any]]? {
    let metadata = caskroom.appendingPathComponent(".metadata")
    if let data = try? Data(contentsOf: metadata.appendingPathComponent("INSTALL_RECEIPT.json")),
      let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      guard receipt["uninstall_flight_blocks"] as? Bool == false else { return nil }
      return receipt["uninstall_artifacts"] as? [[String: Any]]
    }
    let caskfiles =
      FileManager.default.enumerator(at: metadata, includingPropertiesForKeys: nil)?
      .compactMap { $0 as? URL }.filter {
        $0.deletingLastPathComponent().lastPathComponent == "Casks"
      }
      ?? []
    guard caskfiles.count == 1, let caskfile = caskfiles.first, caskfile.pathExtension == "json",
      let data = try? Data(contentsOf: caskfile),
      let cask = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return cask["artifacts"] as? [[String: Any]]
  }
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
  /// The last scheduled invocation; each new one waits for it, across suspensions.
  private var tail: Task<Void, Never>?
  private var detection: (date: Date, installed: [InstalledCask], outdated: [String: String])?

  init(
    brew: URL?, environment: [String: String] = [:],
    logDirectory: URL = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Updater/logs")
  ) {
    self.brew = brew
    self.environment = environment
    self.logDirectory = logDirectory
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

  /// No brew at its fixed locations means nothing can be owned; a query that fails is unknown.
  func ownership(of app: URL, fresh: Bool = false) async -> CaskOwnership {
    guard brew != nil else { return .notOwned }
    do {
      return try await owningCask(of: app, fresh: fresh).map(CaskOwnership.owned) ?? .notOwned
    } catch {
      return .unknown
    }
  }

  /// The version brew would upgrade the cask to, or nil if it is current.
  func outdatedVersion(of token: String, fresh: Bool = false) async throws -> String? {
    try await detect(fresh: fresh).outdated[token]
  }

  func invalidate() { detection = nil }

  /// `<prefix>/Caskroom/<token>`, brew's record of the installed cask version.
  func caskroom(of token: String) -> URL? {
    brew?.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Caskroom/\(token)")
  }

  /// One scan serves a whole check pass; refreshes older than a minute run brew again.
  private func detect(fresh: Bool) async throws
    -> (date: Date, installed: [InstalledCask], outdated: [String: String])
  {
    if !fresh, let detection, Date().timeIntervalSince(detection.date) < 60 { return detection }
    let installed = try Self.parseInstalled(
      try await output(["info", "--cask", "--json=v2", "--installed"]),
      caskroom: { [self] token in caskroom(of: token) })
    let outdated = try Self.parseOutdated(
      try await output(["outdated", "--cask", "--greedy", "--json=v2"]))
    let result = (Date(), installed, outdated)
    detection = result
    return result
  }

  /// The installed app's path: its `target:` if given, else the appdir brew used plus the
  /// source's base name (a source can be nested, like `Payload/Foo.app`). The appdir follows
  /// Homebrew's precedence in config.json: explicit, then environment, then default.
  static func installedTarget(of artifacts: [[String: Any]], caskroom: URL) -> String? {
    let specs = artifacts.compactMap { $0["app"] as? [Any] }
    guard specs.count == 1, let spec = specs.first, let name = spec.first as? String,
      let data = try? Data(contentsOf: caskroom.appendingPathComponent(".metadata/config.json")),
      let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let appdir = ["explicit", "env", "default"].lazy
      .compactMap { (config[$0] as? [String: Any])?["appdir"] as? String }.first
    guard let appdir else { return nil }
    let target =
      spec.dropFirst().compactMap { ($0 as? [String: Any])?["target"] as? String }.first
      ?? (name as NSString).lastPathComponent
    let expanded = (target as NSString).expandingTildeInPath
    let path =
      expanded.hasPrefix("/") ? expanded : (appdir as NSString).appendingPathComponent(expanded)
    return canonical(URL(fileURLWithPath: path))
  }

  /// `brew info --installed` gives the current definition (its `version` is the current
  /// one); the installed definition comes from each cask's Caskroom metadata. Dependencies
  /// (casks, formulae, extraction tools) and nested containers would be installed outside
  /// Updater's protection, so only macOS and architecture constraints are allowed.
  static func parseInstalled(_ data: Data, caskroom: (String) -> URL?) throws -> [InstalledCask] {
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
      let room = caskroom(token)
      let installed = room.flatMap(HomebrewAllowList.installedArtifacts)
      let current = HomebrewAllowList.quits(in: artifacts)
      let previous = installed.flatMap(HomebrewAllowList.quits)
      let latest =
        cask["version"] as? String == "latest" || cask["installed"] as? String == "latest"
      let dependencies = Set((cask["depends_on"] as? [String: Any] ?? [:]).keys)
      let selfContained =
        dependencies.isSubset(of: ["macos", "arch"])
        && (cask["container"] == nil || cask["container"] is NSNull)
      return InstalledCask(
        token: token, apps: apps,
        allowListed: current != nil && previous != nil && !latest && selfContained,
        quits: (current ?? []) + (previous ?? []),
        installedApp: installed.flatMap { artifacts in
          room.flatMap { installedTarget(of: artifacts, caskroom: $0) }
        })
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
  func upgrade(_ token: String, onStart: @escaping @Sendable (Int32) -> Void = { _ in })
    async throws
    -> URL
  {
    let log = try newLog(named: "brew-upgrade-\(token)")
    // --no-quit: Updater has already quit the exact app; brew must not quit others by ID.
    let status = try await run(
      ["upgrade", "--cask", "--no-quit", token], log: log, onStart: onStart)
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
    let status = try await run(arguments, log: log)
    let data = try Data(contentsOf: log)
    guard status == 0 else {
      throw HomebrewError.failed(reason: "brew \(arguments[0]) failed.", logPath: log.path)
    }
    try? FileManager.default.removeItem(at: log)  // detection output is not kept
    // brew prints warnings before the JSON on stderr; take the JSON object.
    guard let start = data.firstIndex(of: UInt8(ascii: "{")) else { return data }
    return data[start...]
  }

  /// Where `brew fetch` left the cask's download.
  func cachedDownload(of token: String) async throws -> URL {
    let data = try await output(["--cache", "--cask", token])
    guard
      let path = String(data: data, encoding: .utf8)?
        .split(separator: "\n").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
      path.hasPrefix("/")
    else { throw HomebrewError.unavailable }
    return URL(fileURLWithPath: path)
  }

  /// Downloads the update into brew's cache without touching the installed app, so the
  /// quit and the upgrade that follow are short.
  func fetch(_ token: String) async throws {
    let log = try newLog(named: "brew-fetch-\(token)")
    guard try await run(["fetch", "--cask", token], log: log) == 0 else {
      throw HomebrewError.failed(reason: "brew fetch --cask \(token) failed.", logPath: log.path)
    }
  }

  /// brew is never interrupted: the job waits for it to exit, holding its lock.
  private func run(
    _ arguments: [String], log: URL, onStart: @escaping @Sendable (Int32) -> Void = { _ in }
  ) async throws -> Int32 {
    let (brew, env) = (try requireBrew(), processEnvironment)
    return try await serialized {
      try await ToolProcess.run(brew, arguments, log: log, environment: env, onStart: onStart)
    }
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
    try ToolProcess.newLog(named: name, in: logDirectory)
  }

  private nonisolated var processEnvironment: [String: String] {
    [
      "HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1",
      "HOMEBREW_NO_INSTALL_CLEANUP": "1", "HOMEBREW_NO_ENV_HINTS": "1",
    ].merging(environment) { _, new in new }
  }
}
