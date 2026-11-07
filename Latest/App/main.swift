//
//  main.swift
//  Latest
//
//  Created by ertyoii on 03.06.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import ObjectiveC
import SwiftUI

private var isRunningUnitTests: Bool {
  let environment = ProcessInfo.processInfo.environment
  return environment["XCTestConfigurationFilePath"] != nil
    || environment["XCTestBundlePath"] != nil || NSClassFromString("XCTestCase") != nil
}

/// The unit-test bundle is linked into the application executable. Launching the
/// production SwiftUI scene from that host used to scan installed applications,
/// make live network requests, and mutate user defaults before XCTest started.
/// A settings-only scene keeps the AppKit test host alive without starting any
/// production service or opening a window.
private struct LatestUnitTestHostApplication: SwiftUI.App {
  var body: some Scene {
    Settings {
      EmptyView()
    }
  }
}

extension NSWindow {
  /// Keep real-app checks and early test-host windows invisible on every display.
  static func keepEveryWindowInvisible() { _ = invisibleWindowObserver }

  private static let invisibleWindowObserver = NotificationCenter.default.addObserver(
    forName: NSWindow.didUpdateNotification, object: nil, queue: .main
  ) { note in
    guard let window = note.object as? NSWindow,
      window.alphaValue != 0 || !window.ignoresMouseEvents
    else { return }
    MainActor.assumeIsolated {
      window.alphaValue = 0
      window.ignoresMouseEvents = true
    }
  }
}

// A hidden app copy must be invisible before WindowServer receives an order request.
// Test bundles have their own equivalent guard installed before XCTest starts.
private func installAgentGuard() {
  func replace(_ type: AnyClass, _ original: String, _ replacement: Selector) {
    guard let old = class_getInstanceMethod(type, NSSelectorFromString(original)),
      let new = class_getInstanceMethod(type, replacement)
    else { return }
    method_exchangeImplementations(old, new)
  }
  replace(NSWindow.self, "setAlphaValue:", #selector(NSWindow.agentSetAlpha(_:)))
  replace(NSWindow.self, "orderWindow:relativeTo:", #selector(NSWindow.agentOrder(_:relativeTo:)))
  replace(NSWindow.self, "orderFront:", #selector(NSWindow.agentOrderFront(_:)))
  replace(NSWindow.self, "orderFrontRegardless", #selector(NSWindow.agentOrderFrontRegardless))
  replace(NSWindow.self, "makeKeyAndOrderFront:", #selector(NSWindow.agentMakeKeyAndOrderFront(_:)))
  replace(NSApplication.self, "activate", #selector(NSApplication.agentActivate))
  replace(
    NSApplication.self, "activateIgnoringOtherApps:",
    #selector(NSApplication.agentActivateIgnoring(_:)))
  replace(NSApplication.self, "noResponderFor:", #selector(NSApplication.agentNoResponder(_:)))
}

extension NSWindow {
  @objc fileprivate func agentSetAlpha(_ value: CGFloat) { agentSetAlpha(0) }
  @objc fileprivate func agentOrder(_ order: NSWindow.OrderingMode, relativeTo other: Int) {
    agentHide()
    agentOrder(order, relativeTo: other)
  }
  // The same three entry points Tests/TestOffscreen covers, so no order path reaches WindowServer visible.
  @objc fileprivate func agentOrderFront(_ sender: Any?) {
    agentHide()
    agentOrderFront(sender)
  }
  @objc fileprivate func agentOrderFrontRegardless() {
    agentHide()
    agentOrderFrontRegardless()
  }
  @objc fileprivate func agentMakeKeyAndOrderFront(_ sender: Any?) {
    agentHide()
    agentMakeKeyAndOrderFront(sender)
  }
  private func agentHide() {
    alphaValue = 0
    ignoresMouseEvents = true
  }
}

extension NSApplication {
  @objc fileprivate func agentActivate() {}
  @objc fileprivate func agentActivateIgnoring(_ flag: Bool) {}
  @objc fileprivate func agentNoResponder(_ selector: Selector) {}
}

if CommandLine.arguments.contains("--agent-screen") { installAgentGuard() }

if isRunningUnitTests || CommandLine.arguments.contains("--agent-screen") {
  NSWindow.keepEveryWindowInvisible()
  NSApplication.shared.setActivationPolicy(.prohibited)
}

#if DEBUG
  if let index = CommandLine.arguments.firstIndex(of: "--journal-crash-probe") {
    JournalCrashProbe.run(Array(CommandLine.arguments[(index + 1)...]))
  }
#endif

if isRunningUnitTests {
  LatestUnitTestHostApplication.main()
} else {
  LatestApplication.main()
}
