// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

final class SidebarAppearanceTest: XCTestCase {
  @MainActor
  func testSidebarRefreshesNewVersionForSameInstalledApp() async throws {
    try requireUITests()
    let settings = try isolatedAppListSettings(for: self)
    let suite = "SidebarVersions.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppDataStore(userDefaults: defaults)
    let installed = makeTestApp(name: "Chrome", version: "154.0.8037.98")
    _ = store.set(appBundle: installed.bundle)
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: store.apps, filterQuery: nil, settings: settings),
      settings: settings, appProvider: store)
    model.startObserving()
    defer { model.stopObserving() }
    let environment = AppEnvironment(settings: settings, updatesListViewModel: model)
    let window = try await makeLatestTestWindow(environment: environment, testCase: self)
    defer { window.close() }
    let fixture = try SidebarInputFixture(window: window, model: model)
    model.select(installed)
    for remoteVersion in ["155.0.8059.40", "155.0.8059.41"] {
      let update = App.Update(
        app: installed.bundle,
        remoteVersion: Version(versionNumber: remoteVersion, buildNumber: nil),
        minimumOSVersion: nil, source: .appStore, date: installed.updateDate,
        releaseNotes: installed.releaseNotes, updateAction: .builtIn { _ in })
      let refreshed = store.set(.success(update), for: installed.bundle)
      let deadline = ContinuousClock.now + .seconds(3)
      while model.selectedApp !== refreshed && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertTrue(model.selectedApp === refreshed)
      let bitmap = try await fixture.captureRow(for: refreshed)
      let expectedNew = try XCTUnwrap(refreshed.localizedVersionInformation?.new)
      XCTAssertTrue(
        fixture.accessibilityElements().contains {
          $0.accessibilityIdentifier() == "updates.app.\(refreshed.identifier)"
            && $0.accessibilityLabel()?.contains(remoteVersion) == true
        },
        "The row must expose the refreshed available version")
      try assertVersionGlyphs(expectedNew, in: bitmap, top: 38)
      let attachment = XCTAttachment(
        image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: bitmap.size))
      attachment.name = "chrome-row-new-version-\(remoteVersion)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  @MainActor
  func testSidebarShowsLongInstalledVersionWithoutTruncationAtIdealWidth() async throws {
    try requireUITests()
    let app = makeTestApp(name: "Chrome", version: "151.0.7922.109")
    let expectedVersion = try XCTUnwrap(app.localizedVersionInformation?.current)
    let fixture = try await SidebarInputFixture.make(apps: [app], testCase: self)
    defer { fixture.window.close() }
    let bitmap = try await fixture.captureRow(for: app)
    try assertVersionGlyphs(expectedVersion, in: bitmap, top: 31)
  }

  @MainActor
  func testSidebarTextColorsFollowSelectionEmphasis() throws {
    try requireUITests()
    try runApplicationTest { try await self.checkSidebarTextColorsFollowSelectionEmphasis() }
  }

  @MainActor
  private func checkSidebarTextColorsFollowSelectionEmphasis() async throws {
    let app = makeTestApp(name: "Discord", version: "0.0.398", remoteVersion: "0.0.399")
    let search = SearchFocusController()
    let fixture = try await SidebarInputFixture.make(
      apps: [app], selected: app, searchFocusController: search, testCase: self)
    defer { fixture.window.close() }
    try await fixture.activate()
    try fixture.click(row: XCTUnwrap(fixture.model.snapshot.firstIndex(of: app)))
    for emphasized in [true, false] {
      if !emphasized {
        // Transfer actual focus within the same production scene. Calling
        // resignKey on a newly opened window did not establish this state.
        search.focus()
        let deadline = ContinuousClock.now + .seconds(1)
        while !(fixture.window.firstResponder is NSTextView) && ContinuousClock.now < deadline {
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(fixture.window.firstResponder is NSTextView, "Search must own keyboard focus")
      }
      try await Task.sleep(for: .milliseconds(100))
      let bitmap = try await fixture.captureRow(for: app)
      var expectedGlyphPixels = 0
      let backing = try XCTUnwrap(bitmap.colorAt(x: 440, y: 104)?.usingColorSpace(.sRGB))
      for y in 18..<46 {
        for x in 116..<220 {
          let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
          // The real system label is not absolute black. Check its contrast
          // with the selection fill in one color space, not device-RGB values.
          let contrast =
            emphasized
            ? color.redComponent - backing.redComponent
            : backing.redComponent - color.redComponent
          if contrast > 0.4 {
            expectedGlyphPixels += 1
          }
        }
      }
      if expectedGlyphPixels <= 50 {
        let attachment = XCTAttachment(
          image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: bitmap.size))
        attachment.name = "production-row-emphasis-\(emphasized)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      XCTAssertGreaterThan(
        expectedGlyphPixels, 50, "Incorrect title color with emphasis=\(emphasized)")
    }
  }

  @MainActor
  private func assertVersionGlyphs(_ version: String, in bitmap: NSBitmapImageRep, top: Int) throws
  {
    let referenceBitmap = try nativeVersionReference(version, y: CGFloat(60 - top - 14))
    var missingGlyphPixels = 0
    var glyphPixels = 0
    let backing = try XCTUnwrap(bitmap.colorAt(x: 600, y: 0)?.usingColorSpace(.deviceRGB))
      .redComponent
    for y in (top * 2)..<((top + 14) * 2) {
      for x in 116..<540 {
        let reference = try XCTUnwrap(
          referenceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        guard reference.alphaComponent > 0.15 else { continue }
        glyphPixels += 1
        // Text and NSTextField may snap coverage to adjacent pixels. Require
        // every native glyph pixel to have matching ink within one pixel.
        var foundInk = false
        for dy in -1...1 {
          for dx in -1...1 {
            let actual = try XCTUnwrap(
              bitmap.colorAt(x: x + dx, y: y + dy)?.usingColorSpace(.deviceRGB))
            if backing - actual.redComponent > 0.08 { foundInk = true }
          }
        }
        if !foundInk { missingGlyphPixels += 1 }
      }
    }
    XCTAssertGreaterThan(
      glyphPixels, 100, "Native text reference must contain the complete version")
    XCTAssertEqual(missingGlyphPixels, 0, "The version must paint every native glyph: \(version)")
  }

  @MainActor
  private func nativeVersionReference(_ version: String, y: CGFloat) throws -> NSBitmapImageRep {
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 308, height: 60))
    host.appearance = NSAppearance(named: .aqua)
    let reference = NSTextField(labelWithString: version)
    reference.font = NSFont.systemFont(ofSize: 11)
    reference.textColor = .secondaryLabelColor
    // NSTextField has 2pt of leading padding relative to the production Text.
    reference.frame = NSRect(x: 56, y: y, width: 216, height: 14)
    host.addSubview(reference)
    let bitmap = try XCTUnwrap(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 616, pixelsHigh: 120,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = host.frame.size
    host.cacheDisplay(in: host.bounds, to: bitmap)
    return bitmap
  }
}
