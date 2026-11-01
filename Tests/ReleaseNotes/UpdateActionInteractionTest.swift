// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Sparkle
import SwiftUI
import Synchronization
import XCTest

@testable import Latest

final class UpdateActionInteractionTest: XCTestCase {
  @MainActor
  func testProgressControlsAdvanceAndCancelUnmeasuredTransfers() throws {
    try requireUITests()
    try runApplicationTest {
      try await self.checkProgressControlsAdvanceAndCancelUnmeasuredTransfers()
    }
  }

  @MainActor
  private func checkProgressControlsAdvanceAndCancelUnmeasuredTransfers() async throws {
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("build/update-debug/progress-controls")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for identifier in ["updates.progress", "update.progress"] {
      let app = makeTestApp(name: "Download target", version: "1", remoteVersion: "2")
      let queue = UpdateQueue()
      queue.isSuspended = true
      let operation = UpdateOperation(
        bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
      queue.addOperation(operation)
      defer {
        operation.finish()
        queue.isSuspended = false
      }
      operation.progressState = .downloading(loadedSize: 25, totalSize: 100)
      let fixture = try await SidebarInputFixture.make(
        apps: [app], selected: app, updating: AppUpdateService(queue: queue), testCase: self)
      defer { fixture.window.close() }
      func progressButton() throws -> SidebarAccessibilityElement {
        try XCTUnwrap(
          fixture.accessibilityElements().first {
            $0.accessibilityIdentifier() == identifier
              && $0.accessibilityFrame().intersects(fixture.window.frame)
          })
      }
      let earlyLabel = try progressButton().accessibilityLabel()
      let early = try await captureWindowBitmap(fixture.window)
      operation.progressState = .downloading(loadedSize: 75, totalSize: 100)
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertNotEqual(try progressButton().accessibilityLabel(), earlyLabel)
      let later = try await captureWindowBitmap(fixture.window)
      let frame = fixture.window.convertFromScreen(try progressButton().accessibilityFrame())
      let crop = CGRect(
        x: frame.minX * 2, y: (fixture.window.frame.height - frame.maxY) * 2,
        width: frame.width * 2, height: frame.height * 2)
      let before = try XCTUnwrap(early.cgImage?.cropping(to: crop))
      let after = try XCTUnwrap(later.cgImage?.cropping(to: crop))
      XCTAssertNotEqual(
        NSBitmapImageRep(cgImage: before).representation(using: .png, properties: [:]),
        NSBitmapImageRep(cgImage: after).representation(using: .png, properties: [:]),
        "The progress ring must repaint when more bytes arrive")
      for (name, bitmap) in [("early", early), ("later", later)] {
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: output.appendingPathComponent("\(identifier)-\(name).png"))
      }
      operation.progressState =
        identifier == "updates.progress"
        ? .downloading(loadedSize: 64, totalSize: -1) : .extracting(progress: nil)
      try await Task.sleep(for: .milliseconds(150))
      let button = try progressButton()
      XCTAssertEqual(button.accessibilityEnabled(), true)
      XCTAssertFalse(operation.isCancelled)
      let unknownEarly = try await captureWindowBitmap(fixture.window)
      try await Task.sleep(for: .milliseconds(150))
      let unknownLater = try await captureWindowBitmap(fixture.window)
      if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        XCTAssertNotEqual(
          NSBitmapImageRep(cgImage: try XCTUnwrap(unknownEarly.cgImage?.cropping(to: crop)))
            .representation(using: .png, properties: [:]),
          NSBitmapImageRep(cgImage: try XCTUnwrap(unknownLater.cgImage?.cropping(to: crop)))
            .representation(using: .png, properties: [:]),
          "The indicator must animate while progress is unmeasured")
      }
      try await activateTestWindow(fixture.window)
      let cancelFrame = fixture.window.convertFromScreen(try progressButton().accessibilityFrame())
      try clickTestWindow(fixture.window, at: NSPoint(x: cancelFrame.midX, y: cancelFrame.midY))
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertTrue(operation.isCancelled, "Unmeasured preparation must remain cancellable")
    }
  }

  @MainActor
  func testQuitRetryControlsReuseActiveSparkleUpdate() throws {
    try requireUITests()
    try runApplicationTest { try await self.checkQuitRetryControlsReuseActiveSparkleUpdate() }
  }

  @MainActor
  private func checkQuitRetryControlsReuseActiveSparkleUpdate() async throws {
    let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("build/diff-review-2026-10-04/retry-controls")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for dark in [false, true] {
      let app = makeTestApp(name: "Sparkle target", version: "1", remoteVersion: "2")
      let queue = UpdateQueue()
      queue.isSuspended = true
      let operation = SparkleUpdateOperation(
        bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
      queue.addOperation(operation)
      defer {
        operation.finish()
        queue.isSuspended = false
      }
      var retries = 0
      operation.showDownloadDidStartExtractingUpdate()
      operation.showExtractionReceivedProgress(0.5)
      let fixture = try await SidebarInputFixture.make(
        apps: [app], selected: app, dark: dark,
        updating: AppUpdateService(queue: queue), testCase: self)
      defer { fixture.window.close() }
      for identifier in ["updates.progress", "update.progress"] {
        let button = try XCTUnwrap(
          fixture.accessibilityElements().first {
            $0.accessibilityIdentifier() == identifier
              && $0.accessibilityFrame().intersects(fixture.window.frame)
          })
        XCTAssertEqual(
          button.accessibilityEnabled(), false, "Protected installation cannot be cancelled")
        let frame = fixture.window.convertFromScreen(button.accessibilityFrame())
        try clickTestWindow(fixture.window, at: NSPoint(x: frame.midX, y: frame.midY))
        XCTAssertFalse(operation.isCancelled)
        XCTAssertTrue(queue.contains(app.identifier))
      }
      let protectedBitmap = try await captureWindowBitmap(fixture.window)
      try XCTUnwrap(protectedBitmap.representation(using: .png, properties: [:])).write(
        to: output.appendingPathComponent("\(dark ? "dark" : "light")-protected.png"))
      operation.showReady { XCTAssertEqual($0, .install) }
      operation.showInstallingUpdate(
        withApplicationTerminated: false, retryTerminatingApplication: { retries += 1 })
      try await Task.sleep(for: .milliseconds(150))
      for (index, identifier) in ["updates.retry-termination", "update.retry-termination"]
        .enumerated()
      {
        let button = try XCTUnwrap(
          fixture.accessibilityElements().first {
            $0.accessibilityIdentifier() == identifier
              && $0.accessibilityFrame().intersects(fixture.window.frame)
          })
        let frame = fixture.window.convertFromScreen(button.accessibilityFrame())
        try clickTestWindow(fixture.window, at: NSPoint(x: frame.midX, y: frame.midY))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(retries, index + 1, "\(identifier) must retry the active installation")
        XCTAssertTrue(queue.contains(app.identifier))
        XCTAssertFalse(operation.isCancelled)
      }
      let bitmap = try await captureWindowBitmap(fixture.window)
      try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
        to: output.appendingPathComponent("\(dark ? "dark" : "light").png"))
    }
  }

  @MainActor
  func testDetailActionUsesRefreshedAppAtSameURL() async throws {
    try requireUITests()
    let calls = Mutex([0, 0])
    let bundle = makeTestApp(name: "Example", version: "1").bundle
    let apps = ["2", "3"].enumerated().map { index, version in
      App(
        bundle: bundle,
        update: .success(
          App.Update(
            app: bundle,
            remoteVersion: Version(versionNumber: version, buildNumber: nil),
            minimumOSVersion: nil, source: .sparkle, date: nil, releaseNotes: nil,
            updateAction: .external(label: "Vendor") { _ in calls.withLock { $0[index] += 1 } })),
        isIgnored: false)
    }
    let host = NSHostingView(rootView: ReleaseNotesHeaderView(app: apps[0]))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 460, height: 79),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer { window.close() }
    for app in apps {
      host.rootView = ReleaseNotesHeaderView(app: app)
      try await Task.sleep(for: .milliseconds(150))
      host.layoutSubtreeIfNeeded()
      let down = try XCTUnwrap(
        NSEvent.mouseEvent(
          with: .leftMouseDown,
          location: NSPoint(x: 406.5, y: 46.5), modifierFlags: [],
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
    }
    XCTAssertEqual(calls.withLock { $0[0] }, 1, "The old app's action must be retired")
    XCTAssertEqual(calls.withLock { $0[1] }, 1, "Use the refreshed app at the same URL")
  }

  @MainActor
  func testDetailCapsulePaintsAndRoutesMouseActions() throws {
    try requireUITests()
    try runApplicationTest { try await self.checkDetailCapsulePaintsAndRoutesMouseActions() }
  }

  @MainActor
  private func checkDetailCapsulePaintsAndRoutesMouseActions() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let set =
      (try? String(
        contentsOf: root.appendingPathComponent("build/detail-capsule-capture-set"),
        encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "current"
    let output = root.appendingPathComponent("build/detail-capsule-\(set)")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let app = LocalUATFixture.apps[0]
    let states: [(String, UpdateActionPresentation)] = [
      ("update", .update)
    ]
    for dark in [false, true] {
      for (name, presentation) in states {
        var actions = 0
        let window = try await makeLatestTestWindow(
          content:
            UpdateActionSurface(
              app: app, presentation: presentation, performAction: { actions += 1 }
            )
            .frame(width: 160, height: 80)
            .background(Color(nsColor: .textBackgroundColor))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(),
          dark: dark, testCase: self)
        defer { window.close() }
        try await activateTestWindow(window)
        let host = try XCTUnwrap(window.contentView)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        _ = try await settledWindowBitmap(window)
        let filename = "\(dark ? "dark" : "light")-\(name)"
        // macOS 26 VM capture fails for tiny windows. Capture a full-size
        // surface and inspect the same 160 x 80pt component crop on both OSes.
        func captureCapsule() async throws -> NSBitmapImageRep {
          let bitmap = try await captureWindowBitmap(window)
          let component = host.convert(
            CGRect(x: host.bounds.midX - 80, y: host.bounds.midY - 40, width: 160, height: 80),
            to: nil)
          let crop = CGRect(
            x: component.minX * 2, y: (window.frame.height - component.maxY) * 2,
            width: 320, height: 160)
          return NSBitmapImageRep(cgImage: try XCTUnwrap(bitmap.cgImage?.cropping(to: crop)))
        }
        let bitmap = try await captureCapsule()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
          to: output.appendingPathComponent("\(filename).png"))
        // Independently inspect the original 59 x 24pt capsule and its blue ink.
        var bluePixels = 0
        for y in 56..<104 {
          for x in 101..<219 {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            if color.blueComponent - color.redComponent > 0.3 { bluePixels += 1 }
          }
        }
        XCTAssertGreaterThan(bluePixels, 25, filename)
        let center = try XCTUnwrap(bitmap.colorAt(x: 160, y: 58)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(center.redComponent, 0.9, filename)
        XCTAssertLessThan(center.redComponent, 0.98, filename)
        XCTAssertGreaterThan(center.blueComponent - center.redComponent, 0.01, filename)
        let down = try XCTUnwrap(
          NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(
          NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: down.locationInWindow, modifierFlags: [], timestamp: down.timestamp + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1,
            pressure: 0))
        // Dispatch to the owning window: macOS 26 does not reliably route a
        // queued synthetic press. Capture the held state before its release.
        let pressed = try await { @MainActor in
          window.sendEvent(down)
          defer { window.sendEvent(up) }
          var pressed: NSBitmapImageRep?
          for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(25))
            let bitmap = try await captureCapsule()
            let fill = try XCTUnwrap(bitmap.colorAt(x: 160, y: 58)?.usingColorSpace(.sRGB))
            if fill.redComponent < center.redComponent - 0.1 {
              pressed = bitmap
              break
            }
          }
          XCTAssertEqual(actions, 0, "The action must wait for mouse-up")
          return try XCTUnwrap(pressed, "\(filename) must paint its pressed fill before release")
        }()
        try XCTUnwrap(pressed.representation(using: .png, properties: [:])).write(
          to: output.appendingPathComponent("\(filename)-pressed.png"))
        let pressedFill = try XCTUnwrap(pressed.colorAt(x: 160, y: 58)?.usingColorSpace(.sRGB))
        XCTAssertLessThan(pressedFill.redComponent, center.redComponent - 0.1, filename)
        for _ in 0..<40 {
          if actions == 1 { break }
          try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(actions, 1, "\(filename) must invoke the displayed action exactly once")
      }
    }
  }
}
