//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-06.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import Latest

/// Native focus and WindowServer captures are explicit opt-in work. The default
/// runner must remain usable while another application is in the foreground.
func requireUITests() throws {
  try XCTSkipUnless(
    ProcessInfo.processInfo.environment["LATEST_UI_TESTS"] == "1",
    "Run ./script/test.sh --ui for window and input tests.")
}

@MainActor
extension AppEnvironment {
  /// A test-only offline state used by deterministic geometry and interaction
  /// contracts. The runnable app and `--uat` always use `live()`.
  static func localUATFixture(settings: AppListSettings) -> AppEnvironment {
    let apps = LocalUATFixture.apps
    let viewModel = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
      settings: settings)
    viewModel.select(viewModel.snapshot.sections.first?.apps.first)
    return AppEnvironment(settings: settings, updatesListViewModel: viewModel)
  }
}

enum LocalUATFixture {
  /// Stable real bundle paths keep deterministic test renders tied to actual
  /// icon assets. This fixture is never selected by the runnable app.
  static let apps: [Latest.App] = [
    ("Notes", "26.4", "26.5", "/System/Applications/Notes.app"),
    ("Terminal", "2.14", "2.15", "/System/Applications/Utilities/Terminal.app"),
    ("TextEdit", "1.19", "1.20", "/System/Applications/TextEdit.app"),
    ("Calculator", "11.0", "11.1", "/System/Applications/Calculator.app"),
    ("Calendar", "15.0", "15.1", "/System/Applications/Calendar.app"),
    ("Contacts", "14.0", "14.1", "/System/Applications/Contacts.app"),
    ("Freeform", "4.0", "4.1", "/System/Applications/Freeform.app"),
    ("Home", "10.0", "10.1", "/System/Applications/Home.app"),
    ("Mail", "16.0", "16.1", "/System/Applications/Mail.app"),
    ("Maps", "4.0", "4.1", "/System/Applications/Maps.app"),
    ("Messages", "14.0", "14.1", "/System/Applications/Messages.app"),
    ("Music", "1.5", "1.6", "/System/Applications/Music.app"),
    ("Photo Booth", "13.0", "13.1", "/System/Applications/Photo Booth.app"),
    ("Photos", "10.0", "10.1", "/System/Applications/Photos.app"),
    ("Podcasts", "1.1", "1.2", "/System/Applications/Podcasts.app"),
    ("Preview", "11.0", "11.1", "/System/Applications/Preview.app"),
    ("Reminders", "7.0", "7.1", "/System/Applications/Reminders.app"),
    ("Shortcuts", "7.0", "7.1", "/System/Applications/Shortcuts.app"),
  ].enumerated().map { index, fixture in
    let fileURL = URL(fileURLWithPath: fixture.3, isDirectory: true)
    let bundle = App.Bundle(
      version: Version(versionNumber: fixture.1, buildNumber: nil),
      name: fixture.0,
      bundleIdentifier: Bundle(url: fileURL)?.bundleIdentifier ?? "com.example.latest-uat.\(index)",
      fileURL: fileURL,
      source: .sparkle,
      modificationDate: Date(timeIntervalSince1970: 1_750_000_000 - Double(index * 86_400))
    )
    let update = App.Update(
      app: bundle,
      remoteVersion: Version(versionNumber: fixture.2, buildNumber: nil),
      minimumOSVersion: nil,
      source: .sparkle,
      date: Date(timeIntervalSince1970: 1_750_000_000 - Double(index * 86_400)),
      releaseNotes: .html(
        string: """
          <h2>Version \(fixture.2)</h2>
          <p>Offline acceptance fixture for \(fixture.0).</p>
          <ul><li>Improved update discovery performance.</li><li>Modernized the macOS interface.</li></ul>
          """),
      updateAction: .builtIn { _ in }
    )
    return App(bundle: bundle, update: .success(update), isIgnored: false)
  }
}

/// Use the real SwiftUI scene, including its toolbar and native window geometry.
/// Each fixture owns an isolated model and never starts live discovery.
@MainActor
func makeLatestTestWindow(
  environment: AppEnvironment, dark: Bool = false, activate: Bool = true, testCase: XCTestCase
) async throws -> NSWindow {
  try await makeLatestTestWindow(
    content: LatestRootView(environment: environment), dark: dark, activate: activate,
    testCase: testCase)
}

