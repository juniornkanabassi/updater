// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

/// Encapsulates different states that may be active during the update process.
enum UpdateProgressState: Sendable {
  /// No update is occurring at the moment.
  case none

  /// The update is currently waiting to be executed. This may happen due to external constraints like the Mac App Store update queue.
  case pending

  /// The download is currently initializing. This may be fetching update information from a server.
  case initializing

  /// The new version is currently downloading. Loaded size defines the already downloaded bytes. Total size defines the final size of the download.
  case downloading(loadedSize: Int64, totalSize: Int64, cancellable: Bool = true)

  /// The update is being extracted. Nil progress means the installer cannot measure it.
  case extracting(progress: Double?, cancellable: Bool = true)

  /// The update is currently installing.
  case installing

  /// Sparkle is ready to install but the target app has not finished quitting.
  case waitingForQuit

  /// An error occurred during updating.
  case error(Error)

  /// The update is currently being cancelled.
  case cancelling
}
