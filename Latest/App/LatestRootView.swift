//
//  LatestRootView.swift
//  Latest
//
//  Structural split from the original implementation.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-08-29.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

struct LatestRootView: View {
  let environment: AppEnvironment
  private let detailViewModel: ReleaseNotesDetailViewModel
  private let history: UpdateHistoryStore

  @FocusState private var focus: SidebarFocus?
  @ObservedObject private var updatesViewModel: UpdatesListViewModel
  @ObservedObject private var searchFocusController: SearchFocusController
  @State private var columnVisibility = NavigationSplitViewVisibility.all
  init(
    environment: AppEnvironment,
    detailViewModel: ReleaseNotesDetailViewModel = ReleaseNotesDetailViewModel(),
    history: UpdateHistoryStore = .shared
  ) {
    self.environment = environment
    self.detailViewModel = detailViewModel
    self.history = history
    _updatesViewModel = ObservedObject(wrappedValue: environment.updatesListViewModel)
    _searchFocusController = ObservedObject(wrappedValue: environment.searchFocusController)
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      UpdatesSidebarView(
        viewModel: updatesViewModel,
        searchFocusController: environment.searchFocusController
      )
      .navigationSplitViewColumnWidth(min: 260, ideal: VisualMetrics.sidebarIdealWidth, max: 480)
    } detail: {
      ReleaseNotesDetailView(
        updatesViewModel: updatesViewModel,
        detailViewModel: detailViewModel, history: history
      )
      .frame(minWidth: VisualMetrics.detailMinWidth)
      .navigationTitle("Updates")
    }
    .environment(\.windowFocus, $focus)
    .onChange(of: searchFocusController.request) { _, request in
      if request != nil { columnVisibility = .all }
    }
    .onAppear {
      if searchFocusController.hasPendingRequest { columnVisibility = .all }
    }
    .modifier(UpdateInstallHelperPresentation())
    .toolbar {
      UpdatesToolbar(
        service: environment.updateCheckingService, summary: environment.menuBar,
        reload: { environment.commands.reload() },
        updateAll: { environment.commands.updateAll() })
    }
  }
}
