//
//  AppListSettings.swift
//  Latest
//
//  Created by Max Langer on 09.01.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Foundation

private let SortOptionsKey = "SortOptionsKey"
private let ShowInstalledUpdatesKey = "ShowInstalledUpdatesKey"
private let ShowIgnoredUpdatesKey = "ShowIgnoredUpdatesKey"

private let IncludeUnsupportedAppsKey = "ShowUnsupportedUpdatesKey"
private let IncludeAppsWithLimitedSupportKey = "IncludeAppsWithLimitedSupportKey"

/// Observable front end to app list preferences.
@MainActor
protocol AppListSettingsProviding: AnyObject {
  func updates() -> AsyncStream<Void>
  var sortOrder: AppListSettings.SortOptions { get set }
  var showInstalledUpdates: Bool { get set }
  var showIgnoredUpdates: Bool { get set }
  var includeUnsupportedApps: Bool { get set }
  var includeAppsWithLimitedSupport: Bool { get set }
}

/// UserDefaults-backed app-list preferences. The store is injectable so tests,
/// previews, and alternate app environments do not mutate global preferences.
@MainActor
final class AppListSettings: AppListSettingsProviding {

  /// Sorting options available to the app list.
  enum SortOptions: Int, CaseIterable {
    /// Sort based on the date of the the last update, similar to what the App Store does.
    case updateDate = 0

    /// Sort alphabetically by app name.
    case name = 1

    /// A user-displayable text of the given sort option.
    var displayName: String {
      switch self {
      case .updateDate:
        return NSLocalizedString(
          "DateSortOption",
          comment: "Update date sorting option. Displayed in menu with title: 'Sort By' -> 'Date'")
      case .name:
        return NSLocalizedString(
          "NameSortOption",
          comment:
            "Sorting option to list by app names alphabetically. Displayed in menu with title: 'Sort By' -> 'Name'"
        )
      }
    }
  }

  private let updateStreams = MainActorAsyncStreamRegistry<Void>()
  private let userDefaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    userDefaults.register(defaults: [
      ShowInstalledUpdatesKey: true,
      IncludeUnsupportedAppsKey: true,
      IncludeAppsWithLimitedSupportKey: true,
    ])
  }

  static let shared = AppListSettings()

  func updates() -> AsyncStream<Void> {
    updateStreams.stream(initialValue: ())
  }

  /// The order the app list should be shown in.
  var sortOrder: SortOptions {
    set {
      set(newValue.rawValue, forKey: SortOptionsKey)
    }

    get {
      SortOptions(rawValue: userDefaults.integer(forKey: SortOptionsKey)) ?? .updateDate
    }
  }

  /// Whether installed apps should be visible
  var showInstalledUpdates: Bool {
    set {
      set(newValue, forKey: ShowInstalledUpdatesKey)
    }

    get {
      userDefaults.bool(forKey: ShowInstalledUpdatesKey)
    }
  }

  /// Whether ignored apps should be visible
  var showIgnoredUpdates: Bool {
    set {
      set(newValue, forKey: ShowIgnoredUpdatesKey)
    }

    get {
      userDefaults.bool(forKey: ShowIgnoredUpdatesKey)
    }
  }

  /// Whether unsupported apps should be visible
  var includeUnsupportedApps: Bool {
    set {
      set(newValue, forKey: IncludeUnsupportedAppsKey)
    }

    get {
      userDefaults.bool(forKey: IncludeUnsupportedAppsKey)
    }
  }

  /// Whether apps only partially supported by Latest should be included.
  var includeAppsWithLimitedSupport: Bool {
    set {
      set(newValue, forKey: IncludeAppsWithLimitedSupportKey)
    }

    get {
      userDefaults.bool(forKey: IncludeAppsWithLimitedSupportKey)
    }
  }

  // MARK: - Utilities

  private func set(_ value: Any, forKey key: String) {
    userDefaults.set(value, forKey: key)
    updateStreams.yield(())
  }

}
