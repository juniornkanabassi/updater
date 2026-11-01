// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

final class InstallHelperInteractionTest: XCTestCase {
  @MainActor
  func testHelperSheetRepairApprovalCancelAndFallback() throws {
    try requireUITests()
    try runApplicationTest {
      let stored = AppStoreUpdateSettings.alwaysPerformManualUpdates.active
      defer { AppStoreUpdateSettings.alwaysPerformManualUpdates.active = stored }
      for dark in [false, true] {
        AppStoreUpdateSettings.alwaysPerformManualUpdates.active = false
        let helper = HelperRegistrationFixture()
        helper.failure = NSError(
          domain: "registration", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Signing does not match"])
        let workspace = StubApplicationWorkspace()
        let presenter = UpdateInstallHelperAlert(helper: helper, workspace: workspace)
        let host = NSHostingView(
          rootView: Color(nsColor: .windowBackgroundColor)
            .modifier(UpdateInstallHelperPresentation(presenter: presenter)))
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        try await activateTestWindow(window)
        var starts = 0
        let url = URL(string: "macappstore://apps.apple.com/updates")!
        presenter.prepare(fallbackURL: url, error: .installHelperNotRegistered) { starts += 1 }
        try await waitForHelper { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        try await self.capture(sheet, name: "\(dark ? "dark" : "light")-setup")
        try await self.press("Enable Helper", in: sheet)
        try await waitForHelper { presenter.errorDetails != nil }
        XCTAssertEqual(helper.registrations, 1)
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(window.attachedSheet === sheet, "Repair must keep one stable sheet")
        try await self.press("Details", in: sheet)
        try await self.capture(sheet, name: "\(dark ? "dark" : "light")-failure")
        XCTAssertTrue(
          self.elements(sheet).contains {
            if $0.accessibilityLabel()?.contains("Signing does not match") == true { return true }
            guard $0.object.responds(to: NSSelectorFromString("accessibilityValue")) else {
              return false
            }
            return ($0.object.value(forKey: "accessibilityValue") as? String)?.contains(
              "Signing does not match") == true
          })
        try await self.press("Always open App Store", in: sheet)
        let escape = try XCTUnwrap(
          NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        sheet.sendEvent(escape)
        try await waitForHelper { window.attachedSheet == nil }
        XCTAssertTrue(AppStoreUpdateSettings.alwaysPerformManualUpdates.active)
        XCTAssertEqual(starts, 0)

        AppStoreUpdateSettings.alwaysPerformManualUpdates.active = false
        presenter.prepare(fallbackURL: url, error: .installHelperRequiresApproval) { starts += 1 }
        try await waitForHelper { window.attachedSheet != nil }
        let approvalSheet = try XCTUnwrap(window.attachedSheet)
        try await self.capture(approvalSheet, name: "\(dark ? "dark" : "light")-approval")
        try await self.press("Open App Store", in: approvalSheet)
        try await waitForHelper { window.attachedSheet == nil }
        XCTAssertEqual(workspace.openedURLs, [url])
        helper.enabled = true
        presenter.resumeIfAvailable()
        XCTAssertEqual(starts, 0)

        helper.suspendsCheck = true
        presenter.prepare(fallbackURL: url) { starts += 1 }
        try await waitForHelper { window.attachedSheet != nil && helper.pendingCheck != nil }
        let checkingSheet = try XCTUnwrap(window.attachedSheet)
        try await self.capture(
          checkingSheet, name: "\(dark ? "dark" : "light")-checking", animated: true)
        try await self.press("Cancel", in: checkingSheet)
        try await waitForHelper { window.attachedSheet == nil }
        let completedChecks = helper.completedChecks
        helper.pendingCheck?.resume()
        try await waitForHelper { helper.completedChecks > completedChecks }
        XCTAssertEqual(starts, 0, "Cancelling the checking sheet must discard its late reply")
      }
    }
  }

  @MainActor
  private func elements(_ window: NSWindow) -> [SidebarAccessibilityElement] {
    NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
    var seen = Set<ObjectIdentifier>()
    var result: [SidebarAccessibilityElement] = []
    func visit(_ value: Any) {
      guard let object = value as? NSObject, seen.insert(ObjectIdentifier(object)).inserted else {
        return
      }
      let element = SidebarAccessibilityElement(object: object)
      result.append(element)
      for child in element.accessibilityChildren() ?? [] { visit(child) }
      for child in (value as? NSView)?.subviews ?? [] { visit(child) }
    }
    visit(window)
    return result
  }

  @MainActor
  private func press(_ title: String, in window: NSWindow) async throws {
    func matchingElements() -> [SidebarAccessibilityElement] {
      elements(window).filter {
        if $0.accessibilityLabel() == title { return true }
        if let button = $0.object as? NSButton, button.title == title { return true }
        guard $0.object.responds(to: NSSelectorFromString("accessibilityTitle")) else {
          return false
        }
        return $0.object.value(forKey: "accessibilityTitle") as? String == title
      }
    }
    try await waitForHelper { !matchingElements().isEmpty }
    let matches = matchingElements()
    let selector = NSSelectorFromString("accessibilityPerformPress")
    if let button = matches.first(where: { $0.object.responds(to: selector) }) {
      typealias Press = @convention(c) (NSObject, Selector) -> Bool
      let press = unsafeBitCast(button.object.method(for: selector), to: Press.self)
      XCTAssertTrue(press(button.object, selector))
      return
    }
    let element = try XCTUnwrap(matches.first, "Missing control: \(title)")
    let frame = element.accessibilityFrame()
    XCTAssertFalse(frame.isEmpty)
    let point = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
      let event = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
          pressure: 1))
      window.sendEvent(event)
    }
  }

  @MainActor
  private func capture(_ window: NSWindow, name: String, animated: Bool = false) async throws {
    try await Task.sleep(for: .milliseconds(250))
    // A running progress indicator cannot produce identical settled frames.
    let bitmap =
      try await animated ? captureWindowBitmap(window) : settledWindowBitmap(window)
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
        "build/helper-repair")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
      to: output.appendingPathComponent("\(name).png"))
  }
}
