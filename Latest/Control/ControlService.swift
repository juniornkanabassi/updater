// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Answers the control socket. Every action goes through the same services as the window
/// (`AppUpdating`, Update All's eligibility, the scheduler's dedup, locks and history), so the GUI
/// shows automation-started jobs live and there is no second update path.
@MainActor
final class ControlService {
  struct Dependencies {
    var apps: @MainActor () -> [App]
    var isChecking: @MainActor () -> Bool
    var startCheck: @MainActor (_ refresh: Bool) -> Void
    var updateAllCandidates: @MainActor () -> [App]
    var updateAll: @MainActor () -> Void
    var updating: any AppUpdating
    var history: UpdateHistoryStore?
  }

  private struct Job {
    let id: String
    let app: App
    let caller: String
    let started: Date
    var result: [String: JSONValue]?
  }

  private let dependencies: Dependencies
  private var jobs = [String: Job]()
  private var jobOrder = [String]()
  private var observations = [String: Task<Void, Never>]()

  init(_ dependencies: Dependencies) { self.dependencies = dependencies }

  func handle(_ request: ControlRequest) async -> ControlResponse {
    switch request.command {
    case "list": await list(updatesOnly: Self.flag(request.args["updates"]))
    case "check": await check(request.args)
    case "update": update(request.args, caller: request.caller)
    case "status": status(jobID: request.args["job"])
    case "history": history(limit: Int(request.args["limit"] ?? "") ?? 20)
    default:
      .failure("unknown_command", "Unknown command \(request.command). Run `updater --help`.")
    }
  }

  // MARK: Commands

  private func list(updatesOnly: Bool) async -> ControlResponse {
    // Just after a headless launch the first scan is still finding apps.
    let deadline = Date().addingTimeInterval(30)
    while dependencies.apps().isEmpty, dependencies.isChecking(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(250))
    }
    let apps = dependencies.apps()
      .filter { !updatesOnly || (($0.updateAvailable || $0.availabilityUnknown) && !$0.isIgnored) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return ControlResponse(
      ok: true, data: ["apps": .array(apps.map(describe)), "count": JSONValue(apps.count)])
  }

  private func check(_ args: [String: String]) async -> ControlResponse {
    let joined = dependencies.isChecking()
    if !joined { dependencies.startCheck(Self.flag(args["refresh"])) }
    let timeout = min(max(Double(args["wait"] ?? "") ?? 120, 0), 600)
    let deadline = Date().addingTimeInterval(timeout)
    while dependencies.isChecking(), Date() < deadline {
      try? await Task.sleep(for: .milliseconds(250))
    }
    let finished = !dependencies.isChecking()
    let waiting = dependencies.apps().filter { $0.updateAvailable && !$0.isIgnored }.count
    return ControlResponse(
      ok: true,
      message: finished
        ? "Check finished: \(waiting) update\(waiting == 1 ? "" : "s") available."
        : "The check is still running; run `updater status` later.",
      data: [
        "finished": .bool(finished), "joined": .bool(joined),
        "updatesAvailable": JSONValue(waiting),
      ])
  }

  private func update(_ args: [String: String], caller: String) -> ControlResponse {
    guard let target = args["target"], !target.isEmpty else {
      return .failure("usage", "Name an app by bundle id or path, or use all.")
    }
    let allowHandOff = Self.flag(args["allow-handoff"])
    let apps = dependencies.apps()
    if target == "all" { return updateAll(apps, caller: caller) }
    let matches =
      target.hasPrefix("/")
      ? apps.filter {
        $0.fileURL.standardizedFileURL.path == URL(fileURLWithPath: target).standardizedFileURL.path
      }
      : apps.filter { $0.bundleIdentifier == target }
    guard let app = matches.first else {
      return .failure(
        "not_found", "No app at \(target) or with that bundle id. Run `updater list`.")
    }
    guard matches.count == 1 else {
      // Identity is the file URL: two copies of one bundle id are two different targets.
      return ControlResponse(
        ok: false, code: "ambiguous",
        message: "\(matches.count) copies have bundle id \(target); name one by path.",
        data: ["paths": .array(matches.map { .string($0.fileURL.path) })])
    }
    let result = start(app, allowHandOff: allowHandOff, caller: caller)
    return ControlResponse(ok: true, data: ["results": .array([.object(result)])])
  }

