// Copyright © 2026 Junior Nkana Bassi. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

/// Renders the Round 6 surfaces offscreen (never ordered on screen, never activated) and checks
/// each render has content. PNGs are written only when `outputDirectory` exists, so the
/// integration lane stays side-effect free.
@MainActor
final class Round6VisualTest: XCTestCase {
  static let outputDirectory = URL(fileURLWithPath: "/private/tmp/updater-build/r6-shots")

  func testRendersMainWindowDetailStatesSettingsAndMenu() async throws {
    let settings = try isolatedAppListSettings(for: self)
    settings.sortOrder = .updateDate
    let fixture = Round6Fixture()
    let store = fixture.store
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: store.apps, filterQuery: nil, settings: settings),
      settings: settings, appProvider: store, updating: fixture.updating)
    let environment = AppEnvironment(
      settings: settings, coordinator: fixture.coordinator, updating: fixture.updating,
      updatesListViewModel: model)
    environment.menuBar.refresh(with: store.apps)
    XCTAssertEqual(
      environment.menuBar.updateAllCount, 5, "Goodnotes, Notion, Word, Audio Hijack, Discord")
    model.startObserving()
    defer { model.stopObserving() }
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(model.selectedApp?.name, "Goodnotes", "The first update is selected")

    for dark in [false, true] {
      let suffix = dark ? "dark" : "light"
      try await render(
        LatestRootView(environment: environment), size: CGSize(width: 900, height: 640),
        dark: dark, window: true, name: "main-window-\(suffix)")
    }

    let detail = CGSize(width: 560, height: 420)
    let history = UpdateHistoryStore(
      fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(
        "round6-\(UUID().uuidString).jsonl"))
    let goodnotes = try XCTUnwrap(store.apps.first { $0.name == "Goodnotes" })
    history.record(
      UpdateHistoryEntry(
        before: goodnotes.bundle, after: goodnotes.bundle,
        outcome: .updated(from: "7.1.30", to: "7.1.32")))
    for name in [
      "Goodnotes", "Adobe Premiere Pro 2026", "Discord", "OBS", "Google Chrome",
      "Final Cut Pro", "Updater", "Raycast", "Audio Hijack",
    ] {
      let app = try XCTUnwrap(store.apps.first { $0.name == name })
      try await render(
        ReleaseNotesDetailSurface(
          app: app,
          contentState: .message(ReleaseNotesMessage(error: LatestError.releaseNotesUnavailable)),
          updating: fixture.updating, history: history),
        size: detail, dark: false,
        name: "detail-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
    for (overview, name) in [
      (DetailOverview.noUpdates(UpdateStatusSummary(current: 42)), "overview-up-to-date"),
      (
        .noUpdates(
          UpdateStatusSummary(
            current: 38, couldNotCheck: 2, checkInVendor: 3, vendor: "Creative Cloud")),
        "overview-partial"
      ),
      (.checking, "overview-checking"), (.offline, "overview-offline"),
      (.lookingForApps, "overview-first-run"),
    ] {
      try await render(
        ReleaseNotesDetailSurface(
          app: nil, contentState: .message(.noSelection), overview: overview),
        size: detail, dark: false, name: name)
    }

    let settingsModel = SettingsViewModel(settings: settings)
    for tab in SettingsViewModel.Tab.allCases {
      settingsModel.selectedTab = tab
      // Settings sizes to its content; a grouped Form must not collapse inside it.
      let fitting = NSHostingController(rootView: SettingsRootView(viewModel: settingsModel))
        .sizeThatFits(in: CGSize(width: 460, height: 10_000))
      XCTAssertGreaterThan(fitting.height, 200, "settings-\(tab) height")
      try await render(
        SettingsRootView(viewModel: settingsModel), size: CGSize(width: 460, height: 560),
        dark: false, name: "settings-\(tab)")
    }

    // A menu bar menu only draws while it is open; record its real structure instead.
    let menu = NSHostingMenu(
      rootView: MenuBarContentView(
        model: environment.menuBar, checking: environment.updateCheckingService, select: { _ in }))
    try await Task.sleep(for: .milliseconds(100))
    menu.update()
    let lines = menu.items.map { item in
      item.isSeparatorItem
        ? "────────"
        : (item.isSectionHeader
          ? "[\(item.title)]" : "  \(item.title)\(item.isEnabled ? "" : "  (disabled)")")
    }
    XCTAssertTrue(lines.contains("  Ready to Update  (disabled)"), lines.joined(separator: "\n"))
    XCTAssertTrue(lines.contains("  Needs You  (disabled)"), lines.joined(separator: "\n"))
    XCTAssertNotEqual(lines.first, "────────", "The menu must not start with a separator")
    XCTAssertTrue(lines.contains("  Update All (5)"), lines.joined(separator: "\n"))
    try write(Data(lines.joined(separator: "\n").utf8), name: "menu-bar.txt")
  }

  /// R6-001: "Everything is up to date" only when every checked app was verified current.
  func testUpToDateIsClaimedOnlyWhenEveryCheckSucceeded() throws {
    let current = makeTestApp(name: "Current", version: "2", remoteVersion: "2")
    let failedBundle = makeTestApp(name: "Failed", version: "1").bundle
    let failed = Latest.App(
      bundle: failedBundle, update: .failure(LatestError.updateInfoUnavailable), isIgnored: false)
    let adobe = makeTestApp(
      name: "Premiere", version: "26", remoteVersion: "26",
      updateAction: .external(label: "Creative Cloud") { _ in })
    let unknown = Latest.App(
      bundle: adobe.bundle,
      update: .success(
        Latest.App.Update(
          app: adobe.bundle, remoteVersion: adobe.bundle.version, minimumOSVersion: nil,
          source: .vendor, date: nil, releaseNotes: nil,
          updateAction: .external(label: "Creative Cloud") { _ in }, availabilityUnknown: true)),
      isIgnored: false)
    XCTAssertTrue(UpdateStatusSummary(apps: [current]).isAllCurrent)
    let partial = UpdateStatusSummary(apps: [current, failed, unknown])
    XCTAssertFalse(partial.isAllCurrent)
    XCTAssertEqual(
      partial.text, "1 up to date · 1 couldn't be checked · 1 check in Creative Cloud")
    let settings = try isolatedAppListSettings(for: self)
    XCTAssertEqual(
      DetailOverview(
        snapshot: AppListSnapshot(
          withApps: [current, failed], filterQuery: nil, settings: settings)
      ), .noUpdates(UpdateStatusSummary(current: 1, couldNotCheck: 1)))
  }

  /// R6-002: history claims "Opened" only when the record says something opened.
  func testHandOffHistoryClaimsOpenedOnlyWhenRecorded() {
    let bundle = makeTestApp(name: "Store", version: "1").bundle
    func entry(_ note: HandOffNote?) -> String {
      UpdateHistoryEntry(before: bundle, after: bundle, outcome: .handedOff, handOff: note)
        .displaySummary
    }
    XCTAssertTrue(
      entry(.init(destination: "App Store", reason: "r", opened: true, blockedByPolicy: false))
        .hasPrefix("Opened App Store"))
    let blocked = entry(
      .init(
        destination: "App Store", reason: "Updater can't target this copy.", opened: false,
        blockedByPolicy: true))
    XCTAssertFalse(blocked.contains("Opened"), blocked)
    XCTAssertTrue(blocked.contains("Updater can't target this copy."), blocked)
    XCTAssertFalse(entry(nil).contains("Opened"), "Records from before 0.7.0 never claim opened")
  }

  /// R6-003, R6-005: no claim the browser downloaded anything or that brew needs a password.
  func testHandOffCopyMakesNoUnverifiedClaims() {
    let chrome = makeTestApp(
      name: "Fixture Chrome", version: "1", remoteVersion: "2", updateAction: .relaunch { _ in })
    XCTAssertTrue(chrome.updateExplanation.contains("if it has downloaded one"))
    XCTAssertFalse(chrome.updateExplanation.contains("already downloaded"))
    let cask = makeTestApp(
      name: "Cask", version: "1", remoteVersion: "2",
      updateAction: .external(label: HomebrewCheckerOperation.handOffLabel) { _ in })
    for text in [cask.updateExplanation, cask.routeShortDescription] {
      XCTAssertFalse(text.localizedCaseInsensitiveContains("password"), text)
    }
    XCTAssertEqual(cask.routeShortDescription, "Opens Terminal with the brew command")
  }

  private func render<Content: View>(
    _ content: Content, size: CGSize, dark: Bool, window: Bool = false, name: String
  ) async throws {
    let root =
      content
      .environment(\.colorScheme, dark ? .dark : .light)
      .environment(\.locale, Locale(identifier: "en_GB"))
    let controller = NSHostingController(rootView: root)
    let host = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: window
        ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless],
      backing: .buffered, defer: false)
    host.isReleasedWhenClosed = false
    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    host.contentViewController = controller
    host.setContentSize(size)
    defer { host.close() }
    for _ in 0..<5 {
      try await Task.sleep(for: .milliseconds(80))
      host.contentView?.layoutSubtreeIfNeeded()
    }
    // The frame view draws the titlebar and toolbar as well as the content.
    let view = try XCTUnwrap(window ? host.contentView?.superview : host.contentView)
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    XCTAssertGreaterThan(bitmap.pixelsWide, 0, name)
    try write(
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), name: "\(name).png")
  }

  private func write(_ data: Data, name: String) throws {
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: Self.outputDirectory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return }
    try data.write(to: Self.outputDirectory.appendingPathComponent(name))
  }
}

