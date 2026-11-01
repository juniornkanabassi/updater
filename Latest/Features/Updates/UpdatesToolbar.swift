//
//  UpdatesToolbar.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

/// Observe scan progress at the toolbar boundary, without invalidating the app list.
struct UpdatesToolbar: ToolbarContent {
  @ObservedObject var service: UpdateCheckingService
  let reload: () -> Void

  var body: some ToolbarContent {
    ToolbarSpacer(.flexible, placement: .primaryAction)
    ToolbarItem(placement: .primaryAction) {
      ToolbarUpdateProgressView(
        presentation: ToolbarProgressPresentation(
          isRunning: service.isRunning, fraction: service.progressFraction))
    }
    // Passive scan status stays outside the refresh action's glass group.
    .sharedBackgroundVisibility(.hidden)
    ToolbarItem(placement: .primaryAction) {
      RefreshToolbarButton(isEnabled: !service.isRunning, action: reload)
    }
  }
}

struct RefreshToolbarButton: View {
  let isEnabled: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label("Check for Updates", systemImage: "arrow.clockwise")
    }
    .labelStyle(.iconOnly)
    .help(
      NSLocalizedString(
        "CheckForUpdatesToolbarItemToolTip",
        comment: "Tool tip of a toolbar button that checks for updates"
      )
    )
    .disabled(!isEnabled)
    .accessibilityIdentifier("toolbar.refresh")
    .accessibilityLabel("Check for Updates")
  }
}

struct ToolbarUpdateProgressView: View {
  let presentation: ToolbarProgressPresentation

  @ViewBuilder
  var body: some View {
    switch presentation {
    case .hidden:
      EmptyView()
    case .determinate(let fraction):
      ProgressView(value: fraction)
        .progressViewStyle(.linear)
        .toolbarProgressFrame()
        .accessibilityLabel("Checking for updates")
    }
  }
}

extension View {
  fileprivate func toolbarProgressFrame() -> some View {
    frame(width: ToolbarProgressMetrics.width)
      .padding(.leading, ToolbarProgressMetrics.leadingPadding)
      .padding(.trailing, ToolbarProgressMetrics.trailingPadding)
  }
}
