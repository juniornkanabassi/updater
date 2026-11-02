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

/// Plain-language descriptions of what Update does for an app, shared by the list, the detail
/// pane and the menu bar. They read the capability; they never decide it.
@MainActor
extension App {
  /// The second line of a row and the menu bar: versions, or why there is none.
  var versionSummary: String {
    if availabilityUnknown, let vendor = externalUpdaterName { return "Check in \(vendor)" }
    guard let versions = localizedVersionInformation else { return "" }
    if updateAvailable, let new = versions.rawNew { return "\(versions.rawCurrent) → \(new)" }
    return versions.rawCurrent
  }

  /// The row's third line when nothing is running: where the update happens, in a few words.
  var routeShortDescription: String {
    if isUpdaterItself { return "This app" }
    if isIgnored { return "Ignored" }
    if isSourcePending { return "Checking…" }
    if isActionable {
      switch capability {
      case .install, .vendorTool: return "Via \(sourceName)"
      case .handOff, .unsupported: break
      }
      if relaunchesToUpdate {
        return SidebarUpdateActionTitle.isRunning(self) ? "Relaunch to apply" : "Open to apply"
      }
      if availabilityUnknown { return "Opens \(externalUpdaterName ?? "its vendor's app")" }
      if externalUpdaterName == HomebrewCheckerOperation.handOffLabel {
        return "Needs your password in Terminal"
      }
      if externalUpdaterName == name { return "Updates from inside the app" }
      return "Opens \(externalUpdaterName ?? "another app")"
    }
    if error != nil { return "Couldn't check" }
    if remoteVersion == nil { return "No update source found" }
    return "Up to date"
  }

  /// One sentence above the release notes saying exactly what clicking the button does.
  var updateExplanation: String {
    if isUpdaterItself { return "This is Updater. It can't update itself yet." }
    if isSourcePending { return "Checking for updates…" }
    if isActionable {
      let new = remoteVersion?.versionNumber.map { " \($0)" } ?? ""
      switch capability {
      case .install:
        return
          "Update downloads version\(new) and installs it here. Updater keeps the old copy until it has checked the new version on disk."
      case .vendorTool:
        return
          "Update runs the developer's own updater, then Updater checks the new version on disk."
      case .handOff, .unsupported: break
      }
      if relaunchesToUpdate {
        return SidebarUpdateActionTitle.isRunning(self)
          ? "\(name) has already downloaded this update. Relaunch quits and reopens it so the update applies."
          : "\(name) has already downloaded this update. Open starts it so the update applies."
      }
      if availabilityUnknown {
        return
          "\(externalUpdaterName ?? "The vendor") doesn't tell other apps whether an update is waiting. Open it to check and update there."
      }
      if externalUpdaterName == HomebrewCheckerOperation.handOffLabel {
        return
          "This update needs your administrator password. Updater copies the brew command and opens Terminal: paste it and press Return."
      }
      if externalUpdaterName == name {
        return "\(name) updates itself. Open it and use its own update command."
      }
      return
        "Updater can't install this one itself. Open \(externalUpdaterName ?? "the updater") and finish the update there."
    }
    if let error { return "Updater couldn't check this app: \(error.localizedDescription)" }
    if remoteVersion == nil {
      return "Updater can't find an update source for this app. Check the app or its website."
    }
    return "You have the latest version."
  }

  /// Who provides the version information, for "Updates via".
  var sourceName: String {
    switch source {
    case .sparkle: "Sparkle"
    case .appStore: "App Store"
    case .homebrew: "Homebrew"
    case .directDownload: "Developer download"
    case .vendor:
      capability == .vendorTool ? "Developer's updater" : externalUpdaterName ?? "Developer"
    case .none: "None found"
    }
  }
}
