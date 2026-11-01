//
//  AppListSnapshot.swift
//  Latest
//
//  Created by Max Langer on 08.01.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Foundation

/// Describes the contents of the app list.
///
/// This structure supports the following states:
/// - All apps with updates available
/// - All installed apps, separated from the ones with updates through sections
/// - A filtered list of apps based on a given filter string
@MainActor
struct AppListSnapshot {
  private struct PreparedSections {
    let availableUpdates: [App]
    let installedUpdates: [App]
    let ignoredUpdates: [App]
  }

  /// The query after which apps can be filtered
  let filterQuery: String?

  /// The apps from which the content is created
  let apps: [App]

  let checkingGeneration: Int?

  private let settings: any AppListSettingsProviding

  /// Initializes the snapshot with the given list of apps and filter query.
  init(
    withApps apps: [App],
    filterQuery: String?,
    settings: any AppListSettingsProviding = AppListSettings.shared,
    checkingGeneration: Int? = nil,
    previous: AppListSnapshot? = nil
  ) {
    self.init(
      apps: apps,
      filterQuery: filterQuery,
      settings: settings,
      checkingGeneration: checkingGeneration,
      preparedSections: Self.prepareSections(
        from: apps, settings: settings, checkingGeneration: checkingGeneration, previous: previous),
      appsByIdentifier: Dictionary(
        apps.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
    )
  }

  private init(
    apps: [App],
    filterQuery: String?,
    settings: any AppListSettingsProviding,
    checkingGeneration: Int?,
    preparedSections: PreparedSections,
    appsByIdentifier: [App.Bundle.Identifier: App]
  ) {
    self.filterQuery = filterQuery
    self.apps = apps
    self.settings = settings
    self.checkingGeneration = checkingGeneration
    self.preparedSections = preparedSections
    let sections = Self.generateSections(from: preparedSections, filterQuery: filterQuery)
    self.sections = sections
    let entries = Self.generateEntries(from: sections)
    self.entries = entries
    self.entryIndexesByAppIdentifier = Self.entryIndexesByAppIdentifier(entries)
    self.appsByIdentifier = appsByIdentifier
  }

  /// Returns a new snapshot containing an updated filter query.
  func updated(with filterQuery: String?) -> AppListSnapshot {
    return AppListSnapshot(
      withApps: self.apps, filterQuery: filterQuery, settings: settings,
      checkingGeneration: checkingGeneration)
  }

  /// Refilters the existing snapshot without recategorizing or resorting unchanged apps.
  func refiltered(with filterQuery: String?) -> AppListSnapshot {
    AppListSnapshot(
      apps: apps,
      filterQuery: filterQuery,
      settings: settings,
      checkingGeneration: checkingGeneration,
      preparedSections: preparedSections,
      appsByIdentifier: appsByIdentifier
    )
  }

  /// The user-facable, sorted and filtered list of apps and sections. Observers of the data store will be notified, when this list changes.
  let entries: [Entry]

  /// Section groups used for selection and presentation without reparsing flattened entries.
  let sections: [SectionContent]

  private let entryIndexesByAppIdentifier: [App.Bundle.Identifier: Int]

  private let appsByIdentifier: [App.Bundle.Identifier: App]

  private let preparedSections: PreparedSections

  /// Sorts and filters all available apps based on the given filter criteria.
  private static func prepareSections(
    from apps: [App],
    settings: any AppListSettingsProviding,
    checkingGeneration: Int?,
    previous: AppListSnapshot?
  ) -> PreparedSections {
    let showInstalledUpdates = settings.showInstalledUpdates
    let showIgnoredUpdates = settings.showIgnoredUpdates
    let includeUnsupportedApps = settings.includeUnsupportedApps
    let includeAppsWithLimitedSupport = settings.includeAppsWithLimitedSupport
    let sortOrder = settings.sortOrder

    var availableUpdates = [App]()
    var installedUpdates = [App]()
    var ignoredUpdates = [App]()

    for app in apps {
      // Filter installed updates
      if !showInstalledUpdates && !(app.updateAvailable || app.isIgnored) {
        continue
      }

      // Filter ignored apps
      if !showIgnoredUpdates && app.isIgnored {
        continue
      }

      // Filter unsupported apps
      if !includeUnsupportedApps && !app.supported
        && !(checkingGeneration != nil && app.isSourcePending)
      {
        continue
      }

      // Filter apps not using the builtin updater
      if !includeAppsWithLimitedSupport && app.updateAvailable && !app.usesBuiltInUpdater {
        continue
      }

      if checkingGeneration != nil {
        installedUpdates.append(app)
      } else if app.isIgnored {
        ignoredUpdates.append(app)
      } else if app.updateAvailable {
        availableUpdates.append(app)
      } else {
        installedUpdates.append(app)
      }
    }

    if checkingGeneration != nil {
      // While status and remote dates resolve, every visible row lives under
      // the neutral Installed Apps heading. Updates remain actionable in place.
      let previousOrder =
        previous.map {
          $0.preparedSections.availableUpdates
            + $0.preparedSections.installedUpdates + $0.preparedSections.ignoredUpdates
        } ?? []
      Self.sort(&installedUpdates, by: sortOrder, previousOrder: previousOrder)
      return PreparedSections(
        availableUpdates: [], installedUpdates: installedUpdates, ignoredUpdates: [])
    }

    // Settled installed apps retain the existing displayed-date order.
    Self.sort(&availableUpdates, by: sortOrder)
    Self.sort(&ignoredUpdates, by: sortOrder)
    Self.sort(&installedUpdates, by: .updateDate)
    return PreparedSections(
      availableUpdates: availableUpdates,
      installedUpdates: installedUpdates,
      ignoredUpdates: ignoredUpdates
    )
  }

  private static func generateSections(
    from preparedSections: PreparedSections, filterQuery: String?
  ) -> [SectionContent] {
    let availableUpdates = Self.filtered(preparedSections.availableUpdates, with: filterQuery)
    let installedUpdates = Self.filtered(preparedSections.installedUpdates, with: filterQuery)
    let ignoredUpdates = Self.filtered(preparedSections.ignoredUpdates, with: filterQuery)

    return [
      SectionContent(
        section: Self.updatableAppsSection(withCount: availableUpdates.count),
        apps: availableUpdates),
      SectionContent(
        section: Self.updatedAppsSection(withCount: installedUpdates.count), apps: installedUpdates),
      SectionContent(
        section: Self.ignoredAppsSection(withCount: ignoredUpdates.count), apps: ignoredUpdates),
    ].filter { !$0.apps.isEmpty }
  }

  private static func generateEntries(from sections: [SectionContent]) -> [Entry] {
    let capacity = sections.reduce(sections.count) { $0 + $1.apps.count }
    var entries = [Entry]()
    entries.reserveCapacity(capacity)
    for section in sections {
      entries.append(.section(section.section))
      entries.append(contentsOf: section.apps.map(Entry.app))
    }
    return entries
  }

  private static func filtered(_ apps: [App], with query: String?) -> [App] {
    guard let query, !query.isEmpty else { return apps }
    return apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
  }

  private static func sort(
    _ apps: inout [App], by sortOrder: AppListSettings.SortOptions, previousOrder: [App] = []
  ) {
    if !previousOrder.isEmpty {
      // Retained rows already have an order. Only newcomers need sort keys.
      // Grouping also preserves duplicate inputs without collapsing their rows.
      var remaining = Dictionary(grouping: apps, by: \.identifier)
      var retained = [App]()
      retained.reserveCapacity(apps.count)
      for previous in previousOrder {
        if let current = remaining.removeValue(forKey: previous.identifier) {
          retained.append(contentsOf: current)
        }
      }
      var newcomers = apps.filter { remaining[$0.identifier] != nil }
      sort(&newcomers, by: sortOrder)
      apps = retained + newcomers
      return
    }
    apps = apps.map {
      (
        app: $0, date: $0.updateDate, name: $0.name.lowercased(),
        path: $0.identifier.absoluteString
      )
    }.sorted { lhs, rhs in
      if sortOrder == .updateDate, lhs.date != rhs.date { return lhs.date > rhs.date }
      if lhs.name != rhs.name { return lhs.name < rhs.name }
      return lhs.path < rhs.path
    }.map(\.app)
  }

  // MARK: - Accessors

  func firstIndex(of app: App) -> Int? {
    entryIndexesByAppIdentifier[app.identifier]
  }

  func app(withIdentifier identifier: App.Bundle.Identifier?) -> App? {
    guard let identifier else { return nil }
    return appsByIdentifier[identifier]
  }

  // MARK: - Section Builder

  private static func updatableAppsSection(withCount numberOfApps: Int) -> Section {
    let title = NSLocalizedString(
      "AvailableUpdatesSection", comment: "Table Section Header for available updates")
    return Section(title: title, numberOfApps: numberOfApps)
  }

  private static func updatedAppsSection(withCount numberOfApps: Int) -> Section {
    let title = NSLocalizedString(
      "InstalledAppsSection", comment: "Table Section Header for already installed apps")
    return Section(title: title, numberOfApps: numberOfApps)
  }

  private static func ignoredAppsSection(withCount numberOfApps: Int) -> Section {
    let title = NSLocalizedString(
      "IgnoredAppsSection", comment: "Table Section Header for ignored apps")
    return Section(title: title, numberOfApps: numberOfApps)
  }

  private static func entryIndexesByAppIdentifier(_ entries: [Entry]) -> [App.Bundle.Identifier:
    Int]
  {
    entries.enumerated().reduce(into: [App.Bundle.Identifier: Int]()) { indexes, element in
      guard case .app(let app) = element.element else { return }
      indexes[app.identifier] = indexes[app.identifier] ?? element.offset
    }
  }

}

extension AppListSnapshot {
  struct SectionContent: Identifiable {
    let section: Section
    let apps: [App]

    var id: String { section.title }
  }

  /// Defines one entry in the filtered update.
  enum Entry: Equatable, Hashable {
    /// Represents one app in the list.
    case app(App)

    /// Represents one section header in the list.
    case section(Section)

  }

  /// A section used for grouping multiple results.
  struct Section: Equatable, Hashable {

    /// The title of the section.
    let title: String

    /// The number of apps this section encloses.
    let numberOfApps: Int

  }
}
