//
//  SettingsViewModel.swift
//  Latest
//
//  Created by ertyoii on 03.06.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import Combine
import Foundation

@MainActor
final class SettingsViewModel: ObservableObject {
  typealias DirectoryStoreFactory = (@escaping AppDirectoryUpdateHandler) -> any AppDirectoryStoring

  enum Tab: CaseIterable, Hashable {
    case general
    case locations

    var title: String {
      switch self {
      case .general:
        return "General"
      case .locations:
        return "Locations"
      }
    }

  }

  @Published var selectedTab: Tab = .general
  @Published private(set) var directoryURLs: [URL] = []
  @Published var selectedDirectory: URL?
  @Published private(set) var showsInstallHelperBanner = false
  @Published var helperRegistrationError: String?

  private let settings: any AppListSettingsProviding
  private let installHelperService: any InstallHelperServicing
  private let directoryStoreFactory: DirectoryStoreFactory
  private lazy var directoryStore = directoryStoreFactory { [weak self] in
    self?.refreshDirectories()
  }

  init(
    settings: any AppListSettingsProviding = AppListSettings.shared,
    installHelperService: any InstallHelperServicing = LiveInstallHelperService.shared,
    directoryStoreFactory: @escaping DirectoryStoreFactory = {
      AppDirectoryStore(updateHandler: $0)
    }
  ) {
    self.settings = settings
    self.installHelperService = installHelperService
    self.directoryStoreFactory = directoryStoreFactory
    refreshDirectories()
    refreshInstallHelperAvailability()
  }

  var includeAppsWithLimitedSupport: Bool {
    get {
      settings.includeAppsWithLimitedSupport
    }
    set {
      settings.includeAppsWithLimitedSupport = newValue
      objectWillChange.send()
    }

  }

  var includeUnsupportedApps: Bool {
    get {
      settings.includeUnsupportedApps
    }
    set {
      settings.includeUnsupportedApps = newValue
      objectWillChange.send()
    }
  }

  func refreshInstallHelperAvailability() {
    do {
      try installHelperService.verifyAvailability()
      showsInstallHelperBanner = false
    } catch {
      showsInstallHelperBanner = true
    }
  }

  func registerInstallHelper() {
    do {
      try installHelperService.register()
    } catch {
      helperRegistrationError = [
        error.localizedDescription, (error as? LocalizedError)?.failureReason,
      ]
      .compactMap { $0 }.joined(separator: "\n\n")
    }
    refreshInstallHelperAvailability()
  }

  func canRemove(_ url: URL?) -> Bool {
    guard let url else { return false }
    return directoryStore.canRemove(url)
  }

  func addDirectories(_ urls: [URL]) {
    urls.forEach(directoryStore.add)
    refreshDirectories()
  }

  func removeSelectedDirectory() {
    guard let selectedDirectory, directoryStore.canRemove(selectedDirectory) else { return }
    directoryStore.remove(selectedDirectory)
    self.selectedDirectory = nil
    refreshDirectories()
  }

  /// Refreshes locations and clears selection when its directory was removed.
  func refreshDirectories() {
    MigrationTelemetry.shared.measureSettingsRefresh {
      directoryURLs = directoryStore.URLs
      if let selectedDirectory, !directoryURLs.contains(selectedDirectory) {
        self.selectedDirectory = nil
      }
    }
  }
}
