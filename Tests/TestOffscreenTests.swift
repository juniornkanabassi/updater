import AppKit
import XCTest

/// Tests never show anything on Junior's screens or take focus.
@MainActor final class TestOffscreenTests: XCTestCase {
  func testEveryWindowATestShowsStaysInvisibleAndClickThrough() {
    TestOffscreenInstalled()
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    for show in [{ window.makeKeyAndOrderFront(nil) }, { window.orderFrontRegardless() }, { window.orderFront(nil) }] {
      window.alphaValue = 1
      show()
      XCTAssertTrue(window.isVisible)
      XCTAssertEqual(window.alphaValue, 0)
      XCTAssertTrue(window.ignoresMouseEvents)
      window.orderOut(nil)
    }
    NSApp.activate(ignoringOtherApps: true)
    XCTAssertFalse(NSApp.isActive, "a test must never bring the test process forward")
  }
}
