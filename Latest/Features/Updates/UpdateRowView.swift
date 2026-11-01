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
  let showsSupportStatus: Bool
  let updating: any AppUpdating
  let accessibilityLabel: String
  private let icon: NSImage
  private let versions: App.DisplayableVersionInformation?
  private let date: String
  @Environment(\.controlActiveState) private var controlActiveState

  init(
    app: App, selection: UpdateRowSelection,
    date: String, showsSupportStatus: Bool, updating: any AppUpdating
  ) {
    self.app = app
    self.selection = selection
    self.showsSupportStatus = showsSupportStatus
    self.updating = updating
    icon = IconCache.shared.iconImmediately(for: app)
    let versions = app.localizedVersionInformation
    self.versions = versions
    accessibilityLabel = [
      app.name, versions?.combined(includeNew: app.updateAvailable), date,
      app.localizedSupportStatus,
      app.updateAvailable
        ? NSLocalizedString("UpdateAction", comment: "Action to update a given app.") : nil,
    ].compactMap { $0 }.joined(separator: ", ")
    self.date = date
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(nsImage: icon)
        .resizable()
        .scaledToFit()
        .frame(width: 50, height: 50)
        .opacity(controlActiveState == .inactive ? 0.5 : 1)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 0) {
        Text(verbatim: app.name)
          .font(.system(size: 13, weight: .semibold))
          .modifier(UpdateRowTextStyle(selection: selection, secondary: false))
          .frame(height: 16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.trailing, 59)
        Text(versions?.current ?? "")
          .font(.system(size: 11))
          .modifier(UpdateRowTextStyle(selection: selection, secondary: true))
          .frame(height: 14)
          .frame(maxWidth: .infinity, alignment: .leading)
        if app.updateAvailable, let versions {
          Text(versions.new ?? "")
            .font(.system(size: 11))
            .modifier(UpdateRowTextStyle(selection: selection, secondary: true))
            .frame(height: 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .lineLimit(1)
      .truncationMode(.tail)
    }
    .padding(.trailing, 36)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .topTrailing) {
      Text(verbatim: date)
        .font(.callout)
        .modifier(UpdateRowTextStyle(selection: selection, secondary: true))
        .lineLimit(1)
        .frame(width: 59, height: 16, alignment: .trailing)
        .padding(.top, 3.5)
        .padding(.trailing, 35.75)
    }
    .overlay(alignment: .bottomTrailing) {
      SidebarUpdateStatus(
        app: app, selection: selection, showsSupportStatus: showsSupportStatus, updating: updating
      )
      .padding(.bottom, 8)
      .padding(.trailing, 32)
    }
    .overlay(alignment: .bottom) {
      UpdateRowSeparator(selection: selection)
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
      .padding(.leading, 58)
      .padding(.trailing, 36)
      .opacity(selection.isSelected ? 0 : 1)
      .accessibilityHidden(true)
  }
}
