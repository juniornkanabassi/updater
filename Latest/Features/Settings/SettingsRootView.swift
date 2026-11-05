//
//  SettingsRootView.swift
//  Latest
//
//  Created by ertyoii on 03.06.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

struct SettingsRootView: View {
  @ObservedObject private var viewModel: SettingsViewModel
  private let permissionsModel: PermissionsViewModel

  init(
    viewModel: SettingsViewModel = SettingsViewModel(),
    permissionsModel: PermissionsViewModel = PermissionsViewModel()
  ) {
    self.viewModel = viewModel
    self.permissionsModel = permissionsModel
  }

  var body: some View {
    TabView(selection: $viewModel.selectedTab) {
      GeneralSettingsView(viewModel: viewModel)
        .tabItem { Label(SettingsViewModel.Tab.general.title, systemImage: "gearshape") }
        .tag(SettingsViewModel.Tab.general)
      LocationsSettingsView(viewModel: viewModel)
        .tabItem { Label(SettingsViewModel.Tab.locations.title, systemImage: "folder") }
        .tag(SettingsViewModel.Tab.locations)
      PermissionsSettingsView(model: permissionsModel)
        .tabItem { Label(SettingsViewModel.Tab.permissions.title, systemImage: "lock.shield") }
        .tag(SettingsViewModel.Tab.permissions)
    }
    .frame(width: 520)
    .fixedSize(horizontal: false, vertical: true)
  }
}
