//
//  UpdateQueueTest.swift
//  Latest Tests
//
//  Created by ertyoii on 28.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-05-28.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import Synchronization
import XCTest

@testable import Latest

@MainActor
final class UpdateCheckDiscoveryTest: XCTestCase {
  func testPostInstallRefreshRejectsOlderCheckInTheSameGeneration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let appURL = root.appendingPathComponent("Installed.app")
    let plist = appURL.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(
      at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    func writeVersion(_ version: String) throws {
      let data = try PropertyListSerialization.data(
        fromPropertyList: [
          "CFBundleName": "Installed", "CFBundleIdentifier": "test.discovery.installed",
          "CFBundleShortVersionString": version, "CFBundlePackageType": "APPL",
          "SUFeedURL": "https://example.invalid/appcast.xml",
        ], format: .xml, options: 0)
      try data.write(to: plist, options: .atomic)
    }
    try writeVersion("1")
    let original = try XCTUnwrap(BundleCollector.collectBundle(at: appURL))
    let oldStarted = expectation(description: "Old installed version check started")
    let newStarted = expectation(description: "New installed version check started")
    let refreshed = expectation(description: "New installed version accepted")
    let checks = SuspendedDiscoveryChecks { bundle in
      (bundle.version.versionNumber == "1" ? oldStarted : newStarted).fulfill()
    }
    let coordinator = UpdateCheckCoordinator(
      check: { bundle, _ in try await checks.check(bundle) }, repositoryProvider: { nil })
    let finished = expectation(description: "Both check batches finished")
    finished.expectedFulfillmentCount = 2
    let progress = DiscoveryCheckProgress(finished: finished) { app in
      if app.version.versionNumber == "2" { refreshed.fulfill() }
    }
    coordinator.progressDelegate = progress
    coordinator.updateDiscoveredBundles([original])
    await fulfillment(of: [oldStarted], timeout: 2)
    try writeVersion("2")
    NotificationCenter.default.post(
      name: .latestUpdateOperationDidFinish, object: nil,
      userInfo: [UpdateOperation.appIdentifierUserInfoKey: appURL])
    await fulfillment(of: [newStarted], timeout: 2)
    await checks.complete("Installed", installedVersion: "2", remoteVersion: "3")
    await fulfillment(of: [refreshed], timeout: 2)
    await checks.complete("Installed", installedVersion: "1", remoteVersion: "3")
    await fulfillment(of: [finished], timeout: 2)
    XCTAssertEqual(coordinator.appProvider.updatableApps.first?.version.versionNumber, "2")
    XCTAssertEqual(progress.checked.count, 1, "Old metadata must not overwrite the refresh")
  }