  private func updateAll(_ apps: [App], caller: String) -> ControlResponse {
    var results = [JSONValue]()
    for app in apps where app.updateAvailable && !app.isIgnored {
      if let id = dependencies.updating.jobID(for: app.identifier) {
        results.append(
          .object(entry(app, "inProgress", ["jobId": .string(id), "state": state(of: app)])))
      }
    }
    let candidates = dependencies.updateAllCandidates()
    let started = Date()
    dependencies.updateAll()
    for app in candidates {
      guard let id = dependencies.updating.jobID(for: app.identifier) else {
        results.append(
          .object(
            entry(
              app, "notQueued",
              [
                "message":
                  "Not started. App Store updates may need the update helper; open Updater."
              ])))
        continue
      }
      track(id, app: app, caller: caller, started: started)
      results.append(
        .object(entry(app, "started", ["jobId": .string(id), "state": state(of: app)])))
    }
    // Update All never hands off; the caller tells the user where these update instead.
    let handOffs = apps.filter {
      $0.updateAvailable && !$0.isIgnored && $0.capability == .handOff
    }
    results += handOffs.map { .object(entry($0, "handOff", ["label": .string(Self.label($0))])) }
    return ControlResponse(ok: true, data: ["results": .array(results)])
  }

  private func start(_ app: App, allowHandOff: Bool, caller: String) -> [String: JSONValue] {
    let updating = dependencies.updating
    if let id = updating.jobID(for: app.identifier) {
      return entry(app, "inProgress", ["jobId": .string(id), "state": state(of: app)])
    }
    guard app.isActionable else { return entry(app, "upToDate", [:]) }
    switch app.capability {
    case .unsupported: return entry(app, "unsupported", [:])
    case .handOff where !allowHandOff:
      // Opening the App Store, Terminal or Creative Cloud is for a person to choose.
      return entry(
        app, "handOff",
        [
          "label": .string(Self.label(app)),
          "message": "Updates through \(Self.label(app)). Pass --allow-handoff to open it.",
        ])
    case .handOff, .install, .vendorTool: break
    }
    let started = Date()
    updating.update(app)
    guard let id = updating.jobID(for: app.identifier) else {
      return app.capability == .handOff
        ? entry(app, "handedOff", ["label": .string(Self.label(app))])
        : entry(app, "notQueued", ["message": "Updater could not start this update; open Updater."])
    }
    track(id, app: app, caller: caller, started: started)
    return entry(app, "started", ["jobId": .string(id), "state": state(of: app)])
  }

  private func status(jobID: String?) -> ControlResponse {
    guard let jobID, !jobID.isEmpty else {
      let waiting = dependencies.apps().filter { $0.updateAvailable && !$0.isIgnored }.count
      return ControlResponse(
        ok: true,
        data: [
          "checking": .bool(dependencies.isChecking()), "updatesAvailable": JSONValue(waiting),
          "jobs": .array(jobOrder.suffix(20).reversed().compactMap { describeJob($0) }),
        ])
    }
    guard let job = describeJob(jobID) else {
      return .failure("not_found", "No job \(jobID) since Updater started.")
    }
    return ControlResponse(ok: true, data: ["job": job])
  }

  private func history(limit: Int) -> ControlResponse {
    let entries = dependencies.history?.entries(limit: min(max(limit, 1), 500)) ?? []
    let formatter = ISO8601DateFormatter()
    return ControlResponse(
      ok: true,
      data: [
        "entries": .array(
          entries.map { entry in
            .object(
              Self.compact(
                [
                  "date": .string(formatter.string(from: entry.date)),
                  "name": .string(
                    URL(fileURLWithPath: entry.appPath).deletingPathExtension().lastPathComponent),
                  "path": .string(entry.appPath), "bundleId": .string(entry.bundleIdentifier),
                ].merging(Self.outcome(entry.outcome)) { $1 }))
          })
      ])
  }

  // MARK: Jobs

  /// Follows the job's state feed until it ends, then keeps its result for `status`.
  private func track(_ id: String, app: App, caller: String, started: Date) {
    guard jobs[id] == nil else { return }
    jobs[id] = Job(id: id, app: app, caller: caller, started: started)
    jobOrder.append(id)
    if jobOrder.count > 200 { jobs[jobOrder.removeFirst()] = nil }
    let feed = dependencies.updating.states(for: app.identifier)
    observations[id] = Task { [weak self] in
      for await state in feed {
        guard let self else { return }
        if case .error = state {
          self.settle(id, error: state)
          break
        }
        if case .none = state, self.dependencies.updating.jobID(for: app.identifier) != id {
          self.settle(id, error: nil)
          break
        }
      }
      self?.observations[id] = nil
    }
  }

