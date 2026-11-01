// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

@MainActor
enum UpdateActionPresentation: Equatable {
  case update
  case open
  case waiting(String)
  case retryTermination
  case progress(fraction: Double?, status: String, cancellable: Bool = true)
  case failed(String)

  static func make(for app: App, progressState: UpdateProgressState) -> Self {
    switch progressState {
    case .none:
      return app.updateAvailable ? .update : .open
    case .pending:
      return .waiting(
        NSLocalizedString(
          "WaitingUpdateStatus",
          comment: "Update progress state of waiting to start an update"
        ))
    case .initializing:
      return .waiting(
        NSLocalizedString(
          "InitializingUpdateStatus",
          comment: "Update progress state of initializing an update"
        ))
    case .downloading(let loadedSize, let totalSize, let cancellable):
      guard totalSize > 0 else {
        let status = String.localizedStringWithFormat(
          NSLocalizedString(
            "DownloadingUnknownSizeUpdateStatus",
            value: "Downloading %@…",
            comment: "Download progress when the server does not provide the final size"),
          Self.byteFormatter.string(fromByteCount: max(loadedSize, 0)))
        return .progress(fraction: nil, status: status, cancellable: cancellable)
      }
      let fraction = min(max(Double(loadedSize) / Double(totalSize), 0), 1) * 0.75
      let format = NSLocalizedString(
        "DownloadingUpdateStatus",
        comment: "Update progress state of downloading an update"
      )
      let status = String.localizedStringWithFormat(
        format,
        Self.byteFormatter.string(fromByteCount: loadedSize),
        Self.byteFormatter.string(fromByteCount: totalSize)
      )
      return .progress(fraction: fraction, status: status, cancellable: cancellable)
    case .extracting(let progress, let cancellable):
      return .progress(
        fraction: progress.map { min(max(0.75 + ($0 * 0.25), 0), 1) },
        status: NSLocalizedString(
          "ExtractingUpdateStatus",
          comment: "Update progress state of extracting the downloaded update"
        ),
        cancellable: cancellable
      )
    case .installing:
      return .waiting(
        NSLocalizedString(
          "InstallingUpdateStatus",
          comment: "Update progress state of installing an update"
        ))
    case .waitingForQuit:
      return .retryTermination
    case .error(let error):
      return .failed(error.localizedDescription)
    case .cancelling:
      return .waiting(
        NSLocalizedString(
          "CancellingUpdateStatus",
          comment: "Update progress state of cancelling an update"
        ))
    }
  }

  private static let byteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter
  }()
}
