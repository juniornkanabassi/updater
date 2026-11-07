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
  func testLongVersionPairKeepsTheCompleteNewVersionAtIdealSidebarWidth() async throws {
    let settings = try isolatedAppListSettings(for: self)
    let app = makeTestApp(
      name: "Google Chrome", version: "156.0.8078.74", remoteVersion: "156.0.8078.80")
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [app], filterQuery: nil, settings: settings),
      settings: settings)
    let host = NSHostingView(
      rootView: UpdatesSidebarView(
        viewModel: model, searchFocusController: SearchFocusController()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: VisualMetrics.sidebarIdealWidth, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let fixture = try SidebarInputFixture(window: window, model: model)
    let identifier = "updates.version.\(app.identifier)"
    let label = try XCTUnwrap(
      fixture.accessibilityElements().first { $0.accessibilityIdentifier() == identifier })
    XCTAssertEqual(label.accessibilityLabel(), "156.0.8078.74 to 156.0.8078.80")
    let frame = try fixture.frame(for: identifier)
    let row = try fixture.contentFrame(for: app)
    XCTAssertTrue(row.contains(frame), "The displayed version must fit inside the row")
    let font = NSFont.monospacedDigitSystemFont(
      ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
    let fullWidth = (app.versionSummary as NSString).size(withAttributes: [.font: font]).width
    let newWidth = ("→ 156.0.8078.80" as NSString).size(withAttributes: [.font: font]).width
    XCTAssertLessThan(
      frame.width, fullWidth, "The native layout should use its compact new-version fallback")
    XCTAssertGreaterThanOrEqual(
      frame.width + 1, newWidth, "The complete new version must remain visible")
  }

  @MainActor
  func testLastResultRemainsVisibleWithReleaseNotesAndRefreshesFromHistory() async throws {
    let enhancedAccessibility = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    let previousAccessibility = NSApp.accessibilityAttributeValue(enhancedAccessibility) ?? false
    NSApp.accessibilitySetValue(true, forAttribute: enhancedAccessibility)
    defer {
      NSApp.accessibilitySetValue(previousAccessibility, forAttribute: enhancedAccessibility)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let history = UpdateHistoryStore(fileURL: directory.appendingPathComponent("history.jsonl"))
    let app = makeTestApp(name: "Notes History", version: "2")
    let host = NSHostingView(
      rootView: ReleaseNotesDetailSurface(
        app: app, contentState: .text(ReleaseNotesContent(string: "Visible release notes")),
        history: history))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    func hasLastResult() -> Bool {
      var seen = Set<ObjectIdentifier>()
      func find(_ value: Any) -> Bool {
        guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else {
          return false
        }
        let element = SidebarAccessibilityElement(object: object)
        if element.accessibilityIdentifier() == "detail.lastResult" { return true }
        return (element.accessibilityChildren() ?? []).contains(where: find)
          || ((object as? NSView)?.subviews ?? []).contains(where: find)
      }
      return find(host)
    }
    XCTAssertFalse(hasLastResult())
    history.record(
      UpdateHistoryEntry(
        before: app.bundle, after: app.bundle, outcome: .updated(from: "1", to: "2")))
    for _ in 0..<100 where !hasLastResult() {
      try await Task.sleep(for: .milliseconds(5))
      host.layoutSubtreeIfNeeded()
    }
    XCTAssertTrue(hasLastResult(), "Last result must be available without hiding release notes")
  }

  @MainActor
  func testNativeTableCommandsRepeatReverseClampAndTargetRowsOffscreen() async throws {
    let settings = try isolatedAppListSettings(for: self)
    let apps = (0..<24).map { index in
      makeTestApp(
        name: String(format: "App %02d with a deliberately long application name", index),
        version: "123.456.789.100", remoteVersion: "124.456.789.100")
    }
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
      settings: settings)
    let host = NSHostingView(
      rootView: UpdatesSidebarView(
        viewModel: model, searchFocusController: SearchFocusController()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(window.alphaValue, 0)
    XCTAssertFalse(window.isKeyWindow)
    let fixture = try SidebarInputFixture(window: window, model: model)
    let table = fixture.table
    XCTAssertEqual(table.numberOfRows, apps.count + 1)

    func assertSelection(_ row: Int, _ message: String) async throws {
      let expected = apps[row - 1].identifier
      let deadline = ContinuousClock.now + .seconds(1)
      while model.selectedAppIDs != [expected] && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
      }
      XCTAssertEqual(table.selectedRow, row, message)
      XCTAssertEqual(model.selectedAppIDs, [expected], "Native selection binding: \(message)")
    }

    func pressArrow(down: Bool) throws {
      let character = down ? "\u{F701}" : "\u{F700}"
      let event = try XCTUnwrap(
        NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, characters: character, charactersIgnoringModifiers: character,
          isARepeat: true, keyCode: down ? 125 : 126))
      // Supply the native keyboard entrypoint with its event; do not activate or post globally.
      table.keyDown(with: event)
    }

    print("NATIVE_NAV initial selection")
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    try await assertSelection(1, "Initial native selection")
    print("NATIVE_NAV repeated down")
    for _ in 0..<6 {
      try pressArrow(down: true)
      try await Task.sleep(for: .milliseconds(5))
    }
    try await assertSelection(7, "Repeated moveDown")
    print("NATIVE_NAV reversal")
    for _ in 0..<3 {
      try pressArrow(down: false)
      try await Task.sleep(for: .milliseconds(5))
    }
    try await assertSelection(4, "Immediate reversal")
    print("NATIVE_NAV bottom edge")
    for _ in 0..<(apps.count * 2) {
      try pressArrow(down: true)
      try await Task.sleep(for: .milliseconds(5))
    }
    try await assertSelection(apps.count, "Bottom edge")
    print("NATIVE_NAV top edge")
    for _ in 0..<(apps.count * 2) {
      try pressArrow(down: false)
      try await Task.sleep(for: .milliseconds(5))
    }
    try await assertSelection(1, "Top edge skips the section header")

    print("NATIVE_NAV three-line geometry")
    table.scrollRowToVisible(1)
    host.layoutSubtreeIfNeeded()
    let first = table.rect(ofRow: 1)
    let next = table.rect(ofRow: 2)
    XCTAssertGreaterThanOrEqual(first.height, VisualMetrics.appRowHeight)
    XCTAssertLessThanOrEqual(first.maxY, next.minY, "Three-line rows must not overlap")
    let row = try fixture.contentFrame(for: apps[0])
    let title = try fixture.frame(for: "updates.title.\(apps[0].identifier)")
    let version = try fixture.frame(for: "updates.version.\(apps[0].identifier)")
    let statusFrame = try fixture.frame(for: "updates.status.\(apps[0].identifier)")
    for textFrame in [title, version, statusFrame] {
      XCTAssertTrue(row.contains(textFrame), "Each of the three text lines must fit its row")
    }
    XCTAssertGreaterThanOrEqual(title.minY, version.maxY)
    XCTAssertGreaterThanOrEqual(version.minY, statusFrame.maxY)

    print("NATIVE_NAV pinned header and targeting")
    let targetRow = 18
    table.scrollRowToVisible(targetRow)
    host.layoutSubtreeIfNeeded()
    XCTAssertTrue(table.floatsGroupRows, "Native sidebar must keep group headers visible")
    let groupView = try XCTUnwrap(table.rowView(atRow: 0, makeIfNecessary: false))
    let groupFrame = groupView.convert(groupView.bounds, to: table)
    XCTAssertTrue(
      groupFrame.intersects(table.visibleRect),
      "The group header must remain visible after scrolling")
    XCTAssertLessThanOrEqual(groupFrame.minY, table.visibleRect.minY + groupFrame.height)
    let target = table.rect(ofRow: targetRow)
    let pointInClip = fixture.scroll.contentView.convert(
      NSPoint(x: target.midX, y: target.midY), from: table)
    XCTAssertTrue(fixture.scroll.contentView.bounds.contains(pointInClip))
    let hit = table.row(at: table.convert(pointInClip, from: fixture.scroll.contentView))
    XCTAssertEqual(hit, targetRow, "Hit testing must follow native scrolling")
    table.selectRowIndexes(IndexSet(integer: hit), byExtendingSelection: false)
    try await assertSelection(targetRow, "Targeted row after scrolling")
    print("NATIVE_NAV complete")
    XCTAssertEqual(window.alphaValue, 0)
    XCTAssertFalse(window.isKeyWindow)
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
