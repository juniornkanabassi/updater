//
//  GeneralSettingsView.swift
//  Latest
//
//  Created by ertyoii on 03.06.26.
//  Copyright © 2026 Max Langer. All rights reserved.
//
//  Fork contributions © 2026 ertyoii. First committed in this fork 2026-06-04.
//  Licensed under GPL-3.0; see LICENSE.md.

import SwiftUI

struct GeneralSettingsView: View {
  @ObservedObject var viewModel: SettingsViewModel
  @AppStorage(ApplicationAppearance.storageKey)
  private var appearanceRawValue = ApplicationAppearance.system.rawValue
  @AppStorage(BackgroundCheckInterval.storageKey)
  private var checkIntervalHours = BackgroundCheckInterval.defaultValue.rawValue
  @AppStorage(MenuBarViewModel.showsItemKey) private var showsMenuBarItem = true
  @AppStorage(AppStoreUpdateSettings.alwaysPerformManualUpdates.rawValue)
  private var alwaysOpenAppStore = false

  var body: some View {
    Form {
      Section {
        Picker("Appearance", selection: $appearanceRawValue) {
          ForEach(ApplicationAppearance.allCases) { appearance in
            Text(appearance.title).tag(appearance.rawValue)
          }
        }
        .pickerStyle(.radioGroup)
        .accessibilityIdentifier("settings.appearance")
      }

      Section("In the Background") {
        Picker(selection: $checkIntervalHours) {
          ForEach(BackgroundCheckInterval.allCases) { Text($0.title).tag($0.rawValue) }
        } label: {
          labelled(
            "Check for updates",
            "Also on launch and after sleep. Updater never installs on its own.")
        }
        .accessibilityLabel("Check for updates")
        .accessibilityIdentifier("settings.checkInterval")

        preferenceOption(
          title: "Show in menu bar",
          description: "Updater keeps running there when you close its window.",
          isOn: $showsMenuBarItem
        )
      }

      Section("App Store") {
        preferenceOption(
          title: "Always open App Store",
          description:
            "Open the App Store for its updates instead of installing them here. Turn this off to use Updater's helper.",
          isOn: $alwaysOpenAppStore
        )
        .accessibilityIdentifier("settings.appStore.manual")
        if viewModel.showsInstallHelperBanner {
          LabeledContent {
            Button("Enable") { viewModel.registerInstallHelper() }
          } label: {
            labelled(
              "Install App Store updates here",
              "Enables a helper so Updater can install App Store apps itself.")
          }
        }
      }
    }
    .formStyle(.grouped)
    .onAppear {
      viewModel.refreshInstallHelperAvailability()
    }
    .alert(
      "Unable to Enable Update Helper",
      isPresented: Binding(
        get: { viewModel.helperRegistrationError != nil },
        set: { if !$0 { viewModel.helperRegistrationError = nil } })
    ) {
      Button("OK", role: .cancel) { viewModel.helperRegistrationError = nil }
    } message: {
      Text(viewModel.helperRegistrationError ?? "")
    }
  }

  private func labelled(_ title: String, _ description: String) -> some View {
    VStack(alignment: .leading, spacing: Space.xs) {
      Text(title)
      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func preferenceOption(
    title: String,
    description: String,
    isOn: Binding<Bool>
  ) -> some View {
    Toggle(isOn: isOn) { labelled(title, description) }
      .toggleStyle(.switch)
      .controlSize(.mini)
      .accessibilityLabel(title)
      .accessibilityHint(description)
  }
}
