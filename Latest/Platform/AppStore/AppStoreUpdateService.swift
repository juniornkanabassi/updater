//
//  AppStoreUpdateService.swift
//  Latest
//
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import Foundation

@MainActor
protocol AppStoreUpdateServicing: AnyObject {
  var alwaysUsesManualUpdates: Bool { get }
  func verifyAvailability() throws(InstallHelperError)
}

@MainActor
final class LiveAppStoreUpdateService: AppStoreUpdateServicing {
  static let shared = LiveAppStoreUpdateService()

  private init() {}

  var alwaysUsesManualUpdates: Bool {
    AppStoreUpdateSettings.alwaysPerformManualUpdates.active
  }

  func verifyAvailability() throws(InstallHelperError) {
    try AppStoreUpdater.verifyAvailability()
  }
}
