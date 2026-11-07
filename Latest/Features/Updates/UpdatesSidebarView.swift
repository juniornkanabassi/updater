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
  @FocusState private var focus: SidebarFocus?
  @Environment(\.windowFocus) private var windowFocus
  @State private var searchPresented = false
  @State private var previousFocus = SidebarFocus.list

  private var activeFocus: FocusState<SidebarFocus?>.Binding { windowFocus ?? $focus }

  init(viewModel: UpdatesListViewModel, searchFocusController: SearchFocusController) {
    self.viewModel = viewModel
    self.searchFocusController = searchFocusController
  }

  var body: some View {
    UpdatesScrollList(viewModel: viewModel, focus: activeFocus)
      .searchable(
        text: Binding(get: { viewModel.searchQuery }, set: { viewModel.setSearchQuery($0) }),
        isPresented: $searchPresented,
        placement: .sidebar,
        prompt: "Search Apps"
      )
      .searchFocused(activeFocus, equals: .search)
      .onChange(of: searchFocusController.request, initial: true) { _, _ in
        if searchFocusController.consumeRequest() {
          searchPresented = true
          activeFocus.wrappedValue = .search
        }
      }

      .onExitCommand {
        guard activeFocus.wrappedValue == .search else { return }
        searchFocusController.dismissRequest()
        searchPresented = false
        activeFocus.wrappedValue = nil
        let request = searchFocusController.request
        Task { @MainActor in
          guard searchFocusController.request == request,
            activeFocus.wrappedValue == nil
          else { return }
          restorePreviousFocus()
        }
      }
      .onChange(of: activeFocus.wrappedValue) { _, new in
        if let new, new != .search { previousFocus = new }
      }
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
