import Foundation
import Synchronization

/// A coherent collection and scan phase; consumers need not sample mutable state.
struct AppListUpdate: Sendable {
  let apps: [App]
  let checkingGeneration: Int?
}

protocol AppProviding {
  var updatableApps: [App] { get }
  func countOfAvailableUpdates(where condition: (App) -> Bool) -> Int
  @MainActor func updates() -> AsyncStream<AppListUpdate>
  func setIgnoredState(_ ignored: Bool, for app: App)
}

/// All collection/index/preference mutations share one mutex. Snapshots leave the
/// lock before caller predicates or main-actor observers run.
final class AppDataStore: AppProviding, Sendable {
  // Foundation documents UserDefaults as thread-safe but does not declare it
  // Sendable. Only this adapter crosses that boundary; accesses use state's mutex.
  private struct Preferences: @unchecked Sendable {
    let value: UserDefaults
  }
  private struct State: Sendable {
    var appsByIdentifier = [App.Bundle.Identifier: App]()
    var pendingCheckGeneration: Int?
    var ignoredAppIdentifiers: Set<String>
    let preferences: Preferences

    func app(for bundle: App.Bundle) -> App {
      if let previous = appsByIdentifier[bundle.identifier],
        previous.bundleIdentifier == bundle.bundleIdentifier,
        previous.bundle.source == bundle.source
      {
        return previous.bundle.matchesMetadata(of: bundle)
          ? previous : previous.with(bundle: bundle)
      }
      // A path can be reused by another product or distribution channel.
      // Its old update action and ignore preference do not identify the replacement.
      return App(
        bundle: bundle, update: nil,
        isIgnored: ignoredAppIdentifiers.contains(bundle.bundleIdentifier))
    }
  }

  private let state: Mutex<State>
  private let scheduledUpdate = Mutex<DispatchWorkItem?>(nil)
  private let schedulingQueue = DispatchQueue(label: "AppDataStoreUpdateSchedulingQueue")
  private static let updateCoalescingInterval: TimeInterval = 0.15
  private static let ignoredAppsKey = "IgnoredAppsKey"
  @MainActor private let updateStreams = MainActorAsyncStreamRegistry<AppListUpdate>()

  init(userDefaults: UserDefaults = .standard) {
    state = Mutex(
      State(
        ignoredAppIdentifiers: Set(userDefaults.stringArray(forKey: Self.ignoredAppsKey) ?? []),
        preferences: Preferences(value: userDefaults)
      ))
  }

  var apps: [App] { state.withLock { Array($0.appsByIdentifier.values) } }
  var updatableApps: [App] {
    apps.filter { $0.updateAvailable && $0.usesBuiltInUpdater && !$0.isIgnored }
  }
  func countOfAvailableUpdates(where condition: (App) -> Bool) -> Int {
    apps.reduce(into: 0) { count, app in
      if app.updateAvailable && !app.isIgnored && condition(app) { count += 1 }
    }
  }

  /// Discovery identity alone is insufficient: an existing path may have new metadata.
  func containsSameBundles(as bundles: Set<App.Bundle>) -> Bool {
    state.withLock { state in
      state.appsByIdentifier.count == bundles.count
        && bundles.allSatisfy { bundle in
          guard let current = state.appsByIdentifier[bundle.identifier]?.bundle else {
            return false
          }
          return current.matchesMetadata(of: bundle)
        }
    }
  }

  func set(appBundles: Set<App.Bundle>) {
    state.withLock { state in
      var appsByIdentifier = [App.Bundle.Identifier: App]()
      appsByIdentifier.reserveCapacity(appBundles.count)
      for bundle in appBundles {
        appsByIdentifier[bundle.identifier] = state.app(for: bundle)
      }
      state.appsByIdentifier = appsByIdentifier
    }
    scheduleFilterUpdate()
  }

  func set(appBundle bundle: App.Bundle) -> App {
    let app = state.withLock { state in
      let app = state.app(for: bundle)
      state.appsByIdentifier[app.identifier] = app
      return app
    }
    scheduleFilterUpdate()
    return app
  }

  func set(_ update: Result<App.Update, Error>?, for bundle: App.Bundle) -> App {
    let app = state.withLock { state in
      let ignored =
        state.appsByIdentifier[bundle.identifier]?.isIgnored
        ?? state.ignoredAppIdentifiers.contains(bundle.bundleIdentifier)
      let app = App(bundle: bundle, update: update, isIgnored: ignored)
      state.appsByIdentifier[app.identifier] = app
      return app
    }
    scheduleFilterUpdate()
    return app
  }

  /// A targeted post-install refresh can change metadata within an ongoing
  /// scan generation. Accept only results for the currently installed bundle.
  func accept(_ update: Result<App.Update, Error>, for bundle: App.Bundle) -> App? {
    let app = state.withLock { state -> App? in
      guard let current = state.appsByIdentifier[bundle.identifier],
        current.bundle.matchesMetadata(of: bundle)
      else { return nil }
      let app = App(bundle: bundle, update: update, isIgnored: current.isIgnored)
      state.appsByIdentifier[app.identifier] = app
      return app
    }
    if app != nil { scheduleFilterUpdate() }
    return app
  }

  func setIgnoredState(_ ignored: Bool, for app: App) {
    state.withLock { state in
      if ignored {
        state.ignoredAppIdentifiers.insert(app.bundleIdentifier)
      } else {
        state.ignoredAppIdentifiers.remove(app.bundleIdentifier)
      }
      state.preferences.value.set(Array(state.ignoredAppIdentifiers), forKey: Self.ignoredAppsKey)
      // Preferences belong to an app identifier, including every installed copy.
      // A settled UI row can outlive discovery; never reinsert its removed path.
      for (identifier, current) in state.appsByIdentifier
      where current.bundleIdentifier == app.bundleIdentifier {
        state.appsByIdentifier[identifier] = current.with(ignoredState: ignored)
      }
    }
    scheduleFilterUpdate()
  }

  /// Publish discovery and status changes throughout the current scan.
  func beginUpdateCheck(generation: Int) {
    state.withLock { $0.pendingCheckGeneration = generation }
    scheduleFilterUpdate()
  }

  @MainActor func finishUpdateCheck(generation: Int) {
    let update = state.withLock { state -> AppListUpdate? in
      guard state.pendingCheckGeneration == generation else { return nil }
      state.pendingCheckGeneration = nil
      return AppListUpdate(apps: Array(state.appsByIdentifier.values), checkingGeneration: nil)
    }
    if let update { updateStreams.yield(update) }
  }

  @MainActor func updates() -> AsyncStream<AppListUpdate> {
    updateStreams.stream(initialValue: listUpdate())
  }

  private func listUpdate() -> AppListUpdate {
    state.withLock {
      AppListUpdate(
        apps: Array($0.appsByIdentifier.values), checkingGeneration: $0.pendingCheckGeneration)
    }
  }

  private func scheduleFilterUpdate() {
    scheduledUpdate.withLock { scheduled in
      // Throttle rather than debounce: a steady stream of completions must not
      // postpone discovery or incremental results indefinitely.
      guard scheduled == nil else { return }
      let work = DispatchWorkItem { [weak self] in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.scheduledUpdate.withLock { $0 = nil }
          self.updateStreams.yield(self.listUpdate())
        }
      }
      scheduled = work
      schedulingQueue.asyncAfter(deadline: .now() + Self.updateCoalescingInterval, execute: work)
    }
  }
}
