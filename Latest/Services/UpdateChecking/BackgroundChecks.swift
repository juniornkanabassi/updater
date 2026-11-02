// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import UserNotifications

/// How often Updater checks by itself, stored in hours (0 is off).
enum BackgroundCheckInterval: Int, CaseIterable, Identifiable {
  case off = 0
  case hourly = 1
  case everyFourHours = 4
  case everyTwelveHours = 12
  case daily = 24

  static let storageKey = "BackgroundCheckIntervalHours"
  static let defaultValue = BackgroundCheckInterval.everyFourHours

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .off: "Off"
    case .hourly: "Every hour"
    case .everyFourHours: "Every 4 hours"
    case .everyTwelveHours: "Every 12 hours"
    case .daily: "Every day"
    }
  }

  var seconds: TimeInterval? { self == .off ? nil : TimeInterval(rawValue) * 3600 }

  static func current(in defaults: UserDefaults = .standard) -> Self {
    guard defaults.object(forKey: storageKey) != nil else { return defaultValue }
    return Self(rawValue: defaults.integer(forKey: storageKey)) ?? defaultValue
  }
}

/// Starts checks on launch, on wake and when the chosen interval has passed. It only ever
/// checks: installing stays the user's action.
@MainActor
final class BackgroundCheckScheduler {
  enum Trigger: Equatable { case launch, wake, timer }

  private let interval: () -> TimeInterval?
  private let isChecking: () -> Bool
  private let now: () -> Date
  private let check: (Trigger) -> Void
  private(set) var lastCheck: Date?
  private var ticker: Task<Void, Never>?
  private var wakeObserver: NSObjectProtocol?

  init(
    interval: @escaping () -> TimeInterval? = { BackgroundCheckInterval.current().seconds },
    isChecking: @escaping () -> Bool,
    now: @escaping () -> Date = Date.init,
    check: @escaping (Trigger) -> Void
  ) {
    self.interval = interval
    self.isChecking = isChecking
    self.now = now
    self.check = check
  }

  /// Starts a check unless one is running. Wake and timer checks follow the interval
  /// setting (off disables both); the timer also waits until the interval has passed.
  @discardableResult
  func fire(_ trigger: Trigger) -> Bool {
    if trigger != .launch {
      guard let interval = interval() else { return false }
      if trigger == .timer, let lastCheck, now().timeIntervalSince(lastCheck) < interval {
        return false
      }
    }
    guard !isChecking() else { return false }
    lastCheck = now()
    check(trigger)
    return true
  }

  /// Polling the wall clock survives sleep and picks up a changed interval at once.
  func start(pollingEvery poll: Duration = .seconds(60), wakeDelay: Duration = .seconds(15)) {
    guard ticker == nil else { return }
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: poll)
        self?.fire(.timer)
      }
    }
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      // The network is often still coming back right after wake.
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: wakeDelay)
        self?.fire(.wake)
      }
    }
  }

  func stop() {
    ticker?.cancel()
    ticker = nil
    if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    wakeObserver = nil
  }
}

@MainActor
protocol UpdateNotifying: AnyObject {
  /// Asks once; later calls return the stored answer without a prompt.
  func requestAuthorization() async
  func post(title: String, body: String) async
}

/// One summary notification per set of updates Updater has not announced before.
@MainActor
final class UpdateNotificationController {
  static let storageKey = "NotifiedUpdates"
  private let notifier: any UpdateNotifying
  private let defaults: UserDefaults

  init(notifier: any UpdateNotifying, defaults: UserDefaults = .standard) {
    self.notifier = notifier
    self.defaults = defaults
  }

  /// Every finished check moves the baseline. Only an explicit manual check stays quiet
  /// (its results are on screen); background and folder-triggered checks announce.
  func checkFinished(_ completion: UpdateCheckCompletion, includeExternal: Bool) async {
    let apps = Self.waitingUpdates(in: completion.apps, includeExternal: includeExternal)
    let previous = Set(defaults.stringArray(forKey: Self.storageKey) ?? [])
    let new = apps.filter { !previous.contains(Self.key(for: $0)) }
    defaults.set(apps.map(Self.key(for:)), forKey: Self.storageKey)
    guard completion.origin != .manual else { return }
    await notifier.requestAuthorization()
    guard let summary = Self.summary(of: new) else { return }
    await notifier.post(title: summary.title, body: summary.body)
  }

  /// The updates the Dock badge and the menu bar count.
  static func waitingUpdates(in apps: [App], includeExternal: Bool) -> [App] {
    apps.filter {
      $0.updateAvailable && !$0.isIgnored && (includeExternal || $0.usesBuiltInUpdater)
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// A new version of an already announced app counts as new.
  static func key(for app: App) -> String {
    app.fileURL.path + "|" + (app.remoteVersion.map(UpdateQueue.display) ?? "")
  }

  static func summary(of apps: [App]) -> (title: String, body: String)? {
    guard !apps.isEmpty else { return nil }
    let names = apps.map(\.name)
    let title = names.count == 1 ? "1 update available" : "\(names.count) updates available"
    let shown = names.prefix(3).joined(separator: ", ")
    return (title, names.count > 3 ? "\(shown) and \(names.count - 3) more" : shown)
  }
}

/// Clicking a notification brings up the main window.
@MainActor
final class LiveUpdateNotifier: NSObject, UpdateNotifying, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let open: @MainActor () -> Void

  init(open: @escaping @MainActor () -> Void) {
    self.open = open
    super.init()
    center.delegate = self
  }

  func requestAuthorization() async {
    _ = try? await center.requestAuthorization(options: [.alert, .sound])
  }

  func post(title: String, body: String) async {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    // A fixed identifier replaces the previous summary instead of stacking them.
    try? await center.add(
      UNNotificationRequest(identifier: "updates-available", content: content, trigger: nil))
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    await open()
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    [.banner, .list]
  }
}
