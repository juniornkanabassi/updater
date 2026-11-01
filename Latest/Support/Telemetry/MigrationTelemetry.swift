//
//  MigrationTelemetry.swift
//  Latest
//
//  Created by ertyoii on 19.07.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-01.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation
import OSLog

/// Signposts discovery, selection, scrolling, and release-note loading for Instruments.
@MainActor
final class MigrationTelemetry {
  static let shared = MigrationTelemetry()

  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
    category: "MigrationPerformance"
  )
  private let signposter = OSSignposter(
    subsystem: Bundle.main.bundleIdentifier ?? "com.max-langer.Latest",
    category: "MigrationPerformance"
  )

  private var coldLaunchInterval: OSSignpostIntervalState?
  private var scanInterval: OSSignpostIntervalState?
  private var selectionInterval: OSSignpostIntervalState?
  private var sidebarScrollInterval: OSSignpostIntervalState?

  private init() {}

  func applicationStarted() {
    guard coldLaunchInterval == nil else { return }
    coldLaunchInterval = signposter.beginInterval("Cold Launch to Populated Sidebar")
  }

  func scanStarted() {
    guard scanInterval == nil else { return }
    scanInterval = signposter.beginInterval("Scan to Stable Snapshot")
  }

  func scanFinished(appCount: Int) {
    guard let scanInterval else { return }
    signposter.endInterval("Scan to Stable Snapshot", scanInterval)
    self.scanInterval = nil
    logger.info("Update scan stabilized with \(appCount, privacy: .public) apps")
  }

  func snapshotCommitted(rowCount: Int, appCount: Int) {
    signposter.emitEvent(
      "Sidebar Snapshot Committed",
      "rows=\(rowCount) apps=\(appCount)"
    )

    guard appCount > 0, let coldLaunchInterval else { return }
    signposter.endInterval("Cold Launch to Populated Sidebar", coldLaunchInterval)
    self.coldLaunchInterval = nil
  }

  func measureFilter<T>(rowCount: Int, operation: () -> T) -> T {
    let state = signposter.beginInterval("Sidebar Filter")
    let start = DispatchTime.now().uptimeNanoseconds
    let result = operation()
    let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    signposter.endInterval("Sidebar Filter", state)
    logger.debug("Filtered \(rowCount, privacy: .public) rows in \(duration, privacy: .public) ms")
    return result
  }

  func selectionStarted(appName: String) {
    if let selectionInterval {
      signposter.endInterval("Selection to Detail", selectionInterval)
    }
    selectionInterval = signposter.beginInterval("Selection to Detail")
    logger.debug("Selection changed to \(appName, privacy: .private)")
  }

  func detailCommitted() {
    guard let selectionInterval else { return }
    signposter.endInterval("Selection to Detail", selectionInterval)
    self.selectionInterval = nil
  }

  func beginSidebarScroll() {
    guard sidebarScrollInterval == nil else { return }
    sidebarScrollInterval = signposter.beginInterval("Sidebar Live Scroll")
  }

  func endSidebarScroll() {
    guard let sidebarScrollInterval else { return }
    signposter.endInterval("Sidebar Live Scroll", sidebarScrollInterval)
    self.sidebarScrollInterval = nil
  }

  func measureSettingsRefresh<T>(_ operation: () -> T) -> T {
    let state = signposter.beginInterval("Settings Locations Refresh")
    defer { signposter.endInterval("Settings Locations Refresh", state) }
    return operation()
  }
}
