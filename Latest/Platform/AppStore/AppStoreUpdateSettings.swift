//
//  AppStoreUpdateCheckerOperation.swift
//  Latest
//
//  Created by Max Langer on 03.10.19.
//  Copyright © 2019 Max Langer. All rights reserved.
//

import Foundation

/// Collection of settings around app store updates
enum AppStoreUpdateSettings: String {
  /// Whether app store updates should always be performed manually.
  case alwaysPerformManualUpdates = "AlwaysPerformManualUpdates"

  /// Whether the setting is active.
  var active: Bool {
    get { UserDefaults.standard.bool(forKey: rawValue) }
    nonmutating set { UserDefaults.standard.set(newValue, forKey: rawValue) }
  }
}

/// Calls `onChange` when "Always open App Store" changes: the helper sheet's toggle and the
/// reset when the helper is enabled both write this plain defaults key. It turns App Store
/// installs into hand-offs, so the menu's Update All and the window's groups both follow it.
@MainActor
final class ManualAppStorePreferenceObserver {
  private nonisolated(unsafe) var token: NSObjectProtocol?
  private var last = AppStoreUpdateSettings.alwaysPerformManualUpdates.active

  init(onChange: @escaping @MainActor () -> Void) {
    token = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let current = AppStoreUpdateSettings.alwaysPerformManualUpdates.active
        guard current != self.last else { return }
        self.last = current
        onChange()
      }
    }
  }

  deinit { token.map(NotificationCenter.default.removeObserver) }
}