  func testDiscoveryPublishesRowsAndResultsBeforeSlowProviderFinishes() async throws {
    let started = expectation(description: "Both providers started")
    started.expectedFulfillmentCount = 2
    let checks = SuspendedDiscoveryChecks { _ in started.fulfill() }
    let coordinator = UpdateCheckCoordinator(
      check: { bundle, _ in try await checks.check(bundle) }, repositoryProvider: { nil })
    let settings = try isolatedAppListSettings(for: self)
    let model = UpdatesListViewModel(settings: settings, appProvider: coordinator.appProvider)
    let discovered = expectation(
      description: "Discovered rows visible with both providers suspended")
    let incremental = expectation(
      description: "First result visible while another provider is suspended")
    let finished = expectation(description: "Scan finished")
    let progress = DiscoveryCheckProgress(finished: finished)
    coordinator.progressDelegate = progress
    var didDiscover = false
    var didPublishResult = false
    let observation = model.$snapshot.sink { snapshot in
      if snapshot.apps.count == 2, !didDiscover {
        didDiscover = true
        discovered.fulfill()
      }
      if snapshot.apps.first(where: { $0.name == "A" })?.remoteVersion != nil,
        !didPublishResult
      {
        didPublishResult = true
        incremental.fulfill()
      }
    }
    defer {
      observation.cancel()
      model.stopObserving()
    }
    model.startObserving()
    coordinator.updateDiscoveredBundles([bundle("A"), bundle("B")])
    await fulfillment(of: [started, discovered], timeout: 2)
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["A", "B"])
    XCTAssertEqual(model.selectedApp?.name, "A")
    await checks.complete("A", date: Date(timeIntervalSince1970: 10))
    await fulfillment(of: [incremental], timeout: 2)
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["A", "B"])
    XCTAssertEqual(model.selectedApp?.name, "A")
    XCTAssertEqual(model.selectedApp?.remoteVersion?.versionNumber, "3")
    XCTAssertEqual(progress.checked.count, 1)
    await checks.fail("B")
    await fulfillment(of: [finished], timeout: 2)
  }

  func testSettlementRefreshAndResubscriptionPreserveSelectionAndPublishCurrentMetadata()
    async throws
  {
    let initialStarted = expectation(description: "Initial checks started")
    initialStarted.expectedFulfillmentCount = 2
    let refreshStarted = expectation(description: "Refresh checks started")
    refreshStarted.expectedFulfillmentCount = 3
    let startedCount = Mutex(0)
    let checks = SuspendedDiscoveryChecks { _ in
      let count = startedCount.withLock {
        $0 += 1
        return $0
      }
      (count <= 2 ? initialStarted : refreshStarted).fulfill()
    }
    defer { Task { await checks.completeAll() } }
    let coordinator = UpdateCheckCoordinator(
      check: { bundle, _ in try await checks.check(bundle) }, repositoryProvider: { nil })
    let settings = try isolatedAppListSettings(for: self)
    settings.sortOrder = .updateDate
    let model = UpdatesListViewModel(settings: settings, appProvider: coordinator.appProvider)
    model.startObserving()
    defer { model.stopObserving() }
    coordinator.updateDiscoveredBundles([bundle("A"), bundle("B")])
    await fulfillment(of: [initialStarted], timeout: 2)
    try await waitForSnapshot(model) { $0.apps.count == 2 }
    XCTAssertEqual(model.selectedApp?.name, "A")
    await checks.complete("B", remoteVersion: "1", date: Date(timeIntervalSince1970: 20))
    try await waitForSnapshot(model) {
      $0.apps.first(where: { $0.name == "B" })?.remoteVersion != nil
    }
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["A", "B"])
    await checks.complete("A", remoteVersion: "1", date: Date(timeIntervalSince1970: 10))
    try await waitForSnapshot(model) { $0.checkingGeneration == nil }
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["B", "A"])
    XCTAssertEqual(
      model.selectedApp?.name, "A", "Automatic initial selection must also survive settlement")
    let identifier = try XCTUnwrap(model.selectedApp?.identifier)
    coordinator.updateDiscoveredBundles(
      [bundle("A"), bundle("B"), bundle("C")], forceRefresh: true)
    await fulfillment(of: [refreshStarted], timeout: 2)
    try await waitForSnapshot(model) { $0.apps.count == 3 && $0.checkingGeneration != nil }
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["B", "A", "C"])
    XCTAssertEqual(
      model.selectedApp?.remoteVersion?.versionNumber, "1",
      "Refresh retains last known result while awaiting replacement")
    await checks.complete("A", date: Date(timeIntervalSince1970: 30))
    try await waitForSnapshot(model) {
      $0.apps.first(where: { $0.name == "A" })?.remoteVersion?.versionNumber == "3"
    }
    XCTAssertEqual(model.selectedApp?.identifier, identifier)
    XCTAssertEqual(model.selectedApp?.remoteVersion?.versionNumber, "3")
    model.setSearchQuery("A")
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["A"])
    model.setSearchQuery("")
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["B", "A", "C"])
    model.stopObserving()
    model.startObserving()
    var iterator = coordinator.appProvider.updates().makeAsyncIterator()
    let current = await iterator.next()
    XCTAssertNotNil(current?.checkingGeneration)
    XCTAssertEqual(
      current?.apps.first(where: { $0.name == "A" })?.remoteVersion?.versionNumber, "3")
    XCTAssertNil(current?.apps.first(where: { $0.name == "C" })?.remoteVersion)
    await checks.fail("B")
    try await waitForSnapshot(model) { $0.apps.first(where: { $0.name == "B" })?.error != nil }
    XCTAssertEqual(model.snapshot.sections.flatMap(\.apps).map(\.name), ["B", "A", "C"])
    await checks.complete("C", remoteVersion: "1", date: Date(timeIntervalSince1970: 40))
    try await waitForSnapshot(model) { $0.checkingGeneration == nil }
    XCTAssertEqual(model.snapshot.sections.map { $0.apps.map(\.name) }, [["A"], ["C", "B"]])
    XCTAssertEqual(model.selectedApp?.identifier, identifier)
    coordinator.updateDiscoveredBundles([])
    try await waitForSnapshot(model) { $0.apps.isEmpty }
    XCTAssertNil(model.selectedApp)
  }

  private func waitForSnapshot(
    _ model: UpdatesListViewModel, _ condition: (AppListSnapshot) -> Bool
  ) async throws {
    for _ in 0..<200 {
      if condition(model.snapshot) { return }
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("Expected current app-list publication did not arrive")
    throw CocoaError(.coderInvalidValue)
  }

  func testUnchangedDiscoveryKeepsPendingChecks() async {
    let started = expectation(description: "Both checks started")
    started.expectedFulfillmentCount = 2
    let checks = SuspendedDiscoveryChecks { _ in started.fulfill() }
    let coordinator = UpdateCheckCoordinator(
      check: { bundle, _ in try await checks.check(bundle) },
      repositoryProvider: {
        XCTFail("Sparkle-only scans must not load the Homebrew catalog")
        return nil
      })
    let progress = DiscoveryCheckProgress(finished: expectation(description: "Scan finished"))
    coordinator.progressDelegate = progress
    let bundles = [bundle("A"), bundle("B")]

    coordinator.updateDiscoveredBundles(bundles)
    await fulfillment(of: [started], timeout: 2)
    coordinator.updateDiscoveredBundles([bundle("B"), bundle("A")])
    await checks.completeAll()
    await fulfillment(of: [progress.finished], timeout: 2)

    XCTAssertEqual(
      Set(coordinator.appProvider.updatableApps.map(\.identifier)), Set(bundles.map(\.identifier)))
    XCTAssertEqual(progress.checked.count, 2)
    XCTAssertEqual(progress.batchSizes, [2])
  }

  func testChangedDiscoveryRechecksRetainedAppsAndRejectsRemovedResults() async {
    let initialStarted = expectation(description: "Initial checks started")
    initialStarted.expectedFulfillmentCount = 3
    let replacementStarted = expectation(description: "Changed and retained apps rechecked")
    replacementStarted.expectedFulfillmentCount = 2
    let startedCount = Mutex(0)
    let checks = SuspendedDiscoveryChecks { _ in
      let count = startedCount.withLock {
        $0 += 1
        return $0
      }
      (count <= 3 ? initialStarted : replacementStarted).fulfill()
    }
    let coordinator = UpdateCheckCoordinator(
      check: { bundle, _ in try await checks.check(bundle) }, repositoryProvider: { nil })
    let progress = DiscoveryCheckProgress(
      finished: expectation(description: "Replacement scan finished"))
    coordinator.progressDelegate = progress
    let replacementPublication = expectation(description: "Replacement discovery visible")
    var publishedApps = [App]()
    var didPublishReplacement = false
    let stream = coordinator.appProvider.updates()
    let observation = Task {
      for await update in stream {
        publishedApps = update.apps
        if update.apps.count == 2,
          update.apps.first(where: { $0.name == "A" })?.version.versionNumber == "2",
          !didPublishReplacement
        {
          didPublishReplacement = true
          replacementPublication.fulfill()
        }
      }
    }
    defer { observation.cancel() }

    coordinator.updateDiscoveredBundles([bundle("A"), bundle("B"), bundle("Removed")])
    await fulfillment(of: [initialStarted], timeout: 2)
    let replacement = [bundle("A", version: "2"), bundle("B")]
    coordinator.updateDiscoveredBundles(replacement)
    await fulfillment(of: [replacementStarted], timeout: 2)
    // Finish the cancelled generation while the replacement checks are still pending.
    await checks.complete("A")
    await checks.complete("B")
    await checks.complete("Removed")
    await fulfillment(of: [replacementPublication], timeout: 2)
    XCTAssertEqual(Set(publishedApps.map(\.identifier)), Set(replacement.map(\.identifier)))
    XCTAssertTrue(publishedApps.allSatisfy { $0.remoteVersion == nil })
    XCTAssertTrue(progress.checked.isEmpty)
    await checks.completeAll()
    await fulfillment(of: [progress.finished], timeout: 2)

    let apps = coordinator.appProvider.updatableApps
    XCTAssertEqual(Set(apps.map(\.identifier)), Set(replacement.map(\.identifier)))
    XCTAssertEqual(apps.first { $0.name == "A" }?.version.versionNumber, "2")
    XCTAssertEqual(progress.batchSizes, [3, 2])
    XCTAssertEqual(progress.checked.count, 2)
    var iterator = coordinator.appProvider.updates().makeAsyncIterator()
    let final = await iterator.next()
    XCTAssertEqual(Set(final?.apps.map(\.identifier) ?? []), Set(replacement.map(\.identifier)))
    XCTAssertNil(final?.checkingGeneration)
  }

  private func bundle(_ name: String, version: String = "1") -> App.Bundle {
    App.Bundle(
      version: Version(versionNumber: version, buildNumber: nil), name: name,
      bundleIdentifier: "test.discovery.\(name)", fileURL: URL(fileURLWithPath: "/tmp/\(name).app"),
      source: .sparkle, modificationDate: .distantPast)
  }
}

