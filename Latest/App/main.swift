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
