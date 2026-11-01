//
//  UpdatesSidebarView.swift
//  Latest
//
//  Created by ertyoii on 31.05.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import AppKit
import SwiftUI

struct UpdatesSidebarView: View {
  @ObservedObject var viewModel: UpdatesListViewModel
  @ObservedObject var searchFocusController: SearchFocusController
  let showsSupportStatusOverride: Bool?
  @FocusState private var focus: SidebarFocus?
  @Environment(\.windowFocus) private var windowFocus
  @State private var previousFocus = SidebarFocus.list

  private var activeFocus: FocusState<SidebarFocus?>.Binding { windowFocus ?? $focus }

  init(
    viewModel: UpdatesListViewModel,
    searchFocusController: SearchFocusController,
    showsSupportStatusOverride: Bool? = nil
  ) {
    self.viewModel = viewModel
    self.searchFocusController = searchFocusController
    self.showsSupportStatusOverride = showsSupportStatusOverride
  }

  var body: some View {
    VStack(spacing: 0) {
      UpdatesSidebarHeaderView(
        viewModel: viewModel, searchFocusController: searchFocusController,
        focus: activeFocus, restoreFocus: restorePreviousFocus
      )
      // Keep the glass shadow above the scrolling content so the first
      // opaque section header does not cut it off at the search/list seam.
      .zIndex(1)
      UpdatesScrollList(
        viewModel: viewModel, showsSupportStatusOverride: showsSupportStatusOverride,
        focus: activeFocus)
    }
    .onChange(of: activeFocus.wrappedValue) { _, new in
      if let new, new != .search { previousFocus = new }
    }
    .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea(.container, edges: .top))
  }

  private func restorePreviousFocus() {
    if searchFocusController.restorePreviousResponder() { return }
    activeFocus.wrappedValue = previousFocus
  }
}

enum SidebarFocus: Hashable {
  case list
  case search
  case releaseNotes
}

extension EnvironmentValues {
  @Entry var windowFocus: FocusState<SidebarFocus?>.Binding?
}

struct UpdatesSidebarHeaderView: View {
  @ObservedObject var viewModel: UpdatesListViewModel
  @ObservedObject var searchFocusController: SearchFocusController
  let focus: FocusState<SidebarFocus?>.Binding
  let restoreFocus: () -> Void

  var body: some View {
    HStack(spacing: 1) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .frame(width: 16)
        .offset(x: -1.5)
        .accessibilityHidden(true)

      TextField(
        "Search",
        // An explicit setter avoids an actor-isolation thunk crash in Xcode 26.6.
        text: Binding(
          get: { viewModel.searchQuery },
          set: { viewModel.setSearchQuery($0) }
        )
      )
      .textFieldStyle(.plain)
      .font(.system(size: 13))
      .focused(focus, equals: .search)
      .accessibilityIdentifier("updates.search")
      .accessibilityLabel("Search Apps")
      .onExitCommand {
        focus.wrappedValue = nil
        Task { @MainActor in restoreFocus() }
      }

      if !viewModel.searchQuery.isEmpty {
        Button {
          viewModel.setSearchQuery("")
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .offset(x: 2.5)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear Search")
      }
    }
    .padding(.horizontal, 7)
    .frame(height: 28)
    .glassEffect(.regular, in: .capsule)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .onChange(of: searchFocusController.request, initial: true) { _, request in
      guard request != nil else { return }
      focus.wrappedValue = .search
    }
  }
}
