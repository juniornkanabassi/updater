//
//  AppListSnapshotTest.swift
//  Latest Tests
//
//  Created by ertyoii on 20.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-05-20.
//  Licensed under GPL-3.0; see LICENSE.md.

import XCTest

@MainActor
final class AppListSnapshotTest: XCTestCase {
  func testUnknownPersistedSortOrderFallsBackToDate() throws {
    let suite = "AppListSnapshotTest.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppListSettings(userDefaults: defaults)
    for value in [-1, 99] {
      defaults.set(value, forKey: "SortOptionsKey")
      XCTAssertEqual(settings.sortOrder, .updateDate)
    }
    settings.sortOrder = .name
    XCTAssertEqual(settings.sortOrder, .name)
  }

  func testSnapshotPartitionsAppsIntoAvailableInstalledAndIgnoredSections() throws {
    let settings = try isolatedAppListSettings(for: self)

    let available = makeApp(name: "Alpha", versionNumber: "1.0", remoteVersionNumber: "2.0")
    let installed = makeApp(name: "Beta", versionNumber: "1.0")
    let ignored = makeApp(
      name: "Gamma", versionNumber: "1.0", remoteVersionNumber: "2.0", isIgnored: true)

    let snapshot = AppListSnapshot(
      withApps: [installed, ignored, available], filterQuery: nil, settings: settings)

    XCTAssertEqual(snapshot.entries.count, 6)
    XCTAssertEqual(section(at: 0, in: snapshot)?.numberOfApps, 1)
    XCTAssertEqual(snapshot.sections[0].apps[0].name, "Alpha")
    XCTAssertEqual(section(at: 2, in: snapshot)?.numberOfApps, 1)
    XCTAssertEqual(snapshot.sections[1].apps[0].name, "Beta")
    XCTAssertEqual(section(at: 4, in: snapshot)?.numberOfApps, 1)
    XCTAssertEqual(snapshot.sections[2].apps[0].name, "Gamma")
  }

  func testSnapshotFilterKeepsOnlyMatchingAppsAndSections() throws {
    let settings = try isolatedAppListSettings(for: self)

    let alpha = makeApp(name: "Alpha", versionNumber: "1.0", remoteVersionNumber: "2.0")
    let beta = makeApp(name: "Beta", versionNumber: "1.0", remoteVersionNumber: "2.0")

    let snapshot = AppListSnapshot(withApps: [alpha, beta], filterQuery: "alp", settings: settings)

    XCTAssertEqual(snapshot.entries.count, 2)
    XCTAssertEqual(section(at: 0, in: snapshot)?.numberOfApps, 1)
    XCTAssertEqual(snapshot.sections[0].apps[0].name, "Alpha")
  }

  func testSearchRefilterMatchesFullSnapshotRebuild() throws {
    let settings = try isolatedAppListSettings(for: self)
    let apps = [
      makeApp(name: "Alpha", versionNumber: "1.0", remoteVersionNumber: "2.0"),
      makeApp(name: "Alphabet", versionNumber: "1.0"),
      makeApp(name: "Beta", versionNumber: "1.0", remoteVersionNumber: "2.0", isIgnored: true),
    ]
    let snapshot = AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings)
    let filtered = snapshot.refiltered(with: "ALPHA")

