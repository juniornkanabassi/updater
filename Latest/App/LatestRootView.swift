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

  @FocusState private var focus: SidebarFocus?
  @ObservedObject private var updatesViewModel: UpdatesListViewModel
  init(environment: AppEnvironment) {
    self.environment = environment
    _updatesViewModel = ObservedObject(wrappedValue: environment.updatesListViewModel)
  }

  var body: some View {
    HStack(spacing: 0) {
      UpdatesSidebarView(
        viewModel: updatesViewModel,
        searchFocusController: environment.searchFocusController,
        showsSupportStatusOverride: updatesViewModel.showsSupportStatus
      )
      .frame(width: VisualMetrics.sidebarIdealWidth)
      .frame(maxHeight: .infinity)
      .overlay(alignment: .trailing) {
        Divider().ignoresSafeArea(.container, edges: .top)
      }

      ReleaseNotesDetailView(
        updatesViewModel: updatesViewModel,
        showsSupportStatus: updatesViewModel.showsSupportStatus
      )
      .frame(minWidth: VisualMetrics.detailMinWidth)
      .overlay(alignment: .top) {
        Rectangle()
          .fill(Color(nsColor: .separatorColor))
          .frame(height: 1)
          .allowsHitTesting(false)
      }
    }
    .environment(\.windowFocus, $focus)
    .modifier(UpdateInstallHelperPresentation())
    .navigationTitle("Latest")
    .toolbar(removing: .title)
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Text(NSLocalizedString("Updates", comment: "Main toolbar title"))
          .font(.system(size: 15, weight: .semibold))
          // Navigation placement starts 96 points from the window's leading edge.
          .padding(
            .leading,
            VisualMetrics.sidebarIdealWidth + VisualMetrics.detailHeaderHorizontalPadding - 96
          )
          .accessibilityIdentifier("toolbar.title")
      }
      .sharedBackgroundVisibility(.hidden)
      UpdatesToolbar(service: environment.updateCheckingService) {
        environment.commands.reload()
      }
    }
  }
}
