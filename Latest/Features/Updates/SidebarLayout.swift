// Fork contributions © 2026 ertyoii. Licensed under GPL-3.0; see LICENSE.md.

import CoreGraphics

/// The ordered layout is built once per snapshot and shared by keyboard
/// scrolling. Headers and their trailing gaps retain their measured geometry.
@MainActor
struct SidebarLayout {
  let frames: [CGRect]
  let contentHeight: CGFloat

  init(entries: [AppListSnapshot.Entry]) {
    var frames: [CGRect] = []
    frames.reserveCapacity(entries.count)
    var y: CGFloat = 0
    for entry in entries {
      let isHeader: Bool
      if case .section = entry { isHeader = true } else { isHeader = false }
      let height = isHeader ? VisualMetrics.sectionHeaderHeight : VisualMetrics.appRowHeight
      frames.append(CGRect(x: 0, y: y, width: VisualMetrics.sidebarIdealWidth, height: height))
      y += height + (isHeader ? VisualMetrics.sectionHeaderSpacing : 0)
    }
    self.frames = frames
    contentHeight = y
  }

}
