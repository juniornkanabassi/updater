// Fork contributions © 2026 ertyoii.
// Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import Observation
import SwiftUI

struct UpdatesScrollList: View {
  @ObservedObject var viewModel: UpdatesListViewModel
  let showsSupportStatusOverride: Bool?
  let focus: FocusState<SidebarFocus?>.Binding
  @State private var navigation = SidebarScrollState()
  @Environment(\.controlActiveState) private var controlActiveState

  var body: some View {
    SidebarScrollingViewport(viewModel: viewModel, navigation: navigation) {
      LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
        ForEach(viewModel.snapshot.sections) { group in
          Section {
            Color.clear.frame(height: VisualMetrics.sectionHeaderSpacing)
              .accessibilityHidden(true)
            ForEach(group.apps, id: \.identifier) { app in
              UpdatesScrollRow(
                app: app, viewModel: viewModel,
                showsSupportStatus: showsSupportStatusOverride ?? true,
                focus: focus,
                selection: navigation.selection(for: app),
                select: { select($0, keyboard: false) }
              )
            }
          } header: {
            UpdateSectionHeaderView(section: group.section)
              .frame(height: VisualMetrics.sectionHeaderHeight)
              .background(Color(nsColor: .windowBackgroundColor))
              .accessibilityAddTraits(.isHeader)
          }
        }
      }
    }
    .scrollEdgeEffectHidden()
    .focusable()
    .focusEffectDisabled()
    .focused(focus, equals: .list)
    .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
      guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else {
        return .ignored
      }
      moveSelection(down: press.key == .downArrow)
      return .handled
    }
    .onScrollGeometryChange(for: CGRect.self) {
      $0.visibleRect
    } action: { _, next in
      // Geometry is input to navigation, not presentation state. Updating it
      // must not rebuild visible rows on every scroll frame.
      navigation.viewport = next
    }
    .onScrollPhaseChange { _, phase in
      if phase == .idle {
        MigrationTelemetry.shared.endSidebarScroll()
      } else {
        MigrationTelemetry.shared.beginSidebarScroll()
      }
    }
    .onChange(of: viewModel.snapshotRevision, initial: true) { _, _ in
      navigation.apply(snapshot: viewModel.snapshot)
      navigation.synchronize(viewModel.selectedApp?.identifier)
      let maximum = max(0, navigation.layout.contentHeight - navigation.viewport.height)
      if navigation.viewport.minY > maximum {
        scroll(to: maximum)
      }
    }
    .onChange(of: focus.wrappedValue, initial: true) { _, _ in
      navigation.setEmphasized(focus.wrappedValue == .list && controlActiveState != .inactive)
    }
    .onChange(of: controlActiveState) { _, _ in
      navigation.setEmphasized(focus.wrappedValue == .list && controlActiveState != .inactive)
    }
    .accessibilityIdentifier("updates.list")
    .accessibilityLabel("Apps")
  }

  private func moveSelection(down: Bool) {
    let snapshot = viewModel.snapshot
    let current = viewModel.selectedApp.flatMap { snapshot.firstIndex(of: $0) }
    var index = current.map { $0 + (down ? 1 : -1) } ?? 0
    while snapshot.entries.indices.contains(index) {
      if case .app(let app) = snapshot.entries[index] {
        moveSelection(to: app, row: navigation.layout.frames[index])
        return
      }
      index += current == nil || down ? 1 : -1
    }
    if let current, case .app(let app) = snapshot.entries[current] {
      moveSelection(to: app, row: navigation.layout.frames[current])
    }
  }

  private func moveSelection(to app: App, row: CGRect) {
    // Update both values in one transaction. No delayed scroll or animation may
    // move the viewport back after another key, a reversal, or a search change.
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      select(app, keyboard: true)
      let target = navigation.scrollOffset(for: row, viewport: navigation.viewport)
      if abs(target - navigation.viewport.minY) > 0.5 { scroll(to: target) }
    }
  }

  private func scroll(to y: CGFloat) {
    navigation.viewport.origin.y = y
    navigation.position.scrollTo(y: y)
  }

  private func select(_ app: App, keyboard: Bool) {
    navigation.synchronize(app.identifier)
    viewModel.select(app, isKeyboardSelection: keyboard)
  }
}

// Selection and ScrollPosition invalidate only this viewport. The lazy
// stack's view value stays stable across arrows and retains its accessibility rows.
private struct SidebarScrollingViewport<Content: View>: View {
  let viewModel: UpdatesListViewModel
  @Bindable var navigation: SidebarScrollState
  let content: Content

  init(
    viewModel: UpdatesListViewModel, navigation: SidebarScrollState,
    @ViewBuilder content: () -> Content
  ) {
    self.viewModel = viewModel
    self.navigation = navigation
    self.content = content()
  }

  var body: some View {
    ScrollView(.vertical) {
      content.background {
        SidebarScrollConfiguration()
          .accessibilityHidden(true)
      }
    }
    .scrollPosition($navigation.position)
    .onChange(of: viewModel.selectedApp?.identifier, initial: true) { _, identifier in
      navigation.synchronize(identifier)
    }
    .contextMenu {
      if let app = viewModel.selectedApp {
        UpdatesRowMenu(app: app, viewModel: viewModel)
      }
    }
  }
}

