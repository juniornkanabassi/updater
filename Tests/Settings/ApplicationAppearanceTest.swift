// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

final class ApplicationAppearanceTest: XCTestCase {
  func testApplicationAppearanceResolvesStoredPreference() {
    XCTAssertNil(ApplicationAppearance.system.appKitAppearanceName)
    XCTAssertEqual(ApplicationAppearance.light.appKitAppearanceName, .aqua)
    XCTAssertEqual(ApplicationAppearance.dark.appKitAppearanceName, .darkAqua)
    XCTAssertEqual(ApplicationAppearance.resolve("dark"), .dark)
    XCTAssertEqual(ApplicationAppearance.resolve("invalid"), .system)
    XCTAssertEqual(ApplicationAppearance.allCases.map(\.title), ["System", "Light", "Dark"])
  }

  @MainActor
  func testApplicationAppearanceCanReturnFromDarkToSystem() {
    let application = NSApplication.shared
    let originalAppearance = application.appearance
    defer { application.appearance = originalAppearance }

    ApplicationAppearance.dark.apply(to: application)
    XCTAssertEqual(application.appearance?.name, .darkAqua)

    ApplicationAppearance.system.apply(to: application)
    XCTAssertNil(application.appearance)
  }
}
