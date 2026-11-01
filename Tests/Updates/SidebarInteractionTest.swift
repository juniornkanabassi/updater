// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI
import WebKit
import XCTest

@testable import Latest

@MainActor
final class SidebarInteractionTest: XCTestCase {
  func testSelectedSupportStatusSettlesWithoutChangingAppOrInstalledVersion() async throws {
    try requireUITests()
    let settings = try isolatedAppListSettings(for: self)
    let suite = "SupportStatus.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppDataStore(userDefaults: defaults)
    let bundle = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "Pending support",
      bundleIdentifier: "test.pending.support",
      fileURL: URL(fileURLWithPath: "/tmp/Pending-Support.app"), source: .none)
    let model = UpdatesListViewModel(settings: settings, appProvider: store)
    model.startObserving()
    defer { model.stopObserving() }
    let environment = AppEnvironment(settings: settings, updatesListViewModel: model)
    let window = try await makeLatestTestWindow(
      environment: environment, activate: false, testCase: self)
    defer { window.close() }
    let fixture = try SidebarInputFixture(window: window, model: model)

    let results: [Result<Latest.App.Update, Error>] = [
      .success(
        App.Update(
          app: bundle, remoteVersion: bundle.version, minimumOSVersion: nil, source: .appStore,
          date: nil, releaseNotes: .html(string: "<p>Current release notes</p>"),
          updateAction: .builtIn { _ in })),
      .failure(LatestError.updateInfoUnavailable),
    ]
    for result in results {
      store.beginUpdateCheck(generation: 1)
      let pending = store.set(nil, for: bundle)
      try await Task.sleep(for: .milliseconds(300))
      let header = try XCTUnwrap(
        fixture.accessibilityElements().first {
          $0.accessibilityIdentifier() == "release-notes.header"
        })
      func supportButton() throws -> SidebarAccessibilityElement {
        try XCTUnwrap(
          fixture.accessibilityElements().first {
            $0.accessibilityFrame().intersects(header.accessibilityFrame())
              && $0.accessibilityLabel() == model.selectedApp?.localizedSupportStatus
          })
      }
      XCTAssertEqual(try supportButton().accessibilityEnabled(), false)
      let resolved = try XCTUnwrap(store.accept(result, for: bundle))
      store.finishUpdateCheck(generation: 1)
      try await Task.sleep(for: .milliseconds(300))
      XCTAssertEqual(pending, resolved, "Installed app identity and version stay unchanged")
      XCTAssertTrue(model.selectedApp === resolved, "Selection must follow the resolved metadata")
      XCTAssertNil(model.snapshot.checkingGeneration)
      let bitmap = try await settledWindowBitmap(window)
      let attachment = XCTAttachment(
        image: NSImage(cgImage: try XCTUnwrap(bitmap.cgImage), size: bitmap.size))
      attachment.name = "resolved-support-\(resolved.source.rawValue)"
      attachment.lifetime = .keepAlways
      add(attachment)
      XCTAssertEqual(
        try supportButton().accessibilityEnabled(), true,
        "The selected header must replace Checking with the resolved support status")
    }
  }

  @MainActor
  func testDiscoveredRowsStayInPlaceAndRefreshRenderedMetadataDuringPendingScan() async throws {
    try requireUITests()
    let suite = "StartupRows.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppListSettings(userDefaults: defaults)
    settings.sortOrder = .name
    let store = AppDataStore(userDefaults: defaults)
    let firstBundle = App.Bundle(
      version: Version(versionNumber: "1", buildNumber: nil), name: "Pending Alpha",
      bundleIdentifier: "test.pending.alpha",
      fileURL: URL(fileURLWithPath: "/tmp/Pending-Alpha.app"), source: .none,
      modificationDate: .distantPast)
    let first = App(bundle: firstBundle, update: nil, isIgnored: false)
    let second = makeTestApp(name: "Pending Beta", version: "1", remoteVersion: "3")
    store.beginUpdateCheck(generation: 1)
    store.set(appBundles: [first.bundle, second.bundle])
    let model = UpdatesListViewModel(settings: settings, appProvider: store)
    model.startObserving()
    defer { model.stopObserving() }
    let environment = AppEnvironment(settings: settings, updatesListViewModel: model)
    let window = try await makeLatestTestWindow(environment: environment, testCase: self)
    defer { window.close() }
    let fixture = try SidebarInputFixture(window: window, model: model)
    try await fixture.activate()
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertEqual(
      model.snapshot.sections.flatMap(\.apps).map(\.identifier),
      [first.identifier, second.identifier])
    try fixture.click(row: try XCTUnwrap(model.snapshot.firstIndex(of: second)))
    try await Task.sleep(for: .milliseconds(100))
    let firstFrame = try fixture.contentFrame(for: first)
    let secondFrame = try fixture.contentFrame(for: second)
    let before = try await fixture.captureRow(for: first)
    let pendingRow = try XCTUnwrap(
      fixture.accessibilityElements().first {
        $0.accessibilityIdentifier() == "updates.app.\(first.identifier)"
      })
    XCTAssertTrue(
      pendingRow.accessibilityLabel()?.contains("Checking for updates") == true,
      "Unknown source must not be described as unsupported")
    let update = App.Update(
      app: first.bundle, remoteVersion: Version(versionNumber: "2", buildNumber: nil),
      minimumOSVersion: nil, source: .appStore, date: .now, releaseNotes: nil,
      updateAction: .builtIn { _ in })
    _ = store.accept(.success(update), for: first.bundle)
    try await Task.sleep(for: .milliseconds(250))
    let after = try await fixture.captureRow(for: first)
    XCTAssertEqual(try fixture.contentFrame(for: first), firstFrame)
    XCTAssertEqual(try fixture.contentFrame(for: second), secondFrame)
    XCTAssertEqual(model.selectedApp?.identifier, second.identifier)
    XCTAssertNotNil(model.snapshot.checkingGeneration, "Other provider is still pending")
    let row = try XCTUnwrap(
      fixture.accessibilityElements().first {
        $0.accessibilityIdentifier() == "updates.app.\(first.identifier)"
      })
    XCTAssertTrue(
      row.accessibilityLabel()?.contains("2") == true, "New version must reach the shipping row")
    // The version line must paint, not merely appear in accessibility metadata.
    var changedPixels = 0
    for y in 57..<85 {
      for x in 116..<420 {
        if before.colorAt(x: x, y: y) != after.colorAt(x: x, y: y) { changedPixels += 1 }
      }
    }
    XCTAssertGreaterThan(
      changedPixels, 20, "The previously absent remote-version line must be rendered")
    model.setSearchQuery("Beta")
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.identifier), [second.identifier])
    model.setSearchQuery("")
    XCTAssertEqual(
      model.snapshot.sections.flatMap(\.apps).map(\.identifier),
      [first.identifier, second.identifier])
  }

  @MainActor
  func testSidebarSearchAcceptsTypingClearAndEscapeRestoresListFocus() throws {
    try requireUITests()
    try runApplicationTest {
      try await self.checkSwiftUISidebarSearch()
    }
  }

  @MainActor
  func testSearchEscapeRestoresReleaseNotesAfterRepeatedFindCommands() throws {
    try requireUITests()
    try runApplicationTest {
      try await self.checkSearchEscapeRestoresReleaseNotesAfterRepeatedFindCommands()
    }
  }

  @MainActor
  private func checkSearchEscapeRestoresReleaseNotesAfterRepeatedFindCommands() async throws {
    let environment = AppEnvironment.localUATFixture(
      settings: try isolatedAppListSettings(for: self))
    let window = try await makeLatestTestWindow(environment: environment, testCase: self)
    let host = try XCTUnwrap(window.contentView)
    defer { window.close() }
    let fixture = try SidebarInputFixture(window: window, model: environment.updatesListViewModel)
    try await fixture.activate()
    func waitForFocus(_ stage: String, _ condition: () -> Bool) async throws {
      for _ in 0..<100 {
        // AppKit may assign its field editor before SwiftUI commits the new
        // responder's key handlers. Require focus to survive a main-loop turn.
        if condition() {
          try await Task.sleep(for: .milliseconds(10))
          if condition() { return }
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTFail(
        "Focus did not settle at \(stage); responder=\(String(describing: window.firstResponder)), key=\(window.isKeyWindow), active=\(NSApp.isActive)"
      )
      throw CocoaError(.coderInvalidValue)
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let web = try XCTUnwrap(host.descendant(of: WKWebView.self))
    try await waitForWebContent(web, containing: "Offline acceptance fixture")
    func focusReleaseNotes() throws {
      let location = web.convert(NSPoint(x: 40, y: 40), to: nil)
      try clickTestWindow(window, at: location)
    }
    try focusReleaseNotes()
    try await waitForFocus("initial release notes") { window.firstResponder === web }
    environment.commands.focusSearch()
    let search = try XCTUnwrap(host.descendant(of: NSTextField.self))
    try await waitForFocus("first Find") { search.currentEditor() === window.firstResponder }
    XCTAssertTrue(search.currentEditor() === window.firstResponder)
    environment.commands.focusSearch()
    // Do not yield after repeated Find: a pending request must not steal focus
    // back after the immediately following Escape.
    XCTAssertTrue(search.currentEditor() === window.firstResponder)
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
    window.sendEvent(escape)
    try await waitForFocus("Escape to release notes") { window.firstResponder === web }
    XCTAssertTrue(
      window.firstResponder === web, "Escape must return to the previously focused release notes")
    for listFocus in [true, false, true] {
      if listFocus { try fixture.focus() } else { try focusReleaseNotes() }
      // SwiftUI commits the click gesture after AppKit sends the mouse events.
      // Let that input finish before issuing the next keyboard command.
      try await Task.sleep(for: .milliseconds(50))
      let destination = window.firstResponder
      environment.commands.focusSearch()
      try await waitForFocus("Find from list=\(listFocus)") {
        search.currentEditor() === window.firstResponder
      }
      window.sendEvent(escape)
      try await waitForFocus("Escape to list=\(listFocus)") {
        window.firstResponder === destination
      }
      XCTAssertTrue(
        window.firstResponder === destination,
        "Escape must follow the latest focus destination when switching between list and notes")
    }
  }

  @MainActor
  func testHeldArrowNavigationKeepsRowsVisibleAndSeparate() throws {
    try requireUITests()
    try runApplicationTest {
      try await self.checkSwiftUISidebarNavigation()
    }
  }

  @MainActor
  func testSidebarSupportPreferenceUpdatesExistingRows() async throws {
    try requireUITests()
    let app = makeTestApp(name: "Example", version: "1")
    let suite = "SidebarSupport.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppListSettings(userDefaults: defaults)
    settings.showInstalledUpdates = true
    let store = AppDataStore(userDefaults: defaults)
    _ = store.set(appBundle: app.bundle)
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: [app], filterQuery: nil, settings: settings),
      settings: settings, appProvider: store)
    model.startObserving()
    defer { model.stopObserving() }
    let environment = AppEnvironment(settings: settings, updatesListViewModel: model)
    let window = try await makeLatestTestWindow(environment: environment, testCase: self)
    defer { window.close() }
    let fixture = try SidebarInputFixture(window: window, model: model)
    for visible in [true, false, true] {
      settings.includeAppsWithLimitedSupport = visible
      settings.includeUnsupportedApps = visible
      try await Task.sleep(for: .milliseconds(150))
      let bitmap = try await fixture.captureRow(for: app)
      var greenPixels = 0
      // Only the production status control, excluding the application's icon.
      for y in 35..<83 {
        for x in 502..<555 {
          let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
          if color.greenComponent - max(color.redComponent, color.blueComponent) > 0.2 {
            greenPixels += 1
          }
        }
      }
      if visible {
        XCTAssertGreaterThan(greenPixels, 20, "Supported app must paint the support dot")
      } else {
        XCTAssertEqual(greenPixels, 0, "Disabling support indicators must remove the painted dot")
      }
      XCTAssertEqual(model.snapshot.apps.map(\.identifier), [app.identifier])
    }
  }

  @MainActor
  private func waitForWebContent(_ web: WKWebView, containing text: String) async throws {
    let deadline = Date(timeIntervalSinceNow: 10)
    while Date() < deadline {
      if let body = try? await web.evaluateJavaScript("document.body.innerText") as? String,
        body.contains(text), !web.isLoading
      {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTFail("WebKit did not render expected content: \(text)")
  }

  @MainActor
  func testSidebarProgressActionCancelsOnlyItsInjectedOperation() async throws {
    try requireUITests()
    let queue = UpdateQueue()
    queue.isSuspended = true
    defer {
      queue.cancelAllOperations()
      queue.isSuspended = false
    }
    let service = AppUpdateService(queue: queue)
    let apps = Array(LocalUATFixture.apps.prefix(2))
    let operations = apps.map {
      UpdateOperation(bundleIdentifier: $0.bundleIdentifier, appIdentifier: $0.identifier)
    }
    for operation in operations { queue.addOperation(operation) }
    operations[0].progressState = .downloading(loadedSize: 25, totalSize: 100)
    let fixture = try await SidebarInputFixture.make(
      apps: apps, updating: service, testCase: self)
    defer { fixture.window.close() }
    try await fixture.clickProgress(for: apps[0])
    XCTAssertTrue(operations[0].isCancelled)
    XCTAssertFalse(operations[1].isCancelled, "Cancel must target the displayed app only")
  }

  private func makeFixture() async throws -> (SidebarInputFixture, AppEnvironment) {
    let settings = try isolatedAppListSettings(for: self)
    let apps = (0..<40).map { index in
      let bundle = Latest.App.Bundle(
        version: Version(versionNumber: "1.0", buildNumber: nil),
        name: String(format: "Sidebar App %02d", index),
        bundleIdentifier: "com.example.sidebar.\(index)",
        fileURL: URL(fileURLWithPath: "/Applications/Sidebar-\(index).app"), source: .appStore)
      let update = Latest.App.Update(
        app: bundle,
        remoteVersion: Version(versionNumber: "2.0", buildNumber: nil), minimumOSVersion: nil,
        source: .appStore, date: nil, releaseNotes: nil,
        updateAction: .builtIn { _ in })
      return Latest.App(
        bundle: bundle, update: index < 25 ? .success(update) : nil, isIgnored: false)
    }
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
      settings: settings)
    let environment = AppEnvironment(
      settings: settings, updatesListViewModel: model)
    NSApp.setActivationPolicy(.regular)
    let window = try await makeLatestTestWindow(environment: environment, testCase: self)
    let fixture = try SidebarInputFixture(window: window, model: model)
    try await fixture.activate()
    try await Task.sleep(for: .milliseconds(100))
    return (fixture, environment)
  }

  func checkSwiftUISidebarNavigation() async throws {
    let (fixture, _) = try await makeFixture()
    defer { fixture.window.close() }
    try fixture.focus()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(fixture.selectedRow, 1)
    try fixture.press(down: true)
    try await Task.sleep(for: .milliseconds(30))
    XCTAssertEqual(fixture.selectedRow, 2)
    XCTAssertTrue(fixture.model.isKeyboardSelection)

    var previousY: CGFloat = 0
    for _ in 0..<30 {
      try fixture.press(down: true)
      try await Task.sleep(for: .milliseconds(16))
      let y = fixture.scroll.contentView.bounds.minY
      XCTAssertGreaterThanOrEqual(y + 0.5, previousY)
      XCTAssertTrue(
        fixture.scroll.contentView.bounds.contains(fixture.rowRect(fixture.selectedRow)),
        "Selected row must remain fully visible: \(fixture.selectedRow), viewport=\(fixture.scroll.contentView.bounds)"
      )
      previousY = y
    }
    XCTAssertEqual(fixture.selectedRow, 33, "Arrow navigation must skip the second section heading")
    try fixture.press(down: false)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.selectedRow, 32)
    let reversedY = fixture.scroll.contentView.bounds.minY
    try await Task.sleep(for: .milliseconds(150))
    XCTAssertEqual(fixture.scroll.contentView.bounds.minY, reversedY, accuracy: 0.5)
    try fixture.click(row: fixture.selectedRow - 1)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.selectedRow, 31)
    XCTAssertFalse(fixture.model.isKeyboardSelection)
    for _ in 0..<50 {
      try fixture.press(down: true)
      try await Task.sleep(for: .milliseconds(8))
    }
    XCTAssertEqual(fixture.selectedRow, fixture.model.snapshot.entries.count - 1)
    for _ in 0..<50 {
      try fixture.press(down: false)
      try await Task.sleep(for: .milliseconds(8))
    }
    XCTAssertEqual(fixture.selectedRow, 1)
    XCTAssertEqual(fixture.scroll.contentView.bounds.minY, 0, accuracy: 0.5)
  }

  func checkSwiftUISidebarSearch() async throws {
    let (fixture, environment) = try await makeFixture()
    defer { fixture.window.close() }
    try fixture.focus()
    try await Task.sleep(for: .milliseconds(50))
    environment.commands.focusSearch()
    try await Task.sleep(for: .milliseconds(100))
    let editor = try XCTUnwrap(fixture.window.firstResponder as? NSTextView)
    editor.insertText("Sidebar App 00", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(fixture.model.snapshot.sections.flatMap(\.apps).count, 1)
    try await fixture.clickSearchClearButton()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(fixture.model.searchQuery, "")
    XCTAssertEqual(fixture.model.snapshot.sections.flatMap(\.apps).count, 40)
    XCTAssertTrue(fixture.window.firstResponder === editor)
    editor.insertText("Sidebar App 00", replacementRange: NSRange(location: NSNotFound, length: 0))
    try await Task.sleep(for: .milliseconds(100))
    environment.commands.focusSearch()
    let escape = try XCTUnwrap(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: fixture.window.windowNumber, context: nil,
        characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
    fixture.window.sendEvent(escape)
    try await Task.sleep(for: .milliseconds(100))
    // SwiftUI can temporarily retain the reusable AppKit field editor while
    // transferring focus. The following arrow must navigate the actual list.
    fixture.model.setSearchQuery("")
    try await Task.sleep(for: .milliseconds(100))
    try fixture.press(down: true)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.selectedRow, 2)
    XCTAssertTrue(fixture.model.isKeyboardSelection)
    let search = try XCTUnwrap(
      fixture.accessibilityElements().compactMap { $0.object as? NSTextField }.first)
    let searchFrame = search.convert(search.bounds, to: nil)
    try clickTestWindow(fixture.window, at: CGPoint(x: searchFrame.midX, y: searchFrame.midY))
    try await Task.sleep(for: .milliseconds(50))
    fixture.window.sendEvent(escape)
    try await Task.sleep(for: .milliseconds(100))
    try fixture.press(down: true)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.selectedRow, 3, "Mouse entry into search must also restore navigation")
    fixture.model.setSearchQuery("No matching app")
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(fixture.model.snapshot.sections.isEmpty)
    XCTAssertEqual(fixture.scroll.contentView.bounds.minY, 0, accuracy: 0.5)
    fixture.model.setSearchQuery("")
    try await Task.sleep(for: .milliseconds(100))
    try fixture.press(down: true)
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.selectedRow, 2)
  }

  func testSidebarScrollbarsAndEdgesKeepRowsInPlace() throws {
    try requireUITests()
    try runApplicationTest {
      let (fixture, _) = try await self.makeFixture()
      defer { fixture.window.close() }
      let app = try XCTUnwrap(fixture.model.snapshot.sections.first?.apps.first)
      let before = try fixture.contentFrame(for: app)
      fixture.scroll.flashScrollers()
      try await Task.sleep(for: .milliseconds(100))
      XCTAssertEqual(try fixture.contentFrame(for: app), before)
      XCTAssertEqual(fixture.scroll.contentSize.width, 308, accuracy: 0.5)
      for (position, delta) in [
        (CGFloat(0), Int32(1000)), (CGFloat.greatestFiniteMagnitude, Int32(-1000)),
      ] {
        let document = try XCTUnwrap(fixture.scroll.documentView)
        let maximum = max(0, document.bounds.height - fixture.scroll.contentSize.height)
        fixture.scroll(to: min(position, maximum))
        try fixture.wheel(dy: delta)
        for _ in 0..<8 {
          try await Task.sleep(for: .milliseconds(16))
          let bounds =
            fixture.scroll.contentView.layer?.presentation()?.bounds
            ?? fixture.scroll.contentView.bounds
          XCTAssertGreaterThanOrEqual(bounds.minY, -0.5)
          XCTAssertLessThanOrEqual(bounds.minY, maximum + 0.5)
        }
      }
      fixture.scroll(to: 0)
      try await Task.sleep(for: .milliseconds(100))
      let selected = fixture.model.selectedApp?.identifier
      let horizontalFrame = try fixture.contentFrame(for: app)
      for delta: Int32 in [200, -200] {
        try fixture.horizontalWheel(row: 1, dx: delta)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fixture.model.selectedApp?.identifier, selected)
        XCTAssertEqual(try fixture.contentFrame(for: app), horizontalFrame)
        XCTAssertFalse(
          fixture.accessibilityElements().contains {
            ["OpenAction", "RevealAction"].map { NSLocalizedString($0, comment: "") }
              .contains($0.accessibilityLabel() ?? "")
          }, "Horizontal input must not reveal row actions")
      }
      try fixture.wheel(dx: 200, dy: 0)
      try await Task.sleep(for: .milliseconds(50))
      XCTAssertEqual(fixture.scroll.contentView.bounds.minX, 0, accuracy: 0.5)
    }
  }
}

final class SidebarAccessibilityTest: XCTestCase {
  @MainActor
  func testSidebarRowBuildsACombinedVoiceOverLabel() throws {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let app = makeTestApp(
      name: "Discord",
      version: "1",
      remoteVersion: "2",
      date: Date(timeIntervalSince1970: 1_750_000_000)
    )

    let row = UpdateRowView(
      app: app, selection: UpdateRowSelection(),
      date: formatter.string(from: app.updateDate), showsSupportStatus: true,
      updating: AppUpdateService(queue: UpdateQueue()))
    let label = row.accessibilityLabel
    XCTAssertTrue(label.contains("Discord"))
    XCTAssertTrue(label.contains("1"))
    XCTAssertTrue(label.contains("2"))
    XCTAssertTrue(label.contains("2025-06-15"))
    XCTAssertTrue(label.contains(NSLocalizedString("UpdateAction", comment: "")))
  }

}
