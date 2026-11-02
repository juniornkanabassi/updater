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
    /// The first discovery and the first full check since launch have both finished.
    var initialCheckFinished: @MainActor () -> Bool
    var startCheck: @MainActor (_ refresh: Bool) -> Void
    var updateAllCandidates: @MainActor () -> [App]
    var updateAll: @MainActor () -> Void
    var updating: any AppUpdating
    var history: UpdateHistoryStore?
    /// How long a command waits for readiness before answering not_ready.
    var readinessWait: Duration = .seconds(20)
  }

  private let dependencies: Dependencies
  /// Who started the jobs started here; the scheduler knows every job, this only adds a name.
  private var callers = [String: String]()
  private var startedHere = [String]()

  init(_ dependencies: Dependencies) { self.dependencies = dependencies }

  func handle(_ request: ControlRequest) async -> ControlResponse {
    let args = request.args
    switch request.command {
    case "list":
      let updatesOnly = Self.flag(args["updates"])
      // Versions are only known once the first check has run; names after discovery.
      if let notReady = await ready(needsCheck: updatesOnly) { return notReady }
      return list(updatesOnly: updatesOnly)
    case "check": return await check(args)
    case "update":
      if let notReady = await ready(needsCheck: true) { return notReady }
      return update(args, caller: request.caller)
    case "status": return status(jobID: args["job"])
    case "history": return history(limit: Int(args["limit"] ?? "") ?? 20)
    default:
      return .failure(
        "unknown_command", "Unknown command \(request.command). Run `updater --help`.")
    }
  }

  // MARK: Readiness

  /// Waits (bounded) for discovery, and for the first check when versions matter. A cold
  /// start from the CLI answers not_ready instead of an empty or stale list.
  private func ready(needsCheck: Bool) async -> ControlResponse? {
    func isReady() -> Bool {
      needsCheck
        ? dependencies.initialCheckFinished()
        : !dependencies.apps().isEmpty || dependencies.initialCheckFinished()
    }
    let deadline = ContinuousClock.now + dependencies.readinessWait
    while !isReady(), ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard !isReady() else { return nil }
    return ControlResponse(
      ok: false, code: "not_ready",
      message: "Updater is still running its first check since launch. Retry in a few seconds.",
      data: ["retryable": .bool(true)])
  }

  // MARK: Commands

  private func list(updatesOnly: Bool) -> ControlResponse {
    let apps = dependencies.apps()
      .filter { !updatesOnly || (($0.updateAvailable || $0.availabilityUnknown) && !$0.isIgnored) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    var data: [String: JSONValue] = [
      "apps": .array(apps.map(describe)), "count": JSONValue(apps.count),
    ]
    // A check in progress means some versions may still change.
    if dependencies.isChecking() { data["checking"] = .bool(true) }
    return ControlResponse(ok: true, data: data)
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
    let result = start(app, allowHandOff: Self.flag(args["allow-handoff"]), caller: caller)
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
    // Update All never hands off, not even from inside a job (an App Store gate fallback).
    ExternalHandOff.$allowed.withValue(false) { dependencies.updateAll() }
    for app in candidates {
      guard let id = dependencies.updating.jobID(for: app.identifier) else {
        results.append(.object(notStarted(app)))
        continue
      }
      remember(id, caller: caller)
      results.append(
        .object(entry(app, "started", ["jobId": .string(id), "state": state(of: app)])))
    }
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
      return handOffEntry(app)
    case .handOff, .install, .vendorTool: break
    }
    // The policy travels with the job, so a fallback inside it opens nothing either.
    ExternalHandOff.$allowed.withValue(allowHandOff) { updating.update(app) }
    guard let id = updating.jobID(for: app.identifier) else {
      if app.capability == .handOff, allowHandOff {
        return entry(app, "handedOff", ["label": .string(Self.label(app))])
      }
      return notStarted(app)
    }
    remember(id, caller: caller)
    return entry(app, "started", ["jobId": .string(id), "state": state(of: app)])
  }

  /// Nothing was queued. If the route turned into a hand-off meanwhile (the App Store's
  /// manual preference) say so; otherwise the window has the reason.
  private func notStarted(_ app: App) -> [String: JSONValue] {
    if app.capability == .handOff { return handOffEntry(app) }
    return entry(
      app, "notQueued",
      ["message": "Not started. App Store updates may need the update helper; open Updater."])
  }

  private func handOffEntry(_ app: App) -> [String: JSONValue] {
    entry(
      app, "handOff",
      [
        "label": .string(Self.label(app)),
        "message": "Updates through \(Self.label(app)). Pass --allow-handoff to open it.",
      ])
  }

  private func status(jobID: String?) -> ControlResponse {
    guard let jobID, !jobID.isEmpty else {
      let waiting = dependencies.apps().filter { $0.updateAvailable && !$0.isIgnored }.count
      let active = dependencies.apps().compactMap {
        dependencies.updating.jobID(for: $0.identifier)
      }
      let recent = startedHere.suffix(20).reversed().filter { !active.contains($0) }
      return ControlResponse(
        ok: true,
        data: [
          "checking": .bool(dependencies.isChecking()), "updatesAvailable": JSONValue(waiting),
          "jobs": .array((active + recent).compactMap(describeJob)),
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
                ].merging(Self.outcome(entry.outcome, label: nil)) { $1 }))
          })
      ])
  }

  // MARK: Jobs

  private func remember(_ id: String, caller: String) {
    callers[id] = caller
    startedHere.append(id)
    if startedHere.count > 200 { callers[startedHere.removeFirst()] = nil }
  }

  /// Any job id the scheduler handed out, including the window's own jobs.
  private func describeJob(_ id: String) -> JSONValue? {
    guard let job = dependencies.updating.job(withID: id) else { return nil }
    let app = dependencies.apps().first { $0.identifier == job.appURL }
    var object: [String: JSONValue] = [
      "jobId": .string(id), "path": .string(job.appURL.path),
      "name": .string(app?.name ?? job.appURL.deletingPathExtension().lastPathComponent),
      "caller": JSONValue(callers[id]),
    ]
    if let state = job.state {
      object["state"] = Self.state(state)
    } else if let record = job.record {
      object.merge(Self.result(record, label: app.map(Self.label))) { $1 }
    }
    return .object(Self.compact(object))
  }

  /// A recorded outcome decides. Without one nothing changed: a declined or unanswered quit
  /// prompt is needsQuit, a cancel is cancelled.
  private static func result(_ record: UpdateJobRecord, label: String?) -> [String: JSONValue] {
    // handedOff means something was actually opened; otherwise the caller gets where to go
    // and why, and --allow-handoff only when it would open that place.
    if record.outcome == .handedOff, let note = record.handOff {
      guard !note.opened else {
        return ["state": "handedOff", "label": .string(note.destination)]
      }
      return [
        "state": "handOff", "label": .string(note.destination), "reason": .string(note.reason),
        "message": .string(
          note.blockedByPolicy
            ? "Not opened: \(note.reason) Retry with --allow-handoff to open \(note.destination)."
            : "\(note.reason) Update it with \(note.destination)."),
      ]
    }
    if let outcome = record.outcome { return Self.outcome(outcome, label: label) }
    if record.quitDeclined {
      return [
        "state": "needsQuit",
        "message": "Nothing changed: the quit prompt was declined or not answered in time.",
      ]
    }
    if record.cancelled {
      return ["state": "cancelled", "message": "The update was cancelled; nothing changed."]
    }
    if let failure = record.failure { return ["state": "failed", "message": .string(failure)] }
    return ["state": "finished", "message": "The job ended without a recorded outcome."]
  }

  // MARK: Formatting

  private func describe(_ app: App) -> JSONValue {
    // Adobe-style apps: Updater cannot see the available version, so it is not invented.
    let (availability, availabilityNote) = Self.availability(
      of: app, checking: dependencies.isChecking())
    return .object(
      Self.compact([
        "name": .string(app.name), "bundleId": .string(app.bundleIdentifier),
        "path": .string(app.fileURL.path), "installed": JSONValue(Self.version(app.version)),
        "available": availability == "available" || availability == "current"
          ? JSONValue(app.remoteVersion.flatMap(Self.version)) : .null,
        "availability": .string(availability),
        "availabilityNote": JSONValue(availabilityNote),
        "updateAvailable": .bool(app.updateAvailable),
        "capability": .string(app.capability.rawValue),
        "handOffLabel": JSONValue(app.capability == .handOff ? Self.label(app) : nil),
        "ignored": app.isIgnored ? .bool(true) : .null,
        // The route Updater chose; where it was found only when that differs.
        "source": .string(app.source.rawValue),
        "detectedBy": app.bundle.source == app.source ? .null : .string(app.bundle.source.rawValue),
        "jobId": JSONValue(dependencies.updating.jobID(for: app.identifier)),
      ]))
  }

  /// `current` only after a check that succeeded and compared; otherwise say what is known.
  static func availability(of app: App, checking: Bool) -> (String, String?) {
    if let error = app.error { return ("error", error.localizedDescription) }
    guard let remote = app.remoteVersion else { return (checking ? "checking" : "unknown", nil) }
    if app.availabilityUnknown { return ("unknown", "Only the vendor's app knows.") }
    if app.updateAvailable { return ("available", nil) }
    switch app.version.comparisonForUpdate(to: remote) {
    case .samePrecedence, .newer: return ("current", nil)
    case .older: return ("unknown", "A newer version needs a newer macOS.")
    case .unavailable: return ("unknown", "The versions cannot be compared.")
    }
  }

  private func entry(_ app: App, _ status: String?, _ extra: [String: JSONValue])
    -> [String: JSONValue]
  {
    Self.compact(
      ["name": .string(app.name), "path": .string(app.fileURL.path), "status": JSONValue(status)]
        .merging(extra) { $1 })
  }

  private func state(of app: App) -> JSONValue {
    Self.state(dependencies.updating.state(for: app.identifier))
  }

  private static func state(_ state: UpdateProgressState) -> JSONValue {
    switch state {
    case .none: "idle"
    case .pending: "waiting"
    case .initializing, .downloading, .extracting, .installing, .waitingForVendor: "running"
    case .waitingForQuit: "waitingForQuit"
    case .cancelling: "cancelling"
    case .error: "failed"
    }
  }

  private static func outcome(_ outcome: UpdateOutcome, label: String?) -> [String: JSONValue] {
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
    case .handedOff: ["state": "handedOff", "label": JSONValue(label)]
    }
  }

  private static func label(_ app: App) -> String {
    if app.relaunchesToUpdate { return "a relaunch of \(app.name)" }
    if let name = app.externalUpdaterName { return name }
    switch app.source {
    case .appStore: return "the App Store"
    case .sparkle: return "the developer's website"
    default: return "the vendor's updater"
    }
  }

  private static func version(_ version: Version) -> String? {
    version.versionNumber ?? version.buildNumber
  }

  private static func compact(_ object: [String: JSONValue]) -> [String: JSONValue] {
    object.filter { $0.value != .null }
  }

  static func flag(_ value: String?) -> Bool { ["1", "true", "yes"].contains(value?.lowercased()) }
}
