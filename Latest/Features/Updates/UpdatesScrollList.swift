// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

/// Native selection, keyboard navigation, scrolling and context-menu targeting.
struct UpdatesScrollList: View {
  @ObservedObject var viewModel: UpdatesListViewModel
  let focus: FocusState<SidebarFocus?>.Binding
  @Environment(\.controlActiveState) private var controlActiveState

  static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    formatter.doesRelativeDateFormatting = true
    return formatter
  }()

  var body: some View {
    List(
      selection: Binding(
        get: { viewModel.selectedAppIDs },
        set: { viewModel.select($0, isKeyboardSelection: NSApp.currentEvent?.type == .keyDown) }
      )
    ) {
      ForEach(viewModel.snapshot.sections) { group in
        Section {
          ForEach(group.apps, id: \.identifier) { app in
            UpdateRowView(
              app: app, selection: UpdateRowSelection(style: selectionStyle(for: app)),
              date: Self.dateFormatter.string(from: app.updateDate),
              updating: viewModel.updating
            )
            .frame(minHeight: VisualMetrics.appRowHeight)
            .tag(app.identifier)
            .accessibilityIdentifier("updates.app.\(app.identifier)")
          }
        } header: {
          UpdateSectionHeaderView(section: group.section)
        }
      }
    }
    .listStyle(.sidebar)
    .background(SidebarScrollConfiguration())
    .focused(focus, equals: .list)
    .contextMenu(forSelectionType: App.Bundle.Identifier.self) { identifiers in
      let apps = viewModel.apps(for: identifiers)
      if apps.count == 1, let app = apps.first {
        UpdatesRowMenu(app: app, viewModel: viewModel)
      } else if !apps.isEmpty {
        Button("Update Selected Apps") { viewModel.updateSelection(identifiers) }
          .disabled(viewModel.automaticUpdateCandidates(identifiers).isEmpty)
        Button("Ignore Selected Apps") {
          apps.forEach { viewModel.setIgnored(true, for: $0) }
        }
        Button("Don't Ignore Selected Apps") {
          apps.forEach { viewModel.setIgnored(false, for: $0) }
        }
      }
    }
    .overlay {
      if viewModel.snapshot.entries.isEmpty && !viewModel.searchQuery.isEmpty {
        ContentUnavailableView.search(text: viewModel.searchQuery)
      }
    }
    .accessibilityIdentifier("updates.list")
    .accessibilityLabel("Apps")
  }

  private func selectionStyle(for app: App) -> UpdateRowSelection.Style {
    guard viewModel.selectedAppIDs.contains(app.identifier) else { return .unselected }
    return controlActiveState != .inactive && focus.wrappedValue == .list ? .active : .inactive
  }
}

private struct UpdatesRowMenu: View {
  let app: App
  let viewModel: UpdatesListViewModel

  var body: some View {
    Button {
      viewModel.update(app)
    } label: {
      Label(SidebarUpdateActionTitle.text(for: app), systemImage: "square.and.arrow.down")
    }.disabled(!app.isActionable || viewModel.updating.isUpdating(app))
    Button {
      viewModel.setIgnored(!app.isIgnored, for: app)
    } label: {
      if app.isIgnored {
        Label(
          NSLocalizedString("UnignoreAction", value: "Don't Ignore", comment: "Unignore app"),
          image: "custom.app.dashed.slash")
      } else {
        Label(
          NSLocalizedString("IgnoreAction", value: "Ignore", comment: "Ignore app"),
          systemImage: "app.dashed")
      }
    }
    Divider()
    Button {
      viewModel.open(app)
    } label: {
      Label(
        NSLocalizedString("OpenAction", comment: "Open app"), systemImage: "arrow.up.forward.app")
    }
    Button {
      viewModel.revealInFinder(app)
    } label: {
      Label(NSLocalizedString("RevealAction", comment: "Reveal app"), systemImage: "finder")
    }
  }
}
