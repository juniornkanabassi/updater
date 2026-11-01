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
final class AppUpdatingBoundaryTest: XCTestCase {
  func testIsolatedServiceRoutesActionsAndHonorsBulkAndQueuedGuards() {
    let calls = Mutex(0)
    let queue = UpdateQueue()
    queue.isSuspended = true
    defer {
      queue.cancelAllOperations()
      queue.isSuspended = false
    }
    let service = AppUpdateService(queue: queue)
    let app = makeApp(action: .builtIn { _ in calls.withLock { $0 += 1 } })
    service.update(app)
    XCTAssertEqual(calls.withLock { $0 }, 1)

    let operation = UpdateOperation(
      bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
    queue.addOperation(operation)
    XCTAssertTrue(service.isUpdating(app))
    service.update(app)
    XCTAssertEqual(calls.withLock { $0 }, 1, "An active operation must suppress duplicate actions")
    service.cancel(app)
    XCTAssertTrue(operation.isCancelled)
    XCTAssertFalse(
      UpdateQueue.shared.contains(app.identifier), "Injected queue must not touch the live queue")

    let external = makeApp(
      action: .external(label: "Vendor", block: { _ in calls.withLock { $0 += 1 } }))
    service.update(external, isBulkUpdate: true)
    XCTAssertEqual(calls.withLock { $0 }, 1)
    service.update(external)
    XCTAssertEqual(calls.withLock { $0 }, 2)
  }

  func testActionModelObservesInjectedQueueAndReleasesWhileStreamIsOpen() async {
    let queue = UpdateQueue()
    queue.isSuspended = true
    defer {
      queue.cancelAllOperations()
      queue.isSuspended = false
    }
    let service = AppUpdateService(queue: queue)
    let app = makeApp(action: .builtIn { _ in })
    let operation = UpdateOperation(
      bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
    queue.addOperation(operation)
    var model: UpdateActionViewModel? = UpdateActionViewModel(app: app, updating: service)
    XCTAssertEqual(model?.presentation, .make(for: app, progressState: .pending))
    operation.progressState = .downloading(loadedSize: 50, totalSize: 100)
    for _ in 0..<100 {
      if model?.presentation == .make(for: app, progressState: operation.progressState) { break }
      await Task.yield()
    }
    XCTAssertEqual(model?.presentation, .make(for: app, progressState: operation.progressState))
    model?.performAction()
    XCTAssertTrue(
      operation.isCancelled, "Progress control must cancel the injected queue's operation")
    weak let weakModel = model
    model = nil
    XCTAssertNil(
      weakModel, "The observation task must not retain its owner across stream suspension")
  }

  func testProgressCanBeReadAndUpdatedConcurrentlyAndCallbackCanReenter() {
    let app = makeApp(action: .builtIn { _ in })
    let operation = UpdateOperation(
      bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
    let notifications = Mutex(0)
    operation.progressHandler = { [weak operation] _ in
      _ = operation?.progressState
      notifications.withLock { $0 += 1 }
    }
    DispatchQueue.concurrentPerform(iterations: 500) { index in
      operation.progressState = .downloading(loadedSize: Int64(index), totalSize: 500)
      _ = operation.progressState
    }
    XCTAssertEqual(notifications.withLock { $0 }, 501)
  }

  func testCommittedInstallIgnoresLateCancellationAndPublishesSuccess() throws {
    for commit in [false, true] {
      let app = makeApp(action: .builtIn { _ in })
      let operation = UpdateOperation(
        bundleIdentifier: app.bundleIdentifier, appIdentifier: app.identifier)
      let notices = Mutex(0)
      let observer = NotificationCenter.default.addObserver(
        forName: .latestUpdateOperationDidFinish, object: operation, queue: nil
      ) { _ in notices.withLock { $0 += 1 } }
      defer { NotificationCenter.default.removeObserver(observer) }
      if commit { try operation.beginCommit() }
      operation.cancel()
      if !commit { XCTAssertThrowsError(try operation.beginCommit()) }
      operation.finish()
      XCTAssertEqual(operation.isCancelled, !commit)
      XCTAssertEqual(notices.withLock { $0 }, commit ? 1 : 0)
    }
  }

  private func makeApp(action: App.Update.Action) -> App {
    let bundle = App.Bundle(
      version: Version(versionNumber: "1.0", buildNumber: nil),
      name: "Isolated", bundleIdentifier: "test.isolated",
      fileURL: URL(fileURLWithPath: "/tmp/Isolated-\(UUID().uuidString).app"),
      source: .sparkle, modificationDate: .distantPast)
    let update = App.Update(
      app: bundle, remoteVersion: Version(versionNumber: "2.0", buildNumber: nil),
      minimumOSVersion: nil, source: .sparkle, date: nil,
      releaseNotes: nil, updateAction: action)
    return App(bundle: bundle, update: .success(update), isIgnored: false)
  }
}
