// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

final class ReleaseNotesHeaderLayoutTest: XCTestCase {
  @MainActor
  func testOptionalDatePreservesTwoLineHeaderAlignment() throws {
    func render(date: Date?) throws -> NSBitmapImageRep {
      let app = makeTestApp(name: "Example", version: "1.0", date: date)
      let host = NSHostingView(
        rootView: ReleaseNotesHeaderView(app: app, showsSupportStatus: false))
      host.appearance = NSAppearance(named: .aqua)
      host.frame = NSRect(x: 0, y: 0, width: 460, height: VisualMetrics.detailHeaderHeight)
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      return bitmap
    }

    let twoLines = try render(date: nil)
    let threeLines = try render(date: Date(timeIntervalSince1970: 1_750_000_000))
    XCTAssertEqual(twoLines.pixelsWide, threeLines.pixelsWide)
    XCTAssertEqual(twoLines.pixelsHigh, threeLines.pixelsHigh)
    let scale = CGFloat(twoLines.pixelsWide) / 460
    var changedAboveDate = 0
    var changedBelowVersion = 0
    // Compare the actual title/version pixels, excluding the asynchronously loaded icon.
    for y in 0..<twoLines.pixelsHigh {
      for x in Int(94 * scale)..<Int(260 * scale) {
        if twoLines.colorAt(x: x, y: y) != threeLines.colorAt(x: x, y: y) {
          if CGFloat(y) / scale < 45 {
            changedAboveDate += 1
          } else {
            changedBelowVersion += 1
          }
        }
      }
    }
    XCTAssertEqual(changedAboveDate, 0, "Adding a date must not move the title or version")
    XCTAssertGreaterThan(changedBelowVersion, 0, "The date must remain visible below the version")
  }
}
