//
//  VersionInfo.swift
//  Latest
//
//  Created by Max Langer on 01.11.17.
//  Copyright © 2017 Max Langer. All rights reserved.
//

import Foundation

extension App {

  /**
   A simple class holding the update information for a single app.
   */
  final class Update: Equatable, Sendable {

    /// The update for which this update exists.
    let app: App.Bundle

    /// The newest version of the app available for download.
    let remoteVersion: Version

    /// The minimum version required to perform this update.
    let minimumOSVersion: OperatingSystemVersion?

    /// The entity the update is being sourced from.
    let source: Source

    /// The release date of the update
    let date: Date?

    /// The release notes of the update
    let releaseNotes: ReleaseNotes?

    /// A handler performing the update action of the app.
    let updateAction: Action

    /// Initializes the update with the given parameters.
    init(
      app: App.Bundle, remoteVersion: Version, minimumOSVersion: OperatingSystemVersion?,
      source: Source, date: Date?, releaseNotes: ReleaseNotes?, updateAction: Action
    ) {
      self.app = app
      self.remoteVersion = remoteVersion
      self.minimumOSVersion = minimumOSVersion
      self.source = source
      self.date = date
      self.releaseNotes = releaseNotes
      self.updateAction = updateAction
    }

    /// Whether an update is available for the given app.
    var updateAvailable: Bool {
      var updateAvailable = app.version.comparisonForUpdate(to: remoteVersion) == .older

      if updateAvailable, let minimumOSVersion {
        updateAvailable = ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumOSVersion)
      }

      return updateAvailable
    }

    /// Whether the update is performed using a built in updater.
    var usesBuiltInUpdater: Bool {
      externalUpdaterName == nil || source == .appStore
    }

    /// The name of the external updater used to update this app.
    var externalUpdaterName: String? {
      if case .external(let label, _) = updateAction { label } else { nil }
    }

    // MARK: - Sanitization

    /// Returns a sanitized update for the given app bundle.
    func sanitized(for bundle: App.Bundle) -> Update {
      let version = remoteVersion.sanitize(with: bundle.version)
      // Keep the vendor's original representation when normalization preserves precedence.
      guard version.comparisonForUpdate(to: remoteVersion) != .samePrecedence || app !== bundle
      else {
        return self
      }

      return Update(
        app: bundle, remoteVersion: version, minimumOSVersion: minimumOSVersion, source: source,
        date: date, releaseNotes: releaseNotes, updateAction: updateAction)
    }

    // MARK: - Equatable

    /// Compares the equality of UpdateInfo objects
    static func == (lhs: Update, rhs: Update) -> Bool {
      return lhs.remoteVersion == rhs.remoteVersion && lhs.date == rhs.date
    }

  }

}

extension App.Update {

  /// Provides several types of release notes.
  enum ReleaseNotes: Sendable {

    /// The url from which release notes can be fetched.
    case url(url: URL)

    /// The release notes in form of pre-formatted HTML.
    case html(string: String)

    /// Generic package-manager information. This is useful provenance for an
    /// update, but it must not be scored or presented as genuine vendor notes.
    case genericMetadata(string: String)

    /// Release notes encoded in the given data object.
    case encoded(data: Data)

    /// The release notes for a GitHub release.
    case githubRelease(apiURL: URL, fallbackHTML: String?)

    /// Product changelog pages that should be filtered to the relevant version.
    case changelog(
      urls: [URL], versionPrefix: String?, allowsLatestFallback: Bool, fallbackHTML: String?)

  }

}

extension App.Update: CustomDebugStringConvertible {
  var debugDescription: String {
    return self.remoteVersion.debugDescription
  }
}

extension App.Update {

  typealias UpdateAction = @Sendable (_ app: App.Bundle) -> Void

  /// Defines possible update actions.
  enum Action: Sendable {

    /// The update will be performed within this app.
    case builtIn(block: UpdateAction)

    /// No updater is available to update this app. An external program will be launched to perform the update.
    case external(label: String, block: UpdateAction)

    /// Performs the update for the given bundle.
    func perform(with bundle: App.Bundle, isBulkUpdate: Bool) {
      switch self {
      case .builtIn(let block):
        block(bundle)
      case .external(_, let block):
        if !isBulkUpdate { block(bundle) }
      }
    }
  }

}
