//
//  Source.swift
//  Latest
//
//  Created by Max Langer on 14.03.22.
//  Copyright © 2022 Max Langer. All rights reserved.
//

extension App {

  /// The source of update information.
  enum Source: String, Equatable, Sendable {
    /// No known source had information about this app. It is unsupported by the update checker.
    case none

    /// The Sparkle Updater is the update source.
    case sparkle

    /// The Mac App Store is the update source.
    case appStore

    /// Homebrew is the update source.
    case homebrew

    /// A vendor-signed standalone application download installed within Latest.
    case directDownload

    /// A vendor feed whose installer must be opened outside Latest.
    case vendor

  }
}

// MARK: - Support State

extension App.Source {
  /// Possible states for whether a source is supported by the app.
  // Referenced by supportState and presentation; the analyzer misses contextual cases.
  // swiftlint:disable:next unused_declaration
  enum SupportState: Sendable {
    /// The source is fully supported, including in-app updates.
    case full

    /// There is some update information available, but it may be incomplete. In-app updates do not work.
    case limited

    /// The source is unknown and no update information is available.
    case none
  }

  /// Whether the source is supported by the app.
  var supportState: SupportState {
    switch self {
    case .none:
      return .none
    case .sparkle, .appStore, .directDownload:
      return .full
    case .homebrew, .vendor:
      return .limited
    }
  }
}
