//
//  VisualMetrics.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import CoreGraphics

@MainActor
enum VisualMetrics {
  /// The original AppKit table resolves its prototype rows to 60 points at
  /// runtime. Keep the production list on that measured cadence; the former
  /// 65-point synthetic fixture made every following row drift farther down.
  static let appRowHeight: CGFloat = 60
  static let sectionHeaderHeight: CGFloat = 27
  static let sectionHeaderSpacing: CGFloat = 10

  static let mainWindowDefaultWidth: CGFloat = 768
  static let mainWindowDefaultHeight: CGFloat = 516
  static let mainWindowMinWidth: CGFloat = 350
  static let mainWindowMinHeight: CGFloat = 300

  static let sidebarIdealWidth: CGFloat = 308
  static let detailMinWidth: CGFloat = 460

  static let detailIconSize: CGFloat = 64

  // The app header sits below the native window toolbar.
  static let detailHeaderVerticalPadding: CGFloat = 7.5
  static let detailHeaderHeight: CGFloat = detailIconSize + (detailHeaderVerticalPadding * 2)
  static let detailHeaderHorizontalPadding: CGFloat = 24
  // SwiftUI Text reserves more ascent space than the original NSTextField
  // stack. These measured offsets align the visible glyph baselines while the
  // header, icon, and action retain their native layout frames.
  static let detailMetadataVerticalOffset: CGFloat = -7
  static let detailMetadataLineVerticalCorrection: CGFloat = 1
  static let detailTitleVerticalCorrection: CGFloat = 0
  static let supportStatusHorizontalCorrection: CGFloat = -1
  static let detailUpdateButtonWidth: CGFloat = 59
  static let detailUpdateButtonHeight: CGFloat = 24

}