  /// The recorded outcome decides; with none recorded nothing changed, which for a declined
  /// or timed-out quit prompt (and a cancel) is reported as needsQuit.
  private func settle(_ id: String, error: UpdateProgressState?) {
    guard var job = jobs[id], job.result == nil else { return }
    if let entry = dependencies.history?.latestEntry(for: job.app.identifier),
      entry.date >= job.started
    {
      job.result = Self.outcome(entry.outcome)
    } else if case .error(let failure) = error {
      job.result = ["state": "failed", "message": .string(failure.localizedDescription)]
    } else {
      job.result = [
        "state": "needsQuit",
        "message":
          "Nothing changed: the quit prompt was declined or timed out, or the update was cancelled.",
      ]
    }
    jobs[id] = job
  }

  private func describeJob(_ id: String) -> JSONValue? {
    guard let job = jobs[id] else { return nil }
    let live: [String: JSONValue] =
      dependencies.updating.jobID(for: job.app.identifier) == id
      ? ["state": state(of: job.app)] : ["state": "finished"]
    return .object(
      Self.compact(
        entry(job.app, nil, ["jobId": .string(id), "caller": .string(job.caller)])
          .merging(job.result ?? live) { $1 }))
  }

  // MARK: Formatting

  private func describe(_ app: App) -> JSONValue {
    .object(
      Self.compact([
        "name": .string(app.name), "bundleId": .string(app.bundleIdentifier),
        "path": .string(app.fileURL.path), "installed": JSONValue(Self.version(app.version)),
        "available": JSONValue(app.remoteVersion.flatMap(Self.version)),
        "updateAvailable": .bool(app.updateAvailable),
        "capability": .string(app.capability.rawValue),
        "handOffLabel": JSONValue(app.capability == .handOff ? Self.label(app) : nil),
        "ignored": app.isIgnored ? .bool(true) : .null,
        "source": .string(app.bundle.source.rawValue),
        "jobId": JSONValue(dependencies.updating.jobID(for: app.identifier)),
      ]))
  }

  private func entry(_ app: App, _ status: String?, _ extra: [String: JSONValue])
    -> [String: JSONValue]
  {
    Self.compact(
      ["name": .string(app.name), "path": .string(app.fileURL.path), "status": JSONValue(status)]
        .merging(extra) { $1 })
  }

  private func state(of app: App) -> JSONValue {
    switch dependencies.updating.state(for: app.identifier) {
    case .none: "idle"
    case .pending: "waiting"
    case .initializing, .downloading, .extracting, .installing, .waitingForVendor: "running"
    case .waitingForQuit: "waitingForQuit"
    case .cancelling: "cancelling"
    case .error: "failed"
    }
  }

  private static func outcome(_ outcome: UpdateOutcome) -> [String: JSONValue] {
    switch outcome {
    case .updated(let from, let to): ["state": "updated", "from": .string(from), "to": .string(to)]
    case .noChange(let reason): ["state": "noChange", "message": JSONValue(reason)]
    case .needsPermission(let kind):
      [
        "state": "needsPermission", "permission": .string(kind),
        "message": JSONValue(UpdateOutcomeError(outcome: outcome)?.errorDescription),
      ]
    case .needsQuit:
      [
        "state": "needsQuit",
        "message": JSONValue(UpdateOutcomeError(outcome: outcome)?.errorDescription),
      ]
    case .failed(let reason, let logPath):
      ["state": "failed", "message": .string(reason), "log": JSONValue(logPath)]
    case .handedOff: ["state": "handedOff"]
    }
  }

  private static func label(_ app: App) -> String {
    if app.relaunchesToUpdate { return "a relaunch of \(app.name)" }
    return app.externalUpdaterName ?? "the vendor's updater"
  }

  private static func version(_ version: Version) -> String? {
    version.versionNumber ?? version.buildNumber
  }

  private static func compact(_ object: [String: JSONValue]) -> [String: JSONValue] {
    object.filter { $0.value != .null }
  }

  static func flag(_ value: String?) -> Bool { ["1", "true", "yes"].contains(value?.lowercased()) }
}
