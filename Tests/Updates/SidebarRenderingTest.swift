// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

// Exercise the shipping sidebar without opening a window or taking focus.
final class SidebarRenderingTest: XCTestCase {
  @MainActor
  func testEscapeCancelsQueuedFindButAllowsNextRequest() {
    let search = SearchFocusController()
    XCTAssertFalse(search.hasPendingRequest)
    search.focus()
    search.focus()
    XCTAssertTrue(search.hasPendingRequest)
    search.dismissRequest()
    XCTAssertFalse(search.hasPendingRequest)
    search.focus()
    XCTAssertTrue(search.hasPendingRequest)
  }

  @MainActor
  func testFindRequestIsConsumedOnceAcrossSidebarRecreation() {
    let search = SearchFocusController()
    search.focus()
    XCTAssertTrue(search.consumeRequest())
    XCTAssertFalse(search.hasPendingRequest)
    XCTAssertFalse(search.consumeRequest(), "Recreating a sidebar must not replay Find")
    search.focus()
    XCTAssertTrue(search.consumeRequest(), "A fresh Find command still focuses search")
  }

  func testRowSelectionHasValueSemantics() {
    let active = UpdateRowSelection(style: .active)
    var copy = active
    copy.style = .inactive
    XCTAssertTrue(active.usesActiveSelectionColors)
    XCTAssertFalse(copy.usesActiveSelectionColors)
    XCTAssertEqual(active, UpdateRowSelection(style: .active))
  }

  @MainActor
  func testIconsAreDisplaySizedCachedAndSeparateRowAndDetailSizes() async {
    let app = makeTestApp(name: "Nonexistent BAMA Icon Fixture", version: "1")
    let icon = await IconCache.shared.icon(for: app)
    XCTAssertTrue(IconCache.shared.cachedIcon(for: app) === icon)
    let refreshed = app.with(ignoredState: true)
    XCTAssertTrue(IconCache.shared.cachedIcon(for: refreshed) === icon)
    let cached = await IconCache.shared.icon(for: app)
    let detail = await IconCache.shared.icon(for: app, pointSize: 64)
    XCTAssertTrue(icon === cached)
    XCTAssertEqual(icon.size, NSSize(width: 40, height: 40))
    XCTAssertEqual(icon.representations.first?.pixelsWide, 80)
    XCTAssertEqual(icon.representations.first?.pixelsHigh, 80)
    XCTAssertEqual(detail.representations.first?.pixelsWide, 128)
    XCTAssertFalse(icon === detail)
  }

  @MainActor
  func testConcurrentIconRequestsShareWorkAndModifiedBundleInvalidatesCache() async {
    let app = makeTestApp(name: "Icon cache \(UUID().uuidString)", version: "1")
    async let first = IconCache.shared.icon(for: app)
    async let second = IconCache.shared.icon(for: app)
    let (firstImage, secondImage) = await (first, second)
    XCTAssertTrue(firstImage === secondImage, "Concurrent requests reuse the same load")
    let bundle = app.bundle
    let modified = app.with(
      bundle: App.Bundle(
        version: bundle.version, name: bundle.name, bundleIdentifier: bundle.bundleIdentifier,
        fileURL: bundle.fileURL, source: bundle.source,
        modificationDate: bundle.modificationDate.addingTimeInterval(1)))
    XCTAssertNotEqual(IconCache.shared.cacheKey(for: app), IconCache.shared.cacheKey(for: modified))
    XCTAssertNil(IconCache.shared.cachedIcon(for: modified))
    let modifiedImage = await IconCache.shared.icon(for: modified)
    XCTAssertFalse(firstImage === modifiedImage)
    XCTAssertTrue(IconCache.shared.cachedIcon(for: modified) === modifiedImage)
  }

