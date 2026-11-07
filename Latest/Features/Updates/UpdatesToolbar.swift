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
  /// The same count the menu bar's Update All uses: exactly the apps Update All would start.
  @ObservedObject var summary: MenuBarViewModel
  let reload: () -> Void
  let updateAll: () -> Void

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
    ToolbarItem(placement: .primaryAction) {
      UpdateAllToolbarButton(count: summary.updateAllCount, action: updateAll)
    }
  }
}

/// The window's one primary action. It names its count so it is clear what will happen;
/// apps under Needs You are never touched by it.
struct UpdateAllToolbarButton: View {
  let count: Int
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Text(count > 0 ? "Update All (\(count))" : "Update All")
        .padding(.horizontal, Space.xs)
    }
    .buttonStyle(.borderedProminent)
    .disabled(count == 0)
    .help(
      count == 0
        ? "Nothing Updater can install by itself right now."
        : "Installs the \(count == 1 ? "update" : "\(count) updates") under Ready to Update. Apps under Needs You are left alone."
    )
    .accessibilityIdentifier("toolbar.updateAll")
    .accessibilityLabel(count == 1 ? "Update 1 app" : "Update all \(count) apps")
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