/// Fixed update states per app, so failures and progress render without running anything.
private final class Round6Updating: AppUpdating {
  let states: [Latest.App.Bundle.Identifier: UpdateProgressState]
  init(states: [Latest.App.Bundle.Identifier: UpdateProgressState]) { self.states = states }
  func isUpdating(_ app: Latest.App) -> Bool { false }
  func update(_ app: Latest.App, isBulkUpdate: Bool) {}
  func cancel(_ app: Latest.App) {}
  @MainActor func retryTermination(_ app: Latest.App) {}
  func state(for identifier: Latest.App.Bundle.Identifier) -> UpdateProgressState {
    states[identifier] ?? .none
  }
  @MainActor func states(for identifier: Latest.App.Bundle.Identifier) -> AsyncStream<
    UpdateProgressState
  > {
    let state = state(for: identifier)
    return AsyncStream {
      $0.yield(state)
      $0.finish()
    }
  }
  @MainActor func stateChanges(for identifier: Latest.App.Bundle.Identifier) -> UpdateStateFeed {
    (state(for: identifier), states(for: identifier))
  }
}

/// Real app paths only for their icons; nothing on disk is read beyond that or changed.
@MainActor
private struct Round6Fixture {
  let coordinator = UpdateCheckCoordinator(
    check: { _, _ in throw LatestError.updateInfoUnavailable }, repositoryProvider: { nil })
  let store: AppDataStore
  let updating: Round6Updating