  @MainActor
  func testRelativeAccessibleDatesAndNativeRowGeometry() async throws {
    XCTAssertTrue(UpdatesScrollList.dateFormatter.doesRelativeDateFormatting)
    let settings = try isolatedAppListSettings(for: self)
    let apps = ["Short", "A long application name wrapping the available sidebar width"].map {
      makeTestApp(name: $0, version: "1", remoteVersion: "2")
    }
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
      settings: settings)
    let host = NSHostingView(
      rootView: UpdatesSidebarView(
        viewModel: model, searchFocusController: SearchFocusController()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let fixture = try SidebarInputFixture(window: window, model: model)
    for index in 0..<fixture.table.numberOfRows {
      XCTAssertEqual(fixture.rowRect(index), fixture.table.rect(ofRow: index))
    }
    XCTAssertGreaterThan(fixture.rowRect(1).height, 0)
    XCTAssertEqual(fixture.rowRect(1).width, fixture.table.bounds.width)
  }

  @MainActor
  func testNativeListSupportsMultipleSelectionAndResizeOffscreen() async throws {
    let settings = try isolatedAppListSettings(for: self)
    let apps = ["Alpha", "Beta", "Gamma"].map {
      makeTestApp(name: $0, version: "1", remoteVersion: "2")
    }
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
      settings: settings)
    let host = NSHostingView(
      rootView: UpdatesSidebarView(
        viewModel: model, searchFocusController: SearchFocusController()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let table = try XCTUnwrap(host.descendant(of: NSTableView.self))
    XCTAssertTrue(table.allowsMultipleSelection)
    XCTAssertEqual(table.numberOfRows, 4, "One native section header and three app rows")
    table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.selectedAppIDs, Set(apps.prefix(2).map(\.identifier)))
    window.setContentSize(NSSize(width: 480, height: 400))
    host.layoutSubtreeIfNeeded()
    XCTAssertGreaterThan(table.bounds.width, 360)
    XCTAssertEqual(model.selectedAppIDs.count, 2)
    table.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(model.selectedAppIDs, [apps[2].identifier])
  }

  @MainActor
  func testUnchangedInstalledVersionRefreshesMountedSidebarMetadata() async throws {
    let settings = try isolatedAppListSettings(for: self)
    let suite = "OffscreenRows.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removeTestPersistentDomain(forName: suite) }
    let store = AppDataStore(userDefaults: defaults)
    let installed = makeTestApp(name: "Chrome", version: "154.0.8037.98")
    _ = store.set(appBundle: installed.bundle)
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: store.apps, filterQuery: nil, settings: settings),
      settings: settings, appProvider: store)
    model.startObserving()
    defer { model.stopObserving() }
    let host = NSHostingView(
      rootView: UpdatesSidebarView(
        viewModel: model, searchFocusController: SearchFocusController()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 308, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let fixture = try SidebarInputFixture(window: window, model: model)
    func paint() throws {
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    try paint()
    try await Task.sleep(for: .milliseconds(150))
    model.select(installed)
    let identifier = "updates.app.\(installed.identifier)"
    XCTAssertTrue(
      fixture.accessibilityElements().contains { $0.accessibilityIdentifier() == identifier })
    for version in ["155.0.8059.40", "155.0.8059.41"] {
      let update = App.Update(
        app: installed.bundle, remoteVersion: Version(versionNumber: version, buildNumber: nil),
        minimumOSVersion: nil, source: .appStore, date: installed.updateDate,
        releaseNotes: installed.releaseNotes, updateAction: .builtIn { _ in })
      let refreshed = store.set(.success(update), for: installed.bundle)
      let deadline = ContinuousClock.now + .seconds(2)
      var label: String?
      repeat {
        try await Task.sleep(for: .milliseconds(10))
        try paint()
        label = fixture.accessibilityElements().first {
          $0.accessibilityIdentifier() == identifier
        }?.accessibilityLabel()
      } while label?.contains(version) != true && ContinuousClock.now < deadline
      XCTAssertTrue(model.selectedApp === refreshed)
      XCTAssertTrue(
        label?.contains(version) == true, "Shipping sidebar label: \(label ?? "missing")")
    }
  }
}
