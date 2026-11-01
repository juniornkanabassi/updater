//
//  File.swift
//  Latest
//
//  Created by Max Langer on 05.01.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

import Foundation

/// The combined representation of an app bundle and its associated update information.
final class App: Sendable {

  /// The bundle of the locally available app.
  let bundle: App.Bundle

  /// The result of an attempted update fetch operation.
  private let updateResult: Result<Update, Error>?

  /// Whether the app is ignored.
  let isIgnored: Bool

  // MARK: - Initialization

  /// Initializes the app with the given parameters.
  init(bundle: App.Bundle, update: Result<Update, Error>?, isIgnored: Bool) {
    self.bundle = bundle
    self.updateResult = Self.sanitize(update: update, for: bundle)
    self.isIgnored = isIgnored
  }

  /// Returns a new app object with an updated bundle.
  func with(bundle: Bundle) -> App {
    return App(bundle: bundle, update: self.updateResult, isIgnored: self.isIgnored)
  }

  /// Returns a new app object with an updated ignored state.
  func with(ignoredState: Bool) -> App {
    return App(bundle: self.bundle, update: self.updateResult, isIgnored: ignoredState)
  }

  // MARK: - Sanitization

  /// Sanitizes the update result for the given app bundle.
  ///
  /// Used to clean up version information based on information provided by the app bundle.
  private static func sanitize(update: Result<Update, Error>?, for bundle: App.Bundle) -> Result<
    Update, Error
  >? {
    guard let update = try? update?.get() else {
      return update
    }

    return .success(update.sanitized(for: bundle))
  }

}

/// Convenience access to underlying properties.
extension App {

  private var update: Update? {
    switch updateResult {
    case .success(let update):
      return update
    default:
      return nil
    }
  }

  /// A missing result means unknown, rather than an unsupported or current app.
  var isSourcePending: Bool { source == .none && updateResult == nil }

  var error: Error? {
    switch updateResult {
    case .failure(let error):
      return error
    default:
      return nil
    }
  }

  // MARK: - Bundle Properties

  // The version currently present on the users computer
  var version: Version { bundle.version }

  /// The display name of the app
  var name: String { bundle.name }

  /// The bundle identifier of the app
  var identifier: Bundle.Identifier { bundle.identifier }

  var bundleIdentifier: String { bundle.bundleIdentifier }

  /// The url of the app on the users computer
  var fileURL: URL { bundle.fileURL }

  /// The overall source the update is being fetched from.
  var source: Source {
    update?.source ?? bundle.source
  }

  /// Whether the app can be updated within Latest.
  var supported: Bool {
    self.source != .none
  }

  /// The date of the app when it was last updated.
  var updateDate: Date {
    self.update?.date ?? self.bundle.modificationDate
  }

  // MARK: - Update Properties

  /// The newest version of the app available for download.
  var remoteVersion: Version? { update?.remoteVersion }

  /// The release date of the update
  var latestUpdateDate: Date? { update?.date }

  /// The release notes of the update
  var releaseNotes: Update.ReleaseNotes? { update?.releaseNotes }

  /// Whether an update is available for the given app.
  var updateAvailable: Bool {
    self.update?.updateAvailable ?? false
  }

  /// Whether the update is performed using a built in updater.
  var usesBuiltInUpdater: Bool {
    self.update?.usesBuiltInUpdater ?? false
  }

  /// The name of the external updater used to update this app.
  ///
  /// Returns `nil` if `usesBuiltInUpdater` is `true`.
  var externalUpdaterName: String? {
    self.update?.externalUpdaterName
  }

  /// The source-provided action, executed by the updating service.
  var updateAction: Update.Action? { update?.updateAction }

}

extension App: Hashable {

  static func == (lhs: App, rhs: App) -> Bool {
    return lhs.identifier == rhs.identifier && lhs.version == rhs.version
  }

  /// Versions at the same path share a bucket; equality also checks the version.
  func hash(into hasher: inout Hasher) {
    hasher.combine(self.identifier)
  }

}

extension App: CustomDebugStringConvertible {
  var debugDescription: String {
    return
      "App:\n\t- Bundle: \(self.bundle)\n\t- Update: \(self.update?.debugDescription ?? "None"))"

  }
}
