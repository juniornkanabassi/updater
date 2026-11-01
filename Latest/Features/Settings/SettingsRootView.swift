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

  init(viewModel: SettingsViewModel = SettingsViewModel()) {
    self.viewModel = viewModel
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Settings", selection: $viewModel.selectedTab) {
        ForEach(SettingsViewModel.Tab.allCases, id: \.self) { tab in
          Text(tab.title).tag(tab)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .controlSize(.large)
      .frame(width: 240)
      .padding(.top, 12)
      .padding(.bottom, 4)

      switch viewModel.selectedTab {
      case .general:
        GeneralSettingsView(viewModel: viewModel)
      case .locations:
        LocationsSettingsView(viewModel: viewModel)
      }
    }
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
    .navigationTitle("Settings")
  }
}
