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
import Observation
import SwiftUI

/// SwiftUI row state shared by selection presentation.
@MainActor
@Observable
final class UpdateRowSelection {
  enum Style {
    case unselected, inactive, active
  }
  var style = Style.unselected
  var isSelected: Bool { style != .unselected }
  var usesActiveSelectionColors: Bool { style == .active }
}

struct UpdateRowView: View {
  let app: App
  let selection: UpdateRowSelection
  let updating: any AppUpdating
  let accessibilityLabel: String
  private let icon: NSImage
  @Environment(\.controlActiveState) private var controlActiveState

  init(app: App, selection: UpdateRowSelection, date: String, updating: any AppUpdating) {
    self.app = app
    self.selection = selection
    self.updating = updating
    icon = IconCache.shared.iconImmediately(for: app)
    accessibilityLabel = [
      app.name, app.localizedVersionInformation?.combined(includeNew: app.updateAvailable), date,
      app.routeShortDescription,
      app.isActionable ? SidebarUpdateActionTitle.text(for: app) : nil,
    ].compactMap { $0 }.joined(separator: ", ")
  }

  var body: some View {
    ObservedUpdatePresentation(app: app, updating: updating) { presentation in
      HStack(spacing: 10) {
        Image(nsImage: icon)
          .resizable()
          .scaledToFit()
          .frame(width: 40, height: 40)
          .opacity(controlActiveState == .inactive ? 0.5 : 1)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 1) {
          Text(verbatim: app.name)
            .font(.system(size: 13, weight: .semibold))
            .modifier(UpdateRowTextStyle(selection: selection, secondary: false))
          Text(verbatim: app.versionSummary)
            .font(.system(size: 11).monospacedDigit())
            .modifier(UpdateRowTextStyle(selection: selection, secondary: true))
          statusLine(presentation)
            .font(.system(size: 11))
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)

        SidebarUpdateStatus(
          app: app, presentation: presentation, selection: selection, updating: updating)
      }
      .padding(.trailing, 36)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .bottom) {
        UpdateRowSeparator(selection: selection)
      }
    }
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
      Text(reason)
        .foregroundStyle(
          selection.usesActiveSelectionColors
            ? Color(nsColor: .alternateSelectedControlTextColor) : Color(nsColor: .systemRed))
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

private struct UpdateRowSeparator: View {
  let selection: UpdateRowSelection

  var body: some View {
    Rectangle()
      .fill(Color(nsColor: .separatorColor))
      .frame(height: 1)
      .padding(.leading, 50)
      .padding(.trailing, 36)
      .opacity(selection.isSelected ? 0 : 1)
      .accessibilityHidden(true)
  }
}
