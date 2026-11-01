// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import Latest

final class ToolbarInteractionTest: XCTestCase {
  @MainActor
  func testToolbarScanBecomesVisibleLinearProgressAndClearsOnCompletion() async throws {
    try requireUITests()
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let set =
      (try? String(
        contentsOf: root.appendingPathComponent("build/sidebar-control-capture-set"),
        encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "current"
    let output = root.appendingPathComponent("build/toolbar-control-\(set)")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for dark in [false, true] {
      let environment = AppEnvironment.localUATFixture(
        settings: try isolatedAppListSettings(for: self))
      let service = environment.updateCheckingService
      let coordinator = UpdateCheckCoordinator()
      let window = try await makeLatestTestWindow(
        environment: environment, dark: dark, testCase: self)
      defer { window.close() }
      let sidebar = try SidebarInputFixture(window: window, model: environment.updatesListViewModel)
      try await sidebar.activate()
      let web = try XCTUnwrap(window.contentView?.descendant(of: WKWebView.self))
      try await waitForWebPaint(web)
      var captures: [String: NSBitmapImageRep] = [:]
      for state in ["idle", "scanning", "zero", "quarter", "three-quarters", "finished"] {
        switch state {
        case "idle": break
        case "scanning": service.updateCheckerDidStartScanningForApps(coordinator)
        case "zero":
          service.updateChecker(coordinator, didStartCheckingApps: 4, generation: 1)
        case "quarter":
          service.updateChecker(coordinator, didCheckApp: LocalUATFixture.apps[0])
        case "three-quarters":
          for app in LocalUATFixture.apps[1...2] {
            service.updateChecker(coordinator, didCheckApp: app)
          }
        default: service.updateCheckerDidFinishCheckingForUpdates(coordinator, generation: 1)
        }
        try await Task.sleep(for: .milliseconds(350))
        window.layoutIfNeeded()
        let bitmap = try await settledWindowBitmap(window)
        let toolbar = try XCTUnwrap(
          bitmap.cgImage?.cropping(
            to: CGRect(
              x: bitmap.pixelsWide - 440, y: 0, width: 440, height: 110)))
        let crop = NSBitmapImageRep(cgImage: toolbar)
        let name = "\(dark ? "dark" : "light")-\(state)"
        try XCTUnwrap(crop.representation(using: .png, properties: [:])).write(
          to: output.appendingPathComponent("\(name).png"))
        captures[state] = crop
      }
      func difference(_ first: String, _ second: String, x: Int, y: Int) throws -> CGFloat {
        let a = try XCTUnwrap(captures[first]?.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        let b = try XCTUnwrap(captures[second]?.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        return max(
          abs(a.redComponent - b.redComponent),
          abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
      }
      // Native toolbars use a neutral fill. Measure actual changed columns,
      // excluding the refresh button, rather than requiring an accent color.
      var changedColumns = Set<Int>()
      var scanPixels = 0
      var scanTransitionPixels = 0
      var completionPixels = 0
      for y in 0..<110 {
        for x in 0..<300 {
          if try difference("quarter", "three-quarters", x: x, y: y) > 0.04 {
            changedColumns.insert(x)
          }
          if try difference("idle", "scanning", x: x, y: y) > 0.04 { scanPixels += 1 }
          if try difference("scanning", "zero", x: x, y: y) > 0.04 {
            scanTransitionPixels += 1
          }
          if try difference("idle", "finished", x: x, y: y) > 0.04 { completionPixels += 1 }
        }
      }
      XCTAssertGreaterThan(
        changedColumns.count, 40, "The horizontal bar must advance with checked apps")
      XCTAssertGreaterThan(scanPixels, 20, "Scanning must paint the empty linear progress track")
      XCTAssertEqual(
        scanTransitionPixels, 0,
        "Learning the app count must preserve the empty bar without a spinner transition")
      XCTAssertEqual(completionPixels, 0, "Completion must remove the progress indicator")
      XCTAssertLessThan(
        try difference("quarter", "finished", x: 240, y: 20), 0.02,
        "Passive progress must not expand the refresh button's glass background")
    }
  }

  @MainActor
  func testToolbarTitleIsVisibleInHostedMainWindow() async throws {
    try requireUITests()
    let environment = AppEnvironment.localUATFixture(
      settings: try isolatedAppListSettings(for: self))
    let window = try await makeLatestTestWindow(
      environment: environment, dark: true, testCase: self)
    let host = try XCTUnwrap(window.contentView)
    defer { window.close() }
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()

    let bitmap = try await captureWindowBitmap(window)
    let scale = CGFloat(bitmap.pixelsWide) / window.frame.width
    let titleStart = VisualMetrics.sidebarIdealWidth + VisualMetrics.detailHeaderHorizontalPadding
    let titleRegion = NSRect(x: titleStart - 4, y: 14, width: 100, height: 26)
    var brightPixels = 0
    var leftmostBrightPixel = bitmap.pixelsWide
    for y in Int(titleRegion.minY * scale)..<Int(titleRegion.maxY * scale) {
      for x in Int(titleRegion.minX * scale)..<Int(titleRegion.maxX * scale) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
          color.brightnessComponent > 0.55
        else { continue }
        brightPixels += 1
        leftmostBrightPixel = min(leftmostBrightPixel, x)
      }
    }
    XCTAssertGreaterThan(brightPixels, 25, "Updates must be painted in the titlebar")
    XCTAssertLessThan(
      CGFloat(leftmostBrightPixel) / scale, titleStart + 20,
      "The title should align with the detail panel")
  }

  @MainActor
  func testRefreshButtonHonorsEnabledStateForMouseInput() async throws {
    try requireUITests()
    for enabled in [true, false] {
      var calls = 0
      let host = NSHostingView(
        rootView: RefreshToolbarButton(isEnabled: enabled) { calls += 1 }
          .frame(width: 160, height: 80))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 160, height: 80),
        styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer { window.close() }
      try await Task.sleep(for: .milliseconds(100))
      host.layoutSubtreeIfNeeded()
      let down = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseDown,
          location: NSPoint(x: 80, y: 40), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
      let up = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseUp,
          location: down.locationInWindow, modifierFlags: [], timestamp: down.timestamp + 0.05,
          windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1,
          pressure: 0))
      NSApp.postEvent(up, atStart: false)
      window.sendEvent(down)
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(calls, enabled ? 1 : 0)
    }
  }

  @MainActor
  func testToolbarReloadRoutesThroughAppCommands() {
    let updateChecking = UpdateCheckingCommandSpy()
    let commands = AppCommands(
      updateCheckingService: updateChecking,
      updatesListViewModel: UpdatesListViewModel(),
      searchFocusController: SearchFocusController()
    )

    commands.reload()

    XCTAssertEqual(updateChecking.checkForUpdatesCount, 1)
  }
}

@MainActor
private final class UpdateCheckingCommandSpy: UpdateCheckingCommandHandling {
  private(set) var checkForUpdatesCount = 0
  private(set) var updateAllCount = 0

  func checkForUpdates() {
    checkForUpdatesCount += 1
  }

  func updateAll() {
    updateAllCount += 1
  }
}
