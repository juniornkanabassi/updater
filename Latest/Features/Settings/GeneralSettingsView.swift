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

  var body: some View {
    Form {
      Section {
        Picker("Appearance", selection: $appearanceRawValue) {
          ForEach(ApplicationAppearance.allCases) { appearance in
            Text(appearance.title).tag(appearance.rawValue)
          }
        }
        .pickerStyle(.segmented)
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

      Section("In the List") {
        preferenceOption(
          title: "Apps that update elsewhere",
          description:
            "Apps you finish updating in the App Store, Creative Cloud, Terminal or the app itself. They appear under Needs You.",
          isOn: limitedSupportBinding
        )
        preferenceOption(
          title: "Apps Updater can't check",
          description: "Apps with no update information. They appear under Other Apps.",
          isOn: unsupportedAppsBinding
        )
      }

      if viewModel.showsInstallHelperBanner {
        Section("App Store") {
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
    .scrollDisabled(true)
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
    VStack(alignment: .leading, spacing: 2) {
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
      .accessibilityLabel(title)
      .accessibilityHint(description)
  }

  private var limitedSupportBinding: Binding<Bool> {
    Binding(
      get: { viewModel.includeAppsWithLimitedSupport },
      set: { viewModel.includeAppsWithLimitedSupport = $0 }
    )
  }

  private var unsupportedAppsBinding: Binding<Bool> {
    Binding(
      get: { viewModel.includeUnsupportedApps },
      set: { viewModel.includeUnsupportedApps = $0 }
    )
  }
}
