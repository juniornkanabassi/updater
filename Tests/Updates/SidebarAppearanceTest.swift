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
    defer { defaults.removeTestPersistentDomain(forName: suite) }
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
      let expectedNew = try XCTUnwrap(refreshed.localizedVersionInformation?.new)
      XCTAssertTrue(
        fixture.accessibilityElements().contains {
          $0.accessibilityIdentifier() == "updates.app.\(refreshed.identifier)"
            && $0.accessibilityLabel()?.contains(remoteVersion) == true
        },
        "The row must expose the refreshed available version")
      try assertVersionLabel(expectedNew, for: refreshed, in: fixture)
    }
  }

  @MainActor
  func testSidebarShowsLongInstalledVersionWithoutTruncationAtIdealWidth() async throws {
    try requireUITests()
    let app = makeTestApp(name: "Chrome", version: "151.0.7922.109")
    let expectedVersion = try XCTUnwrap(app.localizedVersionInformation?.current)
    let fixture = try await SidebarInputFixture.make(apps: [app], testCase: self)
    defer { fixture.window.close() }
    try assertVersionLabel(expectedVersion, for: app, in: fixture)
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
      let rowFrame = try fixture.contentFrame(for: app)
      let titleFrame = try fixture.frame(for: "updates.title.\(app.identifier)")
      let scale = CGFloat(bitmap.pixelsWide) / rowFrame.width
      let titlePixels = CGRect(
        x: (titleFrame.minX - rowFrame.minX) * scale,
        y: (rowFrame.maxY - titleFrame.maxY) * scale,
        width: titleFrame.width * scale, height: titleFrame.height * scale)
      let backing = try XCTUnwrap(
        bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh - 2)?.usingColorSpace(.sRGB))
      for y in max(0, Int(titlePixels.minY))..<min(bitmap.pixelsHigh, Int(titlePixels.maxY)) {
        for x in max(0, Int(titlePixels.minX))..<min(bitmap.pixelsWide, Int(titlePixels.maxX)) {
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
  private func assertVersionLabel(
    _ version: String, for app: Latest.App, in fixture: SidebarInputFixture
  ) throws {
    let identifier = "updates.version.\(app.identifier)"
    let label = try XCTUnwrap(
      fixture.accessibilityElements().first {
        $0.accessibilityIdentifier() == identifier
      })
    XCTAssertTrue(label.accessibilityLabel()?.contains(version) == true)
    let frame = try fixture.frame(for: identifier)
    let row = try fixture.contentFrame(for: app)
    XCTAssertTrue(row.contains(frame), "The version must fit inside its native row")
    let font = NSFont.monospacedDigitSystemFont(
      ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular)
    let visibleVersion =
      app.updateAvailable
      ? app.localizedVersionInformation?.rawNew ?? app.versionSummary : app.versionSummary
    let requiredWidth = (visibleVersion as NSString).size(withAttributes: [.font: font]).width
    XCTAssertGreaterThanOrEqual(frame.width + 1, requiredWidth, "The full version must fit")
  }
}
