// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import XCTest

import class SwiftUI.NSHostingView

@testable import Latest

// Exercise the shipping sidebar without opening a window or taking focus.
final class SidebarRenderingTest: XCTestCase {
  @MainActor
  func testUnchangedInstalledVersionRefreshesMountedSidebarMetadata() async throws {
    let settings = try isolatedAppListSettings(for: self)
    let suite = "OffscreenRows.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = AppDataStore(userDefaults: defaults)
    let installed = makeTestApp(name: "Chrome", version: "154.0.8037.98")
    _ = store.set(appBundle: installed.bundle)
    let model = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: store.apps, filterQuery: nil, settings: settings),
      settings: settings, appProvider: store)
    model.startObserving()
    defer { model.stopObserving() }
    let host = NSHostingView(
      rootView: UpdatesSidebarView(
        viewModel: model, searchFocusController: SearchFocusController()))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 308, height: 300),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    defer { window.close() }
    host.layoutSubtreeIfNeeded()
    let fixture = try SidebarInputFixture(window: window, model: model)
    func paint() throws {
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
    }
    try paint()
    try await Task.sleep(for: .milliseconds(150))
    model.select(installed)
    let identifier = "updates.app.\(installed.identifier)"
    XCTAssertTrue(
      fixture.accessibilityElements().contains { $0.accessibilityIdentifier() == identifier })
    for version in ["155.0.8059.40", "155.0.8059.41"] {
      let update = App.Update(
        app: installed.bundle, remoteVersion: Version(versionNumber: version, buildNumber: nil),
        minimumOSVersion: nil, source: .appStore, date: installed.updateDate,
        releaseNotes: installed.releaseNotes, updateAction: .builtIn { _ in })
      let refreshed = store.set(.success(update), for: installed.bundle)
      let deadline = ContinuousClock.now + .seconds(2)
      var label: String?
      repeat {
        try await Task.sleep(for: .milliseconds(10))
        try paint()
        label = fixture.accessibilityElements().first {
          $0.accessibilityIdentifier() == identifier
        }?.accessibilityLabel()
      } while label?.contains(version) != true && ContinuousClock.now < deadline
      XCTAssertTrue(model.selectedApp === refreshed)
      XCTAssertTrue(
        label?.contains(version) == true, "Shipping sidebar label: \(label ?? "missing")")
    }
  }
}
