//
//  AppPerformanceTest.swift
//  Latest Tests
//
//  Created by ertyoii on 19.07.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-01.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Darwin
import Darwin.Mach
import SwiftUI
import WebKit
import XCTest

@testable import Latest

@MainActor
final class AppPerformanceTest: XCTestCase {
  func testKeyboardSelectionPreparationPerformance() throws {
    guard FileManager.default.fileExists(atPath: Self.benchmarkFlagURL.path) else {
      throw XCTSkip("Run script/benchmark_app.sh to execute app-performance benchmarks.")
    }
    // Embedded changelogs vary greatly in size. Passing a row with held arrows
    // should not hash its payload before the existing quiet interval expires.
    for payloadBytes in [1_024, 1_048_576] {
      let notes = String(repeating: "x", count: payloadBytes)
      let apps = makeApps(count: 120).map { app in
        let update = Latest.App.Update(
          app: app.bundle, remoteVersion: Version(versionNumber: "2.0", buildNumber: nil),
          minimumOSVersion: nil, source: .appStore, date: nil,
          releaseNotes: .html(string: notes), updateAction: .builtIn { _ in })
        return Latest.App(bundle: app.bundle, update: .success(update), isIgnored: false)
      }
      let model = ReleaseNotesDetailViewModel(
        releaseNotesProvider: ImmediateReleaseNotesProvider(
          text: ReleaseNotesContent(string: "Notes")))
      benchmarkSamples("keyboard_selection_preparation_\(payloadBytes)", values: apps) { app in
        model.display(app, waitForSelectionToSettle: true)
        return model.app === app ? 1 : 0
      }
      XCTAssertTrue(model.app === apps.last)
      model.display(nil)
    }
  }

  func testAppPerformanceMatrix() throws {
    guard FileManager.default.fileExists(atPath: Self.benchmarkFlagURL.path) else {
      throw XCTSkip("Run script/benchmark_app.sh to execute app-performance benchmarks.")
    }
    try runApplicationTest { try await self.measureAppPerformanceMatrix() }
  }

  private func measureAppPerformanceMatrix() async throws {
    let settings = try isolatedAppListSettings(for: self)
    emitConfigurationLine()
    let appsBySize = Dictionary(
      uniqueKeysWithValues: [100, 500, 1_500].map { ($0, makeApps(count: $0)) })

    for rowCount in [100, 500, 1_500] {
      let apps = try XCTUnwrap(appsBySize[rowCount])
      let snapshot = AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings)
      let queries = (0..<60).map { "Benchmark App \($0 % max(rowCount / 10, 1))" }
      benchmarkSamples("sidebar_filter_\(rowCount)", values: queries) { query in
        snapshot.refiltered(with: query).entries.count
      }
    }

    let populatedApps = try XCTUnwrap(appsBySize[500])
    benchmark("cold_launch_to_populated_sidebar_fixture", iterations: 30) {
      let snapshot = AppListSnapshot(
        withApps: populatedApps, filterQuery: nil, settings: settings)
      let viewModel = UpdatesListViewModel(snapshot: snapshot, settings: settings)
      let host = NSHostingView(
        rootView: UpdatesSidebarView(
          viewModel: viewModel,
          searchFocusController: SearchFocusController()
        ))
      host.frame = NSRect(x: 0, y: 0, width: VisualMetrics.sidebarIdealWidth, height: 640)
      let window = attachToWindow(host)
      withExtendedLifetime(window) {
        host.displayIfNeeded()
      }
      return snapshot.apps.count
    }

