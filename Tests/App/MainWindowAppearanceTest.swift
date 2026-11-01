// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import Latest

final class MainWindowAppearanceTest: XCTestCase {
  @MainActor
  func testProductionWindowStates() throws {
    try requireUITests()
    try runApplicationTest { try await self.checkProductionWindowStates() }
  }

  @MainActor
  private func checkProductionWindowStates() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let output = root.appendingPathComponent(
      "build/production-visuals/main-window-scene", isDirectory: true)
    let reference = root.appendingPathComponent(
      "build/production-visual-reference/main-window-scene-inactive", isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: reference.path),
      "Production appearance requires same-host originals in \(reference.path)")
    for dark in [false, true] {
      for state in ["initial", "selection", "search", "downloading", "pinned"] {
        let suite = "MainWindowAppearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppListSettings(userDefaults: defaults)
        let apps = LocalUATFixture.apps
        let model = UpdatesListViewModel(
          snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
          settings: settings
        )
        model.select(apps[0])
        if state == "selection" { model.select(apps[3]) }
        if state == "search" { model.setSearchQuery("Notes") }
        var operation: UpdateOperation?
        if state == "downloading" {
          let started = expectation(description: "Visual fixture operation started")
          let updating = ProductionCaptureOperation(app: apps[0], started: started)
          UpdateQueue.shared.addOperation(updating)
          await fulfillment(of: [started], timeout: 2)
          updating.progressState = .downloading(loadedSize: 25_000_000, totalSize: 100_000_000)
          operation = updating
        }
        defer {
          operation?.finish()
        }
        let environment = AppEnvironment(settings: settings, updatesListViewModel: model)
        try await deactivateTestApplication()
        let window = try await makeLatestTestWindow(
          environment: environment, dark: dark, activate: false, testCase: self)
        // Native materials sample the window's backdrop. Keep position and
        // key-window state explicit so earlier input tests cannot change the reference.
        let screen = try XCTUnwrap(window.screen)
        window.setFrameOrigin(
          NSPoint(
            x: screen.visibleFrame.minX + 80,
            y: screen.visibleFrame.maxY - window.frame.height - 80))
        // Native bar materials sample beyond the target window. Cover the
        // screen so their input cannot include the user's foreground content.
        let backdrop = NSWindow(
          contentRect: screen.frame,
          styleMask: [.borderless], backing: .buffered, defer: false)
        backdrop.isReleasedWhenClosed = false
        backdrop.backgroundColor = dark ? .black : .white
        backdrop.isOpaque = true
        backdrop.ignoresMouseEvents = true
        backdrop.order(.below, relativeTo: window.windowNumber)
        defer { backdrop.close() }
        try await deactivateTestApplication()
        XCTAssertFalse(window.isKeyWindow)
        let view = try XCTUnwrap(window.contentView)
        defer { window.close() }
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let web = try XCTUnwrap(view.descendant(of: WKWebView.self))
        try await waitForWebPaint(web)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        let sidebar = try SidebarInputFixture(window: window, model: model)
        let expectedApp = state == "selection" ? apps[3] : apps[0]
        XCTAssertEqual(sidebar.selectedRow, model.snapshot.firstIndex(of: expectedApp))
        let body = try await web.evaluateJavaScript("document.body.innerText") as? String
        XCTAssertTrue(body?.contains("Offline acceptance fixture for \(expectedApp.name).") == true)
        if state == "search" {
          XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["Notes"])
        }
        if state == "pinned" {
          let scroll = sidebar.scroll
          sidebar.scroll(to: 240)
          try await Task.sleep(for: .milliseconds(100))
          XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        }
        // One WindowServer capture covers native chrome, material-composited
        // sidebar, detail and WebKit together. View-cache captures omitted the
        // sidebar and required a redundant second table-only image.
        let bitmap = try await settledWindowBitmap(window)
        try record(
          bitmap, name: "window-\(state)-\(dark ? "dark" : "light").png",
          output: output, reference: reference)
      }
    }
  }

  private func record(
    _ bitmap: NSBitmapImageRep, name: String, output: URL, reference: URL
  ) throws {
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: output.appendingPathComponent(name), options: .atomic)
    let baseline = try XCTUnwrap(
      NSBitmapImageRep(data: Data(contentsOf: reference.appendingPathComponent(name))))
    XCTAssertEqual(bitmap.pixelsWide, baseline.pixelsWide, name)
    XCTAssertEqual(bitmap.pixelsHigh, baseline.pixelsHigh, name)
    XCTAssertTrue(try rgba(bitmap) == rgba(baseline), "Every pixel must match: \(name)")
  }
}

private final class ProductionCaptureOperation: UpdateOperation, @unchecked Sendable {
  private let started: XCTestExpectation
  init(app: Latest.App, started: XCTestExpectation) {
    self.started = started
    super.init(bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
  }
  override func execute() {
    super.execute()
    started.fulfill()
  }
}