    XCTAssertEqual(
      filtered.entries,
      AppListSnapshot(withApps: apps, filterQuery: "ALPHA", settings: settings).entries
    )
    XCTAssertEqual(filtered.sections.map { $0.apps.map(\.name) }, [["Alpha"], ["Alphabet"]])
    XCTAssertEqual(
      snapshot.refiltered(with: nil).entries,
      AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings).entries
    )
  }

  func testInstalledAppsAreSortedByBundleModificationDate() throws {
    let settings = try isolatedAppListSettings(for: self)

    let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let older = try makeApp(
      name: "A Older", versionNumber: "1.0", modificationDate: Date(timeIntervalSince1970: 1),
      in: directory)
    let newer = try makeApp(
      name: "Z Newer", versionNumber: "1.0", modificationDate: Date(timeIntervalSince1970: 2),
      in: directory)

    let snapshot = AppListSnapshot(
      withApps: [older, newer], filterQuery: nil, settings: settings)

    XCTAssertEqual(snapshot.sections[0].apps[0].name, "Z Newer")
    XCTAssertEqual(snapshot.sections[0].apps[1].name, "A Older")
  }

  func testSnapshotMatchesUpdatedAppByIdentifier() throws {
    let settings = try isolatedAppListSettings(for: self)

    let appURL = URL(
      fileURLWithPath: "/Applications/Snapshot-\(UUID().uuidString).app", isDirectory: true)
    let original = makeApp(name: "Snapshot", versionNumber: "1.0", appURL: appURL)
    let refreshed = makeApp(name: "Snapshot", versionNumber: "1.1", appURL: appURL)
    let snapshot = AppListSnapshot(withApps: [original], filterQuery: nil, settings: settings)

    let originalIndex = try XCTUnwrap(snapshot.firstIndex(of: original))
    XCTAssertEqual(snapshot.firstIndex(of: refreshed), originalIndex)
  }

  func testInstalledAppStoreAppsSortByDisplayedDateAfterLookup() throws {
    let settings = try isolatedAppListSettings(for: self)
    let day = 86_400.0
    let apps = [
      (name: "Amazon Kindle", source: App.Source.appStore, localDay: 1.0, releaseDay: 10.0),
      (name: "WhatsApp", source: App.Source.appStore, localDay: 2.0, releaseDay: 9.0),
      (name: "BetterDisplay", source: App.Source.sparkle, localDay: 8.0, releaseDay: nil),
      (name: "Alpha", source: App.Source.appStore, localDay: 3.0, releaseDay: 10.0),
    ].map { fixture -> App in
      let bundle = App.Bundle(
        version: Version(versionNumber: "1.0", buildNumber: nil), name: fixture.name,
        bundleIdentifier: "com.example.\(fixture.name)",
        fileURL: URL(fileURLWithPath: "/Applications/\(fixture.name).app"),
        source: fixture.source,
        modificationDate: Date(timeIntervalSince1970: fixture.localDay * day))
      let update = fixture.releaseDay.map { releaseDay in
        App.Update(
          app: bundle, remoteVersion: bundle.version, minimumOSVersion: nil,
          source: fixture.source, date: Date(timeIntervalSince1970: releaseDay * day),
          releaseNotes: nil, updateAction: .builtIn { _ in })
      }
      return App(bundle: bundle, update: update.map { .success($0) }, isIgnored: false)
    }
    let snapshot = AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings)

    XCTAssertEqual(snapshot.sections.count, 1)
    XCTAssertEqual(
      snapshot.sections[0].apps.map(\.name),
      ["Alpha", "Amazon Kindle", "WhatsApp", "BetterDisplay"])
    XCTAssertEqual(
      snapshot.refiltered(with: "a").sections[0].apps.map(\.name),
      ["Alpha", "Amazon Kindle", "WhatsApp", "BetterDisplay"])
  }

  func testCheckingRowsKeepOrderAsDatesAndUpdateSectionsResolve() throws {
    let settings = try isolatedAppListSettings(for: self)
    settings.sortOrder = .updateDate
    let alpha = makeTestApp(
      name: "Alpha", version: "1", remoteVersion: "2", date: Date(timeIntervalSince1970: 10))
    let beta = makeTestApp(
      name: "Beta", version: "1", remoteVersion: "2", date: Date(timeIntervalSince1970: 20))
    let pending = [alpha, beta].map { App(bundle: $0.bundle, update: nil, isIgnored: false) }
    let discovered = AppListSnapshot(
      withApps: pending.reversed(), filterQuery: nil, settings: settings, checkingGeneration: 1)
    let partial = AppListSnapshot(
      withApps: [alpha, pending[1]], filterQuery: nil, settings: settings, checkingGeneration: 1,
      previous: discovered)
    let complete = AppListSnapshot(
      withApps: [beta, alpha], filterQuery: nil, settings: settings, checkingGeneration: 1,
      previous: partial)
    XCTAssertEqual(complete.sections.count, 1)
    XCTAssertEqual(
      complete.sections[0].section.title, NSLocalizedString("InstalledAppsSection", comment: ""))
    XCTAssertEqual(complete.sections[0].apps.map(\.name), ["Alpha", "Beta"])
    XCTAssertEqual(complete.firstIndex(of: beta), discovered.firstIndex(of: pending[1]))
    XCTAssertEqual(complete.refiltered(with: "b").sections[0].apps.map(\.name), ["Beta"])
    XCTAssertEqual(complete.refiltered(with: nil).sections[0].apps.map(\.name), ["Alpha", "Beta"])
    let gamma = makeTestApp(
      name: "Gamma", version: "1", remoteVersion: "2", date: Date(timeIntervalSince1970: 30))
    let delta = makeTestApp(
      name: "Delta", version: "1", remoteVersion: "2", date: Date(timeIntervalSince1970: 40))
    let rediscovered = AppListSnapshot(
      withApps: [gamma, beta, delta], filterQuery: nil, settings: settings,
      checkingGeneration: 1, previous: complete)
    XCTAssertEqual(
      rediscovered.sections[0].apps.map(\.name), ["Beta", "Delta", "Gamma"],
      "Retained rows precede sorted newcomers, and removed apps leave no row")
    // Explicit preference changes may reorder the current results, without waiting for settlement.
    let explicitlySorted = complete.updated(with: nil)
    XCTAssertEqual(explicitlySorted.sections[0].apps.map(\.name), ["Beta", "Alpha"])
    settings.sortOrder = .name
    XCTAssertEqual(
      explicitlySorted.updated(with: nil).sections[0].apps.map(\.name), ["Alpha", "Beta"])
    settings.sortOrder = .updateDate
    let settled = AppListSnapshot(withApps: [alpha, beta], filterQuery: nil, settings: settings)
    XCTAssertEqual(settled.sections[0].apps.map(\.name), ["Beta", "Alpha"])
    XCTAssertEqual(
      settled.sections[0].section.title, NSLocalizedString("AvailableUpdatesSection", comment: ""))
  }

  func testCheckingFiltersDoNotTreatUnknownSourceAsUnsupportedOrAnAvailableUpdate() throws {
    let settings = try isolatedAppListSettings(for: self)
    settings.includeUnsupportedApps = false
    settings.showIgnoredUpdates = false
    let bundle = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "Unknown",
      bundleIdentifier: "test.unknown", fileURL: URL(fileURLWithPath: "/tmp/Unknown.app"),
      source: .none, modificationDate: .distantPast)
    let pending = App(bundle: bundle, update: nil, isIgnored: false)
    let failed = App(
      bundle: bundle, update: .failure(URLError(.timedOut)), isIgnored: false)
    let available = makeTestApp(name: "Available", version: "1", remoteVersion: "2")
    let limited = makeApp(name: "Limited", versionNumber: "1", remoteVersionNumber: "2")
    func snapshot(_ apps: [App]) -> AppListSnapshot {
      AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings, checkingGeneration: 1)
    }
    XCTAssertEqual(snapshot([pending]).entries.count, 2)
    XCTAssertTrue(snapshot([failed]).entries.isEmpty)
    XCTAssertTrue(snapshot([available.with(ignoredState: true)]).entries.isEmpty)
    settings.showInstalledUpdates = false
    XCTAssertTrue(
      snapshot([pending]).entries.isEmpty,
      "Updates-only never claims an unknown result is an update")
    settings.includeAppsWithLimitedSupport = false
    XCTAssertEqual(
      snapshot([pending, failed, available, limited]).sections.flatMap(\.apps).map(\.name),
      ["Available"])
  }

  func testEqualDatesAndNamesUsePathAsDeterministicTieBreaker() throws {
    let settings = try isolatedAppListSettings(for: self)
    settings.sortOrder = .updateDate
    let first = makeApp(
      name: "Same", versionNumber: "1", remoteVersionNumber: "2",
      appURL: URL(fileURLWithPath: "/tmp/A.app"))
    let second = makeApp(
      name: "Same", versionNumber: "1", remoteVersionNumber: "2",
      appURL: URL(fileURLWithPath: "/tmp/B.app"))
    for apps in [[first, second], [second, first]] {
      XCTAssertEqual(
        AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings).sections[0].apps.map(
          \.identifier), [first.identifier, second.identifier])
    }
  }

  private func section(at index: Int, in snapshot: AppListSnapshot) -> AppListSnapshot.Section? {
    guard case .section(let section) = snapshot.entries[index] else { return nil }
    return section
  }

  private func makeApp(
    name: String,
    versionNumber: String,
    remoteVersionNumber: String? = nil,
    isIgnored: Bool = false,
    appURL: URL? = nil
  ) -> App {
    let url =
      appURL
      ?? URL(fileURLWithPath: "/Applications/\(name)-\(UUID().uuidString).app", isDirectory: true)
    let bundle = App.Bundle(
      version: Version(versionNumber: versionNumber, buildNumber: nil),
      name: name,
      bundleIdentifier: "com.example.\(name.lowercased())",
      fileURL: url,
      source: .sparkle
    )

    let update: Result<App.Update, Error>? = remoteVersionNumber.map { remoteVersionNumber in
      .success(
        App.Update(
          app: bundle,
          remoteVersion: Version(versionNumber: remoteVersionNumber, buildNumber: nil),
          minimumOSVersion: nil,
          source: .sparkle,
          date: nil,
          releaseNotes: nil,
          updateAction: .external(label: "Test") { _ in }
        ))
    }

    return App(bundle: bundle, update: update, isIgnored: isIgnored)
  }

  private func makeApp(
    name: String,
    versionNumber: String,
    modificationDate: Date,
    in directory: URL
  ) throws -> App {
    let url = directory.appendingPathComponent("\(name).app", isDirectory: true)
    let contentsURL = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.modificationDate: modificationDate], ofItemAtPath: url.path)
    try FileManager.default.setAttributes(
      [.modificationDate: modificationDate], ofItemAtPath: contentsURL.path)

    return makeApp(name: name, versionNumber: versionNumber, appURL: url)
  }

}
