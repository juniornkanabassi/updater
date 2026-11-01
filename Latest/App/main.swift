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

if isRunningUnitTests {
  if ProcessInfo.processInfo.environment["LATEST_UI_TESTS"] != "1" {
    // The background lane has no visible scenes and must not activate over the
    // user's foreground app. UI/benchmark runners explicitly opt in.
    NSApplication.shared.setActivationPolicy(.prohibited)
  }
  LatestUnitTestHostApplication.main()
} else {
  LatestApplication.main()
}
