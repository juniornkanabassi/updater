//
//  UpdateRowView.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

/// Value semantics let unchanged native-list rows retain their presentation.
struct UpdateRowSelection: Equatable {
  enum Style: Equatable {
    case unselected, inactive, active
  }
  var style = Style.unselected
  init(style: Style = .unselected) { self.style = style }
  var isSelected: Bool { style != .unselected }
  var usesActiveSelectionColors: Bool { style == .active }
}

struct UpdateRowView: View {
  let app: App
  let selection: UpdateRowSelection
  let updating: any AppUpdating
  let accessibilityLabel: String
  @State private var icon: NSImage?
  @Environment(\.controlActiveState) private var controlActiveState

  init(app: App, selection: UpdateRowSelection, date: String, updating: any AppUpdating) {
    self.app = app
    self.selection = selection
    self.updating = updating
    _icon = State(initialValue: IconCache.shared.cachedIcon(for: app))
    accessibilityLabel = [
      app.name,
      app.localizedVersionInformation?.combined(includeNew: app.updateAvailable)
        .replacingOccurrences(of: "→", with: "to"), date,
      app.routeShortDescription,
      app.isActionable ? SidebarUpdateActionTitle.text(for: app) : nil,
    ].compactMap { $0 }.joined(separator: ", ")
  }

  var body: some View {
    ObservedUpdatePresentation(app: app, updating: updating) { presentation in
      HStack(spacing: Space.sm) {
        Group {
          if let icon {
            Image(nsImage: icon).resizable().scaledToFit()
          } else {
            Image(systemName: "app").resizable().scaledToFit().foregroundStyle(.secondary)
          }
        }
        .frame(width: 40, height: 40)
        .opacity(controlActiveState == .inactive ? 0.5 : 1)
        .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: Space.xs) {
          Text(verbatim: app.name)
            .font(.headline)
            .help(app.name)
            .modifier(UpdateRowTextStyle(selection: selection, secondary: false))
            .accessibilityIdentifier("updates.title.\(app.identifier)")
          ViewThatFits(in: .horizontal) {
            versionText(app.versionSummary)
            versionText(availableVersionSummary)
          }
          .font(.subheadline.monospacedDigit())
          .help(app.versionSummary)
          .modifier(UpdateRowTextStyle(selection: selection, secondary: true))
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(app.versionSummary.replacingOccurrences(of: "→", with: "to"))
          .accessibilityIdentifier("updates.version.\(app.identifier)")
          statusLine(presentation)
            .font(.subheadline)
            .accessibilityIdentifier("updates.status.\(app.identifier)")
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)

        SidebarUpdateStatus(
          app: app, presentation: presentation, selection: selection, updating: updating)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(accessibilityText(for: presentation))
    }
    .task(id: IconCache.shared.cacheKey(for: app)) {
      icon = IconCache.shared.cachedIcon(for: app)
      let image = await IconCache.shared.icon(for: app)
      guard !Task.isCancelled else { return }
      icon = image
    }
  }

  private var availableVersionSummary: String {
    guard app.updateAvailable, let new = app.localizedVersionInformation?.rawNew else {
      return app.versionSummary
    }
    return "→ \(new)"
  }

  private func versionText(_ text: String) -> some View {
    Text(verbatim: text)
      .fixedSize(horizontal: true, vertical: false)
  }

  private func accessibilityText(for presentation: UpdateActionPresentation) -> String {
    let status: String?
    switch presentation {
    case .waiting(let message), .progress(_, let message, _): status = message
    case .retryTermination: status = "Waiting for \(app.name) to quit"
    case .failed(let reason): status = "Update failed: \(reason)"
    case .update, .open: status = nil
    }
    return [accessibilityLabel, status].compactMap { $0 }.joined(separator: ", ")
  }

  /// Progress and failures replace the route line in place, so the row says what is happening.
  @ViewBuilder
  private func statusLine(_ presentation: UpdateActionPresentation) -> some View {
    switch presentation {
    case .waiting(let status), .progress(_, let status, _):
      Text(status).modifier(UpdateRowTextStyle(selection: selection, secondary: true))
    case .retryTermination:
      Text("Waiting for \(app.name) to quit")
        .modifier(UpdateRowTextStyle(selection: selection, secondary: true))
    case .failed(let reason):
      Text("Update failed")
        .modifier(UpdateRowTextStyle(selection: selection, secondary: false))
        .help(reason)
        .accessibilityLabel("Update failed: \(reason)")
    case .update, .open:
      Text(app.routeShortDescription)
        .modifier(UpdateRowTextStyle(selection: selection, secondary: true))
    }
  }
}

/// Color changes leave the text's content and measured layout untouched.
private struct UpdateRowTextStyle: ViewModifier {
  let selection: UpdateRowSelection
  let secondary: Bool

  func body(content: Content) -> some View {
    content.foregroundStyle(
      Color(
        nsColor: selection.usesActiveSelectionColors
          ? .alternateSelectedControlTextColor : (secondary ? .secondaryLabelColor : .labelColor)))
  }
}