private actor SuspendedDiscoveryChecks {
  private let started: @Sendable (App.Bundle) -> Void
  private var pending = [(App.Bundle, CheckedContinuation<App.Update, Error>)]()

  init(started: @escaping @Sendable (App.Bundle) -> Void) {
    self.started = started
  }

  func check(_ bundle: App.Bundle) async throws -> App.Update {
    try await withCheckedThrowingContinuation { continuation in
      pending.append((bundle, continuation))
      started(bundle)
    }
  }

  func completeAll() {
    while let (bundle, _) = pending.first {
      complete(bundle.name)
    }
  }

  func complete(
    _ name: String, installedVersion: String? = nil, remoteVersion: String = "3", date: Date? = nil
  ) {
    guard
      let index = pending.firstIndex(where: {
        $0.0.name == name
          && (installedVersion == nil || $0.0.version.versionNumber == installedVersion)
      })
    else { return }
    let (bundle, continuation) = pending.remove(at: index)
    continuation.resume(
      returning: App.Update(
        app: bundle, remoteVersion: Version(versionNumber: remoteVersion, buildNumber: nil),
        minimumOSVersion: nil, source: .sparkle, date: date, releaseNotes: nil,
        updateAction: .builtIn { _ in }))
  }

  func fail(_ name: String) {
    guard let index = pending.firstIndex(where: { $0.0.name == name }) else { return }
    let (_, continuation) = pending.remove(at: index)
    continuation.resume(throwing: LatestError.updateInfoUnavailable)
  }
}

@MainActor
private final class DiscoveryCheckProgress: UpdateCheckProgressReporting {
  let finished: XCTestExpectation
  var checked = [App]()
  var batchSizes = [Int]()
  private let checkedHandler: ((App) -> Void)?

  init(finished: XCTestExpectation, checked: ((App) -> Void)? = nil) {
    self.finished = finished
    self.checkedHandler = checked
  }
  func updateCheckerDidStartScanningForApps(_ updateChecker: UpdateCheckCoordinator) {}
  func updateChecker(
    _ updateChecker: UpdateCheckCoordinator, didStartCheckingApps count: Int, generation: Int
  ) {
    batchSizes.append(count)
  }
  func updateChecker(_ updateChecker: UpdateCheckCoordinator, didCheckApp app: App) {
    checked.append(app)
    checkedHandler?(app)
  }
  func updateCheckerDidFinishCheckingForUpdates(
    _ updateChecker: UpdateCheckCoordinator, generation: Int
  ) {
    finished.fulfill()
  }
}
