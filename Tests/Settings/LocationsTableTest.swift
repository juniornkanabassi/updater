// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

final class LocationsTableTest: XCTestCase {
  @MainActor
  func testNativeLocationsTableOwnsSelectionAndRowSemantics() throws {
    let applicationsURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let unavailableURL = URL(fileURLWithPath: "/Volumes/Unavailable Apps", isDirectory: true)
    let selection = SelectionBox()
    let view = DirectoryLocationsTable(
      urls: [applicationsURL, unavailableURL],
      selection: Binding(
        get: { selection.url },
        set: { selection.url = $0 }
      ),
      loadDetails: { url in
        DirectoryLocationDetails(
          isReachable: url == applicationsURL,
          appCount: url == applicationsURL ? 38 : 0
        )
      }
    )
    let hostingView = NSHostingView(rootView: view)
    hostingView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    let window = NSWindow(
      contentRect: hostingView.bounds,
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = hostingView
    defer { window.close() }
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

    let tableView = try XCTUnwrap(hostingView.descendant(of: NSTableView.self))
    XCTAssertEqual(tableView.numberOfRows, 2)
    tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    XCTAssertEqual(selection.url, unavailableURL)

    XCTAssertEqual(
      DirectoryLocationPresentation.accessibilityLabel(
        for: applicationsURL,
        details: DirectoryLocationDetails(isReachable: true, appCount: 38)
      ),
      "/Applications, 38 applications"
    )
    XCTAssertEqual(
      DirectoryLocationPresentation.accessibilityLabel(
        for: unavailableURL,
        details: DirectoryLocationDetails(isReachable: false, appCount: 0)
      ),
      "/Volumes/Unavailable Apps, unavailable, 0 applications"
    )
  }
}

@MainActor
private final class SelectionBox {
  var url: URL?
}

extension LocationsTableTest {
  @MainActor
  func testLocationsFormProvidesScrollableViewportOffscreen() async throws {
    let store = UndoDirectoryStore()
    for index in 0..<30 {
      store.add(URL(fileURLWithPath: "/tmp/LocationWheelFixture/Folder-\(index)"))
    }
    let model = SettingsViewModel(
      settings: try isolatedAppListSettings(for: self),
      installHelperService: HelperRegistrationFixture(), directoryStoreFactory: { _ in store })
    let host = NSHostingView(rootView: LocationsSettingsView(viewModel: model))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    func locationsTable(in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView, table.numberOfRows == model.directoryURLs.count {
        return table
      }
      return view.subviews.lazy.compactMap { locationsTable(in: $0) }.first
    }
    let table = try XCTUnwrap(locationsTable(in: host))
    XCTAssertEqual(table.numberOfRows, model.directoryURLs.count)
    let scroll = try XCTUnwrap(table.enclosingScrollView)
    XCTAssertGreaterThan(table.bounds.height, scroll.contentView.bounds.height)
    let lastRow = table.rect(ofRow: table.numberOfRows - 1)
    // Offscreen windows do not route wheel events; verify the available scroll range.
    scroll.contentView.scroll(to: NSPoint(x: 0, y: lastRow.maxY - scroll.contentView.bounds.height))
    scroll.reflectScrolledClipView(scroll.contentView)
    XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
    XCTAssertTrue(scroll.documentVisibleRect.intersects(lastRow))
  }

  @MainActor
  func testRealDirectoryStoreRestoresMiddleLocationInIsolatedDefaults() throws {
    let suite = "DirectoryOrder.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppDirectoryStore(defaults: defaults, updateHandler: {})
    let urls = ["First", "Middle", "Last"].map {
      URL(fileURLWithPath: "/tmp/\(suite)/\($0)", isDirectory: true)
    }
    urls.forEach(store.add)
    let original = store.URLs
    let index = try XCTUnwrap(original.firstIndex(of: urls[1]))
    store.remove(urls[1])
    store.insert(urls[1], at: index)
    XCTAssertEqual(store.URLs, original)
    store.insert(urls[1], at: index)
    XCTAssertEqual(store.URLs, original, "Restoring twice must not duplicate a location")
  }

  @MainActor
  func testRestoreOrderWithDuplicateStoredDefaultsAndCustomLocations() throws {
    let suite = "DuplicateDirectoryOrder.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppDirectoryStore(defaults: defaults, updateHandler: {})
    let urls = ["First", "Middle", "Last"].map {
      URL(fileURLWithPath: "/tmp/\(suite)/\($0)", isDirectory: true)
    }
    defaults.directoryPaths = (store.URLs + [urls[0], urls[0], urls[1], urls[2]]).map(\.path)
    let original = store.URLs
    let index = try XCTUnwrap(original.firstIndex(of: urls[1]))
    store.remove(urls[1])
    store.insert(urls[1], at: index)
    XCTAssertEqual(store.URLs, original)
  }

  @MainActor
  func testUndoDoesNotRegisterRedoForManuallyReaddedLocation() throws {
    let store = UndoDirectoryStore()
    let model = SettingsViewModel(
      settings: try isolatedAppListSettings(for: self),
      installHelperService: HelperRegistrationFixture(), directoryStoreFactory: { _ in store })
    let undo = UndoManager()
    undo.groupsByEvent = false
    model.selectedDirectory = store.custom
    undo.beginUndoGrouping()
    model.removeSelectedDirectory(undoManager: undo)
    undo.endUndoGrouping()
    model.addDirectories([store.custom])
    undo.undo()
    XCTAssertFalse(undo.canRedo)
    XCTAssertTrue(model.directoryURLs.contains(store.custom))
  }

  @MainActor
  func testRemoveLocationSupportsUndoRedoAndProtectsDefaultFolders() throws {
    let store = UndoDirectoryStore()
    let model = SettingsViewModel(
      settings: try isolatedAppListSettings(for: self),
      installHelperService: HelperRegistrationFixture(), directoryStoreFactory: { _ in store })
    let undo = UndoManager()
    let originalOrder = model.directoryURLs
    undo.groupsByEvent = false
    model.selectedDirectory = store.custom
    undo.beginUndoGrouping()
    model.removeSelectedDirectory(undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertFalse(model.directoryURLs.contains(store.custom))
    XCTAssertNil(model.selectedDirectory)
    undo.undo()
    XCTAssertTrue(model.directoryURLs.contains(store.custom))
    XCTAssertEqual(model.directoryURLs, originalOrder)
    XCTAssertEqual(model.selectedDirectory, store.custom)
    undo.redo()
    XCTAssertFalse(model.directoryURLs.contains(store.custom))
    model.selectedDirectory = store.protected
    undo.beginUndoGrouping()
    model.removeSelectedDirectory(undoManager: undo)
    undo.endUndoGrouping()
    XCTAssertTrue(model.directoryURLs.contains(store.protected))
  }

}

private final class UndoDirectoryStore: AppDirectoryStoring {
  let protected = URL(fileURLWithPath: "/tmp/Protected Fixture Apps")
  let custom = URL(fileURLWithPath: "/tmp/Custom Fixture Apps")
  private(set) lazy var URLs = [protected, custom, URL(fileURLWithPath: "/tmp/Last Fixture Apps")]
  func add(_ url: URL) { if !URLs.contains(url) { URLs.append(url) } }
  func insert(_ url: URL, at index: Int) { URLs.insert(url, at: min(index, URLs.count)) }
  func remove(_ url: URL) { URLs.removeAll { $0 == url } }
  func canRemove(_ url: URL) -> Bool { url != protected && URLs.contains(url) }
  func isReachable(_ url: URL) -> Bool { false }
}
