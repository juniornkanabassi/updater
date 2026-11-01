// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import XCTest

@testable import Latest

/// Exercises the shipping scene through real input, without exposing a SwiftUI
/// coordinator or replacing its navigation with a test implementation.
@MainActor
struct SidebarInputFixture {
  let window: NSWindow
  let model: UpdatesListViewModel

  /// The production scene uses the shared SwiftUI renderer. Fixtures
  /// supply data and services only; they never assemble or restyle a row.
  static func make(
    apps: [Latest.App], selected: Latest.App? = nil, dark: Bool = false,
    searchFocusController: SearchFocusController = SearchFocusController(),
    updating: any AppUpdating = AppUpdateService.shared, testCase: XCTestCase
  ) async throws -> SidebarInputFixture {
    let settings = try isolatedAppListSettings(for: testCase)
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
      settings: settings, updating: updating)
    model.select(selected)
    let environment = AppEnvironment(
      searchFocusController: searchFocusController, settings: settings,
      updating: updating, updatesListViewModel: model)
    let window = try await makeLatestTestWindow(
      environment: environment, dark: dark, testCase: testCase)
    let fixture = try SidebarInputFixture(window: window, model: model)
    window.layoutIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    return fixture
  }

  func contentFrame(for app: Latest.App) throws -> CGRect {
    let row = try XCTUnwrap(
      accessibilityElements().first {
        $0.accessibilityIdentifier() == "updates.app.\(app.identifier)"
          && $0.accessibilityFrame().intersects(window.frame)
      })
    // SwiftUI's source-list content begins 16pt inside the full-width AX row.
    return window.convertFromScreen(row.accessibilityFrame()).offsetBy(dx: 16, dy: 0)
  }

  func captureRow(for app: Latest.App) async throws -> NSBitmapImageRep {
    let bitmap = try await settledWindowBitmap(window)
    let frame = try contentFrame(for: app)
    let crop = CGRect(
      x: frame.minX * 2, y: (window.frame.height - frame.maxY) * 2,
      width: frame.width * 2, height: frame.height * 2)
    return NSBitmapImageRep(cgImage: try XCTUnwrap(bitmap.cgImage?.cropping(to: crop)))
  }

  func clickProgress(for app: Latest.App) async throws {
    let frame = try contentFrame(for: app)
    let location = CGPoint(x: frame.minX + 264, y: frame.midY - 10)
    let down = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseDown, location: location, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try XCTUnwrap(
      NSEvent.mouseEvent(
        with: .leftMouseUp, location: location, modifierFlags: [],
        timestamp: down.timestamp + 0.05, windowNumber: window.windowNumber,
        context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    NSApp.postEvent(up, atStart: false)
    window.sendEvent(down)
    try await Task.sleep(for: .milliseconds(50))
  }
  let scroll: NSScrollView

  init(window: NSWindow, model: UpdatesListViewModel) throws {
    self.window = window
    self.model = model
    func find(_ view: NSView) -> NSScrollView? {
      if let scroll = view as? NSScrollView,
        scroll.convert(scroll.bounds, to: window.contentView).minX < 308
      {
        return scroll
      }
      return view.subviews.lazy.compactMap { find($0) }.first
    }
    scroll = try XCTUnwrap(window.contentView.flatMap { find($0) })
  }

  var selectedRow: Int {
    model.selectedApp.flatMap { model.snapshot.firstIndex(of: $0) } ?? -1
  }

  func rowRect(_ index: Int) -> CGRect {
    var entry = 0
    var y: CGFloat = 0
    for section in model.snapshot.sections {
      if index == entry { return CGRect(x: 0, y: y, width: 308, height: 27) }
      let count = section.apps.count
      if index > entry && index <= entry + count {
        return CGRect(x: 0, y: y + 37 + CGFloat(index - entry - 1) * 60, width: 308, height: 60)
      }
      entry += count + 1
      y += 37 + CGFloat(count) * 60
    }
    return .zero
  }

  func focus() throws {
    // Click a visible app, so SwiftUI obtains focus through its normal path.
    let y = scroll.contentView.bounds.minY
    let row = model.snapshot.entries.indices.first {
      if case .app = model.snapshot.entries[$0] {
        let rect = rowRect($0)
        return rect.minY >= y + 27 && rect.maxY <= y + scroll.contentSize.height
      }
      return false
    }
    try click(row: XCTUnwrap(row, "The sidebar must contain a fully visible app row"))
  }

  func scroll(to y: CGFloat) {
    scroll.contentView.scroll(to: CGPoint(x: 0, y: y))
    scroll.reflectScrolledClipView(scroll.contentView)
    window.contentView?.layoutSubtreeIfNeeded()
  }

  func accessibilityElements() -> [SidebarAccessibilityElement] {
    NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
    var seen = Set<ObjectIdentifier>()
    var elements: [SidebarAccessibilityElement] = []
    func visit(_ value: Any) {
      guard let object = value as? NSObject,
        seen.insert(ObjectIdentifier(object)).inserted
      else { return }
      let element = SidebarAccessibilityElement(object: object)
      elements.append(element)
      for child in element.accessibilityChildren() ?? [] { visit(child) }
      // Hosting views may be ignored AX containers; their native children
      // still lead to virtual SwiftUI row elements.
      for child in (value as? NSView)?.subviews ?? [] { visit(child) }
    }
    visit(window)
    return elements
  }

  func clickSearchClearButton() async throws {
    for _ in 0..<100 {
      window.contentView?.layoutSubtreeIfNeeded()
      if let button = accessibilityElements().first(where: {
        $0.accessibilityLabel() == "Clear Search"
          && !$0.accessibilityFrame().isEmpty
          && $0.accessibilityFrame().intersects(window.frame)
      }) {
        let frame = window.convertFromScreen(button.accessibilityFrame())
        try clickTestWindow(window, at: NSPoint(x: frame.midX, y: frame.midY))
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("The visible search clear button did not expose its accessibility frame")
    throw CocoaError(.coderInvalidValue)
  }

  func activate() async throws {
    try await activateTestWindow(window)
  }

  func click(row: Int) throws {
    guard case .app(let app) = model.snapshot.entries[row] else {
      XCTFail("Mouse targeting requires an app row")
      return
    }
    let frame = try contentFrame(for: app)
    try clickTestWindow(window, at: CGPoint(x: frame.minX + 110, y: frame.midY))
  }

  func press(down: Bool, repeatKey: Bool = true) throws {
    let character = down ? "\u{F701}" : "\u{F700}"
    let event = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: character, charactersIgnoringModifiers: character,
        isARepeat: repeatKey, keyCode: down ? 125 : 126))
    window.sendEvent(event)
  }

  func wheel(dx: Int32 = 0, dy: Int32) throws {
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: dy, wheel2: dx, wheel3: 0))
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))
  }

  func horizontalWheel(row: Int, dx: Int32) throws {
    guard case .app(let app) = model.snapshot.entries[row] else {
      throw CocoaError(.coderInvalidValue)
    }
    let frame = try contentFrame(for: app)
    let point = window.convertPoint(toScreen: CGPoint(x: frame.minX + 194, y: frame.midY))
    let screen = try XCTUnwrap(NSScreen.screens.first)
    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
        wheel1: 0, wheel2: dx, wheel3: 0))
    event.location = CGPoint(x: point.x, y: screen.frame.maxY - point.y)
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    // Queue the event through NSApplication so the production input monitor
    // receives the same windowless scroll events as a mouse or VM.
    NSApp.postEvent(try XCTUnwrap(NSEvent(cgEvent: event)), atStart: false)
  }
}

/// SwiftUI's virtual elements implement accessibility getters without always
/// declaring the formal AppKit protocol. Query the exposed getters through KVC.
@MainActor
struct SidebarAccessibilityElement {
  let object: NSObject
  private func value(_ key: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(key)) else { return nil }
    return object.value(forKey: key)
  }
  func accessibilityChildren() -> [Any]? { value("accessibilityChildren") as? [Any] }
  func accessibilityIdentifier() -> String? { value("accessibilityIdentifier") as? String }
  func accessibilityLabel() -> String? { value("accessibilityLabel") as? String }
  func accessibilityEnabled() -> Bool? { value("isAccessibilityEnabled") as? Bool }
  func accessibilityFrame() -> CGRect {
    (value("accessibilityFrame") as? NSValue)?.rectValue ?? .zero
  }
}