  init() {
    var states = [Latest.App.Bundle.Identifier: UpdateProgressState]()
    guard let store = coordinator.appProvider as? AppDataStore else {
      preconditionFailure("UpdateCheckCoordinator publishes an AppDataStore")
    }
    self.store = store
    func add(
      _ name: String, path: String, version: String, remote: String?, source: Latest.App.Source,
      bundleID: String? = nil, action: Latest.App.Update.Action = .builtIn { _ in },
      unknown: Bool = false, state: UpdateProgressState? = nil, days: Double = 0
    ) {
      let bundle = Latest.App.Bundle(
        version: Version(versionNumber: version, buildNumber: nil), name: name,
        bundleIdentifier: bundleID
          ?? "fixture.round6.\(name.replacingOccurrences(of: " ", with: "-"))",
        fileURL: URL(fileURLWithPath: path, isDirectory: true), source: source,
        modificationDate: Date(timeIntervalSince1970: 1_790_000_000 - days * 86_400))
      _ = store.set(appBundle: bundle)
      if let remote {
        _ = store.set(
          .success(
            Latest.App.Update(
              app: bundle, remoteVersion: Version(versionNumber: remote, buildNumber: nil),
              minimumOSVersion: nil, source: source,
              date: Date(timeIntervalSince1970: 1_790_000_000 - days * 86_400), releaseNotes: nil,
              updateAction: action, availabilityUnknown: unknown)), for: bundle)
      } else {
        _ = store.set(.failure(LatestError.updateInfoUnavailable), for: bundle)
      }
      if let state { states[bundle.identifier] = state }
    }
    add(
      "Goodnotes", path: "/Applications/Goodnotes.app", version: "7.1.32", remote: "7.1.34",
      source: .sparkle, days: 0)
    add(
      "Notion", path: "/Applications/Notion.app", version: "4.18.0", remote: "4.19.2",
      source: .homebrew, days: 1)
    add(
      "Microsoft Word", path: "/Applications/Microsoft Word.app", version: "16.102",
      remote: "16.103", source: .vendor, action: .vendorTool { _ in }, days: 2)
    add(
      "Audio Hijack", path: "/Applications/Audio Hijack.app", version: "4.5.2",
      remote: "4.5.3", source: .sparkle,
      state: .downloading(loadedSize: 12_400_000, totalSize: 38_000_000), days: 3)
    add(
      "Discord", path: "/Applications/Discord.app", version: "0.0.351", remote: "0.0.352",
      source: .homebrew,
      state: .error(
        UpdateOutcomeError(
          outcome: .failed(
            reason:
              "The download's signature didn't match the developer's, so nothing was changed.",
            logPath: nil))!), days: 4)
    add(
      "Google Chrome", path: "/Applications/Google Chrome.app", version: "156.0.8078.74",
      remote: "156.0.8078.80", source: .vendor, action: .relaunch { _ in }, days: 5)
    add(
      "Adobe Premiere Pro 2026",
      path: "/Applications/Adobe Premiere Pro 2026/Adobe Premiere Pro 2026.app", version: "26.0",
      remote: "26.0", source: .vendor, action: .external(label: "Creative Cloud") { _ in },
      unknown: true, days: 6)
    add(
      "Final Cut Pro", path: "/Applications/Final Cut Pro.app", version: "11.1",
      remote: "11.2", source: .appStore, action: .external(label: "App Store") { _ in }, days: 7)
    add(
      "OBS", path: "/Applications/OBS.app", version: "31.1.2", remote: "32.0.1",
      source: .homebrew,
      action: .external(label: HomebrewCheckerOperation.handOffLabel) { _ in }, days: 8)
    add(
      "Raycast", path: "/Applications/Raycast.app", version: "1.104.0", remote: "1.104.0",
      source: .sparkle, days: 9)
    add(
      "Rectangle", path: "/Applications/Rectangle.app", version: "0.91", remote: "0.91",
      source: .sparkle, days: 10)
    add(
      "Updater", path: "/Applications/JuniorOS Apps/Updater.app", version: "0.8.0",
      remote: nil, source: .none, bundleID: Foundation.Bundle.main.bundleIdentifier, days: 11)
    updating = Round6Updating(states: states)
  }
}