    let scanRoot = try makeSyntheticAppRoot(count: 120)
    defer { try? FileManager.default.removeItem(at: scanRoot) }
    benchmark("scan_to_stable_snapshot_fixture", iterations: 30) {
      let bundles = BundleCollector.collectBundles(at: scanRoot)
      let apps = bundles.map { Latest.App(bundle: $0, update: nil, isIgnored: false) }
      return AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings).entries.count
    }

    let detailApps = Array(populatedApps.prefix(80))
    let detailViewModel = UpdatesListViewModel(
      snapshot: AppListSnapshot(withApps: detailApps, filterQuery: nil, settings: settings),
      settings: settings)
    let detailState = ReleaseNotesDetailViewModel(
      releaseNotesProvider: ImmediateReleaseNotesProvider(
        text: ReleaseNotesContent(string: "App benchmark release notes")
      )
    )
    let detailHost = NSHostingView(
      rootView: ReleaseNotesDetailView(
        updatesViewModel: detailViewModel,
        detailViewModel: detailState
      ))
    detailHost.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
    let detailWindow = attachToWindow(detailHost)
    defer { detailWindow.close() }
    detailHost.layoutSubtreeIfNeeded()
    let memoryBefore = residentMemoryBytes()
    benchmarkSamples("selection_to_detail", values: Array(0..<160)) { index in
      let app = detailApps[index % detailApps.count]
      detailViewModel.select(app)
      // The production view routes the same selection into this persistent state
      // object from its task. Keep the host alive so this measures selection,
      // detail-state publication, and rendering rather than root reconstruction.
      detailState.display(app)
      detailHost.layoutSubtreeIfNeeded()
      detailHost.displayIfNeeded()
      return detailState.app?.identifier == app.identifier ? 1 : 0
    }
    let memoryAfter = residentMemoryBytes()
    emitMemoryLine(
      name: "repeated_selection_160",
      before: memoryBefore,
      after: memoryAfter
    )

    let markup = makeReleaseNotesMarkup(sectionCount: 220)
    try benchmark("rich_text_normalization_serialization", iterations: 30) {
      let text = try ReleaseNotesMarkup.attributedString(
        from: markup,
        baseURL: URL(string: "https://example.com/changelog"),
        relevantVersion: "220.0"
      ).get()
      // Measure the shipping serializer; WebKit paint is covered below by
      // provider-to-render measurements rather than an unrelated text layout.
      return ReleaseNotesWebDocument.html(for: text).utf8.count
    }

    let resizeSnapshot = AppListSnapshot(
      withApps: try XCTUnwrap(appsBySize[1_500]), filterQuery: nil, settings: settings)
    let environment = AppEnvironment(
      updatesListViewModel: UpdatesListViewModel(snapshot: resizeSnapshot, settings: settings)
    )
    let splitHost = NSHostingView(rootView: LatestRootView(environment: environment))
    splitHost.frame = NSRect(x: 0, y: 0, width: 1_000, height: 640)
    let splitWindow = attachToWindow(splitHost)
    defer { splitWindow.close() }
    benchmarkSamples("resize_split_frame", values: Array(0..<100)) { index in
      let width = index.isMultiple(of: 2) ? 700.0 : 1_300.0
      splitHost.frame.size = NSSize(width: width, height: index.isMultiple(of: 3) ? 480 : 760)
      splitHost.layoutSubtreeIfNeeded()
      return Int(splitHost.bounds.width)
    }

    let settingsViewModel = SettingsViewModel()
    benchmark("settings_locations_refresh", iterations: 40) {
      settingsViewModel.refreshDirectories()
      return settingsViewModel.directoryURLs.count
    }
  }

  private static var benchmarkFlagURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("build/run-app-benchmarks")
  }

  func testReleaseNotesSelectionPerformance() throws {
    guard FileManager.default.fileExists(atPath: Self.benchmarkFlagURL.path) else {
      throw XCTSkip("Run script/benchmark_app.sh to execute selection benchmarks.")
    }
    let settings = try isolatedAppListSettings(for: self)
    let apps = makeApps(count: 30)
    for mode in ["cold", "disk", "memory"] {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      defer { try? FileManager.default.removeItem(at: directory) }
      let cache = ReleaseNotesPersistentCache(directoryURL: directory)
      let provider = ReleaseNotesProvider(persistentCache: cache)
      if mode != "cold" {
        let seeded = expectation(description: "Seed isolated cache")
        Task { @MainActor in
          for app in apps {
            let resolved = ResolvedReleaseNotes(
              content: ReleaseNotesContent(string: "Cached notes for \(app.name)"),
              quality: .genuine, provenance: .changelog)
            let payload = ReleaseNotesPersistentCache.payload(from: resolved)
            await cache.store(payload, forKey: ReleaseNotesCacheKey(app: app).stableIdentifier)
          }
          seeded.fulfill()
        }
        wait(for: [seeded], timeout: 10)
      }
      if mode == "memory" {
        for app in apps {
          let loaded = expectation(description: "Warm provider cache")
          provider.releaseNotes(for: app) { _ in loaded.fulfill() }
          wait(for: [loaded], timeout: 3)
        }
      }
      let model = UpdatesListViewModel(
        snapshot: AppListSnapshot(withApps: apps, filterQuery: nil, settings: settings),
        settings: settings)
      let detail = ReleaseNotesDetailViewModel(releaseNotesProvider: provider)
      let host = NSHostingView(
        rootView: ReleaseNotesDetailView(updatesViewModel: model, detailViewModel: detail))
      host.frame = NSRect(x: 0, y: 0, width: 720, height: 640)
      let window = attachToWindow(host)
      defer { window.close() }
      let memoryBefore = residentMemoryBytes()
      var heapBefore = malloc_statistics_t()
      malloc_zone_statistics(nil, &heapBefore)
      benchmarkSamples("selection_to_render_\(mode)", values: apps) { app in
        model.select(app)
        // Drive the actual SwiftUI selection task, provider, and text view. A
        // previously rendered app's content must not satisfy this sample.
        let deadline = Date(timeIntervalSinceNow: 3)
        var rendered = false
        var renderedText = ""
        var checkingContent = false
        repeat {
          host.layoutSubtreeIfNeeded()
          host.displayIfNeeded()
          if let web = host.descendant(of: WKWebView.self), !checkingContent {
            checkingContent = true
            web.evaluateJavaScript("document.body.innerText") { result, _ in
              renderedText = result as? String ?? ""
              checkingContent = false
            }
          }
          if detail.app === app, case .text(let text) = detail.contentState,
            renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
              == text.string.trimmingCharacters(in: .whitespacesAndNewlines),
            renderedText.contains(app.name)
              || renderedText.contains("app \(apps.firstIndex(where: { $0 === app })!).")
          {
            rendered = true
            break
          }
          RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001))
        } while Date() < deadline
        XCTAssertTrue(rendered, "Selection did not render: \(mode) / \(app.name)")
        return rendered ? 1 : 0
      }
      emitMemoryLine(
        name: "selection_to_render_\(mode)", before: memoryBefore, after: residentMemoryBytes())
      var heapAfter = malloc_statistics_t()
      malloc_zone_statistics(nil, &heapAfter)
      let line =
        "APP_HEAP name=selection_to_render_\(mode) live_bytes_before=\(heapBefore.size_in_use) live_bytes_after=\(heapAfter.size_in_use) live_blocks_before=\(heapBefore.blocks_in_use) live_blocks_after=\(heapAfter.blocks_in_use)"
      FileHandle.standardError.write(Data((line + "\n").utf8))
    }
  }

  private func benchmark(
    _ name: String,
    iterations: Int,
    operation: () throws -> Int
  ) rethrows {
    try benchmarkSamples(name, values: Array(0..<iterations)) { _ in try operation() }
  }

  private func benchmarkSamples<Value>(
    _ name: String,
    values: [Value],
    operation: (Value) throws -> Int
  ) rethrows {
    var samples = [Double]()
    var checksum = 0
    for value in values {
      let start = DispatchTime.now().uptimeNanoseconds
      checksum &+= try operation(value)
      let end = DispatchTime.now().uptimeNanoseconds
      samples.append(Double(end - start) / 1_000_000)
    }

    let sorted = samples.sorted()
    emitBenchmarkLine(
      name: name,
      iterations: samples.count,
      minimum: samples.min() ?? 0,
      average: samples.reduce(0, +) / Double(max(samples.count, 1)),
      median: percentile(0.50, in: sorted),
      p95: percentile(0.95, in: sorted),
      maximum: samples.max() ?? 0,
      checksum: checksum
    )
  }

  private func percentile(_ value: Double, in sortedSamples: [Double]) -> Double {
    guard !sortedSamples.isEmpty else { return 0 }
    let index = Int((Double(sortedSamples.count - 1) * value).rounded(.up))
    return sortedSamples[index]
  }

  private func emitBenchmarkLine(
    name: String,
    iterations: Int,
    minimum: Double,
    average: Double,
    median: Double,
    p95: Double,
    maximum: Double,
    checksum: Int
  ) {
    let line = String(
      format:
        "APP_BENCHMARK name=%@ iterations=%d min_ms=%.3f avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f max_ms=%.3f checksum=%d",
      name, iterations, minimum, average, median, p95, maximum, checksum
    )
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  private func emitMemoryLine(name: String, before: UInt64, after: UInt64) {
    let delta = Int64(bitPattern: after) - Int64(bitPattern: before)
    let line =
      "APP_MEMORY name=\(name) before_bytes=\(before) after_bytes=\(after) delta_bytes=\(delta)"
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  private func emitConfigurationLine() {
    #if DEBUG
      let configuration = "Debug"
    #else
      let configuration = "Release"
    #endif
    let line = "APP_CONFIGURATION sidebar=swiftui configuration=\(configuration)"
    FileHandle.standardError.write(Data((line + "\n").utf8))
  }

  private func residentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? info.resident_size : 0
  }

  private func attachToWindow<Content: View>(_ host: NSHostingView<Content>) -> NSWindow {
    let window = NSWindow(
      contentRect: host.bounds,
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    return window
  }

  private func makeApps(count: Int) -> [Latest.App] {
    (0..<count).map { index in
      let bundle = Latest.App.Bundle(
        version: Version(versionNumber: "1.\(index)", buildNumber: nil),
        name: "Benchmark App \(index)",
        bundleIdentifier: "com.example.app-performance.\(index)",
        fileURL: URL(fileURLWithPath: "/Applications/App-\(index).app", isDirectory: true),
        source: .appStore
      )
      let update = Latest.App.Update(
        app: bundle,
        remoteVersion: Version(versionNumber: "2.\(index)", buildNumber: nil),
        minimumOSVersion: nil,
        source: .appStore,
        date: Date(timeIntervalSince1970: 1_750_000_000 + Double(index)),
        releaseNotes: .html(
          string: "<h2>Version 2.\(index)</h2><p>App fixture notes for app \(index).</p>"),
        updateAction: .builtIn { _ in }
      )
      return Latest.App(bundle: bundle, update: .success(update), isIgnored: index % 17 == 0)
    }
  }

  private func makeReleaseNotesMarkup(sectionCount: Int) -> String {
    (0..<sectionCount).map { index in
      "<h2>Version \(index).0</h2><p>Improved update discovery and fixed layout issue \(index).</p>"
    }.joined(separator: "\n")
  }

  private func makeSyntheticAppRoot(count: Int) throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("LatestAppBenchmark-\(UUID().uuidString)", isDirectory: true)
    for index in 0..<count {
      let contents =
        root
        .appendingPathComponent("Group-\(index / 20)", isDirectory: true)
        .appendingPathComponent("App-\(index).app/Contents", isDirectory: true)
      try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
      let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.synthetic-app-performance.\(index)",
        "CFBundleName": "Synthetic App \(index)",
        "CFBundleShortVersionString": "1.\(index)",
        "CFBundleVersion": "\(index)",
      ]
      let data = try PropertyListSerialization.data(
        fromPropertyList: info, format: .binary, options: 0)
      try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
    return root
  }
}

@MainActor
private final class ImmediateReleaseNotesProvider: ReleaseNotesProviding {
  private let text: ReleaseNotesContent

  init(text: ReleaseNotesContent) {
    self.text = text
  }

  func releaseNotes(
    for app: Latest.App,
    with completion: @escaping ReleaseNotesProvider.Completion
  ) {
    completion(.success(text))
  }
}
