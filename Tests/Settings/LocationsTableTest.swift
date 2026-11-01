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