/// Keep scroll geometry out of SwiftUI invalidation. Selection updates only
/// two rows; the dictionary is bounded by the snapshot.
@MainActor
@Observable
private final class SidebarScrollState {
  var position = ScrollPosition()
  @ObservationIgnored private var emphasized = false
  @ObservationIgnored var viewport = CGRect.zero
  @ObservationIgnored private(set) var layout = SidebarLayout(entries: [])
  @ObservationIgnored private var selections: [App.Bundle.Identifier: UpdateRowSelection] = [:]
  @ObservationIgnored private var selected: App.Bundle.Identifier?

  func selection(for app: App) -> UpdateRowSelection {
    if let selection = selections[app.identifier] { return selection }
    let selection = UpdateRowSelection()
    selection.style =
      selected == app.identifier
      ? (emphasized ? .active : .inactive) : .unselected
    selections[app.identifier] = selection
    return selection
  }

  func apply(snapshot: AppListSnapshot) {
    layout = SidebarLayout(entries: snapshot.entries)
    let identifiers = Set(
      snapshot.entries.compactMap { entry in
        if case .app(let app) = entry { return app.identifier }
        return nil
      })
    selections = selections.filter { identifiers.contains($0.key) }
  }

  func scrollOffset(for row: CGRect, viewport: CGRect) -> CGFloat {
    guard viewport.height > 0 else { return viewport.minY }
    let margin = min(VisualMetrics.appRowHeight, viewport.height / 4)
    var y = viewport.minY
    if row.maxY > viewport.maxY - margin {
      y = row.maxY + margin - viewport.height
    } else if row.minY < viewport.minY + margin {
      y = row.minY - margin
    }
    return min(max(0, y), max(0, layout.contentHeight - viewport.height))
  }

  func synchronize(_ identifier: App.Bundle.Identifier?) {
    guard selected != identifier else { return }
    if let selected { selections[selected]?.style = .unselected }
    selected = identifier
    updateSelectionStyle()
  }

  func setEmphasized(_ value: Bool) {
    guard emphasized != value else { return }
    emphasized = value
    updateSelectionStyle()
  }

  private func updateSelectionStyle() {
    if let selected { selections[selected]?.style = emphasized ? .active : .inactive }
  }
}

private struct UpdatesScrollRow: View {
  // App equality omits remote metadata. Observe the snapshot directly so a
  // path-identified row reads current metadata even when ForEach reuses it.
  @ObservedObject var viewModel: UpdatesListViewModel
  let focus: FocusState<SidebarFocus?>.Binding
  let selection: UpdateRowSelection
  let select: (App) -> Void
  private let initialApp: App
  private let showsSupportStatus: Bool
  private var app: App {
    viewModel.snapshot.app(withIdentifier: initialApp.identifier) ?? initialApp
  }
  private var isSelected: Bool { selection.isSelected }

  init(
    app: App, viewModel: UpdatesListViewModel, showsSupportStatus: Bool,
    focus: FocusState<SidebarFocus?>.Binding, selection: UpdateRowSelection,
    select: @escaping (App) -> Void
  ) {
    self.initialApp = app
    self.showsSupportStatus = showsSupportStatus
    self._viewModel = ObservedObject(wrappedValue: viewModel)
    self.focus = focus
    self.selection = selection
    self.select = select
  }

  var body: some View {
    let app = self.app
    let content = UpdateRowView(
      app: app, selection: selection,
      date: Self.dateFormatter.string(from: app.updateDate),
      showsSupportStatus: showsSupportStatus, updating: viewModel.updating)
    GeometryReader { geometry in
      ZStack {
        content
          // Refresh metadata subscriptions without replacing the path-identified row.
          .id(ObjectIdentifier(app))
          .frame(width: geometry.size.width, height: VisualMetrics.appRowHeight)
          .offset(x: 16)
          .background {
            Color(nsColor: .windowBackgroundColor)
            if isSelected {
              RoundedRectangle(cornerRadius: 8)
                .fill(
                  selection.usesActiveSelectionColors
                    ? Color.accentColor : Color.primary.opacity(0.06)
                )
                .padding(.horizontal, 10)
            }
          }
          .contentShape(Rectangle())
          .onTapGesture(perform: selectApp)
          .contextMenu { UpdatesRowMenu(app: app, viewModel: viewModel) }
      }
      .clipped()
    }
    .frame(height: VisualMetrics.appRowHeight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(content.accessibilityLabel)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { selectApp() }
    .accessibilityIdentifier("updates.app.\(app.identifier)")
  }

  private func selectApp() {
    focus.wrappedValue = .list
    select(app)
  }

  private static let dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .none
    formatter.doesRelativeDateFormatting = true
    return formatter
  }()
}

private struct UpdatesRowMenu: View {
  let app: App
  let viewModel: UpdatesListViewModel

  var body: some View {
    Button {
      viewModel.update(app)
    } label: {
      Label(SidebarUpdateActionTitle.text(for: app), systemImage: "square.and.arrow.down")
    }.disabled(!app.updateAvailable || viewModel.updating.isUpdating(app))
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
