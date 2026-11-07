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

enum Space {
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 20
  static let xxl: CGFloat = 24
}

@MainActor
enum VisualMetrics {
  /// Minimum content height; the native list owns row insets and section spacing.
  static let appRowHeight: CGFloat = 60

  static let mainWindowDefaultWidth: CGFloat = 768
  static let mainWindowDefaultHeight: CGFloat = 516
  static let mainWindowMinWidth: CGFloat = 350
  static let mainWindowMinHeight: CGFloat = 300

  static let sidebarIdealWidth: CGFloat = 308
  static let detailMinWidth: CGFloat = 460

  static let detailIconSize: CGFloat = 64

  // The app header sits below the native window toolbar.
  static let detailHeaderVerticalPadding: CGFloat = Space.sm
  static let detailHeaderHeight: CGFloat = detailIconSize + (detailHeaderVerticalPadding * 2)
  nonisolated static let detailHeaderHorizontalPadding: CGFloat = Space.xxl

}