@MainActor
func makeLatestTestWindow<Content: View>(
  content: Content, dark: Bool = false, activate: Bool = true, testCase: XCTestCase
) async throws -> NSWindow {
  try requireUITests()
  let originalAppearanceName = NSApp.appearance?.name.rawValue
  testCase.addTeardownBlock {
    await MainActor.run {
      NSApp.appearance = originalAppearanceName.flatMap { NSAppearance(named: .init($0)) }
    }
  }
  (dark ? ApplicationAppearance.dark : .light).apply(to: NSApp)
  let id = "latest-test-\(UUID().uuidString)"
  let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
  NSApp.setActivationPolicy(.regular)
  let scene = NSHostingSceneRepresentation {
    LatestMainWindowScene(id: id) {
      content
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: "en_US"))
    }
  }
  NSApp.addSceneRepresentation(scene)
  scene.environment.openWindow(id: id)
  for _ in 0..<100 {
    if let window = NSApp.windows.first(where: {
      !existingWindows.contains(ObjectIdentifier($0)) && $0.isVisible
    }) {
      window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      if activate {
        try await activateTestWindow(window)
      } else {
        window.orderFront(nil)
      }
      window.makeFirstResponder(nil)
      return window
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  XCTFail("The production Latest scene did not open")
  throw CocoaError(.coderInvalidValue)
}

@MainActor
func activateTestWindow(_ window: NSWindow) async throws {
  try requireUITests()
  NSApp.setActivationPolicy(.regular)
  window.makeKeyAndOrderFront(nil)
  // XCTest launches the host in the background. Request the explicit UI
  // launch through LaunchServices; self-activation alone may be declined.
  if !NSApp.isActive {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    configuration.addsToRecentItems = false
    configuration.createsNewApplicationInstance = false
    let application = try await NSWorkspace.shared.openApplication(
      at: Bundle.main.bundleURL, configuration: configuration)
    XCTAssertEqual(application.processIdentifier, ProcessInfo.processInfo.processIdentifier)
  }
  let deadline = ContinuousClock.now + .seconds(5)
  repeat {
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    if NSApp.isActive && window.isKeyWindow {
      try await Task.sleep(for: .milliseconds(20))
      if NSApp.isActive && window.isKeyWindow { return }
    }
    try await Task.sleep(for: .milliseconds(20))
  } while ContinuousClock.now < deadline
  XCTFail(
    "UI test window could not acquire focus: title=\(window.title), class=\(type(of: window)), visible=\(window.isVisible), canBecomeKey=\(window.canBecomeKey), onActiveSpace=\(window.isOnActiveSpace), active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), running=\(NSApp.isRunning), launched=\(NSRunningApplication.current.isFinishedLaunching), frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"). Run --ui when the desktop is available."
  )
  throw CocoaError(.userCancelled)
}

@MainActor
func deactivateTestApplication() async throws {
  try requireUITests()
  if NSApp.isActive {
    let background = try XCTUnwrap(
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    // Deactivating a key window alone can leave its application active. Hand
    // activation to another running app so native materials enter inactive state.
    NSApp.yieldActivation(to: background)
    XCTAssertTrue(background.activate(from: .current, options: []))
  }
  let deadline = ContinuousClock.now + .seconds(5)
  while NSApp.isActive && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  XCTAssertFalse(NSApp.isActive)
}

/// Supply the release before a native view enters its synchronous tracking loop.
@MainActor
func clickTestWindow(_ window: NSWindow, at location: NSPoint) throws {
  let timestamp = ProcessInfo.processInfo.systemUptime
  let down = try XCTUnwrap(
    NSEvent.mouseEvent(
      with: .leftMouseDown, location: location, modifierFlags: [],
      timestamp: timestamp, windowNumber: window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 1, pressure: 1))
  let up = try XCTUnwrap(
    NSEvent.mouseEvent(
      with: .leftMouseUp, location: location, modifierFlags: [],
      timestamp: timestamp + 0.05, windowNumber: window.windowNumber, context: nil,
      eventNumber: 2, clickCount: 1, pressure: 0))
  NSApp.postEvent(up, atStart: false)
  window.sendEvent(down)
  // Native controls may consume the release in their tracking loop. SwiftUI
  // gestures do not; finish that click before sending the next command.
  if let pending = NSApp.nextEvent(
    matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false),
    pending.windowNumber == up.windowNumber, pending.timestamp == up.timestamp
  {
    _ = NSApp.nextEvent(
      matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    window.sendEvent(pending)
  }
}

/// SwiftUI responders need NSApplication's event loop while async XCTest work runs.
@MainActor
func runApplicationTest(_ operation: @escaping @MainActor () async throws -> Void) throws {
  var failure: Error?
  Task { @MainActor in
    do { try await operation() } catch { failure = error }
    NSApp.stop(nil)
    if let wake = NSEvent.otherEvent(
      with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
    {
      NSApp.postEvent(wake, atStart: true)
    }
  }
  NSApp.run()
  if let failure { throw failure }
}
