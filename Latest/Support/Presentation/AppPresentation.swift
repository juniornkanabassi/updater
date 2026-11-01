//
//  AppPresentation.swift
//  Latest
//
//  Presentation adapters for domain values.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-09-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit

extension App {
  var localizedSupportStatus: String {
    isSourcePending
      ? NSLocalizedString(
        "PendingSupportStatus", value: "Checking for updates",
        comment: "Support is unknown until the update lookup finishes")
      : source.supportState.label
  }

  /// Localized version information suitable for display in the interface.
  struct DisplayableVersionInformation {
    private(set) var rawCurrent: String
    private(set) var rawNew: String?

    var current: String {
      String(
        format: NSLocalizedString(
          "LocalVersionFormat",
          comment:
            "The current version of a locally installed app. The placeholder %@ is the version number."
        ),
        rawCurrent
      )
    }

    var new: String? {
      rawNew.map { version in
        String(
          format: NSLocalizedString(
            "RemoteVersionFormat",
            comment:
              "The most recent version available for an app. The placeholder %@ is the version number."
          ),
          version
        )
      }
    }

    func combined(includeNew: Bool) -> String {
      if let rawNew, includeNew, rawCurrent != rawNew {
        return String(
          format: NSLocalizedString(
            "CombinedVersionFormat",
            comment:
              "The current and available version numbers. The first placeholder is current; the second is available."
          ),
          rawCurrent,
          rawNew
        )
      }

      return String(
        format: NSLocalizedString(
          "SingleCombinedVersionFormat",
          comment: "The current version number."
        ),
        rawCurrent
      )
    }
  }

  var localizedVersionInformation: DisplayableVersionInformation? {
    let currentVersion = version
    let newVersion = remoteVersion
    var information: DisplayableVersionInformation?

    if let current = currentVersion.versionNumber, let new = newVersion?.versionNumber {
      information = DisplayableVersionInformation(rawCurrent: current, rawNew: new)

      if updateAvailable,
        current == new,
        let currentBuild = currentVersion.buildNumber,
        let newBuild = newVersion?.buildNumber
      {
        information = DisplayableVersionInformation(
          rawCurrent: "\(current) (\(currentBuild))",
          rawNew: "\(new) (\(newBuild))"
        )
      }
    } else if let current = currentVersion.buildNumber, let new = newVersion?.buildNumber {
      information = DisplayableVersionInformation(rawCurrent: current, rawNew: new)
    } else if let current = currentVersion.versionNumber ?? currentVersion.buildNumber {
      information = DisplayableVersionInformation(rawCurrent: current, rawNew: nil)
    }

    return information
  }

}

extension App.Source.SupportState {

  var statusImage: NSImage {
    let name =
      switch self {
      case .full: NSImage.statusAvailableName
      case .limited: NSImage.statusPartiallyAvailableName
      case .none: NSImage.statusUnavailableName
      }

    return NSImage(named: name)!
  }

  var label: String {
    switch self {
    case .full:
      NSLocalizedString("SupportedLabel", comment: "A label for apps fully supported by Latest.")
    case .limited:
      NSLocalizedString(
        "LimitedSupportLabel", comment: "A label for apps partially supported by Latest.")
    case .none:
      NSLocalizedString("UnsupportedLabel", comment: "A label for apps not supported by Latest.")
    }
  }

  var compactLabel: String {
    switch self {
    case .full:
      NSLocalizedString(
        "SupportedCompactLabel", comment: "A compact label for fully supported apps.")
    case .limited:
      NSLocalizedString(
        "LimitedSupportCompactLabel", comment: "A compact label for partially supported apps.")
    case .none:
      NSLocalizedString("UnsupportedCompactLabel", comment: "A compact label for unsupported apps.")
    }
  }

}
