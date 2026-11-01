// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import Foundation

enum ToolbarProgressPresentation: Equatable {
  case hidden
  case determinate(Double)

  init(isRunning: Bool, fraction: Double?) {
    guard isRunning else {
      self = .hidden
      return
    }
    // Discovery has no app count yet; keep the same empty track until checking starts.
    self = .determinate(ToolbarProgressMetrics.normalized(fraction ?? 0))
  }
}

enum ToolbarProgressMetrics {
  static let width: CGFloat = 64
  static let leadingPadding: CGFloat = 10
  static let trailingPadding: CGFloat = 10

  static func normalized(_ fraction: Double) -> Double {
    min(max(fraction, 0), 1)
  }
}
